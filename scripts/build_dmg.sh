#!/bin/bash
# DMG 조립 — dmgbuild(Python) 로 배경·아이콘 배치가 담긴 .DS_Store 를 만든다.
# Finder AppleScript 방식과 달리 자동화 권한 프롬프트 없이 헤드리스로 동작한다.
# 사용: scripts/build_dmg.sh <staging폴더> <배경.png> <출력.dmg>
set -euo pipefail

STAGING="$1"; BG="$2"; OUT="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/build/dmg-venv"

if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip dmgbuild
fi

rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg_settings.py" \
    -D staging="$STAGING" \
    -D background="$BG" \
    -D volicon="$ROOT/Resources/AppIcon.icns" \
    FaceUnlock "$OUT"
