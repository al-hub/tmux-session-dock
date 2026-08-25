# Session Dock

Session Dock keeps a navigable presenter beside tmux work panes while preserving terminal continuity across managed windows.

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
The session-scoped observer that reports whether a tracked AI CLI is running, idle, or gone independently of Presenter Window selection.
_Avoid_: Fingerprint tracker, gradient detector

**AI Activity State**:
The asynchronous running, idle, or gone status of a session's tracked AI CLI, consumed by the presenter to represent work in progress.
_Avoid_: Animation state, waiting state

**AI Activity Intensity**:
A future measure of how continuously a running AI CLI changes, distinct from its running, idle, or gone state.
_Avoid_: Busy state, gradient state
