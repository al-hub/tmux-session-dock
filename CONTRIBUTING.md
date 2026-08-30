# Contributing to tmux-session-dock

Thank you for your interest in contributing!

## 🛠️ Development Workflow

1. Fork the repository and clone locally.
2. Edit modular source files in `scripts/lib/*.sh`.
3. Compile the production bundle:
   ```bash
   make build
   ```
4. Run syntax checks & test suites:
   ```bash
   make lint
   make test          # tests/ci.list — every entry must pass
   ```
   Every `tests/**/test-*.sh` must be listed in exactly one of `tests/ci.list`
   or `tests/manual.list` (`make test-health` checks this). A test asserts one
   user-visible fact (pane geometry, captured text, session state, a documented
   `@session-dock-*` option); it never reads internal `@dotfiles_*` runtime
   options or trace logs. A wait loop that times out is a failure.
5. Submit a clean Pull Request targeting `main`.

Known gaps and the reasoning behind recent stability/performance work are
recorded in [docs/BACKLOG.md](docs/BACKLOG.md); read it before starting a
larger change.
