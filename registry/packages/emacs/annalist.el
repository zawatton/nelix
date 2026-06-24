;;; annalist.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "annalist"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/noctuid/annalist.el/tar.gz/e1ef5dad75fa502d761f70d9ddf1aeb1c423f41d" :sha256 "sha256-82c04d0d00b7b011ca8d36b095bd84f475ea940bf335f387a33b02935fa3cfae") :dependencies nil :install (:type build :build-system emacs-package :pname "annalist" :load-paths (".") :features (annalist)))))

;;; annalist.el ends here
