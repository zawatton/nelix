;;; nelix-cli-verdict-exit-test.el --- verdict exit codes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `lock-check' answers one question: does the lock still match the
;; manifest?  It used to report drift in its JSON and exit 0 anyway, so a
;; caller doing the obvious thing -- run it, test $? -- was told the lock
;; was fine while "ok":null sat in output it never read.  That is the same
;; shape of mistake as trusting the exit code of a pipeline whose last
;; stage always succeeds.
;;
;; Exit 1 and exit 2 mean different things here and both are pinned: 2 is
;; "the command failed", 1 is "the command worked and the answer is no".

;;; Code:

(require 'ert)
(require 'nelix-cli)

(ert-deftest nelix-cli-verdict-exit-test-drift-is-non-zero ()
  "A negative lock-check verdict exits non-zero."
  (should (= 1 (nelix-cli--verdict-exit-code "lock-check" '(:ok nil))))
  ;; `ok' is nil-by-absence just as often as it is an explicit nil.
  (should (= 1 (nelix-cli--verdict-exit-code "lock-check" '(:expected "a" :actual "b")))))

(ert-deftest nelix-cli-verdict-exit-test-match-is-zero ()
  "A matching lock exits 0."
  (should (= 0 (nelix-cli--verdict-exit-code "lock-check" '(:ok t)))))

(ert-deftest nelix-cli-verdict-exit-test-other-commands-unaffected ()
  "Commands that report rather than judge keep exiting 0.

`audit' and `plan' also carry an `:ok', and callers -- the packaged
gates among them -- run them for the report.  Turning those into
failures is a separate decision, so the verdict list stays explicit."
  (dolist (command '("audit" "plan" "list" "upgrade-plan"))
    (should (= 0 (nelix-cli--verdict-exit-code command '(:ok nil))))))

(ert-deftest nelix-cli-verdict-exit-test-string-result-is-zero ()
  "A result that is not a plist does not accidentally mean failure.

Several commands answer with a string or a list of strings; reading
`:ok' out of those would make them exit 1 for no reason."
  (should (= 0 (nelix-cli--verdict-exit-code "lock-check" "some text"))))

(ert-deftest nelix-cli-verdict-exit-test-absent-verdict-is-non-zero ()
  "No verdict at all is reported as failure, not as success.

A nil result carries no `:ok', so there is nothing saying the lock
matches.  Exiting 0 there would be the very claim this change exists to
stop making -- the caller would read success from a run that verified
nothing."
  (should (= 1 (nelix-cli--verdict-exit-code "lock-check" nil))))

(provide 'nelix-cli-verdict-exit-test)
;;; nelix-cli-verdict-exit-test.el ends here
