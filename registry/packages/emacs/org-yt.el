;;; org-yt.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-yt"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/TobiasZawada/org-yt/tar.gz/56166f48e04d83668f70ed84706b7a4d8b1e5438" :sha256 "sha256-ddaad9ae3258fcdb9cad432ae3a4ad50fa898e8aa6ef57f4cbceb3a40d60e484") :dependencies nil :install (:type build :build-system emacs-package :pname "org-yt" :load-paths (".") :features (org-yt)))))

;;; org-yt.el ends here
