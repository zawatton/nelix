;;; nelix-state-test.el --- ERT tests for nelix-state  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-D sub-task D coverage for the persistent KV layer.  Tests
;; bind `nelix-state-file' to a tmp path so the real
;; ~/.local/state/nelix/state.json is never touched, and
;; `cl-letf' the dispatch fluid for the mock-only round-trip cases.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-state)

(defun nelix-state-test--with-tmp-file (body-fn)
  "Run BODY-FN with `nelix-state-file' bound to a tmp path.
Cleans up both the file and the in-process cache afterwards."
  (let* ((tmp (make-temp-file "nelix-state-test-" nil ".json"))
         (nelix-state-file tmp)
         (nelix-state--cache 'unloaded)
         (nelix-state--loaded-from nil))
    (unwind-protect
        (progn
          ;; make-temp-file creates an empty file; the loader treats an
          ;; empty body as "no state" so no special handling needed.
          (delete-file tmp)
          (funcall body-fn tmp))
      (when (file-exists-p tmp) (delete-file tmp)))))

;;;; --- ERT 17 — round-trip + persistence -----------------------------------

(ert-deftest nelix-state-test-roundtrip-and-persistence ()
  "Put / get / delete round-trip survives a fresh-from-disk reload.

Verifies the JSON serialiser + parser pair: writing a value,
clearing the in-process cache (= simulating an Emacs restart),
then reading should yield the same value."
  (nelix-state-test--with-tmp-file
   (lambda (path)
     ;; First "session" — write three entries across two namespaces.
     (nelix-state-put "nelix-core:test-a" "k1" '(:deps (dash s) :status :hit-pkg-el))
     (nelix-state-put "nelix-core:test-a" "k2" 42)
     (nelix-state-put "nelix-core:test-b" "k3" "hello")
     (should (equal (nelix-state-get "nelix-core:test-a" "k1")
                    '(:deps (dash s) :status :hit-pkg-el)))
     (should (equal (nelix-state-get "nelix-core:test-a" "k2") 42))
     (should (equal (nelix-state-get "nelix-core:test-b" "k3") "hello"))
     (should (file-exists-p path))
     ;; Simulate a fresh Emacs by forcing a reload from disk.
     (setq nelix-state--cache 'unloaded
           nelix-state--loaded-from nil)
     ;; Reads after the simulated restart still see the values.
     (should (equal (nelix-state-get "nelix-core:test-a" "k1")
                    '(:deps (dash s) :status :hit-pkg-el)))
     (should (equal (nelix-state-get "nelix-core:test-a" "k2") 42))
     ;; Delete + clear semantics.
     (nelix-state-delete "nelix-core:test-a" "k1")
     (should (null (nelix-state-get "nelix-core:test-a" "k1")))
     (should (equal (nelix-state-get "nelix-core:test-a" "k2") 42))
     (nelix-state-clear "nelix-core:test-a")
     (should (null (nelix-state-get "nelix-core:test-a" "k2")))
     ;; Other namespace untouched.
     (should (equal (nelix-state-get "nelix-core:test-b" "k3") "hello"))
     (nelix-state-clear-all)
     (should (null (nelix-state-get "nelix-core:test-b" "k3"))))))

;;;; --- ERT 18 — TTL expiry --------------------------------------------------

(ert-deftest nelix-state-test-ttl-expires-entries ()
  "TTL-expired entries are dropped on read; non-TTL entries persist.

Combines wall-clock float-time mocking with a real disk path so the
TTL math is exercised end-to-end without sleeping in the test."
  (nelix-state-test--with-tmp-file
   (lambda (_path)
     (let ((now 1000.0))
       (cl-letf (((symbol-function 'float-time)
                  (lambda (&optional _t) now)))
         ;; t=1000: write an entry with a 60-second TTL and one without.
         (nelix-state-put "nelix-core:ttl" "short" "boom" 60)
         (nelix-state-put "nelix-core:ttl" "forever" "stable")
         (should (equal (nelix-state-get "nelix-core:ttl" "short")
                        "boom"))
         (should (equal (nelix-state-get "nelix-core:ttl" "forever")
                        "stable"))
         ;; t=1059: still within TTL.
         (setq now 1059.0)
         (should (equal (nelix-state-get "nelix-core:ttl" "short")
                        "boom"))
         ;; t=1061: TTL expired; entry should drop.
         (setq now 1061.0)
         (should (null (nelix-state-get "nelix-core:ttl" "short")))
         (should (equal (nelix-state-get "nelix-core:ttl" "forever")
                        "stable")))))))

;;;; --- bonus: keys / clear scope -------------------------------------------

(ert-deftest nelix-state-test-keys-skips-expired ()
  "`nelix-state-keys' must hide expired entries from callers."
  (nelix-state-test--with-tmp-file
   (lambda (_path)
     (let ((now 0.0))
       (cl-letf (((symbol-function 'float-time)
                  (lambda (&optional _t) now)))
         (nelix-state-put "nelix-core:keys" "a" 1 10)
         (nelix-state-put "nelix-core:keys" "b" 2)        ; no TTL
         (nelix-state-put "nelix-core:keys" "c" 3 1000)
         (setq now 50.0)                                      ; "a" expired
         (let ((keys (sort (copy-sequence
                            (nelix-state-keys "nelix-core:keys"))
                           #'string<)))
           (should (equal keys '("b" "c")))))))))

(ert-deftest nelix-state-test-encode-uses-compat-json-serializer ()
  "`nelix-state--encode' must not call `json-serialize' directly."
  (let ((seen nil))
    (cl-letf (((symbol-function 'nelix-compat-json-serialize)
               (lambda (obj)
                 (setq seen obj)
                 "encoded")))
      (should (equal "encoded"
                     (nelix-state--encode
                      '(("ns" . (("key" :value (:deps (dash))
                                  :expires-at nil)))))))
      (should (hash-table-p seen))
      (let* ((inner (gethash "ns" seen))
             (entry (and (hash-table-p inner)
                         (gethash "key" inner))))
        (should (hash-table-p inner))
        (should (hash-table-p entry))
        (should (equal "(:deps (dash))" (gethash "value" entry)))
        (should (null (gethash "expires-at" entry)))))))

(ert-deftest nelix-state-test-mock-dispatch-fluid ()
  "`nelix-core--call-state-fn' can be `cl-letf'-rebound for mocking.

This is the contract nelix-core.el / nelix-emacs.el rely on for
their Phase 4-D test refactors — the public API funnels through the
fluid so a single rebind isolates an entire test from disk I/O."
  (let ((calls nil)
        (store (make-hash-table :test 'equal)))
    (cl-letf (((symbol-value 'nelix-core--call-state-fn)
               (lambda (op &rest args)
                 (push (cons op args) calls)
                 (pcase op
                   (:get (gethash (cons (nth 0 args) (nth 1 args)) store))
                   (:put (puthash (cons (nth 0 args) (nth 1 args))
                                  (nth 2 args) store)
                         (nth 2 args))
                   (:clear t)
                   (_ nil)))))
      (nelix-state-put "ns" "k" "v")
      (should (equal (nelix-state-get "ns" "k") "v"))
      (nelix-state-clear "ns"))
    (should (= (length calls) 3))
    (should (equal (caar (last calls)) :put))))

(provide 'nelix-state-test)
;;; nelix-state-test.el ends here
