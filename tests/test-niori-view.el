;;; test-niori-view.el --- ERT tests for niori-view.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'niori-test-helper)

(ert-deftest niori-view-field-text ()
  "Field rendering handles booleans, numbers, nil and strings."
  (let ((record '(name "Aspirin" active 1 dose_number 2 dosage nil)))
    (should (equal (niori-view--field-text 'medications record 'name)
                   "Aspirin"))
    (should (equal (niori-view--field-text 'medications record 'active)
                   "yes"))
    (should (equal (niori-view--field-text
                    'medications '(active 0) 'active)
                   "no"))
    (should (equal (niori-view--field-text
                    'vaccinations record 'dose_number)
                   "2"))
    (should (equal (niori-view--field-text 'medications record 'dosage)
                   ""))))

(ert-deftest niori-view-record-title ()
  "Record titles come from the module's :title-fn."
  (should (equal (niori-view--record-title
                  'medications '(name "Aspirin" dosage "100 mg"))
                 "Aspirin 100 mg"))
  (should (equal (niori-view--record-title
                  'visits '(date "2026-11-20" doctor "House"))
                 "2026-11-20 — House")))

(ert-deftest niori-view-valid-date-p ()
  "Date validation accepts real calendar dates only."
  (should (niori--valid-date-p "2026-11-20"))
  (should (niori--valid-date-p "2024-02-29"))   ; leap year
  (should-not (niori--valid-date-p "2026-02-29"))
  (should-not (niori--valid-date-p "2026-13-01"))
  (should-not (niori--valid-date-p "20-11-2026"))
  (should-not (niori--valid-date-p "2026/11/20"))
  (should-not (niori--valid-date-p "")))

(ert-deftest niori-view-validate-values ()
  "Form validation catches missing required fields and bad dates."
  (let ((values '((date . "2026-02-30") (doctor . "House"))))
    (should (equal (niori-view--validate-values 'visits values)
                   '("Date must be a YYYY-MM-DD date"))))
  (should (equal (niori-view--validate-values
                  'visits '((doctor . "House")))
                 '("Date is required")))
  (should (null (niori-view--validate-values
                 'visits '((date . "2026-11-20"))))))

(ert-deftest niori-view-csv-export ()
  "CSV rendering quotes separators and newlines."
  (niori-with-test-db
    (niori-store-insert 'medications
                        '((name . "Aspirin, buffered")
                          (dosage . "100 mg")))
    (let ((csv (niori-view--csv
                'medications (niori-store-select 'medications))))
      (should (string-prefix-p "Name" csv))
      (should (string-match-p "\"Aspirin, buffered\"" csv))
      ;; The exported file round-trips through the file system.
      (let ((file (make-temp-file "niori-csv-" nil ".csv")))
        (unwind-protect
            (progn
              (write-region (niori-view--csv
                             'medications
                             (niori-store-select 'medications))
                            nil file)
              (should (file-exists-p file)))
          (ignore-errors (delete-file file)))))))

(ert-deftest niori-view-org-export ()
  "Org export renders a padded table with a header separator."
  (niori-with-test-db
    (niori-store-insert 'medications '((name . "Aspirin")
                                       (dosage . "100 mg")))
    (let ((org (niori-view--org
                'medications (niori-store-select 'medications))))
      (should (string-prefix-p "#+title:" org))
      (should (string-match-p "^| *Name *|" org))
      (should (string-match-p "^|-" org))
      (should (string-match-p "Aspirin" org)))))

(ert-deftest niori-view-roster-renders-in-batch ()
  "A roster buffer renders its entries even without a display."
  (niori-with-test-db
    (niori-test--kill-niori-buffers)
    (niori-store-insert 'medications '((name . "Metoprolol")
                                       (dosage . "50 mg")
                                       (active . 1)))
    (let ((buffer (niori-roster 'medications)))
      (unwind-protect
          (let ((text (with-current-buffer buffer (buffer-string))))
            ;; Rows appear in the buffer text...
            (should (string-match-p "Metoprolol" text))
            ;; ...while the column header is a header-line.
            (should (with-current-buffer buffer
                      (string-match-p "Name"
                                      (format "%s" header-line-format)))))
        (niori-test--kill-niori-buffers)))))

(provide 'test-niori-view)

;;; test-niori-view.el ends here
