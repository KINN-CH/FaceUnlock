#!/usr/bin/env bash
# ArcFace 변환용 Python 환경을 만든다.
#
# coremltools 는 Python 3.9~3.12 만 지원한다 (3.13+ 아직 안 됨). 맥에 기본으로
# 있는 /usr/bin/python3 (3.9) 로도 전부 설치되므로 Homebrew 는 필수가 아니다.
# 이 venv 는 **빌드 타임 도구 전용**이다. 변환이 끝나면 지워도 앱은 정상 동작한다.
set -euo pipefail

cd "$(dirname "$0")/.."

# 이름이 아니라 실제 버전을 물어본다. `python3` 가 3.14 인 맥이 흔하다.
py_ok() {
    [ -n "$1" ] && [ -x "$1" ] || return 1
    "$1" -c 'import sys; sys.exit(0 if (3,9) <= sys.version_info < (3,13) else 1)' \
        >/dev/null 2>&1
}

PY=""
for candidate in \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    "$(command -v python3.12 || true)" \
    "$(command -v python3.11 || true)" \
    "$(command -v python3.10 || true)" \
    "$(command -v python3.9 || true)" \
    /usr/bin/python3 \
    "$(command -v python3 || true)"
do
    if py_ok "$candidate"; then PY="$candidate"; break; fi
done

if [ -z "$PY" ]; then
    echo "오류: 쓸 수 있는 Python (3.9~3.12) 을 찾지 못했습니다." >&2
    echo "      xcode-select --install 로 애플 명령어 도구를 설치하거나," >&2
    echo "      brew install python@3.12 로 설치한 뒤 다시 실행해 주세요." >&2
    exit 1
fi

echo "==> 사용할 인터프리터: $PY ($("$PY" -V))"

if [ ! -d .venv ]; then
    "$PY" -m venv .venv
    echo "==> .venv 생성됨"
fi

.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet torch onnx onnx2torch coremltools numpy pillow
echo "==> 의존성 설치 완료"
