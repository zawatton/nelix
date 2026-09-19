;;; math-preview.el --- Nelix recipe (matsievskiysv/math-preview, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "math-preview" :version "5.1.2" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/matsievskiysv/math-preview/-/archive/a2ca3c175468ceaf02bab6cdfd8ef016bda2b98d/math-preview-a2ca3c175468ceaf02bab6cdfd8ef016bda2b98d.tar.gz" :sha256 "sha256-904a1ae7d90db5b148714711296721d4f4ab372ab50c5e9e2472fb409449b44f") :dependencies ("dash" "s") :install (:type build :build-system emacs-package :pname "math-preview" :load-paths (".") :features (math-preview))) (x86_64-windows :source (:type url :url "https://gitlab.com/matsievskiysv/math-preview/-/archive/a2ca3c175468ceaf02bab6cdfd8ef016bda2b98d/math-preview-a2ca3c175468ceaf02bab6cdfd8ef016bda2b98d.tar.gz" :sha256 "sha256-904a1ae7d90db5b148714711296721d4f4ab372ab50c5e9e2472fb409449b44f") :dependencies ("dash" "s") :install (:type build :build-system emacs-package :pname "math-preview" :load-paths (".") :features (math-preview)))))

;;; math-preview.el ends here
