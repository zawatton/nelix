;;; org-node.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-node"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/meedstrom/org-node/tar.gz/10ea878528a24ae9bf6903da198f347d093f2b11"
                      :sha256 "sha256-d5c81f6e865b90389e77f7c65db1cb93583fe1813d75b7178fa68be4830a3e14")
             :dependencies ("cond-let" "llama" "org-mem")
             :install (:type build
                       :build-system emacs-package
                       :pname "org-node"
                       :load-paths (".")
                       :features (org-node)))))

;;; org-node.el ends here
