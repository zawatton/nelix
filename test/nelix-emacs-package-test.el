;;; nelix-emacs-package-test.el --- Doc 33 M1/M2 emacs-package recipe tests -*- lexical-binding: t; -*-

;; Doc 33 M1/M2: native (Nix-free) Emacs-package recipes (dash), built via the
;; generic `emacs-package' build-system preset (byte-compile + autoload
;; generation).  The recipe-shape and preset tests are hermetic (no network).
;; The end-to-end build/install test is network-gated behind NELIX_NET_TESTS
;; because it fetches the upstream tarball.

(require 'ert)
(require 'nelix)
(require 'nelix-builder)
(require 'nelix-import)

(ert-deftest nelix-emacs-package-dash-recipe-shape ()
  "Doc 33 M1/M2: dash is a built `emacs-package' recipe using the preset."
  (nelix-registry-update)
  (let* ((r (nelix-registry-get "dash"))
         (sys (cdr (assq 'x86_64-linux (plist-get r :systems))))
         (source (plist-get sys :source))
         (install (plist-get sys :install)))
    (should r)
    (should (eq 'emacs-package (plist-get r :class)))
    (should (eq 'url (plist-get source :type)))
    (should (string-prefix-p "sha256-" (plist-get source :sha256)))
    ;; M2: built via the generic emacs-package build-system preset.
    (should (eq 'build (plist-get install :type)))
    (should (eq 'emacs-package (plist-get install :build-system)))
    (should (equal "dash" (plist-get install :pname)))
    (should (equal '(dash) (plist-get install :features)))
    (should (member "." (plist-get install :load-paths)))))

(ert-deftest nelix-emacs-package-preset-resolves-phases ()
  "Doc 33 M2: the `emacs-package' build-system preset resolves to the four
build phases (unpack/compile/autoload/install)."
  (let ((phases (nelix-builder--resolve-phases 'emacs-package nil)))
    (should (assq 'unpack phases))
    (should (assq 'compile phases))
    (should (assq 'autoload phases))
    (should (assq 'install phases))
    ;; Each phase body is a Lisp-native FORM (cons/list), not a shell string.
    (dolist (p phases)
      (should-not (stringp (cdr p))))))

(ert-deftest nelix-emacs-package-dash-native-install ()
  "Doc 33 M1/M2: dash builds natively (byte-compile + autoloads) via the preset
and loads from the store.  Network-gated (NELIX_NET_TESTS)."
  (skip-unless (getenv "NELIX_NET_TESTS"))
  (nelix-registry-update)
  (let* ((rep (nelix-native-install "dash" "native-trial-ert" 'x86_64-linux))
         (store-path (plist-get rep :store-path)))
    (should (eq 'ok (plist-get rep :status)))
    ;; M1b/M2 artifacts: byte-compiled .elc + generated autoloads.
    (should (file-exists-p (expand-file-name "dash.elc" store-path)))
    (should (file-exists-p (expand-file-name "dash-functional.elc" store-path)))
    (should (file-exists-p (expand-file-name "dash-autoloads.el" store-path)))
    ;; Hidden source files (e.g. .dir-locals.el) must not leak into the store.
    (should-not (file-exists-p (expand-file-name ".dir-locals.el" store-path)))
    ;; The profile entry must contribute the store path as an Emacs load path.
    (let* ((gen (nelix-profile-read "native-trial-ert"))
           (entry (seq-find (lambda (e) (equal (plist-get e :name) "dash"))
                            (plist-get gen :entries))))
      (should entry)
      (should (member store-path (plist-get entry :emacs-load-paths)))
      (should (equal '(dash) (plist-get entry :features))))
    ;; Load purely from the native store path (no Nix, no system load-path).
    (let ((load-path (cons store-path load-path)))
      (load "dash" nil t)
      (should (fboundp '-map))
      (should (equal '(2 3 4) (funcall (intern "-map") #'1+ '(1 2 3)))))))

;;;; Doc 33 M3: flake.nix -> recipe import

(defconst nelix-emacs-package-test--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of this test file, captured at load time for fixture lookup.
`load-file-name' is nil during `ert-run-tests', so it must be captured here.")

(defun nelix-emacs-package-test--fixture (name)
  "Return the absolute path of fixture NAME next to this test file."
  (expand-file-name (concat "fixtures/" name) nelix-emacs-package-test--dir))

(ert-deftest nelix-import-flake-emacs-parse ()
  "Doc 33 M3: parse melpaBuild blocks (pname/owner/repo/rev/deps) from flake.nix."
  (let* ((fixture (nelix-emacs-package-test--fixture "sample-flake.nix"))
         (blocks (nelix-import--parse-flake-emacs-blocks fixture))
         (s (seq-find (lambda (b) (equal (plist-get b :name) "s")) blocks))
         (aw (seq-find (lambda (b) (equal (plist-get b :name) "ace-window")) blocks)))
    (should (= 2 (length blocks)))
    (should (equal "magnars" (plist-get s :owner)))
    (should (equal "s.el" (plist-get s :repo)))
    (should (equal "b4b8c03fcef316a27f75633fe4bb990aeff6e705" (plist-get s :rev)))
    (should (null (plist-get s :deps)))
    ;; dependency extraction from packageRequires.
    (should (equal '("avy") (plist-get aw :deps)))))

(ert-deftest nelix-import-flake-block-to-recipe ()
  "Doc 33 M3: render a flake block into an `emacs-package' recipe (no fetch)."
  (let* ((block (list :name "s" :version "0.0.0" :owner "magnars" :repo "s.el"
                      :rev "abc123" :deps '("dash")))
         (recipe (nelix-import-flake-block-to-recipe block))
         (sys (cdr (assq 'x86_64-linux (plist-get recipe :systems))))
         (source (plist-get sys :source))
         (install (plist-get sys :install)))
    (should (eq 'emacs-package (plist-get recipe :class)))
    (should (eq 'url (plist-get source :type)))
    (should (string-match-p "codeload\\.github\\.com/magnars/s\\.el/tar\\.gz/abc123"
                            (plist-get source :url)))
    ;; sha256 is left unresolved unless RESOLVE-SHA256 is requested.
    (should (null (plist-get source :sha256)))
    (should (equal '("dash") (plist-get sys :dependencies)))
    (should (eq 'build (plist-get install :type)))
    (should (eq 'emacs-package (plist-get install :build-system)))
    (should (equal "s" (plist-get install :pname)))))

;;; nelix-emacs-package-test.el ends here
