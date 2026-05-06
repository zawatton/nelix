;;; private-github.el --- Private repo with env-var credentials -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase 4-G: install from a *private* GitHub repository by exporting
;; a GITHUB_TOKEN (or GH_TOKEN) before invoking `pkg-install'.  The
;; DSL form is *identical* to a public-repo recipe — only the env
;; var changes.
;;
;; Workflow:
;;
;;   $ export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
;;   $ emacs -Q -l examples/private-github.el
;;   M-: (pkg-install 'my-private-tool)
;;
;; What anvil-pkg does on your behalf when GITHUB_TOKEN is set:
;;
;;   1. L18 deps pre-fetch — `Authorization: Bearer $TOKEN' header is
;;      added to the raw.githubusercontent.com scrape (same path that
;;      reads `<pname>-pkg.el' / `<pname>.el' for Emacs packages, and
;;      the tarball download for url-fetch sources).
;;   2. git-fetch HTTPS clones — `git -c http.<host>/.extraheader=...'
;;      is prepended so `git clone --depth 1` authenticates.  SSH
;;      URLs (`git@host:owner/repo`) skip this and rely on your SSH
;;      agent as before.
;;   3. Nix build — `--option extra-access-tokens "github.com=$TOKEN"'
;;      is injected into every `nix profile install/add' / `eval' /
;;      `build' invocation so Nix's own fetcher (`fetchFromGitHub',
;;      `fetchTarball', `fetchgit') reaches the private repo.
;;
;; *Where the token is and is not visible:*
;;
;;   - Stored in your shell environment only (no on-disk persistence).
;;   - Never written to `anvil-pkg-state' (state.json), worklog
;;     entries, or any of anvil-pkg's own log lines (those run through
;;     `anvil-pkg-compat-mask-credentials').
;;   - VISIBLE to `ps aux' for the duration of the `nix' / `git'
;;     subprocess — both tools accept the credential on the CLI and
;;     anvil-pkg cannot hide that.  Document this in your threat
;;     model; on a single-user machine it is rarely an issue, on a
;;     shared host consider a Nix daemon `access-tokens.conf' or a
;;     `GIT_ASKPASS' shim instead.
;;
;; *Default credential alist* (see
;; `anvil-pkg-compat-credential-env-alist'):
;;
;;   github.com / raw.githubusercontent.com / api.github.com /
;;   codeload.github.com / objects.githubusercontent.com   ← GITHUB_TOKEN, GH_TOKEN
;;   gitlab.com                                            ← GITLAB_TOKEN
;;   codeberg.org                                          ← CODEBERG_TOKEN
;;
;; Add custom hosts (corporate GitHub Enterprise etc.) by extending
;; the alist before invoking `pkg-install':
;;
;;   (add-to-list 'anvil-pkg-compat-credential-env-alist
;;                '("ghe.example.com" . ("GHE_TOKEN")))

;;; Code:

(require 'anvil-pkg-dsl)

;; Example 1: a private GitHub repo via github-fetch.  Replace owner /
;; repo / rev / sha256 with your real values.  The SHA256 for a
;; private repo is the same as any other github-fetch — supply the
;; tarball hash (Nix will fail loudly if it is wrong).
(pkg-define my-private-tool
  (version "0.1.0")
  (source (github-fetch :owner "your-org"
                        :repo "private-tool"
                        :rev "v0.1.0"
                        :sha256 "sha256-PLACEHOLDER"))
  (build-system (rust :cargo-sha256 "sha256-PLACEHOLDER"))
  (description "An internal CLI tool from a private repository.")
  (homepage "https://github.com/your-org/private-tool")
  (license mit))

;; Example 2: a private repo via git-fetch over HTTPS.  Same pattern;
;; anvil-pkg auto-injects `-c http.https://github.com/.extraheader=...'
;; when GITHUB_TOKEN is set.
(pkg-define my-private-helper
  (version "1.2.3")
  (source (git-fetch :url "https://github.com/your-org/helper.git"
                     :rev "v1.2.3"
                     :sha256 "sha256-PLACEHOLDER"))
  (build-system (go :vendor-sha256 "sha256-PLACEHOLDER"))
  (description "Internal Go helper from a private repository.")
  (homepage "https://github.com/your-org/helper")
  (license apache2))

;; Example 3: same package, but switching to SSH so the token is not
;; needed at all (SSH agent / ~/.ssh/ keys handle auth out-of-band).
;; Useful when you are happy with `ssh-add' but do not want a long-
;; lived PAT.
;;
;; (pkg-define my-private-helper-ssh
;;   (version "1.2.3")
;;   (source (git-fetch :url "git@github.com:your-org/helper.git"
;;                      :rev "v1.2.3"
;;                      :sha256 "sha256-PLACEHOLDER"))
;;   (build-system (go :vendor-sha256 "sha256-PLACEHOLDER"))
;;   (description "Internal Go helper, SSH variant.")
;;   (homepage "https://github.com/your-org/helper")
;;   (license apache2))

;; To install:
;;   M-: (pkg-install 'my-private-tool)
;;
;; If GITHUB_TOKEN is unset, you will see the public-repo error
;; message ("Repository not found") — that is the loud failure mode.
;;
;; To inspect what anvil-pkg would forward to git / nix without
;; leaking the token:
;;   M-: (anvil-pkg-compat-mask-credentials
;;        (mapconcat #'identity
;;                   (cons "git"
;;                         (anvil-pkg-emacs--git-credential-args
;;                          "https://github.com/your-org/private-tool"))
;;                   " "))
;;   ⇒ "git -c http.https://github.com/.extraheader=Authorization: Bearer ***"

(provide 'private-github)
;;; private-github.el ends here
