;;; jq.el --- Nelix packaged registry recipe -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "jq"
 :version "system"
 :class 'system-command
 :description "Expose an existing jq command through a Nelix native profile"
 :systems
 '((x86_64-linux
    :install (:type script-shim
              :command "jq"
              :target "jq"
              :require-target t))
   (aarch64-linux
    :install (:type script-shim
              :command "jq"
              :target "jq"
              :require-target t))
   (x86_64-darwin
    :install (:type script-shim
              :command "jq"
              :target "jq"
              :require-target t))
   (aarch64-darwin
    :install (:type script-shim
              :command "jq"
              :target "jq"
              :require-target t))
   (x86_64-windows
    :install (:type script-shim
              :command "jq.exe"
              :target "jq.exe"
              :require-target t))))

;;; jq.el ends here
