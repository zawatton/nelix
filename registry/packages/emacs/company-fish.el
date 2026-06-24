;;; company-fish.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "company-fish"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/CeleritasCelery/company-fish/tar.gz/f6b245700042d5c9f795547db9ad68a623fb41a5" :sha256 "sha256-e459a35ea793757280f02f4c312c0ac79a4560e6af9e3ea74c7166e8a226af49") :dependencies ("company" "dash" "s") :install (:type build :build-system emacs-package :pname "company-fish" :load-paths (".") :features (company-fish)))))

;;; company-fish.el ends here
