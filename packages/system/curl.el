;;; curl.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "curl"
 :version "system"
 :class 'system-command
 :description "Expose an existing curl command through a Nelix native profile"
 :systems
 '((x86_64-linux
    :install (:type script-shim
              :command "curl"
              :target "curl"
              :require-target t))
   (aarch64-linux
    :install (:type script-shim
              :command "curl"
              :target "curl"
              :require-target t))
   (x86_64-darwin
    :install (:type script-shim
              :command "curl"
              :target "curl"
              :require-target t))
   (aarch64-darwin
    :install (:type script-shim
              :command "curl"
              :target "curl"
              :require-target t))
   (x86_64-windows
    :install (:type script-shim
              :command "curl.exe"
              :target "curl.exe"
              :require-target t))))

;;; curl.el ends here
