;;; nelix-emacs-package-test.el --- Doc 33 M1 emacs-package recipe tests -*- lexical-binding: t; -*-

;; Doc 33 M1: the first native (Nix-free) Emacs-package recipe (dash), built via
;; Lisp-native build phases (byte-compile + autoload generation).  The
;; recipe-shape test is hermetic (loads packaged recipes from disk, no network).
;; The end-to-end build/install test is network-gated behind NELIX_NET_TESTS
;; because it fetches the upstream tarball.

(require 'ert)
(require 'nelix)

(ert-deftest nelix-emacs-package-dash-recipe-shape ()
  "Doc 33 M1: the dash recipe is a well-formed built `emacs-package' recipe."
  (nelix-registry-update)
  (let* ((r (nelix-registry-get "dash"))
         (sys (cdr (assq 'x86_64-linux (plist-get r :systems))))
         (source (plist-get sys :source))
         (install (plist-get sys :install))
         (phases (plist-get install :build-phases)))
    (should r)
    (should (eq 'emacs-package (plist-get r :class)))
    (should (eq 'url (plist-get source :type)))
    (should (string-prefix-p "sha256-" (plist-get source :sha256)))
    ;; M1b: built natively via Lisp-native build phases.
    (should (eq 'build (plist-get install :type)))
    (should (assq 'unpack phases))
    (should (assq 'compile phases))
    (should (assq 'autoload phases))
    (should (assq 'install phases))
    (should (equal '(dash) (plist-get install :features)))
    (should (member "." (plist-get install :load-paths)))))

(ert-deftest nelix-emacs-package-dash-native-install ()
  "Doc 33 M1: dash builds natively (byte-compile + autoloads) and loads from the
store.  Network-gated (NELIX_NET_TESTS) since it fetches the upstream tarball."
  (skip-unless (getenv "NELIX_NET_TESTS"))
  (nelix-registry-update)
  (let* ((rep (nelix-native-install "dash" "native-trial-ert" 'x86_64-linux))
         (store-path (plist-get rep :store-path)))
    (should (eq 'ok (plist-get rep :status)))
    ;; M1b artifacts: byte-compiled .elc + generated autoloads.
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

;;; nelix-emacs-package-test.el ends here
