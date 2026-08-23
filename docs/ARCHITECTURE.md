# tmux-session-dock Architecture & IPC Design

## 1. System Overview

`tmux-session-dock` replaces legacy, fragile physical pane migration models (`move-pane`) with the **Window-Local Thin Presenter + Singleton Coordinator Hub** architecture.

```mermaid
graph TD
    subgraph "tmux Server"
        COORDINATOR["Singleton Coordinator Hub"]
        SUBPANE_HUB["Singleton Subpane Hub Session"]
        EPOCH["Global Topology Epoch Tracker"]
    end

    subgraph "Managed Window 1"
        PRESENTER_1["Window-Local Presenter 1"]
        WORK_1["Work Panes (Multi-split)"]
    end

    subgraph "Managed Window 2"
        PRESENTER_2["Window-Local Presenter 2"]
        WORK_2["Work Panes (Multi-split)"]
    end

    COORDINATOR --> PRESENTER_1
    COORDINATOR --> PRESENTER_2
    SUBPANE_HUB -.-> PRESENTER_1
    EPOCH --> COORDINATOR
```

## 2. Core Invariants

1. **Window-Local Presenters**: Every managed window maintains its own lightweight Presenter pane.
2. **Native `switch-client`**: Session switching executes pure native client switching without moving physical panes across windows.
3. **0.75ms Fast-Path & In-Flight Handover**: In-place switching returns within 0.75ms with zero screen flicker.
4. **Clean Shared History**: Session archive and restoration (`o`) preserves shell history with Zero Time-Travel Pollution.
5. **24-Frame LUT Waveform Engine**: Real-time asynchronous background AI activity telemetry rendered at 30 FPS.
