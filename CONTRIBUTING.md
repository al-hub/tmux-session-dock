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
   make gate-a
   make subpane
   make gradient
   ```
5. Submit a clean Pull Request targeting `main`.
