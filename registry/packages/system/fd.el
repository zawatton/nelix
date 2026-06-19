;;; fd.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "fd"
 :version "system"
 :class 'system-command
 :description "Expose an existing fd command through a Nelix native profile"
 :systems
 '((x86_64-linux
    :install (:type script-shim
              :command "fd"
              :target "fd"
              :require-target t))
   (aarch64-linux
    :install (:type script-shim
              :command "fd"
              :target "fd"
              :require-target t))
   (x86_64-darwin
    :install (:type script-shim
              :command "fd"
              :target "fd"
              :require-target t))
   (aarch64-darwin
    :install (:type script-shim
              :command "fd"
              :target "fd"
              :require-target t))
   (x86_64-windows
    :install (:type script-shim
              :command "fd.exe"
              :target "fd.exe"
              :require-target t))))

;;; fd.el ends here
