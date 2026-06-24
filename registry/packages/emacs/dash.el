;;; dash.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

;; Doc 33 M1: first native Emacs-package recipe.  Source and pin match the
;; flake.nix `dash' derivation (magnars/dash.el rev 1de9dcb...).  M1b builds it
;; natively: the build phases unpack the fetched tarball, byte-compile the
;; package, and generate its autoloads — all as Lisp-native FORMs run by
;; `nelix-builder--run-phase-elisp' (no shell).  `nelix-build--dir' is the build
;; directory and `(nelix-out)' the store $out.

(require 'nelix-registry)

(nelix-package
 :name "dash"
 :version "1de9dcb"
 :class 'emacs-package
 :description "A modern list library for Emacs (native build of magnars/dash.el)"
 :systems
 '((x86_64-linux
    :source (:type url
             :url "https://codeload.github.com/magnars/dash.el/tar.gz/1de9dcb83eacfb162b6d9a118a4770b1281bcd84"
             :sha256 "sha256-4d528df35412d4df346f1ab51f8ee0bee00eb1c6bc3ffe9958e6f15f6ebefd0a")
    :install
    (:type build
     :build-system trivial
     :build-phases
     ((unpack
       . (nelix-invoke "tar" "xzf"
                       (expand-file-name "1de9dcb83eacfb162b6d9a118a4770b1281bcd84"
                                         nelix-build--dir)
                       "--strip-components=1"))
      (compile
       . (let ((load-path (cons nelix-build--dir load-path)))
           (require 'bytecomp)
           (dolist (f (directory-files nelix-build--dir t "\\.el\\'"))
             (unless (or (string-prefix-p "." (file-name-nondirectory f))
                         (string-match-p "autoloads" f))
               (byte-compile-file f)))))
      (autoload
       . (progn
           (require 'package)
           (package-generate-autoloads "dash" nelix-build--dir)))
      (install
       . (progn
           (nelix-mkdir-p (nelix-out))
           (dolist (f (directory-files nelix-build--dir t "\\.elc?\\'"))
             (unless (string-prefix-p "." (file-name-nondirectory f))
               (nelix-copy-file f (expand-file-name (file-name-nondirectory f)
                                                    (nelix-out))))))))
     :load-paths (".")
     :features (dash)))))

;;; dash.el ends here
