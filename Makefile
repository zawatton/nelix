EMACS ?= emacs
SRC = anvil-pkg.el anvil-pkg-dsl.el
TEST_SRC = test/anvil-pkg-test.el test/anvil-pkg-dsl-test.el

EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

.PHONY: all test compile clean lint help

all: test

help:
	@echo "make test     — run ERT suite (no nix required, mocked)"
	@echo "make compile  — byte-compile $(SRC), warnings-as-errors"
	@echo "make lint     — check-declare + byte-compile warnings"
	@echo "make clean    — remove .elc files"

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
