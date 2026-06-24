;;; wl.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "wl"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/wanderlust/wanderlust/tar.gz/dddd7d64f27747cfa546d6656beee6ec4e5c55cf" :sha256 "sha256-8006018cf70c2b73582f6127d4762c4653a004ec25ae840215c1def74ed5ec4f") :dependencies nil :install (:type build :build-system emacs-package :pname "wl" :load-paths (".") :features (wl)))))

;;; wl.el ends here
