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

(defvar nelix-builder--phase-inputs nil
  "Inputs alist ((NAME . STORE-PATH) ...) for the package currently being built.
Bound in `nelix-native-install-recipe' from the dependency reports and
forwarded through `nelix-builder--install-build' into each phase eval.")

(defvar nelix-builder-hermeticity nil
  "Hermeticity tier for source builds.
nil / `tier0 / `tier1 run build phases in-process (the default, cross-
platform path).  `tier2 runs the whole phase sequence inside a Linux
namespace sandbox via the optional `nelix-sandbox' module (design 32),
which is required lazily only then.  Bound dynamically by callers opting
into Tier 2; the default in-process path and its load cost are unchanged.")

(defvar nelix-builder-toolchain-inputs nil
  "Optional list of toolchain paths to bind read-only into the Tier 2 sandbox.
Each path is exposed at its canonical location alongside the host /usr base,
the mechanism for a content-addressed toolchain (design 32 T3).  When nil
the sandbox relies on the host toolchain bound from /usr, which gives
same-host reproducibility; bit-identical output ACROSS hosts requires a
content-addressed toolchain pinned here.  Bound dynamically by callers.")

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
                 ;; Use `t' as BUFFER arg so output goes to current buffer
                 ;; without requiring `current-buffer' (missing in standalone
                 ;; NeLisp).  `with-temp-buffer' establishes the current buffer
                 ;; on both Emacs and NeLisp standalone.
                 (with-temp-buffer
                   (let ((exit (apply #'call-process
                                      program
                                      nil
                                      t
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
  "Return absolute Emacs load-path directories for STORE-PATH and INSTALL.
For emacs-package builds, detect the directories under STORE-PATH that
actually contain .el files, so `lisp/' subdirectories are picked up and each
package keeps its own load-path (no flattening, no name collisions).  Fall
back to the declared :load-paths otherwise."
  (or (and (eq (plist-get install :build-system) 'emacs-package)
           (file-directory-p store-path)
           (let* ((pname (plist-get install :pname))
                  (main (and pname (concat pname ".el")))
                  primary all)
             (dolist (f (directory-files-recursively store-path "\\.el\\'"))
               (unless (string-match-p "/\\.nelix\\(?:/\\|\\'\\)" f)
                 (let ((dir (directory-file-name (file-name-directory f))))
                   (unless (member dir all) (push dir all))
                   ;; The directory holding the package's own NAME.el is the
                   ;; primary load-path; preferring it keeps a vendored/stub copy
                   ;; of another package (in a different dir) from shadowing the
                   ;; real one.
                   (when (and main (equal (file-name-nondirectory f) main)
                              (not (member dir primary)))
                     (push dir primary)))))
             (or (nreverse primary) (nreverse all))))
      (mapcar (lambda (path) (expand-file-name path store-path))
              (nelix-builder-emacs-load-paths install))))

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

;;; M2 — Build-system phase presets (design §8)
;;
;; Each entry: (SYSTEM . PRESET-PHASES) where PRESET-PHASES is an alist
;; of (NAME . SHELL-CMD) pairs in standard execution order.
;;
;; Design notes:
;;   - 'make / 'gnu share the same preset.
;;   - configure is attempted only if ./configure exists (test -x guard).
;;   - 'check is present in the preset list but mapped to nil so callers
;;     can detect it; --resolve-phases drops nil-cmd entries unless the
;;     caller explicitly overrides them.
;;   - 'trivial has no preset; all phases must be explicit.
;;   - $out is set by the run-phase shell wrapper; presets reference it freely.

(defvar nelix-builder--build-system-presets
  '((make
     ;; unpack: no-op placeholder; recipes supply their own unpack phase
     ;; to generate source files.  Having it in the preset means an
     ;; explicit (unpack . CMD) is placed here, before configure/build.
     (unpack    . "true")
     (configure . "test -x ./configure && ./configure --prefix=\"$out\" || true")
     (build     . "make")
     (install   . "make install PREFIX=\"$out\""))
    (gnu
     (unpack    . "true")
     (configure . "test -x ./configure && ./configure --prefix=\"$out\" || true")
     (build     . "make")
     (install   . "make install PREFIX=\"$out\""))
    (cmake
     (unpack    . "true")
     (configure . "cmake -S . -B build -DCMAKE_INSTALL_PREFIX=\"$out\"")
     (build     . "cmake --build build")
     (install   . "cmake --install build"))
    (cargo
     (unpack  . "true")
     (build   . "cargo build --release")
     (install . "mkdir -p \"$out/bin\" && cp target/release/* \"$out/bin/\" 2>/dev/null || true"))
    (emacs-package
     ;; Doc 33 M2: Lisp-native phases (run by `nelix-builder--run-phase-elisp').
     ;; Generic over the package: `nelix-source-archive' / `nelix-package-name' /
     ;; `nelix-out' supply per-recipe specifics, so one preset builds any
     ;; elpa/git Emacs package (skipping hidden files like .dir-locals.el).
     (unpack
      . (nelix-invoke "tar" "xzf" (nelix-source-archive) "--strip-components=1"))
     (install
      . (let ((files (nelix-build-package-el-files)))
          ;; Keep each package's directory structure (lisp/ subdirs) so load
          ;; paths stay separate and names never collide.  Install .el only:
          ;; byte-compiling before the full dependency closure is on load-path
          ;; produces broken .elc that break activation; plain .el always loads.
          (nelix-mkdir-p (nelix-out))
          (dolist (f files)
            (let ((dest (expand-file-name (file-relative-name f nelix-build--dir)
                                          (nelix-out))))
              (nelix-mkdir-p (file-name-directory dest))
              (nelix-copy-file f dest)))))
     (autoload
      . (progn
          (require 'package)
          ;; Generate autoloads for every $out directory that holds .el.
          (let (dirs)
            (dolist (f (directory-files-recursively (nelix-out) "\\.el\\'"))
              (let ((dir (directory-file-name (file-name-directory f))))
                (unless (member dir dirs) (push dir dirs))))
            (dolist (dir dirs)
              (package-generate-autoloads (nelix-package-name) dir)))))))
  "Alist mapping build-system symbols to preset (NAME . SHELL-CMD) phase lists.
\\='trivial is absent: no preset, recipe must supply all :build-phases.
Each preset lists standard phases in execution order.
See `nelix-builder--resolve-phases' for the merge contract.")

(defun nelix-builder--resolve-phases (build-system explicit-phases)
  "Return the final ordered (NAME . CMD) phase list for BUILD-SYSTEM.

Merge contract:
  - If BUILD-SYSTEM is \\='trivial (or nil), return EXPLICIT-PHASES as-is.
  - Otherwise, start from the preset for BUILD-SYSTEM.
  - An explicit entry whose NAME matches a preset phase *replaces* it
    in-place (preserving order).
  - An explicit entry whose NAME is NOT in the preset is *appended*
    after the last preset phase, in EXPLICIT-PHASES order.
  - Recipes can override individual phases (e.g., \\='install) while
    inheriting the rest of the preset, and add project-specific phases
    (e.g., \\='unpack, \\='patch) without restating build/install steps.

Examples:
  (nelix-builder--resolve-phases \\='make nil)
  ;; => ((configure . \"...\") (build . \"make\")
  ;;     (install . \"make install PREFIX=...\"))

  (nelix-builder--resolve-phases
    \\='make \\='((unpack . \"tar xf foo.tar.gz\")
               (install . \"make DESTDIR=$out install\")))
  ;; => ((unpack . \"tar xf foo.tar.gz\") (configure . \"...\")
  ;;     (build . \"make\") (install . \"make DESTDIR=$out install\"))"
  (if (or (null build-system) (eq build-system 'trivial))
      (or explicit-phases '())
    (let* ((preset (cdr (assq build-system
                              nelix-builder--build-system-presets)))
           (explicit (or explicit-phases '()))
           ;; Names overridden by explicit entries (for in-place replacement).
           (override-names (mapcar #'car explicit))
           ;; Preset with overrides applied in-place.
           (merged-preset
            (mapcar (lambda (entry)
                      (let ((name (car entry)))
                        (if (memq name override-names)
                            (assq name explicit)
                          entry)))
                    preset))
           ;; Extra explicit entries not present in the preset (appended after).
           (preset-names (mapcar #'car preset))
           (extras (cl-remove-if (lambda (e) (memq (car e) preset-names))
                                 explicit)))
      (append merged-preset extras))))

;; `nelix-build' defines these as the dynamic phase-eval context.  Declare
;; them special here so the compiler treats the let-binding in
;; `nelix-builder--run-phase-elisp' as a DYNAMIC binding that the `eval'ed
;; phase forms (which call `nelix-out' / `nelix-input' etc.) can actually see.
(defvar nelix-build--out)
(defvar nelix-build--dir)
(defvar nelix-build--inputs)
(defvar nelix-build--pname)
(defvar nelix-build--source-archive)
(defvar nelix-build--el-exclude)

(defun nelix-builder--run-phase (phase-name cmd build-dir out-dir &optional phase-inputs)
  "Run build phase PHASE-NAME in BUILD-DIR with $out=OUT-DIR.
PHASE-INPUTS is an alist ((NAME . STORE-PATH) ...) of dependency store paths
made available to Elisp phases via `nelix-input'.
CMD is either a SHELL-COMMAND STRING (run via sh -c) or a Lisp-native
ELISP FORM evaluated with the `nelix-build' primitive vocabulary
(`nelix-invoke' / `nelix-substitute*' / `nelix-out' / `nelix-input' / ...).
The Lisp-native form keeps phase orchestration in Elisp data — free of
shell-quoting fragility — and only spawns the actual build tools as
subprocesses.  Signals `nelix-error' on failure."
  (if (stringp cmd)
      (nelix-builder--run-phase-shell phase-name cmd build-dir out-dir)
    (nelix-builder--run-phase-elisp phase-name cmd build-dir out-dir phase-inputs)))

(defun nelix-builder--run-phase-elisp (phase-name form build-dir out-dir &optional phase-inputs)
  "Evaluate a Lisp-native build phase FORM in BUILD-DIR with $out=OUT-DIR.
PHASE-INPUTS is an alist ((NAME . STORE-PATH) ...) bound to
`nelix-build--inputs' so that `(nelix-input NAME)' can resolve dependency
store paths.  FORM is plain Elisp using the `nelix-build' vocabulary;
`(nelix-out)' returns OUT-DIR.  No shell drives the orchestration."
  (require 'nelix-build)
  (let ((nelix-build--out (expand-file-name out-dir))
        (nelix-build--dir (expand-file-name build-dir))
        (nelix-build--inputs (or phase-inputs '()))
        (default-directory (file-name-as-directory (expand-file-name build-dir))))
    (when (and (nelix-compat--standalone-nelisp-p) (fboundp 'nelisp-sys-chdir))
      (nelisp-sys-chdir nelix-build--dir))
    (condition-case e
        (eval form t)
      (nelix-error (signal (car e) (cdr e)))
      (nelix-build-error
       (signal 'nelix-error
               (list (format "nelix-builder: build phase %S failed:\n%s"
                             phase-name (cadr e)))))
      (error
       (signal 'nelix-error
               (list (format "nelix-builder: build phase %S errored: %S"
                             phase-name e)))))))

(defun nelix-builder--run-phase-shell (phase-name cmd build-dir out-dir)
  "Run shell CMD string for PHASE-NAME in BUILD-DIR with $out=OUT-DIR.

Uses `default-directory' binding on host Emacs; calls
`nelisp-sys-chdir' first on standalone NeLisp so the child inherits
the cwd.  ENV is injected via a deterministic shell prelude (Tier-1
hardening, design §6 Tier 1):

  - PATH is restricted to /usr/bin:/bin (minimal host toolchain base).
    Recipes needing extra tools should arrange them via :buildInputs or
    explicit phase commands; the ambient caller PATH is NOT inherited.
  - $out is set to OUT-DIR (the store scratch dir for this build).
  - $HOME is redirected to BUILD-DIR so phases cannot read or write the
    real user home directory.
  - SOURCE_DATE_EPOCH=1, TZ=UTC, LC_ALL=C provide a deterministic locale
    and timestamp base (necessary for reproducible archives).
  - `ulimit -t 600' caps CPU time at 600 seconds per phase (shell-level
    guard; not a kernel rlimit, but prevents runaway compilations).
  - No kernel sandbox (Tier 2, out of scope); network is still open.

Signals `nelix-error' on non-zero exit."
  (let* ((safe-out (expand-file-name out-dir))
         (safe-dir (expand-file-name build-dir))
         ;; Tier-1 env prelude: deterministic, minimal, HOME-scrubbed.
         ;; PATH: keep only /usr/bin:/bin (host toolchain minimum).
         ;; Caller's ambient PATH is intentionally NOT forwarded.
         (wrapped (format
                   (concat "ulimit -t 600; "
                           "export out=%s; "
                           "export PATH=/usr/bin:/bin; "
                           "export HOME=%s; "
                           "export SOURCE_DATE_EPOCH=1; "
                           "export TZ=UTC; "
                           "export LC_ALL=C; "
                           "%s")
                   (shell-quote-argument safe-out)
                   (shell-quote-argument safe-dir)
                   cmd))
         exit stdout)
    ;; On standalone NeLisp, default-directory is ignored by call-process.
    ;; Call nelisp-sys-chdir to set the process cwd before spawning.
    (when (and (nelix-compat--standalone-nelisp-p)
               (fboundp 'nelisp-sys-chdir))
      (nelisp-sys-chdir safe-dir))
    (let ((default-directory (file-name-as-directory safe-dir)))
      (if (fboundp 'call-process)
          ;; Use `with-temp-buffer' + `t' instead of `generate-new-buffer' +
          ;; named buffer so this path works on standalone NeLisp which lacks
          ;; `current-buffer' / `set-buffer' but does have `with-temp-buffer',
          ;; `call-process nil t nil', and `buffer-string'.  The pattern is
          ;; identical on host Emacs.
          (with-temp-buffer
            (setq exit (call-process "/bin/sh" nil t nil "-c" wrapped))
            (setq stdout (buffer-string)))
        ;; Fallback for environments without call-process (should not occur).
        (let ((res (nelix-compat-call-process "/bin/sh"
                                              (list "-c" wrapped))))
          (setq exit (plist-get res :exit))
          (setq stdout (plist-get res :stdout)))))
    (unless (eq exit 0)
      (signal 'nelix-error
              (list (format "nelix-builder: build phase %S failed (exit %S):\n%s"
                            phase-name exit stdout))))))

(declare-function nelix-sandbox-run "nelix-sandbox" (spec &optional backend))

(defun nelix-builder--run-phases-sandboxed (phases build-dir out-dir phase-inputs)
  "Run PHASES inside a Tier 2 namespace sandbox (design 32).
Lazily requires the optional `nelix-sandbox' module and delegates to
`nelix-sandbox-run', which builds a SPEC, launches a builder child inside
the sandbox (read-only input closure, writable $out, no network), and runs
the same phases there.  Signals `nelix-error' on build failure or when the
sandbox is unavailable (the latter carries a Tier-1 fallback hint)."
  (require 'nelix-sandbox)
  (let ((result (nelix-sandbox-run
                 (list :phases phases
                       :inputs phase-inputs
                       :out out-dir
                       :build build-dir
                       :net nil
                       :toolchain nelix-builder-toolchain-inputs))))
    (unless (eq (plist-get result :status) 'ok)
      (signal 'nelix-error
              (list (format
                     "nelix-builder: sandboxed (tier2) build failed (code %S): %s"
                     (plist-get result :code)
                     (plist-get result :log)))))
    result))

(defun nelix-builder--install-build (recipe system source install profile-name
                                     &optional phase-inputs)
  "Source-build RECIPE for SYSTEM and deposit into store; update PROFILE-NAME.

_SOURCE is accepted for interface parity but unused for (:type inline)
recipes where the phases generate all source files in the build
directory (Tier-0 MVP, no archive needed).

PHASE-INPUTS is an optional alist ((NAME . STORE-PATH) ...) of dependency
store paths built before this package.  It is bound to `nelix-build--inputs'
during each Elisp-native phase so that `(nelix-input NAME)' can resolve them.

INSTALL is a plist which may include:
  :build-system SYMBOL — selects a phase preset (\\='make, \\='cmake, \\='cargo,
                         \\='trivial).  Defaults to \\='trivial if absent.
  :build-phases ALIST  — explicit (NAME . SHELL-CMD) pairs.  When
                         :build-system is non-trivial, explicit entries
                         override or extend the preset (see
                         `nelix-builder--resolve-phases').  For \\='trivial,
                         :build-phases is the complete phase list.

Each phase runs via sh(1) in the build dir with $out set to the
store temp dir.  Tier-1 env hardening (deterministic PATH, HOME scrub,
SOURCE_DATE_EPOCH, TZ, LC_ALL, ulimit -t) is applied by
`nelix-builder--run-phase'.  Any non-zero phase exit signals \\='nelix-error."
  (let* (;; Resolve phases: merge preset + explicit overrides/extras.
         (build-system (or (plist-get install :build-system) 'trivial))
         (explicit-phases (plist-get install :build-phases))
         (phases (nelix-builder--resolve-phases build-system explicit-phases))
         ;; Use a stable synthetic hash derived from resolved phase bodies so
         ;; the store entry is content-addressed in a repeatable way within a
         ;; session.  (Full reproducibility is Tier-1+; this satisfies the
         ;; store API.)
         (phase-str (format "%S" phases))
         (fake-hash (concat "sha256-build-"
                            ;; `md5' is absent on standalone NeLisp; fall back
                            ;; to a simple length+charcode mix that is stable
                            ;; within a session.  This is not a real hash but
                            ;; satisfies the store-entry uniqueness contract.
                            (if (fboundp 'md5)
                                (substring (md5 phase-str) 0 32)
                              ;; Standalone NeLisp: no md5, no %x format.
                              ;; Build a 32-char decimal+padding fake hash.
                              (let* ((n (length phase-str))
                                     (acc 0)
                                     (i 0))
                                (while (< i n)
                                  (setq acc (+ (* acc 31)
                                               (aref phase-str i))
                                        i (1+ i)))
                                ;; acc may be negative on overflow; take abs.
                                (let* ((v (if (< acc 0) (- acc) acc))
                                       (s (format "%d" v)))
                                  ;; Pad to 32 chars with leading zeros.
                                  (while (< (length s) 32)
                                    (setq s (concat "0" s)))
                                  (if (> (length s) 32)
                                      (substring s 0 32)
                                    s))))))
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
          ;; T2 (design 32, fixed-output source): a non-inline source carrying
          ;; a :sha256 is fetched + hash-verified ON THE HOST (network is
          ;; allowed here, before any sandbox), and the verified file is placed
          ;; in the build dir so the phases run OFFLINE.  A hash mismatch
          ;; signals loudly via `nelix-fetch-source' -- no silent network in
          ;; the build.  Inline sources (no :sha256) are generated by phases.
          (let ((fetched-archive nil))
            (when (and source (plist-get source :sha256))
              (let* ((url (or (plist-get source :url) ""))
                     (base (let ((b (file-name-nondirectory url)))
                             (if (> (length b) 0) b "source")))
                     (dest (expand-file-name base build-dir)))
                (nelix-fetch-source source dest)
                (setq fetched-archive dest)))
            ;; Bind the Emacs-package build accessors (`nelix-package-name' /
            ;; `nelix-source-archive') so generic build-system presets can stay
            ;; package-agnostic.  pname defaults to the recipe :name.
            (let ((nelix-build--pname (or (plist-get install :pname)
                                          (plist-get recipe :name)))
                  (nelix-build--el-exclude (plist-get install :el-exclude))
                  (nelix-build--source-archive fetched-archive))
              ;; Run each (NAME . CMD) phase in build-dir with $out=out-dir.
              (if (eq nelix-builder-hermeticity 'tier2)
                  ;; Tier 2 (design 32): run the whole phase sequence inside a
                  ;; namespace sandbox (read-only input closure, no network).
                  (nelix-builder--run-phases-sandboxed
                   phases build-dir out-dir phase-inputs)
                (dolist (phase phases)
                  (let ((phase-name (car phase))
                        (cmd (cdr phase)))
                    (nelix-builder--run-phase phase-name cmd build-dir out-dir phase-inputs))))))
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

(defvar nelix-builder-allow-missing-dependencies nil
  "When non-nil, a dependency with no registry recipe is logged and skipped
instead of signaling an error.  Used for bulk imports where some deps are
Emacs built-ins (org, transient, magit-section, ...) or come from other
fetchers not yet in the registry.")

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
          (if nelix-builder-allow-missing-dependencies
              (when (fboundp 'message)
                (message "nelix: dependency %s has no recipe (built-in/external); skipping"
                         name))
            (signal 'nelix-error
                    (list (format "nelix-native-install-recipe: missing dependency recipe %s"
                                  name)))))
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
           ;; Build inputs alist from dependency reports so Elisp phases can
           ;; call (nelix-input "NAME") to get a dep's store path — the nelix
           ;; analogue of Guix's (assoc-ref inputs "NAME").
           (phase-inputs
            (delq nil
                  (mapcar (lambda (r)
                            (let ((n  (plist-get r :name))
                                  (sp (plist-get r :store-path)))
                              (when (and n sp)
                                (cons n sp))))
                          dependency-reports)))
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
                recipe system* source install profile-name* phase-inputs))
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
