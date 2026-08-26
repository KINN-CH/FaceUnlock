#!/usr/bin/env bash
# ArcFace 변환용 Python 환경을 만든다.
#
# coremltools 가 Python 3.14 를 아직 지원하지 않아서 3.11 또는 3.12 가 필요하다.
# 이 venv 는 **빌드 타임 도구 전용**이다. 변환이 끝나면 지워도 앱은 정상 동작한다.
set -euo pipefail

cd "$(dirname "$0")/.."

PY=""
for candidate in \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    "$(command -v python3.12 || true)" \
    "$(command -v python3.11 || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then PY="$candidate"; break; fi
done

if [ -z "$PY" ]; then
    echo "오류: Python 3.11 또는 3.12 를 찾지 못했습니다." >&2
    echo "      brew install python@3.11 로 설치한 뒤 다시 실행해 주세요." >&2
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
