;;; org-node.el --- Nelix recipe (meedstrom/org-node, GitHub) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "org-node" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/meedstrom/org-node/tar.gz/7466daf5ec82504eab0fe2a68652830776f0baa8" :sha256 "sha256-5ad8fb6e522d18364f69d47ffb77d5414e596abaa4b07792c7a3981ffa7cacec") :dependencies ("cond-let" "llama" "magit" "org-mem") :install (:type build :build-system emacs-package :pname "org-node" :load-paths (".") :features (org-node))) (x86_64-windows :source (:type url :url "https://codeload.github.com/meedstrom/org-node/tar.gz/7466daf5ec82504eab0fe2a68652830776f0baa8" :sha256 "sha256-5ad8fb6e522d18364f69d47ffb77d5414e596abaa4b07792c7a3981ffa7cacec") :dependencies ("cond-let" "llama" "magit" "org-mem") :install (:type build :build-system emacs-package :pname "org-node" :load-paths (".") :features (org-node)))))

;;; org-node.el ends here
