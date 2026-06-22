;;; nelix-dsl.el --- DSL macro + registry + Nix renderer for nelix-core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; Author: zawatton
;; URL: https://github.com/zawatton/nelix-core
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (nelix-core "0.1.0"))
;; Keywords: tools, packages, nix

;; This file is part of nelix-core.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Phase 2 + 3 of nelix-core.  Provides a Guix-style declarative DSL
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
;;   - build systems: stdenv (Phase 2), rust, python, go, node, haskell
;;   - build-system IR upgraded to plist `(:type SYM ...args)' so each
;;     build system can carry its own required fields (e.g. cargo-sha256
;;     for rust, vendor-sha256 for go, format for python).
;;
;; This file owns:
;;   - `pkg-define' macro + sub-form parser (errors fire at byte-compile)
;;   - `nelix-core--registry' hash-table (SYMBOL -> IR plist)
;;   - `nelix-core-render-nix' pure renderer (IR -> Nix derivation string)
;;   - `nelix-core--render-flake' (registry -> flake.nix string)
;;   - `nelix-core--install-symbol' (lookup -> write -> install)
;;
;; Design doc: docs/design/02-dsl.org.

;;; Code:

(require 'nelix-core)
(require 'nelix-compat)
(require 'cl-lib)
;; nelix-dsl folds in the former public veneer (nelix-dsl-version /
;; nelix-define / nelix-render-nix); nelix-manifest supplies the stable
;; environment DSL version.
(require 'nelix-manifest)

(defun nelix-core--booleanp (value)
  "Return non-nil when VALUE is exactly t or nil."
  (or (eq value t) (null value)))

(declare-function nelix-core--ensure-nix "nelix-core")
(declare-function nelix-core--call-nix "nelix-core")
(declare-function nelix-core--profile-args "nelix-core")
(declare-function nelix-core--nix-install-subcommand "nelix-core")

;; Phase 4-E L27: render-time MELPA upstream fetch fluid lives in
;; nelix-emacs (loaded lazily when emacs-package backend fires).
;; Declare for byte-compile; runtime guards via `boundp' / `functionp'.
(defvar nelix-emacs--render-fetch-fn)

;;;; --- error symbols ---------------------------------------------------------

(nelix-compat-define-error-symbol 'nelix-error
                                      "nelix-core error")
(nelix-compat-define-error-symbol 'nelix-dsl-error
                                      "nelix-core DSL error"
                                      'nelix-error)
(nelix-compat-define-error-symbol 'nelix-undefined-package
                                      "Symbol not registered via pkg-define"
                                      'nelix-error)

;;;; --- registry --------------------------------------------------------------

(defvar nelix-core--registry (make-hash-table :test 'eq)
  "Symbol -> IR plist for packages declared via `pkg-define'.")

(defun nelix-core--register (name ir)
  "Store IR under NAME in the registry, warn on redefinition."
  (when (gethash name nelix-core--registry)
    (lwarn 'nelix-core :warning "redefining package %s" name))
  (puthash name ir nelix-core--registry)
  name)

(defun nelix-core--registry-get (name)
  "Return IR for NAME or signal `nelix-undefined-package'."
  (or (gethash name nelix-core--registry)
      (signal 'nelix-undefined-package
              (list (format "%s not defined; use pkg-define to declare it"
                            name)))))

(defun nelix-core--registry-clear ()
  "Empty the registry.  Test helper."
  (clrhash nelix-core--registry))

;;;; --- parser (macro-time) --------------------------------------------------

(defconst nelix-core--known-keywords
  '(version source build-system inputs native-inputs
            install-phase build-phase depends-on
            description homepage license)
  "Sub-form keywords accepted inside `pkg-define'.")

(defun nelix-core--parse-define (name body)
  "Parse pkg-define BODY into IR plist.  Runs at macro-expand time."
  (let ((ir (list :name name
                  :build-system (list :type 'stdenv)
                  :inputs nil
                  :native-inputs nil
                  :depends-on nil)))
    (dolist (form body)
      (unless (and (consp form) (symbolp (car form)))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: malformed sub-form %S"
                              name form))))
      (let ((key (car form))
            (val (cdr form)))
        (unless (memq key nelix-core--known-keywords)
          (signal 'nelix-dsl-error
                  (list (format "pkg-define %s: unknown keyword %S; expected one of %S"
                                name key nelix-core--known-keywords))))
        (setq ir (plist-put ir
                            (intern (concat ":" (symbol-name key)))
                            (nelix-core--parse-value name key val)))))
    (unless (plist-get ir :version)
      (signal 'nelix-dsl-error
              (list (format "pkg-define %s: missing required (version ...)"
                            name))))
    (unless (plist-get ir :source)
      (signal 'nelix-dsl-error
              (list (format "pkg-define %s: missing required (source ...)"
                            name))))
    (nelix-core--validate-ir name ir)
    ir))

(defun nelix-core--parse-value (name key val)
  "Coerce sub-form VAL based on KEY into IR shape."
  (pcase key
    ('source (nelix-core--parse-source name (car val)))
    ((or 'inputs 'native-inputs 'depends-on)
     (nelix-core--parse-input-list (car val)))
    ('build-system (nelix-core--parse-build-system name (car val)))
    (_ (car val))))

(defconst nelix-core--known-build-systems
  '(stdenv rust python go node haskell emacs-package)
  "Build-system symbols supported by the DSL.")

(defun nelix-core--parse-build-system (name form)
  "Parse a build-system FORM into a plist `(:type SYM ...args)'.

Accepts:
  (build-system stdenv)              ; symbol form, no args
  (build-system (rust :cargo-sha256 \"...\"))
  (build-system (python :format \"pyproject\"))
  (build-system (go :vendor-sha256 \"...\"))
  (build-system (node :npm-deps-hash \"...\"))
  (build-system haskell)"
  (cond
   ((symbolp form)
    (nelix-core--validate-build-system name form nil)
    (list :type form))
   ((and (consp form) (symbolp (car form)))
    (let ((type (car form))
          (args (cdr form)))
      (nelix-core--validate-build-system name type args)
      (apply #'list :type type args)))
   (t (signal 'nelix-dsl-error
              (list (format "pkg-define %s: build-system must be SYMBOL or (SYMBOL :args...), got %S"
                            name form))))))

(defun nelix-core--validate-build-system (name type args)
  "Validate that build-system TYPE is supported and required ARGS are present."
  (unless (memq type nelix-core--known-build-systems)
    (signal 'nelix-dsl-error
            (list (format "pkg-define %s: build-system %S not yet supported (supported: %S)"
                          name type nelix-core--known-build-systems))))
  (pcase type
    ('rust
     (unless (plist-get args :cargo-sha256)
       (signal 'nelix-dsl-error
               (list (format "pkg-define %s: rust build-system requires :cargo-sha256"
                             name))))
     (nelix-core--reject-non-emacs-package-args name type args))
    ('node
     (unless (plist-get args :npm-deps-hash)
       (signal 'nelix-dsl-error
               (list (format "pkg-define %s: node build-system requires :npm-deps-hash"
                             name))))
     (nelix-core--reject-non-emacs-package-args name type args))
    ('emacs-package
     (nelix-core--validate-emacs-package-args name args))
    ;; python: :format optional (defaults to setuptools)
    ;; go: :vendor-sha256 optional (defaults to vendorHash = null)
    ;; node: :npm-deps-hash required
    ;; haskell: no required args
    ;; stdenv: no required args
    ;; All non-emacs-package types reject :native-comp (L13).
    (_
     (nelix-core--reject-non-emacs-package-args name type args))))

(defun nelix-core--reject-non-emacs-package-args (name type args)
  "Signal when ARGS carry emacs-package-only keys on non-emacs TYPE.
Currently catches :native-comp (Phase 4-B L13 reject) and the
Phase 4-D melpa keywords :melpa-synth / :melpa-recipe / :melpa-files (L23),
and :pname / :ignore-compilation-error."
  (dolist (key '(:native-comp :melpa-synth :melpa-recipe :melpa-files
                 :pname :ignore-compilation-error))
    (when (nelix-core--plist-has-key-p args key)
      (signal 'nelix-dsl-error
              (list (format "pkg-define %s: %s is only valid on emacs-package build-system, not %S"
                            name key type))))))

(defun nelix-core--validate-emacs-package-args (name args)
  "Validate emacs-package build-system ARGS.
Phase 4-B L13/L14: :format must be \"trivial\" or \"melpa\";
:native-comp must be t or nil when supplied.
Phase 4-D L23: :melpa-synth must be one of `auto', `force', `never';
:melpa-recipe must be a non-empty string when supplied;
:melpa-files must be a list of non-empty strings when supplied.
:pname must be a non-empty string when supplied.
:ignore-compilation-error must be t or nil when supplied."
  (let ((fmt (plist-get args :format)))
    (when fmt
      (unless (member fmt '("trivial" "melpa"))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :format must be \"trivial\" or \"melpa\", got %S"
                              name fmt))))))
  (when (nelix-core--plist-has-key-p args :native-comp)
    (let ((nc (plist-get args :native-comp)))
      (unless (nelix-core--booleanp nc)
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :native-comp must be t or nil, got %S"
                              name nc))))))
  (when (nelix-core--plist-has-key-p args :melpa-synth)
    (let ((synth (plist-get args :melpa-synth)))
      (unless (memq synth '(auto force never))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :melpa-synth must be one of auto / force / never, got %S"
                              name synth))))))
  (when (nelix-core--plist-has-key-p args :melpa-recipe)
    (let ((recipe (plist-get args :melpa-recipe)))
      (unless (or (null recipe)
                  (and (stringp recipe) (> (length recipe) 0)))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :melpa-recipe must be a non-empty string or nil, got %S"
                              name recipe))))))
  (when (nelix-core--plist-has-key-p args :melpa-files)
    (let ((files (plist-get args :melpa-files)))
      (unless (and (listp files)
                   (cl-every (lambda (f)
                               (and (stringp f) (> (length f) 0)))
                             files))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :melpa-files must be a list of non-empty strings, got %S"
                              name files))))))
  (when (nelix-core--plist-has-key-p args :pname)
    (let ((pname (plist-get args :pname)))
      (unless (and (stringp pname) (> (length pname) 0))
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :pname must be a non-empty string, got %S"
                              name pname))))))
  (when (nelix-core--plist-has-key-p args :ignore-compilation-error)
    (let ((ignore (plist-get args :ignore-compilation-error)))
      (unless (nelix-core--booleanp ignore)
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: emacs-package :ignore-compilation-error must be t or nil, got %S"
                              name ignore)))))))

