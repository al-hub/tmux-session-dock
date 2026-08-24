# tmux-session-dock ⚡

> **The ultra-fast, zero-flicker workspace dock & session orchestrator for tmux.**  
> *Window-Local Thin Presenter • 24fps Real-Time AI Waveform Telemetry • 38 Canonical Themes • Autonomous Lifecycle*

[![CI](https://github.com/al-hub/tmux-session-dock/actions/workflows/ci.yml/badge.svg)](https://github.com/al-hub/tmux-session-dock/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![tmux](https://img.shields.io/badge/tmux-3.2a+-brightgreen.svg)](https://github.com/tmux/tmux)
[![Themes](https://img.shields.io/badge/themes-38%20canonical-blueviolet.svg)](docs/THEMES.md)

[**🇰🇷 한국어 설명서 (Korean Manual)**](README.ko.md) | [**Architecture**](docs/ARCHITECTURE.md) | [**Keybindings**](docs/KEYBINDINGS.md) | [**Theme Catalog**](docs/THEMES.md)

---

## ✨ Features

- ⚡ **0.75ms In-Place Fast-Path & Zero-Flicker**: Eliminates traditional 5-second timeouts and screen flickering using a lightweight Window-Local Presenter architecture.
- 🌊 **24-Frame LUT Waveform Engine**: Real-time asynchronous background AI activity telemetry rendered at 30 FPS.
- 🗂️ **Subpane Hub (`Prefix + P`)**: Dedicated singleton terminal subpane with instant Top/Bottom positional swapping and height persistence.
- 📦 **Zero Time-Travel Pollution Archive**: Clean session snapshots and batch restoration (`o`) without polluting `$HISTFILE`.
- 🎨 **38 Canonical Themes & Live Rich Preview**: Standardized 3-tier taxonomy (`<category>-<family>[-focus].conf`) with live ANSI TrueColor preview chips (`Prefix + T`).
- 📖 **Interactive Help & Command Palette**: Searchable command palette (`Prefix + /`) and categorized keybinding popup (`Prefix + h`).
- 🔄 **Universal Lifecycle Controller (`./setup.sh`)**: Autonomous `install`, `update`, `uninstall`, `purge`, `status`, and `test` CLI.

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
set -g @session-dock-dotfiles-mode 'on'   # [Optional] Enable full ergonomics preset (Ctrl+a, path border, Alt-Nav)

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
```

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

## ⌨️ Keybindings Cheat Sheet (English & 2-Set Korean IME Supported)

| Keybinding (EN) | Keybinding (KR) | Action Description |
| :--- | :--- | :--- |
| **`Prefix + s`** | **`Prefix + ㄴ`** | Toggle session dock sidebar open / close |
| **`Prefix + T`** | **`Prefix + ㅆ`** / **`ㅅ`** | 🎨 Open 38-theme interactive picker with live ANSI preview |
| **`Prefix + /`** | **`Prefix + /`** | ⌨️ Open searchable command palette |
| **`Prefix + h`** / **`?`** | **`Prefix + ㅗ`** / **`?`** | 📖 Open interactive help viewer popup |
| **`Prefix + \|`** / **`%`** | **`Prefix + \|`** / **`%`** | Safe horizontal split (preserves dock layout) |
| **`Prefix + _`** / **`"`** | **`Prefix + _`** / **`"`** | Safe vertical split (preserves dock layout) |
| **`Alt + s`** (`M-s`) | **`Alt + ㄴ`** (`M-ㄴ`) | ⚡ Instant focus jump to session dock / return |

---

## 🏗️ Architecture

`tmux-session-dock` replaces physical pane migration (`move-pane`) with **Window-Local Thin Presenters** driven by a centralized **Logical Coordinator**:

```text
tmux Server (@session_dock_owner_client)
 ├── Logical Coordinator (Singleton State Engine)
 ├── Subpane Hub Session (Singleton Terminal Lease)
 └── Managed Windows
      ├── Window 1: Thin Presenter 1 ── Native switch-client ── Work Panes
      └── Window 2: Thin Presenter 2 ── Native switch-client ── Work Panes
```

---

## 🧪 Testing & Quality Assurance

```bash
# Run unit & contract tests
make gate-a

# Run subpane tests
make subpane

# Run waveform & animation tests
make gradient
```

---

## 📄 License

MIT License © 2026 al-hub
