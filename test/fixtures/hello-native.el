;;; hello-native.el --- Trivial C source-build fixture (no Nix) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Registry-format recipe for the M1 smoke fixture
;; (docs/design/31-nelix-native-source-build-executor.org).
;;
;; Compiles a trivial C program via the nelix-native executor without Nix.
;; Used by `make smoke-native-build'.

;;; Code:

(require 'nelix-registry)

(nelix-package
 :name "hello-native"
 :version "1.0.0"
 :class 'source-build
 :description "Trivial C hello-world built from source without Nix (M1 smoke fixture)"
 :systems
 '((x86_64-linux
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((unpack  . "printf '#include <stdio.h>\\nint main(){printf(\"nelix-native-build-ok\\\\n\");return 0;}\\n' > hello.c")
               (build   . "cc -O2 hello.c -o hello")
               (install . "mkdir -p \"$out/bin\" && cp hello \"$out/bin/hello\""))
              :bin ("bin/hello")))
   (aarch64-linux
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((unpack  . "printf '#include <stdio.h>\\nint main(){printf(\"nelix-native-build-ok\\\\n\");return 0;}\\n' > hello.c")
               (build   . "cc -O2 hello.c -o hello")
               (install . "mkdir -p \"$out/bin\" && cp hello \"$out/bin/hello\""))
              :bin ("bin/hello")))
   (x86_64-darwin
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((unpack  . "printf '#include <stdio.h>\\nint main(){printf(\"nelix-native-build-ok\\\\n\");return 0;}\\n' > hello.c")
               (build   . "cc -O2 hello.c -o hello")
               (install . "mkdir -p \"$out/bin\" && cp hello \"$out/bin/hello\""))
              :bin ("bin/hello")))
   (aarch64-darwin
    :source (:type inline)
    :install (:type build
              :build-system trivial
              :build-phases
              ((unpack  . "printf '#include <stdio.h>\\nint main(){printf(\"nelix-native-build-ok\\\\n\");return 0;}\\n' > hello.c")
               (build   . "cc -O2 hello.c -o hello")
               (install . "mkdir -p \"$out/bin\" && cp hello \"$out/bin/hello\""))
              :bin ("bin/hello")))))

;;; hello-native.el ends here
