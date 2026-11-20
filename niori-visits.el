;;; niori-visits.el --- Visit module for niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health
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

;; The visits module.  Besides the standard roster/form/detail views
;; it provides "letters": buffers pre-filled from a visit record that
;; you can edit as plain text, spell-check with flyspell (when a
;; spelling binary is installed) and expand through yasnippet
;; templates when that package is available (snippets ship in the
;; snippets/ directory of the repository).

;;; Code:

(require 'cl-lib)
(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

(declare-function niori-dashboard--record-button "niori-dashboard")

;; Optional integration point (yasnippet).
(defvar yas-snippet-dirs)

(defgroup niori-visits nil
  "The visits module of niori."
  :group 'niori)

(defcustom niori-visits-upcoming-days 30
  "Days ahead to look for upcoming visits on the dashboard."
  :type 'natnum
  :group 'niori-visits)

(defcustom niori-letter-flyspell 'auto
  "Control spell-checking in niori letter buffers.
`auto' enables flyspell when a spelling binary is found; t always
enables it (erroring when none is found); nil disables it."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'niori-visits)

;;;; Schema

(niori-store-register-schema
 'visits
 '(id date doctor facility reason diagnosis notes
      created_at updated_at)
 "CREATE TABLE visits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  doctor TEXT,
  facility TEXT,
  reason TEXT,
  diagnosis TEXT,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL)")

;;;; Queries

(defun niori-visits--upcoming (&optional days)
  "Visits within the next DAYS days (default 30), soonest first."
  (niori-store-select
   'visits
   :where "date >= ? AND date <= ?"
   :params (list (niori--today) (niori--date+ (or days 30)))
   :order "date, id"))

;;;; Module registration

(defun niori-visits--title (record)
  "Display title of a visit RECORD."
  (concat (or (plist-get record 'date) "?")
          (let ((doctor (plist-get record 'doctor)))
            (if (and doctor (not (string= doctor "")))
                (concat " — " doctor)
              ""))))

(defun niori-visits--dashboard ()
  "Insert the visits section of the dashboard."
  (let ((upcoming (niori-visits--upcoming niori-visits-upcoming-days)))
    (insert (format "Upcoming visits (next %d days): %d\n"
                    niori-visits-upcoming-days (length upcoming)))
    (dolist (record upcoming)
      (insert "  - ")
      (niori-dashboard--record-button 'visits record)
      (insert (or (plist-get record 'reason) "") "\n"))
    (unless upcoming
      (insert "  (no upcoming visits)\n"))))

(niori-register-module
 'visits
 :title "Visits"
 :table 'visits
 :columns '(("Date" 10 date t)
           ("Doctor" 18 doctor t)
           ("Facility" 16 facility nil)
           ("Reason" 26 reason nil))
 :fields '((date . (:label "Date" :type date :required t))
           (doctor . (:label "Doctor" :type string))
           (facility . (:label "Facility" :type string))
           (reason . (:label "Reason" :type text))
           (diagnosis . (:label "Diagnosis" :type text))
           (notes . (:label "Notes" :type text)))
 :order "date DESC, id DESC"
 :default-sort '("Date" . t)
 :title-fn #'niori-visits--title
 :dashboard-fn #'niori-visits--dashboard
 :letter-fn #'niori-visits-letter)

;;;; Commands

;;;###autoload
(defun niori-visits ()
  "Open the visits roster."
  (interactive)
  (niori-roster 'visits))

;;;###autoload
(defun niori-visits-add ()
  "Add a new visit."
  (interactive)
  (niori-form 'visits))

;;;###autoload
(defun niori-visits-letter (id)
  "Compose a letter based on visit ID in a text buffer.
Enables flyspell when possible and yasnippet when installed."
  (interactive (list (niori-view--read-record 'visits "Visit: ")))
  (let* ((record (niori-store-get 'visits id))
         (date (plist-get record 'date))
         (doctor (or (plist-get record 'doctor) ""))
         (buffer (get-buffer-create
                  (format "*niori letter %s*" (or date "draft")))))
    (with-current-buffer buffer
      (niori-letter-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format-time-string "%e %B %Y") "\n\n")
        (insert (format "Re: consultation of %s" (or date "")))
        (when (not (string= doctor ""))
          (insert (format " with %s" doctor)))
        (insert "\n\n")
        (let ((facility (plist-get record 'facility)))
          (when (and facility (not (string= facility "")))
            (insert facility "\n\n")))
        (insert "Reason:\n" (or (plist-get record 'reason) "") "\n\n")
        (insert "Diagnosis:\n" (or (plist-get record 'diagnosis) "")
                "\n\n")
        (insert "Notes:\n\n" (or (plist-get record 'notes) "") "\n")
        (goto-char (point-max))
        (niori-visits--maybe-flyspell)
        (when (fboundp 'yas-minor-mode)
          (niori-visits--setup-snippets)
          (yas-minor-mode 1)
          (message "yasnippet enabled — try the ‘nvisit’ template"))))
    (unless noninteractive (pop-to-buffer buffer))
    buffer))

(defun niori-visits--maybe-flyspell ()
  "Turn on flyspell according to `niori-letter-flyspell'."
  (pcase niori-letter-flyspell
    ('t (flyspell-mode 1))
    ('auto
     (when (cl-some (lambda (binary) (executable-find binary))
                    '("hunspell" "aspell" "ispell"))
       (flyspell-mode 1)))))

(defun niori-visits--setup-snippets ()
  "Point yasnippet at the snippets shipped with niori."
  (let ((directory (expand-file-name "snippets"
                                     (niori--package-root))))
    (when (file-directory-p directory)
      (add-to-list 'yas-snippet-dirs directory t))))

(define-derived-mode niori-letter-mode text-mode "niori-letter"
  "Major mode for letters composed from niori visit records.
A plain `text-mode' derivative so that flyspell, yasnippet and any
other text tooling works as usual.")

(niori-register-command 'visits-open #'niori-visits
                        :title "Open the visits roster")
(niori-register-command 'visits-add #'niori-visits-add
                        :title "Add a visit")
(niori-register-command 'visits-letter #'niori-visits-letter
                        :title "Compose a letter from a visit")

(provide 'niori-visits)

;;; niori-visits.el ends here
