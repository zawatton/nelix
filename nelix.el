;;; nelix.el --- Public Nelix entry point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Nelix is the public name for the package-management surface that began as
;; anvil-pkg.  This file provides the new require/provide boundary while the
;; implementation modules keep their original names for compatibility.

;;; Code:

(require 'anvil-pkg)
(require 'nelix-manifest)
(require 'nelix-fast)
(require 'nelix-store)
(require 'nelix-registry)
(require 'nelix-fetch)
(require 'nelix-builder)
(require 'nelix-backend)
(require 'nelix-substitute)

(provide 'nelix)
;;; nelix.el ends here
