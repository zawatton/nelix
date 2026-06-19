;;; nelix-dsl.el --- Public Nelix DSL entry point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public entry point for Nelix package declarations and desired-state
;; manifests.  `nelix-define' / `nelix-render-nix' are compatibility aliases
;; for recipe work.  `nelix-environment' is the stable v1 user manifest DSL.

;;; Code:

(require 'anvil-pkg-dsl)
(require 'nelix-manifest)

;;;###autoload
(defun nelix-dsl-version ()
  "Return the stable public Nelix environment DSL version."
  nelix-environment-dsl-version)

;;;###autoload
(defalias 'nelix-define (symbol-function 'pkg-define))

;;;###autoload
(defalias 'nelix-render-nix #'anvil-pkg-render-nix)

(provide 'nelix-dsl)
;;; nelix-dsl.el ends here
