SHELL := /usr/bin/env bash
BATS  ?= bats
PY    ?= python3

SH_FILES := $(shell find scripts hooks bin eval -type f \( -name '*.sh' -o -name 'openbrain' -o -name 'run.sh' \) 2>/dev/null)

.PHONY: test test-bats test-py lint check-deps clean

test: lint test-bats test-py

lint:
	@echo "== shellcheck =="
	@shellcheck -x -s bash -P scripts $(SH_FILES)

test-bats:
	@echo "== bats =="
	@command -v $(BATS) >/dev/null 2>&1 || { \
		echo "FALTA bats: npm install -g bats --prefix ~/.local  (o: make test BATS=<ruta>/bats)" >&2; \
		exit 1; \
	}
	@mkdir -p tests/.bats-tmp
	@TMPDIR="$(CURDIR)/tests/.bats-tmp" $(BATS) --tap tests/bats

test-py:
	@echo "== pytest =="
	@if ! $(PY) -c 'import pytest' 2>/dev/null; then \
		echo "FALTA pytest: pip3 install --user --break-system-packages pytest  (o: make test PY=<venv>/bin/python)" >&2; \
		exit 1; \
	fi; \
	dirs=""; \
	[ -d tests/py ] && dirs="tests/py"; \
	[ -d tools/refresh-claude-md ] && dirs="$$dirs tools/refresh-claude-md"; \
	if [ -z "$$dirs" ]; then \
		echo "sin tests python todavía"; \
	else \
		$(PY) -m pytest -q $$dirs; \
	fi

clean:
	@rm -rf tests/.bats-tmp .pytest_cache tools/refresh-claude-md/.pytest_cache
	@find . -name __pycache__ -type d -prune -exec rm -rf {} +

check-deps:
	@rc=0; \
	for t in bash jq openssl gitleaks gpg shellcheck bats python3; do \
	  if command -v $$t >/dev/null; then echo "OK    $$t"; else echo "FALTA $$t"; rc=1; fi; done; \
	if $(PY) -c 'import pytest' 2>/dev/null; then echo "OK    pytest"; else echo "FALTA pytest"; rc=1; fi; \
	exit $$rc
