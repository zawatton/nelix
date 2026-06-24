;;; org-ql.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-ql"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/org-ql/tar.gz/b6f8a315e966123fbfd1ac240d35da5c2b48d6ac" :sha256 "sha256-d76f8954bcc0735ee06941c6244fefe7ac3565215d74f4bf366ee7770e9f8dab") :dependencies nil :install (:type build :build-system emacs-package :pname "org-ql" :load-paths (".") :features (org-ql)))))

;;; org-ql.el ends here
