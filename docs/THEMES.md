# 65 Canonical Themes & Visual Catalog

`tmux-session-dock` includes 65 pre-configured, professionally tuned color themes conforming to the Canonical 3-Tier Taxonomy:

$$\mathbf{Pattern:\quad} \texttt{<category>-<family>[-<flavor>][-focus].conf}$$

## 1. Category Overview

| Category Badge | Theme Families | Focus 1:1 Pairs |
| :--- | :--- | :--- |
| **`[BASE]`** | `base-classic` | Baseline default |
| **`[OPEN]`** | Dracula, Kanagawa, Everforest, Catppuccin Mocha, Nord, OneDark, Gruvbox, TokyoNight, RoséPine, Solarized Dark | 10 Standard + 10 Focus Pairs |
| **`[CODE]`** | Windows Terminal (Campbell), PowerShell, Cyberpunk Neon, Monokai Pro, GitHub Light | 5 Coding Shell themes |
| **`[EYE]`** | Astigmatism-Safe, Circadian-Warm (blue-light filtering), Scotopic-Forest, CVD-Safe (Okabe-Ito), Photophobia-Rose (FL-41), Myopia-Guard (negative polarity), Calm-Sage (low arousal), Dyslexia-Peach (light, Rello & Bigham 2017), **Presbyopia-Acuity** (560-590nm Topaz/accommodation assist), **Fovea-Lutein** (macular carotenoid 400-460nm HEV attenuation), **Low-Scatter-Slate** (Rayleigh anti-scatter warm graphite) | 10 Standard + 10 Focus Pairs + 1 Light (21 themes) |
| **`[DISP]`** | OLED PureBlack (100% true black), Paper Sepia (Kindle cream), IPS Backlight Grey (hides IPS glow), E-Ink Mono (4-level grey), Sunlight Outdoor (21:1 glare-proof), 256-Color Exact (lossless without TrueColor) | 6 Display-specific themes |
| **`[OS]`** | Ubuntu Aubergine, Apple Terminal Pro, Fedora Blue, Arch Cyan, Debian Magenta, NixOS Lavender | 6 Platform signatures |
| **`[RETRO]`** | CRT Phosphor Green, CRT Amber (0% blue light), Commodore 64 Blue, DOS CGA Blue, Game Boy DMG, Windows 95 Teal | 6 Retro hardware themes |

## 2. Adding a theme

A theme is a single `.conf` file; no code change is needed. Drop it in
`themes/` (or `~/.config/tmux/themes/` to keep it out of the repo) and the
picker finds it by scanning the directory. The filename prefix decides the
category badge, so `eye-my-theme.conf` lands under `[EYE]`. Copy an existing
file to get the full key set - every bundled theme defines the same keys.

## 3. Live Rich Preview Inspector

Press `Prefix + T` to open the interactive theme picker with live ANSI TrueColor preview chips and ergonomics metadata.
