;;; phscroll.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "phscroll"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/misohena/phscroll/tar.gz/582abedb4cf6aba216cdb5fe7217d612a1d68d5a" :sha256 "sha256-21d479f6a422d4d8b52cc0cdfceafa1267103aab793637d5c5d8ad502bebde77") :dependencies nil :install (:type build :build-system emacs-package :pname "phscroll" :load-paths (".") :features (phscroll)))))

;;; phscroll.el ends here
