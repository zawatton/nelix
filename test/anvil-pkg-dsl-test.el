;;; anvil-pkg-dsl-test.el --- ERT tests for anvil-pkg-dsl -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 2 ERT coverage.  Mocks `anvil-pkg--call-nix-fn' and
;; `anvil-pkg--write-flake-fn' so neither the nix binary nor disk
;; access is required to run the suite.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-dsl)

(defmacro anvil-pkg-dsl-test--with-clean-registry (&rest body)
  "Run BODY against an empty registry, restored on exit."
  (declare (indent 0))
  `(let ((anvil-pkg--registry (make-hash-table :test 'eq)))
     ,@body))

;;;; --- pkg-define / parser ---------------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-registers ()
  "pkg-define stores IR under the correct symbol with parsed source."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-tool
             (version "1.0.0")
             (source (url-fetch "https://example.com/tool-1.0.tar.gz"
                                :sha256 "sha256-abc")))
          t)
    (let ((ir (gethash 'my-tool anvil-pkg--registry)))
      (should ir)
      (should (eq 'my-tool (plist-get ir :name)))
      (should (equal "1.0.0" (plist-get ir :version)))
      (should (eq 'stdenv (plist-get (plist-get ir :build-system) :type)))
      (let ((src (plist-get ir :source)))
        (should (eq 'url-fetch (plist-get src :type)))
        (should (equal "https://example.com/tool-1.0.tar.gz"
                       (plist-get src :url)))
        (should (equal "sha256-abc" (plist-get src :sha256)))))))

(ert-deftest anvil-pkg-dsl-test-define-rejects-unknown-keyword ()
  "Unknown sub-form keyword raises at expansion time."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (typo-key "oops")))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-define-rejects-unknown-build-system ()
  "Unknown build-system symbol errors at parser."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system nim)))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-define-build-system-emacs-package ()
  "emacs-package build-system parses to the expected IR shape."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-elisp
             (version "1.2.3")
             (source (url-fetch "https://example.com/my-elisp.tar.gz"
                                :sha256 "sha256-elisp"))
             (build-system emacs-package))
          t)
    (let* ((ir (gethash 'my-elisp anvil-pkg--registry))
           (bs (plist-get ir :build-system)))
      (should (equal '(:type emacs-package) bs)))))

(ert-deftest anvil-pkg-dsl-test-define-rejects-install-phase-on-emacs-package ()
  "install-phase is rejected for emacs-package build-system."
  (should-error
   (macroexpand-1
    '(pkg-define my-elisp
       (version "1.2.3")
       (source (url-fetch "https://example.com/my-elisp.tar.gz"
                          :sha256 "sha256-elisp"))
       (build-system (emacs-package))
       (install-phase "mkdir -p $out")))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-define-depends-on-list ()
  "depends-on list parses to a list of symbols."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-elisp
             (version "1.2.3")
             (source (url-fetch "https://example.com/my-elisp.tar.gz"
                                :sha256 "sha256-elisp"))
             (build-system emacs-package)
             (depends-on (list dash transient)))
          t)
    (let ((ir (gethash 'my-elisp anvil-pkg--registry)))
      (should (equal '(dash transient)
                     (plist-get ir :depends-on))))))

;;;; --- renderer (pure, golden) ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-render-stdenv-url-fetch-golden ()
  "Renderer emits expected Nix derivation for stdenv + url-fetch + inputs."
  (let ((ir '(:name my-rg
              :version "13.0.0"
              :source (:type url-fetch
                       :url "https://example.com/rg-13.0.0.tar.gz"
                       :sha256 "sha256-xyz")
              :build-system (:type stdenv)
              :inputs (pkg-config openssl)
              :native-inputs nil
              :install-phase "make install PREFIX=$out"))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-rg\";\n"
                   "  version = \"13.0.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/rg-13.0.0.tar.gz\";\n"
                   "    sha256 = \"sha256-xyz\";\n"
                   "  };\n"
                   "  buildInputs = with pkgs; [ pkg-config openssl ];\n"
                   "  installPhase = ''\n"
                   "    make install PREFIX=$out\n"
                   "  '';\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- pkg-install symbol path ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-install-symbol-dispatches ()
  "pkg-install with symbol arg writes flake + calls nix install."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-tool
             (version "1.0.0")
             (source (url-fetch "https://x" :sha256 "sha256-y")))
          t)
    (let* (call-nix-args
           write-called
           (anvil-pkg--call-nix-fn
            (lambda (args)
              (setq call-nix-args args)
              (list :exit 0 :stdout "" :stderr "")))
           (anvil-pkg--write-flake-fn
            (lambda ()
              (setq write-called t)
              "/tmp/anvil-pkg-test/flake.nix"))
           (anvil-pkg-profile-dir "/tmp/anvil-pkg-test/profile"))
      (should (eq t (pkg-install 'my-tool)))
      (should write-called)
      (should (member "install" call-nix-args))
      (should (cl-some (lambda (a)
                         (and (stringp a)
                              (string-match-p "path:.*#my-tool" a)))
                       call-nix-args)))))

(ert-deftest anvil-pkg-dsl-test-install-undefined-errors ()
  "pkg-install of an unregistered symbol signals undefined-package."
  (anvil-pkg-dsl-test--with-clean-registry
    (let ((anvil-pkg--call-nix-fn
           (lambda (_args) (list :exit 0 :stdout "" :stderr "")))
          (anvil-pkg--write-flake-fn
           (lambda () "/tmp/dummy.nix")))
      (should-error (pkg-install 'never-defined)
                    :type 'anvil-pkg-undefined-package))))

;;;; --- Phase 3: source types -----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-source-github-fetch ()
  "github-fetch sub-form parses owner / repo / rev / sha256."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-rg
             (version "13.0.0")
             (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
                                   :rev "13.0.0"
                                   :sha256 "sha256-abc")))
          t)
    (let* ((ir (gethash 'my-rg anvil-pkg--registry))
           (src (plist-get ir :source)))
      (should (eq 'github-fetch (plist-get src :type)))
      (should (equal "BurntSushi" (plist-get src :owner)))
      (should (equal "ripgrep"     (plist-get src :repo)))
      (should (equal "13.0.0"      (plist-get src :rev)))
      (should (equal "sha256-abc"  (plist-get src :sha256))))))

(ert-deftest anvil-pkg-dsl-test-define-source-git-fetch ()
  "git-fetch sub-form parses url / rev / sha256."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-priv
             (version "0.1.0")
             (source (git-fetch :url "https://example.com/private.git"
                                :rev "abc1234"
                                :sha256 "sha256-priv")))
          t)
    (let* ((ir (gethash 'my-priv anvil-pkg--registry))
           (src (plist-get ir :source)))
      (should (eq 'git-fetch (plist-get src :type)))
      (should (equal "https://example.com/private.git"
                     (plist-get src :url)))
      (should (equal "abc1234"      (plist-get src :rev)))
      (should (equal "sha256-priv"  (plist-get src :sha256))))))

(ert-deftest anvil-pkg-dsl-test-render-github-fetch-golden ()
  "Renderer emits fetchFromGitHub for github-fetch source."
  (let ((ir '(:name my-rg
              :version "13.0.0"
              :source (:type github-fetch
                       :owner "BurntSushi"
                       :repo "ripgrep"
                       :rev "13.0.0"
                       :sha256 "sha256-abc")
              :build-system (:type stdenv)))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-rg\";\n"
                   "  version = \"13.0.0\";\n"
                   "  src = pkgs.fetchFromGitHub {\n"
                   "    owner = \"BurntSushi\";\n"
                   "    repo = \"ripgrep\";\n"
                   "    rev = \"13.0.0\";\n"
                   "    sha256 = \"sha256-abc\";\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-git-fetch-golden ()
  "Renderer emits fetchgit for git-fetch source."
  (let ((ir '(:name my-priv
              :version "0.1.0"
              :source (:type git-fetch
                       :url "https://example.com/repo.git"
                       :rev "abc1234"
                       :sha256 "sha256-priv")
              :build-system (:type stdenv)))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-priv\";\n"
                   "  version = \"0.1.0\";\n"
                   "  src = pkgs.fetchgit {\n"
                   "    url = \"https://example.com/repo.git\";\n"
                   "    rev = \"abc1234\";\n"
                   "    sha256 = \"sha256-priv\";\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- Phase 3: build systems ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-build-system-rust-with-args ()
  "Rust build-system with :cargo-sha256 parses into IR."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-rust-tool
             (version "1.0.0")
             (source (url-fetch "https://x" :sha256 "sha256-src"))
             (build-system (rust :cargo-sha256 "sha256-cargo")))
          t)
    (let* ((ir (gethash 'my-rust-tool anvil-pkg--registry))
           (bs (plist-get ir :build-system)))
      (should (eq 'rust (plist-get bs :type)))
      (should (equal "sha256-cargo" (plist-get bs :cargo-sha256))))))

(ert-deftest anvil-pkg-dsl-test-rust-requires-cargo-sha256 ()
  "Rust build-system without :cargo-sha256 errors at parser."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (rust))))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-render-rust-golden ()
  "Renderer emits rustPlatform.buildRustPackage for rust build-system."
  (let ((ir '(:name my-rust-tool
              :version "1.0.0"
              :source (:type url-fetch
                       :url "https://example.com/rust-tool-1.0.tar.gz"
                       :sha256 "sha256-src")
              :build-system (:type rust :cargo-sha256 "sha256-cargo")
              :inputs (openssl)))
        (expected (concat
                   "pkgs.rustPlatform.buildRustPackage {\n"
                   "  pname = \"my-rust-tool\";\n"
                   "  version = \"1.0.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/rust-tool-1.0.tar.gz\";\n"
                   "    sha256 = \"sha256-src\";\n"
                   "  };\n"
                   "  buildInputs = with pkgs; [ openssl ];\n"
                   "  cargoSha256 = \"sha256-cargo\";\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-python-golden ()
  "Renderer emits buildPythonPackage for python build-system with :format."
  (let ((ir '(:name my-py-tool
              :version "0.5.0"
              :source (:type url-fetch
                       :url "https://example.com/my-py-tool-0.5.0.tar.gz"
                       :sha256 "sha256-py")
              :build-system (:type python :format "pyproject")))
        (expected (concat
                   "pkgs.python3Packages.buildPythonPackage {\n"
                   "  pname = \"my-py-tool\";\n"
                   "  version = \"0.5.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/my-py-tool-0.5.0.tar.gz\";\n"
                   "    sha256 = \"sha256-py\";\n"
                   "  };\n"
                   "  format = \"pyproject\";\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-go-golden ()
  "Renderer emits buildGoModule for go build-system, vendorHash null when absent."
  (let ((ir '(:name my-go-tool
              :version "0.3.0"
              :source (:type git-fetch
                       :url "https://example.com/my-go-tool.git"
                       :rev "v0.3.0"
                       :sha256 "sha256-go")
              :build-system (:type go)))
        (expected (concat
                   "pkgs.buildGoModule {\n"
                   "  pname = \"my-go-tool\";\n"
                   "  version = \"0.3.0\";\n"
                   "  src = pkgs.fetchgit {\n"
                   "    url = \"https://example.com/my-go-tool.git\";\n"
                   "    rev = \"v0.3.0\";\n"
                   "    sha256 = \"sha256-go\";\n"
                   "  };\n"
                   "  vendorHash = null;\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-emacs-package-with-deps-golden ()
  "Renderer emits trivialBuild with packageRequires for emacs-package."
  (let ((ir '(:name magit
              :version "3.3.0"
              :source (:type github-fetch
                       :owner "magit"
                       :repo "magit"
                       :rev "v3.3.0"
                       :sha256 "sha256-magit")
              :build-system (:type emacs-package)
              :depends-on (dash transient)
              :description "A Git porcelain inside Emacs."
              :homepage "https://magit.vc"
              :license gpl3))
        (expected (concat
                   "pkgs.emacsPackages.trivialBuild {\n"
                   "  pname = \"magit\";\n"
                   "  version = \"3.3.0\";\n"
                   "  src = pkgs.fetchFromGitHub {\n"
                   "    owner = \"magit\";\n"
                   "    repo = \"magit\";\n"
                   "    rev = \"v3.3.0\";\n"
                   "    sha256 = \"sha256-magit\";\n"
                   "  };\n"
                   "  packageRequires = with pkgs.emacsPackages; [ dash transient ];\n"
                   "  meta = {\n"
                   "    description = \"A Git porcelain inside Emacs.\";\n"
                   "    homepage = \"https://magit.vc\";\n"
                   "    license = pkgs.lib.licenses.gpl3;\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- Phase 4-B sub-task A: emacs-package :format / :native-comp ----------

(ert-deftest anvil-pkg-dsl-test-define-build-system-emacs-package-format-trivial ()
  "Explicit :format \"trivial\" parses to (:type emacs-package :format \"trivial\")."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-elisp
             (version "1.0.0")
             (source (url-fetch "https://example.com/my-elisp.tar.gz"
                                :sha256 "sha256-elisp"))
             (build-system (emacs-package :format "trivial")))
          t)
    (let ((bs (plist-get (gethash 'my-elisp anvil-pkg--registry) :build-system)))
      (should (eq 'emacs-package (plist-get bs :type)))
      (should (equal "trivial" (plist-get bs :format))))))

(ert-deftest anvil-pkg-dsl-test-define-build-system-emacs-package-format-melpa ()
  ":format \"melpa\" round-trips into the IR build-system plist."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-elisp
             (version "1.0.0")
             (source (url-fetch "https://example.com/my-elisp.tar.gz"
                                :sha256 "sha256-elisp"))
             (build-system (emacs-package :format "melpa")))
          t)
    (let ((bs (plist-get (gethash 'my-elisp anvil-pkg--registry) :build-system)))
      (should (eq 'emacs-package (plist-get bs :type)))
      (should (equal "melpa" (plist-get bs :format))))))

(ert-deftest anvil-pkg-dsl-test-define-rejects-unknown-format ()
  "Unknown :format value raises anvil-pkg-dsl-error at parse time."
  (should-error
   (macroexpand-1
    '(pkg-define my-elisp
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (emacs-package :format "garbage"))))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-define-build-system-emacs-package-native-comp ()
  ":native-comp t round-trips into the IR build-system plist."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-elisp
             (version "1.0.0")
             (source (url-fetch "https://example.com/my-elisp.tar.gz"
                                :sha256 "sha256-elisp"))
             (build-system (emacs-package :format "melpa" :native-comp t)))
          t)
    (let ((bs (plist-get (gethash 'my-elisp anvil-pkg--registry) :build-system)))
      (should (eq 'emacs-package (plist-get bs :type)))
      (should (equal "melpa" (plist-get bs :format)))
      (should (eq t (plist-get bs :native-comp))))))

(ert-deftest anvil-pkg-dsl-test-define-rejects-native-comp-on-non-emacs-package ()
  ":native-comp on stdenv / rust / python / go raises at parse time (L13)."
  (should-error
   (macroexpand-1
    '(pkg-define my-rust-tool
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (rust :cargo-sha256 "sha256-cargo" :native-comp t))))
   :type 'anvil-pkg-dsl-error)
  (should-error
   (macroexpand-1
    '(pkg-define my-py-tool
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (python :native-comp t))))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-render-emacs-package-melpa-golden ()
  "Renderer emits melpaBuild when :format is \"melpa\".
Phase 4-D L23: github-fetch + default :melpa-synth `auto' adds a
postUnpack block synthesising recipes/<pname>.
Phase 4-E L28: default :files comes from
`anvil-pkg--default-melpa-files' (full package-build spec)."
  (let* ((ir '(:name magit
               :version "3.3.0"
               :source (:type github-fetch
                        :owner "magit"
                        :repo "magit"
                        :rev "v3.3.0"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package :format "melpa")
               :depends-on (dash transient)))
         (recipe-line
          (concat "    (magit :fetcher git :url "
                  "\"https://github.com/magit/magit\" :files "
                  (format "(%s)"
                          (mapconcat (lambda (f) (format "%S" f))
                                     anvil-pkg--default-melpa-files
                                     " "))
                  ")\n"))
         (expected (concat
                    "pkgs.emacsPackages.melpaBuild {\n"
                    "  pname = \"magit\";\n"
                    "  version = \"3.3.0\";\n"
                    "  src = pkgs.fetchFromGitHub {\n"
                    "    owner = \"magit\";\n"
                    "    repo = \"magit\";\n"
                    "    rev = \"v3.3.0\";\n"
                    "    sha256 = \"sha256-magit\";\n"
                    "  };\n"
                    "  packageRequires = with pkgs.emacsPackages; [ dash transient ];\n"
                    "  postUnpack = ''\n"
                    "    mkdir -p $sourceRoot/recipes\n"
                    "    cat > $sourceRoot/recipes/magit <<'ANVIL_PKG_RECIPE_EOF'\n"
                    recipe-line
                    "    ANVIL_PKG_RECIPE_EOF\n"
                    "  '';\n"
                    "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-emacs-package-native-comp-golden ()
  "Renderer wraps with (emacsPackagesFor pkgs.emacs) when :native-comp t."
  (let ((ir '(:name dash
              :version "2.20.0"
              :source (:type github-fetch
                       :owner "magnars"
                       :repo "dash.el"
                       :rev "2.20.0"
                       :sha256 "sha256-dash")
              :build-system (:type emacs-package :format "trivial" :native-comp t)))
        (expected (concat
                   "(pkgs.emacsPackagesFor pkgs.emacs).trivialBuild {\n"
                   "  pname = \"dash\";\n"
                   "  version = \"2.20.0\";\n"
                   "  src = pkgs.fetchFromGitHub {\n"
                   "    owner = \"magnars\";\n"
                   "    repo = \"dash.el\";\n"
                   "    rev = \"2.20.0\";\n"
                   "    sha256 = \"sha256-dash\";\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- Phase 4-D sub-task A: :melpa-synth / :melpa-recipe / :melpa-files (L23) -

(ert-deftest anvil-pkg-dsl-test-melpa-synth-auto-with-github-fetch ()
  "L23: :format \"melpa\" + github-fetch + default `:melpa-synth auto'
emits a postUnpack block carrying the github URL.
Phase 4-E L28: synth uses the full default :files spec when
:melpa-files is omitted."
  (let* ((ir '(:name helm
               :version "3.9.7"
               :source (:type github-fetch
                        :owner "emacs-helm"
                        :repo "helm"
                        :rev "v3.9.7"
                        :sha256 "sha256-helm")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    (should (string-match-p "postUnpack = ''" out))
    (should (string-match-p "mkdir -p \\$sourceRoot/recipes" out))
    (should (string-match-p "cat > \\$sourceRoot/recipes/helm" out))
    (should (string-match-p
             "(helm :fetcher git :url \"https://github\\.com/emacs-helm/helm\" :files ("
             out))
    ;; L28: new default expands to lisp/*.el etc., so the synth carries
    ;; more than the bare ("*.el") glob.
    (should (string-match-p "\"lisp/\\*\\.el\"" out))
    (should (string-match-p ":exclude" out))))

(ert-deftest anvil-pkg-dsl-test-melpa-synth-auto-with-git-fetch ()
  "L23: :format \"melpa\" + git-fetch + default `auto' uses the upstream URL.
Phase 4-E L28: default :files spec is the full package-build glob."
  (let* ((ir '(:name myelp
               :version "0.1.0"
               :source (:type git-fetch
                        :url "https://example.com/myelp.git"
                        :rev "abc1234"
                        :sha256 "sha256-myelp")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    (should (string-match-p "postUnpack = ''" out))
    (should (string-match-p
             "(myelp :fetcher git :url \"https://example\\.com/myelp\\.git\" :files ("
             out))
    (should (string-match-p "\"lisp/\\*\\.el\"" out))
    (should (string-match-p ":exclude" out))))

(ert-deftest anvil-pkg-dsl-test-melpa-synth-auto-skipped-for-url-fetch ()
  "L23: :format \"melpa\" + url-fetch + `auto' silently skips synth
\(no postUnpack, no error)."
  (let* ((ir '(:name foo
               :version "1.0.0"
               :source (:type url-fetch
                        :url "https://example.com/foo-1.0.0.tar.gz"
                        :sha256 "sha256-foo")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    (should-not (string-match-p "postUnpack" out))
    (should (string-match-p "pkgs.emacsPackages.melpaBuild {" out))))

(ert-deftest anvil-pkg-dsl-test-melpa-synth-never-disables ()
  "L23: :melpa-synth `never' suppresses synth even on github-fetch."
  (let* ((ir '(:name helm
               :version "3.9.7"
               :source (:type github-fetch
                        :owner "emacs-helm"
                        :repo "helm"
                        :rev "v3.9.7"
                        :sha256 "sha256-helm")
               :build-system (:type emacs-package
                              :format "melpa"
                              :melpa-synth never)))
         (out (anvil-pkg-render-nix ir)))
    (should-not (string-match-p "postUnpack" out))))

(ert-deftest anvil-pkg-dsl-test-melpa-synth-force-on-url-fetch-errors ()
  "L23: :melpa-synth `force' over url-fetch raises `anvil-pkg-error'."
  (anvil-pkg-dsl-test--with-clean-registry
    (should-error
     (macroexpand-1
      '(pkg-define foo
         (version "1.0.0")
         (source (url-fetch "https://example.com/foo-1.0.0.tar.gz"
                            :sha256 "sha256-foo"))
         (build-system (emacs-package :format "melpa" :melpa-synth force))))
     :type 'anvil-pkg-error)))

(ert-deftest anvil-pkg-dsl-test-melpa-recipe-explicit-wins-and-files-keyword ()
  "L23: :melpa-recipe verbatim wins over auto-synth; separately,
:melpa-files overrides the default \(\"*.el\") glob list in the
synthesised recipe."
  ;; Part 1: explicit :melpa-recipe is emitted verbatim, no synth heuristic.
  (let* ((ir-explicit
          '(:name helm
            :version "3.9.7"
            :source (:type github-fetch
                     :owner "emacs-helm"
                     :repo "helm"
                     :rev "v3.9.7"
                     :sha256 "sha256-helm")
            :build-system (:type emacs-package
                           :format "melpa"
                           :melpa-recipe
                           "(helm :fetcher git :url \"u\" :files (\"*.el\" \"lisp/*.el\"))")))
         (out-explicit (anvil-pkg-render-nix ir-explicit)))
    (should (string-match-p "postUnpack = ''" out-explicit))
    ;; The user string is emitted verbatim, including its own URL "u".
    (should (string-match-p
             "(helm :fetcher git :url \"u\" :files (\"\\*\\.el\" \"lisp/\\*\\.el\"))"
             out-explicit))
    ;; Auto-synth would have used the github URL — verify it did NOT.
    (should-not
     (string-match-p "https://github\\.com/emacs-helm/helm" out-explicit)))
  ;; Part 2: :melpa-files overrides the default ("*.el") glob list.
  (let* ((ir-files
          '(:name helm
            :version "3.9.7"
            :source (:type github-fetch
                     :owner "emacs-helm"
                     :repo "helm"
                     :rev "v3.9.7"
                     :sha256 "sha256-helm")
            :build-system (:type emacs-package
                           :format "melpa"
                           :melpa-files ("*.el" "lisp/*.el"))))
         (out-files (anvil-pkg-render-nix ir-files)))
    (should (string-match-p "postUnpack = ''" out-files))
    (should (string-match-p
             "(helm :fetcher git :url \"https://github\\.com/emacs-helm/helm\" :files (\"\\*\\.el\" \"lisp/\\*\\.el\"))"
             out-files))))

;;;; --- Phase 4-E sub-task: L27 upstream MELPA recipe fetch + L28 default ----

(ert-deftest anvil-pkg-dsl-test-l28-default-files-uses-package-build-spec ()
  "L28: default :melpa-files spec is `anvil-pkg--default-melpa-files'.

When :melpa-files is omitted, the synth carries the full
`package-build-default-files-spec' equivalent so subdir / .el.in /
.info layouts match without manual configuration."
  (let* ((ir '(:name dash
               :version "2.20.0"
               :source (:type github-fetch
                        :owner "magnars"
                        :repo "dash.el"
                        :rev "2.20.0"
                        :sha256 "sha256-dash")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    ;; Top-level patterns
    (should (string-match-p "\"\\*\\.el\"" out))
    (should (string-match-p "\"\\*\\.el\\.in\"" out))
    ;; Subdir patterns
    (should (string-match-p "\"lisp/\\*\\.el\"" out))
    ;; Doc patterns
    (should (string-match-p "\"\\*\\.info\"" out))
    ;; Exclusion clause
    (should (string-match-p ":exclude" out))
    (should (string-match-p "\"\\*-test\\.el\"" out))))

(ert-deftest anvil-pkg-dsl-test-l27-auto-uses-upstream-recipe-when-fluid-hits ()
  "L27: :melpa-synth `auto' + render-fetch fluid returning recipe →
upstream body is emitted verbatim (no local synth).

The fluid is normally consulted only when
`anvil-pkg-emacs-melpa-upstream-fetch' is non-nil (it short-circuits
to nil otherwise), but the dsl render delegates entirely to the
fluid value, so re-binding it directly with a stub bypasses the
defcustom gate for test purposes."
  (let* ((upstream-recipe
          "(magit :fetcher github :repo \"magit/magit\" :files (\"lisp/*.el\" \"*.texi\"))")
         (anvil-pkg-emacs--render-fetch-fn
          (lambda (pname) (when (equal pname "magit") upstream-recipe)))
         (ir '(:name magit
               :version "3.3.0"
               :source (:type github-fetch
                        :owner "magit"
                        :repo "magit"
                        :rev "v3.3.0"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    (should (string-match-p "postUnpack = ''" out))
    ;; The upstream body landed verbatim.
    (should (string-match-p
             ":fetcher github :repo \"magit/magit\" :files (\"lisp/\\*\\.el\" \"\\*\\.texi\")"
             out))
    ;; The local synth's :fetcher-git URL did NOT.
    (should-not (string-match-p "fetcher git :url \"https://github\\.com/magit/magit\""
                                out))))

(ert-deftest anvil-pkg-dsl-test-l27-auto-falls-back-to-synth-on-miss ()
  "L27: :melpa-synth `auto' + render-fetch fluid returning nil →
synth proceeds normally (Phase 4-D behaviour)."
  (let* ((anvil-pkg-emacs--render-fetch-fn (lambda (_pname) nil))
         (ir '(:name magit
               :version "3.3.0"
               :source (:type github-fetch
                        :owner "magit"
                        :repo "magit"
                        :rev "v3.3.0"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package :format "melpa")))
         (out (anvil-pkg-render-nix ir)))
    (should (string-match-p "postUnpack = ''" out))
    ;; Synth always uses :fetcher git.
    (should (string-match-p
             "(magit :fetcher git :url \"https://github\\.com/magit/magit\""
             out))))

(ert-deftest anvil-pkg-dsl-test-l27-force-skips-upstream-fetch ()
  "L27: :melpa-synth `force' bypasses the upstream fetch fluid even
when it would have hit.  This is the user's explicit \"do not consult
MELPA\" signal."
  (let* ((calls 0)
         (anvil-pkg-emacs--render-fetch-fn
          (lambda (_pname) (cl-incf calls) "(magit :fetcher upstream)"))
         (ir '(:name magit
               :version "3.3.0"
               :source (:type github-fetch
                        :owner "magit"
                        :repo "magit"
                        :rev "v3.3.0"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package
                              :format "melpa"
                              :melpa-synth force)))
         (out (anvil-pkg-render-nix ir)))
    (should (= 0 calls))
    (should (string-match-p
             "(magit :fetcher git :url \"https://github\\.com/magit/magit\""
             out))))

(provide 'anvil-pkg-dsl-test)
;;; anvil-pkg-dsl-test.el ends here
