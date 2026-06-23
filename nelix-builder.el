;;; nelix-builder.el --- Nelix native builders -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase N4/N5 native builders.  The implemented builders fetch a
;; hash-verified archive, extract it into the native store, write store
;; metadata, and create a profile generation.

;;; Code:

(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-compat)
(require 'nelix-fetch)
(require 'nelix-store)
(require 'nelix-registry)

(defgroup nelix-builder nil
  "Nelix native builders."
  :group 'nelix-core
  :prefix "nelix-builder-")

(defcustom nelix-builder-default-profile "default"
  "Default native profile name for `nelix-native-install'."
  :type 'string
  :group 'nelix-builder)

(defvar nelix-builder--install-stack nil
  "Dynamic stack of native package names currently being installed.")

(defun nelix-builder--system-entry (recipe system)
  "Return RECIPE's system entry for SYSTEM."
  (let (found)
    (dolist (entry (plist-get recipe :systems) found)
      (when (and (null found)
                 (consp entry)
                 (eq (car entry) system))
        (setq found (cdr entry))))))

(defun nelix-builder--archive-format (source archive)
  "Return archive format for SOURCE and ARCHIVE."
  (or (plist-get source :archive-format)
      (cond
       ((string-match-p "\\.zip\\'" archive) 'zip)
       ((string-match-p "\\.\\(tar\\|tar\\.gz\\|tgz\\|tar\\.xz\\)\\'" archive) 'tar)
       (t 'tar))))

(defun nelix-builder--run (program args)
  "Run PROGRAM with ARGS or signal `nelix-error'."
  (unless (nelix-compat-executable-find program)
    (signal 'nelix-error
            (list (format "nelix-builder: required program not found: %s"
                          program))))
  (let ((res (if (fboundp 'call-process)
                 (with-temp-buffer
                   (let ((exit (apply #'call-process
                                      program
                                      nil
                                      (current-buffer)
                                      nil
                                      args)))
                     (list :exit exit
                           :stdout (buffer-string)
                           :stderr "")))
               (nelix-compat-call-process program args))))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-error
              (list (format "nelix-builder: %s failed: %s"
                            program
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) ""))))))
    res))

(defun nelix-builder--strip-components (path root count)
  "Return PATH relative to ROOT with COUNT leading components removed."
  (let* ((relative (file-relative-name path root))
         (components (split-string relative "/" t)))
    (when (> (length components) count)
      (mapconcat #'identity (nthcdr count components) "/"))))

(defun nelix-builder--copy-stripped-files (source-root dest count)
  "Copy files from SOURCE-ROOT into DEST after stripping COUNT path components."
  (dolist (path (directory-files-recursively source-root ".*" t))
    (unless (file-directory-p path)
      (let ((relative (nelix-builder--strip-components
                       path source-root count)))
        (when relative
          (nelix-builder--copy-path
           path
           (expand-file-name relative dest)))))))

(defun nelix-builder--extract-archive (archive dest source install)
  "Extract ARCHIVE into DEST according to SOURCE and INSTALL."
  (nelix-compat-make-directory dest t)
  (pcase (nelix-builder--archive-format source archive)
    ('tar
     (let ((args (append (list "-xf" (expand-file-name archive)
                               "-C" (expand-file-name dest))
                         (when (plist-get install :strip-components)
                           (list (format "--strip-components=%s"
                                         (plist-get install :strip-components)))))))
       (nelix-builder--run "tar" args)))
    ('zip
     (let ((strip-components (or (plist-get install :strip-components) 0)))
       (if (and (integerp strip-components)
                (> strip-components 0))
           (let ((extract-dir (make-temp-file "nelix-zip-extract-" t)))
             (unwind-protect
                 (progn
                   (nelix-builder--run "unzip"
                                       (list "-q" (expand-file-name archive)
                                             "-d" (expand-file-name extract-dir)))
                   (nelix-builder--copy-stripped-files
                    extract-dir dest strip-components))
               (when (and (fboundp 'file-directory-p)
                          (file-directory-p extract-dir))
                 (delete-directory extract-dir t))))
         (nelix-builder--run "unzip"
                             (list "-q" (expand-file-name archive)
                                   "-d" (expand-file-name dest))))))
    (format
     (signal 'nelix-error
             (list (format "nelix-builder: unsupported archive format %S"
                           format))))))

(defun nelix-builder--chmod-runtime-bins (store-path install)
  "Mark declared runtime binaries executable where POSIX modes exist."
  (when (and (not (eq system-type 'windows-nt))
             (fboundp 'set-file-modes))
    (dolist (bin (plist-get install :bin))
      (let ((path (expand-file-name bin store-path)))
        (when (nelix-compat-file-exists-p path)
          (set-file-modes path #o755))))))

(defun nelix-builder--windows-system-p (system)
  "Return non-nil when SYSTEM is a Windows platform id."
  (memq system '(x86_64-windows aarch64-windows i686-windows)))

(defun nelix-builder--copy-path (source dest)
  "Copy SOURCE into DEST, creating parent directories."
  (nelix-compat-make-directory (file-name-directory dest) t)
  (cond
   ((and (fboundp 'file-directory-p)
         (file-directory-p source))
    (copy-directory source dest t t t))
   ((nelix-compat-file-exists-p source)
    (copy-file source dest t))
   (t
    (signal 'nelix-error
            (list (format "nelix-builder: copy source missing: %s"
                          source))))))

(defun nelix-builder--copy-source-contents (source-dir store-path)
  "Copy SOURCE-DIR contents into STORE-PATH."
  (dolist (entry (directory-files source-dir t))
    (unless (member (file-name-nondirectory entry) '("." ".."))
      (nelix-builder--copy-path
       entry
       (expand-file-name (file-name-nondirectory entry) store-path)))))

(defun nelix-builder--copy-spec-pair (spec)
  "Return (FROM . TO) for copy SPEC."
  (cond
   ((stringp spec)
    (cons spec spec))
   ((and (consp spec)
         (stringp (car spec))
         (stringp (cdr spec)))
    spec)
   ((and (listp spec)
         (plist-get spec :from)
         (plist-get spec :to))
    (cons (plist-get spec :from)
          (plist-get spec :to)))
   (t
    (signal 'nelix-error
            (list (format "nelix-builder: invalid copy file spec %S"
                          spec))))))

(defun nelix-builder--copy-files (source-path store-path install)
  "Copy local SOURCE-PATH into STORE-PATH according to INSTALL."
  (let ((files (plist-get install :files)))
    (cond
     (files
      (dolist (spec files)
        (let* ((pair (nelix-builder--copy-spec-pair spec))
               (from (expand-file-name (car pair) source-path))
               (to (expand-file-name (cdr pair) store-path)))
          (nelix-builder--copy-path from to))))
     ((and (fboundp 'file-directory-p)
           (file-directory-p source-path))
      (nelix-builder--copy-source-contents source-path store-path))
     (t
      (nelix-builder--copy-path
       source-path
       (expand-file-name (file-name-nondirectory source-path)
                         store-path))))))

(defun nelix-builder-runtime-paths (install)
  "Return runtime path directories declared by INSTALL."
  (or (plist-get install :runtime-paths)
      (let (dirs)
        (dolist (bin (plist-get install :bin) (nreverse dirs))
          (let ((dir (file-name-directory bin)))
            (when dir
              (setq dir (directory-file-name dir))
              (unless (member dir dirs)
                (push dir dirs))))))))

(defun nelix-builder-emacs-load-paths (install)
  "Return relative Emacs load-path directories declared by INSTALL."
  (or (plist-get install :load-paths)
      (plist-get install :emacs-load-paths)
      (when (eq (plist-get install :type) 'emacs-lisp)
        '("."))))

(defun nelix-builder--absolute-emacs-load-paths (store-path install)
  "Return absolute Emacs load-path directories for STORE-PATH and INSTALL."
  (mapcar (lambda (path) (expand-file-name path store-path))
          (nelix-builder-emacs-load-paths install)))

;;;###autoload
(defun nelix-builder-render-windows-shim (command target)
  "Return a simple Windows cmd shim invoking TARGET with all arguments."
  (format "@echo off\r\n\"%s\" %%*\r\n" (or target command)))

;;;###autoload
(defun nelix-builder-render-posix-shim (command target)
  "Return a POSIX shell shim invoking TARGET with all arguments."
  (format "#!/bin/sh\nexec \"%s\" \"$@\"\n" (or target command)))

(defun nelix-builder--script-shim-command (install)
  "Return script shim command declared by INSTALL."
  (let ((command (or (plist-get install :command)
                     (plist-get install :name))))
    (cond
     ((and (stringp command)
           (> (length (nelix-compat-string-trim command)) 0))
      (nelix-compat-string-trim command))
     ((symbolp command) (symbol-name command))
     (t
      (signal 'nelix-error
              (list (format "nelix-builder: script-shim requires :command, got %S"
                            install)))))))

(defun nelix-builder--script-shim-target (install)
  "Return script shim target declared by INSTALL."
  (let ((target (or (plist-get install :target)
                    (plist-get install :program)
                    (plist-get install :command))))
    (cond
     ((and (stringp target)
           (> (length (nelix-compat-string-trim target)) 0))
      (nelix-compat-string-trim target))
     ((symbolp target) (symbol-name target))
     (t
      (signal 'nelix-error
              (list (format "nelix-builder: script-shim requires :target, got %S"
                            install)))))))

(defun nelix-builder--script-shim-target-available-p (target)
  "Return non-nil when script shim TARGET is currently executable."
  (cond
   ((file-name-absolute-p target)
    (and (nelix-compat-file-exists-p target)
         (or (not (fboundp 'file-executable-p))
             (file-executable-p target))))
   (t
    (nelix-compat-executable-find target))))

(defun nelix-builder--require-script-shim-target (install target)
  "Signal when INSTALL requires TARGET and TARGET is unavailable."
  (when (and (plist-get install :require-target)
             (not (nelix-builder--script-shim-target-available-p target)))
    (signal 'nelix-error
            (list (format "nelix-builder: script-shim target not found: %s"
                          target)))))

(defun nelix-builder--script-shim-runtime-bin (install system)
  "Return runtime bin path for script-shim INSTALL on SYSTEM."
  (or (car (plist-get install :bin))
      (let* ((command (file-name-nondirectory
                       (nelix-builder--script-shim-command install)))
             (basename (if (nelix-builder--windows-system-p system)
                           (concat (file-name-sans-extension command) ".cmd")
                         command)))
        (concat "bin/" basename))))

(defun nelix-builder--script-shim-install (install system)
  "Return INSTALL with a concrete runtime :bin for SYSTEM."
  (let ((install* (copy-sequence install)))
    (plist-put install*
               :bin
               (list (nelix-builder--script-shim-runtime-bin install system)))))

(defun nelix-builder--script-shim-hash (recipe system install)
  "Return deterministic hash for script-shim RECIPE on SYSTEM."
  (nelix-fetch-sha256-string
   (format "%S" (list :builder 'script-shim
                      :name (plist-get recipe :name)
                      :version (plist-get recipe :version)
                      :system system
                      :install install))))

(defun nelix-builder--write-script-shim (store-path install system)
  "Write script-shim INSTALL into STORE-PATH for SYSTEM."
  (let* ((command (nelix-builder--script-shim-command install))
         (target (nelix-builder--script-shim-target install))
         (runtime-bin (nelix-builder--script-shim-runtime-bin install system))
         (path (expand-file-name runtime-bin store-path))
         (content (if (nelix-builder--windows-system-p system)
                      (nelix-builder-render-windows-shim command target)
                    (nelix-builder-render-posix-shim command target))))
    (nelix-builder--require-script-shim-target install target)
    (nelix-compat-make-directory (file-name-directory path) t)
    (nelix-compat-write-file path content)
    (when (and (not (nelix-builder--windows-system-p system))
               (fboundp 'set-file-modes))
      (set-file-modes path #o755))
    path))

(defun nelix-builder--profile-entry (entry store-path install)
  "Return profile entry plist for ENTRY at STORE-PATH."
  (let ((entry* (list :name (plist-get entry :name)
                      :version (plist-get entry :version)
                      :store-path store-path
                      :runtime-paths (nelix-builder-runtime-paths install)
                      :backend 'nelix-native))
        (load-paths (nelix-builder-emacs-load-paths install))
        (features (plist-get install :features)))
    (when load-paths
      (setq entry*
            (plist-put entry*
                       :emacs-load-paths
                       (nelix-builder--absolute-emacs-load-paths
                        store-path install))))
    (when features
      (setq entry* (plist-put entry* :features features)))
    (when (plist-get install :bin)
      (setq entry* (plist-put entry* :runtime-bins
                              (plist-get install :bin))))
    entry*))

(defvar nelix-builder--profile-entries-cache nil
  "Profile-entries cache active during a batch apply install loop.

When bound to a cons cell `(PROFILE-NAME . ENTRIES)' by
`nelix-builder-with-profile-entries-cache', each install reuses the
in-memory ENTRIES instead of re-reading and re-parsing the growing profile
from disk.  Under the standalone NeLisp runtime `nelix-profile-read' parses
the profile with an interpreted `read-from-string', so re-reading it once
per install makes an N-package apply O(N^2); the cache makes it O(N).  nil =
disabled (always read from disk).  Updated by
`nelix-builder--create-profile-generation' after each generation is written.
The apply install loop enables it by dynamically binding this to a fresh
cons cell.")

(defun nelix-builder--profile-current-entries (profile-name)
  "Return current entries for PROFILE-NAME, or nil when no profile exists."
  (if (and (consp nelix-builder--profile-entries-cache)
           (equal (car nelix-builder--profile-entries-cache) profile-name))
      (cdr nelix-builder--profile-entries-cache)
    (condition-case nil
        (plist-get (nelix-profile-read profile-name) :entries)
      (error nil))))

(defun nelix-builder--profile-entry-key (entry)
  "Return stable replacement key for profile ENTRY."
  (or (plist-get entry :name)
      (plist-get entry :store-path)))

(defun nelix-builder--profile-entries-with (profile-name entry)
  "Return PROFILE-NAME entries with ENTRY appended, replacing same-name rows."
  (let ((key (nelix-builder--profile-entry-key entry))
        kept)
    (dolist (existing (nelix-builder--profile-current-entries profile-name)
                      (nreverse (cons entry kept)))
      (unless (equal key (nelix-builder--profile-entry-key existing))
        (push existing kept)))))

(defun nelix-builder--create-profile-generation
    (profile-name system entry)
  "Create PROFILE-NAME generation for SYSTEM including ENTRY."
  (let ((entries (nelix-builder--profile-entries-with profile-name entry)))
    ;; Keep the cache (when enabled) in sync with what we just wrote so the
    ;; next install in the batch reads ENTRIES from memory, not from disk.
    (when (consp nelix-builder--profile-entries-cache)
      (setcar nelix-builder--profile-entries-cache profile-name)
      (setcdr nelix-builder--profile-entries-cache entries))
    (nelix-profile-create-generation profile-name system entries)))

(defun nelix-builder--store-entry (recipe system source install fetch-report)
  "Return store entry plist for RECIPE."
  (let ((entry (list :name (plist-get recipe :name)
                     :version (plist-get recipe :version)
                     :system system
                     :hash (plist-get fetch-report :sha256)
                     :backend 'nelix-native
                     :source source
                     :install install
                     :runtime-paths (nelix-builder-runtime-paths install)
                     :files (plist-get install :bin)))
        (load-paths (nelix-builder-emacs-load-paths install))
        (features (plist-get install :features)))
    (when load-paths
      (setq entry (plist-put entry :emacs-load-paths load-paths)))
    (when features
      (setq entry (plist-put entry :features features)))
    entry))

(defun nelix-builder--finish-install (recipe system source install profile-name)
  "Fetch SOURCE, extract into store for RECIPE, and create PROFILE-NAME."
  (let* ((archive (nelix-compat-make-temp-file "nelix-source-"))
         (fetch-report (nelix-fetch-source source archive))
         (entry (nelix-builder--store-entry
                 recipe system source install fetch-report))
         (store-path (nelix-store-entry-path entry))
         (build-path (nelix-store--entry-temp-dir entry)))
    (unwind-protect
        (progn
          (nelix-builder--extract-archive archive build-path source install)
          (when (eq (plist-get install :type) 'unpack)
            (nelix-builder--chmod-runtime-bins build-path install))
          (nelix-store-write-entry-at entry build-path)
          (nelix-store--commit-entry-dir build-path store-path)
          (setq build-path nil)
          (let ((profile
                 (nelix-builder--create-profile-generation
                  profile-name
                  system
                  (nelix-builder--profile-entry
                   entry store-path install))))
            (list :status 'ok
                  :backend 'nelix-native
                  :name (plist-get recipe :name)
                  :version (plist-get recipe :version)
                  :system system
                  :store-path store-path
                  :profile profile
                  :fetch fetch-report)))
      (nelix-compat-delete-file-quietly archive)
      (nelix-store--delete-directory-quietly build-path))))

(defun nelix-builder--finish-copy-install (recipe system source install profile-name)
  "Verify local SOURCE, copy it into store, and create PROFILE-NAME."
  (let* ((verify-report (nelix-fetch-verify-local-source source))
         (source-path (plist-get verify-report :path))
         (entry (nelix-builder--store-entry
                 recipe system source install verify-report))
         (store-path (nelix-store-entry-path entry))
         (build-path (nelix-store--entry-temp-dir entry)))
    (unwind-protect
        (progn
          (nelix-builder--copy-files source-path build-path install)
          (nelix-builder--chmod-runtime-bins build-path install)
          (nelix-store-write-entry-at entry build-path)
          (nelix-store--commit-entry-dir build-path store-path)
          (setq build-path nil)
          (let ((profile
                 (nelix-builder--create-profile-generation
                  profile-name
                  system
                  (nelix-builder--profile-entry
                   entry store-path install))))
            (list :status 'ok
                  :backend 'nelix-native
                  :name (plist-get recipe :name)
                  :version (plist-get recipe :version)
                  :system system
                  :store-path store-path
                  :profile profile
                  :fetch verify-report)))
      (nelix-store--delete-directory-quietly build-path))))

(defun nelix-builder--finish-script-shim-install (recipe system install profile-name)
  "Generate a script shim into the native store and create PROFILE-NAME."
  (let* ((install* (nelix-builder--script-shim-install install system))
         (source (list :type 'script-shim))
         (fetch-report (list :ok t
                             :sha256
                             (nelix-builder--script-shim-hash
                              recipe system install*)))
         (entry (nelix-builder--store-entry
                 recipe system source install* fetch-report))
         (store-path (nelix-store-entry-path entry))
         (build-path (nelix-store--entry-temp-dir entry)))
    (unwind-protect
        (progn
          (nelix-builder--write-script-shim build-path install* system)
          (nelix-store-write-entry-at entry build-path)
          (nelix-store--commit-entry-dir build-path store-path)
          (setq build-path nil)
          (let ((profile
                 (nelix-builder--create-profile-generation
                  profile-name
                  system
                  (nelix-builder--profile-entry
                   entry store-path install*))))
            (list :status 'ok
                  :backend 'nelix-native
                  :name (plist-get recipe :name)
                  :version (plist-get recipe :version)
                  :system system
                  :store-path store-path
                  :profile profile
                  :fetch fetch-report)))
      (nelix-store--delete-directory-quietly build-path))))

(defun nelix-builder--run-phase (phase-name cmd build-dir out-dir)
  "Run build PHASE-NAME CMD string in BUILD-DIR with $out=OUT-DIR.
Uses `default-directory' binding on host Emacs; calls
`nelisp-sys-chdir' first on standalone NeLisp so the child inherits
the cwd.  ENV is injected via shell-wrapping (sh -c \"export out=...\").
Signals `nelix-error' on non-zero exit."
  (let* ((safe-out (expand-file-name out-dir))
         (safe-dir (expand-file-name build-dir))
         ;; Shell wrapper: export $out and preserve PATH, then run the phase.
         (wrapped (format "export out=%s; export PATH=%s; %s"
                          (shell-quote-argument safe-out)
                          (shell-quote-argument (or (getenv "PATH") "/usr/bin:/bin"))
                          cmd))
         exit stdout)
    ;; On standalone NeLisp, default-directory is ignored by call-process.
    ;; Call nelisp-sys-chdir to set the process cwd before spawning.
    (when (and (nelix-compat--standalone-nelisp-p)
               (fboundp 'nelisp-sys-chdir))
      (nelisp-sys-chdir safe-dir))
    (let ((default-directory (file-name-as-directory safe-dir)))
      (if (fboundp 'call-process)
          (let ((buf (generate-new-buffer " *nelix-build-phase*")))
            (unwind-protect
                (progn
                  (setq exit (call-process "/bin/sh" nil buf nil "-c" wrapped))
                  (setq stdout (with-current-buffer buf (buffer-string))))
              (when (buffer-live-p buf)
                (kill-buffer buf))))
        ;; Fallback for environments without call-process (should not occur).
        (let ((res (nelix-compat-call-process "/bin/sh"
                                              (list "-c" wrapped))))
          (setq exit (plist-get res :exit))
          (setq stdout (plist-get res :stdout)))))
    (unless (eq exit 0)
      (signal 'nelix-error
              (list (format "nelix-builder: build phase %S failed (exit %S):\n%s"
                            phase-name exit stdout))))))

(defun nelix-builder--install-build (recipe system _source install profile-name)
  "Source-build RECIPE for SYSTEM and deposit into store; update PROFILE-NAME.

_SOURCE is accepted for interface parity but unused for (:type inline)
recipes where the phases generate all source files in the build
directory (Tier-0 MVP, no archive needed).
INSTALL must include :build-phases, an alist ((NAME . SHELL-CMD)...).

Each phase runs via sh(1) in the build dir with $out set to the
store temp dir.  Any non-zero phase exit signals `nelix-error'."
  (let* (;; Use a stable synthetic hash derived from phase bodies so the store
         ;; entry is content-addressed in a repeatable way within a session.
         ;; (Full reproducibility is Tier-1+; this satisfies the store API.)
         (phases (plist-get install :build-phases))
         (phase-str (format "%S" phases))
         (fake-hash (concat "sha256-build-"
                            (substring (md5 phase-str) 0 32)))
         (fetch-report (list :ok t :sha256 fake-hash))
         (entry (nelix-builder--store-entry
                 recipe system
                 (list :type 'inline)
                 install
                 fetch-report))
         (store-path (nelix-store-entry-path entry))
         (out-dir (nelix-store--entry-temp-dir entry))
         ;; Build dir: a separate scratch directory for compilation.
         (build-dir (make-temp-file "nelix-build-" t)))
    (unwind-protect
        (progn
          ;; Run each (NAME . SHELL-CMD) phase in build-dir with $out=out-dir.
          (dolist (phase phases)
            (let ((phase-name (car phase))
                  (cmd (cdr phase)))
              (nelix-builder--run-phase phase-name cmd build-dir out-dir)))
          ;; Mark declared binaries executable.
          (nelix-builder--chmod-runtime-bins out-dir install)
          ;; Commit the populated $out into the store.
          (nelix-store-write-entry-at entry out-dir)
          (nelix-store--commit-entry-dir out-dir store-path)
          (setq out-dir nil)
          (let ((profile
                 (nelix-builder--create-profile-generation
                  profile-name
                  system
                  (nelix-builder--profile-entry
                   entry store-path install))))
            (list :status 'ok
                  :backend 'nelix-native
                  :name (plist-get recipe :name)
                  :version (plist-get recipe :version)
                  :system system
                  :store-path store-path
                  :profile profile
                  :fetch fetch-report)))
      (nelix-store--delete-directory-quietly out-dir)
      (when (and (fboundp 'file-directory-p)
                 (file-directory-p build-dir))
        (delete-directory build-dir t)))))

(defun nelix-builder--install-unpack (recipe system source install profile-name)
  "Install RECIPE by unpacking SOURCE into the native store."
  (nelix-builder--finish-install recipe system source install profile-name))

(defun nelix-builder--install-emacs-lisp (recipe system source install profile-name)
  "Install Emacs Lisp RECIPE into the native store."
  (nelix-builder--finish-install recipe system source install profile-name))

(defun nelix-builder--install-copy (recipe system source install profile-name)
  "Install RECIPE by copying local source files into the native store."
  (nelix-builder--finish-copy-install recipe system source install profile-name))

(defun nelix-builder--install-script-shim (recipe system install profile-name)
  "Install RECIPE as a generated script shim."
  (nelix-builder--finish-script-shim-install
   recipe system install profile-name))

(defun nelix-builder--dependency-name (dependency)
  "Return package name string for DEPENDENCY."
  (cond
   ((stringp dependency) dependency)
   ((symbolp dependency) (symbol-name dependency))
   ((and (consp dependency)
         (plist-get dependency :name))
    (nelix-builder--dependency-name (plist-get dependency :name)))
   (t
    (signal 'nelix-error
            (list (format "nelix-native-install-recipe: invalid dependency %S"
                          dependency))))))

(defun nelix-builder--profile-has-entry-p (profile-name name)
  "Return non-nil when PROFILE-NAME already contains NAME."
  (let (found)
    (dolist (entry (nelix-builder--profile-current-entries profile-name) found)
      (when (equal name (plist-get entry :name))
        (setq found t)))))

(defun nelix-builder--install-dependencies
    (dependencies profile-name system)
  "Install DEPENDENCIES into PROFILE-NAME before the parent recipe."
  (let (reports)
    (dolist (dependency dependencies (nreverse reports))
      (let* ((name (nelix-builder--dependency-name dependency))
             (recipe (nelix-registry-get name)))
        (cond
         ((member name nelix-builder--install-stack)
          (signal 'nelix-error
                  (list (format "nelix-native-install-recipe: dependency cycle at %s"
                                name))))
         ((nelix-builder--profile-has-entry-p profile-name name)
          nil)
         ((null recipe)
          (signal 'nelix-error
                  (list (format "nelix-native-install-recipe: missing dependency recipe %s"
                                name))))
         (t
          (push (nelix-native-install-recipe recipe profile-name system)
                reports)))))))

(defun nelix-builder--lock-package-by-name (packages name)
  "Return lock package row named NAME from PACKAGES."
  (let (found)
    (dolist (package packages found)
      (when (and (null found)
                 (equal name (plist-get package :name)))
        (setq found package)))))

(defun nelix-builder--strip-recipe-dependencies (recipe system)
  "Return RECIPE for SYSTEM with native dependencies removed."
  (let ((copy (copy-sequence recipe))
        systems)
    (dolist (entry (plist-get recipe :systems))
      (if (and (consp entry)
               (eq (car entry) system))
          (let ((rest (copy-sequence (cdr entry))))
            (setq rest (plist-put rest :dependencies nil))
            (push (cons (car entry) rest) systems))
        (push entry systems)))
    (plist-put copy :systems (nreverse systems))
    copy))

(defun nelix-builder--install-lock-dependencies
    (dependencies lock-packages profile-name system)
  "Install DEPENDENCIES from LOCK-PACKAGES before a locked package."
  (let (reports)
    (dolist (dependency dependencies (nreverse reports))
      (let* ((name (nelix-builder--dependency-name dependency))
             (package (nelix-builder--lock-package-by-name lock-packages name)))
        (cond
         ((member name nelix-builder--install-stack)
          (signal 'nelix-error
                  (list (format "nelix-native-install-lock-package: dependency cycle at %s"
                                name))))
         ((nelix-builder--profile-has-entry-p profile-name name)
          nil)
         ((null package)
          (signal 'nelix-error
                  (list (format "nelix-native-install-lock-package: missing dependency lock row %s"
                                name))))
         (t
          (push (nelix-native-install-lock-package
                 package profile-name system lock-packages)
                reports)))))))

(defun nelix-builder--lock-package-recipe (package system)
  "Return a transient native recipe from lock PACKAGE for SYSTEM."
  (let ((name (plist-get package :name))
        (version (plist-get package :recipe-version))
        (class (plist-get package :recipe-class))
        (source (plist-get package :recipe-source))
        (install (plist-get package :recipe-install))
        (dependencies (plist-get package :recipe-dependencies)))
    (unless name
      (signal 'nelix-error
              (list "nelix-native-install-lock-package: package row has no :name")))
    (unless version
      (signal 'nelix-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-version"
                            name))))
    (unless class
      (signal 'nelix-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-class"
                            name))))
    (unless install
      (signal 'nelix-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-install"
                            name))))
    (unless (or source
                (eq (plist-get install :type) 'script-shim))
      (signal 'nelix-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-source"
                            name))))
    (list :name name
          :version version
          :class class
          :systems
          (list (cons system
                      (append (when source
                                (list :source source))
                              (list :install install)
                              (when dependencies
                                (list :dependencies dependencies))))))))

;;;###autoload
(defun nelix-native-install-lock-package
    (package &optional profile-name system lock-packages)
  "Install native PACKAGE lock row into the native store/profile.

This path reconstructs a transient recipe from lock row source/install
metadata and does not consult the mutable registry.  When
LOCK-PACKAGES is non-nil, dependency rows are replayed from that
lock set before PACKAGE is installed."
  (let* ((system* (or system
                     (plist-get package :system)
                     (and (fboundp 'nelix-current-system)
                          (nelix-current-system))
                     'x86_64-linux))
         (profile-name* (or profile-name nelix-builder-default-profile))
         (locked-system (plist-get package :system)))
    (when (and locked-system
               (not (eq locked-system system*)))
      (signal 'nelix-error
              (list (format "nelix-native-install-lock-package: system drift, lock=%S current=%S"
                            locked-system system*))))
    (let* ((recipe (nelix-builder--lock-package-recipe package system*))
           (system-entry (nelix-builder--system-entry recipe system*))
           (dependencies (plist-get system-entry :dependencies))
           (dependency-reports
            (when lock-packages
              (let ((nelix-builder--install-stack
                     (cons (plist-get package :name)
                           nelix-builder--install-stack)))
                (nelix-builder--install-lock-dependencies
                 dependencies lock-packages profile-name* system*)))))
      (when lock-packages
        (setq recipe
              (nelix-builder--strip-recipe-dependencies recipe system*)))
      (let ((report (nelix-native-install-recipe
                     recipe profile-name* system*)))
        (if dependency-reports
            (plist-put report :dependencies dependency-reports)
          report)))))

;;;###autoload
(defun nelix-native-install-recipe (recipe &optional profile-name system)
  "Install RECIPE into the native store and PROFILE-NAME."
  (let* ((system* (or system
                     (and (fboundp 'nelix-current-system)
                          (nelix-current-system))
                     'x86_64-linux))
         (profile-name* (or profile-name nelix-builder-default-profile))
         (name (plist-get recipe :name))
         (system-entry (nelix-builder--system-entry recipe system*))
         (source (plist-get system-entry :source))
         (install (plist-get system-entry :install))
         (dependencies (plist-get system-entry :dependencies))
         (kind (plist-get install :type)))
    (when (member name nelix-builder--install-stack)
      (signal 'nelix-error
              (list (format "nelix-native-install-recipe: dependency cycle at %s"
                            name))))
    (unless system-entry
      (signal 'nelix-error
              (list (format "nelix-native-install-recipe: %s has no recipe for %S"
                            name system*))))
    (unless (or source
                (eq kind 'script-shim))
      (signal 'nelix-error
              (list (format "nelix-native-install-recipe: %s has no :source for %S"
                            name system*))))
    (let* ((nelix-builder--install-stack
            (cons name nelix-builder--install-stack))
           (dependency-reports
            (nelix-builder--install-dependencies
             dependencies profile-name* system*))
           (report
            (pcase kind
              ('unpack
               (nelix-builder--install-unpack
                recipe system* source install profile-name*))
              ('emacs-lisp
               (nelix-builder--install-emacs-lisp
                recipe system* source install profile-name*))
              ('copy
               (nelix-builder--install-copy
                recipe system* source install profile-name*))
              ('script-shim
               (nelix-builder--install-script-shim
                recipe system* install profile-name*))
              ('build
               (nelix-builder--install-build
                recipe system* source install profile-name*))
              (_
               (signal 'nelix-error
                       (list (format "nelix-native-install-recipe: unsupported install type %S"
                                     kind)))))))
      (if dependency-reports
          (plist-put report :dependencies dependency-reports)
        report))))

;;;###autoload
(defun nelix-native-install (name &optional profile-name system)
  "Install package NAME from the local registry into native store."
  (let ((recipe (nelix-registry-get name)))
    (unless recipe
      (signal 'nelix-error
              (list (format "nelix-native-install: no registry recipe for %S"
                            name))))
    (nelix-native-install-recipe recipe profile-name system)))

(provide 'nelix-builder)
;;; nelix-builder.el ends here
