;;; tree.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "tree"
 :version "system"
 :class 'system-command
 :description "Expose an existing tree command through a Nelix native profile"
 :systems
 '((x86_64-linux
    :install (:type script-shim
              :command "tree"
              :target "tree"
              :require-target t))
   (aarch64-linux
    :install (:type script-shim
              :command "tree"
              :target "tree"
              :require-target t))
   (x86_64-darwin
    :install (:type script-shim
              :command "tree"
              :target "tree"
              :require-target t))
   (aarch64-darwin
    :install (:type script-shim
              :command "tree"
              :target "tree"
              :require-target t))
   (x86_64-windows
    :install (:type script-shim
              :command "tree.com"
              :target "tree.com"
              :require-target t))))

;;; tree.el ends here
