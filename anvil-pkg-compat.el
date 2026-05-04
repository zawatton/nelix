;;; anvil-pkg-compat.el --- Emacs / NeLisp standalone portability layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Thin shim so anvil-pkg can run under either /Emacs/ (the historic
;; host) or /NeLisp standalone/ (= the Rust runtime + its Layer 2
;; packages: nelisp-process / nelisp-json / nelisp-emacs-compat).
;;
;; The shim deliberately stays dependency-free at load time and only
;; requires its backend implementations lazily, so loading anvil-pkg
;; on bare NeLisp does not error out at file load.
;;
;; Runtime detection happens once at load via `fboundp' probes; the
;; chosen implementations are stashed in defvars so tests can override
;; the dispatch.
;;
;; Public surface (all `anvil-pkg-compat-' prefixed):
;;   call-process            - run cmd, return (:exit :stdout :stderr)
;;   write-file              - dump string to path
;;   read-file               - read path -> string
;;   make-temp-file          - unique writable path under TMPDIR
;;   make-directory          - mkdir -p
;;   delete-file-quietly     - rm -f, no error on miss
;;   file-exists-p           - existence probe
;;   executable-find         - PATH lookup
;;   getenv                  - environment variable
;;   http-get                - synchronous HTTP GET (Emacs only in Phase 4-C)
;;   json-parse              - JSON string -> alist tree (Phase 1 schema)
;;   string-trim             - trim ASCII whitespace
;;   define-error-symbol     - install (sym 'error-conditions . msg) properties

;;; Code:

;; `declare-function' is a byte-compiler hint in Emacs and a no-op
;; at runtime; NeLisp does not ship it.  Stub it so this file loads
;; on bare NeLisp standalone (Phase 8.x Rust evaluator).
(unless (fboundp 'declare-function)
  (defmacro declare-function (&rest _ignored) nil))

;; --- declare-function shims for NeLisp Layer-2 dispatch targets --
;; These functions only exist when nelisp-process / nelisp-json /
;; nelisp-emacs-compat are loaded (= NeLisp standalone runtime).
;; The byte-compiler still needs to know they take `&rest', so
;; declare them here without committing to an arity.
(declare-function nelisp-syscall-getenv         "ext:nelisp-runtime" t t)
(declare-function nelisp-syscall-getpid         "ext:nelisp-runtime" t t)
(declare-function nelisp-call-process           "ext:nelisp-process" t t)
(declare-function nelisp-json-parse-string      "ext:nelisp-json"    t t)
(declare-function nelisp-ec-getenv              "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-executable-find     "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-file-exists-p       "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-make-directory      "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-delete-file         "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-insert-file-contents "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-write-region        "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-generate-new-buffer "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-kill-buffer         "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-buffer-string       "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-with-current-buffer "ext:nelisp-emacs-compat" t t)

(defvar anvil-pkg-compat--nelisp-runtime-p
  (fboundp 'nelisp-call-process)
  "Non-nil when nelisp-process is loaded — choose Layer 2 backends.

Defined as a defvar (not defconst) so tests can override the value
via `cl-letf' / `let'.  Production code should consult
`anvil-pkg-compat-runtime' rather than reading this variable
directly so callers (e.g. anvil-pkg.el's :async branch) get a
single, mockable runtime decision point.")

(defun anvil-pkg-compat-runtime ()
  "Return the active runtime symbol: `nelisp' or `emacs'.
Sole authority for runtime branching outside this file.  Tests
can override via `cl-letf' on this function (preferred) or by
let-binding `anvil-pkg-compat--nelisp-runtime-p'."
  (if anvil-pkg-compat--nelisp-runtime-p 'nelisp 'emacs))

;;;; --- environment / path helpers -------------------------------------------

(defun anvil-pkg-compat-getenv (var &optional default)
  "Return env var VAR or DEFAULT.
Tries Emacs `getenv', then NeLisp Layer-2 alternatives."
  (let ((v (cond
            ((fboundp 'getenv) (getenv var))
            ((fboundp 'nelisp-syscall-getenv) (nelisp-syscall-getenv var))
            ((fboundp 'nelisp-ec-getenv) (nelisp-ec-getenv var))
            (t nil))))
    (or v default)))

(defun anvil-pkg-compat-executable-find (cmd)
  "Find executable CMD on PATH; return absolute path or nil."
  (cond
   ((fboundp 'executable-find) (executable-find cmd))
   ((fboundp 'nelisp-ec-executable-find) (nelisp-ec-executable-find cmd))
   (t nil)))

;;;; --- filesystem ----------------------------------------------------------

(defun anvil-pkg-compat-file-exists-p (path)
  "Return non-nil if PATH exists."
  (cond
   ((fboundp 'file-exists-p) (file-exists-p path))
   ((fboundp 'nelisp-ec-file-exists-p) (nelisp-ec-file-exists-p path))
   (t nil)))

(defun anvil-pkg-compat-make-directory (path &optional parents)
  "Create directory PATH; non-nil PARENTS makes -p style."
  (cond
   ((fboundp 'make-directory) (make-directory path (or parents t)))
   ((fboundp 'nelisp-ec-make-directory) (nelisp-ec-make-directory path (or parents t)))
   (t (error "no make-directory implementation available"))))

(defun anvil-pkg-compat-delete-file-quietly (path)
  "Delete PATH if it exists; ignore failures."
  (when (anvil-pkg-compat-file-exists-p path)
    (cond
     ((fboundp 'delete-file)
      (condition-case _ (delete-file path) (error nil)))
     ((fboundp 'nelisp-ec-delete-file)
      (condition-case _ (nelisp-ec-delete-file path) (error nil))))))

(defun anvil-pkg-compat-read-file (path)
  "Return the entire contents of PATH as a string."
  (cond
   ((and (not anvil-pkg-compat--nelisp-runtime-p)
         (fboundp 'with-temp-buffer)
         (fboundp 'insert-file-contents))
    ;; Emacs path
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string)))
   ((fboundp 'nelisp-ec-insert-file-contents)
    ;; NeLisp Layer-2 path
    (let ((buf (nelisp-ec-generate-new-buffer "*anvil-pkg-read*")))
      (unwind-protect
          (progn
            (nelisp-ec-with-current-buffer buf
              (nelisp-ec-insert-file-contents path)
              (nelisp-ec-buffer-string)))
        (when (fboundp 'nelisp-ec-kill-buffer)
          (nelisp-ec-kill-buffer buf)))))
   (t (error "no read-file backend available for %S" path))))

(defun anvil-pkg-compat-write-file (path content)
  "Write CONTENT (string) to PATH, overwriting."
  (cond
   ((and (not anvil-pkg-compat--nelisp-runtime-p)
         (fboundp 'with-temp-file))
    (with-temp-file path
      (insert content)))
   ((fboundp 'nelisp-ec-write-region)
    ;; nelisp-ec-write-region is the Layer-2 equivalent
    (nelisp-ec-write-region content nil path nil 'silent))
   (t (error "no write-file backend available for %S" path))))

(defun anvil-pkg-compat-make-temp-file (prefix)
  "Create a unique writable file with PREFIX under TMPDIR; return path."
  (cond
   ((fboundp 'make-temp-file) (make-temp-file prefix))
   (t
    (let* ((tmpdir (or (anvil-pkg-compat-getenv "TMPDIR") "/tmp"))
           (pid (cond ((fboundp 'emacs-pid) (emacs-pid))
                      ((fboundp 'nelisp-syscall-getpid) (nelisp-syscall-getpid))
                      (t 0)))
           (counter (abs (random)))
           (path (format "%s/%s%d-%d" tmpdir prefix pid counter)))
      (anvil-pkg-compat-write-file path "")
      path))))

;;;; --- subprocess -----------------------------------------------------------

(defun anvil-pkg-compat-call-process (program args)
  "Run PROGRAM with string-list ARGS synchronously.
Returns plist (:exit INT :stdout STRING :stderr STRING).

Emacs path uses a temp buffer for stdout (= the call-process
contract Emacs guarantees) and a temp file for stderr.  NeLisp
path uses two temp files since nelisp-call-process accepts string
filenames as destinations.  Either way the caller sees the same
plist."
  (cond
   ((and (not anvil-pkg-compat--nelisp-runtime-p)
         (fboundp 'generate-new-buffer)
         (fboundp 'call-process))
    (anvil-pkg-compat--call-process-emacs program args))
   ((fboundp 'nelisp-call-process)
    (anvil-pkg-compat--call-process-nelisp program args))
   (t (error "no call-process backend available"))))

(defun anvil-pkg-compat--call-process-emacs (program args)
  "Emacs backend for `anvil-pkg-compat-call-process'.
Buffer for stdout, temp file for stderr."
  (let ((stdout-buf (generate-new-buffer " *anvil-pkg-stdout*"))
        (stderr-file (anvil-pkg-compat-make-temp-file "anvil-pkg-stderr-")))
    (unwind-protect
        (let ((exit (apply #'call-process
                           program nil
                           (list stdout-buf stderr-file)
                           nil args)))
          (list :exit (if (numberp exit) exit -1)
                :stdout (with-current-buffer stdout-buf (buffer-string))
                :stderr (anvil-pkg-compat-read-file stderr-file)))
      (when (and (fboundp 'buffer-live-p) (buffer-live-p stdout-buf))
        (kill-buffer stdout-buf))
      (anvil-pkg-compat-delete-file-quietly stderr-file))))

(defun anvil-pkg-compat--call-process-nelisp (program args)
  "NeLisp backend for `anvil-pkg-compat-call-process'.
nelisp-call-process accepts string filenames in the destination
cons, so we use two temp files and read them back."
  (let ((stdout-file (anvil-pkg-compat-make-temp-file "anvil-pkg-stdout-"))
        (stderr-file (anvil-pkg-compat-make-temp-file "anvil-pkg-stderr-")))
    (unwind-protect
        (let ((exit (apply #'nelisp-call-process
                           program nil
                           (list stdout-file stderr-file)
                           nil args)))
          (list :exit (if (numberp exit) exit -1)
                :stdout (anvil-pkg-compat-read-file stdout-file)
                :stderr (anvil-pkg-compat-read-file stderr-file)))
      (anvil-pkg-compat-delete-file-quietly stdout-file)
      (anvil-pkg-compat-delete-file-quietly stderr-file))))

;;;; --- JSON -----------------------------------------------------------------

(defun anvil-pkg-compat-json-parse (str)
  "Parse JSON STR into Elisp tree.  Empty / blank input returns nil.
Object -> alist, array -> list, null/false -> nil."
  (let ((trimmed (anvil-pkg-compat-string-trim (or str ""))))
    (when (> (length trimmed) 0)
      (cond
       ((fboundp 'json-parse-string)
        (json-parse-string trimmed
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object nil))
       ((fboundp 'nelisp-json-parse-string)
        (nelisp-json-parse-string trimmed
                                  :object-type 'alist
                                  :array-type 'list
                                  :null-object nil
                                  :false-object nil))
       (t (error "no JSON parser backend available"))))))

;;;; --- string utility -------------------------------------------------------

(defun anvil-pkg-compat-string-trim (str)
  "Remove leading and trailing ASCII whitespace from STR."
  (cond
   ((fboundp 'string-trim) (string-trim str))
   (t
    ;; Implementation uses only `substring' + `length' + prefix
    ;; comparison.  Avoids `aref' (not yet a NeLisp Rust builtin)
    ;; and `?\s' (not in NeLisp's reader) so the same code runs on
    ;; both Emacs and NeLisp standalone.
    (let ((s (or str "")))
      (while (and (> (length s) 0)
                  (or (string-prefix-p " "  s)
                      (string-prefix-p "\t" s)
                      (string-prefix-p "\n" s)
                      (string-prefix-p "\r" s)))
        (setq s (substring s 1)))
      (while (let ((n (length s)))
               (and (> n 0)
                    (let ((tail (substring s (1- n) n)))
                      (or (string-equal tail " ")
                          (string-equal tail "\t")
                          (string-equal tail "\n")
                          (string-equal tail "\r")))))
        (setq s (substring s 0 (1- (length s)))))
      s))))

;;;; --- HTTP -----------------------------------------------------------------

;; `url-retrieve-synchronously' is autoloaded from the built-in `url'
;; package; declare it so byte-compile does not complain when this
;; file is compiled without `url' having been loaded yet.
(declare-function url-retrieve-synchronously "url" t t)

(defun anvil-pkg-compat-http-get (url &optional timeout)
  "Synchronously fetch URL.  TIMEOUT defaults to 5 seconds.

Returns plist (:status INT :body STRING).  Signals
`anvil-pkg-http-not-supported' on NeLisp until Phase 5 lands an
HTTP backend.  Network errors / non-2xx responses return :status
N (the actual code or 0 on connection failure) with :body empty.

Phase 4-C: Emacs implementation uses `url-retrieve-synchronously'
and parses the HTTP status line out of the response buffer's first
line (we do not rely on `url-http-response-status' because the
buffer may not have full HTTP metadata in some Emacs versions)."
  (pcase (anvil-pkg-compat-runtime)
    ('emacs
     (anvil-pkg-compat--http-get-emacs url (or timeout 5)))
    ('nelisp
     (signal 'anvil-pkg-http-not-supported
             (list (format "anvil-pkg-compat-http-get: NeLisp HTTP backend not yet implemented (url=%s)"
                           url))))
    (_
     (signal 'anvil-pkg-http-not-supported
             (list (format "anvil-pkg-compat-http-get: no backend for runtime %S"
                           (anvil-pkg-compat-runtime)))))))

(defun anvil-pkg-compat--http-get-emacs (url timeout)
  "Emacs backend for `anvil-pkg-compat-http-get'.

Wraps `url-retrieve-synchronously' with a TIMEOUT override and
parses the HTTP status line from the buffer's first line.  Returns
plist (:status INT :body STRING).  On any error returns (:status 0
:body \"\") so callers do not need to wrap in `condition-case'."
  (require 'url)
  (defvar url-show-status)
  (let ((url-show-status nil)
        (status 0)
        (body ""))
    ;; Reference url-show-status so the binding is not flagged as
    ;; unused — `url' reads it dynamically inside
    ;; `url-retrieve-synchronously'.
    (ignore url-show-status)
    (condition-case _err
        (let ((buf (url-retrieve-synchronously url t t timeout)))
          (when (and buf (buffer-live-p buf))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  ;; Parse "HTTP/1.x NNN ..." status line from first
                  ;; line of the buffer.
                  (let ((line-end (line-end-position)))
                    (when (re-search-forward
                           "\\`HTTP/[0-9.]+ \\([0-9]+\\)" line-end t)
                      (setq status (string-to-number (match-string 1)))))
                  ;; Body is everything after the blank line that
                  ;; terminates HTTP headers (CRLF CRLF or LF LF).
                  (goto-char (point-min))
                  (when (re-search-forward "\r?\n\r?\n" nil t)
                    (setq body (buffer-substring-no-properties
                                (point) (point-max)))))
              (kill-buffer buf))))
      (error
       ;; Connection failure / timeout / DNS — degrade to status 0.
       (setq status 0
             body "")))
    (list :status status :body body)))

;;;; --- error symbols --------------------------------------------------------

(defun anvil-pkg-compat-define-error-symbol (sym message &optional parent)
  "Install error-conditions / error-message on SYM.
Functional equivalent of `define-error', but works without it
(directly via `put') so it functions on NeLisp standalone too."
  (when (fboundp 'put)
    (let ((parent-conds (and parent
                             (fboundp 'get)
                             (get parent 'error-conditions)))
          (existing (and (fboundp 'get) (get sym 'error-conditions))))
      (put sym 'error-conditions
           (delete-dups
            (append (list sym) parent-conds existing
                    (unless parent-conds '(error)))))
      (put sym 'error-message message)))
  sym)

;; Phase 4-C error symbol installed at load time: callers (anvil-pkg-emacs.el)
;; can `signal' it without first requiring anvil-pkg.
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-http-not-supported
                                      "HTTP not supported on this runtime")

(provide 'anvil-pkg-compat)
;;; anvil-pkg-compat.el ends here
