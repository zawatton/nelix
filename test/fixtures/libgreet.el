;;; libgreet.el --- dependency fixture: writes a value marker -*- lexical-binding: t; -*-
;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; libgreet: a source-build package whose install phase writes the value "42"
;; into $out/value.  Used as a dependency fixture by useapp in smoke-deps-inputs.
;; Verifies the bottom-up build ordering: libgreet must be fully installed before
;; useapp's build phase can call (nelix-input "libgreet").
;;; Code:
(require 'nelix-registry)
(nelix-package
 :name "libgreet"
 :version "1.0.0"
 :class 'source-build
 :description "libgreet: writes 42 into $out/value (dependency fixture)"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((install . (progn
                            (nelix-mkdir-p (nelix-out))
                            (write-region "42" nil (concat (nelix-out) "/value")))))
              :bin ()))))
;;; libgreet.el ends here
