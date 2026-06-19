;;; nelix-store.el --- Native Nelix store/profile metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Metadata-only native store skeleton for Doc 22.  This module does not fetch
;; or build packages; it defines portable store/profile roots, store-entry
;; metadata, profile generations, rollback primitives, and Emacs activation
;; helpers.

;;; Code:

(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-compat)

(defgroup nelix-store nil
  "Native Nelix store/profile metadata."
  :group 'anvil-pkg
  :prefix "nelix-store-")

(defcustom nelix-store-root nil
  "Root directory for native Nelix store entries.
When nil, `nelix-store-root' computes an OS-appropriate default."
  :type '(choice (const :tag "Auto" nil) directory)
  :group 'nelix-store)

(defcustom nelix-profile-root nil
  "Root directory for native Nelix profiles.
When nil, `nelix-profile-root' computes an OS-appropriate default."
  :type '(choice (const :tag "Auto" nil) directory)
  :group 'nelix-store)

(defcustom nelix-profile-activation-link-mode 'auto
  "How native profile activation creates the profile file tree.

The `auto' mode uses POSIX symlinks when available and copies files
otherwise.  Windows profile systems always copy so activation does not
depend on privileged symlink creation."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Symlink" symlink)
                 (const :tag "Copy" copy)
                 (const :tag "Disable link tree" nil))
  :group 'nelix-store)

(defvar nelix-store-entry-last nil
  "Most recently loaded `nelix-store-entry' plist.")

(defvar nelix-profile-last nil
  "Most recently loaded `nelix-profile' plist.")

(defun nelix-store--local-data-home ()
  "Return the base user data directory for native Nelix data."
  (cond
   ((and (eq system-type 'windows-nt)
         (anvil-pkg-compat-getenv "LOCALAPPDATA"))
    (anvil-pkg-compat-getenv "LOCALAPPDATA"))
   ((anvil-pkg-compat-getenv "XDG_DATA_HOME")
    (anvil-pkg-compat-getenv "XDG_DATA_HOME"))
   (t
    (expand-file-name
     ".local/share"
     (or (anvil-pkg-compat-getenv "HOME") "~")))))

(defun nelix-store--local-state-home ()
  "Return the base user state directory for native Nelix profiles."
  (cond
   ((and (eq system-type 'windows-nt)
         (anvil-pkg-compat-getenv "LOCALAPPDATA"))
    (anvil-pkg-compat-getenv "LOCALAPPDATA"))
   ((anvil-pkg-compat-getenv "XDG_STATE_HOME")
    (anvil-pkg-compat-getenv "XDG_STATE_HOME"))
   (t
    (expand-file-name
     ".local/state"
     (or (anvil-pkg-compat-getenv "HOME") "~")))))

;;;###autoload
(defun nelix-store-root ()
  "Return the native Nelix store root directory."
  (expand-file-name
   (or nelix-store-root
       (expand-file-name "nelix/store" (nelix-store--local-data-home)))))

;;;###autoload
(defun nelix-profile-root ()
  "Return the native Nelix profile root directory."
  (expand-file-name
   (or nelix-profile-root
       (expand-file-name "nelix/profiles" (nelix-store--local-state-home)))))

(defun nelix-store--plist-keys (plist)
  "Return keyword keys in PLIST, rejecting malformed input."
  (let ((rest plist)
        keys)
    (while rest
      (unless (and (consp rest) (consp (cdr rest)))
        (signal 'anvil-pkg-error
                (list (format "nelix-store: malformed plist %S" plist))))
      (push (car rest) keys)
      (setq rest (cddr rest)))
    (nreverse keys)))

(defun nelix-store--required-string (caller plist key)
  "Return non-empty string value for KEY in PLIST."
  (let ((value (plist-get plist key)))
    (cond
     ((and (stringp value)
           (> (length (anvil-pkg-compat-string-trim value)) 0))
      (anvil-pkg-compat-string-trim value))
     ((symbolp value) (symbol-name value))
     (t
      (signal 'anvil-pkg-error
              (list (format "%s: %S must be a non-empty string or symbol, got %S"
                            caller key value)))))))

(defun nelix-store--entry-dir-name (entry)
  "Return stable directory name for store ENTRY."
  (let ((hash (nelix-store--required-string "nelix-store-entry" entry :hash))
        (name (nelix-store--required-string "nelix-store-entry" entry :name))
        (version (nelix-store--required-string "nelix-store-entry" entry :version)))
    (format "%s-%s-%s" hash name version)))

;;;###autoload
(defun nelix-store-entry (&rest plist)
  "Return normalized native store entry PLIST.

Required keys are `:name', `:version', `:system', and `:hash'."
  (dolist (key '(:name :version :system :hash))
    (unless (memq key (nelix-store--plist-keys plist))
      (signal 'anvil-pkg-error
              (list (format "nelix-store-entry: missing %S" key)))))
  (let* ((name (nelix-store--required-string "nelix-store-entry" plist :name))
         (version (nelix-store--required-string "nelix-store-entry" plist :version))
         (hash (nelix-store--required-string "nelix-store-entry" plist :hash))
         (system (plist-get plist :system))
         (backend (or (plist-get plist :backend) 'nelix-native))
         (entry (copy-sequence plist)))
    (unless (symbolp system)
      (signal 'anvil-pkg-error
              (list (format "nelix-store-entry: :system must be a symbol, got %S"
                            system))))
    (setq entry (plist-put entry :name name))
    (setq entry (plist-put entry :version version))
    (setq entry (plist-put entry :hash hash))
    (setq entry (plist-put entry :backend backend))
    (setq nelix-store-entry-last entry)))

;;;###autoload
(defun nelix-store-entry-path (entry)
  "Return native store path for ENTRY."
  (expand-file-name (nelix-store--entry-dir-name entry)
                    (nelix-store-root)))

(defun nelix-store--metadata-file (store-path)
  "Return metadata file path inside STORE-PATH."
  (expand-file-name ".nelix/store-entry.el" store-path))

(defun nelix-store--delete-directory-quietly (directory)
  "Delete DIRECTORY recursively when it exists, ignoring errors."
  (when (and directory
             (fboundp 'file-directory-p)
             (file-directory-p directory))
    (condition-case nil
        (delete-directory directory t)
      (error nil))))

(defun nelix-store--format-plist-call (symbol plist)
  "Return an Elisp form calling SYMBOL with PLIST."
  (concat "(" (symbol-name symbol) "\n"
          (mapconcat (lambda (pair)
                       (format " %S %s"
                               (car pair)
                               (nelix-store--format-value (cadr pair))))
                     (let (pairs rest)
                       (setq rest plist)
                       (while rest
                         (push (list (car rest) (cadr rest)) pairs)
                         (setq rest (cddr rest)))
                       (nreverse pairs))
                     "\n")
          ")\n"))

(defun nelix-store--format-value (value)
  "Return Elisp source for literal VALUE."
  (cond
   ((or (null value) (eq value t)) (format "%S" value))
   ((symbolp value) (format "'%S" value))
   ((consp value) (format "'%S" value))
   (t (format "%S" value))))

;;;###autoload
(defun nelix-store-write-entry-at (entry store-path)
  "Create/write metadata for native store ENTRY at STORE-PATH.

This is used by transactional native builders that populate a temporary
store directory before committing it to the final store path."
  (let* ((normalized (apply #'nelix-store-entry entry))
         (metadata (nelix-store--metadata-file store-path)))
    (anvil-pkg-compat-make-directory (file-name-directory metadata) t)
    (anvil-pkg-compat-write-file
     metadata
     (concat ";;; store-entry.el --- generated Nelix store metadata -*- lexical-binding: t; -*-\n\n"
             "(require 'nelix-store)\n\n"
             (nelix-store--format-plist-call 'nelix-store-entry normalized)))
    store-path))

;;;###autoload
(defun nelix-store-write-entry (entry)
  "Create/write metadata for native store ENTRY and return its path."
  (let* ((normalized (apply #'nelix-store-entry entry))
         (store-path (nelix-store-entry-path normalized)))
    (nelix-store-write-entry-at normalized store-path)))

(defun nelix-store--entry-temp-dir (entry)
  "Create and return a temporary store build directory for ENTRY."
  (let ((root (nelix-store-root)))
    (anvil-pkg-compat-make-directory root t)
    (make-temp-file
     (expand-file-name
      (concat ".tmp-" (nelix-store--entry-dir-name entry) "-")
      root)
     t)))

(defun nelix-store--commit-entry-dir (temp-dir store-path)
  "Atomically replace STORE-PATH with completed TEMP-DIR where possible."
  (let ((backup-dir nil))
    (condition-case err
        (progn
          (when (and (fboundp 'file-directory-p)
                     (file-directory-p store-path))
            (setq backup-dir
                  (make-temp-file
                   (expand-file-name
                    ".old-"
                    (file-name-directory
                     (directory-file-name store-path)))
                   t))
            (delete-directory backup-dir t)
            (rename-file store-path backup-dir))
          (when (and (anvil-pkg-compat-file-exists-p store-path)
                     (not (file-directory-p store-path)))
            (signal 'anvil-pkg-error
                    (list (format "nelix-store: final store path is not a directory: %s"
                                  store-path))))
          (rename-file temp-dir store-path)
          (nelix-store--delete-directory-quietly backup-dir)
          store-path)
      (error
       (nelix-store--delete-directory-quietly temp-dir)
       (when (and backup-dir
                  (fboundp 'file-directory-p)
                  (file-directory-p backup-dir)
                  (not (file-exists-p store-path)))
         (rename-file backup-dir store-path))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun nelix-store-read-entry (store-path)
  "Read native store entry metadata from STORE-PATH."
  (let ((file (nelix-store--metadata-file store-path))
        (nelix-store-entry-last nil))
    (unless (anvil-pkg-compat-file-exists-p file)
      (signal 'anvil-pkg-error
              (list (format "nelix-store-read-entry: missing metadata %s" file))))
    (load file nil nil t)
    nelix-store-entry-last))

;;;###autoload
(defun nelix-store-list ()
  "Return native store entries whose metadata is readable."
  (let ((root (nelix-store-root))
        entries)
    (when (and (fboundp 'file-directory-p)
               (file-directory-p root))
      (dolist (path (directory-files root t "\\`[^.]"))
        (when (and (file-directory-p path)
                   (anvil-pkg-compat-file-exists-p
                    (nelix-store--metadata-file path)))
          (push (nelix-store-read-entry path) entries))))
    (nreverse entries)))

;;;###autoload
(defun nelix-store-verify (&optional store-path)
  "Return read-only verification report for STORE-PATH or all entries."
  (if store-path
      (let ((entry (nelix-store-read-entry store-path)))
        (list :ok (and entry t)
              :store-path (expand-file-name store-path)
              :entry entry))
    (let ((entries (nelix-store-list)))
      (list :ok t
            :store-root (nelix-store-root)
            :count (length entries)
            :entries entries))))

;;;###autoload
(defun nelix-profile (&rest plist)
  "Return normalized native profile PLIST."
  (dolist (key '(:name :generation :system :entries))
    (unless (memq key (nelix-store--plist-keys plist))
      (signal 'anvil-pkg-error
              (list (format "nelix-profile: missing %S" key)))))
  (let ((profile (copy-sequence plist)))
    (setq profile
          (plist-put profile :name
                     (nelix-store--required-string "nelix-profile" plist :name)))
    (unless (integerp (plist-get profile :generation))
      (signal 'anvil-pkg-error
              (list (format "nelix-profile: :generation must be integer, got %S"
                            (plist-get profile :generation)))))
    (unless (symbolp (plist-get profile :system))
      (signal 'anvil-pkg-error
              (list (format "nelix-profile: :system must be symbol, got %S"
                            (plist-get profile :system)))))
    (setq nelix-profile-last profile)))

(defun nelix-profile--dir (profile-name)
  "Return directory for PROFILE-NAME."
  (expand-file-name profile-name (nelix-profile-root)))

(defun nelix-profile--generation-dir (profile-name generation)
  "Return directory for PROFILE-NAME GENERATION."
  (expand-file-name (number-to-string generation)
                    (expand-file-name "generations"
                                      (nelix-profile--dir profile-name))))

(defun nelix-profile--profile-file (profile-name generation)
  "Return profile metadata file for PROFILE-NAME GENERATION."
  (expand-file-name "profile.el"
                    (nelix-profile--generation-dir profile-name generation)))

(defun nelix-profile--current-file (profile-name)
  "Return current generation marker file for PROFILE-NAME."
  (expand-file-name "current.el" (nelix-profile--dir profile-name)))

(defun nelix-profile--activation-dir (profile-name)
  "Return activation directory for PROFILE-NAME."
  (expand-file-name "active" (nelix-profile--dir profile-name)))

(defun nelix-profile--activation-profile-dir (profile-name)
  "Return active profile link/copy tree directory for PROFILE-NAME."
  (expand-file-name "profile" (nelix-profile--activation-dir profile-name)))

(defun nelix-profile--activation-temp-dir (profile-name)
  "Create and return a temporary activation directory for PROFILE-NAME."
  (let ((profile-dir (nelix-profile--dir profile-name)))
    (anvil-pkg-compat-make-directory profile-dir t)
    (make-temp-file (expand-file-name "active.tmp-" profile-dir) t)))

(defun nelix-profile--delete-directory-quietly (directory)
  "Delete DIRECTORY recursively when it exists, ignoring errors."
  (when (and directory
             (fboundp 'file-directory-p)
             (file-directory-p directory))
    (condition-case nil
        (delete-directory directory t)
      (error nil))))

(defun nelix-profile--commit-activation-dir (temp-dir active-dir)
  "Replace ACTIVE-DIR with TEMP-DIR, preserving the old tree on failure."
  (let ((backup-dir nil))
    (condition-case err
        (progn
          (when (and (fboundp 'file-directory-p)
                     (file-directory-p active-dir))
            (setq backup-dir
                  (make-temp-file
                   (expand-file-name
                    "active.old-"
                    (file-name-directory
                     (directory-file-name active-dir)))
                   t))
            (delete-directory backup-dir t)
            (rename-file active-dir backup-dir))
          (rename-file temp-dir active-dir)
          (nelix-profile--delete-directory-quietly backup-dir)
          active-dir)
      (error
       (nelix-profile--delete-directory-quietly temp-dir)
       (when (and backup-dir
                  (fboundp 'file-directory-p)
                  (file-directory-p backup-dir)
                  (not (file-exists-p active-dir)))
         (rename-file backup-dir active-dir))
       (signal (car err) (cdr err))))))

(defun nelix-profile--existing-generations (profile-name)
  "Return existing generation numbers for PROFILE-NAME."
  (let ((dir (expand-file-name "generations" (nelix-profile--dir profile-name)))
        gens)
    (when (and (fboundp 'file-directory-p)
               (file-directory-p dir))
      (dolist (path (directory-files dir nil "\\`[0-9]+\\'"))
        (push (string-to-number path) gens)))
    (sort gens #'<)))

;;;###autoload
(defun nelix-profile-next-generation (&optional profile-name)
  "Return next generation number for PROFILE-NAME."
  (let ((gens (nelix-profile--existing-generations
               (or profile-name "default"))))
    (if gens (1+ (car (last gens))) 1)))

;;;###autoload
(defun nelix-profile-write-generation (profile)
  "Write PROFILE metadata and mark it current."
  (let* ((normalized (apply #'nelix-profile profile))
         (name (plist-get normalized :name))
         (generation (plist-get normalized :generation))
         (file (nelix-profile--profile-file name generation)))
    (anvil-pkg-compat-make-directory (file-name-directory file) t)
    (anvil-pkg-compat-write-file
     file
     (concat ";;; profile.el --- generated Nelix profile metadata -*- lexical-binding: t; -*-\n\n"
             "(require 'nelix-store)\n\n"
             (nelix-store--format-plist-call 'nelix-profile normalized)))
    (anvil-pkg-compat-write-file
     (nelix-profile--current-file name)
     (format "%S\n" (list :generation generation :file file)))
    normalized))

;;;###autoload
(defun nelix-profile-create-generation (profile-name system entries)
  "Create a new PROFILE-NAME generation for SYSTEM with ENTRIES."
  (nelix-profile-write-generation
   (list :name profile-name
         :generation (nelix-profile-next-generation profile-name)
         :system system
         :entries entries)))

;;;###autoload
(defun nelix-profile-read (profile-name &optional generation)
  "Read PROFILE-NAME metadata for GENERATION or current generation."
  (let* ((gen (or generation
                  (plist-get (car (read-from-string
                                   (anvil-pkg-compat-read-file
                                    (nelix-profile--current-file profile-name))))
                             :generation)))
         (file (nelix-profile--profile-file profile-name gen))
         (nelix-profile-last nil))
    (unless (anvil-pkg-compat-file-exists-p file)
      (signal 'anvil-pkg-error
              (list (format "nelix-profile-read: missing profile %s" file))))
    (load file nil nil t)
    nelix-profile-last))

;;;###autoload
(defun nelix-profile-rollback (&optional profile-name generation)
  "Set PROFILE-NAME current marker to GENERATION and return that profile."
  (let* ((name (or profile-name "default"))
         (gen (or generation
                  (let ((gens (nelix-profile--existing-generations name)))
                    (unless (> (length gens) 1)
                      (signal 'anvil-pkg-error
                              (list (format "nelix-profile-rollback: no previous generation for %s"
                                            name))))
                    (nth (- (length gens) 2) gens))))
         (profile (nelix-profile-read name gen)))
    (anvil-pkg-compat-write-file
     (nelix-profile--current-file name)
     (format "%S\n" (list :generation gen
                          :file (nelix-profile--profile-file name gen))))
    profile))

(defun nelix-profile--names ()
  "Return profile names under `nelix-profile-root'."
  (let ((root (nelix-profile-root))
        names)
    (when (and (fboundp 'file-directory-p)
               (file-directory-p root))
      (dolist (path (directory-files root nil "\\`[^.]"))
        (when (file-directory-p (expand-file-name path root))
          (push path names))))
    (sort names #'string<)))

;;;###autoload
(defun nelix-profile-live-store-paths (&optional profile-name)
  "Return store paths referenced by PROFILE-NAME generations.

When PROFILE-NAME is nil, scan all native profiles.  All
generations are considered live so rollback remains possible after
GC."
  (let ((profiles (if profile-name
                      (list profile-name)
                    (nelix-profile--names)))
        paths)
    (dolist (name profiles (nreverse paths))
      (dolist (generation (nelix-profile--existing-generations name))
        (let ((profile (condition-case _
                           (nelix-profile-read name generation)
                         (error nil))))
          (dolist (entry (plist-get profile :entries))
            (let ((path (plist-get entry :store-path)))
              (when (and (stringp path)
                         (not (member path paths)))
                (push (expand-file-name path) paths)))))))))

;;;###autoload
(defun nelix-profile-prune (profile-name remove-names &optional system)
  "Remove REMOVE-NAMES from PROFILE-NAME current generation.

Create and return a new profile generation when any entry is
removed.  REMOVE-NAMES may contain strings or symbols."
  (let* ((name (or profile-name "default"))
         (profile (nelix-profile-read name))
         (remove (mapcar (lambda (item)
                           (if (symbolp item) (symbol-name item) item))
                         remove-names))
         kept removed)
    (dolist (entry (plist-get profile :entries))
      (if (member (plist-get entry :name) remove)
          (push entry removed)
        (push entry kept)))
    (setq kept (nreverse kept)
          removed (nreverse removed))
    (list :profile-name name
          :removed removed
          :kept kept
          :changed (and removed t)
          :profile (if removed
                       (nelix-profile-create-generation
                        name
                        (or system (plist-get profile :system))
                        kept)
                     profile))))

;;;###autoload
(defun nelix-store-gc (&rest args)
  "Collect native store entries not referenced by any profile generation.

ARGS accepts `:dry-run' and `:profile'.  When `:profile' is nil,
all profiles are considered live roots."
  (let* ((dry-run (plist-get args :dry-run))
         (profile (plist-get args :profile))
         (live (nelix-profile-live-store-paths profile))
         collected kept)
    (dolist (entry (nelix-store-list))
      (let ((path (nelix-store-entry-path entry)))
        (if (member (expand-file-name path) live)
            (push path kept)
          (push path collected)
          (unless dry-run
            (when (and (fboundp 'file-directory-p)
                       (file-directory-p path))
              (delete-directory path t))))))
    (list :ok t
          :dry-run (and dry-run t)
          :profile profile
          :live (nreverse kept)
          :collected (nreverse collected)
          :removed (if dry-run nil (nreverse collected)))))

;;;###autoload
(defun nelix-profile-emacs-load-paths (&optional profile-name generation)
  "Return Emacs load-path entries from PROFILE-NAME GENERATION."
  (let ((profile (nelix-profile-read (or profile-name "default") generation))
        paths)
    (dolist (entry (plist-get profile :entries) (nreverse paths))
      (dolist (path (plist-get entry :emacs-load-paths))
        (when (and (stringp path)
                   (not (member path paths)))
          (push path paths))))))

;;;###autoload
(defun nelix-profile-activate-emacs (&optional profile-name generation)
  "Add PROFILE-NAME GENERATION Emacs load paths to `load-path'.

Return the load-path entries that were added or already present in
the profile metadata order."
  (let (activated)
    (dolist (path (nelix-profile-emacs-load-paths profile-name generation)
                  (nreverse activated))
      (when (and (boundp 'load-path)
                 (stringp path)
                 (or (not (fboundp 'file-directory-p))
                     (file-directory-p path)))
        (add-to-list 'load-path path)
        (push path activated)))))

(defun nelix-profile--windows-system-p (system)
  "Return non-nil when SYSTEM is a Windows platform id."
  (memq system '(x86_64-windows aarch64-windows i686-windows)))

(defun nelix-profile--render-posix-shim (target)
  "Return POSIX shim content for TARGET."
  (format "#!/bin/sh\nexec \"%s\" \"$@\"\n" target))

(defun nelix-profile--render-windows-shim (target)
  "Return Windows cmd shim content for TARGET."
  (format "@echo off\r\n\"%s\" %%*\r\n" target))

(defun nelix-profile--command-name (runtime-bin windows-p)
  "Return activation command name for RUNTIME-BIN."
  (let ((name (file-name-nondirectory runtime-bin)))
    (if windows-p
        (concat (file-name-sans-extension name) ".cmd")
      name)))

(defun nelix-profile--runtime-bin-targets (entry)
  "Return runtime bin target rows for profile ENTRY."
  (let ((store-path (plist-get entry :store-path))
        (bins (plist-get entry :runtime-bins))
        rows)
    (when (and store-path bins)
      (dolist (bin bins (nreverse rows))
        (let ((target (expand-file-name bin store-path)))
          (when (anvil-pkg-compat-file-exists-p target)
            (push (list :name (plist-get entry :name)
                        :runtime-bin bin
                        :target target)
                  rows)))))))

(defun nelix-profile--activation-link-mode (windows-p)
  "Return concrete activation link mode for WINDOWS-P."
  (pcase nelix-profile-activation-link-mode
    ('nil nil)
    ('copy 'copy)
    ('symlink (if windows-p 'copy 'symlink))
    (_ (if (and (not windows-p)
                (fboundp 'make-symbolic-link))
           'symlink
         'copy))))

(defun nelix-profile--copy-activation-file (target link)
  "Copy TARGET to activation LINK and preserve executable bit where possible."
  (copy-file target link t)
  (when (and (not (eq system-type 'windows-nt))
             (fboundp 'file-modes)
             (fboundp 'set-file-modes))
    (set-file-modes link (file-modes target))))

(defun nelix-profile--activate-link-file (target link mode)
  "Materialize TARGET at activation LINK using MODE.
Return the concrete mode used, either `symlink' or `copy'."
  (anvil-pkg-compat-make-directory (file-name-directory link) t)
  (when (anvil-pkg-compat-file-exists-p link)
    (delete-file link))
  (pcase mode
    ('symlink
     (condition-case err
         (progn
           (make-symbolic-link target link t)
           'symlink)
       (error
        (if (eq nelix-profile-activation-link-mode 'symlink)
            (signal (car err) (cdr err))
          (nelix-profile--copy-activation-file target link)
          'copy))))
    ('copy
     (nelix-profile--copy-activation-file target link)
     'copy)
    (_
     nil)))

;;;###autoload
(defun nelix-profile-activate-runtime (&optional profile-name generation)
  "Generate runtime shims and PATH fragment for PROFILE-NAME GENERATION.

The activation directory is regenerated on each call under the profile's
=active= directory.  POSIX systems get executable shell shims and
=path.sh=.  Windows profile systems get =.cmd= shims and =path.cmd=.
Activation also creates an =active/profile= file tree.  POSIX profiles
use symlinks when available, while Windows profiles use copied files."
  (let* ((name (or profile-name "default"))
         (profile (nelix-profile-read name generation))
         (system (plist-get profile :system))
         (windows-p (nelix-profile--windows-system-p system))
         (active-dir (nelix-profile--activation-dir name))
         (bin-dir (expand-file-name "bin" active-dir))
         (profile-dir (nelix-profile--activation-profile-dir name))
         (path-fragment (expand-file-name (if windows-p "path.cmd" "path.sh")
                                          active-dir))
         (build-dir (nelix-profile--activation-temp-dir name))
         (build-bin-dir (expand-file-name "bin" build-dir))
         (build-profile-dir (expand-file-name "profile" build-dir))
         (build-path-fragment
          (expand-file-name (if windows-p "path.cmd" "path.sh")
                            build-dir))
         (link-mode (nelix-profile--activation-link-mode windows-p))
         shims links seen seen-links)
    (condition-case err
        (progn
          (anvil-pkg-compat-make-directory build-bin-dir t)
          (when link-mode
            (anvil-pkg-compat-make-directory build-profile-dir t))
          (dolist (entry (plist-get profile :entries))
            (dolist (row (nelix-profile--runtime-bin-targets entry))
              (let* ((command (nelix-profile--command-name
                               (plist-get row :runtime-bin)
                               windows-p))
                     (build-shim (expand-file-name command build-bin-dir))
                     (shim (expand-file-name command bin-dir))
                     (target (plist-get row :target))
                     (relative (plist-get row :runtime-bin))
                     (link (and link-mode
                                (expand-file-name relative profile-dir)))
                     (build-link
                      (and link-mode
                           (expand-file-name relative build-profile-dir))))
                (unless (member command seen)
                  (push command seen)
                  (anvil-pkg-compat-write-file
                   build-shim
                   (if windows-p
                       (nelix-profile--render-windows-shim target)
                     (nelix-profile--render-posix-shim target)))
                  (when (and (not windows-p)
                             (fboundp 'set-file-modes))
                    (set-file-modes build-shim #o755))
                  (push (append row
                                (list :command command
                                      :shim shim))
                        shims))
                (when (and link-mode
                           (not (member relative seen-links)))
                  (push relative seen-links)
                  (let ((used-mode
                         (nelix-profile--activate-link-file
                          target build-link link-mode)))
                    (push (append row
                                  (list :relative-path relative
                                        :link link
                                        :mode used-mode))
                          links))))))
          (anvil-pkg-compat-write-file
           build-path-fragment
           (if windows-p
               (format "@echo off\r\nset \"PATH=%s;%%PATH%%\"\r\n" bin-dir)
             (format "PATH=\"%s:$PATH\"\nexport PATH\n" bin-dir)))
          (nelix-profile--commit-activation-dir build-dir active-dir)
          (list :status 'ok
                :profile name
                :generation (plist-get profile :generation)
                :system system
                :activation-dir active-dir
                :bin-dir bin-dir
                :profile-dir (and link-mode profile-dir)
                :path-fragment path-fragment
                :shims (nreverse shims)
                :links (nreverse links)))
      (error
       (nelix-profile--delete-directory-quietly build-dir)
       (signal (car err) (cdr err))))))

(provide 'nelix-store)
;;; nelix-store.el ends here
