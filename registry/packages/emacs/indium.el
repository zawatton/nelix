;;; indium.el --- Nelix recipe (NicolasPetton/Indium, GitHub) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "indium" :version "3.3.1" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/NicolasPetton/Indium/tar.gz/8499e156bf7286846c3a2bf8c9e0c4d4f24b224c" :sha256 "sha256-f5262b7124f96cfc6aef581ea59ba38e5beb2a17231e5db335d57cff69e022b5") :dependencies nil :install (:type build :build-system emacs-package :pname "indium" :load-paths (".") :features (indium))) (x86_64-windows :source (:type url :url "https://codeload.github.com/NicolasPetton/Indium/tar.gz/8499e156bf7286846c3a2bf8c9e0c4d4f24b224c" :sha256 "sha256-f5262b7124f96cfc6aef581ea59ba38e5beb2a17231e5db335d57cff69e022b5") :dependencies nil :install (:type build :build-system emacs-package :pname "indium" :load-paths (".") :features (indium)))))

;;; indium.el ends here
