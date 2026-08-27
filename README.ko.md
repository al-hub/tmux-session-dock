# tmux-session-dock ⚡ (한국어 설명서)

> **tmux를 위한 초고속 무깜빡임(Zero-Flicker) 워크스페이스 세션 도크 및 오케스트레이터**  
> *Window-Local 씬 프레젠터 • 24프레임 실시간 AI 파형 모니터링 • 59종 프리미엄 테마 • 완전 자립형 생명주기*

---

## ✨ 순정 tmux 대비 주요 기능

### 1. 세션 관리 사이드바

- **열기·저장·이동·선택**: `Prefix + s`로 세션 도크를 열고 닫습니다. 행을 선택해 `Enter`로 즉시 세션을 이동하며, 세션 생성·이름 변경·삭제/아카이브와 아카이브 복원을 도크 안에서 처리합니다.
- **무깜빡임 전환**: 물리 페인을 옮기지 않고 각 윈도우의 Presenter를 통해 Native `switch-client`를 수행합니다.
- **Gradient 효과**: 백그라운드 AI CLI의 활동 상태를 감지해 세션 행에 실시간 파형 gradient로 표시합니다. 선택한 세션만이 아니라 다른 세션의 활동도 확인할 수 있습니다.
- **Subpane**: 싱글톤 터미널 Subpane을 열고 닫고(`s`), 상단/하단을 즉시 전환(`p`)하며, 높이를 유지합니다.
- **아카이브**: 셸 히스토리(`$HISTFILE`)를 오염시키지 않고 세션을 스냅샷으로 저장하고 일괄 복원합니다.

### 2. 테마 관리

- **수십 종의 내장 테마**: 59종 Canonical 테마를 제공합니다.
- **테마 선택·수정**: `Prefix + T`의 실시간 ANSI 프리뷰로 테마를 선택하고, tmux 설정의 `@session-dock-theme` 또는 테마 설정 파일을 수정해 기본 테마와 색상을 조정할 수 있습니다.

### 3. 단축키와 현황 보기

- **현황·도움말**: `Prefix + h`/`?`로 전체 단축키 도움말을, `Prefix + /`로 검색 가능한 커맨드 팔레트를 엽니다. 설치 상태는 `./setup.sh status`로 확인합니다.
- **재편집 UI 없음**: 현재 도크 안에서 단축키를 재지정하는 편집 화면은 제공하지 않습니다. 단축키 변경은 tmux 설정 파일에서 합니다 (`@session-dock-key` 등).
- **작업 공간 보호**: 분할 단축키와 `Alt + s` 빠른 포커스 이동으로 도크를 유지한 채 작업 페인을 제어합니다.

### 4. 설치·검증 생명주기

- **통합 제어기**: `./setup.sh`에서 `install`, `update`, `uninstall`, `status`, `build`, `test`, `purge`를 관리합니다.

---

## 🚀 빠른 시작

### 1. TPM (Tmux Plugin Manager) 설치 (권장)

`~/.tmux.conf`에 아래 내용을 추가하고 `Prefix + I`를 누릅니다:
```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'al-hub/tmux-session-dock'

# 선택적 커스텀 옵션
set -g @session-dock-key 's'              # 사이드바 토글 키 (기본: Prefix + s)
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

# 특정 릴리스로 고정 또는 다운그레이드 (태그·브랜치·커밋)
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- install --ref v0.3.19

# 최신 main 으로 복귀
curl -fsSL https://raw.githubusercontent.com/al-hub/tmux-session-dock/refs/heads/main/setup.sh | bash -s -- update
```

`--ref`(또는 `TMUX_DOCK_REF=...`)는 `~/.local/share/tmux-session-dock` 관리 클론에 대한 `install`·`update` 에 적용됩니다. 지정하지 않으면 두 명령 모두 최신 `main` 을 따릅니다. 실행 중인 사이드바는 구버전 코드를 유지하므로 `tmux kill-server` 후 재접속하세요. `./setup.sh status` 가 심링크가 가리키는 체크아웃 ref 를 보여줍니다.

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

## ⌨️ 주요 단축키 가이드

| 단축키 | 기능 설명 |
| :--- | :--- | :--- |
| **`Prefix + s`** | 세션 도크 사이드바 열기 / 닫기 (토글) |
| **`Prefix + T`** | 🎨 59종 프리미엄 테마 피커 팝업 열기 (실시간 프리뷰) |
| **`Prefix + /`** | ⌨️ 전체 단축키 검색 (커맨드 팔레트) |
| **`Prefix + h`** / **`?`** | 📖 인터랙티브 도움말 가이드 팝업 열기 |
| **`Prefix + \|`** / **`%`** | 작업 영역 가로 분할 (사이드바 보호) |
| **`Prefix + _`** / **`"`** | 작업 영역 세로 분할 (사이드바 보호) |
| **`Alt + s`** (`M-s`) | ⚡ 세션 도크 0ms 즉시 포커스 점프 / 복귀 |

---

## 📄 라이선스

MIT License © 2026 al-hub
