;;; niori-platform.el --- Module system, services and commands for niori  -*- lexical-binding: t; -*-

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

;; niori.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with niori.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library is the platform core of niori.el.  The original
;; niori was modelled on the NetBeans Platform: applications are
;; assembled from modules that plug into a registry, obtain services
;; through a lookup mechanism and expose user-facing commands.
;;
;; niori.el keeps that architecture but maps it onto Emacs
;; conventions:
;;
;;   NetBeans module system  -> `niori-register-module'
;;   Lookup / ServiceRegistry -> `niori-register-service' / `niori-lookup'
;;   Action / Command system -> `niori-register-command'
;;   TopComponent            -> roster, form and detail buffers
;;                              (see niori-view.el)
;;
;; See ARCHITECTURE.md in the repository for the full mapping.

;;; Code:

(defgroup niori nil
  "Personal medical information manager.
An Emacs port of the niori Common Lisp/CLOG application."
  :group 'applications
  :link '(url-link "https://github.com/ianikeev/niori.el"))

(defvar niori--modules nil
  "Alist of registered modules: (NAME . PROPS).
PROPS is a plist; see `niori-register-module'.")

(defun niori-register-module (name &rest props)
  "Register (or replace) the module NAME with PROPS.
PROPS is a property list understood by the generic view layer:
  :title          human readable title (also used for buffers)
  :table          SQL table name (a symbol, same as NAME by convention)
  :columns        roster columns: (LABEL WIDTH FIELD SORTABLE)...
  :fields         form/detail fields: (FIELD . (:label ... :type ...))...
  :order          default ORDER BY clause for roster queries
  :default-sort   default `tabulated-list-sort-key'
  :dashboard-fn   function inserting a dashboard section for the module
  :title-fn       function returning a display title for one record
  :letter-fn      function rendering a letter for one record, if any
Registering a module twice replaces the previous definition in
place, keeping the original registration order."
  (niori-platform--set-alist-entry 'niori--modules name props)
  name)

(defun niori-modules ()
  "Names of the registered modules, in registration order."
  (mapcar #'car niori--modules))

(defun niori-platform--set-alist-entry (variable key value)
  "Set KEY to VALUE in the alist stored in VARIABLE, in place.
New entries are appended at the end so registration order is
preserved; replacing an existing key keeps its position."
  (let* ((alist (symbol-value variable))
         (existing (assq key alist)))
    (if existing
        (setcdr existing value)
      (set variable (append alist (list (cons key value)))))))

(defun niori-module-get (module prop)
  "Return PROP of MODULE, or nil if unknown."
  (plist-get (alist-get module niori--modules) prop))

;;;; Services (the NetBeans "Lookup")

(defvar niori--services nil
  "Alist of registered services: (SERVICE-NAME . FUNCTION).")

(defun niori-register-service (name function)
  "Register FUNCTION as the service NAME.
Replaces any previous implementation."
  (niori-platform--set-alist-entry 'niori--services name function))

(defun niori-lookup (name)
  "Look up the service NAME; return its function or nil."
  (alist-get name niori--services))

;;;; Commands

(defvar niori--commands nil
  "Alist of registered commands: (NAME . (FUNCTION . PROPS)).")

(defun niori-register-command (name function &rest props)
  "Register command NAME implemented by FUNCTION with PROPS.
PROPS commonly includes :title, a short description."
  (niori-platform--set-alist-entry 'niori--commands
                                   name (cons function props)))

(defun niori-command (name)
  "Return (FUNCTION . PROPS) for the command NAME, or nil."
  (alist-get name niori--commands))

(defun niori-commands ()
  "Names of the registered commands."
  (mapcar #'car niori--commands))

(defun niori-run-command (name)
  "Run the niori command NAME."
  (interactive
   (list (intern (completing-read "niori command: "
                                  (mapcar #'symbol-name (niori-commands))
                                  nil t))))
  (let ((cmd (niori-command name)))
    (unless cmd
      (user-error "Unknown niori command: %s" name))
    (funcall (car cmd))))

(defun niori-platform-reset ()
  "Clear every niori registry.  Intended for tests and recovery."
  (interactive)
  (setq niori--modules nil
        niori--services nil
        niori--commands nil))

;;;; Shared utilities

(defun niori--package-root ()
  "Directory containing the niori package files."
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name
                             (locate-library "niori"))))))

(defun niori--icon-file (name)
  "Return the absolute path of the icon NAME if it exists, else nil."
  (let ((file (expand-file-name (concat "icons/" name)
                                (niori--package-root))))
    (and (file-exists-p file) file)))

(defun niori--today ()
  "Today's date as an ISO 8601 string (YYYY-MM-DD)."
  (format-time-string "%Y-%m-%d"))

(defun niori--date+ (days)
  "The date DAYS from now as an ISO 8601 string (YYYY-MM-DD).
DAYS may be negative."
  (format-time-string "%Y-%m-%d"
                      (time-add (current-time) (* 86400 days))))

(defun niori--read-module (&optional prompt)
  "Read a module name interactively, returning its symbol."
  (let* ((titles (mapcar (lambda (m)
                           (cons (or (niori-module-get m :title)
                                     (symbol-name m))
                                 m))
                         (niori-modules))))
    (cdr (assoc (completing-read (or prompt "niori module: ")
                                 (mapcar #'car titles) nil t)
                titles))))

(provide 'niori-platform)

;;; niori-platform.el ends here
