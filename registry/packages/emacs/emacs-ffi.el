;;; emacs-ffi.el --- Nelix recipe -*- lexical-binding: t; -*-

;; A C dynamic module, so unlike every other emacs recipe here it
;; compiles rather than just copying .el files.
;;
;; The DSL entry in nelix-package.el could never build it: its hash was
;; in SRI base64 while the native fetcher wants hex, and nothing supplied
;; ltdl.h.  Debian puts that header in libltdl-dev, which needs root, so
;; libtool is built from source as a Nelix package instead and reached
;; here through `nelix-input' -- the whole point being that a C library
;; dependency is resolvable without an OS package manager.
;;
;; The link line adds -rpath for libtool's store lib: store paths are
;; immutable, so recording one is safe, and without it `module-load'
;; fails at runtime with libltdl.so.7 not found.  libffi is not treated
;; this way because Debian ships its development symlink in the runtime
;; package.
;;
;; Provenance: the codeload tarball was fetched twice with identical
;; bytes and its contents compared file by file against a git checkout of
;; the pinned commit.

(require 'nelix-registry)

(nelix-package
 :name "emacs-ffi"
 :version "0.0.0"
 :class 'emacs-package
 :systems
 '((x86_64-linux
    :source (:type url
             :url "https://codeload.github.com/enometh/emacs-ffi/tar.gz/0227ba4e17ae98bf8d1ddd1477ac8894c371734e"
             :sha256 "sha256-1854e3b894b650f48c62ffc64255035645ca3d32221dde93785d6abe33d3dc94")
    :dependencies ("libtool")
    :install (:type build
              :build-system trivial
              :pname "emacs-ffi"
              :load-paths (".")
              :features (ffi)
              :build-phases
              ((unpack . (nelix-build-unpack-source-archive))
               (build
                . (let ((ltdl (nelix-input "libtool")))
                    ;; The upstream Makefile hardcodes the author's Emacs
                    ;; build tree for emacs-module.h and has no install
                    ;; target, so the compile is spelled out here.
                    (nelix-invoke
                     "gcc" "-shared" "-fPIC" "-O2"
                     "-I/usr/local/include" "-I/usr/include"
                     (concat "-I" ltdl "/include")
                     "-o" "ffi-module.so" "ffi-module.c"
                     (concat "-L" ltdl "/lib")
                     (concat "-Wl,-rpath," ltdl "/lib")
                     "-lffi" "-lltdl")))
               (install
                . (progn
                    (nelix-mkdir-p (nelix-out))
                    (nelix-copy-file "ffi.el"
                                     (expand-file-name "ffi.el" (nelix-out)))
                    (nelix-copy-file "ffi-module.so"
                                     (expand-file-name "ffi-module.so"
                                                       (nelix-out))))))))))

;;; emacs-ffi.el ends here
