;;; niori-standalone.el --- Run niori as a standalone application  -*- lexical-binding: t; -*-

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

;; Bootstrap for running niori as a standalone application on top of a
;; stock Emacs, started with `emacs -Q'.  The bin/niori script loads
;; this file; you can also do it by hand:
;;
;;   emacs -Q -l /path/to/niori.el/niori-standalone.el \
;;         -f niori-standalone-run
;;
;; On first run (and when online) the GNU ELPA dependencies and a few
;; enhancement packages are installed automatically; offline, niori
;; degrades gracefully to built-ins: day/night Modus themes instead of
;; auto-dark, a direct font setting instead of fontaine, fido vertical
;; completion instead of vertico, and a plain keymap overview instead
;; of the transient menu.

;;; Code:

;; Defined in files loaded after this one.
(defvar niori-appearance-manage)
(declare-function niori-appearance-setup "niori-appearance")
(declare-function niori-dashboard "niori-dashboard")
(declare-function niori-dashboard-get-buffer "niori-dashboard")
(declare-function niori-dashboard-render "niori-dashboard")
(declare-function niori-mode "niori-menu")
(declare-function niori-menu-install-menubar "niori-menu")
(declare-function vertico-mode "vertico")

(defvar niori-standalone-p)
(setq niori-standalone-p t)

(defgroup niori-standalone nil
  "Running niori as a standalone application."
  :group 'niori)

(defcustom niori-standalone-install-packages t
  "Install the niori GNU ELPA dependencies on first run.
Set to nil — or export NIORI_NO_NET=1 — to start fully offline."
  :type 'boolean
  :group 'niori-standalone)

(defcustom niori-standalone-packages '(compat transient auto-dark fontaine)
  "GNU ELPA packages niori needs at runtime."
  :type '(repeat symbol)
  :group 'niori-standalone)

(defcustom niori-standalone-enhancement-packages
  '(vertico consult orderless which-key)
  "Extra GNU ELPA packages the standalone app installs and enables."
  :type '(repeat symbol)
  :group 'niori-standalone)

(defcustom niori-standalone-cua nil
  "When non-nil, enable `cua-mode' in the standalone application.
CUA gives beginners the usual C-x/C-c/C-v cut/copy/paste bindings
while leaving all Emacs key bindings intact."
  :type 'boolean
  :group 'niori-standalone)

(defconst niori-standalone--root
  (file-name-directory (or load-file-name buffer-file-name ""))
  "Directory containing the niori sources.")

(add-to-list 'load-path niori-standalone--root)

;;;; Package bootstrap

(defun niori-standalone--online-p ()
  "Whether package installation is enabled."
  (and niori-standalone-install-packages
       (not (equal (getenv "NIORI_NO_NET") "1"))))

(defun niori-standalone--ensure-packages (packages)
  "Install any of PACKAGES that is missing from this Emacs."
  (dolist (package packages)
    (unless (or (require package nil t)
                (package-installed-p package))
      (niori-standalone--install package))))

(defun niori-standalone--install (package)
  "Try to install PACKAGE from GNU ELPA, quietly."
  (when (niori-standalone--refresh-archives)
    (condition-case error
        (progn
          (package-install package)
          (message "niori: installed %s" package))
      (error
       (message "niori: could not install %s (%s); using built-ins"
                package (error-message-string error))))))

(defvar niori-standalone--archives-refreshed nil)

(defun niori-standalone--refresh-archives ()
  "Refresh package archives once; return non-nil when reachable."
  (or niori-standalone--archives-refreshed
      (let ((url-show-status nil))
        (setq niori-standalone--archives-refreshed
              (condition-case nil
                  (progn (package-refresh-contents) t)
                (error
                 (message "niori: package archive unreachable; continuing with built-ins")
                 nil))))))

;;;; Enhancement setup

(defun niori-standalone--setup-completion ()
  "Enable vertical completion: vertico when present, else fido."
  (if (require 'vertico nil t)
      (vertico-mode 1)
    (fido-vertical-mode 1))
  (when (require 'orderless nil t)
    (setq completion-styles '(orderless basic)
          completion-category-defaults nil)))

(defun niori-standalone--setup-which-key ()
  "Enable which-key hints when available."
  (when (fboundp 'which-key-mode)
    (which-key-mode 1)))

;;;; Entry point

(defun niori-standalone--initial-buffer ()
  "Return the buffer Emacs should show at startup."
  (niori-dashboard))

;;;###autoload
(defun niori-standalone-run ()
  "Start niori as a standalone application.
Installs dependencies when online, applies the Modus theme and font
defaults, and opens the dashboard."
  (interactive)
  (setq inhibit-startup-screen t
        initial-buffer-choice #'niori-standalone--initial-buffer)
  (when (niori-standalone--online-p)
    (require 'package)
    (package-initialize)
    (niori-standalone--ensure-packages niori-standalone-packages)
    (niori-standalone--ensure-packages
     niori-standalone-enhancement-packages))
  (require 'niori)
  (setq niori-appearance-manage t)
  (niori-appearance-setup)
  (niori-standalone--setup-completion)
  (niori-standalone--setup-which-key)
  (when niori-standalone-cua
    (cua-mode 1))
  (niori-menu-install-menubar)
  (niori-mode 1)
  (if noninteractive
      (with-current-buffer (niori-dashboard-get-buffer)
        (niori-dashboard-render))
    (niori-dashboard)))

(provide 'niori-standalone)

;;; niori-standalone.el ends here
