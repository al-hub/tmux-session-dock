# Architecture Review Backlog

Four read-only reviews (structure / runtime cost / stability / extensibility) were
run against `v0.3.48` on 2026-08-30. This file records what was fixed, what was
deliberately left, and the evidence for each remaining item so the next change
does not have to rediscover it.

Line references drift; treat them as a starting point and confirm with `grep`. Runtime numbers were
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
(contributor time saved × frequency) for the rest. Two have already caused
user-visible failures: **R8**, which broke session switching outright and is
the one to take first, and **R1**. **R10** is the highest-priority item that is
not a defect: it is a policy that was never written down, and four separate
findings fall out of the gap. The numbers are identities, not an order - new
findings are appended.

### R1 — TUI help popup is unreachable on a TPM-only install · S · low risk

`run_tui`'s help action runs `$HOME/.local/bin/tmux-help-viewer` and nothing
else (`scripts/tmux-session-dock:8963`), but that symlink is created only by
`setup.sh`. Installed through TPM, `LAUNCHER_DIR` is `dist/`, which does not
contain the popup scripts, so `h` silently does nothing. The subpane picker one
line earlier already has the fallback (`:8953`).

Fix: give the help popup the same `LAUNCHER_DIR/../scripts/` fallback, or copy
both popup scripts into `dist/` from `scripts/build-dist.sh`.

### R2 — the keymap has four hand-maintained copies · S (drift) / M (structural) · low risk

`read_key` maps both `s` and `S` to `toggle-subpane`, so the `S|config-subpane`
arm in `run_tui` can never be reached from the keyboard. The docs were
corrected to match the code (the stack configurator is `Prefix + S`) and the
`case` now carries a comment pointing here, so this is no longer a drift - it
is an open product question: should `S` inside the TUI open the configurator,
as three documents used to claim? If yes, that is a one-line change plus a
test; if no, the dead arm should be deleted.

