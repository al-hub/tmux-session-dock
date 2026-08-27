# Keybindings & Navigation Cheat Sheet

Uses standard English keys without input-method-specific aliases.

## 1. Global Prefix Bindings (`Ctrl + a` by default)

| Keybinding | Action Description |
| :--- | :--- |
| **`Prefix + s`** | Toggle session dock sidebar open / close |
| **`Prefix + S`** | ⚙️ Open subpane stack & position configurator popup |
| **`Prefix + T`** | Open 47-theme interactive picker with live ANSI preview |
| **`Prefix + /`** | Open searchable command palette |
| **`Prefix + h`** / **`?`** | Open interactive help viewer popup |
| **`Prefix + \|`** / **`%`** | Work-pane safe horizontal split (preserves dock geometry) |
| **`Prefix + _`** / **`"`** | Work-pane safe vertical split (preserves dock geometry) |
| **`Alt + s`** (`M-s`) | Quick jump focus directly to session dock / return |

## 2. Inside the Session Dock TUI

| Primary / Zero-Lag Key | Vim Key | Action Description |
| :--- | :--- | :--- |
| **`↓` / `Ctrl + n`** | **`j`** | Navigate session rows downward |
| **`↑` / `Ctrl + p`** | **`k`** | Navigate session rows upward |
| **`Enter`** | **`Enter`** | Switch immediately to selected session |
| **`Delete` / `Backspace` / `Ctrl + d`** | **`d`** | Delete / Archive current session |
| **`F2` / `Ctrl + r`** | **`r`** | Rename selected session |
| **`+` / `Insert`** | **`c`** | Create new named session |
| **`Tab`** | **`o`** | Toggle session archive & restoration view |
| **`s`** | **`s`** | Toggle subpane (terminal) open / close |
| **`S`** | **`S`** | ⚙️ Open subpane stack configurator popup |
| **`p`** | **`p`** | Swap subpane position (Top ↔ Bottom) |
| **`Space`** | **`Space`** | Mark / unmark selected row |
| **`a`** | **`a`** | Mark / unmark all rows |
| **`/`** | **`/`** | Search / filter session list |
| **`h` / `?`** | **`h` / `?`** | View keybinding help popup |
| **`Esc` / `Ctrl + c`** | **`q`** | Close dock sidebar and return to work pane |
