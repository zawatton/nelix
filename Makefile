EMACS ?= emacs
SRC = anvil-pkg.el
TEST_SRC = test/anvil-pkg-test.el

EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

.PHONY: all test compile clean lint help

all: test

help:
	@echo "make test     — run ERT suite (no nix required, mocked)"
	@echo "make compile  — byte-compile $(SRC), warnings-as-errors"
	@echo "make lint     — check-declare + byte-compile warnings"
	@echo "make clean    — remove .elc files"

test:
	$(EMACS_BATCH) -l ert -l $(TEST_SRC) -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

lint: compile
	$(EMACS_BATCH) -l $(SRC) \
	  --eval "(check-declare-file \"anvil-pkg.el\")"

clean:
	rm -f *.elc test/*.elc
