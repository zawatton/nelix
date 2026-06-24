;;; math-symbol-lists.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "math-symbol-lists"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/vspinu/math-symbol-lists/tar.gz/ac3eb053d3b576fcdd192b0ac6ad5090ea3a7079"
                      :sha256 "sha256-3d1651e36439826b5ee1daee8675b102dc97d738baaa7130d70f6038e757ef5a")
             :dependencies nil
             :install (:type build
                       :build-system emacs-package
                       :pname "math-symbol-lists"
                       :load-paths (".")
                       :features (math-symbol-lists)))))

;;; math-symbol-lists.el ends here
