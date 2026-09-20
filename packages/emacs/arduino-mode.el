;;; arduino-mode.el --- Nelix recipe -*- lexical-binding: t; -*-

;; Hand-written, not generated from flake.nix.  The nelix-package.el DSL
;; entry for this package is unusable: its hash is still
;; "sha256-PLACEHOLDER-fill-in-from-nix" and the rev it pins
;; (0df5a936...) is a TREE object, not a commit, so no fetcher can check
;; it out.  The rev below is upstream master, which is also the commit
;; the working ~/.emacs.d/external-packages copy sits on.
;;
;; This is the only recipe using (:type git).  repo.or.cz serves its
;; gitweb snapshot URLs behind an anti-bot challenge, so there is no
;; stable tarball to pin; the commit sha pins the content and the sha256
;; covers `git archive --format=tar' output, which was stable across two
;; runs here.  A different git version could in principle frame the tar
;; differently -- that fails the hash check loudly, it does not install
;; something else.

(require 'nelix-registry)

(nelix-package :name "arduino-mode" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type git :url "https://repo.or.cz/arduino-mode.git" :rev "b2ffd8441851659cb1cc844156073967729585e5" :sha256 "sha256-ec17c490c899292075685824ff3c4cbe666ef198fe8bd8cec45685d7be7645c8") :dependencies ("spinner" "flycheck") :install (:type build :build-system emacs-package :pname "arduino-mode" :load-paths (".") :features (arduino-mode))) (x86_64-windows :source (:type git :url "https://repo.or.cz/arduino-mode.git" :rev "b2ffd8441851659cb1cc844156073967729585e5" :sha256 "sha256-ec17c490c899292075685824ff3c4cbe666ef198fe8bd8cec45685d7be7645c8") :dependencies ("spinner" "flycheck") :install (:type build :build-system emacs-package :pname "arduino-mode" :load-paths (".") :features (arduino-mode)))))

;;; arduino-mode.el ends here
