# Keybindings & Navigation Cheat Sheet

Supports both standard English keys and Korean (2-Set IME) keys seamlessly without mode switching.

## 1. Global Prefix Bindings (`Ctrl + a` by default)

| Keybinding (EN) | Keybinding (KR) | Action Description |
| :--- | :--- | :--- |
| **`Prefix + s`** | **`Prefix + ㄴ`** | Toggle session dock sidebar open / close |
| **`Prefix + T`** | **`Prefix + ㅆ`** / **`ㅅ`** | Open 38-theme interactive picker with live ANSI preview |
| **`Prefix + /`** | **`Prefix + /`** | Open searchable command palette |
| **`Prefix + h`** / **`?`** | **`Prefix + ㅗ`** / **`?`** | Open interactive help viewer popup |
| **`Prefix + \|`** / **`%`** | **`Prefix + \|`** / **`%`** | Work-pane safe horizontal split (preserves dock geometry) |
| **`Prefix + _`** / **`"`** | **`Prefix + _`** / **`"`** | Work-pane safe vertical split (preserves dock geometry) |
| **`Alt + s`** (`M-s`) | **`Alt + ㄴ`** (`M-ㄴ`) | Quick jump focus directly to session dock / return |

## 2. Inside the Session Dock TUI

| Primary / Zero-Lag Key | Vim / Korean Key | Action Description |
| :--- | :--- | :--- |
| **`↓` / `Ctrl + n`** | **`j` / `ㅓ`** | Navigate session rows downward |
| **`↑` / `Ctrl + p`** | **`k` / `ㅏ`** | Navigate session rows upward |
| **`Enter`** | **`Enter`** | Switch immediately to selected session |
| **`Delete` / `Backspace` / `Ctrl + d`** | **`d` / `ㅇ`** | Delete / Archive current session |
| **`F2` / `Ctrl + r`** | **`r` / `ㄱ`** | Rename selected session |
| **`+` / `Insert`** | **`c` / `ㅊ`** | Create new named session |
| **`Tab`** | **`o` / `ㅐ`** | Toggle session archive & restoration view |
| **`s` / `ㄴ`** | **`s` / `ㄴ`** | Toggle subpane (terminal) open / close |
| **`p` / `ㅔ`** | **`p` / `ㅔ`** | Swap subpane position (Top ↔ Bottom) |
| **`Space`** | **`Space`** | Mark / unmark selected row |
| **`a` / `ㅁ`** | **`a` / `ㅁ`** | Mark / unmark all rows |
| **`/`** | **`/`** | Search / filter session list |
| **`h` / `?` / `ㅗ`** | **`h` / `?` / `ㅗ`** | View keybinding help popup |
| **`Esc` / `Ctrl + c`** | **`q` / `ㅂ`** | Close dock sidebar and return to work pane |
