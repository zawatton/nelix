;;; nelix-import.el --- Public Nelix import helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public Nelix aliases for migration/import helpers.

;;; Code:

(require 'anvil-pkg-import)

;;;###autoload
(defalias 'nelix-import-async-installer
  #'anvil-pkg-import-async-installer)

;;;###autoload
(defalias 'nelix-import-default-clone-dir
  #'anvil-pkg-import-default-clone-dir)

(provide 'nelix-import)
;;; nelix-import.el ends here
