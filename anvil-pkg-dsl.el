;;; anvil-pkg-dsl.el --- DSL macro + registry + Nix renderer for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (anvil-pkg "0.1.0"))
;; Keywords: tools, packages, nix

;; This file is part of anvil-pkg.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Phase 2 + 3 of anvil-pkg.  Provides a Guix-style declarative DSL
;; on top of the Phase 1 nix profile shell-out wrapper.
;;
;;   (pkg-define my-ripgrep
;;     (version "13.0.0")
;;     (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
;;                           :rev "13.0.0" :sha256 "sha256-..."))
;;     (build-system (rust :cargo-sha256 "sha256-..."))
;;     (inputs (list pkg-config openssl)))
;;
;;   (pkg-install 'my-ripgrep)
;;
;; Phase 3 (this file) ships:
;;   - source types: url-fetch (Phase 2), github-fetch, git-fetch
;;   - build systems: stdenv (Phase 2), rust, python, go
;;   - build-system IR upgraded to plist `(:type SYM ...args)' so each
;;     build system can carry its own required fields (e.g. cargo-sha256
;;     for rust, vendor-sha256 for go, format for python).
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
(require 'anvil-pkg-compat)

(declare-function anvil-pkg--ensure-nix "anvil-pkg")
(declare-function anvil-pkg--call-nix "anvil-pkg")
(declare-function anvil-pkg--profile-args "anvil-pkg")
(declare-function anvil-pkg--nix-install-subcommand "anvil-pkg")

;;;; --- error symbols ---------------------------------------------------------

(anvil-pkg-compat-define-error-symbol 'anvil-pkg-dsl-error
                                      "anvil-pkg DSL error"
                                      'anvil-pkg-error)
(anvil-pkg-compat-define-error-symbol 'anvil-pkg-undefined-package
                                      "Symbol not registered via pkg-define"
                                      'anvil-pkg-error)

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
            install-phase build-phase depends-on
            description homepage license)
  "Sub-form keywords accepted inside `pkg-define'.")

(defun anvil-pkg--parse-define (name body)
  "Parse pkg-define BODY into IR plist.  Runs at macro-expand time."
  (let ((ir (list :name name
                  :build-system (list :type 'stdenv)
                  :inputs nil
                  :native-inputs nil
                  :depends-on nil)))
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
    (anvil-pkg--validate-ir name ir)
    ir))

(defun anvil-pkg--parse-value (name key val)
  "Coerce sub-form VAL based on KEY into IR shape."
  (pcase key
    ('source (anvil-pkg--parse-source name (car val)))
    ((or 'inputs 'native-inputs 'depends-on)
     (anvil-pkg--parse-input-list (car val)))
    ('build-system (anvil-pkg--parse-build-system name (car val)))
    (_ (car val))))

(defconst anvil-pkg--known-build-systems
  '(stdenv rust python go emacs-package)
  "Build-system symbols supported by the DSL.")

(defun anvil-pkg--parse-build-system (name form)
  "Parse a build-system FORM into a plist `(:type SYM ...args)'.

Accepts:
  (build-system stdenv)              ; symbol form, no args
  (build-system (rust :cargo-sha256 \"...\"))
  (build-system (python :format \"pyproject\"))
  (build-system (go :vendor-sha256 \"...\"))"
  (cond
   ((symbolp form)
    (anvil-pkg--validate-build-system name form nil)
    (list :type form))
   ((and (consp form) (symbolp (car form)))
    (let ((type (car form))
          (args (cdr form)))
      (anvil-pkg--validate-build-system name type args)
      (apply #'list :type type args)))
   (t (signal 'anvil-pkg-dsl-error
              (list (format "pkg-define %s: build-system must be SYMBOL or (SYMBOL :args...), got %S"
                            name form))))))

(defun anvil-pkg--validate-build-system (name type args)
  "Validate that build-system TYPE is supported and required ARGS are present."
  (unless (memq type anvil-pkg--known-build-systems)
    (signal 'anvil-pkg-dsl-error
            (list (format "pkg-define %s: build-system %S not yet supported (supported: %S)"
                          name type anvil-pkg--known-build-systems))))
  (pcase type
    ('rust
     (unless (plist-get args :cargo-sha256)
       (signal 'anvil-pkg-dsl-error
               (list (format "pkg-define %s: rust build-system requires :cargo-sha256"
                             name))))
     (anvil-pkg--reject-non-emacs-package-args name type args))
    ('emacs-package
     (anvil-pkg--validate-emacs-package-args name args))
    ;; python: :format optional (defaults to setuptools)
    ;; go: :vendor-sha256 optional (defaults to vendorHash = null)
    ;; stdenv: no required args
    ;; All non-emacs-package types reject :native-comp (L13).
    (_
     (anvil-pkg--reject-non-emacs-package-args name type args))))

(defun anvil-pkg--reject-non-emacs-package-args (name type args)
  "Signal when ARGS carry emacs-package-only keys on non-emacs TYPE.
Currently catches :native-comp (Phase 4-B L13 reject)."
  (when (anvil-pkg--plist-has-key-p args :native-comp)
    (signal 'anvil-pkg-dsl-error
            (list (format "pkg-define %s: :native-comp is only valid on emacs-package build-system, not %S"
                          name type)))))

(defun anvil-pkg--validate-emacs-package-args (name args)
  "Validate :format and :native-comp for the emacs-package build-system.
Phase 4-B L13/L14: :format must be \"trivial\" or \"melpa\";
:native-comp must be t or nil when supplied."
  (let ((fmt (plist-get args :format)))
    (when fmt
      (unless (member fmt '("trivial" "melpa"))
        (signal 'anvil-pkg-dsl-error
                (list (format "pkg-define %s: emacs-package :format must be \"trivial\" or \"melpa\", got %S"
                              name fmt))))))
  (when (anvil-pkg--plist-has-key-p args :native-comp)
    (let ((nc (plist-get args :native-comp)))
      (unless (booleanp nc)
        (signal 'anvil-pkg-dsl-error
                (list (format "pkg-define %s: emacs-package :native-comp must be t or nil, got %S"
                              name nc)))))))

(defun anvil-pkg--validate-ir (name ir)
  "Validate cross-field constraints for package NAME and parsed IR."
  (let ((build-system-type (plist-get (plist-get ir :build-system) :type)))
    (when (eq build-system-type 'emacs-package)
      (when (plist-get ir :install-phase)
        (signal 'anvil-pkg-dsl-error
                (list (format "pkg-define %s: install-phase is not supported with build-system emacs-package"
                              name))))
      (when (plist-get ir :build-phase)
        (signal 'anvil-pkg-dsl-error
                (list (format "pkg-define %s: build-phase is not supported with build-system emacs-package"
                              name)))))))

(defun anvil-pkg--parse-source (name form)
  "Parse a source-form into source IR plist.

Phase 3 fetchers:
  (url-fetch URL :sha256 HASH)
  (github-fetch :owner OWNER :repo REPO :rev REV :sha256 HASH)
  (git-fetch :url URL :rev REV :sha256 HASH)"
  (unless (and (consp form) (symbolp (car form)))
    (signal 'anvil-pkg-dsl-error
            (list (format "pkg-define %s: source must be a fetcher form, got %S"
                          name form))))
  (pcase (car form)
    ('url-fetch
     (let* ((url (cadr form))
            (rest (cddr form))
            (sha256 (plist-get rest :sha256)))
       (anvil-pkg--require-string name "url-fetch URL" url)
       (anvil-pkg--require-string name "url-fetch :sha256" sha256)
       (list :type 'url-fetch :url url :sha256 sha256)))
    ('github-fetch
     (let* ((args (cdr form))
            (owner (plist-get args :owner))
            (repo (plist-get args :repo))
            (rev (plist-get args :rev))
            (sha256 (plist-get args :sha256)))
       (anvil-pkg--require-string name "github-fetch :owner" owner)
       (anvil-pkg--require-string name "github-fetch :repo" repo)
       (anvil-pkg--require-string name "github-fetch :rev" rev)
       (anvil-pkg--require-string name "github-fetch :sha256" sha256)
       (list :type 'github-fetch
             :owner owner :repo repo :rev rev :sha256 sha256)))
    ('git-fetch
     (let* ((args (cdr form))
            (url (plist-get args :url))
            (rev (plist-get args :rev))
            (sha256 (plist-get args :sha256)))
       (anvil-pkg--require-string name "git-fetch :url" url)
       (anvil-pkg--require-string name "git-fetch :rev" rev)
       (anvil-pkg--require-string name "git-fetch :sha256" sha256)
       (list :type 'git-fetch :url url :rev rev :sha256 sha256)))
    (_ (signal 'anvil-pkg-dsl-error
               (list (format "pkg-define %s: unsupported source fetcher %S (supported: url-fetch, github-fetch, git-fetch)"
                             name (car form)))))))

(defun anvil-pkg--require-string (name field val)
  "Signal `anvil-pkg-dsl-error' unless VAL is a non-empty string.
NAME is the package name, FIELD a description used in the message."
  (unless (and (stringp val) (> (length val) 0))
    (signal 'anvil-pkg-dsl-error
            (list (format "pkg-define %s: %s must be a non-empty string, got %S"
                          name field val)))))

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
Pure function — same input always yields the same output.

Dispatches on the build-system :type to select the appropriate
nixpkgs builder (stdenv.mkDerivation, rustPlatform.buildRustPackage,
python3Packages.buildPythonPackage, buildGoModule)."
  (let* ((bs (plist-get ir :build-system))
         (type (plist-get bs :type)))
    (pcase type
      ('stdenv (anvil-pkg--render-stdenv ir))
      ('rust   (anvil-pkg--render-rust ir))
      ('python (anvil-pkg--render-python ir))
      ('go     (anvil-pkg--render-go ir))
      ('emacs-package (anvil-pkg--render-emacs-package ir))
      (_ (signal 'anvil-pkg-dsl-error
                 (list (format "render: unsupported build-system :type %S"
                               type)))))))

(defun anvil-pkg--render-derivation (fn-name fields)
  "Compose `FN-NAME { FIELDS }' into a single Nix expression string.
FIELDS is a list of pre-rendered, already-indented strings."
  (concat fn-name " {\n"
          (mapconcat #'identity fields "\n")
          "\n}"))

(defun anvil-pkg--render-pre-bs-fields (ir)
  "Render the common derivation fields that appear BEFORE
build-system specific fields: pname, version, src, buildInputs,
nativeBuildInputs.  Returns a list of strings."
  (let* ((name (plist-get ir :name))
         (version (plist-get ir :version))
         (source (plist-get ir :source))
         (inputs (plist-get ir :inputs))
         (native-inputs (plist-get ir :native-inputs))
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
    (nreverse parts)))

(defun anvil-pkg--render-post-bs-fields (ir)
  "Render the common derivation fields that appear AFTER
build-system specific fields: buildPhase, installPhase, meta.
Returns a list of strings."
  (let* ((install-phase (plist-get ir :install-phase))
         (build-phase (plist-get ir :build-phase))
         (description (plist-get ir :description))
         (homepage (plist-get ir :homepage))
         (license (plist-get ir :license))
         (parts '()))
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
    (nreverse parts)))

(defun anvil-pkg--render-stdenv (ir)
  "Render IR using `pkgs.stdenv.mkDerivation'."
  (anvil-pkg--render-derivation
   "pkgs.stdenv.mkDerivation"
   (append (anvil-pkg--render-pre-bs-fields ir)
           (anvil-pkg--render-post-bs-fields ir))))

(defun anvil-pkg--render-rust (ir)
  "Render IR using `pkgs.rustPlatform.buildRustPackage'.
Requires :cargo-sha256 in the build-system args."
  (let* ((bs (plist-get ir :build-system))
         (cargo-sha256 (plist-get bs :cargo-sha256)))
    (anvil-pkg--render-derivation
     "pkgs.rustPlatform.buildRustPackage"
     (append (anvil-pkg--render-pre-bs-fields ir)
             (list (format "  cargoSha256 = %S;" cargo-sha256))
             (anvil-pkg--render-post-bs-fields ir)))))

(defun anvil-pkg--render-python (ir)
  "Render IR using `pkgs.python3Packages.buildPythonPackage'.
Optional :format key (\"setuptools\" default, \"pyproject\" or \"wheel\")."
  (let* ((bs (plist-get ir :build-system))
         (format-str (plist-get bs :format)))
    (anvil-pkg--render-derivation
     "pkgs.python3Packages.buildPythonPackage"
     (append (anvil-pkg--render-pre-bs-fields ir)
             (when format-str
               (list (format "  format = %S;" format-str)))
             (anvil-pkg--render-post-bs-fields ir)))))

(defun anvil-pkg--render-go (ir)
  "Render IR using `pkgs.buildGoModule'.
Optional :vendor-sha256 (defaults to `vendorHash = null')."
  (let* ((bs (plist-get ir :build-system))
         (vendor-sha256 (plist-get bs :vendor-sha256)))
    (anvil-pkg--render-derivation
     "pkgs.buildGoModule"
     (append (anvil-pkg--render-pre-bs-fields ir)
             (list (if vendor-sha256
                       (format "  vendorHash = %S;" vendor-sha256)
                     "  vendorHash = null;"))
             (anvil-pkg--render-post-bs-fields ir)))))

(defun anvil-pkg--render-emacs-package (ir)
  "Render IR using `pkgs.emacsPackages.trivialBuild' or `.melpaBuild'.
Phase 4-B: :format selects the builder (default \"trivial\");
:native-comp t wraps via `pkgs.emacsPackagesFor pkgs.emacs' so
native compilation flows through both the build call and the
propagated inputs."
  (let* ((bs (plist-get ir :build-system))
         (format-str (or (plist-get bs :format) "trivial"))
         (native-comp (plist-get bs :native-comp))
         (builder-suffix (pcase format-str
                           ("trivial" "trivialBuild")
                           ("melpa"   "melpaBuild")
                           (_ (signal 'anvil-pkg-dsl-error
                                      (list (format "render: unsupported emacs-package :format %S"
                                                    format-str))))))
         (epkgs-set (if native-comp
                        "(pkgs.emacsPackagesFor pkgs.emacs)"
                      "pkgs.emacsPackages"))
         (builder (format "%s.%s" epkgs-set builder-suffix))
         (depends-on (plist-get ir :depends-on)))
    (anvil-pkg--render-derivation
     builder
     (append (anvil-pkg--render-pre-bs-fields ir)
             (when depends-on
               (list (format "  packageRequires = with %s; [ %s ];"
                             epkgs-set
                             (mapconcat #'symbol-name depends-on " "))))
             (anvil-pkg--render-post-bs-fields ir)))))

(defun anvil-pkg--render-source (src)
  "Render a source IR plist into a Nix fetcher expression.

Phase 3 fetchers: url-fetch, github-fetch, git-fetch."
  (pcase (plist-get src :type)
    ('url-fetch
     (format "pkgs.fetchurl {\n    url = %S;\n    sha256 = %S;\n  }"
             (plist-get src :url)
             (plist-get src :sha256)))
    ('github-fetch
     (format "pkgs.fetchFromGitHub {\n    owner = %S;\n    repo = %S;\n    rev = %S;\n    sha256 = %S;\n  }"
             (plist-get src :owner)
             (plist-get src :repo)
             (plist-get src :rev)
             (plist-get src :sha256)))
    ('git-fetch
     (format "pkgs.fetchgit {\n    url = %S;\n    rev = %S;\n    sha256 = %S;\n  }"
             (plist-get src :url)
             (plist-get src :rev)
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
    (anvil-pkg-compat-make-directory (file-name-directory file) t)
    (anvil-pkg-compat-write-file file (anvil-pkg--render-flake))
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
         (subcmd (anvil-pkg--nix-install-subcommand))
         (args (append (list "profile" subcmd)
                       (anvil-pkg--profile-args)
                       (list flakeref)))
         (res (anvil-pkg--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'anvil-pkg-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            sym
                            (plist-get res :exit)
                            (anvil-pkg-compat-string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

(provide 'anvil-pkg-dsl)
;;; anvil-pkg-dsl.el ends here
