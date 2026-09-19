;;; st-mode.el --- Nelix recipe (zawatton/st-mode, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "st-mode" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/st-mode/tar.gz/4a2bb426c4479f49192275427d669a71fe68d3de" :sha256 "sha256-28bb1b2409909fad4a507e02d35f2c63aec96231a4f74dca93c237d4c9fb09ac") :dependencies nil :install (:type build :build-system emacs-package :pname "st-mode" :load-paths (".") :features (iec61131-mode))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/st-mode/tar.gz/4a2bb426c4479f49192275427d669a71fe68d3de" :sha256 "sha256-28bb1b2409909fad4a507e02d35f2c63aec96231a4f74dca93c237d4c9fb09ac") :dependencies nil :install (:type build :build-system emacs-package :pname "st-mode" :load-paths (".") :features (iec61131-mode)))))

;;; st-mode.el ends here
