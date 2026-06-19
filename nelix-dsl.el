;;; nelix-dsl.el --- Public Nelix DSL entry point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Compatibility entry point for the Nelix package declaration DSL.

;;; Code:

(require 'anvil-pkg-dsl)

;;;###autoload
(defalias 'nelix-define (symbol-function 'pkg-define))

;;;###autoload
(defalias 'nelix-render-nix #'anvil-pkg-render-nix)

(provide 'nelix-dsl)
;;; nelix-dsl.el ends here
