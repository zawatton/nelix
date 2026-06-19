;;; nelix-builder.el --- Nelix native builders -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase N4/N5 native builders.  The implemented builders fetch a
;; hash-verified archive, extract it into the native store, write store
;; metadata, and create a profile generation.

;;; Code:

(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-compat)
(require 'nelix-fetch)
(require 'nelix-store)
(require 'nelix-registry)

(defgroup nelix-builder nil
  "Nelix native builders."
  :group 'anvil-pkg
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
  "Run PROGRAM with ARGS or signal `anvil-pkg-error'."
  (unless (anvil-pkg-compat-executable-find program)
    (signal 'anvil-pkg-error
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
               (anvil-pkg-compat-call-process program args))))
    (unless (eq 0 (plist-get res :exit))
      (signal 'anvil-pkg-error
              (list (format "nelix-builder: %s failed: %s"
                            program
                            (anvil-pkg-compat-string-trim
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
  (anvil-pkg-compat-make-directory dest t)
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
     (signal 'anvil-pkg-error
             (list (format "nelix-builder: unsupported archive format %S"
                           format))))))

(defun nelix-builder--chmod-runtime-bins (store-path install)
  "Mark declared runtime binaries executable where POSIX modes exist."
  (when (and (not (eq system-type 'windows-nt))
             (fboundp 'set-file-modes))
    (dolist (bin (plist-get install :bin))
      (let ((path (expand-file-name bin store-path)))
        (when (anvil-pkg-compat-file-exists-p path)
          (set-file-modes path #o755))))))

(defun nelix-builder--windows-system-p (system)
  "Return non-nil when SYSTEM is a Windows platform id."
  (memq system '(x86_64-windows aarch64-windows i686-windows)))

(defun nelix-builder--copy-path (source dest)
  "Copy SOURCE into DEST, creating parent directories."
  (anvil-pkg-compat-make-directory (file-name-directory dest) t)
  (cond
   ((and (fboundp 'file-directory-p)
         (file-directory-p source))
    (copy-directory source dest t t t))
   ((anvil-pkg-compat-file-exists-p source)
    (copy-file source dest t))
   (t
    (signal 'anvil-pkg-error
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
    (signal 'anvil-pkg-error
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
           (> (length (anvil-pkg-compat-string-trim command)) 0))
      (anvil-pkg-compat-string-trim command))
     ((symbolp command) (symbol-name command))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix-builder: script-shim requires :command, got %S"
                            install)))))))

(defun nelix-builder--script-shim-target (install)
  "Return script shim target declared by INSTALL."
  (let ((target (or (plist-get install :target)
                    (plist-get install :program)
                    (plist-get install :command))))
    (cond
     ((and (stringp target)
           (> (length (anvil-pkg-compat-string-trim target)) 0))
      (anvil-pkg-compat-string-trim target))
     ((symbolp target) (symbol-name target))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix-builder: script-shim requires :target, got %S"
                            install)))))))

(defun nelix-builder--script-shim-target-available-p (target)
  "Return non-nil when script shim TARGET is currently executable."
  (cond
   ((file-name-absolute-p target)
    (and (anvil-pkg-compat-file-exists-p target)
         (or (not (fboundp 'file-executable-p))
             (file-executable-p target))))
   (t
    (anvil-pkg-compat-executable-find target))))

(defun nelix-builder--require-script-shim-target (install target)
  "Signal when INSTALL requires TARGET and TARGET is unavailable."
  (when (and (plist-get install :require-target)
             (not (nelix-builder--script-shim-target-available-p target)))
    (signal 'anvil-pkg-error
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
    (anvil-pkg-compat-make-directory (file-name-directory path) t)
    (anvil-pkg-compat-write-file path content)
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

(defun nelix-builder--profile-current-entries (profile-name)
  "Return current entries for PROFILE-NAME, or nil when no profile exists."
  (condition-case nil
      (plist-get (nelix-profile-read profile-name) :entries)
    (error nil)))

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
  (nelix-profile-create-generation
   profile-name
   system
   (nelix-builder--profile-entries-with profile-name entry)))

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
  (let* ((archive (anvil-pkg-compat-make-temp-file "nelix-source-"))
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
      (anvil-pkg-compat-delete-file-quietly archive)
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
    (signal 'anvil-pkg-error
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
          (signal 'anvil-pkg-error
                  (list (format "nelix-native-install-recipe: dependency cycle at %s"
                                name))))
         ((nelix-builder--profile-has-entry-p profile-name name)
          nil)
         ((null recipe)
          (signal 'anvil-pkg-error
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
          (signal 'anvil-pkg-error
                  (list (format "nelix-native-install-lock-package: dependency cycle at %s"
                                name))))
         ((nelix-builder--profile-has-entry-p profile-name name)
          nil)
         ((null package)
          (signal 'anvil-pkg-error
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
      (signal 'anvil-pkg-error
              (list "nelix-native-install-lock-package: package row has no :name")))
    (unless version
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-version"
                            name))))
    (unless class
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-class"
                            name))))
    (unless install
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install-lock-package: %s has no :recipe-install"
                            name))))
    (unless (or source
                (eq (plist-get install :type) 'script-shim))
      (signal 'anvil-pkg-error
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
      (signal 'anvil-pkg-error
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
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install-recipe: dependency cycle at %s"
                            name))))
    (unless system-entry
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install-recipe: %s has no recipe for %S"
                            name system*))))
    (unless (or source
                (eq kind 'script-shim))
      (signal 'anvil-pkg-error
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
              (_
               (signal 'anvil-pkg-error
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
      (signal 'anvil-pkg-error
              (list (format "nelix-native-install: no registry recipe for %S"
                            name))))
    (nelix-native-install-recipe recipe profile-name system)))

(provide 'nelix-builder)
;;; nelix-builder.el ends here
