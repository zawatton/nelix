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
;; Runtime detection starts with `fboundp' probes at load time and is
;; refreshed lazily by `anvil-pkg-compat-runtime'.  This lets callers
;; load anvil-pkg before package-split NeLisp backends without getting
;; stuck on the Emacs branch for the rest of the session.
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
;;   http-get                - synchronous HTTP GET (Emacs + NeLisp hook)
;;                              (Phase 4-G: optional :auth-header keyword)
;;   http-get-binary         - synchronous binary HTTP GET (tarball)
;;                              (Emacs + NeLisp hook / curl fallback)
;;                              (Phase 4-G: optional :auth-header keyword)
;;   nelisp backend hooks    - Phase 5 extension points for process / HTTP
;;   process/buffer helpers  - async process metadata + stderr buffers
;;   credential-for-url      - host -> "Bearer TOKEN" / nil (Phase 4-G)
;;   mask-credentials        - redact token-like patterns in strings
;;   json-parse              - JSON string -> alist tree (Phase 1 schema)
;;   json-serialize          - Lisp tree -> JSON string
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
(declare-function nelisp-sys-getenv             "ext:nelisp-sys" t t)
(declare-function nelisp-sys-executable-find    "ext:nelisp-sys" t t)
(declare-function nelisp-call-process           "ext:nelisp-process" t t)
(declare-function nelisp-make-process           "ext:nelisp-process" t t)
(declare-function nelisp-process-current-status "ext:nelisp-process" t t)
(declare-function nelisp-process-exit-code-value "ext:nelisp-process" t t)
(declare-function nelisp-process-get           "ext:nelisp-process" t t)
(declare-function nelisp-process-put           "ext:nelisp-process" t t)
(declare-function nelisp-http-get               "ext:nelisp-network" t t)
(declare-function nelisp-http-get-binary        "ext:nelisp-network" t t)
(declare-function nelisp-http-fetch             "ext:nelisp-http"    t t)
(declare-function nelisp-json-parse-string      "ext:nelisp-json"    t t)
(declare-function nelisp-json-serialize         "ext:nelisp-json"    t t)
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
(declare-function nelisp-ec-current-buffer      "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-set-buffer          "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-with-current-buffer "ext:nelisp-emacs-compat" t t)

(defvar nelisp-ec--current-buffer)

(defvar anvil-pkg-compat--nelisp-backend-require-attempted nil
  "Non-nil after a lazy require probe for package-split NeLisp backends.")

(defvar anvil-pkg-compat--nelisp-json-require-attempted nil
  "Non-nil after a lazy require probe for package-split NeLisp JSON.")

(defvar anvil-pkg-compat--nelisp-emacs-compat-require-attempted nil
  "Non-nil after a lazy require probe for NeLisp Emacs-compat helpers.")

