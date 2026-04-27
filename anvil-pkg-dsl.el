;;; anvil-pkg-dsl.el --- DSL macro + registry + Nix renderer for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (anvil-pkg "0.1.0"))
;; Keywords: tools, packages, nix

;; This file is part of anvil-pkg.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Phase 2 of anvil-pkg.  Provides a Guix-style declarative DSL on top
;; of the Phase 1 nix profile shell-out wrapper.
;;
;;   (pkg-define my-ripgrep
;;     (version "13.0.0")
;;     (source (url-fetch "https://..." :sha256 "sha256-..."))
;;     (build-system stdenv)
;;     (inputs (list pkg-config openssl))
;;     (install-phase "make install PREFIX=$out"))
;;
;;   (pkg-install 'my-ripgrep)
;;
;; This file owns:
;;   - `pkg-define' macro + sub-form parser (errors fire at byte-compile)
;;   - `anvil-pkg--registry' hash-table (SYMBOL -> IR plist)
;;   - `anvil-pkg-render-nix' pure renderer (IR -> Nix derivation string)
;;   - `anvil-pkg--render-flake' (registry -> flake.nix string)
;;   - `anvil-pkg--install-symbol' (lookup -> write -> install)
;;
;; Design doc: docs/design/02-dsl.org.

;;; Code:

(require 'anvil-pkg)
(require 'subr-x)

(declare-function anvil-pkg--ensure-nix "anvil-pkg")
(declare-function anvil-pkg--call-nix "anvil-pkg")
(declare-function anvil-pkg--profile-args "anvil-pkg")

;;;; --- error symbols ---------------------------------------------------------

(define-error 'anvil-pkg-dsl-error
              "anvil-pkg DSL error" 'anvil-pkg-error)
(define-error 'anvil-pkg-undefined-package
              "Symbol not registered via pkg-define" 'anvil-pkg-error)

;;;; --- registry --------------------------------------------------------------

(defvar anvil-pkg--registry (make-hash-table :test 'eq)
  "Symbol -> IR plist for packages declared via `pkg-define'.")

(defun anvil-pkg--register (name ir)
  "Store IR under NAME in the registry, warn on redefinition."
  (when (gethash name anvil-pkg--registry)
    (lwarn 'anvil-pkg :warning "redefining package %s" name))
  (puthash name ir anvil-pkg--registry)
  name)

(defun anvil-pkg--registry-get (name)
  "Return IR for NAME or signal `anvil-pkg-undefined-package'."
  (or (gethash name anvil-pkg--registry)
      (signal 'anvil-pkg-undefined-package
              (list (format "%s not defined; use pkg-define to declare it"
                            name)))))

(defun anvil-pkg--registry-clear ()
  "Empty the registry.  Test helper."
  (clrhash anvil-pkg--registry))

;;;; --- parser (macro-time) --------------------------------------------------

(defconst anvil-pkg--known-keywords
  '(version source build-system inputs native-inputs
            install-phase build-phase description homepage license)
  "Sub-form keywords accepted inside `pkg-define'.")

(defun anvil-pkg--parse-define (name body)
  "Parse pkg-define BODY into IR plist.  Runs at macro-expand time."
  (let ((ir (list :name name
                  :build-system 'stdenv
                  :inputs nil
                  :native-inputs nil)))
    (dolist (form body)
      (unless (and (consp form) (symbolp (car form)))
        (signal 'anvil-pkg-dsl-error
                (list (format "pkg-define %s: malformed sub-form %S"
                              name form))))
      (let ((key (car form))
            (val (cdr form)))
        (unless (memq key anvil-pkg--known-keywords)
          (signal 'anvil-pkg-dsl-error
                  (list (format "pkg-define %s: unknown keyword %S; expected one of %S"
                                name key anvil-pkg--known-keywords))))
        (setq ir (plist-put ir
                            (intern (concat ":" (symbol-name key)))
                            (anvil-pkg--parse-value name key val)))))
    (unless (plist-get ir :version)
      (signal 'anvil-pkg-dsl-error
              (list (format "pkg-define %s: missing required (version ...)"
                            name))))
    (unless (plist-get ir :source)
      (signal 'anvil-pkg-dsl-error
              (list (format "pkg-define %s: missing required (source ...)"
                            name))))
    ir))

(defun anvil-pkg--parse-value (name key val)
  "Coerce sub-form VAL based on KEY into IR shape."
  (pcase key
    ('source (anvil-pkg--parse-source name (car val)))
    ((or 'inputs 'native-inputs)
     (anvil-pkg--parse-input-list (car val)))
    ('build-system
     (let ((sym (car val)))
       (cond
        ((eq sym 'stdenv) sym)
        (t (signal 'anvil-pkg-dsl-error
                   (list (format "pkg-define %s: build-system %S not yet supported (Phase 2 = stdenv only)"
                                 name sym)))))))
    (_ (car val))))

(defun anvil-pkg--parse-source (name form)
  "Parse a source-form into source IR plist."
  (unless (and (consp form) (symbolp (car form)))
    (signal 'anvil-pkg-dsl-error
            (list (format "pkg-define %s: source must be a fetcher form, got %S"
                          name form))))
  (pcase (car form)
    ('url-fetch
     (let* ((url (cadr form))
            (rest (cddr form))
            (sha256 (plist-get rest :sha256)))
       (unless (stringp url)
         (signal 'anvil-pkg-dsl-error
                 (list (format "pkg-define %s: url-fetch URL must be a string, got %S"
                               name url))))
       (unless (stringp sha256)
         (signal 'anvil-pkg-dsl-error
                 (list (format "pkg-define %s: url-fetch missing :sha256"
                               name))))
       (list :type 'url-fetch :url url :sha256 sha256)))
    (_ (signal 'anvil-pkg-dsl-error
               (list (format "pkg-define %s: unsupported source fetcher %S (Phase 2 = url-fetch only)"
                             name (car form)))))))

(defun anvil-pkg--parse-input-list (form)
  "Coerce FORM into a flat list of nixpkgs attribute symbols.

Accepts (list S1 S2 ...), \\='(S1 S2 ...) or a literal (S1 S2 ...)."
  (cond
   ((null form) nil)
   ((and (consp form) (eq (car form) 'list)) (cdr form))
   ((and (consp form) (eq (car form) 'quote)) (cadr form))
   ((listp form) form)
   (t (signal 'anvil-pkg-dsl-error
              (list (format "inputs: expected list of symbols, got %S"
                            form))))))

;;;; --- macro -----------------------------------------------------------------

;;;###autoload
(defmacro pkg-define (name &rest body)
  "Declare a package NAME from a Guix-style record BODY.

BODY is a list of sub-forms whose head is a recognised keyword.
Required: (version STRING), (source (url-fetch URL :sha256 HASH)).
Optional: build-system (default `stdenv'), inputs, native-inputs,
install-phase, build-phase, description, homepage, license.

The macro parses BODY into an internal IR plist at macroexpand
time, so unknown keywords / type errors fire at byte-compile.  At
load time the IR is registered under NAME and NAME is returned."
  (declare (indent 1))
  (let ((ir (anvil-pkg--parse-define name body)))
    `(progn
       (anvil-pkg--register ',name ',ir)
       ',name)))

;;;; --- renderer (pure, no I/O) ----------------------------------------------

(defun anvil-pkg-render-nix (ir)
  "Render IR plist into a single Nix derivation expression string.
Pure function — same input always yields the same output."
  (unless (eq 'stdenv (plist-get ir :build-system))
    (signal 'anvil-pkg-dsl-error
            (list (format "render: build-system %S not yet supported"
                          (plist-get ir :build-system)))))
  (let* ((name (plist-get ir :name))
         (version (plist-get ir :version))
         (source (plist-get ir :source))
         (inputs (plist-get ir :inputs))
         (native-inputs (plist-get ir :native-inputs))
         (install-phase (plist-get ir :install-phase))
         (build-phase (plist-get ir :build-phase))
         (description (plist-get ir :description))
         (homepage (plist-get ir :homepage))
         (license (plist-get ir :license))
         (parts '()))
    (push (format "  pname = %S;" (symbol-name name)) parts)
    (push (format "  version = %S;" version) parts)
    (push (format "  src = %s;" (anvil-pkg--render-source source)) parts)
    (when inputs
      (push (format "  buildInputs = with pkgs; [ %s ];"
                    (mapconcat #'symbol-name inputs " "))
            parts))
    (when native-inputs
      (push (format "  nativeBuildInputs = with pkgs; [ %s ];"
                    (mapconcat #'symbol-name native-inputs " "))
            parts))
    (when build-phase
      (push (format "  buildPhase = ''\n%s\n  '';"
                    (anvil-pkg--indent-each-line build-phase 4))
            parts))
    (when install-phase
      (push (format "  installPhase = ''\n%s\n  '';"
                    (anvil-pkg--indent-each-line install-phase 4))
            parts))
    (when (or description homepage license)
      (let ((meta-parts '()))
        (when description
          (push (format "    description = %S;" description) meta-parts))
        (when homepage
          (push (format "    homepage = %S;" homepage) meta-parts))
        (when license
          (push (format "    license = %s;"
                        (anvil-pkg--render-license license))
                meta-parts))
        (push (concat "  meta = {\n"
                      (mapconcat #'identity (nreverse meta-parts) "\n")
                      "\n  };")
              parts)))
    (concat "pkgs.stdenv.mkDerivation {\n"
            (mapconcat #'identity (nreverse parts) "\n")
            "\n}")))

(defun anvil-pkg--render-source (src)
  "Render a source IR plist into a Nix fetcher expression."
  (pcase (plist-get src :type)
    ('url-fetch
     (format "pkgs.fetchurl {\n    url = %S;\n    sha256 = %S;\n  }"
             (plist-get src :url)
             (plist-get src :sha256)))
    (_ (signal 'anvil-pkg-dsl-error
               (list (format "render: unsupported source type %S"
                             (plist-get src :type)))))))

(defconst anvil-pkg--license-map
  '((mit     . "pkgs.lib.licenses.mit")
    (gpl2    . "pkgs.lib.licenses.gpl2")
    (gpl3    . "pkgs.lib.licenses.gpl3")
    (bsd2    . "pkgs.lib.licenses.bsd2")
    (bsd3    . "pkgs.lib.licenses.bsd3")
    (apache2 . "pkgs.lib.licenses.asl20"))
  "Phase 2 license symbol -> Nix expression.
Unknown symbols fall back to a quoted string literal.")

(defun anvil-pkg--render-license (sym)
  "Render a license symbol into a Nix expression."
  (or (alist-get sym anvil-pkg--license-map)
      (format "%S" (symbol-name sym))))

(defun anvil-pkg--indent-each-line (s n)
  "Prepend N spaces to every line of S."
  (let ((prefix (make-string n ?\s)))
    (mapconcat (lambda (l) (concat prefix l))
               (split-string s "\n")
               "\n")))

(defun anvil-pkg--shift-tail-lines (s n)
  "Indent line 2..end of S by N spaces; line 1 is unchanged."
  (let* ((lines (split-string s "\n"))
         (head (car lines))
         (tail (cdr lines))
         (prefix (make-string n ?\s)))
    (if (null tail)
        head
      (concat head
              "\n"
              (mapconcat (lambda (l) (concat prefix l)) tail "\n")))))

(defun anvil-pkg--render-flake ()
  "Render the entire registry into a flake.nix string."
  (let (entries)
    (maphash (lambda (k v) (push (cons k v) entries)) anvil-pkg--registry)
    (setq entries (sort entries (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b))))))
    (concat
     "{\n"
     "  description = \"anvil-pkg generated flake\";\n"
     "  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixpkgs-unstable\";\n"
     "  outputs = { self, nixpkgs }: {\n"
     "    packages.x86_64-linux = let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {\n"
     (mapconcat (lambda (entry)
                  (let* ((sym (car entry))
                         (ir (cdr entry))
                         (drv (anvil-pkg-render-nix ir)))
                    (format "      %s = %s;\n"
                            (symbol-name sym)
                            (anvil-pkg--shift-tail-lines drv 6))))
                entries
                "")
     "    };\n"
     "  };\n"
     "}\n")))

;;;; --- flake.nix writer (overridable for tests) -----------------------------

(defvar anvil-pkg--write-flake-fn #'anvil-pkg--write-flake-default
  "Function used to materialise flake.nix.  Override in tests.

Called with no arguments.  Must return the absolute path to the
flake.nix file it wrote.")

(defun anvil-pkg--state-dir ()
  "Return the directory holding flake.nix (parent of profile dir)."
  (file-name-directory
   (directory-file-name (expand-file-name anvil-pkg-profile-dir))))

(defun anvil-pkg--flake-path ()
  "Absolute path to the generated flake.nix."
  (expand-file-name "flake.nix" (anvil-pkg--state-dir)))

(defun anvil-pkg--write-flake-default ()
  "Render the registry into flake.nix on disk.  Returns the path."
  (let ((file (anvil-pkg--flake-path)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (anvil-pkg--render-flake)))
    file))

;;;; --- symbol install path --------------------------------------------------

(defun anvil-pkg--install-symbol (sym)
  "Install a registry-defined SYM via flake.nix dispatch.

Path: registry lookup -> regenerate flake.nix -> nix profile
install path:STATE_DIR#SYM."
  (anvil-pkg--ensure-nix)
  (anvil-pkg--registry-get sym)
  (let* ((flake-path (funcall anvil-pkg--write-flake-fn))
         (flake-dir (directory-file-name (file-name-directory flake-path)))
         (flakeref (format "path:%s#%s" flake-dir sym))
         (args (append (list "profile" "install")
                       (anvil-pkg--profile-args)
                       (list flakeref)))
         (res (anvil-pkg--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            sym
                            (plist-get res :exit)
                            (string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

(provide 'anvil-pkg-dsl)
;;; anvil-pkg-dsl.el ends here
