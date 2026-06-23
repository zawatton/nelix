;;; guix-to-native-driver.el --- Guix -> ldb -> nelix executor driver -*- lexical-binding: t; -*-
;; Used by `make smoke-guix-to-native'.  Reads a Guix .scm recipe path from
;; the GUIX_RECIPE env var, imports it to a native nelix source-build recipe
;; via ldb-guix-import-native-string, registers + installs it through the
;; nelix-native executor (no Nix), and prints the install report.
;; Requires ldb-guix-importer on load-path (LDB_DIR) + nelix on load-path.
;;; Code:
(require 'nelix-builder)
(require 'nelix-registry)
(require 'ldb-guix-importer)

(let* ((scm-path (or (getenv "GUIX_RECIPE")
                     (error "guix-to-native-driver: set GUIX_RECIPE")))
       (scm (with-temp-buffer (insert-file-contents scm-path) (buffer-string)))
       (native (ldb-guix-import-native-string scm 'hello-guix))
       (recipe-file (expand-file-name "hello-guix-native.el" temporary-file-directory)))
  (message "=== NATIVE RECIPE (ldb-translated from Guix) ===\n%S" native)
  (with-temp-file recipe-file
    (insert ";;; -*- lexical-binding: t; -*-\n(require 'nelix-registry)\n")
    (prin1 native (current-buffer))
    (insert "\n"))
  (nelix-registry--load-file recipe-file)
  (let* ((recipe (nelix-registry-get "hello-guix"))
         (report (nelix-native-install-recipe recipe "default" 'x86_64-linux)))
    (message "=== INSTALL REPORT ===\n%S" report)
    (message "GUIX-TO-NATIVE-STORE-PATH=%s" (plist-get report :store-path))))

(provide 'guix-to-native-driver)
;;; guix-to-native-driver.el ends here
