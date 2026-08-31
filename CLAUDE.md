# tmux-session-dock — orientation for an AI CLI session

Read this first, then only what your task needs. Everything below is true as of
`v0.3.64`; when it stops being true, fix it here in the same change.

## What this is

A tmux plugin, written entirely in bash, that puts a navigable **session dock**
(a 34-column sidebar) next to your work panes. From it you switch, create,
rename, archive and restore tmux sessions, and you can stack up to three
terminal subpanes beside it. Session switching uses native `switch-client` and
never moves panes between windows, which is what makes it flicker-free.

Target platform is tmux **3.2a and 3.4** (the CI matrix); it is developed on
WSL2, so the IME integration has a Windows path as well as Linux/macOS ones.

## Shape of the repo

```
scripts/tmux-session-dock      the entrypoint and most of the product (~9k lines)
scripts/lib/*.sh               12 extracted modules (~2.7k lines)
  sidebar_domain*.sh             pure functions, no tmux calls, unit-tested directly
  sidebar_port_tmux.sh           tmux-facing primitives + sidebar identity constants
  sidebar_subpane_hub.sh         subpane pool, slots, lease, slot mutation lock
  sidebar_switch.sh              the hot path of a session switch
scripts/tmux-{subpane,theme}-picker, tmux-help-viewer, tmux-command-palette
                               popup UIs (display-popup)
scripts/tmux-session-dock-ime  small fast-path helper for the IME focus hooks
dist/tmux-session-dock         generated single-file bundle, COMMITTED
session-dock.tmux              TPM entry: reads options, installs keybindings
tests/                         151 files; tests/ci.list is the CI set (138)
themes/                        59 theme .conf files (drop-in, no code change)
```

`make build` regenerates `dist/`; **commit it** — CI and `make check-dist` fail
on a stale bundle.

## How it works, in one paragraph

There is no coordinator daemon. Every managed window runs its own presenter
(a bash TUI in the sidebar pane). They agree through shared tmux server state:
**hidden global environment variables** (`set-environment -gh`) for transient
bookkeeping, because they cause no client redraw; **tmux options** only for
durable identity; and **`mkdir`+pid locks** where real mutual exclusion is
needed. The only extra processes per server are one AI Activity Observer and
the subpane hub keeper. `docs/ARCHITECTURE.md` lists the ten invariants this
rests on — read it before changing coordination, geometry, or hooks.

## Rules that are easy to violate

1. **Transient state carries an owner pid or a deadline.** Never decide
   liveness from how old a lock is: a switch may legitimately wait 5 s for
   provisioning. This caused real failures and is why `v0.3.49` exists.
2. **One round trip per question.** Use `sidebar_window_probe`,
   `sidebar_env_fetch_all`, `sidebar_env_set_many` instead of asking tmux four
   times. Batch writes: every `set-option` redraws every attached client.
3. **A cheaper poll must not become a more frequent poll.** Making the
   readiness probe cheap once tripled its rate and starved the presenter it
   was waiting for.
4. **A tmux command sequence (`a \; b`) aborts at the first failure.** tmux
   3.2a lacks `after-join-pane`, `after-break-pane`, `after-rotate-window`,
   `after-swap-pane`, `after-link-window` and `window-resized`, so hook
   installation issues one `set-hook` per call on purpose.
5. **A function has exactly one home.** Defining a name in both a lib and the
   entrypoint means tests run different code than production;
   `make test-health` fails on it.
6. **`set -euo pipefail` is everywhere**, and the presenter dies silently on an
   unbound variable — its stderr goes to the debug log, not your terminal.
7. **A question about one client goes to `list-clients`.** `display-message -c`
   cannot answer it: 3.2a rejects `-p -c` outright and 3.4 resolves the format
   against the most recently used session, so every client reports the same
   thing. Use `sidebar_client_field`.
8. **The renderer and the switch share a contract nothing declares.** A switch
   is only complete once the target presenter has drawn a frame the switch
   recognises, and it recognises it by reading the pane back as text
   (`sidebar_content_matches`). Draw anything new into the header or the mark
   columns, or change how a name is fitted, and every switch can abort as
   `sidebar-content-unready` — after the client has already moved. It has
   happened twice; `test-content-oracle-unit` is the guardrail.

## Working on it

```bash
make build && make lint && make check-dist
bash tests/run-tests.sh --only 'pattern'    # iterate
bash tests/run-tests.sh --ci                # full suite, ~10 min, RUN IT ALONE
make test-health                            # list hygiene + duplicate defs
```

