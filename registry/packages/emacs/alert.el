;;; alert.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "alert"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jwiegley/alert/tar.gz/7774b5fd2feb98d4910ff06435d08c19fba93e26" :sha256 "sha256-ce79894ba4e8a3bcf98414ee2b310a460a9a382401ca981895430861781a6c66") :dependencies nil :install (:type build :build-system emacs-package :pname "alert" :load-paths (".") :features (alert)))))

;;; alert.el ends here
