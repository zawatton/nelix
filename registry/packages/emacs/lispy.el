;;; lispy.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "lispy"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/lispy/tar.gz/fe44efd21573868638ca86fc8313241148fabbe3" :sha256 "sha256-772f1e6b5877cbaac0726502e953c917d6dd7e1514b82455eabc47abd1c3a970") :dependencies ("ace-window" "hydra" "iedit" "swiper" "zoutline" "indium") :install (:type build :build-system emacs-package :pname "lispy" :load-paths (".") :features (lispy)))))

;;; lispy.el ends here
