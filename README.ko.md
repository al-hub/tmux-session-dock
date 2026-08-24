# tmux-session-dock ⚡ (한국어 설명서)

> **tmux를 위한 초고속 무깜빡임(Zero-Flicker) 워크스페이스 세션 도크 및 오케스트레이터**  
> *Window-Local 씬 프레젠터 • 24프레임 실시간 AI 파형 모니터링 • 38종 프리미엄 테마 • 완전 자립형 생명주기*

---

## ✨ 핵심 기능

- ⚡ **0.75ms 제자리 Fast-Path & 무깜빡임 전환**: 물리 페인을 이동하지 않고 각 윈도우에 사전 배치된 Presenter로 Native `switch-client`를 수행하여 5초 프리징 및 화면 깜빡임을 완전 박멸했습니다.
- 🌊 **24프레임 LUT 파형 엔진**: 백그라운드 AI 에이전트의 활동을 실시간으로 감지하여 30 FPS 주사율로 시각화합니다.
- 🗂️ **싱글톤 서브페인 허브 (`s` / `p`)**: TUI 내부에서 열기/닫기(`s`) 및 상단/하단 위치 즉시 스왑(`p`)과 높이 영속화를 지원하는 전용 터미널 서브페인을 제공합니다.
- 📦 **Zero Time-Travel 오염 방지 아카이브**: 셸 히스토리(`$HISTFILE`)를 오염시키지 않고 세션을 안전하게 스냅샷 보관 및 일괄 복원(`o`)합니다.
- 🎨 **38종 프리미엄 테마 & 실시간 리치 프리뷰 (`Prefix + T` / `ㅆ`)**: 3단계 표준 계층 구조(`open-tokyonight`, `code-windows-terminal`, `eye-astigmatism-safe` 등)와 실시간 컬러 칩 인스펙터를 제공합니다.
- 🔄 **통합 생명주기 제어기 (`./setup.sh`)**: `install`, `update`, `uninstall`, `status`, `build`, `test`, `purge`를 단일 CLI로 총괄 관리합니다.

---

## 🚀 빠른 시작

### 1. TPM (Tmux Plugin Manager) 설치 (권장)

`~/.tmux.conf`에 아래 내용을 추가하고 `Prefix + I`를 누릅니다:
```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'al-hub/tmux-session-dock'

# 선택적 커스텀 옵션
set -g @session-dock-key 's'              # 사이드바 토글 키 (기본: Prefix + s / ㄴ)
set -g @session-dock-width '34'           # 사이드바 너비
set -g @session-dock-theme 'open-tokyonight' # 기본 테마
set -g @session-dock-dotfiles-mode 'on'   # [옵션] Ctrl+a, 상단 경로 보더, Alt+화살표 인체공학 프리셋 활성화

run '~/.tmux/plugins/tpm/tpm'
```

### 2. 원라인 cURL 자동 설치

```bash
# 기본 풀 인체공학 모드 설치 (권장)
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- install

# 업데이트
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- update

# 완전 삭제 (Purge)
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- purge
```

### 3. 로컬 Git Clone 및 `setup.sh` 관리

```bash
git clone https://github.com/al-hub/tmux-session-dock.git ~/.local/share/tmux-session-dock
cd ~/.local/share/tmux-session-dock

# 설치 및 tmux 설정 주입
./setup.sh install

# 상태 및 무결성 진단
./setup.sh status

# 자체 격리 테스트 스위트 검증
./setup.sh test
```

---

## ⌨️ 주요 단축키 가이드 (한/영 2벌식 완벽 지원)

| 영문 단축키 | 한글 단축키 (2벌식) | 기능 설명 |
| :--- | :--- | :--- |
| **`Prefix + s`** | **`Prefix + ㄴ`** | 세션 도크 사이드바 열기 / 닫기 (토글) |
| **`Prefix + T`** | **`Prefix + ㅆ`** / **`ㅅ`** | 🎨 38종 프리미엄 테마 피커 팝업 열기 (실시간 프리뷰) |
| **`Prefix + /`** | **`Prefix + /`** | ⌨️ 전체 단축키 검색 (커맨드 팔레트) |
| **`Prefix + h`** / **`?`** | **`Prefix + ㅗ`** / **`?`** | 📖 인터랙티브 도움말 가이드 팝업 열기 |
| **`Prefix + \|`** / **`%`** | **`Prefix + \|`** / **`%`** | 작업 영역 가로 분할 (사이드바 보호) |
| **`Prefix + _`** / **`"`** | **`Prefix + _`** / **`"`** | 작업 영역 세로 분할 (사이드바 보호) |
| **`Alt + s`** (`M-s`) | **`Alt + ㄴ`** (`M-ㄴ`) | ⚡ 세션 도크 0ms 즉시 포커스 점프 / 복귀 |

---

## 📄 라이선스

MIT License © 2026 al-hub
