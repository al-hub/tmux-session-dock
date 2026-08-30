# Architecture Review Backlog

Four read-only reviews (structure / runtime cost / stability / extensibility) were
run against `v0.3.48` on 2026-08-30. This file records what was fixed, what was
deliberately left, and the evidence for each remaining item so the next change
does not have to rediscover it.

Line references are against the tag named in each entry. Runtime numbers were
measured on tmux 3.2a (WSL2) by putting a counting shim in front of the `tmux`
binary; the method is reproducible with any wrapper that logs `exec`s.

## Principles agreed during the review

1. **State is one of two kinds.** Identity lives in a plain tmux option and needs
   no expiry. Anything transient - a lock, a lease, a guard, an operation - must
   carry an owner pid, a deadline, or both. Age heuristics (`mtime`) and bare
   `1`/`0` flags are not allowed: they cannot tell a slow-but-alive writer from a
   dead one.
2. **One round trip per question.** A hot path asks the server once for
   everything it needs (`sidebar_window_probe`, `sidebar_env_fetch_all`,
   `sidebar_env_set_many`) and writes several options in one command sequence so
   the server redraws once.
3. **Decide in the server when the server can decide.** A hook that would exit
   immediately should never start a process; gate it with `if-shell -F`.
4. **A function has exactly one home.** A name defined in both a lib module and
   the core entrypoint means tests and production run different code;
   `run-tests.sh --health` fails on any duplicate.
5. **A cheaper poll must not become a more frequent poll.** Polling cost that
   moves onto the tmux server starves the presenter the caller is waiting for.

## Done

| Release | Change | Evidence it worked |
|---|---|---|
| `v0.3.49` | Transition lock: no age-based stale-clear (was 3 s `mtime`, which tore down switches legitimately waiting up to 5 s for provisioning); release only by the owning pid. Operation state carries `pid:deadline` and heals when the owner dies. `ensure_target_sidebar_window` returns through result globals instead of a `$(...)` subshell that swallowed the failure reason and defeated the readiness cache. Three duplicate lib/core definitions removed. | `test-transition-lock-liveness-contract`, `test-operation-state-liveness-contract` (both red on `v0.3.48`) |
| `v0.3.50` | Every subpane slot mutation runs under one reentrant mkdir+pid lock; the three hook-suppression flags carry `owner_pid:deadline`; CI and `make check-dist` fail on a stale `dist/`. | `test-subpane-migrate-lock-contract`, `test-guard-flag-liveness-contract` |
| `v0.3.51` | Layout and focus hooks gated on `@dotfiles_sidebar_ready` inside the server; batching primitives for the hot paths; readiness waits poll cheap flags first and back off. | `test-hot-path-round-trips-contract`; sidebar-less window 21 → 0 spawns, focus hook 178 → 94 ms, idle 13.0 → 7.7 execs/s, warm switch ~350 → ~235 ms |

After these, no transient coordination state on the server is left without an
owner or a deadline.

## Remaining

Ranked by (probability × user impact) for the correctness items, then by
(contributor time saved × frequency) for the rest. None of them is a known
cause of a user-visible failure today except **R1**.

### R1 — TUI help popup is unreachable on a TPM-only install · S · low risk

`run_tui`'s help action runs `$HOME/.local/bin/tmux-help-viewer` and nothing
else (`scripts/tmux-session-dock:8963`), but that symlink is created only by
`setup.sh`. Installed through TPM, `LAUNCHER_DIR` is `dist/`, which does not
contain the popup scripts, so `h` silently does nothing. The subpane picker one
line earlier already has the fallback (`:8953`).

Fix: give the help popup the same `LAUNCHER_DIR/../scripts/` fallback, or copy
both popup scripts into `dist/` from `scripts/build-dist.sh`.

### R2 — `S` in the TUI is documented but unreachable · S · low risk

`read_key` maps both `s` and `S` to `toggle-subpane`
(`scripts/tmux-session-dock:8512`), so the `S|config-subpane` arm at `:8951`
can never be reached from the keyboard. `docs/KEYBINDINGS.md:30` and
`scripts/tmux-help-viewer:53` both document `S` as the stack configurator.

