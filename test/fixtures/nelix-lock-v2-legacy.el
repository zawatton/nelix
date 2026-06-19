;;; nelix-lock-v2-legacy.el --- schema v2 lock fixture without schema keys -*- lexical-binding: t; -*-

(require 'nelix-manifest)

(nelix-lock
 :version 2
 :format 'sexp
 :lock "manifest.el.lock.el"
 :manifest-digest "sha256-fixture"
 :manifest-files nil
 :profile "default"
 :backend 'nix
 :system 'x86_64-linux
 :nix-channel "nixpkgs"
 :nix-version "2.34.7"
 :generated-at "2026-06-19T00:00:00+0900"
 :packages nil)
