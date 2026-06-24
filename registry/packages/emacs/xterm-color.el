;;; xterm-color.el --- Nelix recipe (manual pin; missing transitive dep) -*- lexical-binding: t; -*-

;; magit-delta requires xterm-color, which nixpkgs supplied as a propagated
;; dependency and which was therefore never a top-level flake.nix block.  Pinned
;; here by full commit with the real tarball sha256.  xterm-color needs only
;; Emacs 25.1, so it has no external dependencies.

(require 'nelix-registry)

(nelix-package
 :name "xterm-color"
 :version "2.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/atomontage/xterm-color/tar.gz/ffdad85e584dfc0857f2a1fb970f5ef0f5d31ba3" :sha256 "sha256-70311e5b24b10fc2fe07f403aa81a12afce875f47ef17817e1200f55def330d5") :dependencies nil :install (:type build :build-system emacs-package :pname "xterm-color" :load-paths (".") :features (xterm-color)))))

;;; xterm-color.el ends here
