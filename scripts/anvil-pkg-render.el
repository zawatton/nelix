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

(defun anvil-pkg-render--registry-empty-p ()
  "Return non-nil when the current render registry has no packages."
  (let ((empty t))
    (maphash (lambda (_name _ir)
               (setq empty nil))
             anvil-pkg--registry)
    empty))

(defun anvil-pkg-render--load-example (example-file)
  "Load EXAMPLE-FILE into a clean registry.

Signals an error if the file registers no packages."
  (anvil-pkg--registry-clear)
  (load (expand-file-name example-file) nil :nomessage)
  (when (anvil-pkg-render--registry-empty-p)
    (error "no packages registered by %s" example-file)))

(defun anvil-pkg-render--registered-p (name)
  "Return non-nil when package NAME is present in the render registry.

NAME may be a symbol or a string naming a symbol."
  (gethash (if (symbolp name) name (intern name))
           anvil-pkg--registry))

(defun anvil-pkg-render-example (example-file out-dir)
  "Render EXAMPLE-FILE's `pkg-define' forms into `OUT-DIR/flake.nix'.

EXAMPLE-FILE is a path to one of `examples/*.el' (or any file
that loads `anvil-pkg-dsl' and declares `pkg-define' forms).
OUT-DIR is created if missing.  Returns the absolute path to
the written flake.nix.  Signals an error if EXAMPLE-FILE registers no
packages."
  (anvil-pkg-render--load-example example-file)
  (make-directory out-dir :parents)
  (let ((flake-path (expand-file-name "flake.nix" out-dir))
        (rendered (anvil-pkg--render-flake)))
    (with-temp-file flake-path
      (insert rendered))
    flake-path))

(defun anvil-pkg-render-example-attr (example-file attr out-dir)
  "Render EXAMPLE-FILE to OUT-DIR after validating ATTR is registered.

This is the no-Nix guard used by `make smoke-pairs-check': it catches
stale smoke metadata where `example-file:attr' points at an existing
example file but the recipe no longer defines that package."
  (anvil-pkg-render--load-example example-file)
  (unless (anvil-pkg-render--registered-p attr)
    (error "%s does not register package attr %s" example-file attr))
  (make-directory out-dir :parents)
  (let ((flake-path (expand-file-name "flake.nix" out-dir))
        (rendered (anvil-pkg--render-flake)))
    (with-temp-file flake-path
      (insert rendered))
    flake-path))

(defun anvil-pkg-render-example-attr-batch (example-file attr out-dir)
  "Batch entry point for `anvil-pkg-render-example-attr'.

On error, print one concise line and exit with status 1 instead of
letting batch Emacs dump a full backtrace into CI logs."
  (condition-case err
      (anvil-pkg-render-example-attr example-file attr out-dir)
    (error
     (message "error: %s" (error-message-string err))
     (kill-emacs 1))))

(provide 'anvil-pkg-render)
;;; anvil-pkg-render.el ends here
