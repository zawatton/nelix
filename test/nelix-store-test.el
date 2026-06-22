;;; nelix-store-test.el --- ERT tests for native Nelix store -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 22 native backend/store/registry coverage.  These tests avoid Nix and
;; network access.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'nelix)

(defmacro nelix-store-test--with-temp-roots (&rest body)
  "Run BODY with isolated native store/profile/registry roots."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "nelix-store-test-" t))
          (nelix-store-root (expand-file-name "store" tmp))
          (nelix-profile-root (expand-file-name "profiles" tmp))
          (nelix-substitute-root (expand-file-name "substitutes" tmp))
          (nelix-registry-root (expand-file-name "registry" tmp))
          (nelix-registry-roots nil)
          (nelix-registry-remotes nil)
          (nelix-registry-include-packaged-root nil)
          (nelix-registry--packages (make-hash-table :test 'equal)))
     (unwind-protect
         (progn ,@body)
       (delete-directory tmp t))))

(defun nelix-store-test--make-tar-fixture (dir name)
  "Create a small tar fixture under DIR for package NAME."
  (unless (executable-find "tar")
    (ert-skip "tar binary not available"))
  (let* ((root (expand-file-name "payload" dir))
         (bin-dir (expand-file-name "bin" root))
         (exe (expand-file-name name bin-dir))
         (archive (expand-file-name (concat name ".tar") dir)))
    (make-directory bin-dir t)
    (with-temp-file exe
      (insert "#!/bin/sh\n")
      (insert "echo fixture\n"))
    (set-file-modes exe #o755)
    (let ((exit (call-process "tar" nil nil nil
                              "-cf" archive
                              "-C" root
                              ".")))
      (unless (eq exit 0)
        (ert-fail "tar fixture creation failed")))
    archive))

(defun nelix-store-test--make-zip-fixture (dir name)
  "Create a small top-directory zip fixture under DIR for package NAME."
  (unless (or (executable-find "zip")
              (executable-find "jar"))
    (ert-skip "zip or jar binary not available"))
  (let* ((top (format "%s-1.0.0" name))
         (root (expand-file-name "zip-payload" dir))
         (payload-root (expand-file-name top root))
         (bin-dir (expand-file-name "bin" payload-root))
         (exe (expand-file-name name bin-dir))
         (archive (expand-file-name (concat name ".zip") dir)))
    (make-directory bin-dir t)
    (with-temp-file exe
      (insert "#!/bin/sh\n")
      (insert "echo zip fixture\n"))
    (set-file-modes exe #o755)
    (let ((default-directory root))
      (unless (eq 0 (if (executable-find "zip")
                        (call-process "zip" nil nil nil "-qr" archive top)
                      (call-process "jar" nil nil nil "cMf" archive
                                    "-C" root top)))
        (ert-fail "zip fixture creation failed")))
    archive))

(defun nelix-store-test--run-git (directory &rest args)
  "Run git ARGS in DIRECTORY or skip when git is unavailable."
  (unless (executable-find "git")
    (ert-skip "git binary not available"))
  (let ((default-directory directory))
    (unless (eq 0 (apply #'call-process "git" nil nil nil args))
      (ert-skip (format "git command failed: %S" args)))))

(defun nelix-store-test--git-output (directory &rest args)
  "Run git ARGS in DIRECTORY and return stdout."
  (unless (executable-find "git")
    (ert-skip "git binary not available"))
  (with-temp-buffer
    (let ((default-directory directory))
      (unless (eq 0 (apply #'call-process "git" nil (current-buffer) nil args))
        (ert-skip (format "git command failed: %S" args))))
    (string-trim (buffer-string))))

(defun nelix-store-test--make-git-fixture (dir name)
  "Create a local git repository fixture under DIR for package NAME."
  (let* ((repo (expand-file-name (concat name "-repo") dir))
         (bin-dir (expand-file-name "bin" repo))
         (exe (expand-file-name name bin-dir))
         (archive (expand-file-name (concat name "-git.tar") dir)))
    (make-directory bin-dir t)
    (with-temp-file exe
      (insert "#!/bin/sh\n")
      (insert "echo git fixture\n"))
    (set-file-modes exe #o755)
    (nelix-store-test--run-git repo "init" "--quiet")
    (nelix-store-test--run-git repo "config" "user.email" "nelix@example.invalid")
    (nelix-store-test--run-git repo "config" "user.name" "Nelix Test")
    (nelix-store-test--run-git repo "add" ".")
    (nelix-store-test--run-git repo "commit" "--quiet" "-m" "initial")
    (let ((rev (nelix-store-test--git-output repo "rev-parse" "HEAD")))
      (nelix-store-test--run-git repo
                                  "archive" "--format=tar"
                                  "--output" archive
                                  "HEAD")
      (list :repo repo
            :rev rev
            :archive archive))))

(defun nelix-store-test--make-copy-source-fixture (dir name)
  "Create a local source tree fixture under DIR for copy builder tests."
  (let* ((root (expand-file-name (concat name "-source") dir))
         (bin-dir (expand-file-name "bin" root))
         (share-dir (expand-file-name "share" root))
         (exe (expand-file-name name bin-dir))
         (doc (expand-file-name "README.txt" share-dir))
         (ignored (expand-file-name "ignored.txt" root)))
    (make-directory bin-dir t)
    (make-directory share-dir t)
    (with-temp-file exe
      (insert "#!/bin/sh\n")
      (insert "echo copy fixture\n"))
    (with-temp-file doc
      (insert "copy fixture doc\n"))
    (with-temp-file ignored
      (insert "not installed by explicit file list\n"))
    (list :root root
          :bin (format "bin/%s" name)
          :doc "share/README.txt"
          :ignored "ignored.txt")))

(defun nelix-store-test--read-binary-file (file)
  "Return FILE contents preserving binary bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun nelix-store-test--openssl-sign-rsa-sha256 (dir message)
  "Return plist with RSA-SHA256 OpenSSL signature fixture for MESSAGE."
  (unless (executable-find "openssl")
    (ert-skip "openssl binary not available"))
  (let* ((private-key (expand-file-name "private.pem" dir))
         (public-key (expand-file-name "public.pem" dir))
         (message-file (expand-file-name "message.txt" dir))
         (signature-file (expand-file-name "signature.bin" dir)))
    (with-temp-file message-file
      (set-buffer-multibyte nil)
      (insert message))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "genpkey" "-algorithm" "RSA"
                                "-pkeyopt" "rsa_keygen_bits:2048"
                                "-out" private-key))
      (ert-skip "openssl RSA key generation failed"))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "rsa" "-in" private-key
                                "-pubout" "-out" public-key))
      (ert-skip "openssl RSA public key export failed"))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "dgst" "-sha256"
                                "-sign" private-key
                                "-out" signature-file
                                message-file))
      (ert-skip "openssl RSA signature generation failed"))
    (list :public-key-file public-key
          :signature
          (base64-encode-string
          (nelix-store-test--read-binary-file signature-file)
           t))))

(defun nelix-store-test--openssl-sign-ed25519 (dir message)
  "Return plist with Ed25519 OpenSSL signature fixture for MESSAGE."
  (unless (executable-find "openssl")
    (ert-skip "openssl binary not available"))
  (let* ((private-key (expand-file-name "ed25519-private.pem" dir))
         (public-key-der (expand-file-name "ed25519-public.der" dir))
         (message-file (expand-file-name "ed25519-message.txt" dir))
         (signature-file (expand-file-name "ed25519-signature.bin" dir)))
    (with-temp-file message-file
      (set-buffer-multibyte nil)
      (insert message))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "genpkey" "-algorithm" "Ed25519"
                                "-out" private-key))
      (ert-skip "openssl Ed25519 key generation failed"))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "pkey" "-in" private-key
                                "-pubout" "-outform" "DER"
                                "-out" public-key-der))
      (ert-skip "openssl Ed25519 public key export failed"))
    (unless (eq 0 (call-process "openssl" nil nil nil
                                "pkeyutl" "-sign" "-rawin"
                                "-inkey" private-key
                                "-in" message-file
                                "-out" signature-file))
      (ert-skip "openssl Ed25519 signature generation failed"))
    (let* ((der (nelix-store-test--read-binary-file public-key-der))
           (raw-public-key (substring der (- (length der) 32))))
      (list :public-key
            (base64-encode-string raw-public-key t)
            :signature
            (base64-encode-string
             (nelix-store-test--read-binary-file signature-file)
             t)))))

