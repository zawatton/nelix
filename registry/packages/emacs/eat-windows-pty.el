;;; eat-windows-pty.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "eat-windows-pty"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/eat-windows-pty/tar.gz/b642478b601d1ecba6e75eeeda24434fa2cb9a7b" :sha256 "sha256-cd2f1aafcf54a7f22bb0baaa6764201d21e83ee3d95f0ade263bbad659cd0385") :dependencies ("eat") :install (:type build :build-system emacs-package :pname "eat-windows-pty" :load-paths (".") :features (eat-windows-pty)))))

;;; eat-windows-pty.el ends here
