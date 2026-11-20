;;; niori-test-helper.el --- Shared helpers for the niori test suite  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loads the niori package from the repository root and provides a
;; macro that runs each test against a fresh temporary database.

;;; Code:

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root))

(require 'niori)

(defmacro niori-with-test-data-dir (&rest body)
  "Run BODY with a fresh temporary niori data directory."
  (declare (indent 0))
  `(let* ((directory (file-name-as-directory (make-temp-file "niori-test-" t)))
          (niori-data-directory directory)
          ;; Never let a user setting (or a leaked binding) point a test
          ;; at the real database or the real documents.
          (niori-data-file nil)
          (niori-documents-directory nil))
     (unwind-protect
         (progn
           (niori-store-close)
           (niori-store-open)
           ,@body)
       (niori-store-close)
       (ignore-errors (delete-directory directory 'recursive)))))

(defmacro niori-with-test-db (&rest body)
  "Run BODY with a fresh temporary niori database.
The database lives in a temporary data directory, so documents,
backups and exports of a test never touch the user's own."
  (declare (indent 0))
  `(niori-with-test-data-dir ,@body))

(defconst niori-test--posix-modes-p
  (not (memq system-type '(windows-nt ms-dos)))
  "Whether the file-mode checks are meaningful on this system.")

(defun niori-test--kill-niori-buffers ()
  "Kill every niori buffer, for test isolation."
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*niori" (buffer-name buffer))
      (ignore-errors (kill-buffer buffer)))))

(provide 'niori-test-helper)

;;; niori-test-helper.el ends here
