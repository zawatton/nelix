;;; emacs-skkserv.el --- Nelix recipe (zawatton/emacs-skkserv, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "emacs-skkserv" :version "0.1.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/emacs-skkserv/tar.gz/d35fb7cfed5d8591cdd1bf483830c47eadbf6d9a" :sha256 "sha256-93f676cb53338a76971c0c95f6ecf3a2eebff86dd6510516a633a09c4a7fcc63") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-skkserv" :load-paths (".") :features (emacs-skkserv))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/emacs-skkserv/tar.gz/d35fb7cfed5d8591cdd1bf483830c47eadbf6d9a" :sha256 "sha256-93f676cb53338a76971c0c95f6ecf3a2eebff86dd6510516a633a09c4a7fcc63") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-skkserv" :load-paths (".") :features (emacs-skkserv)))))

;;; emacs-skkserv.el ends here
