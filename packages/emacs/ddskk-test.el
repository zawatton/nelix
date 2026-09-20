;;; ddskk-test.el --- Nelix recipe (zawatton/ddskk-test, pinned to main HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "ddskk-test" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/ddskk-test/tar.gz/f6586b5efeb3a9b4ec58ddc93a03186513f2cd73" :sha256 "sha256-7d0335159d5afb66d61ec69e088a88d7241c8e4f99d85b4a9070768555ba2b35") :dependencies nil :install (:type build :build-system emacs-package :pname "ddskk-test" :load-paths (".") :features (ddskk))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/ddskk-test/tar.gz/f6586b5efeb3a9b4ec58ddc93a03186513f2cd73" :sha256 "sha256-7d0335159d5afb66d61ec69e088a88d7241c8e4f99d85b4a9070768555ba2b35") :dependencies nil :install (:type build :build-system emacs-package :pname "ddskk-test" :load-paths (".") :features (ddskk)))))

;;; ddskk-test.el ends here
