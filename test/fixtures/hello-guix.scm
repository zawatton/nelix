;; Guix Scheme recipe — end-to-end fixture for `make smoke-guix-to-native'.
;; A trivial C program built entirely through Guix-style #:phases, imported
;; by lisp-dialect-bridge (ldb-guix-import-native-string) into a native
;; nelix source-build recipe, then built by the nelix-native executor with
;; NO Nix.  The compiled binary exits 42 to prove it ran.
(define-public hello-guix
  (package
    (name "hello-guix")
    (version "1.0.0")
    (source #f)
    (build-system gnu-build-system)
    (synopsis "Guix to ldb to nelix end-to-end demo")
    (arguments
     (list #:phases
           (modify-phases %standard-phases
             (replace 'unpack
               (lambda* (#:key outputs #:allow-other-keys)
                 (invoke "sh" "-c" "printf 'int main(){return 42;}' > hello.c")))
             (replace 'configure
               (lambda* (#:key outputs #:allow-other-keys) #t))
             (replace 'build
               (lambda* (#:key outputs #:allow-other-keys)
                 (invoke "cc" "-O2" "hello.c" "-o" "hello")))
             (replace 'install
               (lambda* (#:key outputs #:allow-other-keys)
                 (invoke "sh" "-c" "mkdir -p $out/bin && cp hello $out/bin/hello-guix"))))))))
