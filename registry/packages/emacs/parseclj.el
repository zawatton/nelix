;;; parseclj.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "parseclj"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/clojure-emacs/parseclj/tar.gz/ca828c202c026e45bd60503984cf510d904cae50"
                      :sha256 "sha256-6e35a9e6abb0403ff0904c746408b3aba8008b7051815cea92557690091b90f5")
             :dependencies nil
             :install (:type build
                       :build-system emacs-package
                       :pname "parseclj"
                       :load-paths (".")
                       :features (parseclj)))))

;;; parseclj.el ends here
