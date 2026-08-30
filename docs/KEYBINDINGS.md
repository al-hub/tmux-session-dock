# Keybindings & Navigation Cheat Sheet

Describes `v0.3.51`. Every row below is bound by `session-dock.tmux` (or by the
ergonomics preset where noted); nothing here relies on an input-method alias.

## 1. Global Prefix Bindings (`Ctrl + a` with the ergonomics preset, otherwise your own prefix)

| Keybinding | Action Description | Override option |
| :--- | :--- | :--- |
| **`Prefix + s`** | Toggle session dock sidebar open / close | `@session-dock-key` |
| **`Prefix + S`** | ⚙️ Settings popup: subpane stack count & position, IME mode, switch recovery | — |
| **`Prefix + T`** | 🎨 59-theme interactive picker with live ANSI preview | `@session-dock-theme-key` |
| **`Prefix + /`** | ⌨️ Searchable command palette | `@session-dock-palette-key` |
| **`Prefix + h`** | 📖 Interactive help viewer popup | `@session-dock-help-key` |
| **`Prefix + \|`** / **`%`** | Work-pane safe horizontal split (preserves dock geometry) | — |
| **`Prefix + _`** / **`"`** | Work-pane safe vertical split (preserves dock geometry) | — |

`Prefix + ?` is tmux's own key list, not this plugin's help popup.

## 2. Root Bindings (no prefix)

| Keybinding | Action Description | Override option |
| :--- | :--- | :--- |
| **`Alt + s`** (`M-s`) | Quick jump focus directly to the dock / return | `@session-dock-quick-jump-key` |
| **`Alt + ←/→/↑/↓`** | Geometric pane focus; wraps at the edges. From a work pane, `Alt + ←` enters the dock only when the dock is the pane immediately to the left | — |
| **`Ctrl + Alt + ←/→/↑/↓`** | Swap the focused work pane in that direction. The dock and its subpanes never move | — |

Both Alt bindings are installed only when `@session-dock-ergonomics` leaves them
enabled (the default).

## 3. Ergonomics Preset Only (`@session-dock-dotfiles-mode 'on'`)

| Keybinding | Action Description |
| :--- | :--- |
| **`Ctrl + a`** | Prefix (replaces `Ctrl + b`) |
| **`Prefix + Tab`** / **`Prefix + BTab`** | Next / previous window |
| **`Prefix + c`** | New window in the current pane's directory |

## 4. Inside the Session Dock TUI

| Primary / Zero-Lag Key | Vim Key | Action Description |
| :--- | :--- | :--- |
| **`↓` / `Ctrl + n`** | **`j`** | Navigate session rows downward |
| **`↑` / `Ctrl + p`** | **`k`** | Navigate session rows upward |
| **`Enter`** | **`Enter`** | Switch immediately to selected session |
| **`Delete` / `Backspace` / `Ctrl + d`** | **`d`** | Delete / Archive current session |
| **`F2` / `Ctrl + r`** | **`r`** | Rename selected session |
| **`+` / `Insert`** | **`c`** | Create new named session |
| **`Tab`** | **`o`** | Toggle session archive & restoration view |
| **`s`** / **`S`** | **`s`** | Toggle subpane (terminal) open / close |
| **`p`** | **`p`** | Swap subpane stack position (Top ↔ Bottom) |
| **`Space`** | **`Space`** | Mark / unmark selected row |
| **`a`** | **`a`** | Mark / unmark all rows |
| **`/`** | **`/`** | Search / filter session list |
| **`h` / `?`** | **`h` / `?`** | View keybinding help popup |
| **`Esc` / `Ctrl + c`** | **`q`** | Close dock sidebar and return to work pane |

The stack **count and position** are set from the `Prefix + S` popup, not from
inside the TUI; `S` there is an alias of `s` (see BACKLOG R2).
