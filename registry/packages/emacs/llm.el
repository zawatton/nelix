;;; llm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "llm"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/ahyatt/llm/tar.gz/main" :sha256 "sha256-05e1153e754137c984d09471baaaf0e43ce76a563dc59d529b6f9134a873b316") :dependencies nil :install (:type build :build-system emacs-package :pname "llm" :load-paths (".") :features (llm)))))

;;; llm.el ends here
