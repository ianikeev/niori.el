;;; niori-appearance.el --- Theme and font setup for niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health, faces
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

;; Optional appearance management for niori.
;;
;; When niori runs as a library inside the user's Emacs this file does
;; nothing by default: your own themes and fonts stay untouched.  When
;; niori runs as a standalone application (`bin/niori',
;; `niori-standalone.el') it sets `niori-appearance-manage' to t and
;; this layer provides sensible defaults:
;;
;;   * the built-in Modus themes, switching automatically between
;;     `modus-operandi' (light) and `modus-vivendi' (dark) — through
;;     the `auto-dark' package when available, with a built-in
;;     day/night fallback otherwise;
;;   * monospaced fonts through `fontaine' when available, with a
;;     direct `set-face-attribute' fallback otherwise.
;;
;; Everything is a defcustom, so a user file loaded before the
;; dashboard keeps full control.

;;; Code:

(require 'cl-lib)

;; Declarations so this file byte-compiles cleanly without the
;; optional fontaine/auto-dark packages being installed.
(defvar fontaine-presets)
(declare-function fontaine-set-preset "fontaine")
(defvar auto-dark-light-theme)
(defvar auto-dark-dark-theme)
(declare-function auto-dark-mode "auto-dark")

(defgroup niori-appearance nil
  "Theme and font management for the niori application."
  :group 'niori)

(defcustom niori-appearance-manage nil
  "When non-nil, niori manages themes and fonts.
Enabled automatically by `niori-standalone-run'."
  :type 'boolean
  :group 'niori-appearance)

(defcustom niori-appearance-light-theme 'modus-operandi
  "Theme for the light half of the day."
  :type 'symbol
  :group 'niori-appearance)

(defcustom niori-appearance-dark-theme 'modus-vivendi
  "Theme for the dark half of the day."
  :type 'symbol
  :group 'niori-appearance)

(defcustom niori-appearance-light-hours '(7 . 21)
  "Cons (FROM . TO) of hours during which the light theme is used.
Only relevant when `auto-dark' is unavailable."
  :type '(cons (integer :tag "From hour") (integer :tag "To hour"))
  :group 'niori-appearance)

(defcustom niori-appearance-font-family nil
  "Monospaced font family for niori, or nil to auto-detect.
Auto-detection picks the first installed font among a list of
common programming fonts and finally falls back to the default."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'niori-appearance)

(defcustom niori-appearance-font-height 105
  "Default font height (tenths of a point)."
  :type 'natnum
  :group 'niori-appearance)

(defcustom niori-appearance-font-candidates
  '("Iosevka" "JetBrains Mono" "Fira Code" "Inconsolata" "IBM Plex Mono"
    "DejaVu Sans Mono" "Noto Sans Mono" "Source Code Pro" "Menlo" "Consolas"
    "Courier New")
  "Font families tried, in order, when auto-detecting."
  :type '(repeat string)
  :group 'niori-appearance)

(defun niori-appearance--pick-family ()
  "Return the first installed candidate font family."
  (if noninteractive
      "monospace"
    (or (cl-find-if (lambda (family)
                      (member family (font-family-list)))
                    niori-appearance-font-candidates)
        "monospace")))

(defun niori-appearance--font-family ()
  "The font family niori should use."
  (or niori-appearance-font-family
      (niori-appearance--pick-family)))

(defun niori-appearance-setup ()
  "Apply niori theme and font defaults.
Does nothing unless `niori-appearance-manage' is non-nil."
  (interactive)
  (when (and niori-appearance-manage (not noninteractive))
    (niori-appearance--setup-font)
    (niori-appearance--setup-theme)))

(defun niori-appearance--setup-font ()
  "Configure the default font, preferring `fontaine'."
  (let ((family (niori-appearance--font-family)))
    (if (require 'fontaine nil t)
        (progn
          (setq fontaine-presets
                `((small  :default-family ,family :default-height 90)
                  (default :default-family ,family
                           :default-height ,niori-appearance-font-height)
                  (large  :default-family ,family :default-height 135)))
          (fontaine-set-preset 'default))
      (set-face-attribute 'default nil
                          :family family
                          :height niori-appearance-font-height))))

(defun niori-appearance--setup-theme ()
  "Load the Modus themes, preferring `auto-dark'."
  (if (require 'auto-dark nil t)
      (progn
        (setq auto-dark-light-theme niori-appearance-light-theme
              auto-dark-dark-theme niori-appearance-dark-theme)
        (auto-dark-mode 1))
    (let* ((hour (nth 2 (decode-time)))
           (light (<= (car niori-appearance-light-hours) hour
                      (cdr niori-appearance-light-hours))))
      (load-theme (if light
                      niori-appearance-light-theme
                    niori-appearance-dark-theme)
                 t))))

(provide 'niori-appearance)

;;; niori-appearance.el ends here
