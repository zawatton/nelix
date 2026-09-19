;;; catchall-box.el --- Nelix recipe (zawatton/catchall-box, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "catchall-box" :version "0.1.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/catchall-box/tar.gz/1af3df4789012f52e0cd38e36365a126732b41b0" :sha256 "sha256-0570205d8dfceb2422bd32bc9eb7c7865791aecfecd7bfa1fb9aeb69fdec7bc5") :dependencies nil :install (:type build :build-system emacs-package :pname "catchall-box" :load-paths (".") :features (catchall-box))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/catchall-box/tar.gz/1af3df4789012f52e0cd38e36365a126732b41b0" :sha256 "sha256-0570205d8dfceb2422bd32bc9eb7c7865791aecfecd7bfa1fb9aeb69fdec7bc5") :dependencies nil :install (:type build :build-system emacs-package :pname "catchall-box" :load-paths (".") :features (catchall-box)))))

;;; catchall-box.el ends here
