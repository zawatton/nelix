;;; nelix-lock-v2-current.el --- current schema v2 lock fixture -*- lexical-binding: t; -*-

(require 'nelix-manifest)

(nelix-lock
 :schema "nelix-lock"
 :schema-version 2
 :version 2
 :format 'sexp
 :lock "manifest.el.nelix-lock"
 :manifest-digest "sha256-fixture"
 :manifest-files nil
 :profile "default"
 :backend 'nix
 :system 'x86_64-linux
 :nix-channel "nixpkgs"
 :nix-version "2.34.7"
 :generated-at "2026-06-19T00:00:00+0900"
 :packages '((:name "ripgrep"
              :target "ripgrep"
              :backend nix
              :system x86_64-linux
              :attr-path "legacyPackages.x86_64-linux.ripgrep"
              :installed-name nil
              :source nixpkgs)))
