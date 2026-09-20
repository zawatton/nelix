;;; async-installer.el --- Nelix recipe (zawatton/async-installer, pinned to master HEAD) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "async-installer" :version "0.4.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/async-installer/tar.gz/90c8fee9ab60c0b97883c05ceb0c68d9a7c19372" :sha256 "sha256-b920d5b04d60a3a5a870a1e99188fe0155d425adb88b293e4dfd2c39cba44a15") :dependencies ("async") :install (:type build :build-system emacs-package :pname "async-installer" :load-paths (".") :features (async-installer))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/async-installer/tar.gz/90c8fee9ab60c0b97883c05ceb0c68d9a7c19372" :sha256 "sha256-b920d5b04d60a3a5a870a1e99188fe0155d425adb88b293e4dfd2c39cba44a15") :dependencies ("async") :install (:type build :build-system emacs-package :pname "async-installer" :load-paths (".") :features (async-installer)))))

;;; async-installer.el ends here
