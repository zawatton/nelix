;;; company-math.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "company-math"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/vspinu/company-math/tar.gz/3eb006874e309ff4076d947fcbd61bb6806aa508" :sha256 "sha256-e3b0ea489362b8edc395c5a9d4595307c699c1c019d228fa88a10a482a4ab666") :dependencies nil :install (:type build :build-system emacs-package :pname "company-math" :load-paths (".") :features (company-math)))))

;;; company-math.el ends here
