;;; ob-iec61131.el --- Nelix recipe (zawatton/ob-iec61131, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "ob-iec61131" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/ob-iec61131/tar.gz/e260ea0a476c6eed9fd50a0932c47032402a69a5" :sha256 "sha256-56d79cbd398dd8e0f61dd1a01e503f581d477dda889cf50c4c3c2e8a36e5e26b") :dependencies ("st-mode") :install (:type build :build-system emacs-package :pname "ob-iec61131" :load-paths (".") :features (ob-iec61131))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/ob-iec61131/tar.gz/e260ea0a476c6eed9fd50a0932c47032402a69a5" :sha256 "sha256-56d79cbd398dd8e0f61dd1a01e503f581d477dda889cf50c4c3c2e8a36e5e26b") :dependencies ("st-mode") :install (:type build :build-system emacs-package :pname "ob-iec61131" :load-paths (".") :features (ob-iec61131)))))

;;; ob-iec61131.el ends here
