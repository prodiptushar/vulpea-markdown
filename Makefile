EMACS ?= emacs

.PHONY: test compile clean

test:
	$(EMACS) --batch -l test/run-tests.el

compile:
	$(EMACS) --batch -l test/compile.el

clean:
	rm -f *.elc test/*.elc