(defun anvil-pkg-compat--try-require-nelisp-backends ()
  "Try to load optional package-split NeLisp backends once.

All requires are noerror probes.  anvil-pkg must remain loadable in
plain Emacs and on bare NeLisp bootstrap images, so failure here is
not exceptional."
  (unless anvil-pkg-compat--nelisp-backend-require-attempted
    (setq anvil-pkg-compat--nelisp-backend-require-attempted t)
    (when (fboundp 'require)
      (require 'nelisp-sys nil t)
      (require 'nelisp-process nil t)
      (require 'nelisp-network nil t)
      (require 'nelisp-http nil t))))

(defun anvil-pkg-compat--try-require-nelisp-json ()
  "Try to load optional package-split NeLisp JSON once."
  (unless anvil-pkg-compat--nelisp-json-require-attempted
    (setq anvil-pkg-compat--nelisp-json-require-attempted t)
    (when (fboundp 'require)
      (require 'nelisp-json nil t))))

(defun anvil-pkg-compat--try-require-nelisp-emacs-compat ()
  "Try to load optional package-split NeLisp Emacs-compat helpers once."
  (unless anvil-pkg-compat--nelisp-emacs-compat-require-attempted
    (setq anvil-pkg-compat--nelisp-emacs-compat-require-attempted t)
    (when (fboundp 'require)
      (require 'nelisp-runtime nil t)
      (require 'nelisp-emacs-compat nil t)
      (require 'nelisp-emacs-compat-fileio nil t))))

(defun anvil-pkg-compat--functions-bound-p (symbols)
  "Return non-nil when every symbol in SYMBOLS is fbound."
  (let ((ok t))
    (while (and ok symbols)
      (unless (fboundp (car symbols))
        (setq ok nil))
      (setq symbols (cdr symbols)))
    ok))

(defun anvil-pkg-compat--detect-nelisp-runtime-p ()
  "Return non-nil when NeLisp Layer-2 runtime primitives are loaded.

Older anvil-pkg releases detected NeLisp via `nelisp-call-process'
only.  Package-split NeLisp can load the async or HTTP substrate
independently, so Phase 5 treats any backend primitive that
anvil-pkg can directly use as sufficient evidence."
  (or (fboundp 'nelisp-call-process)
      (fboundp 'nelisp-make-process)
      (fboundp 'nelisp-http-get)
      (fboundp 'nelisp-http-fetch)
      (fboundp 'nelisp-http-get-binary)
      (progn
        (anvil-pkg-compat--try-require-nelisp-backends)
        (or (fboundp 'nelisp-call-process)
            (fboundp 'nelisp-make-process)
            (fboundp 'nelisp-http-get)
            (fboundp 'nelisp-http-fetch)
            (fboundp 'nelisp-http-get-binary)))))

(defvar anvil-pkg-compat--nelisp-runtime-p
  (anvil-pkg-compat--detect-nelisp-runtime-p)
  "Non-nil when NeLisp Layer-2 backend primitives are loaded.

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
  (when (and (not anvil-pkg-compat--nelisp-runtime-p)
             (anvil-pkg-compat--detect-nelisp-runtime-p))
    (setq anvil-pkg-compat--nelisp-runtime-p t))
  (if anvil-pkg-compat--nelisp-runtime-p 'nelisp 'emacs))

(defun anvil-pkg-compat--emacs-runtime-p ()
  "Return non-nil when the current runtime branch is Emacs.

Use this instead of reading `anvil-pkg-compat--nelisp-runtime-p'
directly so package-split NeLisp backends loaded after this file can
refresh the runtime decision before low-level I/O dispatch."
  (eq (anvil-pkg-compat-runtime) 'emacs))

(defun anvil-pkg-compat--runtime-nelisp-p ()
  "Return non-nil when the current runtime branch is NeLisp."
  (eq (anvil-pkg-compat-runtime) 'nelisp))

(defvar anvil-pkg-compat-nelisp-make-process-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-make-process-async'.

When non-nil, this must be a function accepting the same keyword
plist accepted by `anvil-pkg-compat-make-process-async'.  It is
called only when `anvil-pkg-compat-runtime' returns `nelisp'.
When nil, the NeLisp path keeps the Phase 4-C behaviour and
signals `anvil-pkg-async-not-supported' unless the runtime already
provides `nelisp-make-process'.")

(defvar anvil-pkg-compat-nelisp-call-process-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-call-process'.

When non-nil, this must be a function called as (PROGRAM ARGS) and
must return (:exit INT :stdout STRING :stderr STRING).  It is called
only when `anvil-pkg-compat-runtime' returns `nelisp'.  When nil, the
NeLisp path auto-detects `nelisp-call-process' when loaded.")

(defvar anvil-pkg-compat-nelisp-getenv-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-getenv'.

When non-nil, this must be a function called as (VAR) and must return
a string or nil.  It is called only when `anvil-pkg-compat-runtime'
returns `nelisp'.")

(defvar anvil-pkg-compat-nelisp-executable-find-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-executable-find'.

When non-nil, this must be a function called as (CMD) and must return
an executable path string or nil.  It is called only when
`anvil-pkg-compat-runtime' returns `nelisp'.")

(defvar anvil-pkg-compat-nelisp-http-get-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-http-get'.

When non-nil, this must be a function called as
\(URL TIMEOUT AUTH-HEADER) and must return (:status INT :body
STRING).  It is called only when `anvil-pkg-compat-runtime'
returns `nelisp'.  When nil, the NeLisp path keeps the Phase 4-C
behaviour and signals `anvil-pkg-http-not-supported' unless the
runtime already provides `nelisp-http-get' or the higher-level
`nelisp-http-fetch'.")

(defvar anvil-pkg-compat-nelisp-http-get-binary-function nil
  "Optional NeLisp backend for `anvil-pkg-compat-http-get-binary'.

When non-nil, this must be a function called as
\(URL TIMEOUT AUTH-HEADER) and must return (:status INT :body
STRING :content-length INT-OR-NIL).  It is called only when
`anvil-pkg-compat-runtime' returns `nelisp'.  When nil, the
NeLisp path auto-detects `nelisp-http-get-binary' when loaded, then
uses `curl' as a binary download fallback when available; without a
native backend or curl it keeps the Phase 4-D behaviour and signals
`anvil-pkg-http-not-supported'.")

(defcustom anvil-pkg-compat-curl-program "curl"
  "Curl executable used as a NeLisp fallback for binary HTTP downloads.

`anvil-pkg-compat-http-get-binary' prefers an explicit
`anvil-pkg-compat-nelisp-http-get-binary-function', then a loaded
`nelisp-http-get-binary' backend.  When neither native path exists
and the runtime is NeLisp, this executable is used only if it is
present on PATH.  If it is absent, the NeLisp binary HTTP path keeps
signalling `anvil-pkg-http-not-supported'."
  :type 'string
  :group 'anvil-pkg)

(defun anvil-pkg-compat--validate-call-process-result (resp backend)
  "Validate RESP from BACKEND as a call-process result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :exit))
               (stringp (plist-get resp :stdout))
               (stringp (plist-get resp :stderr)))
    (error "%s returned invalid call-process result: %S" backend resp))
  resp)

(defun anvil-pkg-compat--validate-http-result (resp backend)
  "Validate RESP from BACKEND as a text HTTP result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :status))
               (stringp (plist-get resp :body)))
    (error "%s returned invalid HTTP result: %S" backend resp))
  resp)

(defun anvil-pkg-compat--validate-binary-http-result (resp backend)
  "Validate RESP from BACKEND as a binary HTTP result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :status))
               (stringp (plist-get resp :body))
               (let ((len (plist-get resp :content-length)))
                 (or (null len) (integerp len))))
    (error "%s returned invalid binary HTTP result: %S" backend resp))
  resp)

;;;; --- process object helpers ----------------------------------------------

(defun anvil-pkg-compat-process-get (proc key)
  "Return PROC's property value for KEY across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-get)
    (process-get proc key))
   ((fboundp 'nelisp-process-get)
    (nelisp-process-get proc key))
   (t
    (error "no process property getter backend available"))))

(defun anvil-pkg-compat-process-put (proc key value)
  "Store VALUE under KEY on PROC across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-put)
    (process-put proc key value))
   ((fboundp 'nelisp-process-put)
    (nelisp-process-put proc key value))
   (t
    (error "no process property setter backend available"))))

(defun anvil-pkg-compat-process-status (proc)
  "Return PROC's status across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-status)
    (process-status proc))
   ((fboundp 'nelisp-process-current-status)
    (nelisp-process-current-status proc))
   (t
    (error "no process status backend available"))))

(defun anvil-pkg-compat-process-exit-status (proc)
  "Return PROC's exit status across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-exit-status)
    (process-exit-status proc))
   ((fboundp 'nelisp-process-exit-code-value)
    (nelisp-process-exit-code-value proc))
   (t
    (error "no process exit-status backend available"))))

;;;; --- buffer helpers -------------------------------------------------------

(defun anvil-pkg-compat-generate-buffer (name)
  "Return a new buffer named from NAME across Emacs and NeLisp."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-generate-new-buffer)))
    (nelisp-ec-generate-new-buffer name))
   ((fboundp 'generate-new-buffer)
    (generate-new-buffer name))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-generate-new-buffer)
      (nelisp-ec-generate-new-buffer name))
     (t (error "no generate-buffer backend available"))))))

(defun anvil-pkg-compat-buffer-live-p (buffer)
  "Return non-nil when BUFFER can still be inspected.
NeLisp's current `nelisp-ec' surface has no public live predicate, so
NeLisp callers treat a non-nil buffer as live and let read/kill helpers
swallow backend errors."
  (cond
   ((fboundp 'buffer-live-p)
    (buffer-live-p buffer))
   (t
    (and buffer t))))

(defun anvil-pkg-compat--buffer-string-nelisp (buffer)
  "Return BUFFER contents through NeLisp Emacs-compat helpers."
  (condition-case _
      (cond
       ((anvil-pkg-compat--functions-bound-p
         '(nelisp-ec-current-buffer
           nelisp-ec-set-buffer
           nelisp-ec-buffer-string))
        (let ((saved (nelisp-ec-current-buffer)))
          (unwind-protect
              (progn
                (nelisp-ec-set-buffer buffer)
                (nelisp-ec-buffer-string))
            (cond
             (saved (nelisp-ec-set-buffer saved))
             ((boundp 'nelisp-ec--current-buffer)
              (setq nelisp-ec--current-buffer nil))))))
       ((anvil-pkg-compat--functions-bound-p
         '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string))
        (nelisp-ec-with-current-buffer buffer
          (nelisp-ec-buffer-string)))
       (t ""))
    (error "")))

(defun anvil-pkg-compat-buffer-string (buffer)
  "Return BUFFER contents as a string, or empty string if unavailable."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (or (anvil-pkg-compat--functions-bound-p
                '(nelisp-ec-current-buffer
                  nelisp-ec-set-buffer
                  nelisp-ec-buffer-string))
               (anvil-pkg-compat--functions-bound-p
                '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string)))))
    (anvil-pkg-compat--buffer-string-nelisp buffer))
   ((and (fboundp 'with-current-buffer)
         (fboundp 'buffer-string)
         (anvil-pkg-compat-buffer-live-p buffer))
    (with-current-buffer buffer
      (buffer-string)))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((anvil-pkg-compat--functions-bound-p
       '(nelisp-ec-current-buffer
         nelisp-ec-set-buffer
         nelisp-ec-buffer-string))
      (anvil-pkg-compat--buffer-string-nelisp buffer))
     ((anvil-pkg-compat--functions-bound-p
       '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string))
      (anvil-pkg-compat--buffer-string-nelisp buffer))
     (t "")))))

(defun anvil-pkg-compat-kill-buffer (buffer)
  "Kill BUFFER if possible; ignore already-dead or missing buffers."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-kill-buffer)))
    (condition-case _ (nelisp-ec-kill-buffer buffer) (error nil)))
   ((and (fboundp 'kill-buffer)
         (anvil-pkg-compat-buffer-live-p buffer))
    (condition-case _ (kill-buffer buffer) (error nil)))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (when (fboundp 'nelisp-ec-kill-buffer)
      (condition-case _ (nelisp-ec-kill-buffer buffer) (error nil))))))

;;;; --- environment / path helpers -------------------------------------------

(defun anvil-pkg-compat-getenv (var &optional default)
  "Return env var VAR or DEFAULT.
Tries Emacs `getenv', then NeLisp Layer-2 alternatives."
  (let ((v (and (anvil-pkg-compat--runtime-nelisp-p)
                anvil-pkg-compat-nelisp-getenv-function
                (funcall anvil-pkg-compat-nelisp-getenv-function var))))
    (unless v
      (setq v (and (fboundp 'getenv) (getenv var))))
    (unless v
      (anvil-pkg-compat--try-require-nelisp-backends)
      (setq v
            (cond
             ((fboundp 'nelisp-sys-getenv) (nelisp-sys-getenv var))
             ((fboundp 'nelisp-syscall-getenv) (nelisp-syscall-getenv var)))))
    (unless v
      (anvil-pkg-compat--try-require-nelisp-emacs-compat)
      (setq v
            (cond
             ((fboundp 'nelisp-syscall-getenv) (nelisp-syscall-getenv var))
             ((fboundp 'nelisp-ec-getenv) (nelisp-ec-getenv var)))))
    (or v default)))

(defun anvil-pkg-compat-executable-find (cmd)
  "Find executable CMD on PATH; return absolute path or nil."
  (or (and (anvil-pkg-compat--runtime-nelisp-p)
           anvil-pkg-compat-nelisp-executable-find-function
           (funcall anvil-pkg-compat-nelisp-executable-find-function cmd))
      (and (fboundp 'executable-find) (executable-find cmd))
      (progn
        (anvil-pkg-compat--try-require-nelisp-backends)
        (and (fboundp 'nelisp-sys-executable-find)
             (nelisp-sys-executable-find cmd)))
      (progn
        (anvil-pkg-compat--try-require-nelisp-emacs-compat)
        (and (fboundp 'nelisp-ec-executable-find)
             (nelisp-ec-executable-find cmd)))))

;;;; --- filesystem ----------------------------------------------------------

(defun anvil-pkg-compat-file-exists-p (path)
  "Return non-nil if PATH exists."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-file-exists-p)))
    (nelisp-ec-file-exists-p path))
   ((fboundp 'file-exists-p) (file-exists-p path))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-file-exists-p) (nelisp-ec-file-exists-p path))))))

(defun anvil-pkg-compat-make-directory (path &optional parents)
  "Create directory PATH; non-nil PARENTS makes -p style."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-make-directory)))
    (nelisp-ec-make-directory path (or parents t)))
   ((fboundp 'make-directory) (make-directory path (or parents t)))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-make-directory)
      (nelisp-ec-make-directory path (or parents t)))
     (t (error "no make-directory implementation available"))))))

(defun anvil-pkg-compat-delete-file-quietly (path)
  "Delete PATH if it exists; ignore failures."
  (when (anvil-pkg-compat-file-exists-p path)
    (cond
     ((and (anvil-pkg-compat--runtime-nelisp-p)
           (progn
             (anvil-pkg-compat--try-require-nelisp-emacs-compat)
             (fboundp 'nelisp-ec-delete-file)))
      (condition-case _ (nelisp-ec-delete-file path) (error nil)))
     ((fboundp 'delete-file)
      (condition-case _ (delete-file path) (error nil)))
     (t
      (anvil-pkg-compat--try-require-nelisp-emacs-compat)
      (when (fboundp 'nelisp-ec-delete-file)
        (condition-case _ (nelisp-ec-delete-file path) (error nil)))))))

(defun anvil-pkg-compat-read-file (path)
  "Return the entire contents of PATH as a string."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (anvil-pkg-compat--functions-bound-p
            '(nelisp-ec-insert-file-contents
              nelisp-ec-generate-new-buffer
              nelisp-ec-with-current-buffer
              nelisp-ec-buffer-string))))
    ;; NeLisp Layer-2 path
    (let ((buf (nelisp-ec-generate-new-buffer "*anvil-pkg-read*")))
      (unwind-protect
          (progn
            (nelisp-ec-with-current-buffer buf
              (nelisp-ec-insert-file-contents path)
              (nelisp-ec-buffer-string)))
        (when (fboundp 'nelisp-ec-kill-buffer)
          (nelisp-ec-kill-buffer buf)))))
   ((and (fboundp 'with-temp-buffer)
         (fboundp 'insert-file-contents))
    ;; Emacs path, or Emacs-compatible fallback under test / bootstrap images.
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string)))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((anvil-pkg-compat--functions-bound-p
       '(nelisp-ec-insert-file-contents
         nelisp-ec-generate-new-buffer
         nelisp-ec-with-current-buffer
         nelisp-ec-buffer-string))
      (let ((buf (nelisp-ec-generate-new-buffer "*anvil-pkg-read*")))
        (unwind-protect
            (progn
              (nelisp-ec-with-current-buffer buf
                (nelisp-ec-insert-file-contents path)
                (nelisp-ec-buffer-string)))
          (when (fboundp 'nelisp-ec-kill-buffer)
            (nelisp-ec-kill-buffer buf)))))
     (t (error "no read-file backend available for %S" path))))))

(defun anvil-pkg-compat--read-file-binary (path)
  "Return PATH contents as a raw byte string where the host supports it."
  (cond
   ((and (fboundp 'with-temp-buffer)
         (fboundp 'insert-file-contents-literally))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (buffer-string)))
   ((and (fboundp 'with-temp-buffer)
         (fboundp 'insert-file-contents))
    (let ((coding-system-for-read 'binary))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents path)
        (buffer-string))))
   (t
    (anvil-pkg-compat-read-file path))))

(defun anvil-pkg-compat-write-file (path content)
  "Write CONTENT (string) to PATH, overwriting."
  (cond
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         (progn
           (anvil-pkg-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-write-region)))
    ;; nelisp-ec-write-region is the Layer-2 equivalent
    (nelisp-ec-write-region content nil path nil 'silent))
   ((fboundp 'with-temp-file)
    (with-temp-file path
      (insert content)))
   (t
    (anvil-pkg-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-write-region)
      (nelisp-ec-write-region content nil path nil 'silent))
     (t (error "no write-file backend available for %S" path))))))

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
   ((and (anvil-pkg-compat--emacs-runtime-p)
         (fboundp 'generate-new-buffer)
         (fboundp 'call-process))
    (anvil-pkg-compat--call-process-emacs program args))
   ((and (anvil-pkg-compat--runtime-nelisp-p)
         anvil-pkg-compat-nelisp-call-process-function)
    (anvil-pkg-compat--validate-call-process-result
     (funcall anvil-pkg-compat-nelisp-call-process-function program args)
     "anvil-pkg-compat-nelisp-call-process-function"))
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
       (t
        (anvil-pkg-compat--try-require-nelisp-json)
        (cond
         ((fboundp 'nelisp-json-parse-string)
          (nelisp-json-parse-string trimmed
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil))
         (t (error "no JSON parser backend available"))))))))

(defun anvil-pkg-compat-json-serialize (obj)
  "Serialize OBJ to a JSON string.

Uses Emacs `json-serialize' when available, otherwise the
package-split NeLisp `nelisp-json-serialize' backend.  Hash tables
are the recommended representation for JSON objects because both
backends preserve empty objects that way."
  (cond
   ((fboundp 'json-serialize)
    (json-serialize obj :null-object :null :false-object :json-false))
   (t
    (anvil-pkg-compat--try-require-nelisp-json)
    (cond
     ((fboundp 'nelisp-json-serialize)
      (nelisp-json-serialize obj))
     (t (error "no JSON serializer backend available"))))))

;;;; --- string utility -------------------------------------------------------

(defun anvil-pkg-compat-string-trim (str)
  "Remove leading and trailing ASCII whitespace from STR."
  (cond
   ((fboundp 'string-trim) (string-trim (or str "")))
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

;;;; --- credentials (Phase 4-G L40-L41 + L44) -------------------------------

(defcustom anvil-pkg-compat-credential-env-alist
  '(;; GitHub: main + raw + API + zip download endpoints all accept the
   ;; same PAT, so list each subdomain that we actually fetch from.
   ("github.com"                 . ("GITHUB_TOKEN" "GH_TOKEN"))
   ("raw.githubusercontent.com"  . ("GITHUB_TOKEN" "GH_TOKEN"))
   ("api.github.com"             . ("GITHUB_TOKEN" "GH_TOKEN"))
   ("codeload.github.com"        . ("GITHUB_TOKEN" "GH_TOKEN"))
   ("objects.githubusercontent.com" . ("GITHUB_TOKEN" "GH_TOKEN"))
   ;; GitLab.
   ("gitlab.com"                 . ("GITLAB_TOKEN"))
   ;; Codeberg.
   ("codeberg.org"               . ("CODEBERG_TOKEN")))
  "Alist mapping HOST to environment-variable name list for credential lookup.

Each element is a cons cell =(HOST . (ENV-VAR ...))=.  When
`anvil-pkg-compat-credential-for-url' resolves an URL whose host
matches HOST exactly, the env vars are checked in order; the first
non-empty one wins.  Returning a token here causes the HTTP
helpers to inject =Authorization: Bearer TOKEN= and the git
helpers to inject =-c http.HOST.extraheader=.

GitHub subdomains (raw.githubusercontent.com, api.github.com etc.)
are listed explicitly because host matching is exact rather than
suffix-based — a single GitHub PAT works against all of them.

Phase 4-G design L40: env-var-only credential model.  Tokens
are never persisted to `anvil-pkg-state' or any on-disk file."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'anvil-pkg)

(defun anvil-pkg-compat--url-host (url)
  "Return the lowercased host component of URL, or nil."
  (when (and (stringp url)
             (string-match "\\`[a-z][a-z0-9+.-]*://\\([^/?#]+\\)" url))
    (let ((host (match-string 1 url)))
      (when host (downcase host)))))

(defun anvil-pkg-compat-credential-for-url (url)
  "Return =Bearer TOKEN= for URL, or nil if no credential applies.

Looks up URL's host in `anvil-pkg-compat-credential-env-alist'
and walks the env-var list; the first env var whose value is
non-empty wins.

Phase 4-G L41."
  (let* ((host (anvil-pkg-compat--url-host url))
         (entry (and host (assoc host anvil-pkg-compat-credential-env-alist)))
         (vars  (cdr entry))
         (token nil))
    (while (and vars (null token))
      (let ((v (anvil-pkg-compat-getenv (car vars))))
        (when (and v (> (length v) 0))
          (setq token v)))
      (setq vars (cdr vars)))
    (when token (concat "Bearer " token))))

(defun anvil-pkg-compat-mask-credentials (str)
  "Redact token-like substrings in STR for safe logging.

Currently masks:
  - =Bearer <token>= → =Bearer ***=
  - =extra-access-tokens \"host=token ...\"= → host=***
  - =x-access-token:TOKEN@= → =x-access-token:***@=

Phase 4-G L44.  Pure string transformation; no state."
  (when (stringp str)
    (let ((s str))
      (setq s (replace-regexp-in-string
               "Bearer [A-Za-z0-9_.-]+" "Bearer ***" s))
      (setq s (replace-regexp-in-string
               "\\(extra-access-tokens[ \t]+\"[^\"]*=\\)[^\" ]+"
               "\\1***" s))
      (setq s (replace-regexp-in-string
               "x-access-token:[^@]+@" "x-access-token:***@" s))
      s)))

;;;; --- HTTP -----------------------------------------------------------------

;; `url-retrieve-synchronously' is autoloaded from the built-in `url'
;; package; declare it so byte-compile does not complain when this
;; file is compiled without `url' having been loaded yet.
(declare-function url-retrieve-synchronously "url" t t)

(defun anvil-pkg-compat-http-get (url &optional timeout auth-header)
  "Synchronously fetch URL.  TIMEOUT defaults to 5 seconds.

AUTH-HEADER (Phase 4-G L41), when non-nil, is the full
=Authorization:= value (without the field name) injected into
the request — e.g. \"Bearer ghp_xxx\".  When nil, host-based
auto-detection runs via `anvil-pkg-compat-credential-for-url'
so existing callers transparently pick up credentials from
environment variables.

Returns plist (:status INT :body STRING).  On NeLisp, an explicit
backend hook wins; otherwise a loaded `nelisp-http-get' or
`nelisp-http-fetch' backend is used.  If neither exists, the NeLisp
branch falls back to `curl'
through the binary HTTP curl adapter.  If no native backend and no
curl path are available, signals `anvil-pkg-http-not-supported'.
Network errors / non-2xx responses return :status N (the actual code
or 0 on connection failure) with :body empty.

Phase 4-C: Emacs implementation uses `url-retrieve-synchronously'
and parses the HTTP status line out of the response buffer's first
line (we do not rely on `url-http-response-status' because the
buffer may not have full HTTP metadata in some Emacs versions)."
  (pcase (anvil-pkg-compat-runtime)
    ('emacs
     (let* ((to (or timeout 5))
            (auth (or auth-header (anvil-pkg-compat-credential-for-url url)))
            (res (anvil-pkg-compat--http-get-emacs url to auth)))
       ;; On the standalone NeLisp reader (nemacs), `url-retrieve-synchronously'
       ;; is non-functional (returns nil), so a :status 0 there means "no
       ;; working url.el backend", not "connection failed".  Fall back to the
       ;; tested curl path, which does work on nemacs (call-process + curl).
       ;; Host Emacs (no reader primitive) keeps url.el authoritative -- a
       ;; genuine status-0 connection failure is returned as-is.
       (if (and (eq (plist-get res :status) 0)
                (fboundp 'nelisp--write-stdout-bytes)
                (anvil-pkg-compat-executable-find "curl"))
           (anvil-pkg-compat--http-get-curl url to auth)
         res)))
    ('nelisp
     (if anvil-pkg-compat-nelisp-http-get-function
         (anvil-pkg-compat--validate-http-result
          (funcall anvil-pkg-compat-nelisp-http-get-function
                   url
                   (or timeout 5)
                   (or auth-header (anvil-pkg-compat-credential-for-url url)))
          "anvil-pkg-compat-nelisp-http-get-function")
       (anvil-pkg-compat--try-require-nelisp-backends)
       (if (or (fboundp 'nelisp-http-get)
               (fboundp 'nelisp-http-fetch))
           (let ((timeout (or timeout 5))
                 (auth (or auth-header
                           (anvil-pkg-compat-credential-for-url url))))
             (anvil-pkg-compat--http-get-curl-after-native-zero
              (anvil-pkg-compat--http-get-nelisp url timeout auth)
              url
              timeout
              auth))
         (anvil-pkg-compat--http-get-curl
          url
          (or timeout 5)
          (or auth-header (anvil-pkg-compat-credential-for-url url))))))
    (_
     (signal 'anvil-pkg-http-not-supported
             (list (format "anvil-pkg-compat-http-get: no backend for runtime %S"
                           (anvil-pkg-compat-runtime)))))))

(defun anvil-pkg-compat--http-get-emacs (url timeout &optional auth-header)
  "Emacs backend for `anvil-pkg-compat-http-get'.

Wraps `url-retrieve-synchronously' with a TIMEOUT override and
parses the HTTP status line from the buffer's first line.  Returns
plist (:status INT :body STRING).  On any error returns (:status 0
:body \"\") so callers do not need to wrap in `condition-case'.

AUTH-HEADER (Phase 4-G), when non-nil, is injected into
`url-request-extra-headers' as the =Authorization:= field for
the duration of the call."
  (require 'url)
  (defvar url-show-status)
  (defvar url-request-extra-headers)
  (let ((url-show-status nil)
        (url-request-extra-headers
         (if auth-header
             (cons (cons "Authorization" auth-header)
                   (and (boundp 'url-request-extra-headers)
                        url-request-extra-headers))
           (and (boundp 'url-request-extra-headers)
                url-request-extra-headers)))
        (status 0)
        (body ""))
    ;; Reference url-show-status so the binding is not flagged as
    ;; unused — `url' reads it dynamically inside
    ;; `url-retrieve-synchronously'.
    (ignore url-show-status url-request-extra-headers)
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

(defun anvil-pkg-compat--headers-for-auth (auth-header)
  "Return HTTP header alist for AUTH-HEADER, or nil."
  (when auth-header
    (list (cons "Authorization" auth-header))))

(defun anvil-pkg-compat--http-get-nelisp (url timeout &optional auth-header)
  "NeLisp backend adapter for `anvil-pkg-compat-http-get'.

Uses `nelisp-http-get' when the NeLisp network package is already
loaded, or `nelisp-http-fetch' when the higher-level NeLisp HTTP
package is available.  The adapter normalizes the result into
anvil-pkg's small (:status INT :body STRING) contract and degrades
backend errors to status 0, matching the Emacs backend's
network-failure behaviour."
  (condition-case _err
      (let* ((headers (anvil-pkg-compat--headers-for-auth auth-header))
             (resp (if (fboundp 'nelisp-http-get)
                       (nelisp-http-get
                        url
                        :headers headers
                        :timeout timeout
                        :cache-ttl 0)
                     (nelisp-http-fetch
                      url
                      :headers headers
                      :timeout-sec timeout
                      :ttl 0
                      :no-cache t
                      :skip-robots-check t)))
             (status (plist-get resp :status))
             (body (plist-get resp :body)))
        (list :status (if (integerp status) status 0)
              :body (if (stringp body) body "")))
    (error
     (list :status 0 :body ""))))

(defun anvil-pkg-compat--http-get-curl (url timeout &optional auth-header)
  "Text HTTP fallback for NeLisp via the binary curl adapter.

This keeps the text HTTP contract (:status INT :body STRING) while
reusing the tested curl header/body split path from
`anvil-pkg-compat--http-get-binary-curl'.  Unsupported-runtime
signals from the underlying curl path are intentionally preserved."
  (let ((resp (anvil-pkg-compat--http-get-binary-curl
               url timeout auth-header)))
    (list :status (plist-get resp :status)
          :body (plist-get resp :body))))

(defun anvil-pkg-compat--http-get-curl-after-native-zero
    (resp url timeout auth-header)
  "Return RESP or retry text HTTP through curl after native status 0.

Auto-detected NeLisp HTTP packages can be loadable before their lower
runtime primitives are executable.  In that case the normalized native
adapter returns status 0; use the curl fallback if it is available,
but keep RESP when curl itself is unsupported."
  (if (eq (plist-get resp :status) 0)
      (condition-case _
          (anvil-pkg-compat--http-get-curl url timeout auth-header)
        (anvil-pkg-http-not-supported resp))
    resp))

(defun anvil-pkg-compat--http-get-binary-nelisp (url timeout &optional auth-header)
  "NeLisp backend adapter for `anvil-pkg-compat-http-get-binary'.

Uses `nelisp-http-get-binary' when the NeLisp network package exposes
a raw-byte download primitive.  The adapter normalizes the result into
(:status INT :body STRING :content-length INT-OR-NIL) and degrades
backend errors to status 0, matching the Emacs binary HTTP backend's
network-failure behaviour."
  (condition-case _err
      (let* ((resp (nelisp-http-get-binary
                    url
                    :headers (anvil-pkg-compat--headers-for-auth auth-header)
                    :timeout timeout
                    :cache-ttl 0))
             (status (plist-get resp :status))
             (body (plist-get resp :body))
             (content-length (plist-get resp :content-length)))
        (list :status (if (integerp status) status 0)
              :body (if (stringp body) body "")
              :content-length (and (integerp content-length)
                                   content-length)))
    (error
     (list :status 0 :body "" :content-length nil))))

(defun anvil-pkg-compat--http-get-binary-curl-after-native-zero
    (resp url timeout auth-header)
  "Return RESP or retry binary HTTP through curl after native status 0."
  (if (eq (plist-get resp :status) 0)
      (condition-case _
          (anvil-pkg-compat--http-get-binary-curl url timeout auth-header)
        (anvil-pkg-http-not-supported resp))
    resp))

(defun anvil-pkg-compat--parse-curl-headers (headers)
  "Parse curl --dump-header HEADERS.

Returns (:status INT :content-length INT-OR-NIL) for the final
HTTP response block.  Curl writes one header block per redirect when
`-L' is used, so this parser resets Content-Length each time it
sees a new HTTP status line and keeps the last block."
  (let ((lines (split-string (or headers "") "\r?\n"))
        (status 0)
        (content-length nil))
    (dolist (line lines)
      (cond
       ((string-match "\\`HTTP/[0-9.]+[ \t]+\\([0-9]+\\)" line)
        (setq status (string-to-number (match-string 1 line))
              content-length nil))
       ((string-match "\\`[Cc]ontent-[Ll]ength:[ \t]*\\([0-9]+\\)" line)
        (setq content-length (string-to-number (match-string 1 line))))))
    (list :status status :content-length content-length)))

(defun anvil-pkg-compat--http-get-binary-curl (url timeout &optional auth-header)
  "Fetch URL as raw bytes using curl.

This is the NeLisp fallback when no native binary HTTP hook is
installed.  It writes headers and body to separate temp files so the
binary response is never mixed with textual HTTP metadata."
  (let ((curl (anvil-pkg-compat-executable-find anvil-pkg-compat-curl-program)))
    (unless curl
      (signal 'anvil-pkg-http-not-supported
              (list (format "anvil-pkg-compat-http-get-binary: no NeLisp binary HTTP backend and %s not found"
                            anvil-pkg-compat-curl-program))))
    (let ((headers-file (anvil-pkg-compat-make-temp-file "anvil-pkg-curl-headers-"))
          (body-file (anvil-pkg-compat-make-temp-file "anvil-pkg-curl-body-")))
      (unwind-protect
          (let* ((args (append
                        (list "-L"
                              "--silent"
                              "--show-error"
                              "--max-time" (number-to-string (or timeout 30))
                              "--dump-header" headers-file
                              "--output" body-file)
                        (when auth-header
                          (list "-H" (concat "Authorization: " auth-header)))
                        (list url)))
                 (resp (condition-case err
                           (anvil-pkg-compat-call-process curl args)
                         (error
                          (signal 'anvil-pkg-http-not-supported
                                  (list (format "anvil-pkg-compat-http-get-binary: curl fallback cannot run %s (%s)"
                                                curl
                                                (error-message-string err)))))))
                 (exit (plist-get resp :exit)))
            (if (not (eq exit 0))
                (list :status 0 :body "" :content-length nil)
              (let* ((header-info
                      (anvil-pkg-compat--parse-curl-headers
                       (anvil-pkg-compat-read-file headers-file)))
                     (status (plist-get header-info :status)))
                (list :status status
                      :body (if (eq status 0)
                                ""
                              (anvil-pkg-compat--read-file-binary body-file))
                      :content-length
                      (plist-get header-info :content-length)))))
        (anvil-pkg-compat-delete-file-quietly headers-file)
        (anvil-pkg-compat-delete-file-quietly body-file)))))

(defun anvil-pkg-compat-http-get-binary (url &optional timeout auth-header)
  "Synchronously fetch URL preserving raw bytes (no coding conversion).

Like `anvil-pkg-compat-http-get' but the response :body is the raw
byte string from the server (not decoded into multibyte characters).
Used for binary payloads such as tar.gz tarballs where the L24a
deps scrape pipes the bytes straight to a tmp file for `tar -xzOf'.

AUTH-HEADER (Phase 4-G L41), when non-nil, is the full
=Authorization:= value injected into the request.  Defaults to
host-based auto-detection via `anvil-pkg-compat-credential-for-url'.

Returns plist (:status INT :body STRING :content-length INT-OR-NIL).
The :content-length slot is parsed from the response headers when
present, so callers can refuse oversize payloads without keeping
the whole body in memory afterwards.

On NeLisp, an explicit backend hook wins; otherwise the helper falls
back to a loaded `nelisp-http-get-binary' backend, then to `curl' when
it is available on PATH.  If neither exists, signals
`anvil-pkg-http-not-supported'."
  (pcase (anvil-pkg-compat-runtime)
    ('emacs
     (anvil-pkg-compat--http-get-binary-emacs
      url
      (or timeout 30)
      (or auth-header (anvil-pkg-compat-credential-for-url url))))
    ('nelisp
     (if anvil-pkg-compat-nelisp-http-get-binary-function
         (anvil-pkg-compat--validate-binary-http-result
          (funcall anvil-pkg-compat-nelisp-http-get-binary-function
                   url
                   (or timeout 30)
                   (or auth-header (anvil-pkg-compat-credential-for-url url)))
          "anvil-pkg-compat-nelisp-http-get-binary-function")
       (anvil-pkg-compat--try-require-nelisp-backends)
       (if (fboundp 'nelisp-http-get-binary)
           (let ((timeout (or timeout 30))
                 (auth (or auth-header
                           (anvil-pkg-compat-credential-for-url url))))
             (anvil-pkg-compat--http-get-binary-curl-after-native-zero
              (anvil-pkg-compat--http-get-binary-nelisp url timeout auth)
              url
              timeout
              auth))
         (anvil-pkg-compat--http-get-binary-curl
          url
          (or timeout 30)
          (or auth-header (anvil-pkg-compat-credential-for-url url))))))
    (_
     (signal 'anvil-pkg-http-not-supported
             (list (format "anvil-pkg-compat-http-get-binary: no backend for runtime %S"
                           (anvil-pkg-compat-runtime)))))))

(defun anvil-pkg-compat--http-get-binary-emacs (url timeout &optional auth-header)
  "Emacs backend for `anvil-pkg-compat-http-get-binary'.

Identical control-flow to `anvil-pkg-compat--http-get-emacs' but
binds `coding-system-for-read' to `binary' so the response buffer
is not transcoded; the body is returned as a raw byte string ready
for `write-region' to a tmp tarball file.  Also parses the
Content-Length header into a numeric :content-length slot when
present.

AUTH-HEADER (Phase 4-G), when non-nil, is injected into
`url-request-extra-headers' for the call's duration."
  (require 'url)
  (defvar url-show-status)
  (defvar url-request-extra-headers)
  (let ((url-show-status nil)
        (url-request-extra-headers
         (if auth-header
             (cons (cons "Authorization" auth-header)
                   (and (boundp 'url-request-extra-headers)
                        url-request-extra-headers))
           (and (boundp 'url-request-extra-headers)
                url-request-extra-headers)))
        (coding-system-for-read 'binary)
        (status 0)
        (body "")
        (content-length nil))
    (ignore url-show-status url-request-extra-headers)
    (condition-case _err
        (let ((buf (url-retrieve-synchronously url t t timeout)))
          (when (and buf (buffer-live-p buf))
            (unwind-protect
                (with-current-buffer buf
                  ;; Status line.
                  (goto-char (point-min))
                  (let ((line-end (line-end-position)))
                    (when (re-search-forward
                           "\\`HTTP/[0-9.]+ \\([0-9]+\\)" line-end t)
                      (setq status (string-to-number (match-string 1)))))
                  ;; Content-Length header (case-insensitive).
                  (goto-char (point-min))
                  (let ((case-fold-search t)
                        (header-end
                         (save-excursion
                           (goto-char (point-min))
                           (when (re-search-forward "\r?\n\r?\n" nil t)
                             (point)))))
                    (when (and header-end
                               (re-search-forward
                                "^Content-Length:[ \t]*\\([0-9]+\\)"
                                header-end t))
                      (setq content-length
                            (string-to-number (match-string 1)))))
                  ;; Body.
                  (goto-char (point-min))
                  (when (re-search-forward "\r?\n\r?\n" nil t)
                    (setq body (buffer-substring-no-properties
                                (point) (point-max)))))
              (kill-buffer buf))))
      (error
       (setq status 0
             body ""
             content-length nil)))
    (list :status status :body body :content-length content-length)))

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

;;;; --- async subprocess (Phase 4-C L22) ------------------------------------

;; The error symbol is also redefined in `anvil-pkg.el' (with
;; `anvil-pkg-error' as parent) so the conditions chain routes
;; correctly when both files are loaded.  Defining it here too lets
;; callers that loaded only `anvil-pkg-compat' still signal /
;; should-error against the symbol on NeLisp.
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-async-not-supported
                                      "asynchronous install not supported on this runtime")

;; Phase 4-C L18 error symbol installed at load time: callers
;; (anvil-pkg-emacs.el) can `signal' it without first requiring
;; anvil-pkg.
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-http-not-supported
                                      "HTTP not supported on this runtime")

(defun anvil-pkg-compat-make-process-async (&rest plist)
  "Spawn an asynchronous process portably across Emacs and NeLisp.

PLIST mirrors the keyword arguments accepted by Emacs `make-process'
\(:name :command :sentinel :stderr :connection-type :noquery :buffer\).
Returns a process object on Emacs.  Signals
`anvil-pkg-async-not-supported' on NeLisp only when neither an
explicit backend hook nor a loaded `nelisp-make-process' backend is
available.

This is the sole runtime-aware async-spawn entry point for
anvil-pkg sub-modules; consult `anvil-pkg-compat-runtime' for the
underlying decision."
  (pcase (anvil-pkg-compat-runtime)
    ('emacs
     (apply #'make-process plist))
    ('nelisp
     (if anvil-pkg-compat-nelisp-make-process-function
         (apply anvil-pkg-compat-nelisp-make-process-function plist)
       (anvil-pkg-compat--try-require-nelisp-backends)
       (if (fboundp 'nelisp-make-process)
           (condition-case err
               (apply #'nelisp-make-process plist)
             (error
              (signal 'anvil-pkg-async-not-supported
                      (list
                       (format "anvil-pkg-compat-make-process-async: NeLisp async backend failed (%s)"
                               (error-message-string err))))))
         (signal 'anvil-pkg-async-not-supported
                 (list "anvil-pkg-compat-make-process-async: NeLisp runtime has no async backend (Phase 5)")))))
    (other
     (signal 'anvil-pkg-async-not-supported
             (list (format "anvil-pkg-compat-make-process-async: unknown runtime %S" other))))))

(provide 'anvil-pkg-compat)
;;; anvil-pkg-compat.el ends here