The keyboard and gradient end-to-end tests are timing sensitive: running the
full suite on a loaded machine produces false reds. Each test builds its own
tmux server on a private socket and its own `$HOME`, so it never touches the
developer's live server.

To debug a presenter, set `TMUX_SESSION_LAUNCHER_TRACE=1` and
`TMUX_SESSION_LAUNCHER_TRACE_FILE=/path/trace.log`; the trace is the primary
diagnostic and tests assert against it.

Release convention: a `fix|feat|perf(...)` commit, then a `release: vX.Y.Z`
commit that bumps `VERSION=` in `setup.sh` **and** `scripts/tmux-help-viewer`
and rebuilds `dist/`, then an annotated tag, then push `main` and the tag.
Run the full suite before releasing.

## Where the history is

Design decisions live in the annotated tags and in the commit bodies, which are
written to explain *why*. To catch up quickly:

```bash
git log --oneline -20
git tag -n20 v0.3.62        # or any release
git log -1 --format=%B <commit>
```

The releases that shaped the current design:

| Tag | Why it exists |
| :--- | :--- |
| `v0.3.45` | Dock geometry is declared once per lease transaction as a layout string, instead of being computed by join/resize arithmetic that reversed slot order and lost a row. |
| `v0.3.47` | `setup.sh uninstall` used to `kill-server` and took a user's whole tmux down. Now non-destructive; `--kill-server` is opt-in. |
| `v0.3.48` | Enter on a session whose presenter pane had died burned the provisioning budget and then failed forever. Dead panes are now detected at once and recovered per `@session-dock-switch-recovery`. |
| `v0.3.49` | Transition and operation liveness by owner pid, not lock age; `ensure_target_sidebar_window` returns through result globals; duplicate lib/core definitions removed. |
| `v0.3.50` | Slot mutations serialized under one lock; hook-suppression flags carry owner and deadline; CI rejects a stale `dist/`. |
| `v0.3.51` | Hooks gated inside the tmux server; hot paths batched into single round trips; readiness polling backed off. |
| `v0.3.54` | Awaiting: a session whose AI stopped and that nobody has visited gets a `●` and a header count. The verdict is the shared observer's alone, so two windows cannot contradict each other. |
| `v0.3.56` | The awaiting header and mark broke every session switch: the switch confirms the target presenter by reading its dock back as text, and the renderer had started drawing something that text did not recognise. Mark After floored at the busy window so the number cannot lie. |
| `v0.3.57` | Eight per-client questions asked with `display-message -c`, which neither tmux answers that way; and a session whose name outgrows the row's name cell could not be switched to, for the same renderer/oracle coupling as `v0.3.56`. |
| `v0.3.58` | The settings popup stopped showing a tick on rows that hold a number, and Space can leave a millisecond budget again. |
| `v0.3.61` | The AI Activity Observer claims its lock by hard-linking a pid file, so there is no moment where the lock is held but looks orphaned. |
| `v0.3.64` | `fallback_session` ignores internal infrastructure sessions (`dotfiles-subpane-hub`) so deleting the current session switches cleanly to a surviving user session instead of collapsing the workspace. |

`docs/ARCHITECTURE-EVOLUTION.md` draws the nine points where the shape of
the codebase changed, before and after, with the release on each side.

`docs/BACKLOG.md` records the four-lens architecture review behind
`v0.3.49`–`v0.3.51`: what was fixed, the five principles those fixes converged
on, and the remaining items with evidence, proposed fix, size and risk. Read it
before starting anything large — the item you are about to do may already be
written up there. R10 (the Awaiting settings have no written policy) and R11 (a
toggle that lands during provisioning is dropped) are open and both need a
decision before they need code.

## Reference

- [README.md](README.md) / [README.ko.md](README.ko.md) — user-facing features, install, options.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — invariants and IPC design.
- [docs/ARCHITECTURE-EVOLUTION.md](docs/ARCHITECTURE-EVOLUTION.md) — how the shape changed, release by release.
- [docs/BACKLOG.md](docs/BACKLOG.md) — open items and review findings.
- [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) — every binding, and which option overrides it.
- [docs/THEMES.md](docs/THEMES.md) — theme catalog and how to add one.
- [CONTEXT.md](CONTEXT.md) — domain vocabulary; use these words in code and commits.
- [CONTRIBUTING.md](CONTRIBUTING.md) — workflow, how to write a test, how to add an option.
