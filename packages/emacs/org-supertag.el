;;; org-supertag.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "org-supertag" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/yibie/org-supertag/tar.gz/53bdfc9d1236d85fbc5d7ce8e771be2bb4efbddc" :sha256 "sha256-d4a30f789ae6b8a4f1de3365836b268054baba2ed0a0112b8c482a1ba71f72da") :dependencies ("org" "ht" "gptel" "posframe") :install (:type build :build-system emacs-package :pname "org-supertag" :load-paths (".") :features (org-supertag))) (x86_64-windows :source (:type url :url "https://codeload.github.com/yibie/org-supertag/tar.gz/53bdfc9d1236d85fbc5d7ce8e771be2bb4efbddc" :sha256 "sha256-d4a30f789ae6b8a4f1de3365836b268054baba2ed0a0112b8c482a1ba71f72da") :dependencies ("org" "ht" "gptel" "posframe") :install (:type build :build-system emacs-package :pname "org-supertag" :load-paths (".") :features (org-supertag)))))

;;; org-supertag.el ends here
