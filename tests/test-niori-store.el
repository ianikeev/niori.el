;;; test-niori-store.el --- ERT tests for niori-store.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'niori-test-helper)

(ert-deftest niori-store-migration-creates-tables ()
  "Opening a fresh database applies migration 1 to every module table."
  (niori-with-test-db
    (dolist (table '(medications visits labs vaccinations revisions))
      (should (= (niori-store-count table) 0)))))


(ert-deftest niori-store-crud-roundtrip ()
  "Insert, fetch, update and delete a medication."
  (niori-with-test-db
    (let ((id (niori-store-insert
               'medications '((name . "Aspirin")
                              (dosage . "100 mg")
                              (active . 1)))))
      (should (numberp id))
      (let ((record (niori-store-get 'medications id)))
        (should (equal (plist-get record 'name) "Aspirin"))
        (should (equal (plist-get record 'dosage) "100 mg"))
        (should (equal (plist-get record 'active) 1))
        ;; Timestamps are set by the store.
        (should (plist-get record 'created_at))
        (should (plist-get record 'updated_at)))
      ;; Update round-trips.
      (niori-store-update 'medications id '((dosage . "200 mg")))
      (let ((record (niori-store-get 'medications id)))
        (should (equal (plist-get record 'dosage) "200 mg"))
        (should (equal (plist-get record 'name) "Aspirin")))
      ;; Delete really removes.
      (niori-store-delete 'medications id)
      (should (null (niori-store-get 'medications id)))
      (should (= (niori-store-count 'medications) 0)))))

(ert-deftest niori-store-select-where ()
  "Parameterised selection filters by SQL conditions."
  (niori-with-test-db
    (niori-store-insert 'visits '((date . "2026-11-01")
                                  (doctor . "House")
                                  (reason . "Check-up")))
    (niori-store-insert 'visits '((date . "2026-12-24")
                                  (doctor . "Wilson")
                                  (reason . "Follow-up")))
    (should (= (niori-store-count 'visits) 2))
    (let ((upcoming (niori-store-select 'visits
                                        :where "date > ?"
                                        :params (list "2026-12-01")
                                        :order "date")))
      (should (= (length upcoming) 1))
      (should (equal (plist-get (car upcoming) 'doctor) "Wilson")))
    ;; Injection safety: values are bound, not interpolated.
    (let ((sneaky (niori-store-select 'visits
                                      :where "reason = ?"
                                      :params (list "x' OR '1'='1"))))
      (should (null sneaky)))))

(ert-deftest niori-store-revisions-snapshot ()
  "Updates and deletes leave revision snapshots behind."
  (niori-with-test-db
    (let ((id (niori-store-insert 'medications
                                  '((name . "Metformin")
                                    (dosage . "500 mg")))))
      (should (null (niori-store-record-revisions 'medications id)))
      (niori-store-update 'medications id '((dosage . "1000 mg")))
      (let ((revisions (niori-store-record-revisions 'medications id)))
        (should (= (length revisions) 1))
        ;; The snapshot preserves the *previous* state.
        (should (string-match-p "500 mg"
                                (plist-get (car revisions) 'snapshot)))
        (should (plist-get (car revisions) 'changed_at)))
      (niori-store-delete 'medications id)
      (let ((revisions (niori-store-record-revisions 'medications id)))
        (should (= (length revisions) 2))))))

(ert-deftest niori-store-revisions-can-be-disabled ()
  "No snapshots are taken when `niori-store-keep-revisions' is nil."
  (niori-with-test-db
    (let ((niori-store-keep-revisions nil))
      (let ((id (niori-store-insert 'medications '((name . "Ibuprofen")))))
        (niori-store-update 'medications id '((dosage . "400 mg")))
        (should (null (niori-store-record-revisions 'medications id)))))))

(ert-deftest niori-store-unknown-table-errors ()
  "Unknown tables are rejected before any SQL runs."
  (niori-with-test-db
    (should-error (niori-store-insert 'nosuchtable '((a . 1))))))

;;;; File permissions

(ert-deftest niori-store-database-is-private ()
  "The database file is readable by its owner only."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (should (equal 0 (logand (file-modes (niori-store--data-file)) #o077)))
    ;; ...and so is the directory holding it, even when it already existed.
    (should (equal 0 (logand (file-modes (niori-store--data-directory))
                             #o077)))))

(ert-deftest niori-store-secures-sidecar-files ()
  "Journal, WAL and shared-memory files beside the database become private."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let ((db (niori-store--data-file))
          (sidecars '("-journal" "-wal" "-shm")))
      ;; Pretend an earlier run (or a copy) left them world readable.
      (niori-store-close)
      (dolist (suffix sidecars)
        (with-temp-file (concat db suffix)
          (insert "leftover"))
        (set-file-modes (concat db suffix) #o644))
      (niori-store--secure-database-files)
      (should (equal 0 (logand (file-modes db) #o077)))
      (dolist (suffix sidecars)
        (should (equal 0 (logand (file-modes (concat db suffix)) #o077))))
      (dolist (suffix sidecars)
        (ignore-errors (delete-file (concat db suffix)))))))

(ert-deftest niori-store-transaction-journal-is-private ()
  "The journal SQLite writes during a transaction is owner-only."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let ((journal (concat (niori-store--data-file) "-journal")))
      (niori-store--exec "BEGIN IMMEDIATE")
      (niori-store--exec
       "INSERT INTO visits (date, created_at, updated_at) VALUES (?, ?, ?)"
       (list "2026-12-01" "x" "x"))
      (unwind-protect
          (progn
            (should (file-exists-p journal))
            (should (equal 0 (logand (file-modes journal) #o077))))
        (niori-store--exec "ROLLBACK")))))

(ert-deftest niori-store-private-umask-restores-itself ()
  "The narrowed umask makes new files private and is restored afterwards."
  (skip-unless niori-test--posix-modes-p)
  (let ((file (make-temp-name
               (expand-file-name "niori-umask-" temporary-file-directory)))
        (before (default-file-modes)))
    (unwind-protect
        (progn
          (niori-store--with-private-umask
            (with-temp-file file (insert "x"))
            (should (= 0 (logand (file-modes file) #o077))))
          ;; Restored even though the macro ran an unwind-protect.
          (should (equal before (default-file-modes))))
      (ignore-errors (delete-file file)))))

(ert-deftest niori-store-private-umask-restores-on-error ()
  "An error inside the macro still restores the previous file modes."
  (let ((before (default-file-modes)))
    (should-error (niori-store--with-private-umask (error "boom")))
    (should (equal before (default-file-modes)))))

;;;; Platform behaviour

(ert-deftest niori-store-mode-support-by-platform ()
  "POSIX mode bits are used everywhere except MS-Windows."
  (should (niori-store--modes-supported-p))
  (let ((system-type 'windows-nt))
    (should-not (niori-store--modes-supported-p)))
  (let ((system-type 'ms-dos))
    (should-not (niori-store--modes-supported-p)))
  (let ((system-type 'darwin))
    (should (niori-store--modes-supported-p))))

(ert-deftest niori-store-default-data-directory-is-platform-aware ()
  "The default data directory follows each platform's convention."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "NIORI_DATA_DIR" nil)
    (setenv "XDG_DATA_HOME" nil)
    (setenv "LOCALAPPDATA" nil)
    (should (equal (file-name-as-directory
                    (expand-file-name "niori" "~/.local/share"))
                   (file-name-as-directory
                    (niori-store--default-data-directory))))
    ;; MS-Windows uses the per-user profile directory, not ~/.local.
    (let ((system-type 'windows-nt))
      (setenv "LOCALAPPDATA" "C:/Users/me/AppData/Local")
      (should (equal (file-name-as-directory
                      (expand-file-name "niori" "C:/Users/me/AppData/Local"))
                     (file-name-as-directory
                      (niori-store--default-data-directory)))))
    ;; NIORI_DATA_DIR beats the platform default everywhere.
    (setenv "NIORI_DATA_DIR" "/mnt/records/niori")
    (should (equal (file-name-as-directory "/mnt/records/niori")
                   (file-name-as-directory
                    (niori-store--default-data-directory))))))

(ert-deftest niori-store-tightens-a-loose-data-directory ()
  "A group- or world-readable data directory is tightened on open."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let ((root (niori-store--data-directory)))
      (niori-store-close)
      (set-file-modes root #o755)
      (niori-store-open)
      (should (equal 0 (logand (file-modes root) #o077))))))

(ert-deftest niori-store-respects-deliberate-directory-modes ()
  "With `niori-store-tighten-data-directory' nil your modes are kept."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let ((root (niori-store--data-directory))
          (niori-store-tighten-data-directory nil))
      (niori-store-close)
      (set-file-modes root #o750)
      (niori-store-open)
      (should (equal #o750 (logand (file-modes root) #o777))))))

(ert-deftest niori-store-leaves-modes-alone-on-windows ()
  "On MS-Windows no chmod is attempted, and the database still works."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let ((root (niori-store--data-directory))
          (system-type 'windows-nt))
      (niori-store-close)
      (set-file-modes root #o755)
      (niori-store-open)
      (should (equal #o755 (logand (file-modes root) #o777)))
      (should (numberp (niori-store-insert 'visits
                                           '((date . "2026-11-20"))))))))

(ert-deftest niori-store-advise-policy-keeps-modes-and-advises-once ()
  "The `advise' state leaves the mode alone but reports it, once per session."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let* ((root (niori-store--data-directory))
           (niori-store-tighten-data-directory 'advise)
           (niori-store--advised-about nil)
           (warnings nil))
      (niori-store-close)
      (set-file-modes root #o755)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &optional _level &rest _)
                   (push message warnings))))
        (niori-store-open)
        ;; A reconnect must not nag about the same directory again.
        (niori-store-close)
        (niori-store-open))
      (should (equal #o755 (logand (file-modes root) #o777)))
      (should (= 1 (length warnings)))
      (should (string-match-p "readable by other users" (car warnings)))
      (should (string-match-p "niori-store-secure-data-directory"
                              (car warnings))))))

(ert-deftest niori-store-nil-policy-is-silent ()
  "The nil state leaves the mode alone and says nothing."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let* ((root (niori-store--data-directory))
           (niori-store-tighten-data-directory nil)
           (niori-store--advised-about nil)
           (warnings nil))
      (niori-store-close)
      (set-file-modes root #o755)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (push t warnings))))
        (niori-store-open))
      (should (equal #o755 (logand (file-modes root) #o777)))
      (should-not warnings))))

(ert-deftest niori-store-secure-data-directory-fixes-the-tree ()
  "The command makes the directory, its subdirectories and its files private."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let* ((root (niori-store--data-directory))
           (file (expand-file-name "documents/visits/1/report.pdf" root)))
      (make-directory (file-name-directory file) 'parents)
      (with-temp-file file (insert "PDF"))
      (set-file-modes file #o644)
      (set-file-modes (file-name-directory file) #o755)
      (set-file-modes root #o755)
      (niori-store-secure-data-directory)
      (should (equal 0 (logand (file-modes root) #o077)))
      (should (equal 0 (logand (file-modes (file-name-directory file)) #o077)))
      (should (equal 0 (logand (file-modes file) #o077)))
      (should (equal 0 (logand (file-modes (niori-store--data-file)) #o077))))))

(ert-deftest niori-store-secure-data-directory-skips-symlinks ()
  "A linked document keeps the permissions of the file you own elsewhere."
  (skip-unless niori-test--posix-modes-p)
  (niori-with-test-data-dir
    (let* ((root (niori-store--data-directory))
           (outside (make-temp-file "niori-outside-" nil ".pdf"))
           (link (expand-file-name "documents/linked.pdf" root)))
      (unwind-protect
          (progn
            (with-temp-file outside (insert "PDF"))
            (set-file-modes outside #o644)
            (make-directory (file-name-directory link) 'parents)
            (make-symbolic-link outside link)
            (niori-store-secure-data-directory)
            (should (equal #o644 (logand (file-modes outside) #o777))))
        (ignore-errors (delete-file outside))))))

(provide 'test-niori-store)

;;; test-niori-store.el ends here
