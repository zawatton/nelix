EMACS ?= emacs
SRC = anvil-pkg-compat.el anvil-pkg-state.el anvil-pkg.el anvil-pkg-dsl.el anvil-pkg-import.el anvil-pkg-emacs.el
TEST_SRC = test/anvil-pkg-test.el test/anvil-pkg-uninstall-test.el test/anvil-pkg-upgrade-test.el test/anvil-pkg-info-test.el test/anvil-pkg-doctor-test.el test/anvil-pkg-dsl-test.el test/anvil-pkg-import-test.el test/anvil-pkg-compat-test.el test/anvil-pkg-emacs-test.el test/anvil-pkg-state-test.el
SCRIPT_SRC = scripts/anvil-pkg-render.el scripts/anvil-pkg-nelisp-smoke.el scripts/anvil-pkg-nelisp-ert-shim.el
EXPECTED_ERT_TESTS ?= 204

EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

NELISP ?= $(shell command -v nelisp 2>/dev/null || \
  { test -x ../nelisp.wt-mod-expt/target/nelisp && \
    printf '%s\n' ../nelisp.wt-mod-expt/target/nelisp; } || \
  { test -x ../nelisp/target/nelisp && \
    printf '%s\n' ../nelisp/target/nelisp; } || \
  { test -x ../nelisp/target/debug/nelisp && \
    printf '%s\n' ../nelisp/target/debug/nelisp; } || \
  printf '%s\n' nelisp)
NELISP_JSON_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-json/src/nelisp-json.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-json/src/nelisp-json.el; } || \
  { test -f ../nelisp/packages/nelisp-json/src/nelisp-json.el && \
    printf '%s\n' ../nelisp/packages/nelisp-json/src/nelisp-json.el; } || \
  printf '')
NELISP_TEXT_BUFFER_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/src/nelisp-text-buffer.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/src/nelisp-text-buffer.el; } || \
  { test -f ../nelisp/src/nelisp-text-buffer.el && \
    printf '%s\n' ../nelisp/src/nelisp-text-buffer.el; } || \
  printf '')
NELISP_REGEX_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-regex/src/nelisp-regex.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-regex/src/nelisp-regex.el; } || \
  { test -f ../nelisp/packages/nelisp-regex/src/nelisp-regex.el && \
    printf '%s\n' ../nelisp/packages/nelisp-regex/src/nelisp-regex.el; } || \
  printf '')
NELISP_EMACS_COMPAT_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/src/nelisp-emacs-compat.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/src/nelisp-emacs-compat.el; } || \
  { test -f ../nelisp/src/nelisp-emacs-compat.el && \
    printf '%s\n' ../nelisp/src/nelisp-emacs-compat.el; } || \
  printf '')
NELISP_ACTOR_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-actor/src/nelisp-actor.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-actor/src/nelisp-actor.el; } || \
  { test -f ../nelisp/packages/nelisp-actor/src/nelisp-actor.el && \
    printf '%s\n' ../nelisp/packages/nelisp-actor/src/nelisp-actor.el; } || \
  printf '')
NELISP_STDLIB_EVAL_SPECIAL_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/lisp/nelisp-stdlib-eval-special.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/lisp/nelisp-stdlib-eval-special.el; } || \
  { test -f ../nelisp/lisp/nelisp-stdlib-eval-special.el && \
    printf '%s\n' ../nelisp/lisp/nelisp-stdlib-eval-special.el; } || \
  printf '')
NELISP_CL_MACROS_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/lisp/nelisp-cl-macros.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/lisp/nelisp-cl-macros.el; } || \
  { test -f ../nelisp/lisp/nelisp-cl-macros.el && \
    printf '%s\n' ../nelisp/lisp/nelisp-cl-macros.el; } || \
  printf '')
NELISP_ERT_SHIM_SRC ?= scripts/anvil-pkg-nelisp-ert-shim.el
NELISP_PROCESS_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-process/src/nelisp-process.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-process/src/nelisp-process.el; } || \
  { test -f ../nelisp/packages/nelisp-process/src/nelisp-process.el && \
    printf '%s\n' ../nelisp/packages/nelisp-process/src/nelisp-process.el; } || \
  printf '')
NELISP_NETWORK_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-network/src/nelisp-network.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-network/src/nelisp-network.el; } || \
  { test -f ../nelisp/packages/nelisp-network/src/nelisp-network.el && \
    printf '%s\n' ../nelisp/packages/nelisp-network/src/nelisp-network.el; } || \
  printf '')
