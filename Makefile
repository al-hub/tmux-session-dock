# ==============================================================================
# tmux-session-dock - Makefile
# Automation for Build, Test, Lint, and Lifecycle Management
# ==============================================================================
.PHONY: all build test clean install uninstall status lint gate-a gate-b subpane gradient stress ci

all: build

build:
	@bash scripts/build-dist.sh

test:
	@bash tests/run-tests.sh --gate-a

gate-a:
	@bash tests/run-tests.sh --gate-a

gate-b:
	@bash tests/run-tests.sh --gate-b

subpane:
	@bash tests/run-tests.sh --subpane

gradient:
	@bash tests/run-tests.sh --gradient

stress:
	@bash tests/run-tests.sh --stress

lint:
	@bash -n setup.sh
	@bash -n session-dock.tmux
	@bash -n scripts/build-dist.sh
	@bash -n scripts/tmux-session-dock
	@bash -n scripts/tmux-theme-picker
	@bash -n scripts/tmux-command-palette
	@bash -n scripts/tmux-help-viewer
	@for f in scripts/lib/*.sh; do bash -n "$$f"; done
	@echo "✅ Syntax check passed."

status:
	@./setup.sh status

install: build
	@./setup.sh install

uninstall:
	@./setup.sh uninstall

clean:
	@rm -rf dist/
	@echo "✅ Clean completed."

ci: build lint test
