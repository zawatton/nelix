;;; el-job.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "el-job"
 :version "2.7.4"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/meedstrom/el-job/tar.gz/2.7.4" :sha256 "sha256-dcc646575ad94d89fc0631c158ba4546f974c13dc513e7a5ac6c8c28a5dfb2cc") :dependencies nil :install (:type build :build-system emacs-package :pname "el-job" :load-paths (".") :features (el-job)))))

;;; el-job.el ends here
