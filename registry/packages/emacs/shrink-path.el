;;; shrink-path.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "shrink-path"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/zbelial/shrink-path.el/tar.gz/0bf09bf4d4a90ca183a8806271740239d3ae6703"
                      :sha256 "sha256-ace1786f4ec8e762bd5f44f2f505b9d5b9c8f027e29b899fc2aaf62c55c3a220")
             :dependencies ("s" "dash" "f")
             :install (:type build
                       :build-system emacs-package
                       :pname "shrink-path"
                       :load-paths (".")
                       :features (shrink-path)))))

;;; shrink-path.el ends here
