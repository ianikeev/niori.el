;;; niori-view.el --- Roster, form and detail views for niori  -*- lexical-binding: t; -*-

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

;; Generic view layer shared by every niori module, in the spirit of
;; the original application's pluggable TopComponents:
;;
;;   * rosters  - `tabulated-list-mode' buffers listing the records
;;     of one module (sortable columns, single-key actions);
;;   * forms    - `widget' buffers for creating and editing records,
;;     generated from each module's field specification;
;;   * details  - read-only record buffers with buttons;
;;   * exports  - Org, CSV and (via niori-fhir.el) FHIR JSON;
;;   * revisions - `ediff' comparison of a record with its previous
;;     stored revision.
;;
;; Everything is parameterised by the module plist registered through
;; `niori-register-module'; no module ships its own buffer code.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'wid-edit)
(require 'button)
(require 'tabulated-list)
(require 'niori-platform)
(require 'niori-store)

;; Defined in files loaded after this one.
(declare-function niori-dashboard-refresh "niori-dashboard")
(declare-function niori-attachments-add "niori-attachments")
(declare-function niori-medications-add "niori-medications")
(declare-function niori-visits-add "niori-visits")
(declare-function niori-labs-add "niori-labs")
(declare-function niori-vaccinations-add "niori-vaccinations")
(declare-function niori-fhir-export "niori-fhir")

(defvar niori--module nil
  "Module symbol of the current niori buffer.
Always buffer-local in roster, form and detail buffers.")
(defvar niori--record-id nil
  "Record id of the current niori form or detail buffer.")

(defvar niori-detail-sections-hook nil
  "Hook run at the end of `niori-detail--render'.
Each function is called with no arguments, in the detail buffer, so
`niori--module' and `niori--record-id' describe what is on screen.
Optional features use this to contribute a block to *every*
module's detail view — the attachments section of
niori-attachments.el is such a contributor — without any module
file having to know that the feature exists.")

(defvar niori-record-before-delete-hook nil
  "Hook run before a record is deleted, to allow a veto.
Each function receives the module symbol and the record id; a
non-nil return value cancels the deletion.  niori-attachments.el
uses it to warn that attached files will be kept.")

(defun niori-view--module-title (module)
  "Human readable title of MODULE."
  (or (niori-module-get module :title) (symbol-name module)))

;;;; Field helpers

(defun niori-view--fields (module)
  "Field specifications of MODULE: ((FIELD . PROPS)...)."
  (niori-module-get module :fields))

(defun niori-view--field-spec (module field)
  "PROPS of FIELD in MODULE."
  (cdr (assq field (niori-view--fields module))))

(defun niori-view--field-type (module field)
  "Type symbol of FIELD in MODULE."
  (plist-get (niori-view--field-spec module field) :type))

(defun niori-view--field-text (module record field)
  "Render FIELD of RECORD as display text."
  (let ((value (plist-get record field)))
    (cond ((eq (niori-view--field-type module field) 'bool)
           (if (and value (not (equal value 0))) "yes" "no"))
          ((numberp value) (number-to-string value))
          ((null value) "")
          (t (format "%s" value)))))

(defun niori-view--record-title (module record)
  "Short display title of RECORD in MODULE."
  (let ((fn (niori-module-get module :title-fn)))
    (if fn
        (funcall fn record)
      (format "#%s" (plist-get record 'id)))))

(defun niori-view--read-record (module prompt)
  "Read a record of MODULE with completion; return its id."
  (let* ((records (niori-store-select
                   module :order (or (niori-module-get module :order) "id")))
         (alist (mapcar (lambda (record)
                          (cons (niori-view--record-title module record)
                                (plist-get record 'id)))
                        records)))
    (unless records
      (user-error "No records in %s yet" (niori-view--module-title module)))
    (cdr (assoc (completing-read prompt (mapcar #'car alist) nil t)
                alist))))

;;;; Roster mode

(defvar-keymap niori-export-map
  :doc "Export keymap used in niori buffers."
  "o" #'niori-export-org
  "c" #'niori-export-csv
  "j" #'niori-fhir-export)

(defvar-keymap niori-add-map
  :doc "Keymap for creating new niori records."
  "m" #'niori-medications-add
  "v" #'niori-visits-add
  "t" #'niori-labs-add
  "c" #'niori-vaccinations-add)

(defvar-keymap niori-roster-mode-map
  :parent tabulated-list-mode-map
  :doc "Keymap for niori roster buffers."
  "RET" #'niori-roster-open
  "a" #'niori-roster-add
  "e" #'niori-roster-edit
  "d" #'niori-roster-delete
  "D" #'niori-roster-ediff
  "L" #'niori-roster-letter
  "E" 'niori-export-map)

(define-derived-mode niori-roster-mode tabulated-list-mode "niori-roster"
  "Major mode for niori record lists.
\\<niori-roster-mode-map>\\[niori-roster-open] opens the record at point,
\\[niori-roster-add] creates a record, \\[niori-roster-delete] deletes one,
and \\[niori-export-org] and friends export the whole list."
  (setq-local niori--module nil)
  (setq-local revert-buffer-function #'niori-roster--revert))

(defun niori-roster--revert (&rest _)
  "Refresh the roster buffer."
  (niori-roster--refresh))

(defun niori-roster (module)
  "Open the roster buffer for MODULE."
  (interactive (list (niori--read-module)))
  (niori-store-open)
  (let ((buffer (get-buffer-create
                 (format "*niori %s*"
                         (downcase (niori-view--module-title module))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'niori-roster-mode)
        (niori-roster-mode))
      (setq-local niori--module module)
      (niori-roster--refresh))
    (unless noninteractive (pop-to-buffer buffer))
    buffer))

(defun niori-roster--refresh ()
  "Repopulate the current roster buffer."
  (let ((module niori--module))
    (setq tabulated-list-format (niori-view--tabulated-format module))
    (setq tabulated-list-sort-key (niori-module-get module :default-sort))
    (tabulated-list-init-header)
    (setq tabulated-list-entries (niori-view--entries module))
    (tabulated-list-print)
    (unless tabulated-list-entries
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n  No records yet — press ‘a’ to add the first one.\n")))
    (goto-char (point-min))))

(defun niori-view--tabulated-format (module)
  "Build the `tabulated-list-format' vector for MODULE.
Each column is a list (LABEL WIDTH SORT) as `tabulated-list-mode'
expects (the vector contains lists, not vectors)."
  (vconcat
   (mapcar (lambda (column)
             (list (nth 0 column) (nth 1 column) (nth 3 column)))
           (niori-module-get module :columns))))

(defun niori-view--entries (module)
  "Build `tabulated-list-entries' for MODULE."
  (mapcar (lambda (record)
            (list (plist-get record 'id)
                  (vconcat
                   (mapcar (lambda (column)
                             (niori-view--field-text
                              module record (nth 2 column)))
                           (niori-module-get module :columns)))))
          (niori-store-select
           module :order (or (niori-module-get module :order) "id"))))

(defun niori-roster--id-at-point ()
  "Id of the record at point, or nil."
  (tabulated-list-get-id))

(defun niori-roster-open ()
  "Open the record at point in a detail buffer."
  (interactive)
  (let ((id (niori-roster--id-at-point)))
    (if id
        (niori-detail niori--module id)
      (user-error "No record on this line"))))

(defun niori-roster-add ()
  "Create a new record for the module of this roster."
  (interactive)
  (niori-form niori--module))

(defun niori-roster-edit ()
  "Edit the record at point."
  (interactive)
  (let ((id (niori-roster--id-at-point)))
    (if id
        (niori-form niori--module id)
      (user-error "No record on this line"))))

(defun niori-roster-delete ()
  "Delete the record at point after confirmation."
  (interactive)
  (let ((id (niori-roster--id-at-point)))
    (unless id (user-error "No record on this line"))
    (niori-view--delete niori--module id)))

(defun niori-roster-ediff ()
  "Compare the record at point with its previous revision."
  (interactive)
  (let ((id (niori-roster--id-at-point)))
    (unless id (user-error "No record on this line"))
    (niori-record-ediff niori--module id)))

(defun niori-roster-letter ()
  "Render a letter for the record at point, if the module supports it."
  (interactive)
  (let* ((fn (niori-module-get niori--module :letter-fn))
         (id (niori-roster--id-at-point)))
    (unless fn
      (user-error "No letter template for %s"
                  (niori-view--module-title niori--module)))
    (unless id (user-error "No record on this line"))
    (funcall fn id)))

(defun niori-view--delete (module id)
  "Delete record ID of MODULE after confirmation.
`niori-record-before-delete-hook' runs after the generic confirmation,
so a feature that owns side data (attachments) gets the last word."
  (let* ((record (niori-store-get module id))
         (title (niori-view--record-title module record)))
    (when (y-or-n-p (format "Delete %s? " title))
      (when (run-hook-with-args-until-success
             'niori-record-before-delete-hook module id)
        (user-error "Deletion cancelled"))
      (niori-store-delete module id)
      (niori-view--refresh-module module)
      (message "Deleted %s" title))))

(defun niori-view-refresh-all (&optional module)
  "Refresh open niori buffers, only those of MODULE when non-nil.
The dashboard is always refreshed.  Roster and detail buffers of
MODULE are re-rendered from the database; detail buffers whose
record disappeared are killed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p niori--module)
                 (local-variable-p 'niori--module)
                 niori--module
                 (or (null module) (eq niori--module module)))
        (cond ((derived-mode-p 'niori-roster-mode)
               (niori-roster--refresh))
              ((derived-mode-p 'niori-detail-mode)
               (if (niori-store-get niori--module niori--record-id)
                   (niori-detail--render)
                 (kill-buffer)))))))
  (niori-dashboard-refresh))

(defun niori-view--refresh-module (module)
  "Refresh every open niori buffer related to MODULE."
  (niori-view-refresh-all module))

;;;; Detail mode

(defvar-keymap niori-detail-mode-map
  :parent special-mode-map
  :doc "Keymap for niori detail buffers."
  "e" #'niori-detail-edit
  "d" #'niori-detail-delete
  "D" #'niori-detail-ediff
  "L" #'niori-detail-letter
  "A" #'niori-attachments-add
  "E" 'niori-export-map)

(define-derived-mode niori-detail-mode special-mode "niori-detail"
  "Major mode for a single niori record."
  (setq-local niori--module nil)
  (setq-local niori--record-id nil))

(defun niori-detail (module id)
  "Open a detail buffer for record ID of MODULE."
  (niori-store-open)
  (let ((record (niori-store-get module id)))
    (unless record
      (user-error "No %s record with id %s" module id))
    (let ((buffer (get-buffer-create
                   (format "*niori %s #%s*"
                           (downcase (niori-view--module-title module)) id))))
      (with-current-buffer buffer
        (niori-detail-mode)
        (setq-local niori--module module)
        (setq-local niori--record-id id)
        (niori-detail--render))
      (unless noninteractive (pop-to-buffer buffer))
      buffer)))

(defun niori-detail--render ()
  "Draw the current detail buffer."
  (let ((inhibit-read-only t)
        (module niori--module)
        (id niori--record-id)
        (record (niori-store-get niori--module niori--record-id)))
    (erase-buffer)
    (insert (propertize
             (concat (niori-view--module-title module) ": "
                     (niori-view--record-title module record))
             'face 'bold)
            "\n\n")
    (dolist (field (niori-view--fields module))
      (let* ((props (cdr field))
             (label (plist-get props :label))
             (text (niori-view--field-text module record (car field))))
        (insert (propertize (format "%-14s " label) 'face 'shadow)
                (if (equal text "") "—" text)
                "\n")))
    (insert "\n")
    (run-hooks 'niori-detail-sections-hook)
    (niori-detail--button "Edit" (lambda (&rest _) (niori-form module id)))
    (insert "  ")
    (niori-detail--button "Delete" (lambda (&rest _)
                                     (niori-view--delete module id)))
    (insert "  ")
    (niori-detail--button "Diff revision" (lambda (&rest _)
                                            (niori-record-ediff module id)))
    (insert "  ")
    (niori-detail--button "Export Org" (lambda (&rest _)
                                         (niori-export-org module)))
    (when (niori-module-get module :letter-fn)
      (insert "  ")
      (niori-detail--button "Letter" (lambda (&rest _)
                                       (funcall
                                        (niori-module-get module :letter-fn)
                                        id))))
    (insert "\n")
    (goto-char (point-min))))

(defun niori-detail--button (label action)
  "Insert a button labelled LABEL running ACTION."
  (insert-button label
                 :follow-link t
                 :action action
                 'help-echo (format "Mouse-1 or RET: %s"
                                    (downcase label))))

(defun niori-detail--section-title (title)
  "Insert TITLE as the heading of a detail section."
  (insert (propertize (concat title "\n") 'face 'bold)))

(defun niori-detail-edit ()
  "Edit the record of the current detail buffer."
  (interactive)
  (niori-form niori--module niori--record-id))

(defun niori-detail-delete ()
  "Delete the record of the current detail buffer."
  (interactive)
  (niori-view--delete niori--module niori--record-id))

(defun niori-detail-ediff ()
  "Diff the record of the current detail buffer against its revision."
  (interactive)
  (niori-record-ediff niori--module niori--record-id))

(defun niori-detail-letter ()
  "Render a letter for the record of the current detail buffer."
  (interactive)
  (let ((fn (niori-module-get niori--module :letter-fn)))
    (unless fn
      (user-error "No letter template for %s"
                  (niori-view--module-title niori--module)))
    (funcall fn niori--record-id)))

;;;; Widget forms

(defvar-keymap niori-form-mode-map
  :parent special-mode-map
  :doc "Keymap for niori form buffers."
  "C-c C-c" #'niori-form-save
  "C-c C-k" #'niori-form-cancel)

(define-derived-mode niori-form-mode special-mode "niori-form"
  "Major mode for niori widget forms.
\\<niori-form-mode-map>Save with \\[niori-form-save] and cancel with \
\\[niori-form-cancel]."
  (setq-local niori--module nil)
  (setq-local niori--record-id nil)
  (setq buffer-read-only nil))

(defvar-local niori--widgets nil
  "Alist (FIELD . WIDGET) of the widgets of the current form buffer.")

(defun niori-form (module &optional id)
  "Open a form buffer to create (or edit, given ID) a record of MODULE."
  (interactive (list (niori--read-module)))
  (niori-store-open)
  (let ((buffer (get-buffer-create
                 (format "*niori %s%s*"
                         (downcase (niori-view--module-title module))
                         (if id (format " #%s" id) "")))))
    (with-current-buffer buffer
      (niori-form-mode)
      (setq-local niori--module module)
      (setq-local niori--record-id id)
      (niori-view--render-form))
    (unless noninteractive (pop-to-buffer buffer))
    buffer))

(defun niori-view--render-form ()
  "Draw the current form buffer."
  (let ((inhibit-read-only t)
        (module niori--module)
        (id niori--record-id)
        (record (when niori--record-id
                  (niori-store-get niori--module niori--record-id))))
    (erase-buffer)
    (setq niori--widgets nil)
    (insert (propertize
             (format "%s %s"
                     (if id "Edit" "New")
                     (niori-view--module-title module))
             'face 'bold)
            "\n\n")
    (dolist (spec (niori-view--fields module))
      (niori-view--render-field spec (plist-get record (car spec))))
    (insert "\n")
    (widget-create 'push-button
                   :notify (lambda (&rest _) (niori-form-save))
                   "Save")
    (insert "  ")
    (widget-create 'push-button
                   :notify (lambda (&rest _) (niori-form-cancel))
                   "Cancel")
    (insert "\n")
    (widget-setup)
    (goto-char (point-min))
    (widget-forward 1)))

(defun niori-view--render-field (spec initial)
  "Render one form field described by SPEC with INITIAL value."
  (let* ((field (car spec))
         (props (cdr spec))
         (label (plist-get props :label))
         (type (plist-get props :type))
         (required (plist-get props :required))
         (tag (if (eq type 'date)
                  (format "%s (YYYY-MM-DD)" label)
                (if required (format "%s *" label) label)))
         (widget
          (pcase type
            ('bool
             (widget-create 'checkbox
                            :format "%{%t%}: %v\n" :tag label
                            :value (and initial (not (equal initial 0)))))
            ('choice
             (let ((options (plist-get props :options)))
               (apply #'widget-create 'menu-choice
                      :tag label
                      :format "%{%t%}: %v\n"
                      :value (if (member initial options) initial (car options))
                      (mapcar (lambda (option) `(item :value ,option))
                              options))))
            ('text
             (widget-create 'text
                            :format "%{%t%}: %v\n" :tag tag
                            :value (if initial (format "%s" initial) "")))
            (_
             (widget-create 'editable-field
                            :format "%{%t%}: %v\n" :tag tag
                            :value (if initial (format "%s" initial) ""))))))
    (setq niori--widgets (append niori--widgets (list (cons field widget))))))

(defun niori-form-save ()
  "Validate the current form and store the record."
  (interactive)
  (let* ((module niori--module)
         (id niori--record-id)
         (values (niori-view--form-values module))
         (errors (niori-view--validate-values module values)))
    (if errors
        (user-error "Invalid input: %s" (mapconcat #'identity errors "; "))
      (if id
          (niori-store-update module id values)
        (niori-store-insert module values))
      (kill-buffer)
      (niori-view--refresh-module module)
      (message (if id "niori: record updated" "niori: record created")))))

(defun niori-form-cancel ()
  "Close the current form without saving."
  (interactive)
  (kill-buffer))

(defun niori-view--form-values (module)
  "Collect the form values of MODULE as an alist."
  (mapcar (lambda (spec)
            (let* ((field (car spec))
                   (type (plist-get (cdr spec) :type))
                   (value (widget-value (cdr (assq field niori--widgets)))))
              (cons field
                    (pcase type
                      ('bool (if value 1 0))
                      ('number (if (equal value "") nil
                                 (string-to-number value)))
                      (_ (if (equal value "") nil value))))))
          (niori-view--fields module)))

(defun niori-view--validate-values (module values)
  "Return a list of error messages for the form VALUES of MODULE."
  (cl-loop for spec in (niori-view--fields module)
           for field = (car spec)
           for props = (cdr spec)
           for value = (cdr (assq field values))
           append (let ((label (plist-get props :label)))
                    (cond ((and (plist-get props :required) (null value))
                           (list (format "%s is required" label)))
                          ((and (eq (plist-get props :type) 'date) value
                                (not (niori--valid-date-p value)))
                           (list (format "%s must be a YYYY-MM-DD date"
                                         label)))))))

(defun niori--valid-date-p (string)
  "Return non-nil when STRING is a valid calendar date YYYY-MM-DD."
  (and (stringp string)
       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" string)
       (let* ((year (string-to-number (substring string 0 4)))
              (month (string-to-number (substring string 5 7)))
              (day (string-to-number (substring string 8 10)))
              (time (ignore-errors (encode-time 0 0 0 day month year))))
         (and time
              (equal (format-time-string "%Y-%m-%d" time) string)
              (<= 1900 year 2200)))))

;;;; Revision diffing with ediff

(defun niori-record-ediff (module id)
  "Ediff record ID of MODULE against its previous stored revision."
  (interactive
   (let ((module (niori--read-module)))
     (list module (niori-view--read-record module "Record: "))))
  (let ((revisions (niori-store-record-revisions module id)))
    (unless revisions
      (user-error "No stored revisions for this record yet"))
    (let* ((current (niori-store-get module id))
           (old (niori--json-pretty (plist-get (car revisions) 'snapshot)))
           (new (niori--json-pretty (json-encode current)))
           (old-buffer (get-buffer-create "*niori revision (previous)*"))
           (new-buffer (get-buffer-create "*niori record (current)*")))
      (with-current-buffer old-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert old))
        (special-mode))
      (with-current-buffer new-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert new))
        (special-mode))
      (ediff-buffers old-buffer new-buffer))))

;;;; Exports

(defun niori-export-csv (module &optional file)
  "Export every record of MODULE to FILE as CSV.
When `csv-mode' is installed the result opens in a CSV-aware buffer."
  (interactive
   (let ((module (niori--read-module)))
     (list module
           (read-file-name "Export CSV to: " nil nil nil
                           (format "%s.csv" module)))))
  (let* ((records (niori-store-select
                   module :order (or (niori-module-get module :order) "id")))
         (file (or file (niori--export-file module "csv")))
         (content (niori-view--csv module records)))
    (write-region content nil file)
    (niori-store--secure-file file)
    (message "niori: exported %d records to %s" (length records) file)
    (unless noninteractive (find-file file))
    file))

(defun niori-view--csv-escape (text)
  "Escape TEXT for CSV."
  (if (and text (string-match-p "[\",\n\r]" text))
      (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" text))
    (or text "")))

(defun niori-view--csv (module records)
  "Render RECORDS of MODULE as CSV text."
  (let ((fields (mapcar #'car (niori-view--fields module)))
        (labels (mapcar (lambda (spec) (plist-get (cdr spec) :label))
                        (niori-view--fields module))))
    (with-temp-buffer
      (insert (mapconcat #'niori-view--csv-escape labels ",") "\n")
      (dolist (record records)
        (insert (mapconcat (lambda (field)
                             (niori-view--csv-escape
                              (niori-view--field-text module record field)))
                           fields ",")
                "\n"))
      (buffer-string))))

(defun niori-export-org (module &optional file encrypt)
  "Export every record of MODULE to FILE as an Org table.
With non-nil ENCRYPT (prefix argument) encrypt the file with GPG
for the recipients configured in `niori-encryption-recipients'."
  (interactive
   (let ((module (niori--read-module)))
     (list module
           (read-file-name "Export Org to: " nil nil nil
                           (format "%s.org" module))
           current-prefix-arg)))
  (let* ((records (niori-store-select
                   module :order (or (niori-module-get module :order) "id")))
         (file (or file (niori--export-file module "org")))
         (content (niori-view--org module records)))
    (write-region content nil file)
    (niori-store--secure-file file)
    (cond
     (encrypt
      (if (and (executable-find "gpg") niori-encryption-recipients)
          (progn
            (epa-encrypt-file file niori-encryption-recipients)
            (message "niori: encrypted export written to %s" file))
        (user-error
         "Encryption requires GnuPG and `niori-encryption-recipients'")))
     (t
      (message "niori: exported %d records to %s" (length records) file)
      (unless noninteractive (find-file file))))
    file))

(defcustom niori-encryption-recipients nil
  "GPG key recipients used when exporting encrypted files.
Each element is a string naming a public key, as accepted by
`epa-encrypt-file'."
  :type '(repeat string)
  :group 'niori)

(defun niori-view--org (module records)
  "Render RECORDS of MODULE as an Org document."
  (let* ((specs (niori-view--fields module))
         (labels (mapcar (lambda (spec) (plist-get (cdr spec) :label)) specs))
         (rows (mapcar (lambda (record)
                         (mapcar (lambda (spec)
                                   (niori-view--field-text
                                    module record (car spec)))
                                 specs))
                       records))
         (all-rows (cons labels rows))
         (widths (mapcar (lambda (column)
                           (apply #'max 1
                                  (mapcar (lambda (row) (length (nth column row)))
                                          all-rows)))
                         (number-sequence 0 (1- (length labels))))))
    (with-temp-buffer
      (insert (format "#+title: niori — %s\n"
                      (niori-view--module-title module))
              (format "#+date: %s\n\n" (niori--today)))
      (let ((first t))
        (dolist (row all-rows)
          (insert "|")
          (cl-loop for cell in row
                   for index from 0
                   do (insert (format " %s |"
                                      (niori-view--org-pad
                                       cell (nth index widths)))))
          (insert "\n")
          (when first
            (insert "|"
                    (mapconcat (lambda (width)
                                 (make-string (+ width 2) ?-))
                               widths "|")
                    "|\n")
            (setq first nil))))
      (buffer-string))))

(defun niori-view--org-pad (text width)
  "Pad TEXT with spaces to WIDTH."
  (format (format "%%-%ds" width) (or text "")))

;; Re-render whatever is open when the data directory changes.
(add-hook 'niori-store-switch-hook #'niori-view-refresh-all)

(provide 'niori-view)

;;; niori-view.el ends here
