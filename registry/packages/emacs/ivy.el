;;; ivy.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ivy"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/swiper/tar.gz/0d02f5063d36ff4fa6138f0973c83c6d3874fba0" :sha256 "sha256-7275b78be2554d00ede06ca04cbdce10549e97cedef99bc9026eada49d49fa25") :dependencies ("avy" "hydra") :install (:type build :build-system emacs-package :pname "ivy" :load-paths (".") :features (ivy)))))

;;; ivy.el ends here
