#!/bin/bash
# FaceUnlock 설치 도우미 — DMG 사용자용 원클릭 설치. / FaceUnlock install helper.
#
# 이 파일 하나가 설치의 전부를 처리한다:
#   1) 앱을 /Applications 로 복사 (이미 드래그했다면 그 자리에서 교체)
#   2) quarantine 해제 (공증이 없어 필요 — 사용자가 터미널 명령을 칠 필요 없게)
#   3) 얼굴 인식 모델(ArcFace) 내려받기 + CoreML 변환
#      - InsightFace 가중치는 비상업 연구용 라이선스라 DMG 에 동봉할 수 없어
#        공식 배포처에서 직접 내려받는다. 변환 스크립트는 .tools/ 에 숨겨져 있다.
#      - Python 3.11/3.12 가 없으면 Homebrew 로 설치를 제안한다
#   4) 앱 실행
#
# 메시지는 시스템 언어가 한국어면 한국어, 아니면 영어로 나온다.
# DMG 에서는 '설치 도우미 (Install Helper).command' 라는 이름으로 들어간다.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/FaceUnlock.app"
APP_DST="/Applications/FaceUnlock.app"
WORK="$HOME/Library/Caches/FaceUnlock/model-build"
DEST="$HOME/Library/Application Support/FaceUnlock/Models"

# 시스템 UI 언어 감지 — 한국어가 아니면 영어.
UILANG=en
if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"ko'; then
    UILANG=ko
elif [ "${LANG:-}" != "${LANG#ko}" ]; then
    UILANG=ko
fi
say()  { if [ "$UILANG" = ko ]; then echo "$1"; else echo "$2"; fi; }
step() { echo ""; if [ "$UILANG" = ko ]; then echo "==> $1"; else echo "==> $2"; fi; }
fail() { if [ "$UILANG" = ko ]; then echo "오류: $1" >&2; else echo "Error: $2" >&2; fi; }

say "FaceUnlock 설치 도우미" "FaceUnlock Install Helper"
echo "────────────────────────────────────────"

# ── 1. 앱 복사 ───────────────────────────────────────────────
if [ -d "$APP_DST" ]; then
    step "앱이 이미 Applications 에 있습니다 — 이 DMG 버전으로 새로 복사합니다" \
         "App already in Applications — replacing it with this DMG's version"
    pkill -x FaceUnlock 2>/dev/null || true
    rm -rf "$APP_DST"
else
    step "앱을 Applications 로 복사합니다" "Copying the app into Applications"
fi
if [ ! -d "$APP_SRC" ]; then
    fail "이 파일 옆에 FaceUnlock.app 이 없습니다. DMG 안에서 실행해 주세요." \
         "FaceUnlock.app is not next to this file. Run this from inside the DMG."
    exit 1
fi
cp -R "$APP_SRC" "$APP_DST"

# ── 2. quarantine 해제 ───────────────────────────────────────
# Apple 공증이 없어서 그냥 열면 "손상되었습니다" 경고가 뜬다. 파일이 손상된 게
# 아니라 서명 확인을 못 한 것뿐이다. 미리 quarantine 을 걷어 경고를 없앤다.
step "실행 차단(quarantine) 해제" "Removing the quarantine flag"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# ── 3. 얼굴 인식 모델 ────────────────────────────────────────
if [ -d "$DEST/ArcFace.mlpackage" ]; then
    step "얼굴 인식 모델이 이미 설치되어 있습니다 — 건너뜁니다" \
         "Face recognition model already installed — skipping"
else
    step "얼굴 인식 모델(ArcFace)을 설치합니다" \
         "Installing the face recognition model (ArcFace)"
    say "    라이선스상 DMG 에 동봉할 수 없어 공식 배포처에서 직접 내려받습니다." \
        "    Its license forbids bundling, so it is downloaded from the official source."

    # coremltools 가 Python 3.13+ 를 아직 지원하지 않는다.
    find_python() {
        PY=""
        for candidate in \
            /opt/homebrew/opt/python@3.12/bin/python3.12 \
            /opt/homebrew/opt/python@3.11/bin/python3.11 \
            "$(command -v python3.12 || true)" \
            "$(command -v python3.11 || true)"
        do
            if [ -n "$candidate" ] && [ -x "$candidate" ]; then PY="$candidate"; return 0; fi
        done
        return 1
    }

    if ! find_python; then
        BREW="$(command -v brew || true)"
        [ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
        if [ -n "$BREW" ]; then
            echo ""
            say "    변환 도구가 Python 3.12 를 필요로 합니다 (설치되어 있지 않음)." \
                "    The converter needs Python 3.12, which is not installed."
            if [ "$UILANG" = ko ]; then
                read -r -p "    Homebrew 로 지금 설치할까요? [Y/n] " reply
            else
                read -r -p "    Install it with Homebrew now? [Y/n] " reply
            fi
            case "$reply" in
                [nN]*) say "    설치를 중단합니다. python@3.12 설치 후 다시 실행해 주세요." \
                           "    Aborting. Install python@3.12 and run this again."
                       exit 1 ;;
                *)     "$BREW" install python@3.12 ;;
            esac
            find_python || { fail "Python 설치 후에도 찾지 못했습니다." \
                                  "Python still not found after installing."; exit 1; }
        else
            fail "Python 3.11/3.12 와 Homebrew 가 모두 없습니다.
      https://brew.sh 에서 Homebrew 설치 후 이 파일을 다시 실행해 주세요." \
                 "Neither Python 3.11/3.12 nor Homebrew was found.
      Install Homebrew from https://brew.sh, then run this file again."
            exit 1
        fi
    fi
    echo "    Python: $PY"

    # 작업 폴더는 캐시에 둔다. 중간에 실패해도 내려받은 파일이 남아 이어서 진행된다.
    mkdir -p "$WORK/tools"
    cp "$DIR/.tools/fetch_arcface.py" "$WORK/tools/"

    if [ ! -d "$WORK/.venv" ]; then
        "$PY" -m venv "$WORK/.venv"
    fi
    say "    변환 도구 설치 중… (수백 MB, 몇 분 걸립니다. 끝나면 지워집니다)" \
        "    Installing conversion tools… (a few hundred MB, takes minutes; removed afterwards)"
    "$WORK/.venv/bin/pip" install --quiet --upgrade pip
    "$WORK/.venv/bin/pip" install --quiet torch onnx onnx2torch coremltools numpy pillow

    say "    모델 내려받기 + CoreML 변환 (진행 로그는 한국어로 나옵니다)" \
        "    Downloading + converting the model (progress log below is in Korean)"
    "$WORK/.venv/bin/python" "$WORK/tools/fetch_arcface.py"

    mkdir -p "$DEST"
    rm -rf "$DEST/ArcFace.mlpackage"
    cp -R "$WORK/Resources/Models/ArcFace.mlpackage" "$DEST/"

    # 변환 도구·다운로드 캐시는 더 필요 없다. 남기면 1GB 가까이 차지한다.
    rm -rf "$WORK"
fi

# ── 4. 실행 ──────────────────────────────────────────────────
step "설치 완료 — FaceUnlock 을 실행합니다" "Done — launching FaceUnlock"
open "$APP_DST"

echo ""
say "✅ 끝났습니다. 메뉴바의 얼굴 아이콘 → 설정에서 얼굴과 비밀번호를 등록하세요." \
    "✅ All set. Open Settings from the menu-bar face icon to enroll your face and password."
say "   이 창은 닫아도 됩니다." "   You can close this window."
