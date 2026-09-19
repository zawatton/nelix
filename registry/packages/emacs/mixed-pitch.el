;;; mixed-pitch.el --- Nelix recipe (jabranham/mixed-pitch, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "mixed-pitch" :version "1.1.2" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/jabranham/mixed-pitch/-/archive/519e05f74825abf04b7d2e0e38ec040d013a125a/mixed-pitch-519e05f74825abf04b7d2e0e38ec040d013a125a.tar.gz" :sha256 "sha256-a9f26964b4497e2e60a2113f5a8991bd25c3711ac1913ac20c92d1884a4fc36e") :dependencies nil :install (:type build :build-system emacs-package :pname "mixed-pitch" :load-paths (".") :features (mixed-pitch))) (x86_64-windows :source (:type url :url "https://gitlab.com/jabranham/mixed-pitch/-/archive/519e05f74825abf04b7d2e0e38ec040d013a125a/mixed-pitch-519e05f74825abf04b7d2e0e38ec040d013a125a.tar.gz" :sha256 "sha256-a9f26964b4497e2e60a2113f5a8991bd25c3711ac1913ac20c92d1884a4fc36e") :dependencies nil :install (:type build :build-system emacs-package :pname "mixed-pitch" :load-paths (".") :features (mixed-pitch)))))

;;; mixed-pitch.el ends here
