;;; test-niori-modules.el --- ERT tests for the niori modules  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'niori-test-helper)

(ert-deftest niori-modules-registered ()
  "All four clinical modules register with the platform."
  (dolist (module '(medications visits labs vaccinations))
    (should (memq module (niori-modules)))
    (should (niori-module-get module :title))
    (should (niori-module-get module :fields))
    (should (niori-module-get module :columns))
    (should (niori-module-get module :dashboard-fn))
    (should (fboundp (niori-module-get module :dashboard-fn))))
  ;; Commands are registered too.
  (dolist (command '(medications-open medications-add
                     visits-open visits-add visits-letter
                     labs-open labs-add
                     vaccinations-open vaccinations-add))
    (should (niori-command command))))

(ert-deftest niori-visits-upcoming ()
  "The upcoming-visits query filters by date window."
  (niori-with-test-db
    (let ((past (niori--date+ -10))
          (soon (niori--date+ 3))
          (later (niori--date+ 60)))
      (niori-store-insert 'visits `((date . ,past) (doctor . "Past")))
      (niori-store-insert 'visits `((date . ,soon) (doctor . "Soon")))
      (niori-store-insert 'visits `((date . ,later) (doctor . "Later")))
      (let ((upcoming (niori-visits--upcoming 30)))
        (should (= (length upcoming) 1))
        (should (equal (plist-get (car upcoming) 'doctor) "Soon")))
      (let ((far (niori-visits--upcoming 90)))
        (should (= (length far) 2))))))

(ert-deftest niori-labs-flagged-latest ()
  "Only the latest result per test name is considered."
  (niori-with-test-db
    ;; Hemoglobin: was high, latest is normal -> not flagged.
    (niori-store-insert 'labs '((date . "2026-09-01")
                                 (name . "Hemoglobin")
                                 (result . "13.1")
                                 (flag . "high")))
    (niori-store-insert 'labs '((date . "2026-10-01")
                                 (name . "Hemoglobin")
                                 (result . "13.9")
                                 (flag . "normal")))
    ;; A1c: latest is critical -> flagged.
    (niori-store-insert 'labs '((date . "2026-10-02")
                                 (name . "Hemoglobin A1c")
                                 (result . "9.8")
                                 (flag . "critical")))
    ;; Cholesterol: normal -> ignored.
    (niori-store-insert 'labs '((date . "2026-10-03")
                                 (name . "Cholesterol")
                                 (result . "4.9")
                                 (flag . "normal")))
    (let ((flagged (niori-labs--flagged-latest)))
      (should (= (length flagged) 1))
      (should (equal (plist-get (car flagged) 'name) "Hemoglobin A1c")))))

(ert-deftest niori-vaccinations-due ()
  "Due and overdue boosters are selected; far-future ones are not."
  (niori-with-test-db
    (niori-store-insert 'vaccinations
                        `((date . "2020-01-01")
                          (vaccine . "Tetanus")
                          (next_due_date . ,(niori--date+ -5))))
    (niori-store-insert 'vaccinations
                        `((date . "2024-01-01")
                          (vaccine . "COVID-19")
                          (next_due_date . ,(niori--date+ 30))))
    (niori-store-insert 'vaccinations
                        `((date . "2024-01-01")
                          (vaccine . "Flu")
                          (next_due_date . ,(niori--date+ 400))))
    (niori-store-insert 'vaccinations
                        '((date . "2023-05-05")
                          (vaccine . "Hepatitis B")))
    (let ((due (niori-vaccinations--due 90)))
      (should (= (length due) 2))
      ;; Overdue ones are detected.
      (should (niori-vaccinations--overdue-p
               (cl-find "Tetanus" due :key (lambda (r) (plist-get r 'vaccine))
                         :test #'equal)))
      ;; Future ones are not overdue.
      (should-not (niori-vaccinations--overdue-p
                   (cl-find "COVID-19" due
                            :key (lambda (r) (plist-get r 'vaccine))
                            :test #'equal))))))

(provide 'test-niori-modules)

;;; test-niori-modules.el ends here
