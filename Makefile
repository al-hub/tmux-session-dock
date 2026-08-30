# ==============================================================================
# tmux-session-dock - Makefile
# Automation for Build, Test, Lint, and Lifecycle Management
# ==============================================================================
.PHONY: all build test test-manual test-health check-dist clean install uninstall status lint ci

all: build

build:
	@bash scripts/build-dist.sh

test:
	@bash tests/run-tests.sh --ci

test-manual:
	@bash tests/run-tests.sh --manual

test-health:
	@bash tests/run-tests.sh --health

check-dist: build
	@git diff --quiet -- dist/ || { echo "❌ dist/ is stale: commit the rebuilt bundle"; git --no-pager diff --stat -- dist/; exit 1; }
	@echo "✅ dist/ matches the build."

lint:
	@bash -n setup.sh
	@bash -n session-dock.tmux
	@bash -n scripts/build-dist.sh
	@bash -n scripts/tmux-session-dock
	@bash -n scripts/tmux-theme-picker
	@bash -n scripts/tmux-command-palette
	@bash -n scripts/tmux-help-viewer
	@bash -n scripts/tmux-session-dock-ime
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

ci: build lint check-dist test
