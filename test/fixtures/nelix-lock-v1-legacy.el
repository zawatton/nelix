;;; nelix-lock-v1-legacy.el --- schema v1 lock fixture without package rows -*- lexical-binding: t; -*-

(require 'nelix-manifest)

(nelix-lock
 :version 1
 :format 'sexp
 :lock "manifest.el.lock.el"
 :manifest-digest "sha256-fixture"
 :manifest-files nil
 :profile "default"
 :backend 'nix
 :system 'x86_64-linux
 :nix-channel "nixpkgs"
 :nix-version "2.34.7"
 :generated-at "2026-06-19T00:00:00+0900")
