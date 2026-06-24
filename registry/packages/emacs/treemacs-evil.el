;;; treemacs-evil.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "treemacs-evil"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Alexander-Miller/treemacs/tar.gz/bcba09c1581c4bd93ff0217d464aead04f6d26d4" :sha256 "sha256-8a87f4c52add63c30297870f9ac81496f30579859e33e6ec4ea61f7e9c967fad") :dependencies nil :install (:type build :build-system emacs-package :pname "treemacs-evil" :load-paths (".") :features (treemacs-evil)))))

;;; treemacs-evil.el ends here
