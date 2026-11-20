;;; test-niori-attachments.el --- ERT tests for the data directory and attachments  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'niori-test-helper)

;;;; Helpers

(defun niori-test--source-dir ()
  "Create a temporary directory to import files from."
  (file-name-as-directory (make-temp-file "niori-src-" t)))

(defun niori-test--write (directory name content)
  "Write CONTENT to NAME in DIRECTORY; return the full path."
  (let ((file (expand-file-name name directory)))
    (make-directory (file-name-directory file) 'parents)
    (with-temp-file file (insert content))
    file))

(defmacro niori-test--with-source-files (specs &rest body)
  "Run BODY with a source directory holding SPECS ((NAME . CONTENT)...).
The source directory is bound to `source-directory'."
  (declare (indent 1))
  `(let* ((source-directory (niori-test--source-dir))
          (files (mapcar (lambda (spec)
                           (niori-test--write source-directory
                                              (car spec) (cdr spec)))
                         ,specs)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory source-directory 'recursive)))))

(defun niori-test--visit ()
  "Insert a visit record and return its id."
  (niori-store-insert 'visits '((date . "2026-11-20") (doctor . "House"))))

;;;; The data directory

(ert-deftest niori-data-directory-is-created-on-open ()
  "Opening the database creates the data directory, its marker and subdirectories."
  (niori-with-test-data-dir
    (let ((root (niori-store--data-directory)))
      (should (file-directory-p root))
      (should (file-exists-p (niori-store--data-file)))
      (should (equal (expand-file-name "niori.db" root)
                     (niori-store--data-file)))
      (should (file-exists-p (expand-file-name ".niori-data" root)))
      (should (file-directory-p (expand-file-name "backups" root)))
      (should (file-directory-p (expand-file-name "exports" root)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name ".niori-data" root))
        (should (string-match-p "layout-version: 1" (buffer-string)))))))

(ert-deftest niori-data-directory-is-private ()
  "A data directory created by niori is not readable by other local users."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (should (equal 0 (logand (file-modes (niori-store--data-directory))
                             #o077)))))

(ert-deftest niori-data-subdirectory-rejects-escapes ()
  "Subdirectory names may not leave the data directory."
  (niori-with-test-data-dir
    (dolist (name '("../escape" "/etc" "a/../../b"))
      (should-error (niori-data-subdirectory name)))))

(ert-deftest niori-data-file-override-still-wins ()
  "An explicit `niori-data-file' places the database outside the data directory."
  (niori-with-test-data-dir
    (let ((override (make-temp-name (expand-file-name "niori-override-"
                                                      temporary-file-directory))))
      (unwind-protect
          (let ((niori-data-file override))
            (niori-store-close)
            (niori-store-open)
            (should (equal override (niori-store--data-file)))
            (should (file-exists-p override))
            ;; Documents stay inside the data directory.
            (should (string-prefix-p (niori-store--data-directory)
                                     (niori-data-subdirectory "documents"))))
        (niori-store-close)
        (ignore-errors (delete-file override))))))

(ert-deftest niori-store-creates-late-registered-tables ()
  "A table registered after the database was migrated is created on open."
  (niori-with-test-data-dir
    (niori-store--exec "DROP TABLE IF EXISTS attachments")
    (niori-store-close)
    (niori-store-open)
    (should (= 0 (niori-store-count 'attachments)))
    (should (numberp (niori-store-insert 'attachments
                                         '((table_name . "visits")
                                           (record_id . 1)
                                           (file_name . "visits/1/x.pdf")))))
    (should (= 1 (length (niori-store--exec
                          "SELECT name FROM sqlite_master
                           WHERE name = 'attachments_record'"))))))

(ert-deftest niori-store-switch-data-directory ()
  "Switching the data directory reopens the database from the new location."
  (niori-with-test-data-dir
    (niori-test--visit)
    (should (= 1 (niori-store-count 'visits)))
    (let ((other (file-name-as-directory (make-temp-file "niori-other-" t))))
      (unwind-protect
          (progn
            ;; A directory with no marker and no database is confirmed first.
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (niori-store-switch-data-directory other))
            (should (equal (file-name-as-directory (expand-file-name other))
                           (niori-store--data-directory)))
            (should (file-exists-p (expand-file-name "niori.db" other)))
            ;; The new directory starts empty; the old records are not there.
            (should (= 0 (niori-store-count 'visits))))
        (niori-store-close)
        (ignore-errors (delete-directory other 'recursive))))))

(ert-deftest niori-store-switch-refreshes-open-buffers ()
  "Switching the data directory re-renders or kills the buffers on screen."
  (niori-with-test-data-dir
    (let* ((id (niori-test--visit))
           (buffer (niori-detail 'visits id)))
      (with-current-buffer buffer
        (should (string-match-p "House" (buffer-string))))
      (let ((other (file-name-as-directory (make-temp-file "niori-other-" t))))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (niori-store-switch-data-directory other))
              ;; The record is not in the new directory: the stale detail
              ;; buffer is killed instead of showing a ghost.
              (should-not (buffer-live-p buffer)))
          (niori-store-close)
          (ignore-errors (delete-directory other 'recursive)))))))

;;;; Attaching files

(ert-deftest niori-attachments-add-copies-into-the-data-directory ()
  "Attaching copies the file into the record's folder and records metadata."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let* ((file (car files))
             (id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id file))
             (row (niori-store-get 'attachments attachment))
             (stored (niori-attachments-file row)))
        (should (equal (plist-get row 'table_name) "visits"))
        (should (equal (plist-get row 'record_id) id))
        (should (equal (plist-get row 'title) "lab-report.pdf"))
        (should (equal (plist-get row 'kind) "document"))
        (should (= (plist-get row 'file_size) 3))
        (should (equal 64 (length (plist-get row 'sha256))))
        (should (string-prefix-p (format "visits/%d/" id)
                                 (plist-get row 'file_name)))
        (when (plist-get row 'mime_type)
          (should (string-match-p "pdf" (plist-get row 'mime_type))))
        ;; The copy is inside documents/ and holds the same bytes.
        (should (string-prefix-p
                 (expand-file-name "documents/" (niori-store--data-directory))
                 stored))
        (should (file-exists-p stored))
        (should (equal "PDF"
                       (with-temp-buffer
                         (insert-file-contents stored)
                         (buffer-string))))
        ;; The default import method leaves the original alone.
        (should (file-exists-p file))))))

(ert-deftest niori-attachments-are-private ()
  "Stored documents and the database are readable by their owner only."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (stored (niori-attachments-file
                      (niori-store-get 'attachments attachment))))
        (should (equal 0 (logand (file-modes stored) #o077)))
        (should (equal 0 (logand (file-modes (file-name-directory stored))
                                 #o077)))
        (should (equal 0 (logand (file-modes (niori-store--data-file))
                                 #o077)))))))

(ert-deftest niori-attachments-same-name-coexists ()
  "Two files with the same base name get distinct paths."
  (niori-with-test-data-dir
    (let ((id (niori-test--visit)))
      (niori-test--with-source-files '(("report.pdf" . "one"))
        (niori-attachments-add 'visits id (car files)))
      (niori-test--with-source-files '(("report.pdf" . "two"))
        (niori-attachments-add 'visits id (car files)))
      (let ((names (mapcar (lambda (row) (plist-get row 'file_name))
                           (niori-attachments-list 'visits id))))
        (should (= 2 (length names)))
        (should (= 2 (length (delete-dups (copy-sequence names)))))
        (dolist (row (niori-attachments-list 'visits id))
          (should (file-exists-p (niori-attachments-file row))))))))

(ert-deftest niori-attachments-move-method-removes-original ()
  "The `move' import method relocates the file instead of copying it."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("scan.png" . "PNG"))
      (let* ((file (car files))
             (id (niori-test--visit))
             (niori-attachments-import-method 'move)
             (attachment (niori-attachments-add 'visits id file)))
        (should-not (file-exists-p file))
        (should (file-exists-p
                 (niori-attachments-file (niori-store-get 'attachments attachment))))
        (should (equal (plist-get (niori-store-get 'attachments attachment) 'kind)
                       "image"))))))

(ert-deftest niori-attachments-link-method-keeps-the-original ()
  "The `link' import method stores a relative path to a symlink."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("scan.png" . "PNG"))
      (let* ((file (car files))
             (id (niori-test--visit))
             (niori-attachments-import-method 'link)
             (attachment (niori-attachments-add 'visits id file))
             (row (niori-store-get 'attachments attachment))
             (stored (niori-attachments-file row)))
        ;; The stored path stays relative, so the tree can be moved,
        ;; while the original is untouched and still the only copy.
        (should (string-prefix-p (format "visits/%d/" id)
                                 (plist-get row 'file_name)))
        (should (file-symlink-p stored))
        (should (equal (file-truename stored) (file-truename file)))
        (should (file-exists-p file))))))

(ert-deftest niori-attachments-refuse-escaping-paths ()
  "Stored paths may not leave the documents directory."
  (niori-with-test-data-dir
    (dolist (sneaky '("../../etc/passwd" "/etc/passwd" "visits/../../x"))
      (let ((id (niori-store-insert 'attachments
                                    `((table_name . "visits")
                                      (record_id . 1)
                                      (title . "sneaky")
                                      (file_name . ,sneaky)))))
        (should-error (niori-attachments-file (niori-store-get 'attachments id))
                      :type 'user-error)))))

(ert-deftest niori-attachments-open-missing-file-signals ()
  "Opening an attachment whose file vanished explains what to do."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (row (niori-store-get 'attachments attachment)))
        (delete-file (niori-attachments-file row))
        (should-error (niori-attachments-open attachment) :type 'user-error)))))

(ert-deftest niori-attachments-rename-moves-the-file ()
  "Renaming retitles the attachment and renames its file in place."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (before (niori-attachments-file
                      (niori-store-get 'attachments attachment))))
        (niori-attachments-rename attachment "Blood panel")
        (let* ((row (niori-store-get 'attachments attachment))
               (after (niori-attachments-file row)))
          (should (equal (plist-get row 'title) "Blood panel"))
          (should (string-match-p "-blood-panel\\.pdf\\'" after))
          (should (file-exists-p after))
          (should-not (file-exists-p before))
          ;; Still in the record's folder.
          (should (equal (file-name-directory before)
                         (file-name-directory after))))))))

;;;; Detaching and orphans

(ert-deftest niori-attachments-detach-keeps-file-by-default ()
  "Detaching removes the link but not the file."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (stored (niori-attachments-file
                      (niori-store-get 'attachments attachment))))
        (niori-attachments-detach attachment)
        (should-not (niori-store-get 'attachments attachment))
        (should (file-exists-p stored))))))

(ert-deftest niori-attachments-detach-deletes-file-when-asked ()
  "Detaching with DELETE-FILE removes the stored copy."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (stored (niori-attachments-file
                      (niori-store-get 'attachments attachment))))
        (niori-attachments-detach attachment t)
        (should-not (file-exists-p stored))))))

(ert-deftest niori-attachments-shared-file-is-kept ()
  "A file another attachment points at is never deleted."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (row (niori-store-get 'attachments attachment))
             (stored (niori-attachments-file row)))
        ;; A second record links to the same physical file.
        (niori-store-insert 'attachments
                            `((table_name . "visits")
                              (record_id . ,id)
                              (title . "shared")
                              (file_name . ,(plist-get row 'file_name))))
        (niori-attachments-detach attachment t)
        (should (file-exists-p stored))))))

(ert-deftest niori-attachments-orphans-and-purge ()
  "Deleting a record leaves its attachments orphaned until purged."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files)))
             (stored (niori-attachments-file
                      (niori-store-get 'attachments attachment))))
        (niori-store-delete 'visits id)
        (should (= 1 (length (niori-attachments-orphans))))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (niori-attachments-purge-orphans))
        (should-not (niori-attachments-orphans))
        (should-not (niori-store-get 'attachments attachment))
        (should-not (file-exists-p stored))))))

;;;; Views

(ert-deftest niori-detail-shows-attachments ()
  "Every detail buffer gains an attachments section."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let ((id (niori-test--visit)))
        (niori-attachments-add 'visits id (car files))
        (with-current-buffer (niori-detail 'visits id)
          (should (string-match-p "Attachments (1)" (buffer-string)))
          (should (string-match-p "lab-report.pdf" (buffer-string))))))))

(ert-deftest niori-detail-vetoes-deleting-a-record-with-attachments ()
  "Deleting a record with attachments asks twice, and can be cancelled."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let ((id (niori-test--visit))
            (stored nil))
        (niori-attachments-add 'visits id (car files))
        (setq stored (niori-attachments-file
                      (car (niori-attachments-list 'visits id))))
        ;; Declining the generic confirmation deletes nothing.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (niori-view--delete 'visits id))
        (should (niori-store-get 'visits id))
        ;; Confirming the deletion but refusing the attachment warning cancels.
        (let ((answers '(t nil)))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (&rest _) (pop answers))))
            (should-error (niori-view--delete 'visits id) :type 'user-error)))
        (should (niori-store-get 'visits id))
        ;; Both prompts accepted: the record goes, the file stays.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (niori-view--delete 'visits id))
        (should-not (niori-store-get 'visits id))
        (should (file-exists-p stored))))))

(ert-deftest niori-documents-roster-renders ()
  "The documents buffer lists every attachment."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let ((id (niori-test--visit)))
        (niori-attachments-add 'visits id (car files))
        (with-current-buffer (niori-documents)
          (should (= 1 (length tabulated-list-entries)))
          (should (string-match-p "lab-report.pdf" (buffer-string)))
          (should (string-match-p "ok" (buffer-string))))))))

(ert-deftest niori-attachments-check-reports-missing-files ()
  "The integrity check names attachments whose file is gone."
  (niori-with-test-data-dir
    (niori-test--with-source-files '(("lab-report.pdf" . "PDF"))
      (let* ((id (niori-test--visit))
             (attachment (niori-attachments-add 'visits id (car files))))
        (delete-file (niori-attachments-file
                      (niori-store-get 'attachments attachment)))
        (with-current-buffer (niori-attachments-check)
          (should (string-match-p "Missing files (1)" (buffer-string)))
          (should (string-match-p "lab-report.pdf" (buffer-string))))))))

;;;; Opening with an external program

(ert-deftest niori-attachments-external-opener-per-platform ()
  "Each platform gets a sensible default opener command."
  (should (string-prefix-p "xdg-open "
                           (let ((system-type 'gnu/linux))
                             (niori-attachments--default-external-opener))))
  (should (string-prefix-p "open "
                           (let ((system-type 'darwin))
                             (niori-attachments--default-external-opener))))
  (should (string-prefix-p "start "
                           (let ((system-type 'windows-nt))
                             (niori-attachments--default-external-opener)))))

(provide 'test-niori-attachments)

;;; test-niori-attachments.el ends here
