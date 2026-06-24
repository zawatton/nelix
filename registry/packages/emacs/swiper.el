;;; swiper.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "swiper"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/swiper/tar.gz/d489b4f0d48fd215119261d92de103c5b5580895" :sha256 "sha256-f001b76e447ed8ca428df605f224978ce20e70e450352ce08240a6e7c8200666") :dependencies ("ivy" "avy" "hydra") :install (:type build :build-system emacs-package :pname "swiper" :load-paths (".") :features (swiper)))))

;;; swiper.el ends here
