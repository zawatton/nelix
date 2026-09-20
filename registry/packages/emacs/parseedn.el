;;; parseedn.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "parseedn"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/clojure-emacs/parseedn/tar.gz/1a28a88e2aabd99b41e02f491d6b8874ec128d7d"
                      :sha256 "sha256-2a610e538260a7dadea168418c7e36cc573c0bbc171654ef617ac0f064206de5")
             :dependencies ("parseclj")
             :install (:type build
                       :build-system emacs-package
                       :pname "parseedn"
                       :load-paths (".")
                       :features (parseedn)))
            (x86_64-windows
             :source (:type url
                      :url "https://codeload.github.com/clojure-emacs/parseedn/tar.gz/1a28a88e2aabd99b41e02f491d6b8874ec128d7d"
                      :sha256 "sha256-2a610e538260a7dadea168418c7e36cc573c0bbc171654ef617ac0f064206de5")
             :dependencies ("parseclj")
             :install (:type build
                       :build-system emacs-package
                       :pname "parseedn"
                       :load-paths (".")
                       :features (parseedn)))))

;;; parseedn.el ends here