(defun nelix-store-test--fixture-recipe (name archive)
  "Return a native unpack recipe for NAME using ARCHIVE."
  (list :name name
        :version "1.0.0"
        :class 'system-tool
        :systems
        (list
         (list 'x86_64-linux
               :source (list :type 'url
                             :url archive
                             :sha256 (nelix-fetch-sha256-file archive)
                             :archive-format 'tar)
               :install (list :type 'unpack
                              :bin (list (format "bin/%s" name)))))))

(defun nelix-store-test--fixture-recipe-version (name version)
  "Return a native unpack recipe for NAME at VERSION without fetching."
  (list :name name
        :version version
        :class 'system-tool
        :systems
        (list
         (list 'x86_64-linux
               :source (list :type 'url
                             :url (format "file:///tmp/%s-%s.tar" name version)
                             :sha256 (format "sha256-%s-%s" name version)
                             :archive-format 'tar)
               :install (list :type 'unpack
                              :bin (list (format "bin/%s" name)))))))

(defun nelix-store-test--make-elisp-tar-fixture (dir feature)
  "Create a small Emacs Lisp tar fixture under DIR providing FEATURE."
  (unless (executable-find "tar")
    (ert-skip "tar binary not available"))
  (let* ((root (expand-file-name "elisp-payload" dir))
         (lisp-dir (expand-file-name "lisp" root))
         (file (expand-file-name (format "%s.el" feature) lisp-dir))
         (archive (expand-file-name (format "%s.tar" feature) dir)))
    (make-directory lisp-dir t)
    (with-temp-file file
      (insert ";;; fixture-mode.el --- fixture -*- lexical-binding: t; -*-\n")
      (insert "(defun fixture-mode-version () \"1.0.0\")\n")
      (insert (format "(provide '%s)\n" feature))
      (insert ";;; fixture-mode.el ends here\n"))
    (let ((exit (call-process "tar" nil nil nil
                              "-cf" archive
                              "-C" root
                              ".")))
      (unless (eq exit 0)
        (ert-fail "tar elisp fixture creation failed")))
    archive))

(defun nelix-store-test--elisp-fixture-recipe (name archive feature)
  "Return a native Emacs Lisp recipe for NAME using ARCHIVE and FEATURE."
  (list :name name
        :version "1.0.0"
        :class 'emacs-lisp
        :systems
        (list
         (list 'x86_64-linux
               :source (list :type 'url
                             :url archive
                             :sha256 (nelix-fetch-sha256-file archive)
                             :archive-format 'tar)
               :install (list :type 'emacs-lisp
                              :load-paths '("lisp")
                              :features (list feature))))))

(ert-deftest nelix-store-test-current-system-linux ()
  "nelix-current-system maps GNU/Linux config to a stable system id."
  (let ((system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu"))
    (should (eq 'x86_64-linux (nelix-current-system)))))

(ert-deftest nelix-store-test-backend-policy-prefers-native-without-nix ()
  "Backend selection can choose nelix-native without requiring Nix."
  (cl-letf (((symbol-function 'nelix-compat-executable-find)
             (lambda (_program) nil)))
    (let ((selection (nelix-backend-select
                      "ripgrep" 'x86_64-linux '(nelix-native nix))))
      (should (eq 'nelix-native (plist-get selection :backend)))
      (should (plist-get selection :available)))))

(ert-deftest nelix-store-test-store-entry-roundtrip ()
  "Store entry metadata is written under the native store and read back."
  (nelix-store-test--with-temp-roots
    (let* ((entry (list :name "ripgrep"
                       :version "14.1.1"
                       :system 'x86_64-linux
                       :hash "sha256-fixture-ripgrep"
                       :runtime-paths '("bin")))
           (path (nelix-store-write-entry entry))
           (read-entry (nelix-store-read-entry path)))
      (should (string-match-p "sha256-fixture-ripgrep-ripgrep-14.1.1\\'"
                              path))
      (should (equal "ripgrep" (plist-get read-entry :name)))
      (should (eq 'x86_64-linux (plist-get read-entry :system)))
      (should (equal '("bin") (plist-get read-entry :runtime-paths))))))

(ert-deftest nelix-store-test-profile-generation-and-rollback ()
  "Native profiles record generations and rollback by metadata only."
  (nelix-store-test--with-temp-roots
    (let* ((entry-a (list :name "ripgrep"
                         :store-path "/tmp/store/a"
                         :runtime-paths '("bin")))
           (entry-b (list :name "fd"
                         :store-path "/tmp/store/b"
                         :runtime-paths '("bin")))
           (gen1 (nelix-profile-create-generation
                  "default" 'x86_64-linux (list entry-a)))
           (gen2 (nelix-profile-create-generation
                  "default" 'x86_64-linux (list entry-a entry-b))))
      (should (= 1 (plist-get gen1 :generation)))
      (should (= 2 (plist-get gen2 :generation)))
      (should (= 2 (plist-get (nelix-profile-read "default") :generation)))
      (should (= 1 (plist-get (nelix-profile-rollback "default") :generation)))
      (should (= 1 (length (plist-get (nelix-profile-read "default")
                                      :entries)))))))

(ert-deftest nelix-store-test-registry-load-search-get-fixture ()
  "Local registry fixture exposes ripgrep and magit recipes."
  (nelix-store-test--with-temp-roots
    (let* ((fixture (expand-file-name
                     "test/fixtures/nelix-registry"
                     default-directory))
           (report (nelix-registry-update (list fixture))))
      (should (= 2 (plist-get report :loaded)))
      (should (equal "ripgrep"
                     (plist-get (nelix-registry-get "ripgrep") :name)))
      (should (equal '("magit" "ripgrep")
                     (mapcar (lambda (row) (plist-get row :name))
                             (nelix-registry-list 'x86_64-linux))))
      (should (equal '("magit")
                     (mapcar (lambda (row) (plist-get row :name))
                             (nelix-registry-search "git porcelain"
                                                    'x86_64-linux)))))))

(ert-deftest nelix-store-test-registry-recipe-loader-is-data-only ()
  "Registry recipes are read as data and unsupported forms are not executed."
  (nelix-store-test--with-temp-roots
    (let* ((registry (make-temp-file "nelix-registry-data-only-" t))
           (packages (expand-file-name "packages" registry))
           (marker (expand-file-name "executed" registry))
           (recipe (expand-file-name "bad.el" packages)))
      (unwind-protect
          (progn
            (make-directory packages t)
            (with-temp-file recipe
              (insert "(require 'nelix-registry)\n")
              (prin1 `(write-region "bad" nil ,marker) (current-buffer))
              (insert "\n")
              (insert "(nelix-package\n")
              (insert " :name \"bad\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux :source (:type local :path \"/tmp/bad\") :install (:type copy :files nil))))\n"))
            (should-error (nelix-registry-update (list registry))
                          :type 'nelix-error)
            (should-not (file-exists-p marker)))
        (when (file-directory-p registry)
          (delete-directory registry t))))))

(ert-deftest nelix-store-test-registry-recipe-loader-rejects-unquoted-lists ()
  "Registry recipe plist values must be literal atoms or quoted data."
  (nelix-store-test--with-temp-roots
    (let* ((registry (make-temp-file "nelix-registry-unquoted-" t))
           (packages (expand-file-name "packages" registry))
           (recipe (expand-file-name "bad.el" packages)))
      (unwind-protect
          (progn
            (make-directory packages t)
            (with-temp-file recipe
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"bad\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems (list (list 'x86_64-linux)))\n"))
            (should-error (nelix-registry-update (list registry))
                          :type 'nelix-error))
        (when (file-directory-p registry)
          (delete-directory registry t))))))

(ert-deftest nelix-store-test-registry-sync-remote-static-index ()
  "Static remote registry indexes are hash-verified, cached, and loaded."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-registry-" t))
           (package-dir (expand-file-name "packages" remote-root))
           (recipe-file (expand-file-name "fixture-remote.el" package-dir))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (make-directory package-dir t)
            (with-temp-file recipe-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"fixture-remote\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux\n")
              (insert "             :source (:type url :url \"file:///tmp/fixture-remote.tar\" :sha256 \"sha256-fixture\")\n")
              (insert "             :install (:type unpack :bin (\"bin/fixture-remote\")))))\n"))
            (let ((recipe-sha (nelix-fetch-sha256-file recipe-file)))
              (with-temp-file index-file
                (insert "(require 'nelix-registry)\n")
                (insert "(nelix-registry-index\n")
                (insert " :version 1\n")
                (insert " :packages '")
                (prin1
                 `((:path "packages/fixture-remote.el"
                    :sha256 ,recipe-sha))
                 (current-buffer))
                (insert ")\n")
                (insert "\n")))
            (let* ((index-sha (nelix-fetch-sha256-file index-file))
                   (nelix-registry-remotes
                    (list (list :name "fixture"
                                :url index-file
                                :sha256 index-sha)))
                   (report (nelix-registry-update))
                   (remote (car (plist-get report :remote)))
                   (cached-recipe
                    (expand-file-name
                     "remotes/fixture/packages/fixture-remote.el"
                     nelix-registry-root)))
              (should (equal "fixture" (plist-get remote :name)))
              (should (= 1 (plist-get remote :count)))
              (should (= 1 (plist-get report :loaded)))
              (should (file-exists-p cached-recipe))
              (should (equal "fixture-remote"
                             (plist-get
                              (nelix-registry-get "fixture-remote")
                              :name)))))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-write-index-from-local-root ()
  "Local registry roots can generate a static remote index."
  (nelix-store-test--with-temp-roots
    (let* ((registry (make-temp-file "nelix-registry-index-" t))
           (package-dir (expand-file-name "packages" registry))
           (recipe-file (expand-file-name "fixture-index.el" package-dir))
           (index-file (expand-file-name "index.el" registry)))
      (unwind-protect
          (progn
            (make-directory package-dir t)
            (with-temp-file recipe-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"fixture-index\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux\n")
              (insert "             :install (:type script-shim\n")
              (insert "                       :command \"fixture-index\"\n")
              (insert "                       :target \"/usr/bin/fixture-index\"))))\n"))
            (let* ((report (nelix-registry-write-index registry index-file))
                   (index (plist-get report :index))
                   (row (car (plist-get index :packages)))
                   (nelix-registry-remotes
                    (list (list :name "generated"
                                :url index-file
                                :sha256 (nelix-fetch-sha256-file
                                         index-file))))
                   (sync (nelix-registry-update)))
              (should (eq 'ok (plist-get report :status)))
              (should (= 1 (plist-get report :count)))
              (should (equal "packages/fixture-index.el"
                             (plist-get row :path)))
              (should (equal "fixture-index" (plist-get row :name)))
              (should (equal (nelix-fetch-sha256-file recipe-file)
                             (plist-get row :sha256)))
              (should (= 1 (plist-get sync :loaded)))
              (should (equal "fixture-index"
                             (plist-get
                              (nelix-registry-get "fixture-index")
                              :name)))))
        (when (file-directory-p registry)
          (delete-directory registry t))))))

(ert-deftest nelix-store-test-registry-sync-remote-signed-recipe ()
  "Remote package recipe rows can require trusted signatures."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-recipe-signed-" t))
           (package-dir (expand-file-name "packages" remote-root))
           (recipe-file (expand-file-name "fixture-signed.el" package-dir))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (make-directory package-dir t)
            (with-temp-file recipe-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"fixture-signed\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux :source (:type local :path \"/tmp/fixture-signed\") :install (:type copy :files nil))))\n"))
            (let* ((recipe-sha (nelix-fetch-sha256-file recipe-file))
                   (recipe (apply #'nelix-package
                                  (nelix-registry--read-call
                                   recipe-file
                                   'nelix-package)))
                   (row-base
                    (list :path "packages/fixture-signed.el"
                          :sha256 recipe-sha
                          :signature-algorithm 'nelix-sha256-digest))
                   (remote-base
                    (list :name "fixture"
                          :url index-file
                          :sha256 "sha256-placeholder"))
                   (digest
                    (nelix-fetch-sha256-string
                     (nelix-registry-recipe-signature-message
                      remote-base
                      row-base
                      recipe
                      recipe-sha)))
                   (row
                    (append row-base
                            (list :require-signature t
                                  :sig
                                  (list :key "nelix.recipe-1"
                                        :algorithm
                                        'nelix-sha256-digest
                                        :value digest)
                                  :trusted-signers '("nelix.recipe-1")
                                  :public-keys
                                  (list (list :key "nelix.recipe-1"
                                              :algorithm
                                              'nelix-sha256-digest))))))
              (with-temp-file index-file
                (insert "(require 'nelix-registry)\n")
                (insert "(nelix-registry-index :version 1 :packages '")
                (prin1 (list row) (current-buffer))
                (insert ")\n")))
            (let* ((index-sha (nelix-fetch-sha256-file index-file))
                   (nelix-registry-remotes
                    (list (list :name "fixture"
                                :url index-file
                                :sha256 index-sha)))
                   (report (nelix-registry-update))
                   (remote (car (plist-get report :remote)))
                   (package-signature
                    (car (plist-get remote :package-signatures))))
              (should (= 1 (plist-get remote :count)))
              (should (plist-get package-signature :present))
              (should (plist-get package-signature :verified))
              (should (plist-get
                       (plist-get package-signature :crypto)
                       :verified))
              (should (equal "fixture-signed"
                             (plist-get
                              (nelix-registry-get "fixture-signed")
                              :name)))))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-requires-recipe-signature ()
  "Remote package recipe rows reject missing signatures when required."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-recipe-required-" t))
           (package-dir (expand-file-name "packages" remote-root))
           (recipe-file (expand-file-name "fixture-required.el" package-dir))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (make-directory package-dir t)
            (with-temp-file recipe-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"fixture-required\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux :source (:type local :path \"/tmp/fixture-required\") :install (:type copy :files nil))))\n"))
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages '")
              (prin1
               (list
                (list :path "packages/fixture-required.el"
                      :sha256 (nelix-fetch-sha256-file recipe-file)
                      :require-signature t))
               (current-buffer))
              (insert ")\n"))
            (let ((nelix-registry-remotes
                   (list (list :name "fixture"
                               :url index-file
                               :sha256
                               (nelix-fetch-sha256-file index-file)))))
              (should-error (nelix-registry-update)
                            :type 'nelix-error)))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-rejects-bad-recipe-signature ()
  "Remote package recipe rows reject invalid trusted signatures."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-recipe-badsig-" t))
           (package-dir (expand-file-name "packages" remote-root))
           (recipe-file (expand-file-name "fixture-badsig.el" package-dir))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (make-directory package-dir t)
            (with-temp-file recipe-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-package\n")
              (insert " :name \"fixture-badsig\"\n")
              (insert " :version \"1.0.0\"\n")
              (insert " :class 'system-tool\n")
              (insert " :systems '((x86_64-linux :source (:type local :path \"/tmp/fixture-badsig\") :install (:type copy :files nil))))\n"))
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages '")
              (prin1
               (list
                (list :path "packages/fixture-badsig.el"
                      :sha256 (nelix-fetch-sha256-file recipe-file)
                      :signature-algorithm 'nelix-sha256-digest
                      :require-signature t
                      :sig (list
                            :key "nelix.recipe-1"
                            :algorithm 'nelix-sha256-digest
                            :value
                            "sha256-0000000000000000000000000000000000000000000000000000000000000000")
                      :trusted-signers '("nelix.recipe-1")
                      :public-keys
                      (list (list :key "nelix.recipe-1"
                                  :algorithm
                                  'nelix-sha256-digest))))
               (current-buffer))
              (insert ")\n"))
            (let ((nelix-registry-remotes
                   (list (list :name "fixture"
                               :url index-file
                               :sha256
                               (nelix-fetch-sha256-file index-file)))))
              (should-error (nelix-registry-update)
                            :type 'nelix-error)))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-rejects-bad-hash ()
  "Static remote registry synchronization rejects hash mismatches."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-registry-bad-" t))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages nil)\n"))
            (let ((nelix-registry-remotes
                   (list (list :name "fixture"
                               :url index-file
                               :sha256
                               "sha256-0000000000000000000000000000000000000000000000000000000000000000"))))
              (should-error (nelix-registry-update)
                            :type 'nelix-error)))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-signed-index ()
  "Static remote registry indexes can require trusted signatures."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-registry-signed-" t))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages nil)\n"))
            (let* ((index-sha (nelix-fetch-sha256-file index-file))
                   (index (nelix-registry-index :version 1 :packages nil))
                   (remote-base
                    (list :name "signed"
                          :url index-file
                          :sha256 index-sha
                          :signature-algorithm 'nelix-sha256-digest))
                   (digest
                    (nelix-fetch-sha256-string
                     (nelix-registry-index-signature-message
                      remote-base
                      index
                      index-sha)))
                   (nelix-registry-remotes
                    (list
                     (append
                      remote-base
                      (list :require-signature t
                            :sig (list :key "nelix.registry-1"
                                       :algorithm 'nelix-sha256-digest
                                       :value digest)
                            :trusted-signers '("nelix.registry-1")
                            :public-keys
                            (list (list :key "nelix.registry-1"
                                        :algorithm
                                        'nelix-sha256-digest))))))
                   (report (nelix-registry-update))
                   (remote (car (plist-get report :remote)))
                   (signature (plist-get remote :signature)))
              (should (= 0 (plist-get remote :count)))
              (should (plist-get signature :present))
              (should (plist-get signature :verified))
              (should (plist-get
                       (plist-get signature :crypto)
                       :verified))))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-requires-signature ()
  "Remote registry signature policy rejects unsigned required indexes."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-registry-required-" t))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages nil)\n"))
            (let ((nelix-registry-remotes
                   (list (list :name "unsigned"
                               :url index-file
                               :sha256 (nelix-fetch-sha256-file index-file)
                               :require-signature t))))
              (should-error (nelix-registry-update)
                            :type 'nelix-error)))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-registry-sync-remote-rejects-bad-signature ()
  "Remote registry signature policy rejects invalid signatures."
  (nelix-store-test--with-temp-roots
    (let* ((remote-root (make-temp-file "nelix-remote-registry-badsig-" t))
           (index-file (expand-file-name "index.el" remote-root)))
      (unwind-protect
          (progn
            (with-temp-file index-file
              (insert "(require 'nelix-registry)\n")
              (insert "(nelix-registry-index :version 1 :packages nil)\n"))
            (let* ((index-sha (nelix-fetch-sha256-file index-file))
                   (nelix-registry-remotes
                    (list
                     (list :name "signed"
                           :url index-file
                           :sha256 index-sha
                           :signature-algorithm 'nelix-sha256-digest
                           :require-signature t
                           :sig (list
                                 :key "nelix.registry-1"
                                 :algorithm 'nelix-sha256-digest
                                 :value
                                 "sha256-0000000000000000000000000000000000000000000000000000000000000000")
                           :trusted-signers '("nelix.registry-1")
                           :public-keys
                           (list (list :key "nelix.registry-1"
                                       :algorithm
                                       'nelix-sha256-digest))))))
              (should-error (nelix-registry-update)
                            :type 'nelix-error)))
        (when (file-directory-p remote-root)
          (delete-directory remote-root t))))))

(ert-deftest nelix-store-test-native-audit-does-not-require-nix ()
  "nelix-native-audit returns an OK report even when Nix is unavailable."
  (nelix-store-test--with-temp-roots
    (cl-letf (((symbol-function 'nelix-compat-executable-find)
               (lambda (_program) nil)))
      (let ((audit (nelix-native-audit)))
        (should (plist-get audit :ok))
        (should (eq 'nelix-native (plist-get audit :backend)))
        (should (eq nil (plist-get audit :nix-required)))
        (should (plist-get (plist-get audit :store) :ok))))))

(ert-deftest nelix-store-test-native-audit-reports-unsupported-target-system ()
  "nelix-native-audit reports requested recipes unsupported on this system."
  (nelix-store-test--with-temp-roots
    (nelix-registry-add
     '(:name "darwin-only"
       :version "1.0.0"
       :class tool
       :systems ((x86_64-darwin :source nil))))
    (cl-letf (((symbol-function 'nelix-current-system)
               (lambda () 'x86_64-linux)))
      (let* ((audit (nelix-native-audit '("darwin-only")))
             (unsupported (plist-get audit :unsupported-systems)))
        (should-not (plist-get audit :ok))
        (should (equal "darwin-only"
                       (plist-get (car unsupported) :name)))
        (should (eq :unsupported-system
                    (plist-get (car unsupported) :reason)))
        (should (equal '(x86_64-darwin)
                       (plist-get (car unsupported) :supported-systems)))))))

(ert-deftest nelix-store-test-fetch-sha256-file-known-content ()
  "nelix-fetch-sha256-file returns a stable sha256-prefixed digest."
  (let ((file (make-temp-file "nelix-fetch-sha-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "hello\n"))
          (should (equal (concat "sha256-"
                                 "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
                         (nelix-fetch-sha256-file file)))
          (should (plist-get
                   (nelix-fetch-verify-file
                    file
                    "sha256-5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
                   :ok)))
      (delete-file file))))

(ert-deftest nelix-store-test-fetch-source-local-file-url ()
  "nelix-fetch-source copies file:// sources and verifies their hash."
  (let ((src (make-temp-file "nelix-fetch-src-"))
        (dest (make-temp-file "nelix-fetch-dest-")))
    (unwind-protect
        (progn
          (with-temp-file src
            (insert "payload\n"))
          (delete-file dest)
          (let ((report (nelix-fetch-source
                         (list :type 'url
                               :url (concat "file://" src)
                               :sha256 (nelix-fetch-sha256-file src))
                         dest)))
            (should (plist-get report :ok))
            (should (equal "payload\n"
                           (with-temp-buffer
                             (insert-file-contents dest)
                             (buffer-string))))))
      (when (file-exists-p src) (delete-file src))
      (when (file-exists-p dest) (delete-file dest)))))

(ert-deftest nelix-store-test-fetch-source-elpa-base-url ()
  "nelix-fetch-source resolves ELPA package archives from base URL metadata."
  (let* ((dir (make-temp-file "nelix-fetch-elpa-" t))
         (src (expand-file-name "fixture-mode-1.0.0.tar" dir))
         (dest (make-temp-file "nelix-fetch-elpa-dest-")))
    (unwind-protect
        (progn
          (with-temp-file src
            (insert "elpa payload\n"))
          (delete-file dest)
          (let ((report (nelix-fetch-source
                         (list :type 'elpa
                               :base-url (concat "file://" dir)
                               :archive 'gnu
                               :package "fixture-mode"
                               :version "1.0.0"
                               :sha256 (nelix-fetch-sha256-file src))
                         dest)))
            (should (plist-get report :ok))
            (should (equal (concat "file://" dir "/fixture-mode-1.0.0.tar")
                           (plist-get report :url)))
            (should (equal "elpa payload\n"
                           (with-temp-buffer
                             (insert-file-contents dest)
                             (buffer-string))))))
      (when (file-exists-p dest) (delete-file dest))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest nelix-store-test-fetch-source-github-release-base-url ()
  "nelix-fetch-source can use a GitHub-compatible release asset mirror."
  (let* ((dir (make-temp-file "nelix-fetch-github-release-" t))
         (mirror (expand-file-name "mirror" dir))
         (asset-dir (expand-file-name
                     "example/tool/releases/download/v1.0.0"
                     mirror))
         (asset (expand-file-name "fixture-tool.zip" asset-dir))
         (dest (make-temp-file "nelix-fetch-github-release-dest-")))
    (unwind-protect
        (progn
          (make-directory asset-dir t)
          (with-temp-file asset
            (insert "github release fixture\n"))
          (delete-file dest)
          (let ((report
                 (nelix-fetch-source
                  (list :type 'github-release
                        :base-url (concat "file://" mirror)
                        :repo "example/tool"
                        :tag "v1.0.0"
                        :asset "fixture-tool.zip"
                        :sha256 (nelix-fetch-sha256-file asset))
                  dest)))
            (should (plist-get report :ok))
            (should (equal (concat "file://" mirror
                                   "/example/tool/releases/download/v1.0.0/fixture-tool.zip")
                           (plist-get report :url)))
            (should (equal (nelix-fetch-sha256-file asset)
                           (nelix-fetch-sha256-file dest)))))
      (when (file-exists-p dest) (delete-file dest))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest nelix-store-test-fetch-source-git-rev ()
  "nelix-fetch-source archives an exact Git rev and verifies its hash."
  (let* ((dir (make-temp-file "nelix-fetch-git-" t))
         (fixture (nelix-store-test--make-git-fixture dir "fixture-git"))
         (dest (make-temp-file "nelix-fetch-git-dest-")))
    (unwind-protect
        (progn
          (delete-file dest)
          (let ((report (nelix-fetch-source
                         (list :type 'git
                               :url (plist-get fixture :repo)
                               :rev (plist-get fixture :rev)
                               :sha256
                               (nelix-fetch-sha256-file
                                (plist-get fixture :archive))
                               :archive-format 'tar)
                         dest)))
            (should (plist-get report :ok))
            (should (equal (plist-get fixture :repo)
                           (plist-get report :url)))
            (should (equal (plist-get fixture :rev)
                           (plist-get report :rev)))
            (should (equal (nelix-fetch-sha256-file
                            (plist-get fixture :archive))
                           (nelix-fetch-sha256-file dest)))))
      (when (file-exists-p dest) (delete-file dest))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest nelix-store-test-verify-local-directory-source ()
  "nelix-fetch-verify-local-source verifies deterministic directory hashes."
  (let* ((dir (make-temp-file "nelix-local-source-" t))
         (fixture (nelix-store-test--make-copy-source-fixture
                   dir "fixture-copy"))
         (source (list :type 'local
                       :path (plist-get fixture :root)
                       :sha256
                       (nelix-fetch-sha256-directory
                        (plist-get fixture :root)))))
    (unwind-protect
        (let ((report (nelix-fetch-verify-local-source source)))
          (should (plist-get report :ok))
          (should (equal (expand-file-name (plist-get fixture :root))
                         (plist-get report :path)))
          (should (equal (plist-get source :sha256)
                         (plist-get report :sha256))))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest nelix-store-test-native-unpack-installs-to-store-and-profile ()
  "nelix-native-install-recipe unpacks a hash-verified tar into native store."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-rg"))
           (recipe (nelix-store-test--fixture-recipe "fixture-rg" archive))
           (report (nelix-native-install-recipe recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p (expand-file-name "bin/fixture-rg" store-path)))
      (should (file-exists-p (expand-file-name ".nelix/store-entry.el"
                                               store-path)))
      (should (= 1 (plist-get (plist-get report :profile) :generation)))
      (should (equal '("bin")
                     (plist-get (car (plist-get (plist-get report :profile)
                                                :entries))
                                :runtime-paths)))
      (should (equal (list "bin/fixture-rg")
                     (plist-get (car (plist-get (plist-get report :profile)
                                                :entries))
                                :runtime-bins))))))

(ert-deftest nelix-store-test-native-unpack-installs-zip-with-strip-components ()
  "nelix-native-install-recipe strips top-directory zip payloads."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-zip-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-zip-tool"))
           (recipe (list
                    :name "fixture-zip-tool"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-linux
                           :source
                           (list :type 'url
                                 :url archive
                                 :sha256 (nelix-fetch-sha256-file archive)
                                 :archive-format 'zip)
                           :install
                           (list :type 'unpack
                                 :strip-components 1
                                 :bin '("bin/fixture-zip-tool"))))))
           (report (nelix-native-install-recipe
                    recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name "bin/fixture-zip-tool" store-path)))
      (should-not
       (file-exists-p
        (expand-file-name
         "fixture-zip-tool-1.0.0/bin/fixture-zip-tool"
         store-path)))
      (should (= 1 (plist-get (plist-get report :profile) :generation))))))

(ert-deftest nelix-store-test-native-github-release-mirror-zip-install ()
  "Native recipes can install mirrored GitHub release zip assets."
  (nelix-store-test--with-temp-roots
    (let* ((dir (file-name-directory nelix-store-root))
           (source-archive (nelix-store-test--make-zip-fixture
                            dir "fixture-gh-tool"))
           (mirror (expand-file-name "github-mirror" dir))
           (asset-dir (expand-file-name
                       "example/fixture/releases/download/v1.0.0"
                       mirror))
           (asset (expand-file-name "fixture-gh-tool.zip" asset-dir)))
      (make-directory asset-dir t)
      (copy-file source-archive asset t)
      (let* ((recipe (list
                      :name "fixture-gh-tool"
                      :version "1.0.0"
                      :class 'system-tool
                      :systems
                      (list
                       (list 'x86_64-linux
                             :source
                             (list :type 'github-release
                                   :base-url (concat "file://" mirror)
                                   :repo "example/fixture"
                                   :tag "v1.0.0"
                                   :asset "fixture-gh-tool.zip"
                                   :sha256 (nelix-fetch-sha256-file asset)
                                   :archive-format 'zip)
                             :install
                             (list :type 'unpack
                                   :strip-components 1
                                   :bin '("bin/fixture-gh-tool"))))))
             (report (nelix-native-install-recipe
                      recipe "default" 'x86_64-linux))
             (store-path (plist-get report :store-path)))
        (should (eq 'ok (plist-get report :status)))
        (should (file-exists-p
                 (expand-file-name "bin/fixture-gh-tool" store-path)))
        (should (string-prefix-p (concat "file://" mirror)
                                 (plist-get (plist-get report :fetch)
                                            :url)))
        (should (= 1 (plist-get (plist-get report :profile)
                                :generation)))))))

(ert-deftest nelix-store-test-native-unpack-installs-from-git-source ()
  "nelix-native-install-recipe can install an exact Git source rev."
  (nelix-store-test--with-temp-roots
    (let* ((fixture (nelix-store-test--make-git-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-git-tool"))
           (recipe (list
                    :name "fixture-git-tool"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-linux
                           :source
                           (list :type 'git
                                 :url (plist-get fixture :repo)
                                 :rev (plist-get fixture :rev)
                                 :sha256
                                 (nelix-fetch-sha256-file
                                  (plist-get fixture :archive))
                                 :archive-format 'tar)
                           :install
                           (list :type 'unpack
                                 :bin '("bin/fixture-git-tool"))))))
           (report (nelix-native-install-recipe
                    recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name "bin/fixture-git-tool" store-path)))
      (should (= 1 (plist-get (plist-get report :profile) :generation))))))

(ert-deftest nelix-store-test-native-copy-installs-selected-local-files ()
  "nelix-native-install-recipe copies selected local source files into store."
  (nelix-store-test--with-temp-roots
    (let* ((fixture (nelix-store-test--make-copy-source-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-copy-tool"))
           (root (plist-get fixture :root))
           (recipe (list
                    :name "fixture-copy-tool"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-linux
                           :source
                           (list :type 'local
                                 :path root
                                 :sha256
                                 (nelix-fetch-sha256-directory root))
                           :install
                           (list :type 'copy
                                 :files
                                 (list (cons (plist-get fixture :bin)
                                             (plist-get fixture :bin))
                                       (cons (plist-get fixture :doc)
                                             (plist-get fixture :doc)))
                                 :bin
                                 (list (plist-get fixture :bin)))))))
           (report (nelix-native-install-recipe
                    recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path))
           (profile-entry (car (plist-get (plist-get report :profile)
                                          :entries))))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name (plist-get fixture :bin) store-path)))
      (should (file-exists-p
               (expand-file-name (plist-get fixture :doc) store-path)))
      (should-not (file-exists-p
                   (expand-file-name (plist-get fixture :ignored)
                                     store-path)))
      (should (equal '("bin") (plist-get profile-entry :runtime-paths)))
      (should (equal (list (plist-get fixture :bin))
                     (plist-get profile-entry :runtime-bins)))
      (should (= 1 (plist-get (plist-get report :profile) :generation))))))

(ert-deftest nelix-store-test-native-unpack-failure-leaves-no-partial-store ()
  "Failed native archive extraction does not expose partial store entries."
  (nelix-store-test--with-temp-roots
    (let* ((bad-archive (expand-file-name "bad.tar"
                                          (file-name-directory
                                           nelix-store-root)))
           (recipe nil))
      (with-temp-file bad-archive
        (insert "not a tar archive\n"))
      (setq recipe
            (list :name "fixture-bad-unpack"
                  :version "1.0.0"
                  :class 'system-tool
                  :systems
                  (list
                   (list 'x86_64-linux
                         :source
                         (list :type 'url
                               :url bad-archive
                               :sha256 (nelix-fetch-sha256-file bad-archive)
                               :archive-format 'tar)
                         :install
                         (list :type 'unpack
                               :bin '("bin/fixture-bad-unpack"))))))
      (should-error
       (nelix-native-install-recipe recipe "default" 'x86_64-linux)
       :type 'nelix-error)
      (should-not (file-exists-p (nelix-profile--current-file "default")))
      (should (equal nil (nelix-store-list)))
      (should (equal nil
                     (and (file-directory-p nelix-store-root)
                          (directory-files nelix-store-root nil
                                           "\\`[^.]")))))))

(ert-deftest nelix-store-test-native-copy-failure-leaves-no-partial-store ()
  "Failed native copy installation does not expose partial store entries."
  (nelix-store-test--with-temp-roots
    (let* ((fixture (nelix-store-test--make-copy-source-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-copy-fail"))
           (root (plist-get fixture :root))
           (recipe
            (list :name "fixture-copy-fail"
                  :version "1.0.0"
                  :class 'system-tool
                  :systems
                  (list
                   (list 'x86_64-linux
                         :source
                         (list :type 'local
                               :path root
                               :sha256
                               (nelix-fetch-sha256-directory root))
                         :install
                         (list :type 'copy
                               :files
                               (list (cons "missing-file"
                                           "missing-file"))))))))
      (should-error
       (nelix-native-install-recipe recipe "default" 'x86_64-linux)
       :type 'nelix-error)
      (should-not (file-exists-p (nelix-profile--current-file "default")))
      (should (equal nil (nelix-store-list)))
      (should (equal nil
                     (and (file-directory-p nelix-store-root)
                          (directory-files nelix-store-root nil
                                           "\\`[^.]")))))))

(ert-deftest nelix-store-test-native-script-shim-installs-posix-shim ()
  "nelix-native-install-recipe can generate a POSIX script-shim package."
  (nelix-store-test--with-temp-roots
    (let* ((recipe (list
                    :name "fixture-shim"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-linux
                           :install
                           (list :type 'script-shim
                                 :command "fixture-shim"
                                 :target "/usr/bin/fixture-real")))))
           (report (nelix-native-install-recipe
                    recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path))
           (shim (expand-file-name "bin/fixture-shim" store-path))
           (profile-entry (car (plist-get (plist-get report :profile)
                                          :entries)))
           (entry (nelix-store-read-entry store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p shim))
      (should (string-match-p "#!/bin/sh"
                              (nelix-store-test--read-binary-file shim)))
      (should (string-match-p "/usr/bin/fixture-real"
                              (nelix-store-test--read-binary-file shim)))
      (when (fboundp 'file-executable-p)
        (should (file-executable-p shim)))
      (should (equal '("bin")
                     (plist-get profile-entry :runtime-paths)))
      (should (equal '("bin/fixture-shim")
                     (plist-get profile-entry :runtime-bins)))
      (should (equal 'script-shim
                     (plist-get (plist-get entry :source) :type)))
      (should (= 1 (plist-get (plist-get report :profile) :generation))))))

(ert-deftest nelix-store-test-packaged-registry-root-defaults-and-opt-out ()
  "Default registry updates include packaged recipes unless disabled."
  (let* ((tmp (make-temp-file "nelix-packaged-registry-test-" t))
         (old-xdg-data (getenv "XDG_DATA_HOME"))
         (old-include (getenv "NELIX_REGISTRY_INCLUDE_PACKAGED"))
         (nelix-registry-root nil)
         (nelix-registry-roots nil)
         (nelix-registry-remotes nil)
         (nelix-registry-include-packaged-root t)
         (nelix-registry--packages (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (setenv "XDG_DATA_HOME" (expand-file-name "xdg-data" tmp))
          (setenv "NELIX_REGISTRY_INCLUDE_PACKAGED" nil)
          (let ((report (nelix-registry-update)))
            (should (member (nelix-registry-packaged-root)
                            (plist-get report :roots)))
            (should (>= (plist-get report :loaded) 6))
            (should (nelix-registry-get "curl"))
            (should (nelix-registry-get "fd"))
            (should (nelix-registry-get "git"))
            (should (nelix-registry-get "jq"))
            (should (nelix-registry-get "ripgrep"))
            (should (nelix-registry-get "tree")))
          (setenv "NELIX_REGISTRY_INCLUDE_PACKAGED" "0")
          (let ((report (nelix-registry-update)))
            (should (= 0 (plist-get report :loaded)))
            (should-not (member (nelix-registry-packaged-root)
                                (plist-get report :roots)))
            (should-not (nelix-registry-get "curl"))
            (should-not (nelix-registry-get "fd"))
            (should-not (nelix-registry-get "git"))
            (should-not (nelix-registry-get "jq"))
            (should-not (nelix-registry-get "ripgrep"))
            (should-not (nelix-registry-get "tree"))))
      (setenv "XDG_DATA_HOME" old-xdg-data)
      (setenv "NELIX_REGISTRY_INCLUDE_PACKAGED" old-include)
      (delete-directory tmp t))))

(ert-deftest nelix-store-test-native-script-shim-require-target ()
  "script-shim recipes can require the target command to exist."
  (nelix-store-test--with-temp-roots
    (let* ((bin-dir (expand-file-name "bin" (file-name-directory
                                             nelix-store-root)))
           (tool (expand-file-name "fixture-required-tool" bin-dir))
           (old-path (getenv "PATH"))
           (recipe (list
                    :name "fixture-required-shim"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-linux
                           :install
                           (list :type 'script-shim
                                 :command "fixture-required-shim"
                                 :target "fixture-required-tool"
                                 :require-target t))))))
      (make-directory bin-dir t)
      (unwind-protect
          (progn
            (let ((exec-path nil))
              (setenv "PATH" "")
              (should-error
               (nelix-native-install-recipe recipe "default" 'x86_64-linux)
               :type 'nelix-error))
            (with-temp-file tool
              (insert "#!/bin/sh\n")
              (insert "echo fixture-required-tool\n"))
            (set-file-modes tool #o755)
            (let ((exec-path (cons bin-dir exec-path)))
              (setenv "PATH" (concat bin-dir path-separator (or old-path "")))
              (let* ((report (nelix-native-install-recipe
                              recipe "default" 'x86_64-linux))
                     (store-path (plist-get report :store-path))
                     (shim (expand-file-name
                            "bin/fixture-required-shim" store-path)))
                (should (eq 'ok (plist-get report :status)))
                (should (file-exists-p shim))
                (should (string-match-p "fixture-required-tool"
                                        (nelix-store-test--read-binary-file
                                         shim))))))
        (setenv "PATH" old-path)))))

(ert-deftest nelix-store-test-native-script-shim-installs-windows-cmd ()
  "nelix-native-install-recipe can generate a Windows script-shim package."
  (nelix-store-test--with-temp-roots
    (let* ((recipe (list
                    :name "fixture-win-shim"
                    :version "1.0.0"
                    :class 'system-tool
                    :systems
                    (list
                     (list 'x86_64-windows
                           :install
                           (list :type 'script-shim
                                 :command "fixture-win"
                                 :target "C:/Tools/fixture.exe")))))
           (report (nelix-native-install-recipe
                    recipe "default" 'x86_64-windows))
           (store-path (plist-get report :store-path))
           (shim (expand-file-name "bin/fixture-win.cmd" store-path))
           (profile-entry (car (plist-get (plist-get report :profile)
                                          :entries))))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p shim))
      (should (string-match-p "@echo off"
                              (nelix-store-test--read-binary-file shim)))
      (should (string-match-p "C:/Tools/fixture\\.exe"
                              (nelix-store-test--read-binary-file shim)))
      (should (equal '("bin")
                     (plist-get profile-entry :runtime-paths)))
      (should (equal '("bin/fixture-win.cmd")
                     (plist-get profile-entry :runtime-bins)))
      (should (= 1 (plist-get (plist-get report :profile) :generation))))))

(ert-deftest nelix-store-test-backend-native-install-uses-registry ()
  "nelix-backend-install dispatches nelix-native targets through registry recipes."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-tool"))
           (recipe (nelix-store-test--fixture-recipe "fixture-tool" archive)))
      (nelix-registry-add recipe)
      (let* ((reports (nelix-backend-install 'nelix-native "fixture-tool"))
             (report (car reports)))
        (should (eq 'ok (plist-get report :status)))
        (should (file-exists-p
                 (expand-file-name "bin/fixture-tool"
                                   (plist-get report :store-path))))))))

(ert-deftest nelix-store-test-native-install-preserves-profile-entries ()
  "Subsequent native installs preserve existing profile entries."
  (nelix-store-test--with-temp-roots
    (let ((first (list :name "fixture-first"
                       :version "1.0.0"
                       :class 'system-tool
                       :systems
                       '((x86_64-linux
                          :install (:type script-shim
                                    :command "fixture-first"
                                    :target "/usr/bin/first")))))
          (second (list :name "fixture-second"
                        :version "1.0.0"
                        :class 'system-tool
                        :systems
                        '((x86_64-linux
                           :install (:type script-shim
                                     :command "fixture-second"
                                     :target "/usr/bin/second"))))))
      (nelix-registry-add first)
      (nelix-registry-add second)
      (nelix-native-install "fixture-first" "default" 'x86_64-linux)
      (let* ((report (nelix-native-install
                      "fixture-second" "default" 'x86_64-linux))
             (profile (plist-get report :profile))
             (names (mapcar (lambda (entry) (plist-get entry :name))
                            (plist-get profile :entries))))
        (should (= 2 (plist-get profile :generation)))
        (should (equal '("fixture-first" "fixture-second") names))))))

(ert-deftest nelix-store-test-profile-prune-creates-generation ()
  "Native profile prune removes selected names through a new generation."
  (nelix-store-test--with-temp-roots
    (let* ((entry-a (list :name "fixture-a"
                         :version "1.0.0"
                         :system 'x86_64-linux
                         :hash "sha256-fixture-a"))
           (entry-b (list :name "fixture-b"
                          :version "1.0.0"
                          :system 'x86_64-linux
                          :hash "sha256-fixture-b"))
           (store-a (nelix-store-write-entry entry-a))
           (store-b (nelix-store-write-entry entry-b)))
      (nelix-profile-create-generation
       "default" 'x86_64-linux
       (list (list :name "fixture-a" :store-path store-a)
             (list :name "fixture-b" :store-path store-b)))
      (let* ((report (nelix-profile-prune "default" '("fixture-b")))
             (profile (plist-get report :profile))
             (current (nelix-profile-read "default")))
        (should (plist-get report :changed))
        (should (= 1 (length (plist-get report :removed))))
        (should (= 2 (plist-get profile :generation)))
        (should (= 2 (plist-get current :generation)))
        (should (equal '("fixture-a")
                       (mapcar (lambda (entry)
                                 (plist-get entry :name))
                               (plist-get current :entries))))
        (should (file-exists-p store-a))
        (should (file-exists-p store-b))))))

(ert-deftest nelix-store-test-native-install-installs-registry-dependencies ()
  "Native install installs declared registry dependencies before the target."
  (nelix-store-test--with-temp-roots
    (let ((dependency (list :name "fixture-dep"
                            :version "1.0.0"
                            :class 'system-tool
                            :systems
                            '((x86_64-linux
                               :install (:type script-shim
                                         :command "fixture-dep"
                                         :target "/usr/bin/dep")))))
          (app (list :name "fixture-app"
                     :version "1.0.0"
                     :class 'system-tool
                     :systems
                     '((x86_64-linux
                        :dependencies ("fixture-dep")
                        :install (:type script-shim
                                  :command "fixture-app"
                                  :target "/usr/bin/app"))))))
      (nelix-registry-add dependency)
      (nelix-registry-add app)
      (let* ((report (nelix-native-install
                      "fixture-app" "default" 'x86_64-linux))
             (profile (plist-get report :profile))
             (names (mapcar (lambda (entry) (plist-get entry :name))
                            (plist-get profile :entries))))
        (should (= 1 (length (plist-get report :dependencies))))
        (should (= 2 (plist-get profile :generation)))
        (should (equal '("fixture-dep" "fixture-app") names))
        (should (file-exists-p
                 (expand-file-name
                  "bin/fixture-dep"
                  (plist-get (car (plist-get profile :entries))
                             :store-path))))))))

(ert-deftest nelix-store-test-native-install-rejects-dependency-cycle ()
  "Native install rejects registry dependency cycles."
  (nelix-store-test--with-temp-roots
    (nelix-registry-add
     (list :name "fixture-a"
           :version "1.0.0"
           :class 'system-tool
           :systems
           '((x86_64-linux
              :dependencies ("fixture-b")
              :install (:type script-shim
                        :command "fixture-a"
                        :target "/usr/bin/a")))))
    (nelix-registry-add
     (list :name "fixture-b"
           :version "1.0.0"
           :class 'system-tool
           :systems
           '((x86_64-linux
              :dependencies ("fixture-a")
              :install (:type script-shim
                        :command "fixture-b"
                        :target "/usr/bin/b")))))
    (should-error (nelix-native-install
                   "fixture-a" "default" 'x86_64-linux)
                  :type 'nelix-error)))

(ert-deftest nelix-store-test-native-install-lock-package-replays-source ()
  "nelix-native-install-lock-package installs from lock row source/install data."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-lock-tool"))
           (source (list :type 'url
                         :url (concat "file://" archive)
                         :sha256 (nelix-fetch-sha256-file archive)))
           (install (list :type 'unpack
                          :bin '("bin/fixture-lock-tool")))
           (package (list :name "fixture-lock-tool"
                          :target "fixture-lock-tool"
                          :backend 'nelix-native
                          :system 'x86_64-linux
                          :recipe-version "1.0.0"
                          :recipe-class 'system-tool
                          :recipe-source source
                          :recipe-install install))
           (report (nelix-native-install-lock-package
                    package "default" 'x86_64-linux)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name "bin/fixture-lock-tool"
                                 (plist-get report :store-path))))
      (should (= 1 (plist-get (plist-get report :profile)
                              :generation))))))

(ert-deftest nelix-store-test-native-install-lock-package-replays-script-shim ()
  "nelix-native-install-lock-package replays source-free script-shim rows."
  (nelix-store-test--with-temp-roots
    (let* ((package (list :name "fixture-lock-shim"
                          :target "fixture-lock-shim"
                          :backend 'nelix-native
                          :system 'x86_64-linux
                          :recipe-version "1.0.0"
                          :recipe-class 'system-tool
                          :recipe-install
                          (list :type 'script-shim
                                :command "fixture-lock-shim"
                                :target "/usr/bin/fixture-real")))
           (report (nelix-native-install-lock-package
                    package "default" 'x86_64-linux))
           (store-path (plist-get report :store-path))
           (shim (expand-file-name "bin/fixture-lock-shim" store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p shim))
      (should (string-match-p "/usr/bin/fixture-real"
                              (nelix-store-test--read-binary-file shim)))
      (should (= 1 (plist-get (plist-get report :profile)
                              :generation))))))

(ert-deftest nelix-store-test-native-install-lock-package-replays-dependencies ()
  "Locked native install replays dependencies from lock package rows."
  (nelix-store-test--with-temp-roots
    (let* ((dep (list :name "fixture-lock-dep"
                      :target "fixture-lock-dep"
                      :backend 'nelix-native
                      :system 'x86_64-linux
                      :recipe-version "1.0.0"
                      :recipe-class 'system-tool
                      :recipe-install
                      (list :type 'script-shim
                            :command "fixture-lock-dep"
                            :target "/usr/bin/fixture-lock-dep")))
           (app (list :name "fixture-lock-app"
                      :target "fixture-lock-app"
                      :backend 'nelix-native
                      :system 'x86_64-linux
                      :recipe-version "1.0.0"
                      :recipe-class 'system-tool
                      :recipe-install
                      (list :type 'script-shim
                            :command "fixture-lock-app"
                            :target "/usr/bin/fixture-lock-app")
                      :recipe-dependencies
                      '("fixture-lock-dep")))
           (lock-packages (list app dep))
           (report (nelix-native-install-lock-package
                    app "default" 'x86_64-linux lock-packages))
           (profile (plist-get report :profile))
           (names (mapcar (lambda (entry) (plist-get entry :name))
                          (plist-get profile :entries))))
      (should (= 1 (length (plist-get report :dependencies))))
      (should (= 2 (plist-get profile :generation)))
      (should (equal '("fixture-lock-dep" "fixture-lock-app") names)))))

(ert-deftest nelix-store-test-native-install-lock-package-requires-dependency-row ()
  "Locked native install fails when a dependency row is absent."
  (nelix-store-test--with-temp-roots
    (let ((app (list :name "fixture-lock-app"
                     :target "fixture-lock-app"
                     :backend 'nelix-native
                     :system 'x86_64-linux
                     :recipe-version "1.0.0"
                     :recipe-class 'system-tool
                     :recipe-install
                     (list :type 'script-shim
                           :command "fixture-lock-app"
                           :target "/usr/bin/fixture-lock-app")
                     :recipe-dependencies
                     '("fixture-lock-missing"))))
      (should-error
       (nelix-native-install-lock-package
        app "default" 'x86_64-linux (list app))
       :type 'nelix-error))))

(ert-deftest nelix-store-test-native-upgrade-plan-reports-registry-candidate ()
  "Native upgrade plan compares current profile entries to registry recipes."
  (nelix-store-test--with-temp-roots
    (let* ((entry (list :name "fixture-tool"
                        :version "1.0.0"
                        :system 'x86_64-linux
                        :hash "sha256-fixture-tool-1"))
           (store-path (nelix-store-write-entry entry)))
      (nelix-profile-create-generation
       "default" 'x86_64-linux
       (list (list :name "fixture-tool"
                   :version "1.0.0"
                   :store-path store-path
                   :backend 'nelix-native)))
      (nelix-registry-add
       (nelix-store-test--fixture-recipe-version "fixture-tool" "2.0.0"))
      (let* ((plan (nelix-backend-upgrade-plan 'nelix-native))
             (row (car (plist-get plan :upgrade))))
        (should (eq 'upgrade (plist-get plan :operation)))
        (should (= 1 (plist-get plan :count)))
        (should (equal "fixture-tool" (plist-get row :name)))
        (should (equal "1.0.0" (plist-get row :from)))
        (should (equal "2.0.0" (plist-get row :to)))
        (should-not (plist-get row :blocked))))))

(ert-deftest nelix-store-test-native-upgrade-plan-honors-pins ()
  "Pinned native entries are reported but excluded from upgrade candidates."
  (nelix-store-test--with-temp-roots
    (let* ((entry (list :name "fixture-tool"
                        :version "1.0.0"
                        :system 'x86_64-linux
                        :hash "sha256-fixture-tool-1"))
           (store-path (nelix-store-write-entry entry)))
      (nelix-profile-create-generation
       "default" 'x86_64-linux
       (list (list :name "fixture-tool"
                   :version "1.0.0"
                   :store-path store-path
                   :backend 'nelix-native)))
      (nelix-registry-add
       (nelix-store-test--fixture-recipe-version "fixture-tool" "2.0.0"))
      (cl-letf (((symbol-function 'nelix-list-pins)
                 (lambda () '("fixture-tool"))))
        (let ((plan (nelix-backend-upgrade-plan 'nelix-native)))
          (should (plist-get plan :empty))
          (should (= 0 (plist-get plan :count)))
          (should (equal '("fixture-tool")
                         (mapcar (lambda (row) (plist-get row :name))
                                 (plist-get plan :pinned))))
          (should (eq :pinned
                      (plist-get (car (plist-get plan :pinned))
                                 :blocked))))))))

(ert-deftest nelix-store-test-native-upgrade-plan-direct-missing-target ()
  "Direct native upgrade targets report missing entries read-only."
  (nelix-store-test--with-temp-roots
    (nelix-registry-add
     (nelix-store-test--fixture-recipe-version "fixture-tool" "2.0.0"))
    (let ((plan (nelix-backend-upgrade-plan 'nelix-native "fixture-tool")))
      (should (plist-get plan :empty))
      (should (= 0 (plist-get plan :count)))
      (should (equal '("fixture-tool")
                     (mapcar (lambda (row) (plist-get row :name))
                             (plist-get plan :missing))))
      (should (eq :missing
                  (plist-get (car (plist-get plan :missing))
                             :blocked))))))

(ert-deftest nelix-store-test-native-emacs-lisp-installs-load-path-metadata ()
  "Native Emacs Lisp install records store/profile load-path metadata."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-elisp-tar-fixture
                     (file-name-directory nelix-store-root)
                     'fixture-mode))
           (recipe (nelix-store-test--elisp-fixture-recipe
                    "fixture-mode" archive 'fixture-mode))
           (report (nelix-native-install-recipe recipe "default" 'x86_64-linux))
           (store-path (plist-get report :store-path))
           (store-entry (nelix-store-read-entry store-path))
           (profile-entry (car (plist-get (plist-get report :profile)
                                          :entries))))
      (should (file-exists-p (expand-file-name "lisp/fixture-mode.el"
                                               store-path)))
      (should (equal '("lisp") (plist-get store-entry :emacs-load-paths)))
      (should (equal '(fixture-mode) (plist-get store-entry :features)))
      (should (equal (list (expand-file-name "lisp" store-path))
                     (plist-get profile-entry :emacs-load-paths)))
      (should (equal '(fixture-mode) (plist-get profile-entry :features))))))

(ert-deftest nelix-store-test-native-emacs-lisp-installs-from-elpa-source ()
  "Native Emacs Lisp install can fetch an ELPA source archive."
  (nelix-store-test--with-temp-roots
    (let* ((archive-dir (file-name-directory nelix-store-root))
           (archive (nelix-store-test--make-elisp-tar-fixture
                     archive-dir
                     'fixture-elpa-mode))
           (elpa-archive (expand-file-name "fixture-elpa-mode-1.0.0.tar"
                                           archive-dir))
           (recipe (list
                    :name "fixture-elpa-mode"
                    :version "1.0.0"
                    :class 'emacs-lisp
                    :systems
                    (list
                     (cons 'x86_64-linux
                           (list :source
                                 (list :type 'elpa
                                       :archive 'gnu
                                       :base-url (concat "file://" archive-dir)
                                       :package "fixture-elpa-mode"
                                       :version "1.0.0"
                                       :sha256
                                       (nelix-fetch-sha256-file archive))
                                 :install
                                 (list :type 'emacs-lisp
                                       :load-paths '("lisp")
                                       :features '(fixture-elpa-mode))))))))
      (copy-file archive elpa-archive t)
      (let* ((report (nelix-native-install-recipe
                      recipe "default" 'x86_64-linux))
             (store-path (plist-get report :store-path))
             (profile-entry (car (plist-get (plist-get report :profile)
                                            :entries))))
        (should (file-exists-p
                 (expand-file-name "lisp/fixture-elpa-mode.el" store-path)))
        (should (equal (list (expand-file-name "lisp" store-path))
                       (plist-get profile-entry :emacs-load-paths)))))))

(ert-deftest nelix-store-test-profile-activate-emacs-adds-load-path ()
  "nelix-profile-activate-emacs adds profile load paths to `load-path'."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-elisp-tar-fixture
                     (file-name-directory nelix-store-root)
                     'fixture-mode))
           (recipe (nelix-store-test--elisp-fixture-recipe
                    "fixture-mode" archive 'fixture-mode))
           (report (nelix-native-install-recipe recipe "default" 'x86_64-linux))
           (load-dir (expand-file-name "lisp" (plist-get report :store-path))))
      (let ((load-path nil))
        (should (equal (list load-dir)
                       (nelix-profile-activate-emacs "default")))
        (should (member load-dir load-path))))))

(ert-deftest nelix-store-test-profile-activate-runtime-generates-posix-shims ()
  "Runtime activation generates POSIX shims and a PATH fragment."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-runtime"))
           (recipe (nelix-store-test--fixture-recipe "fixture-runtime"
                                                     archive))
           (_report (nelix-native-install-recipe
                     recipe "default" 'x86_64-linux))
           (activation (nelix-profile-activate-runtime "default"))
           (shim (expand-file-name "fixture-runtime"
                                   (plist-get activation :bin-dir)))
           (profile-link (expand-file-name "bin/fixture-runtime"
                                           (plist-get activation :profile-dir)))
           (path-fragment (plist-get activation :path-fragment)))
      (should (eq 'ok (plist-get activation :status)))
      (should (= 1 (length (plist-get activation :shims))))
      (should (= 1 (length (plist-get activation :links))))
      (should (file-exists-p shim))
      (should (file-exists-p profile-link))
      (should (memq (plist-get (car (plist-get activation :links)) :mode)
                    '(symlink copy)))
      (should (file-exists-p path-fragment))
      (should (string-match-p "#!/bin/sh"
                              (nelix-store-test--read-binary-file shim)))
      (should (string-match-p "fixture-runtime"
                              (nelix-store-test--read-binary-file shim)))
      (should (string-match-p "PATH="
                              (nelix-store-test--read-binary-file
                               path-fragment))))))

(ert-deftest nelix-store-test-profile-activate-runtime-can-copy-profile-tree ()
  "Runtime activation can materialize the profile tree without symlinks."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-runtime-copy"))
           (recipe (nelix-store-test--fixture-recipe "fixture-runtime-copy"
                                                     archive))
           (nelix-profile-activation-link-mode 'copy)
           (_report (nelix-native-install-recipe
                     recipe "default" 'x86_64-linux))
           (activation (nelix-profile-activate-runtime "default"))
           (link-row (car (plist-get activation :links)))
           (profile-link (plist-get link-row :link))
           (target (plist-get link-row :target)))
      (should (eq 'ok (plist-get activation :status)))
      (should (eq 'copy (plist-get link-row :mode)))
      (should (file-exists-p profile-link))
      (when (fboundp 'file-symlink-p)
        (should-not (file-symlink-p profile-link)))
      (should (equal (nelix-store-test--read-binary-file target)
                     (nelix-store-test--read-binary-file profile-link))))))

(ert-deftest nelix-store-test-profile-activate-runtime-forces-posix-symlinks ()
  "Runtime activation creates profile symlinks when POSIX symlink mode is set."
  (when (eq system-type 'windows-nt)
    (ert-skip "POSIX symlink activation is not used on Windows"))
  (unless (and (fboundp 'make-symbolic-link)
               (fboundp 'file-symlink-p))
    (ert-skip "symbolic links are not available in this Emacs"))
  (nelix-store-test--with-temp-roots
    (let ((probe-target (expand-file-name "symlink-probe-target"
                                          nelix-store-root))
          (probe-link (expand-file-name "symlink-probe-link"
                                        nelix-store-root))
          (nelix-profile-activation-link-mode 'symlink))
      (make-directory nelix-store-root t)
      (with-temp-file probe-target
        (insert "probe\n"))
      (condition-case err
          (make-symbolic-link probe-target probe-link t)
        (error
         (ert-skip (format "symbolic links are not permitted here: %s"
                           (error-message-string err)))))
      (let* ((archive (nelix-store-test--make-tar-fixture
                       (file-name-directory nelix-store-root)
                       "fixture-runtime-symlink"))
             (recipe (nelix-store-test--fixture-recipe
                      "fixture-runtime-symlink"
                      archive))
             (_report (nelix-native-install-recipe
                       recipe "default" 'x86_64-linux))
             (activation (nelix-profile-activate-runtime "default"))
             (link-row (car (plist-get activation :links)))
             (profile-link (plist-get link-row :link))
             (target (plist-get link-row :target)))
        (should (eq 'ok (plist-get activation :status)))
        (should (eq 'symlink (plist-get link-row :mode)))
        (should (file-symlink-p profile-link))
        (should (equal (file-truename target)
                       (file-truename profile-link)))))))

(ert-deftest nelix-store-test-profile-activate-runtime-preserves-active-on-failure ()
  "Runtime activation leaves the previous active tree intact on failure."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-runtime"))
           (recipe (nelix-store-test--fixture-recipe "fixture-runtime"
                                                     archive))
           (_report (nelix-native-install-recipe
                     recipe "default" 'x86_64-linux))
           (activation (nelix-profile-activate-runtime "default"))
           (active-dir (plist-get activation :activation-dir))
           (shim (expand-file-name "bin/fixture-runtime" active-dir))
           (path-fragment (expand-file-name "path.sh" active-dir))
           (marker (expand-file-name "marker.txt" active-dir)))
      (with-temp-file marker
        (insert "keep me\n"))
      (cl-letf (((symbol-function 'nelix-profile--activate-link-file)
                 (lambda (&rest _args)
                   (signal 'nelix-error
                           (list "fixture activation failure")))))
        (should-error (nelix-profile-activate-runtime "default")
                      :type 'nelix-error))
      (should (file-exists-p active-dir))
      (should (file-exists-p shim))
      (should (file-exists-p path-fragment))
      (should (equal "keep me\n"
                     (nelix-store-test--read-binary-file marker)))
      (should-not
       (directory-files (file-name-directory active-dir)
                        nil
                        "\\`active\\.tmp-")))))

(ert-deftest nelix-store-test-profile-activate-runtime-generates-windows-shims ()
  "Runtime activation generates Windows cmd shims for Windows profiles."
  (nelix-store-test--with-temp-roots
    (let* ((entry (list :name "fixture-rg"
                        :version "1.0.0"
                        :system 'x86_64-windows
                        :hash "sha256-fixture-windows"
                        :runtime-paths '("bin")))
           (store-path (nelix-store-write-entry entry))
           (bin-dir (expand-file-name "bin" store-path))
           (exe (expand-file-name "rg.exe" bin-dir)))
      (make-directory bin-dir t)
      (with-temp-file exe
        (insert "windows binary fixture\n"))
      (nelix-profile-create-generation
       "default" 'x86_64-windows
       (list (list :name "fixture-rg"
                   :version "1.0.0"
                   :store-path store-path
                   :runtime-paths '("bin")
                   :runtime-bins '("bin/rg.exe")
                   :backend 'nelix-native)))
      (let* ((activation (nelix-profile-activate-runtime "default"))
             (shim (expand-file-name "rg.cmd"
                                     (plist-get activation :bin-dir)))
             (profile-link (expand-file-name "bin/rg.exe"
                                             (plist-get activation
                                                        :profile-dir)))
             (path-fragment (plist-get activation :path-fragment)))
        (should (eq 'x86_64-windows (plist-get activation :system)))
        (should (file-exists-p shim))
        (should (file-exists-p profile-link))
        (should (equal 'copy
                       (plist-get (car (plist-get activation :links)) :mode)))
        (should (equal "windows binary fixture\n"
                       (nelix-store-test--read-binary-file profile-link)))
        (should (file-exists-p path-fragment))
        (should (string-match-p "@echo off"
                                (nelix-store-test--read-binary-file shim)))
        (should (string-match-p "rg\\.exe"
                                (nelix-store-test--read-binary-file shim)))
        (should (string-match-p "set \"PATH="
                                (nelix-store-test--read-binary-file
                                 path-fragment)))))))

(ert-deftest nelix-store-test-gc-keeps-all-profile-generations ()
  "nelix-store-gc keeps store paths referenced by any profile generation."
  (nelix-store-test--with-temp-roots
    (let* ((entry-a (list :name "fixture-a"
                         :version "1.0.0"
                         :system 'x86_64-linux
                         :hash "sha256-fixture-a"))
           (entry-b (list :name "fixture-b"
                         :version "1.0.0"
                         :system 'x86_64-linux
                         :hash "sha256-fixture-b"))
           (entry-orphan (list :name "fixture-orphan"
                               :version "1.0.0"
                               :system 'x86_64-linux
                               :hash "sha256-fixture-orphan"))
           (store-a (nelix-store-write-entry entry-a))
           (store-b (nelix-store-write-entry entry-b))
           (store-orphan (nelix-store-write-entry entry-orphan)))
      (nelix-profile-create-generation
       "default" 'x86_64-linux
       (list (list :name "fixture-a" :store-path store-a)
             (list :name "fixture-b" :store-path store-b)))
      (nelix-profile-create-generation
       "default" 'x86_64-linux
       (list (list :name "fixture-a" :store-path store-a)))
      (let ((report (nelix-store-gc)))
        (should (file-exists-p store-a))
        (should (file-exists-p store-b))
        (should-not (file-exists-p store-orphan))
        (should (equal (list store-orphan)
                       (plist-get report :removed)))))))

(ert-deftest nelix-store-test-substitute-metadata-roundtrip ()
  "Substitute metadata is normalized and persisted by system."
  (nelix-store-test--with-temp-roots
    (let* ((substitute (list :name "fixture-tool"
                             :version "1.0.0"
                             :system 'x86_64-linux
                             :source 'nelix-cache
                             :url "https://packages.example/fixture-tool.tar"
                             :sha256 "sha256-fixture-tool"))
           (file (nelix-substitute-write substitute))
           (read-back (nelix-substitute-read file)))
      (should (string-match-p "/x86_64-linux/fixture-tool-1.0.0\\.el\\'"
                              file))
      (should (equal "fixture-tool" (plist-get read-back :name)))
      (should (eq 'x86_64-linux (plist-get read-back :system)))
      (should (equal "sha256-fixture-tool"
                     (plist-get read-back :sha256)))
      (should (equal '("fixture-tool")
                     (mapcar (lambda (row) (plist-get row :name))
                             (nelix-substitute-list 'x86_64-linux)))))))

(ert-deftest nelix-store-test-substitute-verify-local-file ()
  "Substitute verification checks local payload hashes when declared."
  (nelix-store-test--with-temp-roots
    (let ((payload (make-temp-file "nelix-substitute-payload-")))
      (unwind-protect
          (progn
            (with-temp-file payload
              (insert "payload\n"))
            (let* ((substitute (list :name "fixture-tool"
                                     :version "1.0.0"
                                     :system 'x86_64-linux
                                     :source 'nelix-cache
                                     :file payload
                                     :sha256 (nelix-fetch-sha256-file payload)))
                   (report (nelix-substitute-verify substitute)))
              (should (plist-get report :ok))
              (should (plist-get (plist-get report :file-report) :ok))))
        (when (file-exists-p payload)
          (delete-file payload))))))

(ert-deftest nelix-store-test-substitute-rejects-missing-hash ()
  "Substitute metadata must include a payload hash."
  (let ((err (should-error
              (nelix-substitute :name "fixture"
                                :version "1.0.0"
                                :system 'x86_64-linux
                                :source 'nelix-cache)
              :type 'nelix-error)))
    (should (string-match-p "missing :sha256" (cadr err)))))

(ert-deftest nelix-store-test-substitute-nix-bridge-normalizes-metadata ()
  "nelix-substitute-from-nix maps precomputed Nix metadata to Nelix."
  (let ((substitute (nelix-substitute-from-nix
                     (list :name "ripgrep"
                           :version "14.1.1"
                           :system 'x86_64-linux
                           :cache "https://cache.nixos.org"
                           :store-path "/nix/store/hash-ripgrep-14.1.1"
                           :nar-hash "sha256-nar"
                           :nar-size 123
                           :references '("/nix/store/ref")
                           :sig "cache.nixos.org-1:signature"))))
    (should (eq 'nix-cache (plist-get substitute :source)))
    (should (equal "sha256-nar" (plist-get substitute :sha256)))
    (should (equal "/nix/store/hash-ripgrep-14.1.1"
                   (plist-get substitute :store-path)))))

(ert-deftest nelix-store-test-substitute-nix-bridge-requires-cache-fields ()
  "Nix-cache substitute metadata must include cache, store path, and nar hash."
  (let ((err (should-error
              (nelix-substitute :name "ripgrep"
                                :version "14.1.1"
                                :system 'x86_64-linux
                                :source 'nix-cache
                                :sha256 "sha256-nar")
              :type 'nelix-error)))
    (should (string-match-p "nix-cache source missing" (cadr err)))))

(ert-deftest nelix-store-test-substitute-parse-narinfo ()
  "Nix .narinfo text is parsed into structured metadata."
  (let* ((text (concat
                "StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1\n"
                "URL: nar/fixture.nar.xz\n"
                "Compression: xz\n"
                "FileHash: sha256:download\n"
                "FileSize: 42\n"
                "NarHash: sha256:nar\n"
                "NarSize: 123\n"
                "References: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-lib cccccccccccccccccccccccccccccccc-zlib\n"
                "Deriver: unknown-deriver\n"
                "Sig: cache.nixos.org-1:c2ln\n"))
         (narinfo (nelix-substitute-parse-narinfo text)))
    (should (equal "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1"
                   (plist-get narinfo :store-path)))
    (should (equal "nar/fixture.nar.xz" (plist-get narinfo :nar-url)))
    (should (equal "sha256:nar" (plist-get narinfo :nar-hash)))
    (should (equal 123 (plist-get narinfo :nar-size)))
    (should (equal '("cache.nixos.org-1:c2ln")
                   (plist-get narinfo :signatures)))))

(ert-deftest nelix-store-test-substitute-narinfo-fingerprint ()
  "Nix narinfo fingerprints match the signed valid path shape."
  (let* ((narinfo
          (list :store-path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1"
                :nar-hash "sha256:nar"
                :nar-size 123
                :references
                '("cccccccccccccccccccccccccccccccc-zlib"
                  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-lib")))
         (fingerprint (nelix-substitute-narinfo-fingerprint narinfo)))
    (should
     (equal
      "1;/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1;sha256:nar;123;/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-lib,/nix/store/cccccccccccccccccccccccccccccccc-zlib"
      fingerprint))))

(ert-deftest nelix-store-test-substitute-from-narinfo-normalizes-metadata ()
  "Narinfo metadata can be mapped into a Nix-cache substitute descriptor."
  (let* ((text (concat
                "StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1\n"
                "URL: nar/fixture.nar.xz\n"
                "NarHash: sha256:nar\n"
                "NarSize: 123\n"
                "References: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-lib\n"
                "Sig: cache.nixos.org-1:c2ln\n"))
         (substitute
          (nelix-substitute-from-narinfo
           text
           (list :name "ripgrep"
                 :version "14.1.1"
                 :system 'x86_64-linux
                 :cache "https://cache.nixos.org"))))
    (should (eq 'nix-cache (plist-get substitute :source)))
    (should (equal "https://cache.nixos.org"
                   (plist-get substitute :cache)))
    (should (equal "sha256:nar" (plist-get substitute :sha256)))
    (should (equal "cache.nixos.org-1:c2ln"
                   (plist-get substitute :sig)))
    (should (equal 'nix-ed25519
                   (plist-get substitute :signature-algorithm)))
    (should (string-prefix-p "1;/nix/store/"
                             (plist-get substitute :signature-message)))))

(ert-deftest nelix-store-test-substitute-narinfo-ed25519-openssl ()
  "Narinfo Nix Ed25519 signatures verify through OpenSSL and reject tampering."
  (nelix-store-test--with-temp-roots
    (let* ((base-text
            (concat
             "StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ripgrep-14.1.1\n"
             "URL: nar/fixture.nar.xz\n"
             "NarHash: sha256:nar\n"
             "NarSize: 123\n"
             "References: \n"))
           (fingerprint
            (nelix-substitute-narinfo-fingerprint
             (nelix-substitute-parse-narinfo base-text)))
           (fixture
            (nelix-store-test--openssl-sign-ed25519
             (file-name-directory nelix-store-root)
             fingerprint))
           (substitute
            (nelix-substitute-from-narinfo
             (concat base-text
                     "Sig: cache.nixos.org-1:"
                     (plist-get fixture :signature)
                     "\n")
             (list :name "ripgrep"
                   :version "14.1.1"
                   :system 'x86_64-linux
                   :cache "https://cache.nixos.org")))
           (public-keys
            (list (list :key "cache.nixos.org-1"
                        :algorithm 'nix-ed25519
                        :public-key
                        (concat "cache.nixos.org-1:"
                                (plist-get fixture :public-key)))))
           (valid
            (nelix-substitute-verify-trust
             substitute
             '("cache.nixos.org-1")
             public-keys))
           (tampered
            (nelix-substitute-verify-trust
             (plist-put (copy-sequence substitute)
                        :signature-message
                        (concat (plist-get substitute :signature-message) "x"))
             '("cache.nixos.org-1")
             public-keys)))
      (should (plist-get valid :ok))
      (should (plist-get valid :trusted))
      (should (plist-get
               (plist-get (plist-get valid :signature) :crypto)
               :verified))
      (should-not (plist-get tampered :ok))
      (should (eq :cryptographic-signature-invalid
                  (plist-get (plist-get tampered :signature)
                             :blocked))))))

(ert-deftest nelix-store-test-substitute-materialize-tar-payload ()
  "Substitute materialization downloads and unpacks a tar payload into store."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-tool"))
           (substitute (list :name "fixture-tool"
                             :version "1.0.0"
                             :system 'x86_64-linux
                             :source 'nelix-cache
                             :url archive
                             :sha256 (nelix-fetch-sha256-file archive)
                             :archive-format 'tar
                             :install (list :type 'unpack
                                            :bin '("bin/fixture-tool"))))
           (report (nelix-substitute-materialize substitute))
           (store-path (plist-get report :store-path))
           (entry (nelix-store-read-entry store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name "bin/fixture-tool" store-path)))
      (should (equal "fixture-tool" (plist-get entry :name)))
      (should (eq 'substitute (plist-get entry :source))))))

(ert-deftest nelix-store-test-substitute-materialize-zip-payload-with-strip ()
  "Substitute materialization strips top-directory zip payloads."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-zip-fixture
                     (file-name-directory nelix-store-root)
                     "fixture-zip-substitute"))
           (substitute (list :name "fixture-zip-substitute"
                             :version "1.0.0"
                             :system 'x86_64-linux
                             :source 'nelix-cache
                             :url archive
                             :sha256 (nelix-fetch-sha256-file archive)
                             :archive-format 'zip
                             :install (list :type 'unpack
                                            :strip-components 1
                                            :bin '("bin/fixture-zip-substitute"))))
           (report (nelix-substitute-materialize substitute))
           (store-path (plist-get report :store-path)))
      (should (eq 'ok (plist-get report :status)))
      (should (file-exists-p
               (expand-file-name "bin/fixture-zip-substitute" store-path)))
      (should-not
       (file-exists-p
        (expand-file-name
         "fixture-zip-substitute-1.0.0/bin/fixture-zip-substitute"
         store-path))))))

(ert-deftest nelix-store-test-substitute-install-nix-bridge-tar-payload ()
  "Nix bridge substitute metadata can install a portable tar payload."
  (nelix-store-test--with-temp-roots
    (let* ((archive (nelix-store-test--make-tar-fixture
                     (file-name-directory nelix-store-root)
                     "ripgrep"))
           (substitute (nelix-substitute-from-nix
                        (list :name "ripgrep"
                              :version "14.1.1"
                              :system 'x86_64-linux
                              :cache "file:///unused"
                              :store-path "/nix/store/hash-ripgrep-14.1.1"
                              :nar-url archive
                              :nar-format 'tar
                              :nar-hash (nelix-fetch-sha256-file archive)
                              :install (list :type 'unpack
                                             :bin '("bin/ripgrep")))))
           (report (nelix-substitute-install substitute "default" 'x86_64-linux))
           (profile (plist-get report :profile))
           (entry (car (plist-get profile :entries))))
      (should (eq 'install-substitute (plist-get report :operation)))
      (should (file-exists-p
               (expand-file-name "bin/ripgrep"
                                 (plist-get report :store-path))))
      (should (equal "ripgrep" (plist-get entry :name)))
      (should (equal '("bin") (plist-get entry :runtime-paths))))))

(ert-deftest nelix-store-test-substitute-signature-policy ()
  "Substitute signature policy reports trusted and untrusted signers."
  (let* ((substitute (list :name "ripgrep"
                           :version "14.1.1"
                           :system 'x86_64-linux
                           :source 'nelix-cache
                           :sha256 "sha256-payload"
                           :sig "nelix.example-1:signature"))
         (trusted (nelix-substitute-verify-trust
                   substitute
                   '("nelix.example-1")))
         (untrusted (nelix-substitute-verify-trust
                     substitute
                     '("other.example-1")))
         (unsigned (nelix-substitute-verify-trust
                    (plist-put (copy-sequence substitute) :sig nil)
                    '("nelix.example-1"))))
    (should (plist-get trusted :ok))
    (should (plist-get trusted :trusted))
    (should-not (plist-get untrusted :ok))
    (should (eq :untrusted-signature
                (plist-get (plist-get untrusted :signature) :blocked)))
    (should-not (plist-get unsigned :ok))
    (should (eq :missing-signature
                (plist-get (plist-get unsigned :signature) :blocked)))))

(ert-deftest nelix-store-test-substitute-signature-missing-public-key-blocks ()
  "Cryptographic signatures require a matching configured public key."
  (let* ((substitute (list :name "ripgrep"
                           :version "14.1.1"
                           :system 'x86_64-linux
                           :source 'nelix-cache
                           :sha256 "sha256-payload"
                           :sig (list :key "nelix.example-1"
                                      :algorithm 'openssl-rsa-sha256
                                      :value "ZmFrZQ==")))
         (report (nelix-substitute-verify-trust
                  substitute
                  '("nelix.example-1")
                  nil))
         (signature (plist-get report :signature)))
    (should-not (plist-get report :ok))
    (should (eq :missing-public-key
                (plist-get signature :blocked)))
    (should (eq :missing-public-key
                (plist-get (plist-get signature :crypto) :blocked)))))

(ert-deftest nelix-store-test-substitute-signature-native-sha256-digest ()
  "Native SHA-256 digest verifier works without the openssl command."
  (let* ((base (list :name "ripgrep"
                     :version "14.1.1"
                     :system 'x86_64-linux
                     :source 'nelix-cache
                     :sha256 "sha256-payload"))
         (digest (nelix-fetch-sha256-string
                  (nelix-substitute-canonical-message base)))
         (signed
          (append base
                  (list :sig
                        (list :key "nelix.native-1"
                              :algorithm 'nelix-sha256-digest
                              :value digest))))
         (public-keys
          (list (list :key "nelix.native-1"
                      :algorithm 'nelix-sha256-digest)))
         valid
         invalid)
    (cl-letf (((symbol-function 'nelix-substitute--executable-find)
               (lambda (_program) nil)))
      (setq valid
            (nelix-substitute-verify-trust
             signed
             '("nelix.native-1")
             public-keys))
      (setq invalid
            (nelix-substitute-verify-trust
             (plist-put (copy-sequence signed) :version "14.2.0")
             '("nelix.native-1")
             public-keys)))
    (should (plist-get valid :ok))
    (should (plist-get valid :trusted))
    (should (plist-get
             (plist-get (plist-get valid :signature) :crypto)
             :verified))
    (should (eq 'nelix-native
                (plist-get (plist-get (plist-get valid :signature) :crypto)
                           :backend)))
    (should-not (plist-get invalid :ok))
    (should (eq :cryptographic-signature-invalid
                (plist-get (plist-get invalid :signature)
                           :blocked)))))

(ert-deftest nelix-store-test-substitute-signature-registered-verifier ()
  "Registered cryptographic verifiers participate in trust verification."
  (let* ((substitute (list :name "ripgrep"
                           :version "14.1.1"
                           :system 'x86_64-linux
                           :source 'nelix-cache
                           :sha256 "sha256-payload"
                           :sig (list :key "nelix.fixture-1"
                                      :algorithm 'fixture-native
                                      :value "ok")))
         (public-keys
          (list (list :key "nelix.fixture-1"
                      :algorithm 'fixture-native)))
         (nelix-substitute-crypto-verifiers
          (list
           (cons 'fixture-native
                 (lambda (_message signature _key-entry algorithm)
                   (list :verified (equal signature "ok")
                         :backend 'nelisp-fixture
                         :algorithm algorithm)))))
         (report (nelix-substitute-verify-trust
                  substitute
                  '("nelix.fixture-1")
                  public-keys))
         (crypto (plist-get (plist-get report :signature) :crypto)))
    (should (plist-get report :ok))
    (should (plist-get crypto :verified))
    (should (eq 'nelisp-fixture (plist-get crypto :backend)))))

(ert-deftest nelix-store-test-substitute-signature-openssl-rsa-sha256 ()
  "OpenSSL RSA-SHA256 verifier accepts signed metadata and rejects tampering."
  (nelix-store-test--with-temp-roots
    (let* ((base (list :name "ripgrep"
                       :version "14.1.1"
                       :system 'x86_64-linux
                       :source 'nelix-cache
                       :sha256 "sha256-payload"))
           (fixture
            (nelix-store-test--openssl-sign-rsa-sha256
             (file-name-directory nelix-store-root)
             (nelix-substitute-canonical-message base)))
           (signed
            (append base
                    (list :sig
                          (list :key "nelix.example-1"
                                :algorithm 'openssl-rsa-sha256
                                :value (plist-get fixture :signature)))))
           (public-keys
            (list (list :key "nelix.example-1"
                        :algorithm 'openssl-rsa-sha256
                        :public-key-file
                        (plist-get fixture :public-key-file))))
           (valid (nelix-substitute-verify-trust
                   signed
                   '("nelix.example-1")
                   public-keys))
           (tampered (plist-put (copy-sequence signed)
                                :version "14.2.0"))
           (invalid (nelix-substitute-verify-trust
                     tampered
                     '("nelix.example-1")
                     public-keys)))
      (should (plist-get valid :ok))
      (should (plist-get valid :trusted))
      (should (plist-get
               (plist-get (plist-get valid :signature) :crypto)
               :verified))
      (should-not (plist-get invalid :ok))
      (should (eq :cryptographic-signature-invalid
                  (plist-get (plist-get invalid :signature)
                             :blocked))))))

(ert-deftest nelix-store-test-windows-shim-render ()
  "Windows shims are renderable without running on Windows."
  (let ((shim (nelix-builder-render-windows-shim
               "rg" "C:/nelix/store/ripgrep/bin/rg.exe")))
    (should (string-match-p "@echo off" shim))
    (should (string-match-p "rg\\.exe" shim))
    (should (string-match-p "%\\*" shim))))

(ert-deftest nelix-store-test-posix-shim-render ()
  "POSIX shims are renderable without running a shell."
  (let ((shim (nelix-builder-render-posix-shim
               "rg" "/nelix/store/ripgrep/bin/rg")))
    (should (string-match-p "#!/bin/sh" shim))
    (should (string-match-p "exec" shim))
    (should (string-match-p "\"\\$@\"" shim))))

(provide 'nelix-store-test)
;;; nelix-store-test.el ends here
