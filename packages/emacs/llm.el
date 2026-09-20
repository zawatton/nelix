;;; llm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "llm" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/ahyatt/llm/tar.gz/90e67fc4dfe3fae5b00e7cf6bb68137ac8c441a1" :sha256 "sha256-5144012a6cfd374a16a756b7e5802c4b29f237bda956083446b8959baf3de2fd") :dependencies nil :install (:type build :build-system emacs-package :pname "llm" :load-paths (".") :features (llm))) (x86_64-windows :source (:type url :url "https://codeload.github.com/ahyatt/llm/tar.gz/90e67fc4dfe3fae5b00e7cf6bb68137ac8c441a1" :sha256 "sha256-5144012a6cfd374a16a756b7e5802c4b29f237bda956083446b8959baf3de2fd") :dependencies nil :install (:type build :build-system emacs-package :pname "llm" :load-paths (".") :features (llm)))))

;;; llm.el ends here
