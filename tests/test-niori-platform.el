;;; test-niori-platform.el --- ERT tests for niori-platform.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'niori-test-helper)

(ert-deftest niori-platform-register-module ()
  "Modules register, replace and report their properties."
  (let ((niori--modules nil))
    (should (eq (niori-register-module 'one :title "One") 'one))
    (should (equal (niori-modules) '(one)))
    (should (equal (niori-module-get 'one :title) "One"))
    (should (null (niori-module-get 'one :absent)))
    ;; Re-registering replaces rather than duplicates.
    (niori-register-module 'one :title "Uno" :version "2")
    (should (equal (niori-modules) '(one)))
    (should (equal (niori-module-get 'one :title) "Uno"))
    (should (equal (niori-module-get 'one :version) "2"))
    ;; Registration order is preserved.
    (niori-register-module 'two :title "Two")
    (should (equal (niori-modules) '(one two)))))

(ert-deftest niori-platform-service-lookup ()
  "Services register and are found through `niori-lookup'."
  (let ((niori--services nil)
        (called nil))
    (should (null (niori-lookup 'greeter)))
    (niori-register-service 'greeter (lambda (&rest _) (push :called called)))
    (should (functionp (niori-lookup 'greeter)))
    (funcall (niori-lookup 'greeter))
    (should (eq (car called) :called))
    ;; Replacement wins.
    (niori-register-service 'greeter #'ignore)
    (should (eq (niori-lookup 'greeter) #'ignore))))

(ert-deftest niori-platform-commands ()
  "Commands register and `niori-run-command' dispatches to them."
  (let ((niori--commands nil)
        (ran nil))
    (niori-register-command 'poke (lambda () (setq ran t)) :title "Poke")
    (should (niori-command 'poke))
    (should (equal (niori-commands) '(poke)))
    (should (equal (cdr (niori-command 'poke)) '(:title "Poke")))
    (niori-run-command 'poke)
    (should (eq ran t))
    (should-error (niori-run-command 'nonexistent))))

(ert-deftest niori-platform-date-helpers ()
  "Date helpers produce and shift ISO dates."
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                          (niori--today)))
  (should (equal (niori--date+ 0) (niori--today)))
  ;; Date arithmetic crosses month boundaries.
  (cl-letf (((symbol-function 'current-time)
             (lambda () (encode-time 0 0 0 31 1 2026))))
    (should (equal (niori--date+ 1) "2026-02-01"))
    (should (equal (niori--date+ 60) "2026-04-01"))))

(provide 'test-niori-platform)

;;; test-niori-platform.el ends here
