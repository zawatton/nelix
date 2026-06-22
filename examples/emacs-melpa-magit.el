;;; emacs-melpa-magit.el --- emacs-package melpa example -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A multi-file Emacs Lisp library built via
;; `pkgs.emacsPackages.melpaBuild'.  Demonstrates the full stack of
;; emacs-package features:
;;
;;   - :format "melpa" so melpaBuild's recipe-driven layout (dir,
;;     :files glob, autoload generation) takes over from the simpler
;;     trivialBuild path.
;;   - :native-comp t so the resulting .elc / .eln files target the
;;     running Emacs.
;;   - Phase 4-D L23 :melpa-synth — by default 'auto, which
;;     synthesises a recipes/<pname> entry inside postUnpack so the
;;     repo doesn't need a recipes file checked in.
;;   - Phase 4-E L27 opt-in upstream MELPA recipe lookup — when
;;     `nelix-emacs-melpa-upstream-fetch' is non-nil, nelix-core
;;     consults raw.githubusercontent.com/melpa/melpa first; on hit
;;     the canonical curated recipe wins over the local synth.
;;   - Phase 4-E L28 default :files spec — covers lisp/, *.info,
;;     *.el.in, with :exclude clauses for tests / .dir-locals.
;;
;; magit is the standard Emacs git porcelain.  Multi-file, has a
;; lisp/ subdir, depends on dash + transient + with-editor.  These
;; deps come from auto-derive (L18); no need to enumerate manually.
;;
;; Usage:
;;   ;; opt-in to canonical MELPA recipe lookup (Phase 4-E):
;;   (setq nelix-emacs-melpa-upstream-fetch t)
;;
;;   M-: (load-file "/path/to/nelix-core/examples/emacs-melpa-magit.el")
;;   M-: (pkg-install 'magit :require t)

;;; Code:

(require 'nelix-dsl)

(pkg-define magit
  (version "3.3.0")
  (source (github-fetch :owner "magit" :repo "magit"
                        :rev "v3.3.0"
                        :sha256 "sha256-PLACEHOLDER-fill-in-from-nix"))
  (build-system (emacs-package
                 :format "melpa"
                 :native-comp t
                 :melpa-synth auto))     ; default; explicit for clarity
  (description "A Git porcelain inside Emacs.")
  (homepage "https://magit.vc/")
  (license gpl3))

;; Variant with explicit verbatim recipe — useful when you don't
;; want nelix-core to consult upstream MELPA at all and the synth's
;; defaults aren't right for your repo layout:
;;
;; (pkg-define my-fork
;;   (version "0.1.0")
;;   (source (github-fetch :owner "me" :repo "magit-fork"
;;                         :rev "v0.1.0" :sha256 "sha256-..."))
;;   (build-system (emacs-package
;;                  :format "melpa"
;;                  :melpa-recipe "(my-fork :fetcher git :url \"https://github.com/me/magit-fork.git\" :files (\"lisp/*.el\"))")))

;; Variant pinning explicit :melpa-files to bypass the default
;; package-build glob spec:
;;
;; (pkg-define magit-tight
;;   (version "3.3.0")
;;   (source (github-fetch :owner "magit" :repo "magit"
;;                         :rev "v3.3.0" :sha256 "sha256-..."))
;;   (build-system (emacs-package
;;                  :format "melpa"
;;                  :melpa-files ("lisp/*.el" "lisp/magit-pkg.el"))))

(provide 'emacs-melpa-magit)
;;; emacs-melpa-magit.el ends here
