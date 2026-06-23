;;; nelix-registry.el --- Native Nelix package registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native registry support for Doc 22.  Recipes are data-oriented Elisp forms
;; created with `nelix-package'.  Local roots and hash-verified static remote
;; indexes can be loaded before search/show/install flows run without Nix.

;;; Code:

(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-compat)
(require 'nelix-fetch)
(require 'nelix-store)

(declare-function nelix-substitute-canonical-message "nelix-substitute")
(declare-function nelix-substitute-signature-report "nelix-substitute")

(defvar read-eval)

(defgroup nelix-registry nil
  "Native Nelix registry."
  :group 'nelix-core
  :prefix "nelix-registry-")

(defcustom nelix-registry-root nil
  "Local Nelix registry root.
When nil, `nelix-registry-root' computes an OS-appropriate default."
  :type '(choice (const :tag "Auto" nil) directory)
  :group 'nelix-registry)

(defcustom nelix-registry-roots nil
  "Additional local registry roots loaded by `nelix-registry-update'."
  :type '(repeat directory)
  :group 'nelix-registry)

(defcustom nelix-registry-remotes nil
  "Static remote registry indexes synchronized by `nelix-registry-update'.

Each entry is a plist with at least `:name', `:url', and `:sha256'.
The URL points at an Elisp index file that calls
`nelix-registry-index'.  Package rows inside that index declare
`:path' or `:url' plus `:sha256'; recipe files are hash-verified
before they are cached under the local registry root.  Remote entries
may also declare `:sig' or `:signature', `:trusted-signers',
`:public-keys', and `:require-signature' for signed index policy."
  :type '(repeat plist)
  :group 'nelix-registry)

(defcustom nelix-registry-trusted-signers nil
  "Trusted signer key names for signed registry indexes."
  :type '(repeat string)
  :group 'nelix-registry)

(defcustom nelix-registry-public-keys nil
  "Public keys used for cryptographic registry index signature checks.
Entries use the same plist shape as `nelix-substitute-public-keys'."
  :type '(repeat sexp)
  :group 'nelix-registry)

(defcustom nelix-registry-require-signature nil
  "Whether remote registry indexes must have trusted signatures."
  :type 'boolean
  :group 'nelix-registry)

(defcustom nelix-registry-require-recipe-signature nil
  "Whether remote package recipe rows must have trusted signatures."
  :type 'boolean
  :group 'nelix-registry)

(defcustom nelix-registry-include-packaged-root t
  "Whether `nelix-registry-update' loads packaged registry recipes.

Set environment variable `NELIX_REGISTRY_INCLUDE_PACKAGED=0' to disable
packaged recipes for isolated tests or fully private registries."
  :type 'boolean
  :group 'nelix-registry)

(defvar nelix-package-last nil
  "Most recently loaded `nelix-package' recipe.")

(defvar nelix-registry-index-last nil
  "Most recently loaded `nelix-registry-index' plist.")

(defvar nelix-registry--packages nil
  "In-memory registry of package recipes keyed by package name.")

(defun nelix-registry-root ()
  "Return the default local registry root."
  (expand-file-name
   (or nelix-registry-root
       (expand-file-name "nelix/registry" (nelix-store--local-data-home)))))

(defun nelix-registry--packaged-enabled-p ()
  "Return non-nil when packaged registry roots should be loaded."
  (let ((env (nelix-compat-getenv "NELIX_REGISTRY_INCLUDE_PACKAGED")))
    (and nelix-registry-include-packaged-root
         (not (member env '("0" "false" "FALSE" "no" "NO"))))))

(defun nelix-registry--library-directory ()
  "Return the directory containing the installed Nelix Lisp files."
  (file-name-directory
   (expand-file-name
    (or load-file-name
        (locate-library "nelix-registry")
        buffer-file-name
        "nelix-registry.el"))))

(defun nelix-registry-packaged-root ()
  "Return packaged registry root, or nil when no packaged recipes exist."
  (let ((root (expand-file-name "registry"
                                (nelix-registry--library-directory))))
    (and (fboundp 'file-directory-p)
         (file-directory-p root)
         root)))

(defun nelix-registry--default-roots (remote-reports)
  "Return default registry roots including packaged and REMOTE-REPORTS roots.

Packaged recipes load first, remote cache roots next, then the user local root
and `nelix-registry-roots'.  Later roots override earlier recipes with the same
package name."
  (append (when (nelix-registry--packaged-enabled-p)
            (let ((root (nelix-registry-packaged-root)))
              (and root (list root))))
          (mapcar (lambda (report)
                    (plist-get report :cache-root))
                  remote-reports)
          (list (nelix-registry-root))
          nelix-registry-roots))

(defun nelix-registry--ensure-table ()
  "Ensure `nelix-registry--packages' is a hash table."
  (unless (hash-table-p nelix-registry--packages)
    (setq nelix-registry--packages
          (make-hash-table :test 'equal)))
  nelix-registry--packages)

(defun nelix-registry--required-string (caller plist key)
  "Return non-empty string value for KEY in PLIST."
  (let ((value (plist-get plist key)))
    (cond
     ((and (stringp value)
           (> (length (nelix-compat-string-trim value)) 0))
      (nelix-compat-string-trim value))
     ((symbolp value) (symbol-name value))
     (t
      (signal 'nelix-error
              (list (format "%s: %S must be a non-empty string or symbol, got %S"
                            caller key value)))))))

(defun nelix-registry--plist-keys (plist)
  "Return keyword keys in PLIST, rejecting malformed input."
  (let ((rest plist)
        keys)
    (while rest
      (unless (and (consp rest) (consp (cdr rest)))
        (signal 'nelix-error
                (list (format "nelix-package: malformed plist %S" plist))))
      (push (car rest) keys)
      (setq rest (cddr rest)))
    (nreverse keys)))

;;;###autoload
(defun nelix-package (&rest plist)
  "Return normalized native Nelix package recipe PLIST."
  (dolist (key '(:name :version :class :systems))
    (unless (memq key (nelix-registry--plist-keys plist))
      (signal 'nelix-error
              (list (format "nelix-package: missing %S" key)))))
  (let* ((name (nelix-registry--required-string "nelix-package" plist :name))
         (version (nelix-registry--required-string "nelix-package" plist :version))
         (class (plist-get plist :class))
         (systems (plist-get plist :systems))
         (recipe (copy-sequence plist)))
    (unless (symbolp class)
      (signal 'nelix-error
              (list (format "nelix-package: :class must be symbol, got %S"
                            class))))
    (unless (listp systems)
      (signal 'nelix-error
              (list (format "nelix-package: :systems must be list, got %S"
                            systems))))
    (setq recipe (plist-put recipe :name name))
    (setq recipe (plist-put recipe :version version))
    (setq nelix-package-last recipe)
    recipe))

;;;###autoload
(defun nelix-registry-index (&rest plist)
  "Return normalized static registry index PLIST."
  (dolist (key '(:version :packages))
    (unless (memq key (nelix-registry--plist-keys plist))
      (signal 'nelix-error
              (list (format "nelix-registry-index: missing %S" key)))))
  (let ((version (plist-get plist :version))
        (packages (plist-get plist :packages))
        (index (copy-sequence plist)))
    (unless (integerp version)
      (signal 'nelix-error
              (list (format "nelix-registry-index: :version must be integer, got %S"
                            version))))
    (unless (listp packages)
      (signal 'nelix-error
              (list (format "nelix-registry-index: :packages must be list, got %S"
                            packages))))
    (setq nelix-registry-index-last index)
    index))

(defun nelix-registry--recipe-system-supported-p (recipe system)
  "Return non-nil when RECIPE has data for SYSTEM."
  (let ((systems (plist-get recipe :systems))
        supported)
    (dolist (entry systems supported)
      (when (and (consp entry)
                 (eq (car entry) system))
        (setq supported t)))))

(defun nelix-registry-add (recipe)
  "Add RECIPE to the in-memory registry."
  (let ((normalized (apply #'nelix-package recipe)))
    (puthash (plist-get normalized :name)
             normalized
             (nelix-registry--ensure-table))
    normalized))

(defun nelix-registry--canonicalize-nil-t (form)
  "Recursively replace standalone-reader pseudo nil/t symbols in FORM.
NeLisp's standalone `read-from-string' interns the bare tokens `nil' and
`t' as fresh symbols not `eq' to the canonical empty-list / true objects;
only the empty-list token yields canonical nil.  Such pseudo-symbols print
as nil/t yet are truthy and non-`eq', silently breaking predicates and
optional-argument handling such as `write-region's END, which aborts a
build phase.  Walk FORM, rebuilding conses and mapping any non-canonical
nil/t leaf back to the canonical object.  No-op on host Emacs."
  (cond
   ((consp form)
    (cons (nelix-registry--canonicalize-nil-t (car form))
          (nelix-registry--canonicalize-nil-t (cdr form))))
   ((and (symbolp form) form)
    (let ((nm (symbol-name form)))
      (cond ((string-equal nm "nil") nil)
            ((and (string-equal nm "t") (not (eq form t))) t)
            (t form))))
   (t form)))

(defun nelix-registry--read-forms (file)
  "Read Elisp data forms from FILE without evaluating them."
  (let ((forms nil)
        (read-eval nil))
    (if (not (fboundp 'goto-char))
        ;; Standalone NeLisp: buffer-nav primitives absent; use
        ;; read-from-string loop over the file contents instead.
        (let* ((contents (with-temp-buffer
                           (insert-file-contents (expand-file-name file))
                           (buffer-string)))
               (pos 0)
               (len (length contents)))
          (condition-case err
              (while (< pos len)
                ;; Skip leading whitespace manually.
                (while (and (< pos len)
                            (let ((ch (substring contents pos (1+ pos))))
                              (or (string-equal ch " ")
                                  (string-equal ch "\t")
                                  (string-equal ch "\n")
                                  (string-equal ch "\r"))))
                  (setq pos (1+ pos)))
                ;; Skip comment lines (`;' to end of line).
                (while (and (< pos len)
                            (string-equal (substring contents pos (1+ pos)) ";"))
                  (while (and (< pos len)
                              (not (string-equal (substring contents pos (1+ pos)) "\n")))
                    (setq pos (1+ pos)))
                  ;; Consume the newline.
                  (when (< pos len)
                    (setq pos (1+ pos)))
                  ;; Skip any further whitespace after the comment.
                  (while (and (< pos len)
                              (let ((ch (substring contents pos (1+ pos))))
                                (or (string-equal ch " ")
                                    (string-equal ch "\t")
                                    (string-equal ch "\n")
                                    (string-equal ch "\r"))))
                    (setq pos (1+ pos))))
                (when (< pos len)
                  (let* ((result (read-from-string contents pos))
                         (form (car result))
                         (new-pos (cdr result)))
                    (push (nelix-registry--canonicalize-nil-t form) forms)
                    (setq pos new-pos))))
            (end-of-file nil)
            (invalid-read-syntax
             (signal 'nelix-error
                     (list (format "nelix-registry: invalid recipe syntax in %s: %s"
                                   file
                                   (error-message-string err)))))))
      (with-temp-buffer
        (insert-file-contents (expand-file-name file))
        (goto-char (point-min))
        (condition-case err
            (while t
              (push (read (current-buffer)) forms))
          (end-of-file nil)
          (invalid-read-syntax
           (signal 'nelix-error
                   (list (format "nelix-registry: invalid recipe syntax in %s: %s"
                                 file
                                 (error-message-string err))))))))
    (nreverse forms)))

(defun nelix-registry--quoted-form-p (form)
  "Return non-nil when FORM is `(quote VALUE)'."
  (and (consp form)
       (eq (car form) 'quote)
       (consp (cdr form))
       (null (cddr form))))

(defun nelix-registry--literal-value (file form)
  "Return literal value represented by FORM in FILE.
Top-level package/index plist arguments may be quoted data or atoms.
Unquoted lists are rejected so registry files are parsed as data, not
executed as Elisp programs."
  (cond
   ((nelix-registry--quoted-form-p form)
    (cadr form))
   ((or (null form)
        (stringp form)
        (numberp form)
        (symbolp form))
    form)
   (t
    (signal 'nelix-error
            (list (format "nelix-registry: non-literal form in %s: %S"
                          file
                          form))))))

(defun nelix-registry--literal-args (file args)
  "Return literal plist ARGS read from FILE."
  (mapcar (lambda (form)
            (nelix-registry--literal-value file form))
          args))

(defun nelix-registry--require-form-p (form)
  "Return non-nil when FORM is an allowed registry require form."
  (and (consp form)
       (eq (car form) 'require)
       (let ((feature (cadr form)))
         (or (eq feature 'nelix-registry)
             (and (nelix-registry--quoted-form-p feature)
                  (eq (cadr feature) 'nelix-registry))))))

(defun nelix-registry--read-call (file function)
  "Read FILE as data and return the sole FUNCTION call's literal args."
  (let ((calls nil))
    (dolist (form (nelix-registry--read-forms file))
      (cond
       ((nelix-registry--require-form-p form) nil)
       ((and (consp form)
             (eq (car form) function))
        (push (cdr form) calls))
       (t
        (signal 'nelix-error
                (list (format "nelix-registry: unsupported form in %s: %S"
                              file
                              form))))))
    (cond
     ((null calls)
      (signal 'nelix-error
              (list (format "nelix-registry: %s did not contain %S"
                            file
                            function))))
     ((cdr calls)
      (signal 'nelix-error
              (list (format "nelix-registry: %s contains multiple %S forms"
                            file
                            function))))
     (t
      (nelix-registry--literal-args file (car calls))))))

(defun nelix-registry--load-file (file)
  "Load one registry recipe FILE and return its recipe."
  (nelix-registry-add
   (apply #'nelix-package
          (nelix-registry--read-call file 'nelix-package))))

(defun nelix-registry--recipe-files (root)
  "Return recipe files under ROOT/packages."
  (let ((packages-dir (expand-file-name "packages" root))
        files)
    (when (and (fboundp 'file-directory-p)
               (file-directory-p packages-dir))
      (dolist (path (directory-files-recursively packages-dir "\\.el\\'"))
        (push path files)))
    (sort files #'string<)))

(defun nelix-registry--remote-name (remote)
  "Return normalized REMOTE name."
  (nelix-registry--required-string "nelix-registry remote" remote :name))

(defun nelix-registry--remote-url (remote)
  "Return normalized REMOTE URL."
  (nelix-registry--required-string "nelix-registry remote" remote :url))

(defun nelix-registry--remote-sha256 (remote)
  "Return normalized REMOTE index hash."
  (nelix-registry--required-string "nelix-registry remote" remote :sha256))

(defun nelix-registry--remote-signature (remote)
  "Return REMOTE registry signature, if any."
  (or (plist-get remote :sig)
      (plist-get remote :signature)))

(defun nelix-registry--remote-trusted-signers (remote)
  "Return trusted signers for REMOTE."
  (or (plist-get remote :trusted-signers)
      nelix-registry-trusted-signers))

(defun nelix-registry--remote-public-keys (remote)
  "Return public keys for REMOTE."
  (or (plist-get remote :public-keys)
      nelix-registry-public-keys))

(defun nelix-registry--row-signature (row)
  "Return package ROW signature, if any."
  (or (plist-get row :sig)
      (plist-get row :signature)))

(defun nelix-registry--row-trusted-signers (row remote)
  "Return trusted signers for package ROW in REMOTE."
  (or (plist-get row :trusted-signers)
      (plist-get remote :recipe-trusted-signers)
      (nelix-registry--remote-trusted-signers remote)))

(defun nelix-registry--row-public-keys (row remote)
  "Return public keys for package ROW in REMOTE."
  (or (plist-get row :public-keys)
      (plist-get remote :recipe-public-keys)
      (nelix-registry--remote-public-keys remote)))

(defun nelix-registry--row-signature-algorithm (row remote)
  "Return signature algorithm for package ROW in REMOTE."
  (or (plist-get row :signature-algorithm)
      (plist-get remote :recipe-signature-algorithm)))

(defun nelix-registry--row-signature-format (row remote)
  "Return signature format for package ROW in REMOTE."
  (or (plist-get row :signature-format)
      (plist-get remote :recipe-signature-format)))

(defun nelix-registry--row-require-signature-p (row remote)
  "Return non-nil when package ROW in REMOTE requires a signature."
  (or nelix-registry-require-recipe-signature
      (plist-get remote :require-recipe-signature)
      (plist-get row :require-signature)))

(defun nelix-registry--remote-cache-root (remote)
  "Return local cache root for REMOTE."
  (expand-file-name
   (nelix-registry--remote-name remote)
   (expand-file-name "remotes" (nelix-registry-root))))

(defun nelix-registry--url-directory (url)
  "Return URL or file-name directory for URL."
  (cond
   ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url)
    (replace-regexp-in-string "[^/]*\\'" "" url))
   (t
    (file-name-as-directory
     (file-name-directory (expand-file-name url))))))

(defun nelix-registry--join-url (base path)
  "Return PATH resolved relative to BASE."
  (cond
   ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" path)
    path)
   ((file-name-absolute-p path)
    path)
   ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" base)
    (concat (nelix-fetch--ensure-directory-url base) path))
   (t
    (expand-file-name path base))))

(defun nelix-registry--load-index-file (file)
  "Load registry index FILE and return its plist."
  (apply #'nelix-registry-index
         (nelix-registry--read-call file 'nelix-registry-index)))

(defun nelix-registry--index-signature-descriptor
    (remote index sha256 &optional signature)
  "Return substitute-compatible signature descriptor for REMOTE INDEX."
  (let ((descriptor
         (list :name (format "registry:%s"
                             (nelix-registry--remote-name remote))
               :version (number-to-string (plist-get index :version))
               :system 'nelix-registry-index
               :source 'nelix-registry
               :sha256 sha256
               :url (nelix-registry--remote-url remote)
               :package-count (length (plist-get index :packages)))))
    (when (plist-get remote :signature-algorithm)
      (setq descriptor
            (append descriptor
                    (list :signature-algorithm
                          (plist-get remote :signature-algorithm)))))
    (when (plist-get remote :signature-format)
      (setq descriptor
            (append descriptor
                    (list :signature-format
                          (plist-get remote :signature-format)))))
    (if signature
        (append descriptor (list :sig signature))
      descriptor)))

;;;###autoload
(defun nelix-registry-index-signature-message (remote index sha256)
  "Return canonical signed message for REMOTE INDEX SHA256."
  (require 'nelix-substitute)
  (nelix-substitute-canonical-message
   (nelix-registry--index-signature-descriptor remote index sha256)))

(defun nelix-registry--verify-index-signature (remote index sha256)
  "Verify REMOTE INDEX signature policy and return a report plist."
  (let* ((signature (nelix-registry--remote-signature remote))
         (required (or nelix-registry-require-signature
                       (plist-get remote :require-signature)))
         (descriptor (nelix-registry--index-signature-descriptor
                      remote
                      index
                      sha256
                      signature))
         (report
          (when (or signature required)
            (require 'nelix-substitute)
            (nelix-substitute-signature-report
             descriptor
             (nelix-registry--remote-trusted-signers remote)
             (nelix-registry--remote-public-keys remote)))))
    (when (and required (not signature))
      (signal 'nelix-error
              (list "nelix-registry: remote registry index requires a signature"
                    :remote (nelix-registry--remote-name remote)
                    :signature report)))
    (when (and report (not (plist-get report :verified)))
      (signal 'nelix-error
              (list (format "nelix-registry: untrusted registry index signature for %s: %S"
                            (nelix-registry--remote-name remote)
                            (plist-get report :blocked))
                    :remote (nelix-registry--remote-name remote)
                    :signature report)))
    (or report (list :required nil
                     :present nil
                     :verified nil
                     :blocked nil))))

(defun nelix-registry--recipe-signature-descriptor
    (remote row recipe sha256 &optional signature)
  "Return substitute-compatible signature descriptor for ROW RECIPE."
  (let* ((path (or (plist-get row :path)
                   (plist-get row :file)))
         (url (plist-get row :url))
         (descriptor
          (list :name (format "registry-recipe:%s"
                              (plist-get recipe :name))
                :version (plist-get recipe :version)
                :system 'nelix-registry-recipe
                :source 'nelix-registry
                :sha256 sha256
                :remote (nelix-registry--remote-name remote)
                :recipe-name (plist-get recipe :name)
                :recipe-class (plist-get recipe :class))))
    (when path
      (setq descriptor (append descriptor (list :path path))))
    (when url
      (setq descriptor (append descriptor (list :url url))))
    (when (nelix-registry--row-signature-algorithm row remote)
      (setq descriptor
            (append descriptor
                    (list :signature-algorithm
                          (nelix-registry--row-signature-algorithm
                           row
                           remote)))))
    (when (nelix-registry--row-signature-format row remote)
      (setq descriptor
            (append descriptor
                    (list :signature-format
                          (nelix-registry--row-signature-format
                           row
                           remote)))))
    (if signature
        (append descriptor (list :sig signature))
      descriptor)))

;;;###autoload
(defun nelix-registry-recipe-signature-message (remote row recipe sha256)
  "Return canonical signed message for package ROW RECIPE SHA256."
  (require 'nelix-substitute)
  (nelix-substitute-canonical-message
   (nelix-registry--recipe-signature-descriptor remote row recipe sha256)))

(defun nelix-registry--verify-recipe-signature
    (remote row recipe sha256)
  "Verify package ROW signature policy for RECIPE and return report plist."
  (let* ((signature (nelix-registry--row-signature row))
         (required (nelix-registry--row-require-signature-p row remote))
         (descriptor (nelix-registry--recipe-signature-descriptor
                      remote
                      row
                      recipe
                      sha256
                      signature))
         (report
          (when (or signature required)
            (require 'nelix-substitute)
            (nelix-substitute-signature-report
             descriptor
             (nelix-registry--row-trusted-signers row remote)
             (nelix-registry--row-public-keys row remote)))))
    (when (and required (not signature))
      (signal 'nelix-error
              (list "nelix-registry: remote package recipe requires a signature"
                    :remote (nelix-registry--remote-name remote)
                    :row row
                    :signature report)))
    (when (and report (not (plist-get report :verified)))
      (signal 'nelix-error
              (list (format "nelix-registry: untrusted package recipe signature for %s: %S"
                            (plist-get recipe :name)
                            (plist-get report :blocked))
                    :remote (nelix-registry--remote-name remote)
                    :row row
                    :signature report)))
    (or report (list :required nil
                     :present nil
                     :verified nil
                     :blocked nil))))

(defun nelix-registry--sync-remote-package (remote row base-url cache-root)
  "Synchronize one package ROW from REMOTE BASE-URL into CACHE-ROOT."
  (let* ((path (or (plist-get row :path)
                   (plist-get row :file)))
         (url (or (plist-get row :url)
                  (and path
                       (nelix-registry--join-url base-url path))))
         (sha256 (plist-get row :sha256))
         (dest (expand-file-name
                (or path (file-name-nondirectory url))
                cache-root)))
    (unless (and (stringp url)
                 (> (length (nelix-compat-string-trim url)) 0))
      (signal 'nelix-error
              (list (format "nelix-registry: remote package row needs :path or :url: %S"
                            row))))
    (unless sha256
      (signal 'nelix-error
              (list (format "nelix-registry: remote package row needs :sha256: %S"
                            row))))
    (nelix-compat-make-directory (file-name-directory dest) t)
    (nelix-fetch-source
     (list :type 'url :url url :sha256 sha256)
     dest)
    (let* ((recipe (apply #'nelix-package
                          (nelix-registry--read-call dest 'nelix-package)))
           (signature (nelix-registry--verify-recipe-signature
                       remote
                       row
                       recipe
                       sha256)))
      (list :file dest
            :signature signature))))

;;;###autoload
(defun nelix-registry-sync-remote (remote)
  "Synchronize one static REMOTE registry and return a report plist."
  (let* ((name (nelix-registry--remote-name remote))
         (url (nelix-registry--remote-url remote))
         (sha256 (nelix-registry--remote-sha256 remote))
         (cache-root (nelix-registry--remote-cache-root remote))
         (index-file (expand-file-name "index.el" cache-root))
         (base-url (nelix-registry--url-directory url))
         index synced)
    (nelix-compat-make-directory cache-root t)
    (nelix-fetch-source
     (list :type 'url :url url :sha256 sha256)
     index-file)
    (setq index (nelix-registry--load-index-file index-file))
    (let ((signature (nelix-registry--verify-index-signature
                      remote
                      index
                      sha256)))
      (dolist (row (plist-get index :packages))
        (push (nelix-registry--sync-remote-package
               remote
               row
               base-url
               cache-root)
              synced))
      (setq synced (nreverse synced))
      (list :status 'ok
            :name name
            :url url
            :cache-root cache-root
            :index index-file
            :signature signature
            :packages (mapcar (lambda (report)
                                (plist-get report :file))
                              synced)
            :package-signatures
            (mapcar (lambda (report)
                      (plist-get report :signature))
                    synced)
            :count (length synced)))))

;;;###autoload
(defun nelix-registry-load-root (root)
  "Load local registry ROOT and return loaded recipe count."
  (let ((count 0))
    (dolist (file (nelix-registry--recipe-files (expand-file-name root)) count)
      (nelix-registry--load-file file)
      (setq count (1+ count)))))

(defun nelix-registry--portable-relative-file-name (file root)
  "Return FILE relative to ROOT using forward slashes."
  (subst-char-in-string
   ?\\ ?/
   (file-relative-name (expand-file-name file)
                       (file-name-as-directory (expand-file-name root)))))

;;;###autoload
(defun nelix-registry-build-index (root &optional version)
  "Return a static registry index plist for local registry ROOT.

The returned index has the same shape accepted by
`nelix-registry-index'.  Each package row contains at least `:path'
and `:sha256', plus recipe identity fields for human inspection.
Recipe files are parsed through the data-only registry parser before
they are included."
  (let ((root* (expand-file-name root))
        rows)
    (unless (and (fboundp 'file-directory-p)
                 (file-directory-p root*))
      (signal 'nelix-error
              (list (format "nelix-registry-build-index: missing registry root %s"
                            root*))))
    (dolist (file (nelix-registry--recipe-files root*))
      (let* ((recipe (apply #'nelix-package
                            (nelix-registry--read-call file 'nelix-package)))
             (relative (nelix-registry--portable-relative-file-name
                        file root*)))
        (push (list :path relative
                    :sha256 (nelix-fetch-sha256-file file)
                    :name (plist-get recipe :name)
                    :version (plist-get recipe :version)
                    :class (plist-get recipe :class))
              rows)))
    (nelix-registry-index
     :version (or version 1)
     :packages (sort rows
                     (lambda (a b)
                       (string< (plist-get a :path)
                                (plist-get b :path)))))))

;;;###autoload
(defun nelix-registry-write-index (root output &optional version)
  "Write a static registry index for ROOT to OUTPUT and return a report plist."
  (let* ((index (nelix-registry-build-index root version))
         (output* (expand-file-name output)))
    (nelix-compat-make-directory (file-name-directory output*) t)
    (nelix-compat-write-file
     output*
     (concat ";;; index.el --- generated Nelix registry index -*- lexical-binding: t; -*-\n\n"
             "(require 'nelix-registry)\n\n"
             "(nelix-registry-index\n"
             " :version " (number-to-string (plist-get index :version)) "\n"
             " :packages '"
             (prin1-to-string (plist-get index :packages))
             ")\n"))
    (list :status 'ok
          :operation 'registry-index
          :root (expand-file-name root)
          :output output*
          :version (plist-get index :version)
          :count (length (plist-get index :packages))
          :index index)))

;;;###autoload
(defun nelix-registry-update (&optional roots)
  "Load local registry ROOTS and return an update report.

When ROOTS is nil, synchronize `nelix-registry-remotes' first and
then load the default root, remote caches, and
`nelix-registry-roots'."
  (clrhash (nelix-registry--ensure-table))
  (let ((loaded 0)
        (remote-reports nil)
        (roots* roots))
    (unless roots*
      (dolist (remote nelix-registry-remotes)
        (push (nelix-registry-sync-remote remote) remote-reports))
      (setq remote-reports (nreverse remote-reports))
      (setq roots* (nelix-registry--default-roots remote-reports)))
    (dolist (root roots*)
      (when (and (fboundp 'file-directory-p)
                 (file-directory-p (expand-file-name root)))
        (setq loaded (+ loaded (nelix-registry-load-root root)))))
    (list :status 'ok
          :loaded loaded
          :roots roots*
          :remote remote-reports)))

;;;###autoload
(defun nelix-registry-get (name)
  "Return package recipe for NAME, or nil."
  (gethash (nelix-registry--required-string "nelix-registry-get"
                                            (list :name name)
                                            :name)
           (nelix-registry--ensure-table)))

;;;###autoload
(defun nelix-registry-list (&optional system)
  "Return all registry recipes, optionally restricted to SYSTEM."
  (let (rows)
    (maphash
     (lambda (_name recipe)
       (when (or (null system)
                 (nelix-registry--recipe-system-supported-p recipe system))
         (push recipe rows)))
     (nelix-registry--ensure-table))
    (sort rows (lambda (a b)
                 (string< (plist-get a :name)
                          (plist-get b :name))))))

;;;###autoload
(defun nelix-registry-search (query &optional system)
  "Return registry recipes matching QUERY and optional SYSTEM."
  (let ((needle (downcase (nelix-registry--required-string
                           "nelix-registry-search"
                           (list :query query)
                           :query)))
        rows)
    (maphash
     (lambda (_name recipe)
       (let ((haystack
              (downcase
               (mapconcat #'identity
                          (delq nil
                                (list (plist-get recipe :name)
                                      (plist-get recipe :version)
                                      (symbol-name (plist-get recipe :class))
                                      (plist-get recipe :description)))
                          " "))))
         (when (and (string-match-p (regexp-quote needle) haystack)
                    (or (null system)
                        (nelix-registry--recipe-system-supported-p recipe system)))
           (push recipe rows))))
     (nelix-registry--ensure-table))
    (sort rows (lambda (a b)
                 (string< (plist-get a :name)
                          (plist-get b :name))))))

;;;###autoload
(defun nelix-registry-count ()
  "Return number of in-memory registry recipes."
  (hash-table-count (nelix-registry--ensure-table)))

(provide 'nelix-registry)
;;; nelix-registry.el ends here
