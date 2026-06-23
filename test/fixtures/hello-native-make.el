;;; hello-native-make.el --- Make build-system preset smoke fixture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Registry-format recipe for the M2 smoke fixture
;; (docs/design/31-nelix-native-source-build-executor.org §8).
;;
;; Demonstrates :build-system 'make with NO explicit build or install phases.
;; Only an 'unpack phase is supplied; the 'configure (skip-guarded), 'build,
;; and 'install phases are driven entirely by the 'make preset in
;; `nelix-builder--build-system-presets'.
;;
;; The unpack phase writes:
;;   hello-make.c    — prints "nelix-native-make-build-ok\n"
;;   Makefile        — all: compiles hello-make; install: copies to $out/bin
;;
;; Used by `make smoke-native-build-make'.

;;; Code:

(require 'nelix-registry)

(nelix-package
 :name "hello-native-make"
 :version "1.0.0"
 :class 'source-build
 :description "Trivial C hello-world built via make preset without Nix (M2 smoke fixture)"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :install (:type build
              :build-system make
              :build-phases
              ((unpack . "printf '#include <stdio.h>\\nint main(){puts(\"nelix-native-make-build-ok\");return 0;}\\n' > hello-make.c && printf 'all:\\n\\tcc -O2 hello-make.c -o hello-make\\ninstall:\\n\\tmkdir -p $(PREFIX)/bin\\n\\tcp hello-make $(PREFIX)/bin/hello-make\\n' > Makefile"))
              :bin ("bin/hello-make")))
   (aarch64-linux
    :source (:type inline)
    :install (:type build
              :build-system make
              :build-phases
              ((unpack . "printf '#include <stdio.h>\\nint main(){puts(\"nelix-native-make-build-ok\");return 0;}\\n' > hello-make.c && printf 'all:\\n\\tcc -O2 hello-make.c -o hello-make\\ninstall:\\n\\tmkdir -p $(PREFIX)/bin\\n\\tcp hello-make $(PREFIX)/bin/hello-make\\n' > Makefile"))
              :bin ("bin/hello-make")))
   (x86_64-darwin
    :source (:type inline)
    :install (:type build
              :build-system make
              :build-phases
              ((unpack . "printf '#include <stdio.h>\\nint main(){puts(\"nelix-native-make-build-ok\");return 0;}\\n' > hello-make.c && printf 'all:\\n\\tcc -O2 hello-make.c -o hello-make\\ninstall:\\n\\tmkdir -p $(PREFIX)/bin\\n\\tcp hello-make $(PREFIX)/bin/hello-make\\n' > Makefile"))
              :bin ("bin/hello-make")))
   (aarch64-darwin
    :source (:type inline)
    :install (:type build
              :build-system make
              :build-phases
              ((unpack . "printf '#include <stdio.h>\\nint main(){puts(\"nelix-native-make-build-ok\");return 0;}\\n' > hello-make.c && printf 'all:\\n\\tcc -O2 hello-make.c -o hello-make\\ninstall:\\n\\tmkdir -p $(PREFIX)/bin\\n\\tcp hello-make $(PREFIX)/bin/hello-make\\n' > Makefile"))
              :bin ("bin/hello-make")))))

;;; hello-native-make.el ends here
