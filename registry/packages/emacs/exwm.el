;;; exwm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "exwm"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-exwm/exwm/tar.gz/10bd61dbcf69110b2b029ac677c38bd076376d21" :sha256 "sha256-b040fc530f8c13dcf6e582cf0b0b9cdcc472ba84cfa590b4b23d21e50bcf26f6") :dependencies ("xelb") :install (:type build :build-system emacs-package :pname "exwm" :load-paths (".") :features (exwm)))))

;;; exwm.el ends here
