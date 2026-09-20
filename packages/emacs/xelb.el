;;; xelb.el --- Nelix recipe (manual pin) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "xelb"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux
             :source (:type url
                      :url "https://codeload.github.com/ch11ng/xelb/tar.gz/df102a5773b37cec154e795a17a8513144dde643"
                      :sha256 "sha256-1c12d491bc5ec5f48d7d5184926b4bc9c482d193e34621293b0a3ae4068f7cef")
             :dependencies nil
             :install (:type build
                       :build-system emacs-package
                       :pname "xelb"
                       :load-paths (".")
                       :features (xelb)))))

;;; xelb.el ends here
