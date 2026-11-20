# Makefile for niori.el
#
# Targets:
#   make check    run the ERT test suite
#   make compile  byte-compile every source file
#   make clean    remove build products
#   make install  install the standalone app under PREFIX (default ~/.local)

EMACS ?= emacs

ELS := $(wildcard *.el)
TESTS := $(wildcard tests/test-*.el)
PREFIX ?= $(HOME)/.local

.PHONY: check compile clean install

check:
	$(EMACS) -Q --batch -L . -L tests \
	  -l tests/niori-test-helper.el \
	  $(foreach test,$(TESTS),-l $(test)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(ELS)

clean:
	rm -f -- *.elc tests/*.elc

install: compile
	install -Dm755 bin/niori $(PREFIX)/bin/niori
	install -d $(PREFIX)/share/emacs/site-lisp/niori
	install -m644 $(ELS) *.elc $(PREFIX)/share/emacs/site-lisp/niori/
	install -d $(PREFIX)/share/emacs/site-lisp/niori/tests $(PREFIX)/share/emacs/site-lisp/niori/icons
	install -m644 tests/*.el $(PREFIX)/share/emacs/site-lisp/niori/tests/
	install -m644 icons/* $(PREFIX)/share/emacs/site-lisp/niori/icons/
	install -Dm644 icons/niori.png $(PREFIX)/share/icons/hicolor/64x64/apps/niori.png
	sed 's|^Exec=.*|Exec=$(PREFIX)/bin/niori|' etc/niori.desktop \
	  > $(PREFIX)/share/applications/niori.desktop
	@echo "Installed niori under $(PREFIX) (restart your session to see the menu entry)"
