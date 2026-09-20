;;; emacs-markdown-babel.el --- Nelix recipe (whacked/emacs-markdown-babel, GitHub) -*- lexical-binding: t; -*-

;; NOTE: emacs-markdown-babel.el has no `(provide ...)` form upstream (it is
;; a loose snippet collection, not a packaged library), so `:features` below
;; is best-effort and `(require 'emacs-markdown-babel)` will not actually
;; succeed. The recipe still resolves and installs the file for name
;; tracking / manual `load` use.

(require 'nelix-registry)

(nelix-package :name "emacs-markdown-babel" :version "0.0.1-alpha" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/whacked/emacs-markdown-babel/tar.gz/f7a65a240a1f60255a121b84cd3fa1cec3abb7ef" :sha256 "sha256-cb9577521534aa46247fb4f01a969f629e713e79f32eb6be3a1d04edaff6f517") :dependencies ("markdown-mode" "s" "f") :install (:type build :build-system emacs-package :pname "emacs-markdown-babel" :load-paths (".") :features (emacs-markdown-babel))) (x86_64-windows :source (:type url :url "https://codeload.github.com/whacked/emacs-markdown-babel/tar.gz/f7a65a240a1f60255a121b84cd3fa1cec3abb7ef" :sha256 "sha256-cb9577521534aa46247fb4f01a969f629e713e79f32eb6be3a1d04edaff6f517") :dependencies ("markdown-mode" "s" "f") :install (:type build :build-system emacs-package :pname "emacs-markdown-babel" :load-paths (".") :features (emacs-markdown-babel)))))

;;; emacs-markdown-babel.el ends here
