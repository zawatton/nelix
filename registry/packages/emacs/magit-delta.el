;;; magit-delta.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "magit-delta"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/dandavison/magit-delta/tar.gz/5fc7dbddcfacfe46d3fd876172ad02a9ab6ac616" :sha256 "sha256-2f8fd156b4d941541c1f4f48ea84a419fb05ca78182dc1f1c83b3607865a62de") :dependencies nil :install (:type build :build-system emacs-package :pname "magit-delta" :load-paths (".") :features (magit-delta)))))

;;; magit-delta.el ends here
