# tmux Sidebar Gradient Tests

이 테스트는 production launcher의 renderer, fingerprint, 상태 전이와 tmux lifecycle을 검증한다. 실제 AI CLI나 네트워크는 사용하지 않는다.

AI 관측은 기본적으로 서버당 하나의 `--observe` 프로세스가 수행하고 presenter 는 그 상태 파일을 읽는다(`TMUX_SESSION_SIDEBAR_AI_OBSERVER=local` 로 presenter 자체 관측 복원; unit test 의 `lib.sh` 는 local 고정). 애니메이션은 client 가 attach 된 presenter 에서만 돈다. client 없이 frame 을 capture 하는 테스트는 launcher 에 `TMUX_SESSION_SIDEBAR_ANIMATE_DETACHED=true` 를 준다. wave 주기는 정확히 1초(24fps × 24 phase)이므로 frame 변화를 1초 간격 두 샘플로만 비교하면 aliasing 된다.

## 실행

```sh
make test                                   # tests/ci.list 전체
bash tests/run-tests.sh --only gradient     # 이 디렉터리만
```

live tmux 서버를 읽는 `test-live-*.sh`는 `tests/manual.list`에 있으며 CI에서 실행하지 않는다.

tmux socket 접근이 제한된 sandbox에서는 `test-lifecycle-e2e.sh` 실행에 추가 권한이 필요할 수 있다.

## 구성

- `test-render.sh`: frame별 ANSI gradient와 비활성 렌더 검증
- `test-fingerprint.sh`: production fingerprint(`act:<pane activity>:cap:<capture cksum>`)의 정규화와 변화 검증
- `test-state.sh`: 관측 변화·grace 중 `running` 유지, shell-only `gone` 상태 검증
- `test-session-isolation.sh`: 여러 session의 animation 상태 독립성 검증
- `test-lifecycle-e2e.sh`: 격리 tmux와 fake `codex`를 사용한 시작, 정지, 재시작, 종료 검증
- `test-equal-size-enter-observer-continues-e2e.sh`: 같은 크기 window 간 Enter 전환 후 target presenter 의 AI 관측이 계속되는지(gradient 시작·종료) 검증. handover 가 남긴 `transition_render_pending` marker 뒤에서 observer 가 영구 정지하던 회귀
- `test-detached-presenter-no-animation-e2e.sh`: client 가 붙은 presenter 만 gradient 를 애니메이션하고, detached presenter 는 정적 frame 을 유지하며, Enter 전환 시 애니메이션이 client 를 따라가는지 검증
- `test-shell-session-presenter-tracks-others-e2e.sh`: shell-only 세션에 머무는 presenter 가 다른 세션의 AI 상태(running/idle 전이, 나중에 시작된 AI 발견)를 계속 관측하는지 검증. "Enter 로 이동 후 gradient 가 멈춘다" 필드 리포트 재현
- `test-shared-observer-e2e.sh`: 서버당 observer(`--observe`) 1개, 상태 파일 신선도, presenter 의 공유 상태 소비, observer 강제 종료 후 재기동, sidebar 소멸 후 자동 종료 검증
- `test-ai-observer-state.sh`: 공유 상태 파일 파서·stale 판정·collect 반영 unit
- `test-regressions.sh`: idle grace, spinner 재그리기 관측, pane 세대 초기화, session/client 전환과 resize 회귀 검증
- `lib.sh`: launcher 함수 로딩, tmux snapshot stub, assertion 공통 helper. `run_test`는 test 본문을 errexit subshell로 실행하므로 모든 `assert_*` 실패가 FAIL이 된다

## 결과 의미

- `PASS`: 현재 요구사항이 충족됨
- `FAIL`: 기존 동작의 회귀 또는 test harness 오류
- `XFAIL`: 아직 수정하지 않은 알려진 문제를 예상대로 재현함
- `XPASS`: 알려진 문제가 해결됐으므로 XFAIL을 일반 assertion으로 전환해야 함

현재 자동 테스트에는 XFAIL이 없습니다. 실제 attached tmux에서 빠른 session 전환 직후 이전 `>`가 잠깐 남는 transient cursor frame은 별도 수동 재현 대상입니다.