Decide which is true, then make the other match. The same pass should clear the
rest of the keymap drift the review found: keys documented in
`scripts/tmux-help-viewer` that are bound nowhere in the repo (`Escape`, `p`,
`v`, `n`, `Ctrl+\`, `Prefix + ?`), `M-arrow`/`C-M-arrow` bound in
`session-dock.tmux` but absent from `docs/KEYBINDINGS.md`, and the
`tmux-command-palette` alias that names a command (`tmux-session-launcher
--open-sidebar`) the code no longer issues.

Structural fix (larger): turn `read_key`'s `case` into a table and generate the
TUI section of `docs/KEYBINDINGS.md` and the help viewer from it, with a test
that diffs generated against committed. Global keys can be generated the same
way from `tmux list-keys -N`, which the palette already parses at runtime.

### R3 — Provisioning lock falls through instead of giving up · S · low risk

`provision_sidebar_window` waits 60 × 0.05 s for another creator
(`scripts/tmux-session-dock:2215`), then takes the lock anyway
(`:2226`, `mkdir ... || true`) and splits. Two sidebar panes can result; the
reconciler kills one, and the pane it kills may be the one whose presenter has
already published its pane id. The transition lock has the right shape here:
a live owner means give up (return), a dead one means reclaim.

### R4 — Slot limit 3 is code, not policy · S · low risk

`subpane_hub_get_count` / `subpane_hub_set_count` hard-code `2|3`
(`scripts/lib/sidebar_subpane_hub.sh:130,138`), the reconcile loop iterates
`for slot in 1 2 3` (`:745`), and the picker has one literal row per count
(`scripts/tmux-subpane-picker:87-88`). Everything else - `resolve_pool`, the
layout builder, `@dotfiles_subpane_slot_N_height`, the topology oracle - is
already N-agnostic since `v0.3.45`.

Fix: one `SUBPANE_MAX_SLOTS` constant, a range check instead of a case list, and
picker rows generated from it. Raising the limit then only needs a height-budget
review.

### R5 — No option registry · M · low risk

Adding one `@session-dock-*` option touches 7-9 files, and defaults are written
in four different places (`session-dock.tmux`'s getter, the picker's own
getters, `sidebar_subpane_hub.sh`, and literals at each read site). There are 13
such options today.

Fix: one table (name, default, allowed values, description) in a new
`scripts/lib/sidebar_options.sh`, with the picker rows, the README option block
and a `--list-options` output generated from it, and a test that fails when the
committed README block differs from the generated one.

### R6 — Test harness duplication and serial runtime · L · medium risk

131 test files, 68 of which use none of the shared helpers: `cleanup()` is
defined 82 times, `tmuxc()` 37 times, and 15 files define their own `wait_*`
(30 variants). The suite is serial and takes ~9.5 min; 19 tests (15%) account
for 56% of that.

Parallelism is blocked by exactly two things, both fixable: the leak sweep in
`tests/run-tests.sh` kills every socket that appeared during a run (it would
kill a neighbour's server), and the default trace path is a shared
`/tmp` file when a test enables `TRACE=1` without naming one.

Also worth doing here: 8 of the 18 `test-keyboard-e2e.sh` scenarios have no CI
wrapper, so they never run; `--health` should fail on an unwrapped scenario.

### R7 — Monolith split · L · medium risk

`scripts/tmux-session-dock` is ~9,000 lines and ~290 functions; the libs are
~2,500. The largest functions are `collect_sessions` (~670), `run_tui` (~530),
`restore_archive` (~370) and `switch_session` (~350). 14 lib functions call back
into names defined only in the core, guarded by `declare -f` checks that hide
load-order bugs.

Fix incrementally, one concern per change, keeping the single-file `dist`:
`sidebar_trace.sh` first (it removes ~40 `declare -f` guards), then metrics,
observer, archive, transaction, provisioning, TUI. Only `main()` and the config
block stay in the entrypoint.

## Not planned

- Raising the subpane slot limit above 3 (R4 makes it possible, it is not itself
  a goal).
- Rewriting the presenter's render loop. It is already fork-free per animation
  frame and waits on `read -t`.
- The `'env ... --observe ...' terminated by signal 15` status message. This is
  `run-shell -b` reporting a SIGTERMed child's exit status; the observer does
  trap `EXIT INT TERM HUP`, so a trap is not the fix. Spawning the observer
  detached (`setsid`) so tmux never tracks it is the remaining candidate. On
  hold at the user's request pending more observation.
