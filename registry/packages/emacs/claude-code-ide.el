;;; claude-code-ide.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "claude-code-ide"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/claude-code-ide.el/tar.gz/c66f8a8a198fa0b3c751fd56038b416ad633b03a" :sha256 "sha256-9650fec5dbab49f891d406bcedf0a406a8bdcf3a6b9e48d91cfcf784383b7c83") :dependencies ("websocket" "web-server" "transient") :install (:type build :build-system emacs-package :pname "claude-code-ide" :load-paths (".") :features (claude-code-ide)))))

;;; claude-code-ide.el ends here
