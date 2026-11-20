;;; niori-vaccinations.el --- Vaccination module for niori  -*- lexical-binding: t; -*-

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

;; The vaccinations module.  Each record can carry a next-due date;
;; the dashboard section lists boosters that are overdue or due
;; within a configurable window.

;;; Code:

(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

(declare-function niori-dashboard--record-button "niori-dashboard")

(defgroup niori-vaccinations nil
  "The vaccinations module of niori."
  :group 'niori)

(defcustom niori-vaccinations-due-days 90
  "Days ahead to look for due boosters on the dashboard."
  :type 'natnum
  :group 'niori-vaccinations)

;;;; Schema

(niori-store-register-schema
 'vaccinations
 '(id date vaccine dose_number route site lot provider next_due_date
      notes created_at updated_at)
 "CREATE TABLE vaccinations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  vaccine TEXT NOT NULL,
  dose_number INTEGER,
  route TEXT,
  site TEXT,
  lot TEXT,
  provider TEXT,
  next_due_date TEXT,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL)")

;;;; Queries

(defun niori-vaccinations--due (&optional days)
  "Vaccinations with a next-due date within DAYS days (default 90),
overdue ones first."
  (niori-store-select
   'vaccinations
   :where "next_due_date IS NOT NULL AND next_due_date <= ?"
   :params (list (niori--date+ (or days niori-vaccinations-due-days)))
   :order "next_due_date"))

(defun niori-vaccinations--overdue-p (record)
  "Non-nil when RECORD's next-due date is in the past."
  (let ((due (plist-get record 'next_due_date)))
    (and due (string< due (niori--today)))))

;;;; Module registration

(defun niori-vaccinations--title (record)
  "Display title of a vaccination RECORD."
  (concat (or (plist-get record 'date) "?")
          " "
          (or (plist-get record 'vaccine) "?")))

(defun niori-vaccinations--dashboard ()
  "Insert the vaccinations section of the dashboard."
  (let ((due (niori-vaccinations--due niori-vaccinations-due-days)))
    (insert (format "Boosters due within %d days: %d\n"
                    niori-vaccinations-due-days (length due)))
    (dolist (record due)
      (insert "  - ")
      (niori-dashboard--record-button 'vaccinations record)
      (insert (format "due %s%s\n"
                      (or (plist-get record 'next_due_date) "")
                      (if (niori-vaccinations--overdue-p record)
                          " (overdue!)"
                        ""))))
    (unless due
      (insert "  (nothing due)\n"))))

(niori-register-module
 'vaccinations
 :title "Vaccinations"
 :table 'vaccinations
 :columns '(("Date" 10 date t)
           ("Vaccine" 20 vaccine t)
           ("Dose" 5 dose_number nil)
           ("Route" 13 route nil)
           ("Next due" 10 next_due_date t))
 :fields '((date . (:label "Date" :type date :required t))
           (vaccine . (:label "Vaccine" :type string :required t))
           (dose_number . (:label "Dose number" :type number))
           (route . (:label "Route" :type choice
                            :options ("intramuscular" "subcutaneous"
                                      "oral" "intranasal" "other")))
           (site . (:label "Site" :type string))
           (lot . (:label "Lot" :type string))
           (provider . (:label "Provider" :type string))
           (next_due_date . (:label "Next due date" :type date))
           (notes . (:label "Notes" :type text)))
 :order "date DESC, id DESC"
 :default-sort '("Date" . t)
 :title-fn #'niori-vaccinations--title
 :dashboard-fn #'niori-vaccinations--dashboard)

;;;; Commands

;;;###autoload
(defun niori-vaccinations ()
  "Open the vaccinations roster."
  (interactive)
  (niori-roster 'vaccinations))

;;;###autoload
(defun niori-vaccinations-add ()
  "Add a new vaccination record."
  (interactive)
  (niori-form 'vaccinations))

(niori-register-command 'vaccinations-open #'niori-vaccinations
                        :title "Open the vaccinations roster")
(niori-register-command 'vaccinations-add #'niori-vaccinations-add
                        :title "Add a vaccination record")

(provide 'niori-vaccinations)

;;; niori-vaccinations.el ends here
