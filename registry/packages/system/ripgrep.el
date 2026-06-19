;;; ripgrep.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ripgrep"
 :version "system"
 :class 'system-command
 :description "Expose an existing ripgrep rg command through a Nelix native profile"
 :systems
 '((x86_64-linux
    :install (:type script-shim
              :command "rg"
              :target "rg"
              :require-target t))
   (aarch64-linux
    :install (:type script-shim
              :command "rg"
              :target "rg"
              :require-target t))
   (x86_64-darwin
    :install (:type script-shim
              :command "rg"
              :target "rg"
              :require-target t))
   (aarch64-darwin
    :install (:type script-shim
              :command "rg"
              :target "rg"
              :require-target t))
   (x86_64-windows
    :install (:type script-shim
              :command "rg.exe"
              :target "rg.exe"
              :require-target t))))

;;; ripgrep.el ends here
