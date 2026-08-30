# Contributing to tmux-session-dock

## Where the code is

| Path | What lives there |
| :--- | :--- |
| `scripts/tmux-session-dock` | The entrypoint and most of the product: the presenter TUI, session switching, archive/restore, hooks, the CLI `case`. |
| `scripts/lib/*.sh` | Extracted modules. `sidebar_domain*.sh` are pure (no tmux calls, unit-testable); `sidebar_port_tmux.sh` and `sidebar_subpane_hub.sh` own the tmux-facing primitives. |
| `scripts/tmux-{subpane-picker,theme-picker,help-viewer,command-palette}` | Popup UIs, run by `display-popup`. |
| `scripts/tmux-session-dock-ime` | Small fast-path helper spawned by the IME focus hooks. |
| `dist/tmux-session-dock` | Generated single-file bundle (libs inlined, then the entrypoint). Committed. |
| `session-dock.tmux` | TPM entry: reads `@session-dock-*` options and installs keybindings. |

Moving a function out of the entrypoint into a lib is welcome, but a name must
exist in exactly one of them - `make test-health` fails on a duplicate, because
lib-only test harnesses would otherwise exercise a different body than
production does.

## Workflow

1. Fork and clone.
2. Edit `scripts/` (see the table above for which file).
3. Rebuild and verify the bundle:
   ```bash
   make build        # regenerates dist/
   make check-dist   # fails if the committed dist/ is stale
   make lint
   ```
   **Commit `dist/` with your change**; CI fails when it does not match a fresh
   build.
4. Run the suites:
   ```bash
   make test         # tests/ci.list - every entry must pass (~10 min, run it alone)
   make test-health  # list hygiene + duplicate-definition check
   ```
   The keyboard and gradient end-to-end tests are timing sensitive; running
   them while the machine is loaded produces false reds.
5. Open a PR against `main`.

## Writing a test

Every `tests/**/test-*.sh` must appear in exactly one of `tests/ci.list` or
`tests/manual.list`. A test asserts one user-visible fact - pane geometry,
captured pane text, session state, or a documented `@session-dock-*` option.
It does not read internal `@dotfiles_*` runtime options. A wait loop that times
out is a failure, never a pass.

Coordination behaviour (locks, leases, liveness) is the exception: those tests
may read the internal state directly, because the fact under test *is* the
state. `test-transition-lock-liveness-contract.sh` is the model to copy.

Each test creates its own tmux server on a private socket (`-L name-$$`) and
its own `$HOME`; never assume the developer's server exists.

## Adding a `@session-dock-*` option

There is no registry yet (see BACKLOG R5), so all of these need touching:
the read site in `scripts/`, the default in `session-dock.tmux`, a row in
`scripts/tmux-subpane-picker` if it belongs in the settings popup, the option
block in `README.md` **and** `README.ko.md`, and a test that asserts the
behaviour for each accepted value.

## Further reading

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - invariants the code must keep.
- [docs/BACKLOG.md](docs/BACKLOG.md) - known gaps, with evidence and sizing.
- [CONTEXT.md](CONTEXT.md) - the domain vocabulary; use these words in code and commits.
