;; M4 end-to-end fixture for `make smoke-guix-to-native-rich'.
;; Exercises the broadened ldb Guix phase-body translation through the real
;; nelix executor: substitute* (patches return 7 -> 42), a multi-statement
;; build phase, install-file + string-append + (assoc-ref outputs "out").
;; The compiled binary exits 42 ONLY if substitute* ran before build and
;; install-file placed it under the expanded $out — a runtime proof, not a
;; string match.
(define-public hello-guix
  (package
    (name "hello-guix")
    (version "1.0.0")
    (source #f)
    (build-system gnu-build-system)
    (synopsis "M4 rich recipe: substitute* + install-file + string-append + assoc-ref")
    (arguments
     (list #:phases
           (modify-phases %standard-phases
             (replace 'unpack
               (lambda* (#:key outputs #:allow-other-keys)
                 (invoke "sh" "-c" "printf 'int main(){return 7;}' > hello.c")))
             (replace 'configure
               (lambda* (#:key outputs #:allow-other-keys) #t))
             (replace 'build
               (lambda* (#:key outputs #:allow-other-keys)
                 (substitute* "hello.c"
                   (("return 7") "return 42"))
                 (invoke "cc" "-O2" "hello.c" "-o" "hello-guix")))
             (replace 'install
               (lambda* (#:key outputs #:allow-other-keys)
                 (install-file "hello-guix"
                               (string-append (assoc-ref outputs "out") "/bin")))))))))
