;;; ob-async-test.el --- Nelix recipe (zawatton/ob-async-test, pinned to main HEAD) -*- lexical-binding: t; -*-

;; NOTE: this repo is zawatton's fork/test tree of astahlman/ob-async;
;; its main file is ob-async.el and provides feature `ob-async` (not
;; `ob-async-test`).

(require 'nelix-registry)

(nelix-package :name "ob-async-test" :version "0.1" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/ob-async-test/tar.gz/ed95f1af0f1983265617d532bca9f34df9c7075c" :sha256 "sha256-ae4e5bf3ef939cbee5ab2df21a159db2b73927f60e24bd6d13ad5f8f208e7525") :dependencies ("async") :install (:type build :build-system emacs-package :pname "ob-async-test" :load-paths (".") :features (ob-async))) (x86_64-windows :source (:type url :url "https://codeload.github.com/zawatton/ob-async-test/tar.gz/ed95f1af0f1983265617d532bca9f34df9c7075c" :sha256 "sha256-ae4e5bf3ef939cbee5ab2df21a159db2b73927f60e24bd6d13ad5f8f208e7525") :dependencies ("async") :install (:type build :build-system emacs-package :pname "ob-async-test" :load-paths (".") :features (ob-async)))))

;;; ob-async-test.el ends here
