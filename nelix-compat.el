;;; nelix-compat.el --- Emacs / NeLisp standalone portability layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Thin shim so nelix-core can run under either /Emacs/ (the historic
;; host) or /NeLisp standalone/ (= the Rust runtime + its Layer 2
;; packages: nelisp-process / nelisp-json / nelisp-emacs-compat).
;;
;; The shim deliberately stays dependency-free at load time and only
;; requires its backend implementations lazily, so loading nelix-core
;; on bare NeLisp does not error out at file load.
;;
;; Runtime detection starts with `fboundp' probes at load time and is
;; refreshed lazily by `nelix-compat-runtime'.  This lets callers
;; load nelix-core before package-split NeLisp backends without getting
;; stuck on the Emacs branch for the rest of the session.
;;
;; Public surface (all `nelix-compat-' prefixed):
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

(unless (fboundp 'ignore)
  (defun ignore (&rest _ignored)
    "Ignore all arguments and return nil."
    nil))

(unless (get 'void-function 'error-conditions)
  (put 'void-function 'error-conditions '(error void-function))
  (put 'void-function 'error-message "Symbol's function definition is void"))

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
(declare-function rdf                           "ext:nelisp-runtime" t t)
(declare-function nelisp--syscall-read-file     "ext:nelisp-runtime" t t)
(declare-function nelisp-ec-getenv              "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-executable-find     "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-file-exists-p       "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-make-directory      "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-delete-file         "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-insert-file-contents "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-write-region        "ext:nelisp-emacs-compat-fileio" t t)
(declare-function nelisp-ec-generate-new-buffer "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-kill-buffer         "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-buffer-p           "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-buffer-killed-p    "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-buffer-string       "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-current-buffer      "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-set-buffer          "ext:nelisp-emacs-compat" t t)
(declare-function nelisp-ec-with-current-buffer "ext:nelisp-emacs-compat" t t)

(defvar nelisp-ec--current-buffer)

(defvar nelix-compat--nelisp-backend-require-attempted nil
  "Non-nil after a lazy require probe for package-split NeLisp backends.")

(defvar nelix-compat--nelisp-json-require-attempted nil
  "Non-nil after a lazy require probe for package-split NeLisp JSON.")

(defvar nelix-compat--nelisp-emacs-compat-require-attempted nil
  "Non-nil after a lazy require probe for NeLisp Emacs-compat helpers.")

(defun nelix-compat--try-require-nelisp-backends ()
  "Try to load optional package-split NeLisp backends once.

All requires are noerror probes.  nelix-core must remain loadable in
plain Emacs and on bare NeLisp bootstrap images, so failure here is
not exceptional."
  (unless nelix-compat--nelisp-backend-require-attempted
    (setq nelix-compat--nelisp-backend-require-attempted t)
    (when (fboundp 'require)
      (require 'nelisp-sys nil t)
      (require 'nelisp-process nil t)
      (require 'nelisp-network nil t)
      (require 'nelisp-http nil t))))

(defun nelix-compat--try-require-nelisp-json ()
  "Try to load optional package-split NeLisp JSON once."
  (unless nelix-compat--nelisp-json-require-attempted
    (setq nelix-compat--nelisp-json-require-attempted t)
    (when (fboundp 'require)
      (require 'nelisp-json nil t))))

(defvar nelix-compat-nelisp-emacs-lisp-dirs nil
  "Directories holding the libraryized `nelisp-emacs' compat packages.
When set, these are prepended to `load-path' before the
`nelisp-emacs-compat' / `nelisp-emacs-compat-fileio' features are
required, so the reusable `nelisp-emacs' library implementation is
resolved in preference to any older in-tree copy (e.g. the
`nelisp/src' bootstrap copies).  Each entry is a package `lisp/'
directory, e.g.
  .../nelisp-emacs/packages/nelisp-emacs-buffer-core/lisp
  .../nelisp-emacs/packages/nelisp-emacs-io/lisp
  .../nelisp-emacs/packages/nelisp-emacs-text-core/lisp
When nil, the `NELIX_NELISP_EMACS_LISP' environment variable is read
on first use (`path-separator'-separated list of dirs; the legacy
`ANVIL_NELISP_EMACS_LISP' name is still accepted as a fallback).")

(defvar nelix-compat--nelisp-emacs-load-path-augmented nil
  "Non-nil once `nelisp-emacs' library dirs were added to `load-path'.")

(defun nelix-compat--augment-nelisp-emacs-load-path ()
  "Prepend `nelisp-emacs' library lisp dirs to `load-path' once.
Dir list comes from `nelix-compat-nelisp-emacs-lisp-dirs', or,
when that is nil, from the `NELIX_NELISP_EMACS_LISP' environment
variable (legacy `ANVIL_NELISP_EMACS_LISP' also accepted).  No-op
when neither is set, so plain Emacs and bare NeLisp images that
already ship a compat copy keep loading unchanged.  Uses manual
prepend (not `add-to-list') to stay loadable on bare NeLisp."
  (unless nelix-compat--nelisp-emacs-load-path-augmented
    (setq nelix-compat--nelisp-emacs-load-path-augmented t)
    (let ((dirs nelix-compat-nelisp-emacs-lisp-dirs)
          (sep (if (boundp 'path-separator) path-separator ":")))
      (when (and (null dirs) (fboundp 'getenv))
        (let ((env (or (getenv "NELIX_NELISP_EMACS_LISP")
                       ;; Legacy name kept as a fallback during the
                       ;; nelix-core -> nelix rename.
                       (getenv "ANVIL_NELISP_EMACS_LISP"))))
          (when (and (stringp env) (> (length env) 0))
            (setq dirs (if (fboundp 'split-string)
                           (split-string env sep t)
                         (list env))))))
      (when (and dirs (boundp 'load-path))
        ;; Add in reverse so the first listed dir lands first on load-path.
        (dolist (dir (reverse dirs))
          (when (and (stringp dir) (> (length dir) 0)
                     (not (member dir load-path)))
            (setq load-path (cons dir load-path))))))))

(defun nelix-compat--try-require-nelisp-emacs-compat ()
  "Try to load optional package-split NeLisp Emacs-compat helpers once."
  (unless nelix-compat--nelisp-emacs-compat-require-attempted
    (setq nelix-compat--nelisp-emacs-compat-require-attempted t)
    ;; Prefer the libraryized `nelisp-emacs' implementation when its
    ;; package dirs are known: prepend them so the require below
    ;; resolves the reusable library copy over any older in-tree one.
    (nelix-compat--augment-nelisp-emacs-load-path)
    (when (fboundp 'require)
      (require 'nelisp-runtime nil t)
      (require 'nelisp-emacs-compat nil t)
      (require 'nelisp-emacs-compat-fileio nil t))))

(defun nelix-compat--functions-bound-p (symbols)
  "Return non-nil when every symbol in SYMBOLS is fbound."
  (let ((ok t))
    (while (and ok symbols)
      (unless (fboundp (car symbols))
        (setq ok nil))
      (setq symbols (cdr symbols)))
    ok))

(defun nelix-compat--detect-nelisp-runtime-p ()
  "Return non-nil when NeLisp Layer-2 runtime primitives are loaded.

Older nelix-core releases detected NeLisp via `nelisp-call-process'
only.  Package-split NeLisp can load the async or HTTP substrate
independently, so Phase 5 treats any backend primitive that
nelix-core can directly use as sufficient evidence."
  (or (fboundp 'nelisp-call-process)
      (fboundp 'nelisp-make-process)
      (fboundp 'nelisp-http-get)
      (fboundp 'nelisp-http-fetch)
      (fboundp 'nelisp-http-get-binary)
      (progn
        (nelix-compat--try-require-nelisp-backends)
        (or (fboundp 'nelisp-call-process)
            (fboundp 'nelisp-make-process)
            (fboundp 'nelisp-http-get)
            (fboundp 'nelisp-http-fetch)
            (fboundp 'nelisp-http-get-binary)))))

(defvar nelix-compat--nelisp-runtime-p
  (nelix-compat--detect-nelisp-runtime-p)
  "Non-nil when NeLisp Layer-2 backend primitives are loaded.

Defined as a defvar (not defconst) so tests can override the value
via `cl-letf' / `let'.  Production code should consult
`nelix-compat-runtime' rather than reading this variable
directly so callers (e.g. nelix-core.el's :async branch) get a
single, mockable runtime decision point.")

(defun nelix-compat-runtime ()
  "Return the active runtime symbol: `nelisp' or `emacs'.
Sole authority for runtime branching outside this file.  Tests
can override via `cl-letf' on this function (preferred) or by
let-binding `nelix-compat--nelisp-runtime-p'."
  (when (and (not nelix-compat--nelisp-runtime-p)
             (nelix-compat--detect-nelisp-runtime-p))
    (setq nelix-compat--nelisp-runtime-p t))
  (if nelix-compat--nelisp-runtime-p 'nelisp 'emacs))

(defun nelix-compat--emacs-runtime-p ()
  "Return non-nil when the current runtime branch is Emacs.

Use this instead of reading `nelix-compat--nelisp-runtime-p'
directly so package-split NeLisp backends loaded after this file can
refresh the runtime decision before low-level I/O dispatch."
  (eq (nelix-compat-runtime) 'emacs))

(defun nelix-compat--runtime-nelisp-p ()
  "Return non-nil when the current runtime branch is NeLisp."
  (eq (nelix-compat-runtime) 'nelisp))

(defun nelix-compat--standalone-nelisp-p ()
  "Return non-nil only in the standalone NeLisp runtime.

Emacs tests may mock `nelix-compat-runtime' to `nelisp' while
still running inside Emacs.  This predicate keeps production fast
paths that depend on NeLisp's standalone process/file primitives out
of those mocked Emacs sessions."
  (and (nelix-compat--runtime-nelisp-p)
       (not (boundp 'emacs-version))))

(defvar nelix-compat-nelisp-make-process-function nil
  "Optional NeLisp backend for `nelix-compat-make-process-async'.

When non-nil, this must be a function accepting the same keyword
plist accepted by `nelix-compat-make-process-async'.  It is
called only when `nelix-compat-runtime' returns `nelisp'.
When nil, the NeLisp path keeps the Phase 4-C behaviour and
signals `nelix-async-not-supported' unless the runtime already
provides `nelisp-make-process'.")

(defvar nelix-compat-nelisp-call-process-function nil
  "Optional NeLisp backend for `nelix-compat-call-process'.

When non-nil, this must be a function called as (PROGRAM ARGS) and
must return (:exit INT :stdout STRING :stderr STRING).  It is called
only when `nelix-compat-runtime' returns `nelisp'.  When nil, the
NeLisp path auto-detects `nelisp-call-process' when loaded.")

(defvar nelix-compat-nelisp-getenv-function nil
  "Optional NeLisp backend for `nelix-compat-getenv'.

When non-nil, this must be a function called as (VAR) and must return
a string or nil.  It is called only when `nelix-compat-runtime'
returns `nelisp'.")

(defvar nelix-compat-nelisp-executable-find-function nil
  "Optional NeLisp backend for `nelix-compat-executable-find'.

When non-nil, this must be a function called as (CMD) and must return
an executable path string or nil.  It is called only when
`nelix-compat-runtime' returns `nelisp'.")

(defvar nelix-compat-nelisp-http-get-function nil
  "Optional NeLisp backend for `nelix-compat-http-get'.

When non-nil, this must be a function called as
\(URL TIMEOUT AUTH-HEADER) and must return (:status INT :body
STRING).  It is called only when `nelix-compat-runtime'
returns `nelisp'.  When nil, the NeLisp path keeps the Phase 4-C
behaviour and signals `nelix-http-not-supported' unless the
runtime already provides `nelisp-http-get' or the higher-level
`nelisp-http-fetch'.")

(defvar nelix-compat-nelisp-http-get-binary-function nil
  "Optional NeLisp backend for `nelix-compat-http-get-binary'.

When non-nil, this must be a function called as
\(URL TIMEOUT AUTH-HEADER) and must return (:status INT :body
STRING :content-length INT-OR-NIL).  It is called only when
`nelix-compat-runtime' returns `nelisp'.  When nil, the
NeLisp path auto-detects `nelisp-http-get-binary' when loaded, then
uses `curl' as a binary download fallback when available; without a
native backend or curl it keeps the Phase 4-D behaviour and signals
`nelix-http-not-supported'.")

(defcustom nelix-compat-curl-program "curl"
  "Curl executable used as a NeLisp fallback for binary HTTP downloads.

`nelix-compat-http-get-binary' prefers an explicit
`nelix-compat-nelisp-http-get-binary-function', then a loaded
`nelisp-http-get-binary' backend.  When neither native path exists
and the runtime is NeLisp, this executable is used only if it is
present on PATH.  If it is absent, the NeLisp binary HTTP path keeps
signalling `nelix-http-not-supported'."
  :type 'string
  :group 'nelix-core)

(defun nelix-compat--validate-call-process-result (resp backend)
  "Validate RESP from BACKEND as a call-process result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :exit))
               (stringp (plist-get resp :stdout))
               (stringp (plist-get resp :stderr)))
    (error "%s returned invalid call-process result: %S" backend resp))
  resp)

(defun nelix-compat--validate-http-result (resp backend)
  "Validate RESP from BACKEND as a text HTTP result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :status))
               (stringp (plist-get resp :body)))
    (error "%s returned invalid HTTP result: %S" backend resp))
  resp)

(defun nelix-compat--validate-binary-http-result (resp backend)
  "Validate RESP from BACKEND as a binary HTTP result plist."
  (unless (and (listp resp)
               (integerp (plist-get resp :status))
               (stringp (plist-get resp :body))
               (let ((len (plist-get resp :content-length)))
                 (or (null len) (integerp len))))
    (error "%s returned invalid binary HTTP result: %S" backend resp))
  resp)

(defun nelix-compat--call-optional-backend (symbol &rest args)
  "Call optional backend SYMBOL with ARGS, or return nil when unavailable."
  (when (fboundp symbol)
    (condition-case nil
        (apply symbol args)
      (error nil))))

;;;; --- process object helpers ----------------------------------------------

(defun nelix-compat-process-get (proc key)
  "Return PROC's property value for KEY across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-get)
    (process-get proc key))
   ((fboundp 'nelisp-process-get)
    (nelisp-process-get proc key))
   (t
    (error "no process property getter backend available"))))

(defun nelix-compat-process-put (proc key value)
  "Store VALUE under KEY on PROC across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-put)
    (process-put proc key value))
   ((fboundp 'nelisp-process-put)
    (nelisp-process-put proc key value))
   (t
    (error "no process property setter backend available"))))

(defun nelix-compat-process-status (proc)
  "Return PROC's status across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-status)
    (process-status proc))
   ((fboundp 'nelisp-process-current-status)
    (nelisp-process-current-status proc))
   (t
    (error "no process status backend available"))))

(defun nelix-compat-process-exit-status (proc)
  "Return PROC's exit status across Emacs and NeLisp wraps."
  (cond
   ((fboundp 'process-exit-status)
    (process-exit-status proc))
   ((fboundp 'nelisp-process-exit-code-value)
    (nelisp-process-exit-code-value proc))
   (t
    (error "no process exit-status backend available"))))

;;;; --- buffer helpers -------------------------------------------------------

(defun nelix-compat-generate-buffer (name)
  "Return a new buffer named from NAME across Emacs and NeLisp."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-generate-new-buffer)))
    (nelisp-ec-generate-new-buffer name))
   ((fboundp 'generate-new-buffer)
    (generate-new-buffer name))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-generate-new-buffer)
      (nelisp-ec-generate-new-buffer name))
     (t (error "no generate-buffer backend available"))))))

(defun nelix-compat-buffer-live-p (buffer)
  "Return non-nil when BUFFER can still be inspected.
NeLisp `nelisp-ec' buffers are checked before the host Emacs predicate
so standalone vector-backed buffers are not rejected by `buffer-live-p'."
  (cond
   ((and (fboundp 'nelisp-ec-buffer-p)
         (nelisp-ec-buffer-p buffer))
    (not (and (fboundp 'nelisp-ec-buffer-killed-p)
              (nelisp-ec-buffer-killed-p buffer))))
   ((fboundp 'buffer-live-p)
    (buffer-live-p buffer))
   (t
    (and buffer t))))

(defun nelix-compat--buffer-string-nelisp (buffer)
  "Return BUFFER contents through NeLisp Emacs-compat helpers."
  (condition-case _
      (cond
       ((nelix-compat--functions-bound-p
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
       ((nelix-compat--functions-bound-p
         '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string))
        (nelisp-ec-with-current-buffer buffer
          (nelisp-ec-buffer-string)))
       (t ""))
    (error "")))

(defun nelix-compat-buffer-string (buffer)
  "Return BUFFER contents as a string, or empty string if unavailable."
  (cond
   ((and (vectorp buffer)
         (> (length buffer) 2)
         (eq (aref buffer 0) 'buffer))
    (aref buffer 2))
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (or (nelix-compat--functions-bound-p
                '(nelisp-ec-current-buffer
                  nelisp-ec-set-buffer
                  nelisp-ec-buffer-string))
               (nelix-compat--functions-bound-p
                '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string)))))
    (nelix-compat--buffer-string-nelisp buffer))
   ((and (fboundp 'with-current-buffer)
         (fboundp 'buffer-string)
         (nelix-compat-buffer-live-p buffer))
    (with-current-buffer buffer
      (buffer-string)))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((nelix-compat--functions-bound-p
       '(nelisp-ec-current-buffer
         nelisp-ec-set-buffer
         nelisp-ec-buffer-string))
      (nelix-compat--buffer-string-nelisp buffer))
     ((nelix-compat--functions-bound-p
       '(nelisp-ec-with-current-buffer nelisp-ec-buffer-string))
      (nelix-compat--buffer-string-nelisp buffer))
     (t "")))))

(defun nelix-compat-kill-buffer (buffer)
  "Kill BUFFER if possible; ignore already-dead or missing buffers."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-kill-buffer)))
    (condition-case _ (nelisp-ec-kill-buffer buffer) (error nil)))
   ((and (fboundp 'kill-buffer)
         (nelix-compat-buffer-live-p buffer))
    (condition-case _ (kill-buffer buffer) (error nil)))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (when (fboundp 'nelisp-ec-kill-buffer)
      (condition-case _ (nelisp-ec-kill-buffer buffer) (error nil))))))

;;;; --- environment / path helpers -------------------------------------------

(defun nelix-compat-getenv (var &optional default)
  "Return env var VAR or DEFAULT.
Tries Emacs `getenv', then NeLisp Layer-2 alternatives."
  (let ((v (and (nelix-compat--runtime-nelisp-p)
                nelix-compat-nelisp-getenv-function
                (funcall nelix-compat-nelisp-getenv-function var))))
    (unless v
      (setq v (and (fboundp 'getenv) (getenv var))))
    (unless v
      (nelix-compat--try-require-nelisp-backends)
      (setq v
            (or (nelix-compat--call-optional-backend
                 'nelisp-sys-getenv var)
                (nelix-compat--call-optional-backend
                 'nelisp-syscall-getenv var))))
    (unless v
      (nelix-compat--try-require-nelisp-emacs-compat)
      (setq v
            (or (nelix-compat--call-optional-backend
                 'nelisp-syscall-getenv var)
                (nelix-compat--call-optional-backend
                 'nelisp-ec-getenv var))))
    (or v default)))

(defun nelix-compat-executable-find (cmd)
  "Find executable CMD on PATH; return absolute path or nil."
  (or (and (nelix-compat--runtime-nelisp-p)
           nelix-compat-nelisp-executable-find-function
           (funcall nelix-compat-nelisp-executable-find-function cmd))
      (and (fboundp 'executable-find) (executable-find cmd))
      (progn
        (nelix-compat--try-require-nelisp-emacs-compat)
        (nelix-compat--call-optional-backend
         'nelisp-ec-executable-find cmd))))

;;;; --- filesystem ----------------------------------------------------------

(defun nelix-compat-file-exists-p (path)
  "Return non-nil if PATH exists."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-file-exists-p)))
    (nelisp-ec-file-exists-p path))
   ((fboundp 'file-exists-p) (file-exists-p path))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-file-exists-p) (nelisp-ec-file-exists-p path))))))

(defun nelix-compat-make-directory (path &optional parents)
  "Create directory PATH; non-nil PARENTS makes -p style."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-make-directory)))
    (nelisp-ec-make-directory path (or parents t)))
   ((fboundp 'make-directory) (make-directory path (or parents t)))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-make-directory)
      (nelisp-ec-make-directory path (or parents t)))
     (t (error "no make-directory implementation available"))))))

(defun nelix-compat-delete-file-quietly (path)
  "Delete PATH if it exists; ignore failures."
  (when (nelix-compat-file-exists-p path)
    (cond
     ((and (nelix-compat--runtime-nelisp-p)
           (progn
             (nelix-compat--try-require-nelisp-emacs-compat)
             (fboundp 'nelisp-ec-delete-file)))
      (condition-case _ (nelisp-ec-delete-file path) (error nil)))
     ((fboundp 'delete-file)
      (condition-case _ (delete-file path) (error nil)))
     (t
      (nelix-compat--try-require-nelisp-emacs-compat)
      (when (fboundp 'nelisp-ec-delete-file)
        (condition-case _ (nelisp-ec-delete-file path) (error nil)))))))

(defun nelix-compat-read-file (path)
  "Return the entire contents of PATH as a string."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (fboundp 'rdf))
    (or (rdf path) ""))
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (nelix-compat--functions-bound-p
            '(nelisp-ec-insert-file-contents
              nelisp-ec-generate-new-buffer
              nelisp-ec-with-current-buffer
              nelisp-ec-buffer-string))))
    ;; NeLisp Layer-2 path
    (let ((buf (nelisp-ec-generate-new-buffer "*nelix-core-read*")))
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
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((nelix-compat--functions-bound-p
       '(nelisp-ec-insert-file-contents
         nelisp-ec-generate-new-buffer
         nelisp-ec-with-current-buffer
         nelisp-ec-buffer-string))
      (let ((buf (nelisp-ec-generate-new-buffer "*nelix-core-read*")))
        (unwind-protect
            (progn
              (nelisp-ec-with-current-buffer buf
                (nelisp-ec-insert-file-contents path)
                (nelisp-ec-buffer-string)))
          (when (fboundp 'nelisp-ec-kill-buffer)
            (nelisp-ec-kill-buffer buf)))))
     (t (error "no read-file backend available for %S" path))))))

(defun nelix-compat--read-file-binary (path)
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
    (nelix-compat-read-file path))))

(defun nelix-compat-write-file (path content)
  "Write CONTENT (string) to PATH, overwriting."
  (cond
   ((and (nelix-compat--runtime-nelisp-p)
         (progn
           (nelix-compat--try-require-nelisp-emacs-compat)
           (fboundp 'nelisp-ec-write-region)))
    ;; nelisp-ec-write-region is the Layer-2 equivalent
    (nelisp-ec-write-region content nil path nil 'silent))
   ((fboundp 'with-temp-file)
    (with-temp-file path
      (insert content)))
   (t
    (nelix-compat--try-require-nelisp-emacs-compat)
    (cond
     ((fboundp 'nelisp-ec-write-region)
      (nelisp-ec-write-region content nil path nil 'silent))
     (t (error "no write-file backend available for %S" path))))))

(defun nelix-compat-make-temp-file (prefix)
  "Create a unique writable file with PREFIX under TMPDIR; return path."
  (cond
   ((fboundp 'make-temp-file) (make-temp-file prefix))
   (t
    (let* ((tmpdir (or (nelix-compat-getenv "TMPDIR") "/tmp"))
           (pid (cond ((fboundp 'emacs-pid) (emacs-pid))
                      ((fboundp 'nelisp-syscall-getpid) (nelisp-syscall-getpid))
                      (t 0)))
           (counter (abs (random)))
           (path (format "%s/%s%d-%d" tmpdir prefix pid counter)))
      (nelix-compat-write-file path "")
      path))))

;;;; --- subprocess -----------------------------------------------------------

(defun nelix-compat-call-process (program args)
  "Run PROGRAM with string-list ARGS synchronously.
Returns plist (:exit INT :stdout STRING :stderr STRING).

Emacs path uses a temp buffer for stdout (= the call-process
contract Emacs guarantees) and a temp file for stderr.  NeLisp
path uses two temp files since nelisp-call-process accepts string
filenames as destinations.  Either way the caller sees the same
plist."
  (cond
   ((and (nelix-compat--emacs-runtime-p)
         (fboundp 'generate-new-buffer)
         (fboundp 'call-process))
    (nelix-compat--call-process-emacs program args))
   ((and (nelix-compat--runtime-nelisp-p)
         nelix-compat-nelisp-call-process-function)
    (nelix-compat--validate-call-process-result
     (funcall nelix-compat-nelisp-call-process-function program args)
     "nelix-compat-nelisp-call-process-function"))
   ((fboundp 'nelisp-call-process)
    (nelix-compat--call-process-nelisp program args))
   (t (error "no call-process backend available"))))

(defun nelix-compat--call-process-emacs (program args)
  "Emacs backend for `nelix-compat-call-process'.
Buffer for stdout, temp file for stderr."
  (let ((stdout-buf (generate-new-buffer " *nelix-core-stdout*"))
        (stderr-file (nelix-compat-make-temp-file "nelix-core-stderr-")))
    (unwind-protect
        (let ((exit (apply #'call-process
                           program nil
                           (list stdout-buf stderr-file)
                           nil args)))
          (list :exit (if (numberp exit) exit -1)
                :stdout (with-current-buffer stdout-buf (buffer-string))
                :stderr (nelix-compat-read-file stderr-file)))
      (when (and (fboundp 'buffer-live-p) (buffer-live-p stdout-buf))
        (kill-buffer stdout-buf))
      (nelix-compat-delete-file-quietly stderr-file))))

(defun nelix-compat--call-process-nelisp (program args)
  "NeLisp backend for `nelix-compat-call-process'.
nelisp-call-process accepts string filenames in the destination
cons, so we use two temp files and read them back."
  (let ((stdout-file (nelix-compat-make-temp-file "nelix-core-stdout-"))
        (stderr-file (nelix-compat-make-temp-file "nelix-core-stderr-")))
    (unwind-protect
        (let ((exit (apply #'nelisp-call-process
                           program nil
                           (list stdout-file stderr-file)
                           nil args)))
          (list :exit (if (numberp exit) exit -1)
                :stdout (nelix-compat-read-file stdout-file)
                :stderr (nelix-compat-read-file stderr-file)))
      (nelix-compat-delete-file-quietly stdout-file)
      (nelix-compat-delete-file-quietly stderr-file))))

;;;; --- JSON -----------------------------------------------------------------

(defun nelix-compat-json-parse (str)
  "Parse JSON STR into Elisp tree.  Empty / blank input returns nil.
Object -> alist, array -> list, null/false -> nil."
  (let ((trimmed (nelix-compat-string-trim (or str ""))))
    (when (> (length trimmed) 0)
      (cond
       ((fboundp 'json-parse-string)
        (json-parse-string trimmed
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object nil))
       (t
        (nelix-compat--try-require-nelisp-json)
        (cond
         ((fboundp 'nelisp-json-parse-string)
          (nelix-compat--json-symbolize-alist-keys
           (nelisp-json-parse-string trimmed
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil)))
         (t (error "no JSON parser backend available"))))))))

(defun nelix-compat--json-symbolize-alist-keys (value)
  "Normalize NeLisp JSON alist object keys to Emacs `json-parse-string' keys."
  (cond
   ((and (consp value)
         (consp (car value))
         (or (stringp (caar value))
             (symbolp (caar value))))
    (mapcar (lambda (entry)
              (if (consp entry)
                  (cons (if (stringp (car entry))
                            (intern (car entry))
                          (car entry))
                        (nelix-compat--json-symbolize-alist-keys
                         (cdr entry)))
                (nelix-compat--json-symbolize-alist-keys entry)))
            value))
   ((consp value)
    (mapcar #'nelix-compat--json-symbolize-alist-keys value))
   (t value)))

(defun nelix-compat-json-serialize (obj)
  "Serialize OBJ to a JSON string.

Uses Emacs `json-serialize' when available, otherwise the
package-split NeLisp `nelisp-json-serialize' backend.  Hash tables
are the recommended representation for JSON objects because both
backends preserve empty objects that way."
  (cond
   ((fboundp 'json-serialize)
    (json-serialize obj :null-object :null :false-object :json-false))
   (t
    (nelix-compat--try-require-nelisp-json)
    (cond
     ((fboundp 'nelisp-json-serialize)
      (nelisp-json-serialize obj))
     (t (error "no JSON serializer backend available"))))))

;;;; --- string utility -------------------------------------------------------

(defun nelix-compat-string-trim (str)
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

(defcustom nelix-compat-credential-env-alist
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
`nelix-compat-credential-for-url' resolves an URL whose host
matches HOST exactly, the env vars are checked in order; the first
non-empty one wins.  Returning a token here causes the HTTP
helpers to inject =Authorization: Bearer TOKEN= and the git
helpers to inject =-c http.HOST.extraheader=.

GitHub subdomains (raw.githubusercontent.com, api.github.com etc.)
are listed explicitly because host matching is exact rather than
suffix-based — a single GitHub PAT works against all of them.

Phase 4-G design L40: env-var-only credential model.  Tokens
are never persisted to `nelix-state' or any on-disk file."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'nelix-core)

(defun nelix-compat--url-host (url)
  "Return the lowercased host component of URL, or nil."
  (when (and (stringp url)
             (string-match "\\`[a-z][a-z0-9+.-]*://\\([^/?#]+\\)" url))
    (let ((host (match-string 1 url)))
      (when host (downcase host)))))

(defun nelix-compat-credential-for-url (url)
  "Return =Bearer TOKEN= for URL, or nil if no credential applies.

Looks up URL's host in `nelix-compat-credential-env-alist'
and walks the env-var list; the first env var whose value is
non-empty wins.

Phase 4-G L41."
  (let* ((host (nelix-compat--url-host url))
         (entry (and host (assoc host nelix-compat-credential-env-alist)))
         (vars  (cdr entry))
         (token nil))
    (while (and vars (null token))
      (let ((v (nelix-compat-getenv (car vars))))
        (when (and v (> (length v) 0))
          (setq token v)))
      (setq vars (cdr vars)))
    (when token (concat "Bearer " token))))

(defun nelix-compat-mask-credentials (str)
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

(defun nelix-compat-http-get (url &optional timeout auth-header)
  "Synchronously fetch URL.  TIMEOUT defaults to 5 seconds.

AUTH-HEADER (Phase 4-G L41), when non-nil, is the full
=Authorization:= value (without the field name) injected into
the request — e.g. \"Bearer ghp_xxx\".  When nil, host-based
auto-detection runs via `nelix-compat-credential-for-url'
so existing callers transparently pick up credentials from
environment variables.

Returns plist (:status INT :body STRING).  On NeLisp, an explicit
backend hook wins; otherwise a loaded `nelisp-http-get' or
`nelisp-http-fetch' backend is used.  If neither exists, the NeLisp
branch falls back to `curl'
through the binary HTTP curl adapter.  If no native backend and no
curl path are available, signals `nelix-http-not-supported'.
Network errors / non-2xx responses return :status N (the actual code
or 0 on connection failure) with :body empty.

Phase 4-C: Emacs implementation uses `url-retrieve-synchronously'
and parses the HTTP status line out of the response buffer's first
line (we do not rely on `url-http-response-status' because the
buffer may not have full HTTP metadata in some Emacs versions)."
  (pcase (nelix-compat-runtime)
    ('emacs
     (let* ((to (or timeout 5))
            (auth (or auth-header (nelix-compat-credential-for-url url)))
            (res (nelix-compat--http-get-emacs url to auth)))
       ;; On the standalone NeLisp reader (nemacs), `url-retrieve-synchronously'
       ;; is non-functional (returns nil), so a :status 0 there means "no
       ;; working url.el backend", not "connection failed".  Fall back to the
       ;; tested curl path, which does work on nemacs (call-process + curl).
       ;; Host Emacs (no reader primitive) keeps url.el authoritative -- a
       ;; genuine status-0 connection failure is returned as-is.
       (if (and (eq (plist-get res :status) 0)
                (fboundp 'nelisp--write-stdout-bytes)
                (nelix-compat-executable-find "curl"))
           (nelix-compat--http-get-curl url to auth)
         res)))
    ('nelisp
     (if nelix-compat-nelisp-http-get-function
         (nelix-compat--validate-http-result
          (funcall nelix-compat-nelisp-http-get-function
                   url
                   (or timeout 5)
                   (or auth-header (nelix-compat-credential-for-url url)))
          "nelix-compat-nelisp-http-get-function")
       (nelix-compat--try-require-nelisp-backends)
       (if (or (fboundp 'nelisp-http-get)
               (fboundp 'nelisp-http-fetch))
           (let ((timeout (or timeout 5))
                 (auth (or auth-header
                           (nelix-compat-credential-for-url url))))
             (nelix-compat--http-get-curl-after-native-zero
              (nelix-compat--http-get-nelisp url timeout auth)
              url
              timeout
              auth))
         (nelix-compat--http-get-curl
          url
          (or timeout 5)
          (or auth-header (nelix-compat-credential-for-url url))))))
    (_
     (signal 'nelix-http-not-supported
             (list (format "nelix-compat-http-get: no backend for runtime %S"
                           (nelix-compat-runtime)))))))

(defun nelix-compat--http-get-emacs (url timeout &optional auth-header)
  "Emacs backend for `nelix-compat-http-get'.

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

(defun nelix-compat--headers-for-auth (auth-header)
  "Return HTTP header alist for AUTH-HEADER, or nil."
  (when auth-header
    (list (cons "Authorization" auth-header))))

(defun nelix-compat--http-get-nelisp (url timeout &optional auth-header)
  "NeLisp backend adapter for `nelix-compat-http-get'.

Uses `nelisp-http-get' when the NeLisp network package is already
loaded, or `nelisp-http-fetch' when the higher-level NeLisp HTTP
package is available.  The adapter normalizes the result into
nelix-core's small (:status INT :body STRING) contract and degrades
backend errors to status 0, matching the Emacs backend's
network-failure behaviour."
  (condition-case _err
      (let* ((headers (nelix-compat--headers-for-auth auth-header))
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

(defun nelix-compat--http-get-curl (url timeout &optional auth-header)
  "Text HTTP fallback for NeLisp via the binary curl adapter.

This keeps the text HTTP contract (:status INT :body STRING) while
reusing the tested curl header/body split path from
`nelix-compat--http-get-binary-curl'.  Unsupported-runtime
signals from the underlying curl path are intentionally preserved."
  (let ((resp (nelix-compat--http-get-binary-curl
               url timeout auth-header)))
    (list :status (plist-get resp :status)
          :body (plist-get resp :body))))

(defun nelix-compat--http-get-curl-after-native-zero
    (resp url timeout auth-header)
  "Return RESP or retry text HTTP through curl after native status 0.

Auto-detected NeLisp HTTP packages can be loadable before their lower
runtime primitives are executable.  In that case the normalized native
adapter returns status 0; use the curl fallback if it is available,
but keep RESP when curl itself is unsupported."
  (if (eq (plist-get resp :status) 0)
      (condition-case _
          (nelix-compat--http-get-curl url timeout auth-header)
        (nelix-http-not-supported resp))
    resp))

(defun nelix-compat--http-get-binary-nelisp (url timeout &optional auth-header)
  "NeLisp backend adapter for `nelix-compat-http-get-binary'.

Uses `nelisp-http-get-binary' when the NeLisp network package exposes
a raw-byte download primitive.  The adapter normalizes the result into
(:status INT :body STRING :content-length INT-OR-NIL) and degrades
backend errors to status 0, matching the Emacs binary HTTP backend's
network-failure behaviour."
  (condition-case _err
      (let* ((resp (nelisp-http-get-binary
                    url
                    :headers (nelix-compat--headers-for-auth auth-header)
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

(defun nelix-compat--http-get-binary-curl-after-native-zero
    (resp url timeout auth-header)
  "Return RESP or retry binary HTTP through curl after native status 0."
  (if (eq (plist-get resp :status) 0)
      (condition-case _
          (nelix-compat--http-get-binary-curl url timeout auth-header)
        (nelix-http-not-supported resp))
    resp))

(defun nelix-compat--parse-curl-headers (headers)
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

(defun nelix-compat--http-get-binary-curl (url timeout &optional auth-header)
  "Fetch URL as raw bytes using curl.

This is the NeLisp fallback when no native binary HTTP hook is
installed.  It writes headers and body to separate temp files so the
binary response is never mixed with textual HTTP metadata."
  (let ((curl (nelix-compat-executable-find nelix-compat-curl-program)))
    (unless curl
      (signal 'nelix-http-not-supported
              (list (format "nelix-compat-http-get-binary: no NeLisp binary HTTP backend and %s not found"
                            nelix-compat-curl-program))))
    (let ((headers-file (nelix-compat-make-temp-file "nelix-core-curl-headers-"))
          (body-file (nelix-compat-make-temp-file "nelix-core-curl-body-")))
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
                           (nelix-compat-call-process curl args)
                         (error
                          (signal 'nelix-http-not-supported
                                  (list (format "nelix-compat-http-get-binary: curl fallback cannot run %s (%s)"
                                                curl
                                                (error-message-string err)))))))
                 (exit (plist-get resp :exit)))
            (if (not (eq exit 0))
                (list :status 0 :body "" :content-length nil)
              (let* ((header-info
                      (nelix-compat--parse-curl-headers
                       (nelix-compat-read-file headers-file)))
                     (status (plist-get header-info :status)))
                (list :status status
                      :body (if (eq status 0)
                                ""
                              (nelix-compat--read-file-binary body-file))
                      :content-length
                      (plist-get header-info :content-length)))))
        (nelix-compat-delete-file-quietly headers-file)
        (nelix-compat-delete-file-quietly body-file)))))

(defun nelix-compat-http-get-binary (url &optional timeout auth-header)
  "Synchronously fetch URL preserving raw bytes (no coding conversion).

Like `nelix-compat-http-get' but the response :body is the raw
byte string from the server (not decoded into multibyte characters).
Used for binary payloads such as tar.gz tarballs where the L24a
deps scrape pipes the bytes straight to a tmp file for `tar -xzOf'.

AUTH-HEADER (Phase 4-G L41), when non-nil, is the full
=Authorization:= value injected into the request.  Defaults to
host-based auto-detection via `nelix-compat-credential-for-url'.

Returns plist (:status INT :body STRING :content-length INT-OR-NIL).
The :content-length slot is parsed from the response headers when
present, so callers can refuse oversize payloads without keeping
the whole body in memory afterwards.

On NeLisp, an explicit backend hook wins; otherwise the helper falls
back to a loaded `nelisp-http-get-binary' backend, then to `curl' when
it is available on PATH.  If neither exists, signals
`nelix-http-not-supported'."
  (pcase (nelix-compat-runtime)
    ('emacs
     (nelix-compat--http-get-binary-emacs
      url
      (or timeout 30)
      (or auth-header (nelix-compat-credential-for-url url))))
    ('nelisp
     (if nelix-compat-nelisp-http-get-binary-function
         (nelix-compat--validate-binary-http-result
          (funcall nelix-compat-nelisp-http-get-binary-function
                   url
                   (or timeout 30)
                   (or auth-header (nelix-compat-credential-for-url url)))
          "nelix-compat-nelisp-http-get-binary-function")
       (nelix-compat--try-require-nelisp-backends)
       (if (fboundp 'nelisp-http-get-binary)
           (let ((timeout (or timeout 30))
                 (auth (or auth-header
                           (nelix-compat-credential-for-url url))))
             (nelix-compat--http-get-binary-curl-after-native-zero
              (nelix-compat--http-get-binary-nelisp url timeout auth)
              url
              timeout
              auth))
         (nelix-compat--http-get-binary-curl
          url
          (or timeout 30)
          (or auth-header (nelix-compat-credential-for-url url))))))
    (_
     (signal 'nelix-http-not-supported
             (list (format "nelix-compat-http-get-binary: no backend for runtime %S"
                           (nelix-compat-runtime)))))))

(defun nelix-compat--http-get-binary-emacs (url timeout &optional auth-header)
  "Emacs backend for `nelix-compat-http-get-binary'.

Identical control-flow to `nelix-compat--http-get-emacs' but
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

(defun nelix-compat-define-error-symbol (sym message &optional parent)
  "Install error-conditions / error-message on SYM.
Functional equivalent of `define-error', but works without it
(directly via `put') so it functions on NeLisp standalone too."
  (let ((parent-conds (and parent (get parent 'error-conditions)))
        (existing (get sym 'error-conditions)))
    (put sym 'error-conditions
         (delete-dups
          (append (list sym) parent-conds existing
                  (unless parent-conds '(error)))))
    (put sym 'error-message message))
  sym)

;;;; --- async subprocess (Phase 4-C L22) ------------------------------------

;; The error symbol is also redefined in `nelix-core.el' (with
;; `nelix-error' as parent) so the conditions chain routes
;; correctly when both files are loaded.  Defining it here too lets
;; callers that loaded only `nelix-compat' still signal /
;; should-error against the symbol on NeLisp.
(nelix-compat-define-error-symbol 'nelix-async-not-supported
                                      "asynchronous install not supported on this runtime")

;; Phase 4-C L18 error symbol installed at load time: callers
;; (nelix-emacs.el) can `signal' it without first requiring
;; nelix-core.
(nelix-compat-define-error-symbol 'nelix-http-not-supported
                                      "HTTP not supported on this runtime")

(defun nelix-compat-make-process-async (&rest plist)
  "Spawn an asynchronous process portably across Emacs and NeLisp.

PLIST mirrors the keyword arguments accepted by Emacs `make-process'
\(:name :command :sentinel :stderr :connection-type :noquery :buffer\).
Returns a process object on Emacs.  Signals
`nelix-async-not-supported' on NeLisp only when neither an
explicit backend hook nor a loaded `nelisp-make-process' backend is
available.

This is the sole runtime-aware async-spawn entry point for
nelix-core sub-modules; consult `nelix-compat-runtime' for the
underlying decision."
  (pcase (nelix-compat-runtime)
    ('emacs
     (apply #'make-process plist))
    ('nelisp
     (if nelix-compat-nelisp-make-process-function
         (apply nelix-compat-nelisp-make-process-function plist)
       (nelix-compat--try-require-nelisp-backends)
       (if (fboundp 'nelisp-make-process)
           (condition-case err
               (apply #'nelisp-make-process plist)
             (error
              (signal 'nelix-async-not-supported
                      (list
                       (format "nelix-compat-make-process-async: NeLisp async backend failed (%s)"
                               (error-message-string err))))))
         (signal 'nelix-async-not-supported
                 (list "nelix-compat-make-process-async: NeLisp runtime has no async backend (Phase 5)")))))
    (other
     (signal 'nelix-async-not-supported
             (list (format "nelix-compat-make-process-async: unknown runtime %S" other))))))

(provide 'nelix-compat)
;;; nelix-compat.el ends here
