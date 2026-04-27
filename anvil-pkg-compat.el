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
;;   json-parse              - JSON string -> alist tree (Phase 1 schema)
;;   string-trim             - trim ASCII whitespace
;;   define-error-symbol     - install (sym 'error-conditions . msg) properties

;;; Code:

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

(defconst anvil-pkg-compat--nelisp-runtime-p
  (fboundp 'nelisp-call-process)
  "Non-nil when nelisp-process is loaded — choose Layer 2 backends.")

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
    (let ((s (or str ""))
          (start 0)
          end)
      (setq end (length s))
      (while (and (< start end)
                  (memq (aref s start) '(?\s ?\t ?\n ?\r)))
        (setq start (1+ start)))
      (while (and (> end start)
                  (memq (aref s (1- end)) '(?\s ?\t ?\n ?\r)))
        (setq end (1- end)))
      (substring s start end)))))

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

(provide 'anvil-pkg-compat)
;;; anvil-pkg-compat.el ends here
