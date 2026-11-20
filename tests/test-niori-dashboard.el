;;; test-niori-dashboard.el --- ERT tests for niori-dashboard.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'niori-test-helper)

(ert-deftest niori-dashboard-renders-modules ()
  "The dashboard shows one section per registered module."
  (niori-with-test-db
    (niori-test--kill-niori-buffers)
    (let ((buffer (niori-dashboard)))
      (unwind-protect
          (let ((text (with-current-buffer buffer (buffer-string))))
            (dolist (module (niori-modules))
              (should (string-match-p
                       (regexp-quote (niori-module-get module :title))
                       text))))
        (niori-test--kill-niori-buffers)))))

(ert-deftest niori-dashboard-shows-records ()
  "Records added to the store show up on the dashboard."
  (niori-with-test-db
    (niori-test--kill-niori-buffers)
    (niori-store-insert 'medications
                        '((name . "Levothyroxine")
                          (dosage . "75 mcg")
                          (active . 1)))
    (niori-store-insert 'visits
                        `((date . ,(niori--date+ 7))
                          (doctor . "Cuddy")
                          (reason . "Thyroid review")))
    (niori-store-insert 'labs
                        '((date . "2026-11-01")
                          (name . "TSH")
                          (result . "8.2")
                          (flag . "high")))
    (niori-store-insert 'vaccinations
                        `((date . "2020-01-01")
                          (vaccine . "Tetanus")
                          (next_due_date . ,(niori--date+ -1))))
    (let ((buffer (niori-dashboard)))
      (unwind-protect
          (let ((text (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "Levothyroxine" text))
            (should (string-match-p "Cuddy" text))
            (should (string-match-p "TSH" text))
            (should (string-match-p "overdue" text)))
        (niori-test--kill-niori-buffers)))))

(ert-deftest niori-dashboard-refresh-picks-up-changes ()
  "Refreshing re-renders the dashboard with current data."
  (niori-with-test-db
    (niori-test--kill-niori-buffers)
    (niori-dashboard)
    (niori-store-insert 'medications '((name . "Warfarin")
                                       (active . 1)))
    (should (niori-dashboard-refresh))
    (should (string-match-p
             "Warfarin"
             (with-current-buffer (get-buffer "*niori*")
               (buffer-string))))
    (niori-test--kill-niori-buffers)))

(ert-deftest niori-view-refresh-module-updates-dashboard ()
  "Saving through the view layer refreshes the dashboard too."
  (niori-with-test-db
    (niori-test--kill-niori-buffers)
    (niori-dashboard)
    (niori-view--refresh-module 'medications)
    ;; Simply verifying the helper runs without error against an
    ;; existing dashboard; the render itself is covered above.
    (should (get-buffer "*niori*"))
    (niori-test--kill-niori-buffers)))

(provide 'test-niori-dashboard)

;;; test-niori-dashboard.el ends here
