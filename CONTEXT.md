# Session Dock

Session Dock keeps a navigable presenter beside tmux work panes while preserving terminal continuity across managed windows.

These are the words the code, the tests, the commit messages and the docs use.
Prefer them over the alternatives listed under each entry.

## Language

**Presenter Window**:
A managed tmux window that contains a Session Dock presenter and may hold the active Subpane Lease.
_Avoid_: Target window, sidebar session

**Subpane Pool**:
The server-wide set of terminal panes available for presentation beside a Session Dock presenter.
_Avoid_: Subpane Hub Manager, pane mirror

**Subpane Slot**:
A stable position in the Subpane Pool whose terminal identity survives movement between Presenter Windows.
_Avoid_: Subpane copy, duplicate pane

**Subpane Lease**:
The exclusive right of one Presenter Window to display the Subpane Pool.
_Avoid_: Subpane ownership, target assignment

**Hub Keeper**:
The non-terminal member that keeps the Subpane Pool available while every Subpane Slot is leased to a Presenter Window.
_Avoid_: Slot zero, placeholder subpane

**User Height Intent**:
The most recently accepted vertical size of each Subpane Slot, retained across lease movement.
_Avoid_: Cached pane height, default height

**AI Activity Observer**:
The single per-server process (`--observe`) that samples every session's tracked AI CLI once per second and publishes each session's AI Activity State for all presenters, independently of Presenter Window selection. Presenters consume the published state and fall back to observing locally only while no observer is alive.
_Avoid_: Fingerprint tracker, gradient detector, per-presenter observer

**AI Activity State**:
The status of a session's tracked AI CLI, consumed by the presenter to decide what the row shows. Exactly four: **Working**, **Awaiting**, **Idle**, **Absent**.
_Avoid_: Animation state, waiting state

**Working**:
A session whose tracked AI CLI is changing its visible output. The only state the gradient animates.
_Avoid_: Busy, active

**Awaiting**:
A session whose tracked AI CLI stopped changing its output long enough to be worth reporting, and that no client has visited since. It says the user is the one who moves this session forward - never that the work finished, which cannot be observed: a session blocked on an approval prompt is Awaiting too. Announced once; visiting the session or the AI moving again ends it, and no clock does.
_Avoid_: Done, Finished, Complete, Waiting

**Idle**:
A session whose AI stopped and that has either been visited since, or has not been quiet long enough to report. Both render as nothing, so the two readings never need distinguishing on screen.
_Avoid_: Quiet, stopped

**Absent**:
A session with no tracked AI CLI - one that never ran one, or whose AI exited. The wire value is `gone`.
_Avoid_: Gone, dead, missing

**Mark Column**:
The second of the two columns to the left of a session name. It carries `*` for the session a client is on and `●` for an Awaiting session. **These can never both apply**, because being on a session is exactly what ends Awaiting; the single column depends on that. Narrowing acknowledgement to pane focus would break it and force the mark elsewhere.
_Avoid_: Badge, indicator column

**AI Activity Intensity**:
A future measure of how continuously a running AI CLI changes, distinct from its running, idle, or gone state. Not implemented.
_Avoid_: Busy state, gradient state

**Transition**:
One session switch, from the moment a target is chosen until the client is on it and its presenter has rendered a frame for it. Owned by exactly one process, which holds the Transition Lock for its duration.
_Avoid_: Switch operation, transaction

**Transition Lock**:
The server-wide `mkdir`+pid lock that admits one Transition at a time. Liveness is decided by the owner process, never by how long the lock has existed.
_Avoid_: Switch lease, transition timeout

**Slot Mutation Lock**:
The server-wide `mkdir`+pid lock held while Subpane Slots are joined or parked, so two processes never interleave moves of the same slot. Distinct from the transaction marker, which only asks observers to skip snapshots.
_Avoid_: Subpane lock, hub lock

**Guard Flag**:
A tmux option that suppresses hooks while a toggle or restore is in flight. Carries the owner pid and a deadline, so a writer that dies cannot suppress the server forever.
_Avoid_: Busy flag, batch flag

**Hook Gate**:
The `if-shell -F` condition wrapped around a layout or focus hook so the tmux server itself decides whether the hook is worth a process.
_Avoid_: Hook filter, early return

**Switch Recovery**:
What happens when a Transition cannot reach its target because that window's presenter pane is dead or never became ready: a diagnosis is shown and the user chooses (`popup`), the presenter is respawned silently (`auto`), or the switch aborts (`off`).
_Avoid_: Retry, failover