Fixed in the same documentation pass: `docs/KEYBINDINGS.md` now lists
`M-arrow`, `C-M-arrow` and the preset-only `Tab`/`BTab`, records which option
overrides each binding, and states that `Prefix + ?` is tmux's own key list
rather than this plugin's help popup; `scripts/tmux-help-viewer` no longer
advertises `Ctrl+a Escape`, `Ctrl+a p`, `Ctrl+a v`, `Ctrl+a n` or `Ctrl + \`,
none of which this repo binds.

What survives is the cause, not the symptom: the keymap has no single source.
`read_key`'s `case`, `session-dock.tmux`'s `bind-key` calls,
`docs/KEYBINDINGS.md` and `scripts/tmux-help-viewer` are four hand-maintained
copies, and `scripts/tmux-command-palette`'s alias map still names a command
(`tmux-session-launcher --open-sidebar`) the code no longer issues.

Fix: make `read_key` a table, generate the TUI section and the help viewer
from it, generate the global table from `tmux list-keys -N` (which the palette
already parses at runtime), and add a test that diffs generated against
committed.

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

Two concrete symptoms to fix while in here: 8 of the 18 `test-keyboard-e2e.sh`
scenarios have no CI wrapper, so they never run (`--health` should fail on an
unwrapped scenario), and `test-session-name-zero.sh` fails in roughly half of
full-suite runs while passing every time on its own - a wait budget that is
adequate on an idle machine and not on a loaded one.

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

### R8 — the switch judges readiness by reading the screen back · M · medium risk

A session switch is only complete once the target presenter has drawn a frame
for the target session. `wait_for_sidebar_content_ready` decides that from
three things: the window's readiness option, the presenter's own
`HANDOVER_RENDERED_<window>` declaration, and - the problem - a scrape of the
pane text matched against what the renderer is expected to have drawn
(`sidebar_content_matches`, plus a second copy of the same idea as
`grep -Eq '^[[:space:]]*sessions'` in the batch-restore barrier).

Named in the usual vocabulary, the closest fit is DIP: a high-level policy
("has the transition completed?") depends on a low-level detail (the exact
bytes the renderer emits) although both sides already share an abstraction that
means precisely that. OCP is next: each renderer *addition* forced a
*modification* of the switch. SRP is true but loosest - the module has two
reasons to change, though not in the usual "does two jobs" shape.

The more actionable statement is not a SOLID letter. There are **two sources of
truth for "the target has rendered"**, and the redundant one is obtained by
parsing a presentation format. In this repo's own vocabulary the seam sits one
layer too low: the switch wants *render completion* and is given *rendered
text*.

That makes the header text and the mark column an implicit contract between the
renderer and the switch, and it has been broken twice by drawing more into
them:

- `v0.3.54` added a count of waiting sessions to the header. The pattern
  required a line that was exactly `sessions`, so **every** switch aborted as
  `sidebar-content-unready` whenever any session was Awaiting - after the
  client had already moved, which is what made it look like Enter did nothing.
- The same release put `●` in the mark column. The row pattern allowed only
  `>`, `*` and spaces, so a switch onto an Awaiting session could not settle
  either.

Both are fixed and `test-content-oracle-unit` now pins the contract - every
mark `row_mark_value` can emit, against every header `render_header` can emit -
so a third render change breaks a test instead of session switching. That is a
guardrail, not a separation: the coupling is still there, and widening the
renderer still means remembering to widen the oracle.

The separation is half-built already. `mark_handover_rendered` is called only
after `render_transition_delta` or `render_full` has actually drawn
(`scripts/tmux-session-dock` around the `flush_full_render_request` body), so
the declaration means what the scrape is trying to infer. If it can be trusted,
the scrape is redundant and can go, taking the implicit contract - and
`test-content-oracle-unit` - with it.

**Do not simply delete the scrape.** It is the only check of what the user can
actually see: the declaration says the presenter *called* a render function,
the scrape says the pane *contains* the frame. tmux updates panes
asynchronously and a later redraw can overwrite one, so the two are not
equivalent. The fix is to promote the declaration until it means "on screen",
not to drop the check that currently means it. Remove SOLID's complaint without
that and the flicker the barrier exists to prevent comes straight back.

Before removing it, two things need checking, and they are the reason this is
not a one-line change:

1. **Does every path that draws a settled frame declare it?** After
   `render_full "$reason"` the declaration is made only for
   `marker-handover-reconcile` and `enter-session-switch-fallback`. A frame
   drawn for any other reason leaves no declaration, and the scrape may be
   quietly covering that gap.
2. **Is the declaration never ahead of the screen?** It is written after the
   `printf`, but tmux updates the pane asynchronously; a switch that trusts the
   flag alone must not finish before the user can see the frame, which is the
   flicker the barrier exists to prevent.

Fix, in order: instrument which render reasons reach a settled target frame
without declaring; close that gap in the renderer; then delete the scrape from
`wait_for_sidebar_content_ready` and the batch-restore barrier, and delete the
oracle contract test with them.

**Severity**: the impact is severe and the likelihood is now low - which is what
the M rating multiplies, not smallness. When it fires, the product's primary
action stops working entirely, and it fails quietly: the client has already
moved and the error line is overwritten by the next redraw a second later,
which is why the first report of it was "Enter does nothing" with no clue
attached. What is low is the chance of firing again: the header pattern now
accepts anything beginning with `sessions`, the mark pattern is built from the
glyph constant, the mark's two-column width is asserted, and `render_header` is
the only writer of row 1.

**Limit of the guardrail**, worth closing cheaply whenever this area is next
touched: `test-content-oracle-unit` *assembles* the frames it checks - it takes
the mark from `row_mark_value` but supplies literal headers and its own row
layout, so it never captures a real render. A change to `format_row`'s columns,
or a header shaped unlike the three literals, would pass it. Feeding it a pane
captured from a live presenter would bring the whole render path inside the
contract.

### R9 — two AI Activity Observers can run at once for a moment · S · low risk

The observer is meant to be one per server; `run_ai_observer` enforces it with a
`mkdir` lock plus a pid file, and `ensure_ai_observer` throttles each presenter
to one spawn every five seconds. Under load that is not quite enough, and it has
been seen twice:

- Restarting four presenters at once on a live server left two observers
  running. They converged on their own after about six seconds.
- `test-shared-observer-e2e` failed once in a loaded full run with "expected
  exactly one observer for this server, found 2", and passed twice when run
  alone.

The window is between taking the lock and writing the pid into it: the holder
does `mkdir` and only then `printf ... > "$lock_dir/pid"`, while a loser polls
`ai_observer_pid` (which needs that file) ten times at 0.2 s and, if it never
appears, deletes the lock directory and takes it. A holder that is slow to get
scheduled therefore looks orphaned. The throttle does not help: it is a
process-local variable, so four presenters starting together each get their own
five-second budget and all four spawn.

The consequence today is mild - the state file has a single writer, the extra
observer exits as soon as it can see the holder's pid, and nothing observed a
wrong verdict - so this is a correctness tidy, not a live defect.

Fix candidates, cheapest first: write the pid *before* releasing the mkdir (not
possible directly, so instead treat "lock exists but no pid file yet" as held
for a grace period rather than as orphaned); or have the loser verify with a
second, longer poll before reclaiming; or move the spawn throttle into a
server-wide flag so simultaneous presenters do not each spawn.

Related, and the reason this was written down together with it: the observer is
started with `run-shell -b`, so tmux tracks the `sh -c` wrapper and reports its
death. Killing that wrapper (as any `pkill -f` matching the command line will,
including one typed by an operator) produces the status message
`'env ... --observe ...' terminated by signal 15`. The bash underneath traps
`EXIT INT TERM HUP` and exits quietly; the wrapper has no trap. Spawning the
observer detached (`setsid`) would remove that message *and* change how tmux
tracks the observer's lifetime, which is why it belongs with this item rather
than on its own. The message itself was judged operator error, not a defect:
select the bash and leave the wrapper alone.

### R10 — the Awaiting settings have no written policy · policy first, then S · low risk

Reported as "Mark After does not stop at the time I set". It is not a defect in
Mark After. Measured on the live server on 2026-08-30, with
`@session-dock-awaiting-after 10000`, by recording every transition the shared
observer published:

```
22:47:48 dotfiles              running   silent=0s
22:48:13 dotfiles              awaiting  silent=10s
22:47:57 waiting-seesion-test  running   silent=0s
22:48:18 waiting-seesion-test  awaiting  silent=10s
```

Both sessions were marked exactly ten seconds after their last output. An
isolated server agrees: 20000 marks at 20 s, 10000 at 11 s. What did not stop
was the *blink*, which `@session-dock-awaiting-blink` governs and which was
unset, i.e. `always`. The two options are read as one thing by the user, and
nothing in the product corrects that reading. Four findings sit on that gap;
none is fixed, because each needs a decision before it needs code.

**(a) The popup's `[✓]` column means three different things.** One renderer
(`scripts/tmux-subpane-picker:303`) serves toggle rows (Space flips them),
value rows (`Mark After (ms)`, `Wave Cycle (ms)` - Space and Enter both open a
number prompt, there is nothing to flip) and multi-state rows (`Blink Until
Seen`, `On Failure`). On a value row the check reports the *parent's* state:
`AAFTER` is ticked whenever `Awaiting Marker` is on (`:275`). So the row reads
as a switch that cannot be switched off. The footer legend - `토글 & 적용:
[ Space / Enter ]` - names both actions in one breath and completes the
misreading. Candidate: value rows show the value (`[10s]`, `[1.2s]`) instead of
a tick, and keep `[ ]` + dim when the parent is off.

**(b) The blink default is `always`, so out of the box the mark never settles.**
`sidebar_awaiting_apply` maps an unset option to `blink_ms=-1`
(`scripts/tmux-session-dock:5591`), and `row_mark_value` then skips the budget
check entirely. This is documented (README:66) and the popup says it
("확인할 때까지 계속 깜빡임"), but no test pins the default, and it is the state
every new user starts in. Candidate: keep `always`, or default to a budget -
the state itself never times out either way, so a budget loses no information.

**(c) Mark After cannot be turned off, and the observer ignores the off
switch.** `sidebar_domain_activity_await_after` clamps everything back into
10000-300000; `off`, `0`, `-1` and an empty value all return a live threshold:

```
[]  -> 30000    [0]  -> 10000    [off] -> 30000    [-1] -> 30000
[1] -> 10000    [9999] -> 10000  [999999] -> 300000
```

`await_after=0`, the value that does disable awaiting, is reachable only from
one call site (`scripts/tmux-session-dock:4767`), where a presenter observing
without a shared observer must not publish a verdict its neighbours would
contradict. The only user-facing switch is `@session-dock-awaiting off`, and
that stops the *drawing* only: the observer loop reads the threshold option but
never the on/off one (`:5988`), so it keeps publishing `awaiting` into the state
file while the mark is hidden. Turning the marker back on shows the backlog
immediately rather than restarting the clock, which may well be what we want -
it has simply never been decided.

**(d) The busy window is environment-only, and the popup does not know it.**
`SIDEBAR_BUSY_SECONDS` comes from `TMUX_SESSION_SIDEBAR_BUSY_SECONDS` and is
read once at startup (`:79`); unlike every `@session-dock-*` option it is not
re-read each second, so it needs a dock restart. It also sets Mark After's floor
(`:94`, `SIDEBAR_BUSY_SECONDS * 1000`, itself floored at 1000). The libs are
sourced before that line, so the derived value beats the lib's hardcoded
`SIDEBAR_AWAITING_AFTER_MS_MIN=10000` in the dock and in `dist/`. The picker,
though, sources only the lib (`scripts/tmux-subpane-picker:47`), so its floor is
always 10000: lower the busy window and the dock accepts 5000 while the popup
clamps typed values to 10000 (`:411`), advertises `10000~300000` (`:283`), and
re-displays a stored 5000 as 10000. The popup and the dock then disagree about
what a number means - the very thing `prompt_ms_value`'s comment says must not
happen.

Decide before writing code:

1. Does the blink keep `always` as its default, or get a budget?
2. Is Mark After allowed an off of its own, or is `Awaiting Marker` the single
   switch for the whole feature?
3. While the marker is off, should the observer stop computing `awaiting` - or
   keep the verdict warm so turning it back on is instant?
4. Does the busy window become a `@session-dock-*` option? If so the floor stops
   being a source-time constant and the clamp has to move to call time.
5. What does the popup's mark column mean - one meaning for every row, or one
   per row kind, spelled out in the legend?

Only (a) and (d) are safe to do without answering the rest; (d) is a real
inconsistency today, (a) is the change that stops the report from recurring.

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
