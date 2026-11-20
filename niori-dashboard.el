;;; niori-dashboard.el --- The niori dashboard buffer  -*- lexical-binding: t; -*-

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

;; The dashboard is the landing buffer of the application: counts and
;; quick actions per module, plus the actionable lists a health record
;; keeper actually needs — upcoming visits, lab results that need
;; attention, and vaccination boosters that are due.  Each module
;; contributes its own section through the :dashboard-fn property of
;; its registration (see `niori-register-module'), so the dashboard
;; itself contains no module-specific knowledge.

;;; Code:

(require 'seq)
(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

;; Commands defined in the module files, loaded after this one.
(declare-function niori-medications "niori-medications")
(declare-function niori-visits "niori-visits")
(declare-function niori-labs "niori-labs")
(declare-function niori-vaccinations "niori-vaccinations")
(declare-function niori-form "niori-view")

(defgroup niori-dashboard nil
  "The niori dashboard buffer."
  :group 'niori)

(defconst niori-dashboard-buffer-name "*niori*"
  "Name of the dashboard buffer.")

(defvar-keymap niori-dashboard-mode-map
  :parent special-mode-map
  :doc "Keymap for the niori dashboard."
  "g" #'niori-dashboard-refresh
  "m" #'niori-medications
  "v" #'niori-visits
  "t" #'niori-labs
  "c" #'niori-vaccinations)

(define-derived-mode niori-dashboard-mode special-mode "niori"
  "Major mode for the niori dashboard.
\\<niori-dashboard-mode-map>Press \\[niori-dashboard-refresh] to refresh, and \
use TAB to move between buttons."
  (setq-local revert-buffer-function #'niori-dashboard-refresh))

;;;###autoload
(defun niori-dashboard ()
  "Open (or refresh) the niori dashboard."
  (interactive)
  (niori-store-open)
  (let ((buffer (niori-dashboard-get-buffer)))
    (with-current-buffer buffer
      (niori-dashboard-render))
    (unless noninteractive (pop-to-buffer buffer))
    buffer))

(defun niori-dashboard-get-buffer ()
  "Return the dashboard buffer, creating it if needed."
  (let ((buffer (get-buffer-create niori-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'niori-dashboard-mode)
        (niori-dashboard-mode)))
    buffer))

(defun niori-dashboard-refresh (&rest _)
  "Re-render the dashboard buffer if it exists."
  (interactive)
  (when (get-buffer niori-dashboard-buffer-name)
    (with-current-buffer (niori-dashboard-get-buffer)
      (niori-dashboard-render))
    t))

(defun niori-dashboard-render ()
  "Draw the dashboard in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (niori-dashboard--insert-icon "niori.png" 40)
    (insert (propertize "niori" 'face '(:weight bold :height 1.6))
            (propertize " — medical records\n" 'face 'shadow))
    (insert (propertize
             (format-time-string "%A, %e %B %Y")
             'face 'shadow)
            "\n\n")
    (dolist (module (niori-modules))
      (niori-dashboard--section module))
    (insert (propertize "Actions\n" 'face 'bold))
    (dolist (module (niori-modules))
      (let ((title (niori-view--module-title module)))
        (insert-button (format " New %s " (downcase title))
                       :follow-link t
                       :action (lambda (&rest _) (niori-form module)))
        (insert "  ")))
    (insert "\n\n")
    (insert (propertize
             (concat "C-c M ?  — command menu      "
                     "C-c M C-h  — keymap overview      "
                     "g  — refresh      "
                     "q  — hide")
             'face 'shadow)
            "\n")
    (goto-char (point-min))))

(defun niori-dashboard--section (module)
  "Insert the dashboard section of MODULE."
  (niori-dashboard--insert-icon (format "%s.svg" module) 24)
  (insert (propertize (concat (niori-view--module-title module) "\n")
                      'face 'bold))
  (let ((here (point)))
    (funcall (niori-module-get module :dashboard-fn))
    (when (= here (point))
      (insert "  (no data)\n")))
  (insert "\n"))

(defun niori-dashboard--insert-icon (name height)
  "Insert icon NAME scaled to HEIGHT pixels, when images are possible."
  (when (display-graphic-p)
    (let* ((file (niori--icon-file name))
           (type (and file (intern (file-name-extension file)))))
      (when (and file (image-type-available-p type))
        (insert-image (create-image file type nil :height height)
                      " ")
        (insert " ")))))

(defun niori-dashboard--record-button (module record)
  "Insert a button opening MODULE's RECORD detail view."
  (insert-button
   (niori-view--record-title module record)
   :follow-link t
   :action (lambda (&rest _)
             (niori-detail module (plist-get record 'id))))
  (insert "  "))

(provide 'niori-dashboard)

;;; niori-dashboard.el ends here
