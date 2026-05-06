EMACS ?= emacs
SRC = anvil-pkg-compat.el anvil-pkg-state.el anvil-pkg.el anvil-pkg-dsl.el anvil-pkg-import.el anvil-pkg-emacs.el
TEST_SRC = test/anvil-pkg-test.el test/anvil-pkg-dsl-test.el test/anvil-pkg-import-test.el test/anvil-pkg-compat-test.el test/anvil-pkg-emacs-test.el test/anvil-pkg-state-test.el

EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

NIX ?= nix
SMOKE_DIR ?= /tmp/anvil-pkg-smoke

# Examples whose source/cargo/vendor hashes are real (Phase 4-H).
# Format:  <example-file>:<nix-attr>
SMOKE_EVAL_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/rust-ripgrep.el:ripgrep \
  examples/python-black.el:black \
  examples/go-hugo.el:hugo

# Subset of SMOKE_EVAL_PAIRS that are cheap enough to actually
# `nix build' on a developer machine (~5s + ~30s).  Rust / Go are
# excluded because cargo / go-mod cold pulls take 3-5min each.
SMOKE_BUILD_PAIRS = \
  examples/stdenv-hello.el:gnu-hello \
  examples/python-black.el:black

.PHONY: all test compile clean lint help smoke-eval smoke-build smoke-clean

all: test

help:
	@echo "make test         — run ERT suite (no nix required, mocked)"
	@echo "make compile      — byte-compile $(SRC), warnings-as-errors"
	@echo "make lint         — check-declare + byte-compile warnings"
	@echo "make clean        — remove .elc files"
	@echo "make smoke-eval   — render examples + 'nix flake check --no-build' (CI)"
	@echo "make smoke-build  — actually 'nix build' the cheap examples (local)"
	@echo "make smoke-clean  — rm -rf $(SMOKE_DIR)"

test:
	$(EMACS_BATCH) -l ert \
	  $(foreach f,$(TEST_SRC),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

lint: compile
	$(EMACS_BATCH) \
	  $(foreach f,$(SRC),-l $(f)) \
	  $(foreach f,$(SRC),--eval "(check-declare-file \"$(f)\")")

clean:
	rm -f *.elc test/*.elc

smoke-clean:
	rm -rf $(SMOKE_DIR)

# Render each example to $(SMOKE_DIR)/<basename>/flake.nix, then run
# `nix flake check --no-build' to validate the renderer's output
# against a real Nix evaluator without paying for source fetches.
smoke-eval:
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
	  $(NIX) flake check --no-build "path:$$out" || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-eval: all $(words $(SMOKE_EVAL_PAIRS)) examples passed"

# Actually realise the cheap subset.  Local-only by default.
smoke-build:
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
	  $(NIX) build "path:$$out#$$attr" --no-link --print-out-paths || exit 1; \
	  echo "::endgroup::"; \
	done
	@echo "smoke-build: all $(words $(SMOKE_BUILD_PAIRS)) examples built"
