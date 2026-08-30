# tmux-session-dock ⚡

> **The ultra-fast, zero-flicker workspace dock & session orchestrator for tmux.**  
> *Window-Local Thin Presenter • 24fps Real-Time AI Waveform Telemetry • 59 Canonical Themes • Autonomous Lifecycle*

[![CI](https://github.com/al-hub/tmux-session-dock/actions/workflows/ci.yml/badge.svg)](https://github.com/al-hub/tmux-session-dock/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![tmux](https://img.shields.io/badge/tmux-3.2a+-brightgreen.svg)](https://github.com/tmux/tmux)
[![Themes](https://img.shields.io/badge/themes-59%20canonical-blueviolet.svg)](docs/THEMES.md)

[**🇰🇷 한국어 설명서 (Korean Manual)**](README.ko.md) | [**Architecture**](docs/ARCHITECTURE.md) | [**Keybindings**](docs/KEYBINDINGS.md) | [**Theme Catalog**](docs/THEMES.md)

> Working on this repo with an AI CLI? Start at [CLAUDE.md](CLAUDE.md).

---

## ✨ Major Additions over Stock tmux

### 1. Session-management sidebar

- **Open, save, move, and select**: Toggle the dock with `Prefix + s`, select a row, and press `Enter` to switch sessions immediately. Create, rename, archive/delete, and restore sessions from the dock.
- **Zero-flicker switching**: Window-Local Presenters use native `switch-client` instead of physically moving panes.
- **Gradient activity effect**: Detects background AI CLI activity and renders it as a live waveform gradient on session rows, including rows for non-selected sessions. Turn it off or set the wave speed in milliseconds from `Prefix + S`.
- **Awaiting mark**: A session whose AI stopped and that you have not visited since gets a `●` beside its name, and the header counts them, so a finished run is visible without opening each session in turn. It says your attention is wanted, not that the work succeeded.
- **Subpane stack**: Open/close a terminal subpane beside the dock (`s`), stack up to three of them (`Prefix + S`), swap the stack Top/Bottom (`p`); each slot keeps its own height across session switches.
- **Archive**: Snapshot and batch-restore sessions without polluting `$HISTFILE`.

### 2. Theme management

- **Dozens of bundled themes**: 59 Canonical themes are included.
- **Select and customize themes**: Choose with live ANSI preview via `Prefix + T`; set the default through `@session-dock-theme` or adjust a theme configuration file.

### 3. Keybindings and status visibility

- **Status and help**: `Prefix + h` opens the keybinding help, `Prefix + /` opens the searchable command palette, `Prefix + S` opens the settings popup, and `./setup.sh status` reports installation status.
- **No keybinding editor UI**: The dock does not currently provide an in-UI keybinding editor. Change bindings in the tmux configuration instead (such as `@session-dock-key`).
- **Workspace-safe controls**: Safe split bindings and `Alt + s` provide fast dock focus navigation while preserving the workspace layout.

### 4. Installation and verification lifecycle

- **Unified controller**: `./setup.sh` manages `install`, `update`, `uninstall`, `status`, `build`, `test`, and `purge`.

---

## 🚀 Quick Start

### 1. Via TPM (Tmux Plugin Manager) — Recommended

Add to your `~/.tmux.conf`:
```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'al-hub/tmux-session-dock'

# Optional customizations
set -g @session-dock-key 's'              # Toggle sidebar key (Prefix + s)
set -g @session-dock-width '34'           # Sidebar column width
set -g @session-dock-theme 'open-tokyonight' # Default theme
set -g @session-dock-dotfiles-mode 'on'   # [Optional] Enable full ergonomics preset (Ctrl+a, path border, Alt-Nav, Tab window switching)
set -g @session-dock-ime 'restore'        # [Optional] IME → English on sidebar focus: off | on | restore (restore puts 한/영 back on leave)
set -g @session-dock-switch-recovery 'popup' # [Optional] When Enter cannot land on a session (dead sidebar presenter): popup = show the diagnosis and ask | auto = respawn silently | off
set -g @session-dock-subpane-count '1'    # [Optional] Terminal subpanes stacked beside the dock: 1 | 2 | 3
set -g @session-dock-subpane-position 'bottom' # [Optional] Stack the subpanes below or above the dock: bottom | top
set -g @session-dock-gradient 'on'        # [Optional] Activity gradient on rows whose AI CLI is working: on | off
set -g @session-dock-gradient-speed '1000' # [Optional] One wave cycle in milliseconds, 400-4000 (24 frames per cycle)
set -g @session-dock-awaiting 'on'         # [Optional] Mark sessions whose AI stopped and that you have not visited: on | off
set -g @session-dock-awaiting-blink 'always' # [Optional] Blink that mark: always | off | milliseconds (the state itself never times out)
set -g @session-dock-awaiting-after '30000'  # [Optional] How long a session must be silent before it is marked, in ms, measured from its last output (floor: the busy window, 10000)

# Every option above is also editable from the Prefix + S popup.
# Key overrides: @session-dock-theme-key, @session-dock-help-key,
# @session-dock-palette-key, @session-dock-quick-jump-key, @session-dock-ergonomics
run '~/.tmux/plugins/tpm/tpm'
```
Press `Prefix + I` inside tmux to install and activate.

### 2. Standalone One-Line cURL Installer

```bash
# Install full ergonomics mode (Recommended)
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- install

# Update
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- update

# Clean Purge
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- purge

# Pin or downgrade to a specific release (tag, branch or commit)
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- install --ref v0.3.19

# Back to latest main
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- update
```

`--ref` (or `TMUX_DOCK_REF=...`) works for `install` and `update` on the managed clone in `~/.local/share/tmux-session-dock`. Without it, both commands track the latest `main`. Restart the tmux server (`tmux kill-server`) so running sidebars pick up the new version; `./setup.sh status` shows which ref the installed symlinks point at.

### 3. Local Git Clone & Universal Setup Controller

```bash
git clone https://github.com/al-hub/tmux-session-dock.git ~/.local/share/tmux-session-dock
cd ~/.local/share/tmux-session-dock

# Install & configure
./setup.sh install

# Check status
./setup.sh status

# Run self-contained test matrix
./setup.sh test
```

---

## ⌨️ Keybindings Cheat Sheet

| Keybinding | Action Description |
| :--- | :--- |
| **`Prefix + s`** | Toggle session dock sidebar open / close |
| **`Prefix + S`** | ⚙️ Open the settings popup (subpane stack & position, IME, switch recovery, activity gradient) |
| **`Prefix + T`** | 🎨 Open 59-theme interactive picker with live ANSI preview |
| **`Prefix + /`** | ⌨️ Open searchable command palette |
| **`Prefix + h`** | 📖 Open interactive help viewer popup |
| **`Prefix + \|`** / **`%`** | Safe horizontal split (preserves dock layout) |
| **`Prefix + _`** / **`"`** | Safe vertical split (preserves dock layout) |
| **`Alt + s`** (`M-s`) | ⚡ Instant focus jump to session dock / return |
| **`Alt + ←/→/↑/↓`** | 🧭 Geometric pane focus (wraps; enters the dock only from the pane beside it) |
| **`Ctrl + Alt + ←/→/↑/↓`** | ↔️ Swap the focused work pane in that direction (never moves the dock) |
| **`Prefix + Tab`** / **`Prefix + BTab`** | Next / previous window — only with `@session-dock-dotfiles-mode 'on'` |

Inside the dock TUI: `j`/`k` or arrows to move, `Enter` to switch, `s` subpane,
`p` swap position, `d` archive, `c` create, `r` rename, `/` filter, `o`/`Tab`
archive view, `h` help, `q` close. Full table: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md).

---

## 🏗️ Architecture

`tmux-session-dock` replaces physical pane migration (`move-pane`) with **Window-Local Thin Presenters**. There is no coordinator daemon: every managed window runs its own presenter, and they agree through shared tmux server state (hidden environment variables for transient bookkeeping, options for durable identity, pid locks for mutual exclusion).

```text
tmux Server
 ├── shared state: transition flags (hidden env) · @dotfiles_sidebar_owner_client · pid locks
 ├── AI Activity Observer (one per server)
 ├── Subpane Hub Session (singleton terminal lease, 1..3 slots)
 └── Managed Windows
      ├── Window 1: Thin Presenter 1 ── native switch-client ── Work Panes
      └── Window 2: Thin Presenter 2 ── native switch-client ── Work Panes
```

Full design and invariants: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Open items and the reasoning behind recent work: [docs/BACKLOG.md](docs/BACKLOG.md).

---

## 🧪 Testing & Quality Assurance

```bash
# Run every test in tests/ci.list (unit, contract, subpane, gradient)
make test

# Check that every test file is listed exactly once (ci.list or manual.list)
make test-health

# Tests that need your live tmux server (run on purpose only)
SESSION_DOCK_ALLOW_USER_SERVER=1 make test-manual
```

---

## 📄 License

MIT License © 2026 al-hub
