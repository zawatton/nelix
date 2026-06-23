;;; nelix-sandbox-builder.el --- In-sandbox build phase runner -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The builder child for Tier 2 (design 32).  It runs INSIDE the namespace
;; sandbox under the standalone NeLisp binary (launched by `bwrap' from
;; `nelix-sandbox--run-bwrap'), reads the serialized job SPEC pointed to by
;; the NELIX_SANDBOX_SPEC environment variable, loads the nelix modules at
;; their bind-mounted canonical paths, and runs each build phase via the
;; UNCHANGED `nelix-builder--run-phase'.  No new build logic lives here —
;; this is the existing per-phase eval, relocated into the namespace.
;;
;; The store commit + profile generation happen on the HOST after this
;; child exits (the $out dir is bind-mounted read-write, so files written
;; here are visible to the host).  This child therefore only runs phases.
;;
;; Exit code 0 = all phases succeeded; non-zero = a phase failed (the host
;; surfaces it as a `nelix-error').

;;; Code:

(defun nelix-sandbox-builder-log (fmt &rest args)
  "Print a log line to stdout via `princ'."
  (princ (apply #'format fmt args))
  (princ "\n"))

(defun nelix-sandbox-builder-fatal (msg)
  "Print MSG as fatal and exit non-zero."
  (princ (concat "NELIX-SANDBOX-BUILDER: FATAL: " msg "\n"))
  (if (fboundp 'nelisp-sys-exit) (nelisp-sys-exit 1) (error "%s" msg)))

(defun nelix-sandbox-builder--shell-getenv (var)
  "Return environment variable VAR via a shell subprocess, or nil.
`getenv' on the standalone runtime does not read the OS environment, but a
child shell does, so this recovers env vars set by `bwrap --setenv'."
  (let ((out (with-temp-buffer
               (call-process "/bin/sh" nil t nil
                             "-c" (concat "printf '%s' \"$" var "\""))
               (buffer-string))))
    (if (and (stringp out) (> (length out) 0)) out nil)))

;; Step 1 — locate the job spec.
(defvar nelix-sandbox-builder--spec-file
  (or (nelix-sandbox-builder--shell-getenv "NELIX_SANDBOX_SPEC")
      (nelix-sandbox-builder-fatal "NELIX_SANDBOX_SPEC not set"))
  "Absolute path of the serialized job spec inside the sandbox.")

;; Step 2 — read the raw spec.  Repo roots are strings (safe even before
;; canonicalization); phase forms' pseudo-nil/t are fixed in Step 4.
(defvar nelix-sandbox-builder--raw-spec
  (car (read-from-string
        (with-temp-buffer
          (insert-file-contents nelix-sandbox-builder--spec-file)
          (buffer-string))))
  "The job spec as first read (phase nil/t not yet canonicalized).")

(defvar nelix-sandbox-builder--nelix-root
  (plist-get nelix-sandbox-builder--raw-spec :nelix-root)
  "nelix repo root, bind-mounted read-only at its canonical path.")

(defvar nelix-sandbox-builder--nelisp-root
  (plist-get nelix-sandbox-builder--raw-spec :nelisp-root)
  "nelisp repo root, bind-mounted read-only at its canonical path.")

(unless (and (stringp nelix-sandbox-builder--nelix-root)
             (stringp nelix-sandbox-builder--nelisp-root))
  (nelix-sandbox-builder-fatal "spec missing :nelix-root / :nelisp-root"))

;; Step 3 — load nelisp-sys + shims + the nelix modules.  Each load is
;; preceded by a `princ'.  This inner side-effecting form is LOAD-BEARING:
;; on the standalone runtime, loading the full module set in one tight loop
;; with no intervening side effect trips a heap-corruption crash (SIGSEGV);
;; a `princ' between loads reliably avoids it (the standalone deps driver
;; uses the same per-iteration logging).  `princ'+`concat' is used rather
;; than the `format'/`apply' logger, which is unreliable before the shims
;; are loaded.
(princ "nelix-sandbox-builder: loading nelisp-sys\n")
(load (concat nelix-sandbox-builder--nelisp-root
              "packages/nelisp-sys/src/nelisp-sys.el")
      nil t)
(princ "nelix-sandbox-builder: loading shim\n")
(load (concat nelix-sandbox-builder--nelix-root
              "scripts/nelix-standalone-shim.el")
      nil t)
(dolist (module '("nelix-compat.el" "nelix-build.el" "nelix-store.el"
                  "nelix-registry.el" "nelix-fetch.el" "nelix-backend.el"
                  "nelix-builder.el"))
  (princ (concat "nelix-sandbox-builder: loading " module "\n"))
  (load (concat nelix-sandbox-builder--nelix-root module) nil t))

;; Step 4 — canonicalize the WHOLE spec so the standalone reader's
;; pseudo-nil/t (see `nelix-registry--canonicalize-nil-t', nelix c859278)
;; does not break phase forms OR plist values such as `:inputs nil'.
(defvar nelix-sandbox-builder--spec
  (nelix-registry--canonicalize-nil-t nelix-sandbox-builder--raw-spec)
  "The canonicalized job spec.")

;; Step 5 — run each phase via the unchanged executor path.  Success/failure
;; is reported to the host by writing the SPEC's :status-file.  The standalone
;; runtime ALWAYS exits 0 (kill-emacs / error / nelisp-sys-exit all leave the
;; process exit code at 0), so a failed phase cannot be signalled via the exit
;; code; a disk marker the host reads back is the reliable channel.
(let* ((spec nelix-sandbox-builder--spec)
       (phases (plist-get spec :phases))
       (inputs (plist-get spec :inputs))
       (out (plist-get spec :out))
       (build (plist-get spec :build))
       (status-file (plist-get spec :status-file)))
  (unless (and (stringp out) (stringp build))
    (nelix-sandbox-builder-fatal "spec missing :out / :build"))
  (nelix-sandbox-builder-log
   "nelix-sandbox-builder: %d phase(s), out=%s build=%s net=%s"
   (length phases) out build (if (plist-get spec :net) "shared" "denied"))
  (condition-case err
      (progn
        (dolist (ph phases)
          (nelix-sandbox-builder-log "nelix-sandbox-builder: phase %s" (car ph))
          (nelix-builder--run-phase (car ph) (cdr ph) build out inputs))
        (when (stringp status-file)
          (write-region "ok\n" nil status-file))
        (nelix-sandbox-builder-log "NELIX-SANDBOX-BUILDER: SUCCESS"))
    (error
     (let ((msg (if (fboundp 'error-message-string)
                    (error-message-string err)
                  (format "%S" err))))
       (when (stringp status-file)
         (write-region (concat "fail: " msg "\n") nil status-file))
       (princ (concat "NELIX-SANDBOX-BUILDER: FATAL: phase failed: " msg "\n"))))))

;;; nelix-sandbox-builder.el ends here
