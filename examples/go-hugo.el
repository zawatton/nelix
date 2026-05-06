;;; go-hugo.el --- Go build example for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Go binary built via `pkgs.buildGoModule'.  Demonstrates:
;;
;;   - github-fetch source pinning
;;   - the go build-system's optional :vendor-sha256
;;     (set to nil / omit → the renderer emits `vendorHash = null;'
;;     which means "vendor at build time, no offline cache" — fine
;;     for one-off installs but slower)
;;
;; Hugo is the static site generator.  It's a single-binary CLI
;; with a vendored go.mod tree.
;;
;; Usage:
;;   M-: (load-file "/path/to/anvil-pkg/examples/go-hugo.el")
;;   M-: (pkg-install 'hugo)

;;; Code:

(require 'anvil-pkg-dsl)

(pkg-define hugo
  (version "0.139.0")
  (source (github-fetch :owner "gohugoio" :repo "hugo"
                        :rev "v0.139.0"
                        :sha256 "sha256-PLACEHOLDER-source-hash"))
  (build-system (go :vendor-sha256 "sha256-PLACEHOLDER-go-mod-hash"))
  (description "The world's fastest framework for building websites.")
  (homepage "https://gohugo.io/")
  (license apache2))

;; Quick variant: omit :vendor-sha256 for an unhashed build.  The
;; renderer emits `vendorHash = null;' and Go will resolve the
;; module graph at build time.  Useful for prototyping; not
;; reproducible across sandboxed CI.
;;
;; (pkg-define hugo-unhashed
;;   (version "0.139.0")
;;   (source (github-fetch :owner "gohugoio" :repo "hugo"
;;                         :rev "v0.139.0"
;;                         :sha256 "sha256-PLACEHOLDER-source-hash"))
;;   (build-system (go))   ; no :vendor-sha256 → vendorHash = null
;;   (description "Hugo, unhashed vendor cache.")
;;   (homepage "https://gohugo.io/"))

(provide 'go-hugo)
;;; go-hugo.el ends here
