;;; niori-fhir.el --- FHIR R4 export and client for niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health, tools
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

;; Interoperability with the FHIR (Fast Healthcare Interoperability
;; Resources) standard, using only built-in libraries:
;;
;;   * serialisation — every niori record maps to a simplified FHIR
;;     R4 resource (MedicationStatement, Encounter, Observation,
;;     Immunization) and `niori-fhir-export' writes the whole module
;;     as a FHIR collection Bundle, using `json-encode';
;;   * retrieval — `niori-fhir-fetch' performs authenticated GET
;;     requests against a FHIR server with `url' and reads the
;;     bearer token from `auth-source' (an entry whose host matches
;;     `niori-fhir-server-url').
;;
;; The mappings are deliberately minimal (identification by display
;; strings, no code system translations); they are intended for
;; personal export and review, not for clinical record exchange.

;;; Code:

(require 'json)
(require 'url)
(require 'auth-source)
(require 'niori-platform)
(require 'niori-store)

(defgroup niori-fhir nil
  "FHIR interoperability for niori."
  :group 'niori)

(defcustom niori-fhir-server-url nil
  "Base URL of a FHIR server, for `niori-fhir-fetch'.
Example: \"https://server.example.com/fhir\"."
  :type '(choice (const :tag "None" nil) string)
  :group 'niori-fhir)

;;;; Serialisation

(defun niori-fhir--value (record field)
  "FIELD of RECORD unless empty, in which case nil."
  (let ((value (plist-get record field)))
    (if (equal value "") nil value)))

(defun niori-fhir--medication (record)
  "FHIR MedicationStatement alist for a medication RECORD."
  (let ((dosage (niori-fhir--value record 'dosage))
        (form (niori-fhir--value record 'form)))
    (append
     '((resourceType . "MedicationStatement"))
     `((status . ,(if (and (plist-get record 'active)
                           (not (equal 0 (plist-get record 'active))))
                      "active" "completed")))
     `((medicationCodeableConcept
        . ((text . ,(or (niori-fhir--value record 'name) "")))))
     (when dosage
       `((dosage . (((text . ,(if form
                                  (concat dosage " (" form ")")
                                dosage)))))))
     (let ((start (niori-fhir--value record 'start_date))
           (end (niori-fhir--value record 'end_date)))
       (when (or start end)
         `((effectivePeriod . ((start . ,start) (end . ,end))))))
     (when (niori-fhir--value record 'prescriber)
       `((informationSource . ((display . ,(plist-get record
                                                   'prescriber))))))
     (when (niori-fhir--value record 'instructions)
       `((note . (((text . ,(plist-get record 'instructions))))))))))

(defun niori-fhir--encounter (record)
  "FHIR Encounter alist for a visit RECORD."
  (append
   '((resourceType . "Encounter") (status . "finished"))
   `((class . ((code . "AMB") (display . "ambulatory"))))
   (when (niori-fhir--value record 'date)
     `((period . ((start . ,(plist-get record 'date))))))
   (when (niori-fhir--value record 'doctor)
     `((participant . (((individual . ((display . ,(plist-get record
                                                            'doctor)))))))))
   (when (niori-fhir--value record 'reason)
     `((reasonCode . (((text . ,(plist-get record 'reason)))))))
   (when (niori-fhir--value record 'diagnosis)
     `((diagnosis . (((condition . ((display . ,(plist-get record
                                                        'diagnosis)))))))))
   (when (niori-fhir--value record 'facility)
     `((serviceProvider . ((display . ,(plist-get record 'facility))))))))

(defun niori-fhir--observation (record)
  "FHIR Observation alist for a lab test RECORD."
  (let* ((result (niori-fhir--value record 'result))
         (numeric (and result (string-match-p "\\`[0-9.]+\\'" result)))
         (flag-code (pcase (niori-fhir--value record 'flag)
                      ("high" "H")
                      ("low" "L")
                      ("critical" "A")
                      (_ nil))))
    (append
     '((resourceType . "Observation") (status . "final"))
     `((code . ((text . ,(or (niori-fhir--value record 'name) "")))))
     (when (niori-fhir--value record 'date)
       `((effectiveDateTime . ,(plist-get record 'date))))
     (cond (numeric
            `((valueQuantity . ((value . ,(string-to-number result))
                                (unit . ,(or (niori-fhir--value record 'unit)
                                             ""))))))
           (result
            `((valueString . ,result))))
     (when (niori-fhir--value record 'reference_range)
       `((referenceRange . (((text . ,(plist-get record
                                                'reference_range)))))))
     (when flag-code
       `((interpretation . (((coding . (((code . ,flag-code))))))))))))

(defun niori-fhir--immunization (record)
  "FHIR Immunization alist for a vaccination RECORD."
  (append
   '((resourceType . "Immunization") (status . "completed"))
   `((vaccineCode . ((text . ,(or (niori-fhir--value record 'vaccine)
                                  "")))))
   (when (niori-fhir--value record 'date)
     `((occurrenceDateTime . ,(plist-get record 'date))))
   (when (niori-fhir--value record 'lot)
     `((lotNumber . ,(plist-get record 'lot))))
   (when (niori-fhir--value record 'route)
     `((route . ((text . ,(plist-get record 'route))))))
   (when (niori-fhir--value record 'site)
     `((site . ((text . ,(plist-get record 'site))))))
   (when (niori-fhir--value record 'provider)
     `((performer
        . (((actor . ((display . ,(plist-get record 'provider)))))))))))

(defun niori-fhir-resource (table record)
  "Convert RECORD of TABLE to a simplified FHIR R4 resource (alist)."
  (pcase table
    ('medications (niori-fhir--medication record))
    ('visits (niori-fhir--encounter record))
    ('labs (niori-fhir--observation record))
    ('vaccinations (niori-fhir--immunization record))
    (_ (error "No FHIR mapping for table %s" table))))

(defun niori-fhir-bundle (table)
  "FHIR collection Bundle (alist) with every record of TABLE."
  `((resourceType . "Bundle")
    (type . "collection")
    (entry . ,(mapcar (lambda (record)
                        `((resource . ,(niori-fhir-resource table record))))
                      (niori-store-select
                       table :order (or (niori-module-get table :order)
                                        "id"))))))

;;;###autoload
(defun niori-fhir-export (table &optional file)
  "Export every record of TABLE to FILE as a FHIR JSON bundle."
  (interactive
   (let ((table (niori--read-module)))
     (list table
           (read-file-name "Export FHIR JSON to: " nil nil nil
                           (format "%s-fhir.json" table)))))
  (let* ((file (or file (niori--export-file table "json")))
         (content (niori--json-pretty
                   (json-encode (niori-fhir-bundle table)))))
    (write-region content nil file)
    (niori-store--secure-file file)
    (message "niori: FHIR bundle with %d entries written to %s"
             (niori-store-count table) file)
    (unless noninteractive (find-file file))
    file))

;;;; Retrieval

(defun niori-fhir--bearer (host)
  "Bearer token for HOST from `auth-source', or nil."
  (let ((source (car (auth-source-search :host host :max 1
                                         :require '(:secret)))))
    (when source
      (let ((secret (plist-get source :secret)))
        (when (functionp secret)
          (funcall secret))))))

(defun niori-fhir-fetch (path)
  "GET PATH from `niori-fhir-server-url'; return the parsed JSON.
The bearer token is read from `auth-source'."
  (interactive (list (read-string "FHIR path: " "/Patient")))
  (unless niori-fhir-server-url
    (user-error "Set `niori-fhir-server-url' first"))
  (let* ((url (concat niori-fhir-server-url path))
         (token (niori-fhir--bearer (url-host (url-generic-parse-url url))))
         (url-request-method "GET")
         (url-request-extra-headers
          (append '(("Accept" . "application/fhir+json"))
                  (when token
                    `(("Authorization" . ,(concat "Bearer " token)))))))
    (let ((buffer (url-retrieve-synchronously url)))
      (unless buffer
        (user-error "FHIR request to %s failed" url))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (or (bound-and-true-p url-http-end-of-headers)
                           (point-min)))
            (json-read))
        (kill-buffer buffer)))))

(provide 'niori-fhir)

;;; niori-fhir.el ends here