(defun nelix-core--validate-ir (name ir)
  "Validate cross-field constraints for package NAME and parsed IR."
  (let* ((bs (plist-get ir :build-system))
         (build-system-type (plist-get bs :type)))
    (when (eq build-system-type 'emacs-package)
      (when (plist-get ir :install-phase)
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: install-phase is not supported with build-system emacs-package"
                              name))))
      (when (plist-get ir :build-phase)
        (signal 'nelix-dsl-error
                (list (format "pkg-define %s: build-phase is not supported with build-system emacs-package"
                              name))))
      ;; L23: :melpa-synth 'force is incompatible with url-fetch source.
      (let ((synth (plist-get bs :melpa-synth))
            (src-type (plist-get (plist-get ir :source) :type)))
        (when (and (eq synth 'force) (eq src-type 'url-fetch))
          (signal 'nelix-dsl-error
                  (list (format "pkg-define %s: :melpa-synth 'force is not supported with url-fetch source (tarball cannot be re-pinned via :fetcher git); supply :melpa-recipe explicitly or switch to github-fetch / git-fetch"
                                name))))))))

(defun nelix-core--parse-source (name form)
  "Parse a source-form into source IR plist.

Phase 3 fetchers:
  (url-fetch URL :sha256 HASH)
  (github-fetch :owner OWNER :repo REPO :rev REV :sha256 HASH)
  (git-fetch :url URL :rev REV :sha256 HASH)"
  (unless (and (consp form) (symbolp (car form)))
    (signal 'nelix-dsl-error
            (list (format "pkg-define %s: source must be a fetcher form, got %S"
                          name form))))
  (pcase (car form)
    ('url-fetch
     (let* ((url (cadr form))
            (rest (cddr form))
            (sha256 (plist-get rest :sha256)))
       (nelix-core--require-string name "url-fetch URL" url)
       (nelix-core--require-string name "url-fetch :sha256" sha256)
       (list :type 'url-fetch :url url :sha256 sha256)))
    ('github-fetch
     (let* ((args (cdr form))
            (owner (plist-get args :owner))
            (repo (plist-get args :repo))
            (rev (plist-get args :rev))
            (sha256 (plist-get args :sha256)))
       (nelix-core--require-string name "github-fetch :owner" owner)
       (nelix-core--require-string name "github-fetch :repo" repo)
       (nelix-core--require-string name "github-fetch :rev" rev)
       (nelix-core--require-string name "github-fetch :sha256" sha256)
       (list :type 'github-fetch
             :owner owner :repo repo :rev rev :sha256 sha256)))
    ('git-fetch
     (let* ((args (cdr form))
            (url (plist-get args :url))
            (rev (plist-get args :rev))
            (sha256 (plist-get args :sha256)))
       (nelix-core--require-string name "git-fetch :url" url)
       (nelix-core--require-string name "git-fetch :rev" rev)
       (nelix-core--require-string name "git-fetch :sha256" sha256)
       (list :type 'git-fetch :url url :rev rev :sha256 sha256)))
    (_ (signal 'nelix-dsl-error
               (list (format "pkg-define %s: unsupported source fetcher %S (supported: url-fetch, github-fetch, git-fetch)"
                             name (car form)))))))

(defun nelix-core--require-string (name field val)
  "Signal `nelix-dsl-error' unless VAL is a non-empty string.
NAME is the package name, FIELD a description used in the message."
  (unless (and (stringp val) (> (length val) 0))
    (signal 'nelix-dsl-error
            (list (format "pkg-define %s: %s must be a non-empty string, got %S"
                          name field val)))))

(defun nelix-core--parse-input-list (form)
  "Coerce FORM into a flat list of nixpkgs attribute symbols.

Accepts (list S1 S2 ...), \\='(S1 S2 ...) or a literal (S1 S2 ...)."
  (cond
   ((null form) nil)
   ((and (consp form) (eq (car form) 'list)) (cdr form))
   ((and (consp form) (eq (car form) 'quote)) (cadr form))
   ((listp form) form)
   (t (signal 'nelix-dsl-error
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
  (let ((ir (nelix-core--parse-define name body)))
    `(progn
       (nelix-core--register ',name ',ir)
       ',name)))

;;;; --- renderer (pure, no I/O) ----------------------------------------------

(defun nelix-core-render-nix (ir)
  "Render IR plist into a single Nix derivation expression string.
Pure function — same input always yields the same output.

Dispatches on the build-system :type to select the appropriate
nixpkgs builder (stdenv.mkDerivation, rustPlatform.buildRustPackage,
python3Packages.buildPythonPackage, buildGoModule, buildNpmPackage,
haskellPackages.mkDerivation)."
  (let* ((bs (plist-get ir :build-system))
         (type (plist-get bs :type)))
    (cond
     ((eq type 'stdenv) (nelix-core--render-stdenv ir))
     ((eq type 'rust) (nelix-core--render-rust ir))
     ((eq type 'python) (nelix-core--render-python ir))
     ((eq type 'go) (nelix-core--render-go ir))
     ((eq type 'node) (nelix-core--render-node ir))
     ((eq type 'haskell) (nelix-core--render-haskell ir))
     ((eq type 'emacs-package) (nelix-core--render-emacs-package ir))
     (t (signal 'nelix-dsl-error
                (list (format "render: unsupported build-system :type %S"
                              type)))))))

(defun nelix-core--render-derivation (fn-name fields)
  "Compose `FN-NAME { FIELDS }' into a single Nix expression string.
FIELDS is a list of pre-rendered, already-indented strings."
  (concat fn-name " {\n"
          (nelix-core--join-strings fields "\n")
          "\n}"))

(defun nelix-core--join-strings (strings separator)
  "Join STRINGS with SEPARATOR without relying on symbol-function `identity'."
  (mapconcat (lambda (s) s) strings separator))

(defun nelix-core--quote-string (string)
  "Return STRING as a Nix/Elisp double-quoted literal."
  (concat "\"" string "\""))

(defun nelix-core--render-elisp-literal (value)
  "Return VALUE rendered as a small Elisp literal for generated recipes."
  (cond
   ((stringp value) (nelix-core--quote-string value))
   ((symbolp value) (symbol-name value))
   ((consp value)
    (concat "("
            (mapconcat #'nelix-core--render-elisp-literal value " ")
            ")"))
   (t (format "%S" value))))

(defun nelix-core--render-pre-bs-fields (ir)
  "Render the common derivation fields that appear BEFORE
build-system specific fields: pname, version, src, buildInputs,
nativeBuildInputs.  Returns a list of strings."
  (let* ((name (plist-get ir :name))
         (bs (plist-get ir :build-system))
         (pname (or (plist-get bs :pname)
                    (symbol-name name)))
         (version (plist-get ir :version))
         (source (plist-get ir :source))
         (inputs (plist-get ir :inputs))
         (native-inputs (plist-get ir :native-inputs))
         (parts '()))
    (push (format "  pname = %s;" (nelix-core--quote-string pname)) parts)
    (push (format "  version = %s;" (nelix-core--quote-string version)) parts)
    (push (format "  src = %s;" (nelix-core--render-source source)) parts)
    (when inputs
      (push (format "  buildInputs = with pkgs; [ %s ];"
                    (mapconcat #'symbol-name inputs " "))
            parts))
    (when native-inputs
      (push (format "  nativeBuildInputs = with pkgs; [ %s ];"
                    (mapconcat #'symbol-name native-inputs " "))
            parts))
    (nreverse parts)))

(defun nelix-core--render-post-bs-fields (ir)
  "Render the common derivation fields that appear AFTER
build-system specific fields: buildPhase, installPhase, meta.
Returns a list of strings."
  (let* ((bs (plist-get ir :build-system))
         (install-phase (plist-get ir :install-phase))
         (build-phase (plist-get ir :build-phase))
         (description (plist-get ir :description))
         (homepage (plist-get ir :homepage))
         (license (plist-get ir :license))
         (parts '()))
    (when (nelix-core--plist-has-key-p bs :ignore-compilation-error)
      (push (format "  ignoreCompilationError = %s;"
                    (if (plist-get bs :ignore-compilation-error) "true" "false"))
            parts))
    (when build-phase
      (push (format "  buildPhase = ''\n%s\n  '';"
                    (nelix-core--indent-each-line build-phase 4))
            parts))
    (when install-phase
      (push (format "  installPhase = ''\n%s\n  '';"
                    (nelix-core--indent-each-line install-phase 4))
            parts))
    (when (or description homepage license)
      (let ((meta-parts '()))
        (when description
          (push (format "    description = %s;"
                        (nelix-core--quote-string description))
                meta-parts))
        (when homepage
          (push (format "    homepage = %s;"
                        (nelix-core--quote-string homepage))
                meta-parts))
        (when license
          (push (format "    license = %s;"
                        (nelix-core--render-license license))
                meta-parts))
        (push (concat "  meta = {\n"
                      (nelix-core--join-strings (nreverse meta-parts) "\n")
                      "\n  };")
              parts)))
    (nreverse parts)))

(defun nelix-core--render-stdenv (ir)
  "Render IR using `pkgs.stdenv.mkDerivation'."
  (nelix-core--render-derivation
   "pkgs.stdenv.mkDerivation"
   (append (nelix-core--render-pre-bs-fields ir)
           (nelix-core--render-post-bs-fields ir))))

(defun nelix-core--render-rust (ir)
  "Render IR using `pkgs.rustPlatform.buildRustPackage'.
Requires :cargo-sha256 in the build-system args.

DSL keyword stays :cargo-sha256 for backward compat, but the
emitted Nix attribute is `cargoHash' — modern nixpkgs (>=23.11)
deprecated `cargoSha256' and unstable rejects it outright."
  (let* ((bs (plist-get ir :build-system))
         (cargo-sha256 (plist-get bs :cargo-sha256)))
    (nelix-core--render-derivation
     "pkgs.rustPlatform.buildRustPackage"
     (append (nelix-core--render-pre-bs-fields ir)
             (list (format "  cargoHash = %s;" (nelix-core--quote-string cargo-sha256)))
             (nelix-core--render-post-bs-fields ir)))))

(defun nelix-core--render-python (ir)
  "Render IR using `pkgs.python3Packages.buildPythonPackage'.
Optional :format key (\"setuptools\" default, \"pyproject\" or \"wheel\")."
  (let* ((bs (plist-get ir :build-system))
         (format-str (plist-get bs :format)))
    (nelix-core--render-derivation
     "pkgs.python3Packages.buildPythonPackage"
     (append (nelix-core--render-pre-bs-fields ir)
             (when format-str
               (list (format "  format = %s;" (nelix-core--quote-string format-str))))
             (nelix-core--render-post-bs-fields ir)))))

(defun nelix-core--render-go (ir)
  "Render IR using `pkgs.buildGoModule'.
Optional :vendor-sha256 (defaults to `vendorHash = null')."
  (let* ((bs (plist-get ir :build-system))
         (vendor-sha256 (plist-get bs :vendor-sha256)))
    (nelix-core--render-derivation
     "pkgs.buildGoModule"
     (append (nelix-core--render-pre-bs-fields ir)
             (list (if vendor-sha256
                       (format "  vendorHash = %s;" (nelix-core--quote-string vendor-sha256))
                     "  vendorHash = null;"))
             (nelix-core--render-post-bs-fields ir)))))

(defun nelix-core--render-node (ir)
  "Render IR using `pkgs.buildNpmPackage'.
Requires :npm-deps-hash in the build-system args."
  (let* ((bs (plist-get ir :build-system))
         (npm-deps-hash (plist-get bs :npm-deps-hash)))
    (nelix-core--render-derivation
     "pkgs.buildNpmPackage"
     (append (nelix-core--render-pre-bs-fields ir)
             (list (format "  npmDepsHash = %s;" (nelix-core--quote-string npm-deps-hash)))
             (nelix-core--render-post-bs-fields ir)))))

(defun nelix-core--render-haskell (ir)
  "Render IR using `pkgs.haskellPackages.mkDerivation'."
  (nelix-core--render-derivation
   "pkgs.haskellPackages.mkDerivation"
   (append (nelix-core--render-pre-bs-fields ir)
           (nelix-core--render-post-bs-fields ir))))

(defun nelix-core--render-emacs-package (ir)
  "Render IR using `pkgs.emacsPackages.trivialBuild' or `.melpaBuild'.
Phase 4-B: :format selects the builder (default \"trivial\");
:native-comp t wraps via `pkgs.emacsPackagesFor pkgs.emacs' so
native compilation flows through both the build call and the
propagated inputs.
Phase 4-D L23: when :format is \"melpa\", :melpa-synth controls
auto-synthesis of a postUnpack block writing recipes/<pname>.
:melpa-recipe overrides synth with a verbatim user string;
:melpa-files overrides the default \(\"*.el\") glob list."
  (let* ((bs (plist-get ir :build-system))
         (format-str (or (plist-get bs :format) "trivial"))
         (native-comp (plist-get bs :native-comp))
         (builder-suffix (cond
                          ((equal format-str "trivial") "trivialBuild")
                          ((equal format-str "melpa") "melpaBuild")
                          (t (signal 'nelix-dsl-error
                                     (list (format "render: unsupported emacs-package :format %S"
                                                   format-str))))))
         (epkgs-set (if native-comp
                        "(pkgs.emacsPackagesFor pkgs.emacs)"
                      "pkgs.emacsPackages"))
         (builder (format "%s.%s" epkgs-set builder-suffix))
         (depends-on (plist-get ir :depends-on))
         (post-unpack (and (equal format-str "melpa")
                           (nelix-core--render-melpa-post-unpack ir))))
    (nelix-core--render-derivation
     builder
     (append (nelix-core--render-pre-bs-fields ir)
             (when depends-on
               (list (format "  packageRequires = with %s; [ %s ];"
                             epkgs-set
                             (mapconcat #'symbol-name depends-on " "))))
             (when post-unpack (list post-unpack))
             (nelix-core--render-post-bs-fields ir)))))

(defconst nelix-core--default-melpa-files
  '("*.el" "*.el.in" "dir"
    "*.info" "*.texi" "*.texinfo"
    "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
    "lisp/*.el" "lisp/*.el.in" "lisp/dir"
    "lisp/*.info" "lisp/*.texi" "lisp/*.texinfo"
    (:exclude ".dir-locals.el" "lisp/.dir-locals.el"
              "test.el" "tests.el" "*-test.el" "*-tests.el"
              "lisp/test.el" "lisp/tests.el"
              "lisp/*-test.el" "lisp/*-tests.el"))
  "Default :files glob spec applied when :melpa-files is omitted.

Mirrors `package-build-default-files-spec' from MELPA's
package-build.  Phase 4-E L28 promoted this from the previous
=(\"*.el\")= default so subdir / .el.in / .info layouts work
without explicit :melpa-files.  Users still override by supplying
their own list.")

(defun nelix-core--render-melpa-post-unpack (ir)
  "Return a `postUnpack' Nix field for IR or nil if no synth applies.

Phase 4-D L23 logic, evaluated only for :format \"melpa\":

- If :melpa-recipe is supplied, use it verbatim (synth skipped).
- Else dispatch on :melpa-synth (default `auto'):
  - `never'                         → return nil (no synth).
  - `auto' (default) on github-fetch / git-fetch:
    - Phase 4-E L27: when
      `nelix-emacs-melpa-upstream-fetch' is non-nil, consult
      MELPA upstream via `nelix-emacs--render-fetch-fn'; on
      hit emit the canonical recipe verbatim, on miss fall back
      to local synth.
    - When the defcustom is nil (default), behave like Phase 4-D
      = synth directly.
  - `force' on github-fetch / git-fetch:
    - Always synth, never consult upstream.  This is the user's
      explicit \"do not consult MELPA\" signal.
  - `auto' on url-fetch              → return nil (silently skip;
                                       tarball cannot be re-pinned).
  - `force' on url-fetch             → already rejected at parse time
                                       (`nelix-core--validate-ir')."
  (let* ((bs (plist-get ir :build-system))
         (name (plist-get ir :name))
         (pname (or (plist-get bs :pname)
                    (symbol-name name)))
         (explicit (plist-get bs :melpa-recipe))
         (synth (or (plist-get bs :melpa-synth) 'auto))
         (files (or (plist-get bs :melpa-files)
                    nelix-core--default-melpa-files)))
    (cond
     ;; Explicit recipe wins, unconditionally.
     ((and (stringp explicit) (> (length explicit) 0))
      (nelix-core--render-post-unpack-block pname explicit))
     ;; User opted out.
     ((eq synth 'never) nil)
     ;; Auto / force on a re-pinnable git source.
     ((memq synth '(auto force))
      (let* ((src (plist-get ir :source))
             (src-type (plist-get src :type))
             (url (pcase src-type
                    ('github-fetch
                     (format "https://github.com/%s/%s"
                             (plist-get src :owner)
                             (plist-get src :repo)))
                    ('git-fetch (plist-get src :url))
                    ('url-fetch nil)
                    (_ nil))))
        (when url
          ;; L27: auto + git-style source → optionally consult upstream.
          (let* ((upstream
                  (and (eq synth 'auto)
                       (memq src-type '(github-fetch git-fetch))
                       (nelix-core--fetch-upstream-melpa-recipe pname)))
                 (recipe
                  (or (and (stringp upstream) (> (length upstream) 0)
                           upstream)
                      (nelix-core--synth-melpa-recipe pname url files))))
            (nelix-core--render-post-unpack-block pname recipe)))))
     (t nil))))

(defun nelix-core--fetch-upstream-melpa-recipe (pname)
  "Indirect through `nelix-emacs--render-fetch-fn' for upstream lookup.

Returns STRING (the recipe body) or nil.  Wraps the fluid in a
`condition-case' so a defective stub during render does not abort
the flake render — failure → nil → synth fallback.  Phase 4-E L27."
  (condition-case err
      (let ((fetch-fn (and (boundp 'nelix-emacs--render-fetch-fn)
                           nelix-emacs--render-fetch-fn)))
        (and fetch-fn
             (funcall fetch-fn pname)))
    (error
     (lwarn 'nelix-core :warning
            "nelix-core: melpa upstream fetch fluid raised %S for %s; falling back to synth"
            err pname)
     nil)))

(defun nelix-core--synth-melpa-recipe (pname url files)
  "Return synthesised MELPA recipe string for PNAME / URL / FILES.

Shape: `(<pname> :fetcher git :url \"<url>\" :files (\"<f1>\" \"<f2>\"))'.
PNAME is the Elisp symbol name as a string.  FILES is a list of
glob strings."
  (format "(%s :fetcher git :url %s :files (%s))"
          pname
          (nelix-core--quote-string url)
          (mapconcat #'nelix-core--render-elisp-literal files " ")))

(defun nelix-core--render-post-unpack-block (pname recipe)
  "Render a postUnpack Nix field that emits PNAME's RECIPE.

The block writes the verbatim RECIPE string into
$NIX_BUILD_TOP/recipes/PNAME via a heredoc so any Elisp double-quotes
in RECIPE survive the shell layer.  `melpaBuild' reads recipes from
$NIX_BUILD_TOP/recipes during buildPhase; writing under $sourceRoot
would leave the builder's default recipe in effect."
  (concat "  postUnpack = ''\n"
          "    mkdir -p \"$NIX_BUILD_TOP/recipes\"\n"
          "    cat > \"$NIX_BUILD_TOP/recipes/" pname "\" <<'ANVIL_PKG_RECIPE_EOF'\n"
          "    " recipe "\n"
          "    ANVIL_PKG_RECIPE_EOF\n"
          "  '';"))

(defun nelix-core--render-source (src)
  "Render a source IR plist into a Nix fetcher expression.

Phase 3 fetchers: url-fetch, github-fetch, git-fetch."
  (pcase (plist-get src :type)
    ('url-fetch
     (format "pkgs.fetchurl {\n    url = %s;\n    sha256 = %s;\n  }"
             (nelix-core--quote-string (plist-get src :url))
             (nelix-core--quote-string (plist-get src :sha256))))
    ('github-fetch
     (format "pkgs.fetchFromGitHub {\n    owner = %s;\n    repo = %s;\n    rev = %s;\n    sha256 = %s;\n  }"
             (nelix-core--quote-string (plist-get src :owner))
             (nelix-core--quote-string (plist-get src :repo))
             (nelix-core--quote-string (plist-get src :rev))
             (nelix-core--quote-string (plist-get src :sha256))))
    ('git-fetch
     (format "pkgs.fetchgit {\n    url = %s;\n    rev = %s;\n    sha256 = %s;\n  }"
             (nelix-core--quote-string (plist-get src :url))
             (nelix-core--quote-string (plist-get src :rev))
             (nelix-core--quote-string (plist-get src :sha256))))
    (_ (signal 'nelix-dsl-error
               (list (format "render: unsupported source type %S"
                             (plist-get src :type)))))))

(defconst nelix-core--license-map
  '((mit     . "pkgs.lib.licenses.mit")
    (gpl2    . "pkgs.lib.licenses.gpl2")
    (gpl3    . "pkgs.lib.licenses.gpl3")
    (bsd2    . "pkgs.lib.licenses.bsd2")
    (bsd3    . "pkgs.lib.licenses.bsd3")
    (apache2 . "pkgs.lib.licenses.asl20"))
  "Phase 2 license symbol -> Nix expression.
Unknown symbols fall back to a quoted string literal.")

(defun nelix-core--render-license (sym)
  "Render a license symbol into a Nix expression."
  (or (alist-get sym nelix-core--license-map)
      (nelix-core--quote-string (symbol-name sym))))

(defun nelix-core--indent-each-line (s n)
  "Prepend N spaces to every line of S."
  (let ((prefix (make-string n ?\s)))
    (mapconcat (lambda (l) (concat prefix l))
               (split-string s "\n")
               "\n")))

(defun nelix-core--shift-tail-lines (s n)
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

(defun nelix-core--render-flake ()
  "Render the entire registry into a flake.nix string."
  (let (entries)
    (maphash (lambda (k v) (push (cons k v) entries)) nelix-core--registry)
    (setq entries (sort entries (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b))))))
    (concat
     "{\n"
     "  description = \"nelix-core generated flake\";\n"
     "  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixpkgs-unstable\";\n"
     "  outputs = { self, nixpkgs }: {\n"
     "    packages.x86_64-linux = let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {\n"
     (mapconcat (lambda (entry)
                  (let* ((sym (car entry))
                         (ir (cdr entry))
                         (drv (nelix-core-render-nix ir)))
                    (format "      %s = %s;\n"
                            (symbol-name sym)
                            (nelix-core--shift-tail-lines drv 6))))
                entries
                "")
     "    };\n"
     "  };\n"
     "}\n")))

;;;; --- flake.nix writer (overridable for tests) -----------------------------

(defvar nelix-core--write-flake-fn #'nelix-core--write-flake-default
  "Function used to materialise flake.nix.  Override in tests.

Called with no arguments.  Must return the absolute path to the
flake.nix file it wrote.")

(defun nelix-core--state-dir ()
  "Return the directory holding flake.nix (parent of profile dir)."
  (file-name-directory
   (directory-file-name (expand-file-name nelix-core-profile-dir))))

(defun nelix-core--flake-path ()
  "Absolute path to the generated flake.nix."
  (expand-file-name "flake.nix" (nelix-core--state-dir)))

(defun nelix-core--write-flake-default ()
  "Render the registry into flake.nix on disk.  Returns the path."
  (let ((file (nelix-core--flake-path)))
    (nelix-compat-make-directory (file-name-directory file) t)
    (nelix-compat-write-file file (nelix-core--render-flake))
    file))

;;;; --- symbol install path --------------------------------------------------

(defun nelix-core--install-symbol (sym)
  "Install a registry-defined SYM via flake.nix dispatch.

Path: registry lookup -> regenerate flake.nix -> nix profile
install path:STATE_DIR#SYM."
  (nelix-core--ensure-nix)
  (nelix-core--registry-get sym)
  (let* ((flake-path (funcall nelix-core--write-flake-fn))
         (flake-dir (directory-file-name (file-name-directory flake-path)))
         (flakeref (format "path:%s#%s" flake-dir sym))
         (subcmd (nelix-core--nix-install-subcommand))
         (args (append (list "profile" subcmd)
                       (nelix-core--profile-args)
                       (list flakeref)))
         (res (nelix-core--call-nix args)))
    (if (eq 0 (plist-get res :exit))
        t
      (signal 'nelix-nix-failed
              (list (format "nix profile install %s failed (exit %s): %s"
                            sym
                            (plist-get res :exit)
                            (nelix-compat-string-trim (or (plist-get res :stderr) "")))
                    :stderr (plist-get res :stderr))))))

;;; Public Nelix DSL entry points (folded in from the former nelix-dsl
;;; veneer).  `nelix-define' / `nelix-render-nix' are compatibility
;;; aliases; `nelix-dsl-version' exposes the stable environment DSL version.

;;;###autoload
(defun nelix-dsl-version ()
  "Return the stable public Nelix environment DSL version."
  nelix-environment-dsl-version)

;;;###autoload
(defalias 'nelix-define (symbol-function 'pkg-define))

;;;###autoload
(defalias 'nelix-render-nix #'nelix-core-render-nix)

(provide 'nelix-dsl)
;;; nelix-dsl.el ends here
