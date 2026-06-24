;;; epc.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "epc"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/kiwanami/emacs-epc/tar.gz/94cd36a3bec752263ac9b1b3a9dd2def329d2af7" :sha256 "sha256-3ce1a5d4a1eb512a8b143448bfad751336b791f81853382f440762685abd0f2c") :dependencies ("concurrent" "ctable") :install (:type build :build-system emacs-package :pname "epc" :load-paths (".") :features (epc)))))

;;; epc.el ends here
