;;; chatgpt.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "chatgpt"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/h-ohsaki/chatgpt-el/tar.gz/607afffe267b8fc3e777c7820a2f539dddeb9cc1" :sha256 "sha256-f357869ea7245bdd548e4a97f098372c4094bcd57ca7651e0713003f39518097") :dependencies nil :install (:type build :build-system emacs-package :pname "chatgpt" :el-exclude ("llama.el") :load-paths (".") :features (chatgpt)))))

;;; chatgpt.el ends here
