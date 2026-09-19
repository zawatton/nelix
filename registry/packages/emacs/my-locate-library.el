;;; my-locate-library.el --- Nelix recipe (zawatton/my-locate-library, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "my-locate-library" :version "0.1.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/my-locate-library/tar.gz/9eeb890fe28113ca8282d1d68c1c47eb071e08e9" :sha256 "sha256-2fce3c938467e3e9c6073907beb02afbdf71b441cd4c789d68bf5b32f0b8132e") :dependencies nil :install (:type build :build-system emacs-package :pname "my-locate-library" :load-paths (".") :features (my-locate-library))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/my-locate-library/tar.gz/9eeb890fe28113ca8282d1d68c1c47eb071e08e9" :sha256 "sha256-2fce3c938467e3e9c6073907beb02afbdf71b441cd4c789d68bf5b32f0b8132e") :dependencies nil :install (:type build :build-system emacs-package :pname "my-locate-library" :load-paths (".") :features (my-locate-library)))))

;;; my-locate-library.el ends here
