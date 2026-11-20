;;; test-niori-fhir.el --- ERT tests for niori-fhir.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'json)
(require 'niori-test-helper)

;; Store records are plists; the tests below use the same shape.

(ert-deftest niori-fhir-medication-resource ()
  "A medication maps to a MedicationStatement with status and code."
  (let* ((resource (niori-fhir-resource
                    'medications
                    '(name "Aspirin"
                           dosage "100 mg"
                           form "tablet"
                           active 1
                           start_date "2026-01-01")))
         (json (json-read-from-string (json-encode resource))))
    (should (equal (cdr (assq 'resourceType json)) "MedicationStatement"))
    (should (equal (cdr (assq 'status json)) "active"))
    (should (equal
             (cdr (assq 'text (cdr (assq 'medicationCodeableConcept json))))
             "Aspirin"))
    (should (equal
             (cdr (assq 'start (cdr (assq 'effectivePeriod json))))
             "2026-01-01"))
    ;; An inactive medication is a completed statement.
    (let ((json (json-read-from-string
                 (json-encode
                  (niori-fhir-resource
                   'medications '(name "Aspirin" active 0))))))
      (should (equal (cdr (assq 'status json)) "completed")))))

(ert-deftest niori-fhir-observation-resource ()
  "A numeric lab result becomes a valueQuantity; flags map to codes."
  (let* ((resource (niori-fhir-resource
                    'labs
                    '(date "2026-10-02"
                           name "Hemoglobin A1c"
                           result "9.8"
                           unit "%"
                           flag "critical"
                           reference_range "4.0-5.6")))
         (json (json-read-from-string (json-encode resource))))
    (should (equal (cdr (assq 'resourceType json)) "Observation"))
    (should (equal (cdr (assq 'status json)) "final"))
    (should (= (cdr (assq 'value (cdr (assq 'valueQuantity json))))
               9.8))
    ;; json-read returns arrays as vectors; dig through them.
    (let* ((interpretation (cdr (assq 'interpretation json)))
           (object (aref interpretation 0))
           (coding-array (cdr (assq 'coding object)))
           (coding (aref coding-array 0)))
      (should (equal (cdr (assq 'code coding)) "A")))
    ;; Non-numeric results become valueString.
    (let ((json (json-read-from-string
                 (json-encode
                  (niori-fhir-resource
                   'labs '(name "Blood smear"
                                 result "normal morphology"
                                 flag "normal"))))))
      (should (equal (cdr (assq 'valueString json))
                     "normal morphology")))))

(ert-deftest niori-fhir-immunization-and-encounter ()
  "Vaccinations and visits map to Immunization and Encounter."
  (let ((json (json-read-from-string
               (json-encode
                (niori-fhir-resource
                 'vaccinations
                 '(date "2026-03-01"
                        vaccine "COVID-19 mRNA"
                        dose_number 3
                        route "intramuscular"
                        lot "XR42A"))))))
    (should (equal (cdr (assq 'resourceType json)) "Immunization"))
    (should (equal (cdr (assq 'lotNumber json)) "XR42A"))
    (should (equal (cdr (assq 'occurrenceDateTime json)) "2026-03-01")))
  (let ((json (json-read-from-string
               (json-encode
                (niori-fhir-resource
                 'visits
                 '(date "2026-11-01"
                        doctor "House"
                        facility "Princeton-Plainsboro"
                        reason "Check-up"))))))
    (should (equal (cdr (assq 'resourceType json)) "Encounter"))
    (should (equal (cdr (assq 'status json)) "finished"))))

(ert-deftest niori-fhir-bundle-structure ()
  "A bundle collects every record under resourceType Bundle."
  (niori-with-test-db
    (niori-store-insert 'medications '((name . "Aspirin")))
    (niori-store-insert 'medications '((name . "Metformin")))
    (let* ((bundle (niori-fhir-bundle 'medications))
           (json (json-read-from-string (json-encode bundle))))
      (should (equal (cdr (assq 'resourceType json)) "Bundle"))
      (should (equal (cdr (assq 'type json)) "collection"))
      (should (= (length (cdr (assq 'entry json))) 2))
      (let ((first-entry (aref (cdr (assq 'entry json)) 0)))
        (should (assq 'resource first-entry))))))

(provide 'test-niori-fhir)

;;; test-niori-fhir.el ends here
