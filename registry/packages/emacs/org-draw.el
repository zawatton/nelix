;;; org-draw.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-draw"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/org-draw/tar.gz/f1576b43c01d8a62ffc57a8f86ce2017373b2231" :sha256 "sha256-83b9099e216db9aaaff08e02dbbd9551c2da652f87c805291c7f0a1f2788f5c4") :dependencies ("org") :install (:type build :build-system emacs-package :pname "org-draw" :load-paths (".") :features (org-draw)))))

;;; org-draw.el ends here
