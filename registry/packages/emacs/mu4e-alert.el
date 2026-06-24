;;; mu4e-alert.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "mu4e-alert"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/xzz53/mu4e-alert/tar.gz/d36eb0c1842dea51ee0465bb3751948c8886617c" :sha256 "sha256-4c9f27a357f46fda9fdf40916237de0c8989600c05161a03a5a9c64103ad228e") :dependencies nil :install (:type build :build-system emacs-package :pname "mu4e-alert" :load-paths (".") :features (mu4e-alert)))))

;;; mu4e-alert.el ends here
