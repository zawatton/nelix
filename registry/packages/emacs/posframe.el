;;; posframe.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "posframe"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tumashu/posframe/tar.gz/570273bcf6c21641f02ccfcc9478607728f0a2a2" :sha256 "sha256-927a207524676270f76af71dc5023e36af3e3850fab43338da3806b5f40b4853") :dependencies nil :install (:type build :build-system emacs-package :pname "posframe" :load-paths (".") :features (posframe)))))

;;; posframe.el ends here