NELISP_HTTP_SRC ?= $(shell \
  { test -f ../nelisp.wt-mod-expt/packages/nelisp-http/src/nelisp-http.el && \
    printf '%s\n' ../nelisp.wt-mod-expt/packages/nelisp-http/src/nelisp-http.el; } || \
  { test -f ../nelisp/packages/nelisp-http/src/nelisp-http.el && \
    printf '%s\n' ../nelisp/packages/nelisp-http/src/nelisp-http.el; } || \
  printf '')

NIX ?= $(shell command -v nix 2>/dev/null || \
  { test -x /nix/var/nix/profiles/default/bin/nix && \
    printf '%s\n' /nix/var/nix/profiles/default/bin/nix; } || \
  printf '%s\n' nix)
NIX_CONFIG ?= experimental-features = nix-command flakes
SMOKE_DIR ?= /tmp/anvil-pkg-smoke

# Examples whose source/cargo/vendor hashes are real (Phase 4-H).
# Format:  <example-file>:<nix-attr>
SMOKE_EVAL_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/rust-ripgrep.el:ripgrep \
  examples/python-black.el:black \
  examples/go-hugo.el:hugo

RENDER_EXAMPLES = $(sort $(wildcard examples/*.el))

# Subset of SMOKE_EVAL_PAIRS that are cheap enough to actually
# `nix build' on a developer machine (~5s + ~30s).  Rust / Go are
# excluded because cargo / go-mod cold pulls take 3-5min each.
SMOKE_BUILD_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/python-black.el:black

.PHONY: all check verify-local check-whitespace nix-check test compile compile-tests check-declare clean lint help smoke-render smoke-pairs-check smoke-eval-pairs-check smoke-build-pairs-check smoke-eval smoke-build smoke-nelisp smoke-nelisp-capabilities smoke-nelisp-suite-readiness smoke-nelisp-suite-loadability smoke-nelisp-suite smoke-nelisp-local smoke-clean

all: check

check: lint test smoke-pairs-check smoke-render

verify-local: check nix-check smoke-eval smoke-build smoke-nelisp-local check-whitespace

help:
	@echo "make check        — run local no-Nix gate: lint + test + smoke metadata + render"
	@echo "make verify-local — run full local gate: check + repository flake + real Nix + NeLisp + whitespace"
	@echo "make nix-check    — run top-level 'nix flake check'"
	@echo "make test         — run ERT suite (no nix required, mocked)"
	@echo "make compile      — byte-compile runtime source/scripts, warnings-as-errors"
	@echo "make compile-tests — byte-compile $(TEST_SRC), warnings-as-errors"
	@echo "make check-declare — run check-declare over source/scripts/tests"
	@echo "make lint         — byte-compile source/scripts/tests + check-declare"
	@echo "make clean        — remove .elc files"
	@echo "make smoke-render — render every example to flake.nix (no nix required)"
	@echo "make smoke-pairs-check — validate smoke example pair lists (no nix required)"
	@echo "make smoke-eval   — render examples + 'nix flake check --no-build' (CI)"
	@echo "make smoke-build  — actually 'nix build' the cheap examples (local)"
	@echo "make smoke-nelisp — load compat layer with a local NeLisp binary"
	@echo "make smoke-nelisp-capabilities — print local standalone NeLisp backend capabilities"
	@echo "make smoke-nelisp-suite-readiness — audit whether standalone NeLisp can run the full suite"
	@echo "make smoke-nelisp-suite-loadability — load each ERT file under standalone NeLisp"
	@echo "make smoke-nelisp-suite — run full suite under standalone NeLisp once readiness passes"
	@echo "make smoke-nelisp-local — run all local NeLisp smoke gates"
	@echo "                  NIX=$(NIX)"
	@echo "                  NIX_CONFIG='$(NIX_CONFIG)'"
	@echo "                  NELISP=$(NELISP)"
	@echo "                  NELISP_JSON_SRC=$(NELISP_JSON_SRC)"
	@echo "                  NELISP_STDLIB_EVAL_SPECIAL_SRC=$(NELISP_STDLIB_EVAL_SPECIAL_SRC)"
	@echo "                  NELISP_CL_MACROS_SRC=$(NELISP_CL_MACROS_SRC)"
	@echo "                  NELISP_ERT_SHIM_SRC=$(NELISP_ERT_SHIM_SRC)"
	@echo "                  NELISP_HTTP_SRC=$(NELISP_HTTP_SRC)"
	@echo "make smoke-clean  — rm -rf $(SMOKE_DIR)"

check-whitespace:
	git diff --check

nix-check:
	NIX_CONFIG="$(NIX_CONFIG)" $(NIX) flake check

test:
	$(EMACS_BATCH) -l ert \
	  $(foreach f,$(TEST_SRC),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC) $(SCRIPT_SRC)

compile-tests:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(TEST_SRC)

check-declare:
	$(EMACS_BATCH) \
	  $(foreach f,$(SRC),-l $(f)) \
	  $(foreach f,$(SCRIPT_SRC),-l $(f)) \
	  $(foreach f,$(SRC) $(SCRIPT_SRC) $(TEST_SRC),--eval "(check-declare-file \"$(f)\")")

lint: compile compile-tests check-declare

clean:
	rm -f *.elc test/*.elc scripts/*.elc

smoke-clean:
	rm -rf $(SMOKE_DIR)

# Render every examples/*.el recipe without invoking Nix.  This is the
# lightweight local check for example/DSL drift; `smoke-eval' adds the
# real Nix evaluator on top for the four real-hash examples.
smoke-render:
	@test -n "$(RENDER_EXAMPLES)" || { \
	  echo "error: no examples/*.el files found"; \
	  exit 1; \
	}
	@for ex in $(RENDER_EXAMPLES); do \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-render $$ex"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  test -s "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix was not written"; \
	    exit 1; \
	  }; \
	  grep -Fq "outputs = { self, nixpkgs }:" "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix does not look like an anvil-pkg flake"; \
	    exit 1; \
	  }; \
	  grep -Fq "packages.x86_64-linux" "$$out/flake.nix" || { \
	    echo "error: $$out/flake.nix does not expose packages for system"; \
	    exit 1; \
	  }; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-render: all $(words $(RENDER_EXAMPLES)) examples rendered"

smoke-pairs-check: smoke-eval-pairs-check smoke-build-pairs-check
	@echo "smoke-pairs-check: example pair lists are valid"

smoke-eval-pairs-check:
	@test -n "$(strip $(SMOKE_EVAL_PAIRS))" || { \
	  echo "error: no smoke-eval example pairs configured"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_EVAL_PAIRS); do \
	  case "$$pair" in \
	    *:*:*) echo "error: smoke-eval pair '$$pair' must contain exactly one ':'"; exit 1 ;; \
	    *:*) ;; \
	    *) echo "error: smoke-eval pair '$$pair' must use <example-file>:<nix-attr>"; exit 1 ;; \
	  esac; \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  test -n "$$ex" || { \
	    echo "error: smoke-eval pair '$$pair' has an empty example file"; \
	    exit 1; \
	  }; \
	  test -n "$$attr" || { \
	    echo "error: smoke-eval pair '$$pair' has an empty nix attr"; \
	    exit 1; \
	  }; \
	  test -f "$$ex" || { \
	    echo "error: smoke-eval pair '$$pair' references missing example file"; \
	    exit 1; \
	  }; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/pair-check/eval/$$name; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example-attr-batch \"$$ex\" \"$$attr\" \"$$out\")" \
	    || exit 1; \
	done

smoke-build-pairs-check:
	@test -n "$(strip $(SMOKE_BUILD_PAIRS))" || { \
	  echo "error: no smoke-build example pairs configured"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_BUILD_PAIRS); do \
	  case "$$pair" in \
	    *:*:*) echo "error: smoke-build pair '$$pair' must contain exactly one ':'"; exit 1 ;; \
	    *:*) ;; \
	    *) echo "error: smoke-build pair '$$pair' must use <example-file>:<nix-attr>"; exit 1 ;; \
	  esac; \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  test -n "$$ex" || { \
	    echo "error: smoke-build pair '$$pair' has an empty example file"; \
	    exit 1; \
	  }; \
	  test -n "$$attr" || { \
	    echo "error: smoke-build pair '$$pair' has an empty nix attr"; \
	    exit 1; \
	  }; \
	  test -f "$$ex" || { \
	    echo "error: smoke-build pair '$$pair' references missing example file"; \
	    exit 1; \
	  }; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/pair-check/build/$$name; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example-attr-batch \"$$ex\" \"$$attr\" \"$$out\")" \
	    || exit 1; \
	done

# Render each example to $(SMOKE_DIR)/<basename>/flake.nix, then run
# `nix flake check --no-build' to validate the renderer's output
# against a real Nix evaluator without paying for source fetches.
smoke-eval: smoke-eval-pairs-check
	@command -v $(NIX) >/dev/null 2>&1 || { \
	  echo "error: $(NIX) not on PATH (Phase 4-H needs Nix to smoke-test)"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_EVAL_PAIRS); do \
	  ex=$${pair%:*}; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-eval $$ex"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  NIX_CONFIG="$(NIX_CONFIG)" $(NIX) flake check --no-build "path:$$out" || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-eval: all $(words $(SMOKE_EVAL_PAIRS)) examples passed"

# Actually realise the cheap subset.  Local-only by default.
smoke-build: smoke-build-pairs-check
	@command -v $(NIX) >/dev/null 2>&1 || { \
	  echo "error: $(NIX) not on PATH"; \
	  exit 1; \
	}
	@for pair in $(SMOKE_BUILD_PAIRS); do \
	  ex=$${pair%:*}; \
	  attr=$${pair#*:}; \
	  name=$$(basename $$ex .el); \
	  out=$(SMOKE_DIR)/$$name; \
	  echo "::group::smoke-build $$ex#$$attr"; \
	  $(EMACS_BATCH) -l scripts/anvil-pkg-render.el \
	    --eval "(anvil-pkg-render-example \"$$ex\" \"$$out\")" \
	    || exit 1; \
	  NIX_CONFIG="$(NIX_CONFIG)" $(NIX) build "path:$$out#$$attr" --no-link --print-out-paths || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-build: all $(words $(SMOKE_BUILD_PAIRS)) examples built"

# Narrow standalone-runtime smoke.  Current NeLisp CLI does not expose
# the full Emacs batch interface or complete file/env helpers, so this
# target proves only that the compat layer loads and the narrow helper
# surface available to this standalone image evaluates.  When local
# nelisp-json / nelisp-emacs-compat source files are available, it also
# proves compat dispatch through those real package-split backends.
# Native process / HTTP source probing lives in
# `smoke-nelisp-capabilities' because loading those definitions can
# expose functions before this standalone image has the lower runtime
# primitives needed to execute them.
smoke-nelisp:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-text-buffer-source "$(NELISP_TEXT_BUFFER_SRC)") (setq anvil-pkg-nelisp-smoke-regex-source "$(NELISP_REGEX_SRC)") (setq anvil-pkg-nelisp-smoke-emacs-compat-source "$(NELISP_EMACS_COMPAT_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (load "anvil-pkg-compat.el") (list :smoke-ok (and (fboundp (quote anvil-pkg-compat-runtime)) (memq (anvil-pkg-compat-runtime) (quote (emacs nelisp))) (equal (anvil-pkg-compat-string-trim " ok ") "ok") (equal (anvil-pkg-compat-string-trim nil) "") (fboundp (quote anvil-pkg-compat-json-parse)) (fboundp (quote anvil-pkg-compat-json-serialize)) (anvil-pkg-nelisp-smoke--json-backend-ok-p) (anvil-pkg-nelisp-smoke--buffer-backend-ok-p) (anvil-pkg-nelisp-smoke--unsupported-branches-ok-p) (anvil-pkg-nelisp-smoke--explicit-hooks-ok-p))))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":smoke-ok t" || { \
	    echo "error: smoke-nelisp did not report :smoke-ok t"; \
	    exit 1; \
	  }
	@echo "smoke-nelisp: compat layer loaded under $(NELISP)"

smoke-nelisp-capabilities:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-json-source "$(NELISP_JSON_SRC)") (setq anvil-pkg-nelisp-smoke-text-buffer-source "$(NELISP_TEXT_BUFFER_SRC)") (setq anvil-pkg-nelisp-smoke-regex-source "$(NELISP_REGEX_SRC)") (setq anvil-pkg-nelisp-smoke-emacs-compat-source "$(NELISP_EMACS_COMPAT_SRC)") (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-capabilities))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":native-gap-accounted t" || { \
	    echo "error: smoke-nelisp-capabilities did not account for native backend gaps"; \
	    exit 1; \
	  }
	@marker=$$(mktemp /tmp/anvil-pkg-nelisp-call-process.XXXXXX); \
	  rm -f "$$marker"; \
	  "$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke--load-native-prereqs) (anvil-pkg-nelisp-smoke--load-optional anvil-pkg-nelisp-smoke-process-source) (when (fboundp (quote nelisp-call-process)) (nelisp-call-process "/bin/sh" nil nil nil "-c" "printf ok > '"$$marker"'"))) ' >/dev/null 2>&1 || true; \
	  if test -s "$$marker"; then \
	    echo ":nelisp-call-process-executes t"; \
	  else \
	    echo ":nelisp-call-process-executes nil"; \
	  fi; \
	  rm -f "$$marker"

smoke-nelisp-suite-readiness:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-suite-readiness))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":readiness-audit-ok t" || { \
	    echo "error: smoke-nelisp-suite-readiness did not produce an actionable readiness audit"; \
	    exit 1; \
	  }

smoke-nelisp-suite-loadability:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@total=0; \
	for file in $(TEST_SRC); do \
	  echo "::group::smoke-nelisp-suite-loadability $$file"; \
	  out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (setq anvil-pkg-nelisp-smoke-suite-test-files (list "'"$$file"'")) (anvil-pkg-nelisp-smoke-suite-loadability))'); \
	  printf '%s\n' "$$out"; \
	  printf '%s\n' "$$out" | grep -q ":suite-loadable t" || { \
	    echo "error: smoke-nelisp-suite-loadability could not load $$file"; \
	    exit 1; \
	  }; \
	  printf '%s\n' "$$out" | grep -q ":runtime nelisp" || { \
	    echo "error: smoke-nelisp-suite-loadability did not run $$file in NeLisp runtime mode"; \
	    exit 1; \
	  }; \
	  count=$$(printf '%s\n' "$$out" | sed -n 's/.*:tests \([0-9][0-9]*\).*/\1/p'); \
	  test -n "$$count" || { \
	    echo "error: smoke-nelisp-suite-loadability did not report a test count for $$file"; \
	    exit 1; \
	  }; \
	  total=$$((total + count)); \
	  echo "::endgroup::"; \
	done; \
	test "$$total" -eq $(EXPECTED_ERT_TESTS) || { \
	  echo "error: smoke-nelisp-suite-loadability registered $$total tests, expected $(EXPECTED_ERT_TESTS)"; \
	  exit 1; \
	}; \
	echo "smoke-nelisp-suite-loadability: all $(words $(TEST_SRC)) ERT files loaded ($$total tests)"

smoke-nelisp-suite:
	@{ test -x "$(NELISP)" || command -v "$(NELISP)" >/dev/null 2>&1; } || { \
	  echo "error: $(NELISP) not found (set NELISP=/path/to/nelisp)"; \
	  exit 1; \
	}
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-run-suite))'); \
	  printf '%s\n' "$$out"; \
	  if printf '%s\n' "$$out" | grep -q ":suite-run nil"; then \
	    echo "error: standalone NeLisp is not ready to run the full suite"; \
	    exit 1; \
	  fi

