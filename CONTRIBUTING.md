# Contributing

한국어 안내는 [아래쪽](#기여하기)에 있습니다.

## Before you write code

Open an issue or a [discussion](https://github.com/KINN-CH/FaceUnlock/discussions)
first if the change is more than a few lines. This is a small project with a
narrow purpose, and some things are deliberately out of scope (see below) — it
would be a waste of your evening to find that out from a closed pull request.

The most useful contribution right now is not code. It is **telling us whether
it works on your machine**: which MacBook, which macOS, and whether the lock
screen actually opened. There is a thread for that in Discussions.

## Building

No Xcode project. The Makefile is the build system.

```bash
make release                     # build and sign the app bundle
make aligntest                   # build the self-check tool
./build/aligntest --selftest     # lock guard · alignment residual · render orientation
```

`make install && open -a /Applications/FaceUnlock.app` installs it — `make
install` only kills the running app, it does not relaunch it.

Two targets are **not** run in CI and should not be added to it: `make model`
and `make xcheck` both download the InsightFace ArcFace weights, which are under
a non-commercial research license. They must never be fetched by public CI, and
the weights must never be committed.

`--selftest` needs no model, which is why it is the check CI runs.

## Pull requests

- CI must be green. Do not make a check pass by making the check weaker.
- Keep the diff to one thing.
- Comments in this codebase say *why*, not *what*. Match that.
- Commit messages are `type: short summary` — Korean or English, either is fine.
- Touching the camera or lock path? Say in the PR that you tested the real
  regression: lock the Mac, let the screen go dark, wait more than 40 seconds,
  wake it, and check that your face opens it. That failure mode is invisible in
  a debugger and it broke v0.1.0 through v0.1.4.

## Deliberately out of scope

Not because they are bad ideas — because they are the wrong trade for this
project.

| | Why not |
|---|---|
| PAM module (sudo, auth dialogs) | Get it wrong and you cannot log in at all. |
| Passive anti-spoofing model | Every usable set of weights has the same licensing problem ArcFace already has. |
| Sparkle auto-install | The build is unsigned and unnotarized; automatic installation of that is not something to hand to strangers. |
| Threshold tuning PRs | The thresholds are set. Changes need evidence from real use, not a hunch. |

---

# 기여하기

## 코드를 쓰기 전에

몇 줄 넘는 변경이라면 먼저 이슈나
[Discussions](https://github.com/KINN-CH/FaceUnlock/discussions) 에 올려주세요.
목적이 좁은 작은 프로젝트라 일부러 다루지 않는 것들이 있습니다(아래 표).
닫힌 PR 로 그 사실을 알게 되면 저녁 시간이 아깝습니다.

지금 가장 도움이 되는 건 코드가 아닙니다. **본인 기기에서 되는지 알려주는
것**입니다 — 어떤 맥북, 어떤 macOS, 잠금 화면이 실제로 열렸는지.
Discussions 에 그 스레드가 있습니다.

## 빌드

Xcode 프로젝트는 없습니다. Makefile 이 빌드 시스템입니다.

```bash
make release                     # 앱 번들 빌드 + 서명
make aligntest                   # 자체 검증 도구 빌드
./build/aligntest --selftest     # 잠금 가드 · 정렬 잔차 · 렌더 상하 방향
```

설치는 `make install && open -a /Applications/FaceUnlock.app` 입니다 —
`make install` 은 앱을 죽이기만 하고 다시 띄우지 않습니다.

`make model` 과 `make xcheck` 는 **CI 에 넣지 않습니다.** 둘 다 InsightFace
ArcFace 가중치를 내려받는데 비상업 연구용 라이선스입니다. 공개 CI 가 받아가게
해서는 안 되고, 가중치를 커밋해서도 안 됩니다.

`--selftest` 는 모델 없이 돌기 때문에 CI 가 이것을 씁니다.

## 풀 리퀘스트

- CI 가 초록이어야 합니다. 검사를 무르게 고쳐서 통과시키지 마세요.
- 한 PR 은 한 가지만.
- 이 코드베이스의 주석은 *무엇*이 아니라 *왜*를 적습니다. 맞춰주세요.
- 커밋 메시지는 `type: 짧은 요약` — 한국어든 영어든 상관없습니다.
- 카메라나 잠금 경로를 건드렸다면, 실제 회귀 검사를 했다고 PR 에 적어주세요:
  잠그고 → 화면이 꺼지고 → 40초 넘게 기다렸다가 → 깨워서 얼굴로 열리는지.
  디버거로는 안 보이는 실패이고, v0.1.0~v0.1.4 를 망가뜨린 것이 이것입니다.

## 일부러 다루지 않는 것

나쁜 생각이라서가 아니라, 이 프로젝트에는 맞지 않는 거래여서입니다.

| | 이유 |
|---|---|
| PAM 모듈 (sudo·인증 창) | 잘못 만들면 로그인 자체가 막힙니다. |
| 패시브 안티스푸핑 모델 | 쓸 만한 가중치가 전부 ArcFace 와 같은 라이선스 문제를 안고 있습니다. |
| Sparkle 자동 설치 | 무서명·무공증 빌드입니다. 그걸 자동으로 설치하게 만들어 남에게 건넬 수는 없습니다. |
| 임계값 조정 PR | 임계값은 정해져 있습니다. 바꾸려면 실사용 근거가 필요하고, 감으로는 안 됩니다. |
