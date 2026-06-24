;;; ob-typescript.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ob-typescript"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/lurdan/ob-typescript/tar.gz/5fe1762f8d8692dd5b6f1697bedbbf4cae9ef036" :sha256 "sha256-7d4237931f7e908e9f1aaa18e5ace672ef16a89a5667827e83d2d538e9b1ec37") :dependencies nil :install (:type build :build-system emacs-package :pname "ob-typescript" :load-paths (".") :features (ob-typescript)))))

;;; ob-typescript.el ends here
