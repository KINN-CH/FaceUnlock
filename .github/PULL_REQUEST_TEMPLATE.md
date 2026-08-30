## 무엇을 · What

<!-- 한 가지만. 무엇을 왜 바꿨는지. · One thing. What changed and why. -->

## 어떻게 확인했나 · How it was verified

<!-- 돌린 명령과 결과. `./build/aligntest --selftest` 는 최소한. -->
<!-- Commands you ran and what they printed. `./build/aligntest --selftest` at minimum. -->

## 카메라나 잠금 경로를 건드렸나요 · Does this touch the camera or lock path

- [ ] 아니오 · No
- [ ] 예 — 실기에서 확인했습니다: 잠그고 → 화면이 꺼지고 → 40초 넘게 기다렸다가
      → 깨워서 얼굴로 열림 · Yes — verified on real hardware: lock, screen sleeps,
      wait 40+ seconds, wake, face opens it

<!-- 이 회귀는 디버거로 안 보이고, v0.1.0~v0.1.4 를 망가뜨린 것이 이것입니다. -->
<!-- This regression is invisible in a debugger; it broke v0.1.0 through v0.1.4. -->
