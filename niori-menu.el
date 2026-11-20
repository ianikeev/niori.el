;;; niori-menu.el --- Key bindings and menus for niori  -*- lexical-binding: t; -*-

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

;; Every niori key binding lives under the single `C-c M' prefix,
;; enabled by the global minor mode `niori-mode' (the same convention
;; used by org-roam).  An overview is always available:
;;
;;   C-c M C-h   describe the whole prefix map
;;   C-c M ?     the `transient' command menu (when transient is
;;               installed; otherwise a which-key/keyboard fallback)
;;
;; The standalone application additionally installs a menu-bar entry
;; (`niori-menu-install-menubar').

;;; Code:

(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)

;; Commands defined in files loaded after this one.
(declare-function niori-dashboard "niori-dashboard")
(declare-function niori-medications "niori-medications")
(declare-function niori-visits "niori-visits")
(declare-function niori-visits-letter "niori-visits")
(declare-function niori-labs "niori-labs")
(declare-function niori-vaccinations "niori-vaccinations")
(declare-function niori-medications-add "niori-medications")
(declare-function niori-visits-add "niori-visits")
(declare-function niori-labs-add "niori-labs")
(declare-function niori-vaccinations-add "niori-vaccinations")
(declare-function niori-documents "niori-attachments")
(declare-function niori-attachments-add "niori-attachments")
(declare-function niori-fhir-export "niori-fhir")

(defvar-keymap niori-command-map
  :doc "niori prefix map, bound to `C-c M' by `niori-mode'."
  "d" #'niori-dashboard
  "m" #'niori-medications
  "v" #'niori-visits
  "t" #'niori-labs
  "c" #'niori-vaccinations
  "f" #'niori-documents
  "a" 'niori-add-map
  "E" 'niori-export-map
  "D" #'niori-record-ediff
  "l" #'niori-visits-letter
  "b" #'niori-store-backup
  "?" #'niori-menu
  "C-h" #'niori-menu)

;;;###autoload
(define-minor-mode niori-mode
  "Toggle the global niori key bindings.
This binds `niori-command-map' under the `C-c M' prefix."
  :global t
  :group 'niori
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c M") niori-command-map)
            map)
  (when niori-mode
    (condition-case error
        (niori-store-open)
      (error (message "niori: %s" (error-message-string error))))))

(defun niori-menu ()
  "Open the niori command menu.
Uses `niori-transient-menu' when the transient menu is available,
and falls back to a which-key overview, or the dashboard."
  (interactive)
  (cond ((fboundp 'niori-transient-menu)
         (call-interactively #'niori-transient-menu))
        ((fboundp 'which-key-show-full-keymap)
         (which-key-show-full-keymap 'niori-command-map))
        (t
         (niori-dashboard))))

;;;; Menu bar integration

(defvar niori-menubar-menu nil
  "Menu-bar menu installed by `niori-menu-install-menubar'.")

(defun niori-menu-install-menubar ()
  "Add an niori entry to the menu bar (for the standalone app)."
  (interactive)
  (easy-menu-define niori-menubar-menu global-map "niori"
    '("niori"
      ["Dashboard" niori-dashboard]
      "---"
      ["Medications" niori-medications]
      ["Visits" niori-visits]
      ["Lab tests" niori-labs]
      ["Vaccinations" niori-vaccinations]
      "---"
      ["Documents" niori-documents]
      ["Attach file" niori-attachments-add]
      ["New medication" niori-medications-add]
      ["New visit" niori-visits-add]
      ["New lab test" niori-labs-add]
      ["New vaccination" niori-vaccinations-add]
      "---"
      ["Export Org" niori-export-org]
      ["Export CSV" niori-export-csv]
      ["Export FHIR JSON" niori-fhir-export]
      ["Backup database" niori-store-backup]
      "---"
      ["Quit niori" save-buffers-kill-terminal]))
  (message "niori: menu bar entry installed"))

(defun niori-menu-uninstall-menubar ()
  "Remove the niori menu bar entry."
  (interactive)
  (define-key global-map [menu-bar niori] nil))

(provide 'niori-menu)

;;; niori-menu.el ends here
