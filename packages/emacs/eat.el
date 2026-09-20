;;; eat.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "eat"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeberg.org/akib/emacs-eat/archive/c8d54d649872bfe7b2b9f49ae5c2addbf12d3b99.tar.gz"
                      :sha256 "sha256-e4810462c0a91bc5b2c50e45a5e20b4a3472b66a50f2c29ca7ca02ba04a7bd58")
             :dependencies ("compat")
             :install (:type build
                       :build-system emacs-package
                       :pname "eat"
                       :load-paths (".")
                       :features (eat)))))

;;; eat.el ends here