smoke-nelisp-local: smoke-nelisp smoke-nelisp-capabilities smoke-nelisp-suite-readiness smoke-nelisp-suite-loadability
	@out=$$("$(NELISP)" --eval '(progn (setq anvil-pkg-nelisp-smoke-stdlib-eval-special-source "$(NELISP_STDLIB_EVAL_SPECIAL_SRC)") (setq anvil-pkg-nelisp-smoke-cl-macros-source "$(NELISP_CL_MACROS_SRC)") (setq anvil-pkg-nelisp-smoke-ert-shim-source "$(NELISP_ERT_SHIM_SRC)") (setq anvil-pkg-nelisp-smoke-actor-source "$(NELISP_ACTOR_SRC)") (setq anvil-pkg-nelisp-smoke-process-source "$(NELISP_PROCESS_SRC)") (setq anvil-pkg-nelisp-smoke-network-source "$(NELISP_NETWORK_SRC)") (setq anvil-pkg-nelisp-smoke-http-source "$(NELISP_HTTP_SRC)") (load "scripts/anvil-pkg-nelisp-smoke.el") (anvil-pkg-nelisp-smoke-run-suite))'); \
	  printf '%s\n' "$$out"; \
	  if printf '%s\n' "$$out" | grep -q ":suite-run nil"; then \
	    echo "smoke-nelisp-local: full standalone NeLisp suite is not ready yet (expected until lower primitives land)"; \
	  elif printf '%s\n' "$$out" | grep -q ":suite-run t"; then \
	    echo "smoke-nelisp-local: full standalone NeLisp suite passed"; \
	  else \
	    echo "error: smoke-nelisp-local could not determine standalone suite status"; \
	    exit 1; \
	  fi
