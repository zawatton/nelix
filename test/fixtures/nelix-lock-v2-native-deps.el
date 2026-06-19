;;; nelix-lock-v2-native-deps.el --- native dependency lock fixture -*- lexical-binding: t; -*-

(require 'nelix-manifest)

(nelix-lock
 :schema "nelix-lock"
 :schema-version 2
 :version 2
 :format 'sexp
 :lock "manifest.el.nelix-lock"
 :manifest-digest "sha256-fixture-native"
 :manifest-files nil
 :profile "default"
 :backend 'nelix-native
 :system 'x86_64-linux
 :nix-channel "nixpkgs"
 :nix-version nil
 :generated-at "2026-06-19T00:00:00+0900"
 :packages '((:name "fixture-app"
              :target "fixture-app"
              :resolved-target "fixture-app"
              :installed-name nil
              :pinned nil
              :backend nelix-native
              :system x86_64-linux
              :source registry
              :recipe-version "1.0.0"
              :recipe-source nil
              :recipe-install (:type script-shim
                               :command "fixture-app"
                               :target "/usr/bin/fixture-app")
              :recipe-dependencies ("fixture-dep")
              :recipe-class system-tool)
             (:name "fixture-dep"
              :target "fixture-dep"
              :resolved-target "fixture-dep"
              :installed-name nil
              :pinned nil
              :backend nelix-native
              :system x86_64-linux
              :source registry
              :recipe-version "1.0.0"
              :recipe-source nil
              :recipe-install (:type script-shim
                               :command "fixture-dep"
                               :target "/usr/bin/fixture-dep")
              :recipe-dependencies nil
              :recipe-class system-tool)))
