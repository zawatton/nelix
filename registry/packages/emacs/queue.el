;;; queue.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "queue"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-straight/queue/tar.gz/8df1334d54d4735d2f821790422a850dfaaa08ef" :sha256 "sha256-a596ba71bedba0f4d44c6f4300c9e251d67e24340789405b8c09201c5b44fe38") :dependencies nil :install (:type build :build-system emacs-package :pname "queue" :load-paths (".") :features (queue)))))

;;; queue.el ends here
