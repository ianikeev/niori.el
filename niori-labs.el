;;; niori-labs.el --- Lab test module for niori  -*- lexical-binding: t; -*-

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

;; The lab test module.  The dashboard section highlights the most
;; recent result of every test whose flag is abnormal (high, low or
;; critical) so that results needing attention surface by themselves.

;;; Code:

(require 'cl-lib)
(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

(declare-function niori-dashboard--record-button "niori-dashboard")

;;;; Schema

(niori-store-register-schema
 'labs
 '(id date name category result unit reference_range flag notes
      created_at updated_at)
 "CREATE TABLE labs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  name TEXT NOT NULL,
  category TEXT,
  result TEXT,
  unit TEXT,
  reference_range TEXT,
  flag TEXT,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL)")

;;;; Queries

(defun niori-labs--latest-by-name ()
  "Most recent test record per test name, newest first."
  (let ((seen nil)
        (latest nil))
    (dolist (record (niori-store-select 'labs
                                        :order "date DESC, id DESC"))
      (let ((name (plist-get record 'name)))
        (unless (member name seen)
          (push name seen)
          (push record latest))))
    latest))

(defun niori-labs--flagged-latest ()
  "Latest result of each test whose latest flag is abnormal."
  (cl-loop for record in (niori-labs--latest-by-name)
           when (member (plist-get record 'flag)
                        '("high" "low" "critical"))
           collect record))

;;;; Module registration

(defun niori-labs--title (record)
  "Display title of a test RECORD."
  (let ((flag (plist-get record 'flag)))
    (concat (or (plist-get record 'date) "?")
            " "
            (or (plist-get record 'name) "?")
            (if (and flag (not (member flag '(nil "normal" "pending"))))
                (format " (%s)" flag)
              ""))))

(defun niori-labs--dashboard ()
  "Insert the lab tests section of the dashboard."
  (let ((flagged (niori-labs--flagged-latest))
        (total (niori-store-count 'labs)))
    (insert (format "Records: %d — needing attention: %d\n"
                    total (length flagged)))
    (dolist (record flagged)
      (insert "  - ")
      (niori-dashboard--record-button 'labs record)
      (insert (format " %s %s\n"
                      (or (plist-get record 'result) "")
                      (or (plist-get record 'unit) ""))))
    (when (zerop total)
      (insert "  (no test records yet)\n"))
    (when (and (not (zerop total)) (null flagged))
      (insert "  (latest results all within reference)\n"))))

(niori-register-module
 'labs
 :title "Lab tests"
 :table 'labs
 :columns '(("Date" 10 date t)
           ("Name" 22 name t)
           ("Result" 12 result nil)
           ("Unit" 7 unit nil)
           ("Flag" 9 flag t)
           ("Reference" 14 reference_range nil)
           ("Category" 12 category nil))
 :fields '((date . (:label "Date" :type date :required t))
           (name . (:label "Test name" :type string :required t))
           (category . (:label "Category" :type string))
           (result . (:label "Result" :type string))
           (unit . (:label "Unit" :type string))
           (reference_range . (:label "Reference range" :type string))
           (flag . (:label "Flag" :type choice
                           :options ("normal" "high" "low" "critical"
                                     "pending")))
           (notes . (:label "Notes" :type text)))
 :order "date DESC, id DESC"
 :default-sort '("Date" . t)
 :title-fn #'niori-labs--title
 :dashboard-fn #'niori-labs--dashboard)

;;;; Commands

;;;###autoload
(defun niori-labs ()
  "Open the lab tests roster."
  (interactive)
  (niori-roster 'labs))

;;;###autoload
(defun niori-labs-add ()
  "Add a new lab test result."
  (interactive)
  (niori-form 'labs))

(niori-register-command 'labs-open #'niori-labs
                        :title "Open the lab tests roster")
(niori-register-command 'labs-add #'niori-labs-add
                        :title "Add a lab test result")

(provide 'niori-labs)

;;; niori-labs.el ends here
