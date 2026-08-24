#!/usr/bin/env bash
# ==============================================================================
# scripts/build-dist.sh
# Production Single-Binary Bundler for tmux-session-dock
# Zero Sourcing I/O Overhead | Fully Self-Contained
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
OUTPUT_BIN="$DIST_DIR/tmux-session-dock"

mkdir -p "$DIST_DIR"

cat <<'EOF_HEADER' > "$OUTPUT_BIN"
#!/usr/bin/env bash
# ==============================================================================
# tmux-session-dock (Bundled Standalone Production Distribution)
# https://github.com/al-hub/tmux-session-dock
# Auto-generated. Do not edit directly.
# ==============================================================================
set -euo pipefail
EOF_HEADER

# 1. Inlining lib modules in optimal topological order
LIBS=(
    "sidebar_domain.sh"
    "sidebar_domain_animation.sh"
    "sidebar_domain_activity.sh"
    "sidebar_port_tmux.sh"
    "sidebar_subpane_hub.sh"
    "sidebar_topology.sh"
    "sidebar_switch.sh"
    "sidebar_presenter.sh"
    "sidebar_ime.sh"
    "sidebar_coordinator.sh"
    "sidebar_archive.sh"
)

for lib_name in "${LIBS[@]}"; do
    lib="$REPO_ROOT/scripts/lib/$lib_name"
    [ -r "$lib" ] || continue
    echo "" >> "$OUTPUT_BIN"
    echo "# >>> MODULE: $lib_name >>>" >> "$OUTPUT_BIN"
    grep -v '^#!/usr/bin/env bash' "$lib" | grep -v '^set -euo pipefail' >> "$OUTPUT_BIN"
    echo "# <<< MODULE: $lib_name <<<" >> "$OUTPUT_BIN"
done

# 2. Main entrypoint code integration
echo "" >> "$OUTPUT_BIN"
echo "# >>> CORE ENTRYPOINT >>>" >> "$OUTPUT_BIN"
grep -v 'LAUNCHER_DIR/lib/sidebar_' "$REPO_ROOT/scripts/tmux-session-dock" \
    | grep -v '^#!/usr/bin/env bash' \
    | grep -v '^set -euo pipefail' >> "$OUTPUT_BIN" || true

chmod +x "$OUTPUT_BIN"
cp "$REPO_ROOT/scripts/tmux-sidebar-tmux-adapter" "$DIST_DIR/tmux-sidebar-tmux-adapter" 2>/dev/null || true
chmod +x "$DIST_DIR/tmux-sidebar-tmux-adapter" 2>/dev/null || true

echo "✅ Production bundle built successfully: $OUTPUT_BIN ($(wc -c < "$OUTPUT_BIN") bytes)"
