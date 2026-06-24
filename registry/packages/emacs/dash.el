;;; dash.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

;; Doc 33 M1/M2: native Emacs-package recipe.  Source and pin match the
;; flake.nix `dash' derivation (magnars/dash.el rev 1de9dcb...).  The build is
;; the generic `emacs-package' build-system preset (unpack tarball,
;; byte-compile, generate autoloads, install .el/.elc/autoloads), so this recipe
;; only declares the source, the pin, and the package metadata.

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
    :install (:type build
              :build-system emacs-package
              :pname "dash"
              :load-paths (".")
              :features (dash)))))

;;; dash.el ends here
