#!/bin/bash
# FaceUnlock 얼굴 인식 모델(ArcFace) 설치 — DMG 사용자용.
#
# InsightFace 가중치는 비상업 연구용 라이선스라 DMG 에 동봉할 수 없다.
# 이 스크립트가 공식 배포처에서 직접 내려받아 CoreML 로 변환한 뒤
# ~/Library/Application Support/FaceUnlock/Models/ 에 넣는다.
# 앱은 번들에 모델이 없으면 이 위치를 찾는다.
#
# DMG 에서는 이 파일이 '모델 설치.command' 라는 이름으로 들어가고,
# 변환 스크립트는 같은 위치의 .tools/fetch_arcface.py 에 숨겨져 있다.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/Library/Caches/FaceUnlock/model-build"
DEST="$HOME/Library/Application Support/FaceUnlock/Models"

echo "==> FaceUnlock 모델 설치를 시작합니다"
echo "    InsightFace 가중치는 라이선스상 동봉할 수 없어 공식 배포처에서 직접 내려받습니다."
echo ""

# coremltools 가 Python 3.13+ 를 아직 지원하지 않는다 (scripts/setup_model_env.sh 와 동일).
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
    echo "오류: Python 3.11 또는 3.12 가 필요합니다 (변환 도구의 요구사항)." >&2
    echo "      Homebrew 로 설치한 뒤 이 파일을 다시 실행해 주세요:" >&2
    echo "          brew install python@3.12" >&2
    exit 1
fi
echo "==> Python: $PY"

# 작업 폴더는 캐시에 둔다. 중간에 실패해도 내려받은 파일이 남아 이어서 진행된다.
mkdir -p "$WORK/tools"
cp "$DIR/.tools/fetch_arcface.py" "$WORK/tools/"

if [ ! -d "$WORK/.venv" ]; then
    "$PY" -m venv "$WORK/.venv"
fi
echo "==> 변환 도구 설치 중… (수백 MB, 몇 분 걸립니다. 끝나면 지워집니다)"
"$WORK/.venv/bin/pip" install --quiet --upgrade pip
"$WORK/.venv/bin/pip" install --quiet torch onnx onnx2torch coremltools numpy pillow

echo "==> 모델 내려받기 + CoreML 변환"
"$WORK/.venv/bin/python" "$WORK/tools/fetch_arcface.py"

mkdir -p "$DEST"
rm -rf "$DEST/ArcFace.mlpackage"
cp -R "$WORK/Resources/Models/ArcFace.mlpackage" "$DEST/"

# 변환 도구·다운로드 캐시는 더 필요 없다. 남기면 1GB 가까이 차지한다.
rm -rf "$WORK"

echo ""
echo "✅ 모델 설치 완료: $DEST/ArcFace.mlpackage"
echo "   FaceUnlock 앱을 (다시) 실행하면 자동으로 인식합니다. 이 창은 닫아도 됩니다."
