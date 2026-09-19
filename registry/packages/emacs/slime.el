;;; slime.el --- Nelix recipe (slime/slime, GitHub) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "slime" :version "2.32.git" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/slime/slime/tar.gz/06e46196ad7d972c10559291d8a82f8beb735463" :sha256 "sha256-b0eb2cc30a1ec0df30921833daeddd35ded2b675474fbc762581b54502e67f04") :dependencies nil :install (:type build :build-system emacs-package :pname "slime" :load-paths (".") :features (slime))) (x86_64-windows :source (:type url :url "https://codeload.github.com/slime/slime/tar.gz/06e46196ad7d972c10559291d8a82f8beb735463" :sha256 "sha256-b0eb2cc30a1ec0df30921833daeddd35ded2b675474fbc762581b54502e67f04") :dependencies nil :install (:type build :build-system emacs-package :pname "slime" :load-paths (".") :features (slime)))))

;;; slime.el ends here
