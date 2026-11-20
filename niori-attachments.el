;;; niori-attachments.el --- Documents attached to niori records  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health, database
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of niori.el.

;; niori.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; niori.el is delivered under the same terms.

;;; Commentary:

;; The documents niori manages — lab reports, letters from specialists,
;; package leaflets, photographs of a rash — live *next to* the database
;; in `niori-data-directory' (see `niori-documents-directory'), one
;; folder per record:
;;
;;   <data-dir>/documents/visits/42/2026-11-20-lab-report.pdf
;;   <data-dir>/documents/labs/7/2026-10-02-blood-panel.pdf
;;
;; The `attachments' table stores only paths *relative* to the documents
;; directory plus metadata (title, size, MIME type, SHA-256), so the whole
;; tree can be moved, synced or backed up as a unit and the database never
;; contains an absolute path.  `niori-attachments-file' refuses a stored
;; path that would escape that directory.
;;
;; Attaching copies the file and leaves the original untouched (see
;; `niori-attachments-import-method' for move/link).  Opening dispatches
;; on the extension: PDFs go to `doc-view', images to `image-mode', text
;; to its usual mode, and formats Emacs cannot render (docx, odt, xlsx…)
;; to `niori-attachments-external-opener'.
;;
;; Nothing is ever deleted behind the user's back: detaching asks before
;; removing a file, and deleting a record with attachments asks first and
;; keeps the files.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'dired)
(require 'tabulated-list)
(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

(defgroup niori-attachments nil
  "Documents attached to niori records."
  :group 'niori)

;; Loaded on demand by `niori-attachments--mime-type'.
(declare-function mailcap-extension-to-mime "mailcap" (extension))

(defcustom niori-documents-directory nil
  "Directory holding attachment files, or nil for the data directory's own.
When nil the files live in `niori-data-directory'/documents.  Set it
to keep documents on another volume — the database stores only
paths relative to this directory, so a Syncthing folder or a mounted
drive works as long as it stays reachable."
  :type '(choice (const :tag "Inside `niori-data-directory'" nil) directory)
  :group 'niori-attachments)

(defcustom niori-attachments-import-method 'copy
  "What attaching a file does to the original.
`copy' leaves the original where it was, so the data directory
holds a complete second copy of the record — the recommended
setting and the only one that makes the directory self-sufficient.
`move' removes the original.  `link' keeps the original in place
and stores a symbolic link, so the data directory is *not*
self-contained."
  :type '(choice (const :tag "Copy into the data directory" copy)
                 (const :tag "Move into the data directory" move)
                 (const :tag "Symlink to the original" link))
  :group 'niori-attachments)

(defcustom niori-attachments-max-size (* 64 1024 1024)
  "Size in bytes above which attaching a file asks for confirmation.
Nil disables the check."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'niori-attachments)

(defcustom niori-attachments-external-extensions
  '("doc" "docx" "odt" "rtf" "xls" "xlsx" "ods" "ppt" "pptx" "odp"
    "pages" "numbers" "key" "djvu")
  "File extensions Emacs cannot display, opened by an external program."
  :type '(repeat string)
  :group 'niori-attachments)

(defun niori-attachments--default-external-opener ()
  "Command that opens a file with the platform's default application."
  (cond ((eq system-type 'darwin) "open %s")
        ((memq system-type '(windows-nt ms-dos)) "start \"\" %s")
        (t "xdg-open %s")))

(defcustom niori-attachments-external-opener
  (niori-attachments--default-external-opener)
  "Shell command used for `niori-attachments-external-extensions'.
%s is replaced by the shell-quoted file name.  The default is
`xdg-open' on GNU/Linux and the BSDs, `open' on macOS, and `start' on
MS-Windows — except that MS-Windows actually goes through
`w32-shell-execute', which uses the shell's own file associations and
ignores this variable."
  :type 'string
  :group 'niori-attachments)

;;;; Schema

(niori-store-register-schema
 'attachments
 '(id table_name record_id title file_name kind mime_type file_size
      sha256 notes created_at updated_at)
 "CREATE TABLE attachments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  record_id INTEGER NOT NULL,
  title TEXT,
  file_name TEXT NOT NULL,
  kind TEXT,
  mime_type TEXT,
  file_size INTEGER,
  sha256 TEXT,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL)")

(niori-store-register-index 'attachments "attachments_record"
                            '(table_name record_id))
(niori-store-register-index 'attachments "attachments_sha256" '(sha256))

;;;; Paths

(defun niori-attachments--root ()
  "Absolute name of the documents directory (not created)."
  (if niori-documents-directory
      (file-name-as-directory (expand-file-name niori-documents-directory))
    (expand-file-name "documents/"
                      (niori-store--data-directory))))

(defun niori-attachments--ensure-root ()
  "Return the documents directory, creating it owner-only if needed."
  (let ((root (niori-attachments--root)))
    (unless (file-directory-p root)
      (make-directory root 'parents)
      (ignore-errors (set-file-modes root niori-store--directory-mode)))
    root))

(defun niori-attachments--record-directory (module record-id)
  "Folder holding the attachments of RECORD-ID of MODULE (not created)."
  (expand-file-name (format "%s/%s" module record-id)
                    (niori-attachments--root)))

(defun niori-attachments--ensure-directory (directory)
  "Create DIRECTORY below the documents directory, owner-only.
Every level niori creates there stays mode 0700, so the documents are
as private as the database even if the tree is later moved to a
shared volume."
  (let ((root (niori-attachments--ensure-root)))
    (unless (file-directory-p directory)
      (make-directory directory 'parents))
    (while (and (string-prefix-p root directory)
                (not (equal (file-name-as-directory directory) root)))
      (niori-store--tighten-directory directory)
      (setq directory (file-name-directory (directory-file-name directory))))
    directory))

(defun niori-attachments-file (attachment)
  "Absolute file name of ATTACHMENT, a plist from `niori-attachments-list'.
Signals a `user-error' when the stored path is not inside the
documents directory: the column is relative by contract, and a
hand-edited database must not turn into an arbitrary file reader."
  (let* ((root (niori-attachments--root))
         (relative (plist-get attachment 'file_name))
         (file (and (stringp relative)
                    (not (string-empty-p relative))
                    (expand-file-name relative root))))
    (unless (and file
                 (string-prefix-p root file)
                 (not (equal file root)))
      (user-error "Attachment %s has an invalid stored path (%s)"
                  (or (plist-get attachment 'id) "?") relative))
    file))

(defun niori-attachments--slug (name)
  "Return NAME reduced to something safe to use as a file name."
  (let* ((base (file-name-nondirectory (or name "")))
         (extension (file-name-extension base))
         (stem (file-name-sans-extension base))
         (slug (string-trim
                (downcase (replace-regexp-in-string "[^[:alnum:]]+" "-" stem))
                "-" "-")))
    (when (string-empty-p slug)
      (setq slug "file"))
    (setq slug (substring slug 0 (min 60 (length slug))))
    (if (and extension (not (string-empty-p extension)))
        (format "%s.%s" slug
                (downcase (replace-regexp-in-string "[^[:alnum:]]" "" extension)))
      slug)))

(defun niori-attachments--path-taken-p (file)
  "Non-nil when a stored attachment already claims FILE."
  (let ((relative (file-relative-name file (niori-attachments--root))))
    (and (niori-store-select 'attachments
                             :where "file_name = ?" :params (list relative))
         t)))

(defun niori-attachments--target-file (module record-id source)
  "Free absolute path for attaching SOURCE to RECORD-ID of MODULE."
  (let* ((directory (niori-attachments--record-directory module record-id))
         (slug (niori-attachments--slug source))
         (counter 0)
         file)
    (while (progn
             (setq file (expand-file-name
                         (if (= counter 0)
                             (format "%s-%s" (niori--today) slug)
                           (format "%s-%d-%s" (niori--today) counter slug))
                         directory))
             (and (or (file-exists-p file)
                      (niori-attachments--path-taken-p file))
                  (setq counter (1+ counter)))))
    file))

;;;; File metadata

(defun niori-attachments--kind (file)
  "Coarse kind of FILE: `image', `document' or `other'."
  (let ((extension (downcase (or (file-name-extension file) ""))))
    (cond ((member extension '("png" "jpg" "jpeg" "gif" "svg" "webp"
                               "tif" "tiff" "bmp" "heic" "avif"))
           "image")
          ((member extension '("pdf" "doc" "docx" "odt" "rtf" "txt" "md"
                               "org" "csv" "xls" "xlsx" "ods"))
           "document")
          (t "other"))))

(defun niori-attachments--mime-type (file)
  "MIME type of FILE as guessed from its extension, or nil."
  (when (require 'mailcap nil t)
    (ignore-errors
      (mailcap-extension-to-mime (or (file-name-extension file) "")))))

(defun niori-attachments--sha256 (file)
  "SHA-256 checksum of FILE, or nil when it cannot be read."
  (when (file-regular-p file)
    (ignore-errors
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (secure-hash 'sha256 (current-buffer))))))

(defun niori-attachments--format-size (bytes)
  "Render BYTES as a short human readable string."
  (let ((size (or bytes 0)))
    (cond ((>= size (* 1024 1024)) (format "%.1f MB" (/ size (* 1024.0 1024.0))))
          ((>= size 1024) (format "%.0f kB" (/ size 1024.0)))
          (t (format "%d B" size)))))

;;;; Reading attachments

(defun niori-attachments-list (&optional module record-id)
  "Attachments of RECORD-ID in MODULE, newest first.
With MODULE nil, every attachment in the database."
  (if module
      (niori-store-select 'attachments
                          :where "table_name = ? AND record_id = ?"
                          :params (list (symbol-name module) record-id)
                          :order "id DESC")
    (niori-store-select 'attachments :order "id DESC")))

(defun niori-attachments-count (&optional module record-id)
  "Number of attachments of RECORD-ID in MODULE (of everything, if nil)."
  (length (niori-attachments-list module record-id)))

(defun niori-attachments--row (id)
  "Attachment row ID, or nil."
  (niori-store-get 'attachments id))

(defun niori-attachments--describe (row)
  "One-line description of attachment ROW."
  (format "%s #%s — %s"
          (plist-get row 'table_name)
          (plist-get row 'record_id)
          (or (plist-get row 'title)
              (file-name-nondirectory (plist-get row 'file_name)))))

(defun niori-attachments--read-attachment (&optional prompt)
  "Read an attachment with completion; return its id."
  (let* ((rows (niori-attachments-list))
         (alist (mapcar (lambda (row)
                          (cons (niori-attachments--describe row)
                                (plist-get row 'id)))
                        rows)))
    (unless rows
      (user-error "No attachments yet"))
    (cdr (assoc (completing-read (or prompt "Attachment: ")
                                 (mapcar #'car alist) nil t)
                alist))))

;;;; Attaching

(defun niori-attachments-add (module record-id file &optional title)
  "Attach FILE to record RECORD-ID of MODULE, returning the new id.
The file is copied into the record's folder under
`niori-documents-directory' (or moved, or symlinked, according to
`niori-attachments-import-method') and its metadata is stored in
the `attachments' table.  TITLE defaults to the file's base name."
  (interactive
   (let* ((module (or (bound-and-true-p niori--module)
                      (niori--read-module)))
          (record-id (if (and (eq module (bound-and-true-p niori--module))
                              (bound-and-true-p niori--record-id))
                         niori--record-id
                       (niori-view--read-record module "Attach to: ")))
          (file (read-file-name "Attach file: " nil nil t)))
     (list module record-id file)))
  (unless (file-regular-p file)
    (user-error "%s is not a readable file" file))
  (let ((size (file-attribute-size (file-attributes file))))
    (when (and niori-attachments-max-size
               size
               (> size niori-attachments-max-size)
               (not (y-or-n-p
                     (format "%s is %s — attach it anyway? "
                             (file-name-nondirectory file)
                             (niori-attachments--format-size size)))))
      (user-error "Attachment cancelled")))
  (let* ((root (niori-attachments--root))
         (target (niori-attachments--target-file module record-id file))
         (relative (file-relative-name target root)))
    (niori-attachments--ensure-directory (file-name-directory target))
    (condition-case error
        (pcase niori-attachments-import-method
          ;; Only a stored copy is chmodded: a symlink must never change
          ;; the permissions of the file the user still owns elsewhere.
          ('move (condition-case nil
                     (rename-file file target)
                   (file-error
                    (copy-file file target)
                    (ignore-errors (delete-file file))))
                 (niori-store--secure-file target))
          ('link (make-symbolic-link (expand-file-name file) target))
          (_ (copy-file file target)
             (niori-store--secure-file target)))
      (file-error
       (user-error "Could not store %s in %s (%s)"
                   file root (error-message-string error))))
    (let ((id (niori-store-insert
               'attachments
               `((table_name . ,(symbol-name module))
                 (record_id . ,record-id)
                 (title . ,(or title (file-name-nondirectory file)))
                 (file_name . ,relative)
                 (kind . ,(niori-attachments--kind file))
                 (mime_type . ,(niori-attachments--mime-type file))
                 (file_size . ,(file-attribute-size (file-attributes target)))
                 (sha256 . ,(niori-attachments--sha256 target))))))
      (niori-attachments--refresh)
      (message "niori: attached %s to %s #%s"
               (file-name-nondirectory file)
               (niori-view--module-title module)
               record-id)
      id)))

(defun niori-attachments-rename (id title)
  "Retitle attachment ID and rename its file to match.
The file stays in its record's folder; the date prefix is kept so
the folder stays in chronological order."
  (interactive
   (let* ((id (niori-attachments--read-attachment))
          (row (niori-attachments--row id)))
     (list id (read-string "Title: " (plist-get row 'title)))))
  (let* ((row (niori-attachments--row id))
         (file (niori-attachments-file row))
         (directory (file-name-directory file))
         (base (file-name-nondirectory file))
         (prefix (if (string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" base)
                     (match-string 1 base)
                   (niori--today)))
         (extension (file-name-extension file))
         (suffix (if extension (concat "." extension) ""))
         (slug (niori-attachments--slug title))
         (counter 0)
         target)
    (while (progn
             (setq target (expand-file-name
                           (if (= counter 0)
                               (format "%s-%s%s" prefix slug suffix)
                             (format "%s-%s-%d%s" prefix slug counter suffix))
                           directory))
             (and (file-exists-p target)
                  (not (equal target file))
                  (setq counter (1+ counter)))))
    (unless (equal target file)
      (rename-file file target))
    (condition-case error
        (niori-store-update 'attachments id
                            `((title . ,title)
                              (file_name . ,(file-relative-name
                                             target (niori-attachments--root)))))
      (error
       ;; Keep the file and the row consistent rather than leaving a
       ;; record that points at a file which is no longer there.
       (when (and (not (equal target file)) (file-exists-p target))
         (ignore-errors (rename-file target file)))
       (signal (car error) (cdr error))))
    (niori-attachments--refresh)
    id))

;;;; Opening

(defun niori-attachments--open-external (file)
  "Open FILE with the system's default application.
MS-Windows uses `w32-shell-execute' (the shell's file associations);
everywhere else `niori-attachments-external-opener' runs as a shell
command."
  (if (fboundp 'w32-shell-execute)
      (w32-shell-execute "open" file)
    (let* ((command (format niori-attachments-external-opener
                            (shell-quote-argument file)))
           (program (car (split-string command))))
      (unless (executable-find program)
        (user-error "No external opener (%s) found; customize `niori-attachments-external-opener'"
                    program))
      (call-process-shell-command command nil 0)))
  file)

(defun niori-attachments-open (id &optional external)
  "Open attachment ID.
PDFs open in `doc-view', images in `image-mode', text in its usual
mode.  With EXTERNAL (a prefix argument), or for an extension listed
in `niori-attachments-external-extensions', an external program
opens the file instead."
  (interactive
   (list (niori-attachments--read-attachment) current-prefix-arg))
  (let* ((row (niori-attachments--row id))
         (file (and row (niori-attachments-file row)))
         (extension (downcase (or (and file (file-name-extension file)) ""))))
    (unless row
      (user-error "No attachment with id %s" id))
    (unless (file-exists-p file)
      (user-error "Attached file is missing: %s (see M-x niori-attachments-check)"
                  file))
    (setq file (expand-file-name file))
    (if (or external (member extension niori-attachments-external-extensions))
        (niori-attachments--open-external file)
      (pop-to-buffer (find-file-noselect file)))
    file))

(defun niori-attachments-reveal (id)
  "Show attachment ID's folder in Dired."
  (interactive (list (niori-attachments--read-attachment)))
  (let ((file (niori-attachments-file (niori-attachments--row id))))
    (unless (file-exists-p file)
      (user-error "Attached file is missing: %s" file))
    (dired (file-name-directory file))
    (dired-goto-file file)))

;;;; Removing

(defun niori-attachments--delete-row (id delete-file)
  "Delete attachment ID; delete its file too when DELETE-FILE is non-nil.
A file another attachment still points at is never deleted.  No
buffer is refreshed here, so bulk callers can do it once."
  (let ((row (niori-attachments--row id)))
    (unless row
      (user-error "No attachment with id %s" id))
    (let* ((file (ignore-errors (niori-attachments-file row)))
           (relative (plist-get row 'file_name))
           (shared (seq-some (lambda (other)
                               (and (not (equal (plist-get other 'id) id))
                                    (equal (plist-get other 'file_name) relative)))
                             (niori-attachments-list))))
      (niori-store-delete 'attachments id)
      (when (and delete-file file (file-exists-p file))
        (if shared
            (message "niori: file kept — another record uses it too")
          (delete-file file)
          (message "niori: deleted %s" file))))
    id))

(defun niori-attachments-detach (id &optional delete-file)
  "Remove attachment ID, and its file when DELETE-FILE is non-nil.
A file another attachment still points at is never deleted."
  (interactive
   (let ((id (niori-attachments--read-attachment)))
     (list id (y-or-n-p "Also delete the file? "))))
  (prog1 (niori-attachments--delete-row id delete-file)
    (niori-attachments--refresh)))

(defun niori-attachments--orphan-p (row)
  "Non-nil when attachment ROW lost its owning record."
  (condition-case nil
      (null (niori-store-get (intern (plist-get row 'table_name))
                             (plist-get row 'record_id)))
    (error nil)))

(defun niori-attachments-orphans ()
  "Attachments whose owning record no longer exists."
  (seq-filter #'niori-attachments--orphan-p (niori-attachments-list)))

(defun niori-attachments-purge-orphans (&optional keep-files)
  "Delete attachment rows whose record no longer exists.
The files go too unless KEEP-FILES is non-nil (interactively, a
prefix argument)."
  (interactive "P")
  (let ((orphans (niori-attachments-orphans)))
    (unless orphans
      (user-error "No orphaned attachments"))
    (when (y-or-n-p (format "Remove %d orphaned attachment(s)%s? "
                            (length orphans)
                            (if keep-files " (keeping the files)" "")))
      (dolist (row orphans)
        (niori-attachments--delete-row (plist-get row 'id) (not keep-files)))
      (niori-attachments--refresh)
      (message "niori: purged %d orphaned attachment(s)" (length orphans)))))

;;;; Integrity check

(defun niori-attachments-check ()
  "List attachments whose file is missing, orphaned or duplicated."
  (interactive)
  (let ((rows (niori-attachments-list))
        (missing nil)
        (orphans nil)
        (duplicates nil)
        (seen (make-hash-table :test #'equal)))
    (dolist (row rows)
      (let ((file (ignore-errors (niori-attachments-file row))))
        (cond ((null file) (push row missing))
              ((not (file-exists-p file)) (push row missing)))
        (when (niori-attachments--orphan-p row)
          (push row orphans))
        (let ((sha (plist-get row 'sha256)))
          (when sha
            (if (gethash sha seen)
                (push row duplicates)
              (puthash sha t seen))))))
    (let ((buffer (get-buffer-create "*niori attachments check*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "niori attachment check\n\n" 'face 'bold))
          (insert (format "%d attachment(s), documents in %s\n\n"
                          (length rows) (niori-attachments--root)))
          (dolist (section (list (cons (format "Missing files (%d)"
                                               (length missing))
                                       missing)
                                 (cons (format "Orphaned links (%d)"
                                               (length orphans))
                                       orphans)
                                 (cons (format "Possible duplicates (%d)"
                                               (length duplicates))
                                       duplicates)))
            (insert (propertize (car section) 'face 'bold) "\n")
            (if (null (cdr section))
                (insert (propertize "  none\n" 'face 'shadow))
              (dolist (row (reverse (cdr section)))
                (insert "  " (niori-attachments--describe row) "\n")))
            (insert "\n"))
          (insert (propertize
                   (concat "M-x niori-attachments-purge-orphans removes "
                           "links to deleted records.\n")
                   'face 'shadow))
          (special-mode)
          (goto-char (point-min))))
      (unless noninteractive (pop-to-buffer buffer))
      buffer)))

;;;; The documents buffer

(defvar-keymap niori-documents-mode-map
  :parent tabulated-list-mode-map
  :doc "Keymap for the niori documents buffer."
  "RET" #'niori-documents-open
  "a" #'niori-attachments-add
  "d" #'niori-documents-detach
  "r" #'niori-documents-rename
  "o" #'niori-documents-reveal
  "f" #'niori-documents-open-external
  "c" #'niori-attachments-check
  "g" #'niori-documents--revert)

(define-derived-mode niori-documents-mode tabulated-list-mode "niori-documents"
  "Major mode listing every document niori manages.
\\<niori-documents-mode-map>\\[niori-documents-open] opens the file at point,\
 \\[niori-attachments-add] attaches a new one, \\[niori-documents-detach]
detaches it and \\[niori-documents-reveal] shows it in Dired."
  (setq tabulated-list-format
        [("Record" 22 t)
         ("Title" 34 t)
         ("Kind" 9 t)
         ("Size" 9 nil)
         ("Added" 11 t)
         ("State" 9 t)])
  (setq-local revert-buffer-function #'niori-documents--revert)
  (tabulated-list-init-header))

(defun niori-documents--revert (&rest _)
  "Repopulate the documents buffer."
  (niori-documents--refresh))

(defun niori-documents--refresh ()
  "Repopulate the current documents buffer, keeping point in place."
  (setq tabulated-list-entries (niori-documents--entries))
  (tabulated-list-print t)
  (unless tabulated-list-entries
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n  No documents yet — press ‘a’ to attach one.\n")))
  (goto-char (point-min)))

(defun niori-documents--entries ()
  "Build `tabulated-list-entries' for the documents buffer."
  (mapcar
   (lambda (row)
     (let* ((file (ignore-errors (niori-attachments-file row)))
            (present (and file (file-exists-p file))))
       (list (plist-get row 'id)
             (vector (format "%s #%s" (plist-get row 'table_name)
                             (plist-get row 'record_id))
                     (or (plist-get row 'title) "")
                     (or (plist-get row 'kind) "")
                     (niori-attachments--format-size (plist-get row 'file_size))
                     (substring (or (plist-get row 'created_at) "") 0
                                (min 10 (length (or (plist-get row 'created_at) ""))))
                     (if present "ok" "MISSING")))))
   (niori-attachments-list)))

(defun niori-documents ()
  "Open the buffer listing every document niori manages."
  (interactive)
  (niori-store-open)
  (let ((buffer (get-buffer-create "*niori documents*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'niori-documents-mode)
        (niori-documents-mode))
      (niori-documents--refresh))
    (unless noninteractive (pop-to-buffer buffer))
    buffer))

(defun niori-documents--id-at-point ()
  "Id of the document at point, or nil."
  (tabulated-list-get-id))

(defun niori-documents-open (&optional external)
  "Open the document at point."
  (interactive "P")
  (let ((id (niori-documents--id-at-point)))
    (if id
        (niori-attachments-open id external)
      (user-error "No document on this line"))))

(defun niori-documents-open-external ()
  "Open the document at point with an external program."
  (interactive)
  (niori-documents-open t))

(defun niori-documents-detach ()
  "Detach the document at point."
  (interactive)
  (let ((id (niori-documents--id-at-point)))
    (unless id (user-error "No document on this line"))
    (niori-attachments-detach id (y-or-n-p "Also delete the file? "))))

(defun niori-documents-rename ()
  "Retitle the document at point."
  (interactive)
  (let* ((id (niori-documents--id-at-point))
         (row (and id (niori-attachments--row id))))
    (unless row (user-error "No document on this line"))
    (niori-attachments-rename
     id (read-string "Title: " (plist-get row 'title)))))

(defun niori-documents-reveal ()
  "Show the folder of the document at point in Dired."
  (interactive)
  (let ((id (niori-documents--id-at-point)))
    (unless id (user-error "No document on this line"))
    (niori-attachments-reveal id)))

;;;; Integration with the detail view and record deletion

(defun niori-attachments--refresh ()
  "Re-render niori buffers after an attachment changed."
  (niori-view-refresh-all)
  (when (get-buffer "*niori documents*")
    (with-current-buffer (get-buffer "*niori documents*")
      (niori-documents--refresh))))

(defun niori-attachments--detail-section ()
  "Insert the attachments block into the current detail buffer."
  (when (and niori--module niori--record-id)
    (niori-attachments--insert-detail-section)))

(defun niori-attachments--insert-detail-section ()
  "Insert the attachments block of the record shown here."
  (let* ((module niori--module)
         (record-id niori--record-id)
         (rows (niori-attachments-list module record-id)))
    (niori-detail--section-title (format "Attachments (%d)" (length rows)))
    (if (null rows)
        (insert (propertize "  none yet — press A to attach a file\n"
                            'face 'shadow))
      (dolist (row rows)
        (let* ((id (plist-get row 'id))
               (file (ignore-errors (niori-attachments-file row)))
               (present (and file (file-exists-p file))))
          (insert "  • ")
          (insert-button (or (plist-get row 'title)
                             (file-name-nondirectory (plist-get row 'file_name)))
                         :follow-link t
                         :action (lambda (&rest _) (niori-attachments-open id))
                         'help-echo (if present file "File is missing"))
          (insert (propertize
                   (format "  %s, %s%s"
                           (or (plist-get row 'kind) "file")
                           (niori-attachments--format-size
                            (plist-get row 'file_size))
                           (if present "" "  (MISSING)"))
                   'face (if present 'shadow 'warning)))
          (insert "  ")
          (insert-button "detach"
                         :follow-link t
                         :action (lambda (&rest _)
                                   (niori-attachments-detach id))
                         'help-echo "Remove the link; the file is kept")
          (insert "\n"))))
    (insert "\n")))

(defun niori-attachments--before-delete (module record-id)
  "Ask before deleting a record that has attachments.
Both the files and their links are kept (so the files stay reachable
and `niori-attachments-purge-orphans' can tidy up later); the
confirmation says so.  Returning non-nil cancels the deletion."
  (let ((count (niori-attachments-count module record-id)))
    (and (> count 0)
         (not (y-or-n-p
               (format "This record has %d attachment(s). The files and their links will be kept (purge them later). Delete anyway? "
                       count))))))

(add-hook 'niori-detail-sections-hook #'niori-attachments--detail-section)
(add-hook 'niori-record-before-delete-hook #'niori-attachments--before-delete)

;;;; Commands

(niori-register-command 'documents #'niori-documents
                        :title "Browse the documents attached to records")

(provide 'niori-attachments)

;;; niori-attachments.el ends here
