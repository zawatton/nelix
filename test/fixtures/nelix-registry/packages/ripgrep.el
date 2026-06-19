;;; ripgrep.el --- Nelix registry fixture -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ripgrep"
 :version "14.1.1"
 :class 'system-tool
 :description "Fast recursive search tool"
 :systems
 '((x86_64-linux
    :source (:type github-release
             :repo "BurntSushi/ripgrep"
             :tag "14.1.1"
             :asset "ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz"
             :sha256 "sha256-fixture-ripgrep-linux")
    :install (:type unpack :bin ("rg")))
   (x86_64-windows
    :source (:type github-release
             :repo "BurntSushi/ripgrep"
             :tag "14.1.1"
             :asset "ripgrep-14.1.1-x86_64-pc-windows-msvc.zip"
             :sha256 "sha256-fixture-ripgrep-windows")
    :install (:type unpack :bin ("rg.exe")))))

;;; ripgrep.el ends here
