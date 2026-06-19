;;; nelix-emacs.el --- Public Nelix Emacs-package helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public Nelix aliases for Emacs-package helper APIs.

;;; Code:

(require 'anvil-pkg-emacs)

(defvaralias 'nelix-emacs-cache-ttl-seconds
  'anvil-pkg-emacs-cache-ttl-seconds)
(defvaralias 'nelix-emacs-http-timeout
  'anvil-pkg-emacs-http-timeout)
(defvaralias 'nelix-emacs-tarball-timeout
  'anvil-pkg-emacs-tarball-timeout)
(defvaralias 'nelix-emacs-tarball-max-bytes
  'anvil-pkg-emacs-tarball-max-bytes)
(defvaralias 'nelix-emacs-git-clone-timeout
  'anvil-pkg-emacs-git-clone-timeout)
(defvaralias 'nelix-emacs-melpa-upstream-fetch
  'anvil-pkg-emacs-melpa-upstream-fetch)
(defvaralias 'nelix-emacs-melpa-recipe-ttl-seconds
  'anvil-pkg-emacs-melpa-recipe-ttl-seconds)

;;;###autoload
(defalias 'nelix-emacs-fetch-melpa-recipe
  #'anvil-pkg-emacs-fetch-melpa-recipe)
;;;###autoload
(defalias 'nelix-emacs-clear-melpa-recipe-cache
  #'anvil-pkg-emacs-clear-melpa-recipe-cache)
;;;###autoload
(defalias 'nelix-emacs-clear-cache
  #'anvil-pkg-emacs-clear-cache)
;;;###autoload
(defalias 'nelix-emacs-derive-deps
  #'anvil-pkg-emacs-derive-deps)
;;;###autoload
(defalias 'nelix-emacs-derive-deps-from-dir
  #'anvil-pkg-emacs-derive-deps-from-dir)

(provide 'nelix-emacs)
;;; nelix-emacs.el ends here
