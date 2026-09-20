;;; shrink-path.el --- Nelix recipe (bennya/shrink-path.el, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "shrink-path" :version "0.3.1" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/bennya/shrink-path.el/-/archive/c14882c8599aec79a6e8ef2d06454254bb3e1e41/shrink-path.el-c14882c8599aec79a6e8ef2d06454254bb3e1e41.tar.gz" :sha256 "sha256-77fadcf7a2772edff6c1fb5f516293ad5aa9e463dfae8c2a2f0ceaa3ec9c581d") :dependencies ("s" "dash" "f") :install (:type build :build-system emacs-package :pname "shrink-path" :load-paths (".") :features (shrink-path))) (x86_64-windows :source (:type url :url "https://gitlab.com/bennya/shrink-path.el/-/archive/c14882c8599aec79a6e8ef2d06454254bb3e1e41/shrink-path.el-c14882c8599aec79a6e8ef2d06454254bb3e1e41.tar.gz" :sha256 "sha256-77fadcf7a2772edff6c1fb5f516293ad5aa9e463dfae8c2a2f0ceaa3ec9c581d") :dependencies ("s" "dash" "f") :install (:type build :build-system emacs-package :pname "shrink-path" :load-paths (".") :features (shrink-path)))))

;;; shrink-path.el ends here
