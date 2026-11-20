;;; niori-transient.el --- Transient command menu for niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.3.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of niori.el.

;; niori.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; niori.el is delivered under the same terms.

;;; Commentary:

;; A `transient' menu for niori (the same UI library that powers
;; Magit).  This file defines the menu at run time so that niori
;; keeps working, and byte-compiling cleanly, on Emacsen where
;; transient is not installed: `niori-menu' simply falls back to a
;; keymap overview in that case.

;;; Code:

(require 'niori-platform)

(defun niori-transient--define-menu ()
  "Define `niori-transient-menu' using the transient library.
The macro is evaluated at run time (once transient is available)
so that this file never requires transient at compile time."
  (eval
   '(transient-define-prefix niori-transient-menu ()
      "niori command menu."
      [["View"
        ("d" "Dashboard" niori-dashboard)
        ("m" "Medications" niori-medications)
        ("v" "Visits" niori-visits)
        ("t" "Lab tests" niori-labs)
        ("c" "Vaccinations" niori-vaccinations)
        ("f" "Documents" niori-documents)]
       ["Create"
        ("M" "New medication" niori-medications-add)
        ("V" "New visit" niori-visits-add)
        ("T" "New lab test" niori-labs-add)
        ("C" "New vaccination" niori-vaccinations-add)
        ("A" "Attach a file" niori-attachments-add)]]
      [["Data"
        ("o" "Export Org" niori-export-org)
        ("x" "Export CSV" niori-export-csv)
        ("j" "Export FHIR JSON" niori-fhir-export)
        ("=" "Diff record revision" niori-record-ediff)
        ("b" "Backup database" niori-store-backup)
        ("h" "Check attachments" niori-attachments-check)]
       ["Letters"
        ("l" "Visit letter" niori-visits-letter)]])))

(if (require 'transient nil 'noerror)
    (niori-transient--define-menu)
  (with-eval-after-load 'transient
    (niori-transient--define-menu)))

(provide 'niori-transient)

;;; niori-transient.el ends here
