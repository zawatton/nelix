;;; devdocs.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "devdocs"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/astoff/devdocs.el/tar.gz/c14d1306648d3ae09ee3a3b3f45592334943cfeb" :sha256 "sha256-aaa1f2a32273cb64910e82346093491f3413b3689524c1480cf2735cceccb65d") :dependencies nil :install (:type build :build-system emacs-package :pname "devdocs" :load-paths (".") :features (devdocs)))))

;;; devdocs.el ends here
