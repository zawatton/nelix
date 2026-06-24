;;; uuidgen.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "uuidgen"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/kanru/uuidgen-el/tar.gz/cebbe09d27c63abe61fe8c2e2248587d90265b59" :sha256 "sha256-baa9700c4d38a324d1d54c9b21d9fce0c73e9a2848642a882d85e7e6742ecba4") :dependencies nil :install (:type build :build-system emacs-package :pname "uuidgen" :load-paths (".") :features (uuidgen)))))

;;; uuidgen.el ends here
