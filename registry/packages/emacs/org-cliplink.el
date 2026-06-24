;;; org-cliplink.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-cliplink"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/rexim/org-cliplink/tar.gz/13e0940b65d22bec34e2de4bc8cba1412a7abfbc" :sha256 "sha256-a42dfb16220c39cc75bc0f8b4f56b0e755d5221eb2d0899f6ff1caa02e2c8365") :dependencies nil :install (:type build :build-system emacs-package :pname "org-cliplink" :load-paths (".") :features (org-cliplink)))))

;;; org-cliplink.el ends here
