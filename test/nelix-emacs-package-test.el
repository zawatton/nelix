;;; nelix-emacs-package-test.el --- Doc 33 M1 emacs-package recipe tests -*- lexical-binding: t; -*-

;; Doc 33 M1: the first native (Nix-free) Emacs-package recipe (dash).  The
;; recipe-shape test is hermetic (loads packaged recipes from disk, no network).
;; The end-to-end install test is network-gated behind NELIX_NET_TESTS because it
;; fetches the upstream tarball.

(require 'ert)
(require 'nelix)

(ert-deftest nelix-emacs-package-dash-recipe-shape ()
  "Doc 33 M1: the dash recipe is a well-formed `emacs-package' recipe."
  (nelix-registry-update)
  (let* ((r (nelix-registry-get "dash"))
         (sys (cdr (assq 'x86_64-linux (plist-get r :systems))))
         (source (plist-get sys :source))
         (install (plist-get sys :install)))
    (should r)
    (should (eq 'emacs-package (plist-get r :class)))
    (should (eq 'url (plist-get source :type)))
    (should (string-prefix-p "sha256-" (plist-get source :sha256)))
    (should (eq 'emacs-lisp (plist-get install :type)))
    (should (equal 1 (plist-get install :strip-components)))
    (should (equal '(dash) (plist-get install :features)))
    (should (member "." (plist-get install :load-paths)))))

(ert-deftest nelix-emacs-package-dash-native-install ()
  "Doc 33 M1: dash installs natively and `(require \\='dash)' works from the store.
Network-gated (NELIX_NET_TESTS) since it fetches the upstream tarball."
  (skip-unless (getenv "NELIX_NET_TESTS"))
  (nelix-registry-update)
  (let* ((rep (nelix-native-install "dash" "native-trial-ert" 'x86_64-linux))
         (store-path (plist-get rep :store-path)))
    (should (eq 'ok (plist-get rep :status)))
    (should (file-exists-p (expand-file-name "dash.el" store-path)))
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
