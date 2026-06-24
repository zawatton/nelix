;;; company-posframe.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "company-posframe"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tumashu/company-posframe/tar.gz/18d6641bba72cba3c00018cee737ea8b454f64a8" :sha256 "sha256-8b3b9d5fce64f23782f2267f0ffa345233106fb671636bbd8d9422458521f9c1") :dependencies ("company" "posframe") :install (:type build :build-system emacs-package :pname "company-posframe" :load-paths (".") :features (company-posframe)))))

;;; company-posframe.el ends here
