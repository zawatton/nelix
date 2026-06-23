;;; nelix-build.el --- Lisp-native build-phase primitives -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Build-primitive vocabulary for *Lisp-native* build phases (design 31, the
;; "phase as Elisp, not a shell string" refactor).
;;
;; A native source-build recipe's :build-phases may use either form:
;;   (NAME . "shell command")  — legacy, run via `sh -c' (nelix-builder).
;;   (NAME . ELISP-FORM)       — Lisp-native: the executor `eval's the form,
;;                               which calls the primitives below.
;;
;; The orchestration (substitution, file moves, control flow, $out handling)
;; stays in Elisp data — introspectable, composable, free of shell-quoting
;; fragility (no sed delimiter clashes, no `$out' single-quote freezing).
;; Only the actual build tools (cc/make/...) are subprocesses, spawned via
;; `call-process' with a deterministic env — no shell in the loop.
;;
;; Bound by the executor during a phase eval (see nelix-builder--run-phase):
;;   `nelix-build--out' = $out (the store scratch dir); read via `(nelix-out)'.
;;   `nelix-build--dir' = the build directory (cwd).
;;
;; Works on host Emacs and on the standalone NeLisp runtime (pure Elisp over
;; call-process + file ops; no Emacs-only buffer navigation).

;;; Code:

(require 'nelix-compat)

(defvar nelix-build--out nil
  "Bound to the build output dir ($out, the store scratch dir) during a phase.")
(defvar nelix-build--dir nil
  "Bound to the build directory (working dir) during a phase.")

(define-error 'nelix-build-error "nelix-build phase primitive error")

;;;###autoload
(defun nelix-out ()
  "Return the build output directory ($out) for the current phase.
This is what a Guix `(assoc-ref outputs \"out\")' / `#$output' maps to."
  (or nelix-build--out
      (signal 'nelix-build-error '("nelix-out called outside a build phase"))))

(defun nelix-build--env ()
  "Return the deterministic environment KV list for `nelix-invoke' (Tier-1).
Sets a minimal PATH, scrubs HOME to the build dir, exports `out', and pins
SOURCE_DATE_EPOCH/TZ/LC_ALL.  Passed to env(1) so no shell is needed."
  (list (concat "out=" (or nelix-build--out ""))
        "PATH=/usr/bin:/bin"
        (concat "HOME=" (or nelix-build--dir ""))
        "SOURCE_DATE_EPOCH=1"
        "TZ=UTC"
        "LC_ALL=C"))

(defun nelix-build--stringify (x)
  "Coerce phase-argument X to a string (numbers/symbols allowed)."
  (cond ((stringp x) x)
        ((symbolp x) (symbol-name x))
        ((numberp x) (number-to-string x))
        (t (format "%s" x))))

;;;###autoload
(defun nelix-invoke (program &rest args)
  "Run PROGRAM with ARGS in the build dir with the deterministic build env.
Signals `nelix-build-error' on a non-zero exit (with captured output).
Uses env(1) to set the env without a shell, so it behaves identically on
host Emacs and the standalone NeLisp runtime."
  (let* ((prog (nelix-build--stringify program))
         (argv (mapcar #'nelix-build--stringify args))
         (env-kv (nelix-build--env))
         exit out)
    (with-temp-buffer
      (setq exit (apply #'call-process "/usr/bin/env" nil t nil
                        (append env-kv (cons prog argv))))
      (setq out (buffer-string)))
    (unless (eq exit 0)
      (signal 'nelix-build-error
              (list (format "nelix-invoke %s %S failed (exit %S):\n%s"
                            prog argv exit out))))
    exit))

;;;###autoload
(defun nelix-substitute* (file &rest clauses)
  "Apply regex CLAUSES to FILE in place — the Guix `substitute*' analogue.
Each clause is (PATTERN . REPLACEMENT) or (PATTERN REPLACEMENT); PATTERN is
an Emacs regexp, REPLACEMENT a literal string.  Pure Elisp (no sed), so
slashes / shell metacharacters in patterns are never a problem."
  (let* ((path (nelix-build--stringify file))
         (text (with-temp-buffer (insert-file-contents path) (buffer-string))))
    (dolist (clause clauses)
      (let ((pat (nelix-build--stringify (car clause)))
            (rep (nelix-build--stringify
                  (if (and (consp (cdr clause)) (cdr clause))
                      (cadr clause)       ; (PATTERN REPLACEMENT)
                    (cdr clause)))))      ; (PATTERN . REPLACEMENT)
        (setq text (replace-regexp-in-string pat rep text t t))))
    (with-temp-file path (insert text))
    path))

(defmacro nelix-with-directory (dir &rest body)
  "Run BODY with the build cwd temporarily changed to DIR (Guix
`with-directory-excursion').  Restores cwd afterward."
  (declare (indent 1))
  `(let* ((nelix-build--dir (expand-file-name ,dir nelix-build--dir))
          (default-directory (file-name-as-directory nelix-build--dir)))
     (when (and (nelix-compat--standalone-nelisp-p) (fboundp 'nelisp-sys-chdir))
       (nelisp-sys-chdir nelix-build--dir))
     (prog1 (progn ,@body)
       ;; restore cwd for subsequent primitives in the enclosing phase
       (when (and (nelix-compat--standalone-nelisp-p) (fboundp 'nelisp-sys-chdir))
         (nelisp-sys-chdir
          (file-name-as-directory (expand-file-name default-directory)))))))

;;;###autoload
(defun nelix-setenv (var val)
  "Set build env VAR to VAL for subsequent `nelix-invoke' calls in this phase."
  (setenv (nelix-build--stringify var) (nelix-build--stringify val)))

;;;###autoload
(defun nelix-mkdir-p (dir)
  "Create DIR and parents."
  (nelix-compat-make-directory (nelix-build--stringify dir) t))

;;;###autoload
(defun nelix-install-file (file dir)
  "Copy FILE into DIR, creating DIR (Guix `install-file')."
  (let ((d (nelix-build--stringify dir))
        (f (nelix-build--stringify file)))
    (nelix-compat-make-directory d t)
    (copy-file f (expand-file-name (file-name-nondirectory f)
                                   (file-name-as-directory d))
               t)))

;;;###autoload
(defun nelix-copy-file (src dst)
  "Copy SRC to DST."
  (copy-file (nelix-build--stringify src) (nelix-build--stringify dst) t))

;;;###autoload
(defun nelix-copy-recursively (src dst)
  "Recursively copy directory SRC to DST (uses cp -r via `nelix-invoke')."
  (nelix-mkdir-p (file-name-directory (directory-file-name
                                       (nelix-build--stringify dst))))
  (nelix-invoke "cp" "-r" (nelix-build--stringify src)
                (nelix-build--stringify dst)))

;;;###autoload
(defun nelix-delete-file (file)
  "Delete FILE if present."
  (let ((f (nelix-build--stringify file)))
    (when (file-exists-p f) (delete-file f))))

;;;###autoload
(defun nelix-rename (a b)
  "Rename A to B."
  (rename-file (nelix-build--stringify a) (nelix-build--stringify b) t))

(provide 'nelix-build)
;;; nelix-build.el ends here
