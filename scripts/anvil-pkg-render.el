;;; anvil-pkg-render.el --- Batch-mode flake renderer for smoke tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase 4-H helper.  Loads an `examples/<recipe>.el' file, renders
;; the registry into a `flake.nix' on disk, and exits.  Used by
;; `make smoke-eval' / `make smoke-build' to exercise the renderer
;; against a real Nix evaluator without depending on the public
;; `pkg-install' shell-out path (which would couple smoke testing
;; to nix daemon state).
;;
;; Usage from the command line:
;;
;;   emacs -Q --batch -L . -l scripts/anvil-pkg-render.el \
;;     --eval "(anvil-pkg-render-example \
;;                \"examples/stdenv-hello.el\" \
;;                \"/tmp/smoke/hello\")"
;;
;; Side effects: `<OUT-DIR>/flake.nix' is overwritten.
;; The registry is cleared before each call so successive invocations
;; in a single Emacs session do not accumulate cross-recipe state.

;;; Code:

(require 'anvil-pkg-dsl)

(defun anvil-pkg-render-example (example-file out-dir)
  "Render EXAMPLE-FILE's `pkg-define' forms into `OUT-DIR/flake.nix'.

EXAMPLE-FILE is a path to one of `examples/*.el' (or any file
that loads `anvil-pkg-dsl' and declares `pkg-define' forms).
OUT-DIR is created if missing.  Returns the absolute path to
the written flake.nix."
  (anvil-pkg--registry-clear)
  (load (expand-file-name example-file) nil :nomessage)
  (make-directory out-dir :parents)
  (let ((flake-path (expand-file-name "flake.nix" out-dir))
        (rendered (anvil-pkg--render-flake)))
    (with-temp-file flake-path
      (insert rendered))
    flake-path))

(provide 'anvil-pkg-render)
;;; anvil-pkg-render.el ends here
