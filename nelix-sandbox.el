;;; nelix-sandbox.el --- Tier 2 hermetic build isolation (Linux) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Optional, Linux-only module that runs a nelix source build inside a
;; kernel namespace sandbox (Tier 2; design 32).  It is NOT loaded by
;; default — `nelix-builder' requires it lazily only when a build requests
;; `:hermeticity 'tier2'.  Because build phases are already Elisp data
;; (the phase-elisp refactor, design 31), the entire build is re-run,
;; unchanged, inside the sandbox by a small builder child
;; (`scripts/nelix-sandbox-builder.el') that calls the existing
;; `nelix-builder--run-phase'.  This module only provides the backend-
;; neutral contract + the bwrap launch + the SPEC serialization.
;;
;; Decisions (design 32):
;;  - Mechanism: pluggable; a `bwrap' backend ships first (pure
;;    `call-process', zero new runtime primitive).  A pure-Elisp `raw-ns'
;;    backend may follow under the SAME contract (zero Rust).
;;  - Network: deny-all by default (the build's net namespace is unshared,
;;    so there is no route out); fixed-output fetch stays a host concern.
;;
;; Public API:
;;   (nelix-sandbox-run SPEC &optional BACKEND) -> (:status ok|error :code N :log STR)
;;   (nelix-sandbox-available-p &optional BACKEND) -> non-nil if usable here
;;
;; SPEC plist:
;;   :phases   ((NAME . FORM-or-SHELL-STRING) ...)  build phases (Elisp data)
;;   :inputs   ((NAME . STORE-PATH) ...)            bind read-only inside
;;   :out      PATH                                 $out, bind read-write
;;   :build    PATH                                 working dir, bind read-write
;;   :net      nil = deny-all (default) | t = share host network

;;; Code:

(require 'cl-lib)
(require 'nelix-compat)

(defgroup nelix-sandbox nil
  "Tier 2 hermetic build isolation for nelix (Linux only)."
  :group 'nelix
  :prefix "nelix-sandbox-")

(defvar nelix-sandbox--this-file (or load-file-name buffer-file-name)
  "Absolute path of this file, used to derive the repo roots.")

(defcustom nelix-sandbox-bwrap-program "bwrap"
  "The bubblewrap executable used by the `bwrap' backend."
  :type 'string
  :group 'nelix-sandbox)

(defcustom nelix-sandbox-nelix-root
  (and nelix-sandbox--this-file (file-name-directory nelix-sandbox--this-file))
  "Root directory of the nelix repository (trailing slash).
Bind-mounted read-only into the sandbox so the builder child can load the
nelix modules at their canonical paths."
  :type '(choice (const nil) directory)
  :group 'nelix-sandbox)

(defcustom nelix-sandbox-nelisp-root
  (and nelix-sandbox-nelix-root
       (file-name-as-directory
        (expand-file-name "../nelisp" nelix-sandbox-nelix-root)))
  "Root directory of the nelisp repository (trailing slash).
Bind-mounted read-only so the builder child can load `nelisp-sys' and run
under the standalone NeLisp binary inside the sandbox."
  :type '(choice (const nil) directory)
  :group 'nelix-sandbox)

(defcustom nelix-sandbox-nelisp-binary
  (or (let ((env (getenv "NELISP_BIN")))
        (and env (> (length env) 0) env))
      (and nelix-sandbox-nelisp-root
           (expand-file-name "target/nelisp" nelix-sandbox-nelisp-root)))
  "Path to the standalone NeLisp binary used to run the in-sandbox builder."
  :type '(choice (const nil) file)
  :group 'nelix-sandbox)

(defcustom nelix-sandbox-backend 'bwrap
  "Default sandbox backend.  Currently only `bwrap' is implemented."
  :type '(choice (const bwrap) (const raw-ns))
  :group 'nelix-sandbox)

(defun nelix-sandbox--builder-el ()
  "Return the absolute path of the in-sandbox builder driver."
  (expand-file-name "scripts/nelix-sandbox-builder.el" nelix-sandbox-nelix-root))

(defun nelix-sandbox--linux-p ()
  "Return non-nil when running on Linux (where namespaces exist)."
  (eq system-type 'gnu/linux))

(defun nelix-sandbox--bwrap-available-p ()
  "Return non-nil when `bwrap' is usable on this host.
Checks the binary resolves and that an unprivileged unshare actually
succeeds (covers kernels where unprivileged user namespaces are disabled)."
  (and (nelix-sandbox--linux-p)
       (or (file-name-absolute-p nelix-sandbox-bwrap-program)
           (executable-find nelix-sandbox-bwrap-program))
       (condition-case nil
           (eq 0 (call-process nelix-sandbox-bwrap-program nil nil nil
                               "--unshare-user" "--unshare-net"
                               "--ro-bind" "/usr" "/usr"
                               "--ro-bind-try" "/lib" "/lib"
                               "--ro-bind-try" "/lib64" "/lib64"
                               "--dev" "/dev" "--proc" "/proc"
                               "--" "/usr/bin/true"))
         (error nil))))

(defun nelix-sandbox--raw-ns-available-p ()
  "Return non-nil when the pure-elisp `raw-ns' backend can run here.
Requires Linux, the standalone NeLisp binary, the `nelisp--syscall-unshare'
builtin compiled in, AND that an unprivileged `unshare(CLONE_NEWUSER)'
actually succeeds (probed by running the binary once)."
  (and (nelix-sandbox--linux-p)
       (stringp nelix-sandbox-nelisp-binary)
       (file-executable-p (expand-file-name nelix-sandbox-nelisp-binary))
       (let ((probe (make-temp-file "nelix-rawns-probe-" nil ".el")))
         (unwind-protect
             (progn
               (with-temp-file probe
                 (insert "(princ (if (fboundp 'nelisp--syscall-unshare)"
                         " (nelisp--syscall-unshare 268435456) -1))"))
               (with-temp-buffer
                 (call-process (expand-file-name nelix-sandbox-nelisp-binary)
                               nil t nil "--load" probe)
                 ;; "0" => builtin present AND unshare(CLONE_NEWUSER) succeeded.
                 (string-prefix-p "0" (string-trim (buffer-string)))))
           (when (file-exists-p probe) (delete-file probe))))))

;;;###autoload
(defun nelix-sandbox-available-p (&optional backend)
  "Return non-nil when the sandbox BACKEND (default `nelix-sandbox-backend')
can run on this host."
  (pcase (or backend nelix-sandbox-backend)
    ('bwrap (nelix-sandbox--bwrap-available-p))
    ('raw-ns (nelix-sandbox--raw-ns-available-p))
    (_ nil)))

(defun nelix-sandbox--write-spec (spec)
  "Serialize SPEC (a plist) to a fresh temp file and return its path.
The builder child reads it back with `read'/`read-from-string'.  Phase
FORMS round-trip as Elisp data; the builder child canonicalizes the
standalone reader's pseudo-nil/t (see `nelix-registry--canonicalize-nil-t')."
  (let ((file (make-temp-file "nelix-sandbox-spec-" nil ".el"))
        (print-level nil)
        (print-length nil)
        (print-circle nil))
    (with-temp-file file
      (insert (format "%S\n" spec)))
    file))

(defun nelix-sandbox--bwrap-argv (spec spec-file)
  "Build the bwrap argument list for SPEC, reading the job from SPEC-FILE.
Returns a list of strings (the args after the program name)."
  (let* ((out   (expand-file-name (plist-get spec :out)))
         (build (expand-file-name (plist-get spec :build)))
         (inputs (plist-get spec :inputs))
         (deny-net (null (plist-get spec :net)))
         (nelix-root (directory-file-name
                      (expand-file-name nelix-sandbox-nelix-root)))
         (nelisp-root (directory-file-name
                       (expand-file-name nelix-sandbox-nelisp-root)))
         (args '()))
    (cl-flet ((push* (&rest xs) (dolist (x xs) (push x args))))
      ;; Namespaces.  Unsharing the net namespace removes every route,
      ;; so the build is offline (deny-all); other namespaces isolate
      ;; the filesystem/PID/IPC view.
      (push* "--unshare-user" "--unshare-ipc" "--unshare-pid"
             "--unshare-uts" "--unshare-cgroup-try")
      (when deny-net (push* "--unshare-net"))
      (push* "--die-with-parent" "--new-session")
      ;; Host toolchain + loader, read-only (Tier-0 host-toolchain stance).
      (push* "--ro-bind" "/usr" "/usr")
      (push* "--ro-bind-try" "/bin" "/bin")
      (push* "--ro-bind-try" "/sbin" "/sbin")
      (push* "--ro-bind-try" "/lib" "/lib")
      (push* "--ro-bind-try" "/lib64" "/lib64")
      (push* "--ro-bind-try" "/etc" "/etc")
      ;; nelix + nelisp trees (modules + binary) at their canonical paths.
      (push* "--ro-bind" nelix-root nelix-root)
      (push* "--ro-bind" nelisp-root nelisp-root)
      ;; Kernel pseudo-filesystems + a private /tmp.
      (push* "--proc" "/proc")
      (push* "--dev" "/dev")
      (push* "--tmpfs" "/tmp")
      ;; Writable build dir + $out (bound AFTER --tmpfs so paths under /tmp
      ;; are re-exposed on top of the private tmpfs).
      (push* "--bind" build build)
      (push* "--bind" out out)
      ;; The status marker file, read-write, so the builder child can report
      ;; success/failure back to the host (the runtime cannot via exit code).
      (let ((sf (plist-get spec :status-file)))
        (when sf
          (let ((p (expand-file-name sf)))
            (push* "--bind" p p))))
      ;; Declared input closure, read-only, at identical paths so
      ;; (nelix-input NAME) resolves the same inside and out.
      (dolist (in inputs)
        (let ((p (expand-file-name (cdr in))))
          (push* "--ro-bind" p p)))
      ;; Extra read-only toolchain paths (T3, design 32): a content-addressed
      ;; toolchain opt-in.  When empty the host /usr bound above provides the
      ;; compiler (same-host reproducible; cross-host repro needs a pinned
      ;; toolchain here).
      (dolist (tc (plist-get spec :toolchain))
        (let ((p (expand-file-name tc)))
          (push* "--ro-bind" p p)))
      ;; The job spec, read-only.
      (push* "--ro-bind" spec-file spec-file)
      ;; Run in the build dir, with a scrubbed env carrying only the spec
      ;; pointer + a minimal PATH (each phase re-applies its own Tier-1 env).
      (push* "--chdir" build)
      (push* "--clearenv")
      (push* "--setenv" "NELIX_SANDBOX_SPEC" spec-file)
      (push* "--setenv" "PATH" "/usr/bin:/bin")
      (push* "--")
      (push* nelix-sandbox-nelisp-binary "--load" (nelix-sandbox--builder-el)))
    (nreverse args)))

(defun nelix-sandbox--run-bwrap (spec)
  "Run SPEC inside bubblewrap and return (:status :code :log).
Success/failure is taken from a status marker file the builder child writes
inside the sandbox: the standalone runtime always exits 0 (kill-emacs /
error / nelisp-sys-exit cannot set a non-zero code), so the process exit
code only catches crashes, not a failed phase.  The build is OK iff bwrap
exited 0 AND the status file reads \"ok\"."
  (let* ((status-file (make-temp-file "nelix-sandbox-status-"))
         (spec (append spec
                       (list :nelix-root
                             (file-name-as-directory
                              (expand-file-name nelix-sandbox-nelix-root))
                             :nelisp-root
                             (file-name-as-directory
                              (expand-file-name nelix-sandbox-nelisp-root))
                             :status-file status-file)))
         (spec-file (nelix-sandbox--write-spec spec))
         (argv (nelix-sandbox--bwrap-argv spec spec-file))
         code log status)
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq code (apply #'call-process nelix-sandbox-bwrap-program
                              nil t nil argv))
            (setq log (buffer-string)))
          (setq status (when (file-exists-p status-file)
                         (with-temp-buffer
                           (insert-file-contents status-file)
                           (buffer-string)))))
      (when (and (fboundp 'file-exists-p) (file-exists-p spec-file))
        (delete-file spec-file))
      (when (and (fboundp 'file-exists-p) (file-exists-p status-file))
        (delete-file status-file)))
    (let ((ok (and (eq code 0)
                   (stringp status)
                   (string-prefix-p "ok" status))))
      (list :status (if ok 'ok 'error)
            :code code
            :log (if (and (stringp status) (not (string-prefix-p "ok" status)))
                     (concat log "\n[status] " status)
                   log)))))

(defun nelix-sandbox--run-raw-ns (spec)
  "Run SPEC via the PURE-ELISP raw-ns backend (no bwrap; design 32 T4).
Launches the standalone NeLisp binary directly with NELIX_SANDBOX_RAWNS=1 so
the builder child unshares the namespaces in-process via
`nelisp--syscall-unshare' (CLONE_NEWUSER + uid/gid map, then
NEWNS|NEWNET|NEWUTS|NEWIPC) and runs the phases OFFLINE.  v1 isolation:
network + user/mount/ipc/uts namespaces; the filesystem is the shared host
view (no bind-mount read-only input closure yet -- that needs the
mount/pivot_root builtins).  Same status-file success protocol as bwrap."
  (let* ((status-file (make-temp-file "nelix-sandbox-status-"))
         (spec (append spec
                       (list :nelix-root
                             (file-name-as-directory
                              (expand-file-name nelix-sandbox-nelix-root))
                             :nelisp-root
                             (file-name-as-directory
                              (expand-file-name nelix-sandbox-nelisp-root))
                             :status-file status-file)))
         (spec-file (nelix-sandbox--write-spec spec))
         (process-environment
          (append (list (concat "NELIX_SANDBOX_SPEC=" spec-file)
                        "NELIX_SANDBOX_RAWNS=1"
                        (concat "NELIX_SANDBOX_UID="
                                (number-to-string (user-real-uid)))
                        (concat "NELIX_SANDBOX_GID="
                                (number-to-string (group-real-gid)))
                        "PATH=/usr/bin:/bin")
                  process-environment))
         code log status)
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq code (call-process
                        (expand-file-name nelix-sandbox-nelisp-binary)
                        nil t nil "--load" (nelix-sandbox--builder-el)))
            (setq log (buffer-string)))
          (setq status (when (file-exists-p status-file)
                         (with-temp-buffer
                           (insert-file-contents status-file)
                           (buffer-string)))))
      (when (file-exists-p spec-file) (delete-file spec-file))
      (when (file-exists-p status-file) (delete-file status-file)))
    (let ((ok (and (eq code 0)
                   (stringp status)
                   (string-prefix-p "ok" status))))
      (list :status (if ok 'ok 'error)
            :code code
            :log (if (and (stringp status) (not (string-prefix-p "ok" status)))
                     (concat log "\n[status] " status)
                   log)))))

;;;###autoload
(defun nelix-sandbox-run (spec &optional backend)
  "Run a nelix build SPEC inside a Tier 2 sandbox; return (:status :code :log).
BACKEND defaults to `nelix-sandbox-backend'.  Signals `nelix-error' if the
backend is unavailable on this host (non-Linux, no bwrap, or unprivileged
user namespaces disabled) so the caller can surface a loud Tier-1 fallback."
  (let ((backend (or backend nelix-sandbox-backend)))
    (unless (nelix-sandbox-available-p backend)
      (signal 'nelix-error
              (list (format (concat "nelix-sandbox: backend %S unavailable on this host "
                                    "(need Linux + bwrap + unprivileged user namespaces). "
                                    "Re-run with :hermeticity 'tier1 for a non-isolated build.")
                            backend))))
    (pcase backend
      ('bwrap (nelix-sandbox--run-bwrap spec))
      ('raw-ns (nelix-sandbox--run-raw-ns spec))
      (_ (signal 'nelix-error
                 (list (format "nelix-sandbox: unknown backend %S" backend)))))))

(provide 'nelix-sandbox)
;;; nelix-sandbox.el ends here
