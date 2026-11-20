;;; niori.el --- Personal medical records manager, Emacs port of niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health, database
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (compat "29.1") (transient "0.3.0") (auto-dark "0.2.0") (fontaine "0.3.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of niori.el, an Emacs port of the niori
;; medical information manager (https://github.com/ianikeev/niori).

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

;; niori is a personal medical records manager: medications, visits,
;; lab tests and vaccinations stored in a local SQLite database, with
;; a dashboard for what needs attention.  This package ports the
;; original application to Emacs, reusing the platform Emacs
;; provides instead of reimplementing it (see ARCHITECTURE.md).
;;
;; Quick start:
;;
;;   M-x niori            open the dashboard and enable C-c M keys
;;   C-c M m / v / t / c  rosters: medications, visits, tests,
;;                        vaccinations
;;   C-c M C-h            overview of every niori key binding
;;   C-c M ?              the transient command menu
;;
;; Data lives in one directory the user chooses; see
;; `niori-data-directory'.  It holds the SQLite database, the documents
;; attached to records (`documents/'), backups and exports.  The
;; database is created and migrated automatically on first use.
;;
;; niori can also run as a standalone application with no Emacs
;; configuration at all: run the bin/niori script from the repository
;; (see README.md).

;;; Code:

(require 'niori-platform)
(require 'niori-store)
(require 'niori-view)
(require 'niori-appearance)
(require 'niori-dashboard)
(require 'niori-menu)
(require 'niori-transient nil t)
(require 'niori-medications)
(require 'niori-visits)
(require 'niori-labs)
(require 'niori-vaccinations)
(require 'niori-attachments)
(require 'niori-fhir)

;; Close the database cleanly when Emacs exits.
(add-hook 'kill-emacs-hook #'niori-store-close)

;;;###autoload
(defun niori ()
  "Open the niori dashboard and enable the global key bindings."
  (interactive)
  (niori-mode 1)
  (niori-dashboard))

(provide 'niori)

;;; niori.el ends here
