;;; visual-fill-column.el --- Nelix recipe (joostkremers/visual-fill-column, Codeberg) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "visual-fill-column" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeberg.org/joostkremers/visual-fill-column/archive/e04d3521b6dc2435de4c4a4b9cac5feb194f0d5b.tar.gz" :sha256 "sha256-da5195ea56bf80a204e9e9bf0e75bf61c955319a1728cc0bf59ecc56c1e98b9a") :dependencies nil :install (:type build :build-system emacs-package :pname "visual-fill-column" :load-paths (".") :features (visual-fill-column))) (x86_64-windows :source (:type url :url "https://codeberg.org/joostkremers/visual-fill-column/archive/e04d3521b6dc2435de4c4a4b9cac5feb194f0d5b.tar.gz" :sha256 "sha256-da5195ea56bf80a204e9e9bf0e75bf61c955319a1728cc0bf59ecc56c1e98b9a") :dependencies nil :install (:type build :build-system emacs-package :pname "visual-fill-column" :load-paths (".") :features (visual-fill-column)))))

;;; visual-fill-column.el ends here
