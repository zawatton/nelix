;;; hello-sandbox-net.el --- Tier 2 network-denial negative fixture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A source-build recipe whose build phase tries to reach the network
;; (an HTTPS GET to a routable IP literal, no DNS).  Under Tier 2 the
;; build runs in a sandbox with the network namespace unshared, so the
;; connection has no route out and curl exits non-zero -> the phase fails
;; -> the build signals `nelix-error'.  `make smoke-sandbox-bwrap' asserts
;; that this build FAILS under tier2 (the negative assertion proving the
;; network namespace is real).  On the host (no sandbox) the same curl
;; succeeds, which the smoke checks as a control.

;;; Code:

(require 'nelix-registry)

(nelix-package
 :name "hello-sandbox-net"
 :version "1.0.0"
 :class 'source-build
 :description "Network-probe fixture: a build phase reaching the net (must FAIL under tier2)"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((probe . "curl -sS --max-time 5 -o /dev/null https://1.1.1.1/"))
              :bin ()))))

;;; hello-sandbox-net.el ends here
