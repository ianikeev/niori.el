;;; niori-medications.el --- Medication module for niori  -*- lexical-binding: t; -*-

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

;; The medications module: table schema, roster/form specification and
;; the dashboard section.  Buffer behaviour comes from the generic
;; layer in niori-view.el.

;;; Code:

(require 'seq)
(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

(declare-function niori-dashboard--record-button "niori-dashboard")

;;;; Schema

(niori-store-register-schema
 'medications
 '(id name dosage form instructions prescriber start_date end_date
      active notes created_at updated_at)
 "CREATE TABLE medications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  dosage TEXT,
  form TEXT,
  instructions TEXT,
  prescriber TEXT,
  start_date TEXT,
  end_date TEXT,
  active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL)")

;;;; Module registration

(defun niori-medications--title (record)
  "Display title of a medication RECORD."
  (let ((dosage (plist-get record 'dosage)))
    (concat (or (plist-get record 'name) "?")
            (if (and dosage (not (string= dosage "")))
                (concat " " dosage)
              ""))))

(defun niori-medications--dashboard ()
  "Insert the medications section of the dashboard."
  (let ((active (niori-store-select 'medications
                                    :where "active = 1"
                                    :order "name")))
    (insert (format "Active: %d of %d\n"
                    (length active)
                    (niori-store-count 'medications)))
    (dolist (record (seq-take active 5))
      (insert "  - ")
      (niori-dashboard--record-button 'medications record)
      (insert "\n"))
    (when (> (length active) 5)
      (insert (format "  … and %d more\n" (- (length active) 5))))))

(niori-register-module
 'medications
 :title "Medications"
 :table 'medications
 :columns '(("Name" 22 name t)
           ("Dosage" 12 dosage nil)
           ("Form" 10 form t)
           ("Active" 7 active t)
           ("Start" 10 start_date t)
           ("End" 10 end_date nil)
           ("Prescriber" 16 prescriber nil))
 :fields '((name . (:label "Name" :type string :required t))
           (dosage . (:label "Dosage" :type string))
           (form . (:label "Form" :type choice
                           :options ("tablet" "capsule" "liquid"
                                     "injection" "topical" "inhaler"
                                     "other")))
           (active . (:label "Active" :type bool))
           (start_date . (:label "Start date" :type date))
           (end_date . (:label "End date" :type date))
           (prescriber . (:label "Prescriber" :type string))
           (instructions . (:label "Instructions" :type text))
           (notes . (:label "Notes" :type text)))
 :order "name"
 :title-fn #'niori-medications--title
 :dashboard-fn #'niori-medications--dashboard)

;;;; Commands

;;;###autoload
(defun niori-medications ()
  "Open the medications roster."
  (interactive)
  (niori-roster 'medications))

;;;###autoload
(defun niori-medications-add ()
  "Add a new medication."
  (interactive)
  (niori-form 'medications))

(niori-register-command 'medications-open #'niori-medications
                        :title "Open the medications roster")
(niori-register-command 'medications-add #'niori-medications-add
                        :title "Add a medication")

(provide 'niori-medications)

;;; niori-medications.el ends here
