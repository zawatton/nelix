;;; org-node-fakeroam.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-node-fakeroam"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/meedstrom/org-node-fakeroam/tar.gz/fda864320606e1e860b5bd9a6b2b08aec9abc8de" :sha256 "sha256-879f81a8d4a94772da3df1b32c179f8ce82085fe31df32eb2b619f819a7b4635") :dependencies ("org-node" "emacsql" "org-roam") :install (:type build :build-system emacs-package :pname "org-node-fakeroam" :load-paths (".") :features (org-node-fakeroam)))))

;;; org-node-fakeroam.el ends here
