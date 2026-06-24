;;; clojure-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "clojure-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/clojure-emacs/clojure-mode/tar.gz/815bc387ec1436fb2fcac00ba8a61207636d0186" :sha256 "sha256-4db8570413dadac2d0f7b0d32d746bc51ef203b8c3777a26120456a5d3f81a08") :dependencies nil :install (:type build :build-system emacs-package :pname "clojure-mode" :load-paths (".") :features (clojure-mode)))))

;;; clojure-mode.el ends here
