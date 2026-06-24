;;; all-the-icons-dired.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "all-the-icons-dired"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/wyuenho/all-the-icons-dired/tar.gz/e157f0668f22ed586aebe0a2c0186ab07702986c" :sha256 "sha256-486b9db6cfcafef9f7199a0e481c8513f2b1c393ba9c8dfcb8905423e00c1a13") :dependencies ("all-the-icons") :install (:type build :build-system emacs-package :pname "all-the-icons-dired" :load-paths (".") :features (all-the-icons-dired)))))

;;; all-the-icons-dired.el ends here
