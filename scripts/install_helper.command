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
# 메시지는 한국어·영어를 함께 찍는다. 시스템 언어가 먼저 나온다.
# DMG 에서는 '설치 도우미 (Install Helper).command' 라는 이름으로 들어간다.
#
# 주의: 공증이 없어서 이 파일을 열려면 우클릭 → 열기 → 시스템 설정의 '그래도 열기'
# 절차를 **두 번** 밟아야 한다. 첫 번째는 승인만 되고 실행은 안 된다.
# 그 안내는 DMG 배경(tools/make_dmg_background.swift)과 README 에 있다.
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

# 안내는 **두 언어를 모두** 찍는다. 시스템 언어를 먼저, 나머지를 그다음 줄에.
# 감지 하나에 기대지 않는 이유는 설치가 한 번뿐이기 때문이다 — 빗나가면
# 사용자는 읽을 수 없는 안내만 보고 이 창을 닫는다. 줄 수가 두 배로 늘지만
# 그 대가로 누가 열어도 읽을 수 있다.
say()  { if [ "$UILANG" = ko ]; then echo "$1"; echo "$2"
         else echo "$2"; echo "$1"; fi; }
step() { echo ""
         if [ "$UILANG" = ko ]; then echo "==> $1"; echo "    $2"
         else echo "==> $2"; echo "    $1"; fi; }
fail() { if [ "$UILANG" = ko ]; then echo "오류: $1" >&2; echo "Error: $2" >&2
         else echo "Error: $2" >&2; echo "오류: $1" >&2; fi; }

say "FaceUnlock 설치 도우미" "FaceUnlock Install Helper"
echo "────────────────────────────────────────"
# 이 창을 봤다는 건 Gatekeeper 를 통과했다는 뜻이다. 여기 오기까지 '그래도 열기'를
# 두 번 눌러야 해서, 더 눌러야 하나 싶어 헤매는 사람이 많다. 끝났다고 알려준다.
say "Gatekeeper 통과했습니다. '그래도 열기'는 이제 안 눌러도 됩니다 — 나머지는 자동입니다." \
    "You're past Gatekeeper. No more 'Open Anyway' clicks — the rest is automatic."

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
    # 그 라이선스는 받아 쓰는 사람에게도 그대로 걸린다. 개인 기기면 상관없지만
    # 회사 지급 기기라면 얘기가 달라지므로, 받기 전에 알려준다.
    say "    비상업 연구용 라이선스입니다. 업무용 기기에 설치하신다면 먼저 라이선스를 확인해 주세요." \
        "    It is licensed for non-commercial research only — check the license first if this is a work machine."

    # coremltools 는 Python 3.9~3.12 만 지원한다 (3.13+ 아직 안 됨).
    # 맥에 기본으로 있는 /usr/bin/python3 (3.9) 로도 전부 설치되므로,
    # 이름이 아니라 실제 버전을 물어보고 범위에 드는 첫 번째를 쓴다.
    # 예전에는 Homebrew 의 3.11/3.12 만 찾아서, Homebrew 가 없는 사람은
    # 기본 파이썬이 멀쩡히 있는데도 설치가 통째로 막혔다.
    py_ok() {
        [ -n "$1" ] && [ -x "$1" ] || return 1
        # /usr/bin/python3 는 진짜 파이썬이 아니라 xcrun 스텁이다(/usr/bin/git 과
        # 같은 파일). 명령어 도구가 없는 맥에서 이걸 실행하면 설치하겠냐는 창이
        # 불쑥 뜬다. 아래에서 설명하고 물어볼 참이니 여기서는 건드리지 않는다.
        case "$1" in
            /usr/bin/*) has_clt || return 1 ;;
        esac
        "$1" -c 'import sys; sys.exit(0 if (3,9) <= sys.version_info < (3,13) else 1)' \
            >/dev/null 2>&1
    }

    has_clt() { xcode-select -p >/dev/null 2>&1; }

    find_python() {
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
            if py_ok "$candidate"; then PY="$candidate"; return 0; fi
        done
        return 1
    }

    if ! find_python; then
        # 여기까지 왔다면 맥의 기본 파이썬조차 못 쓰는 경우다. 대개는 명령어
        # 도구(Command Line Tools)가 없어서인데, 그건 Homebrew 보다 가볍다.
        BREW="$(command -v brew || true)"
        [ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
        if [ -n "$BREW" ]; then
            echo ""
            say "    변환 도구가 Python 3.12 를 필요로 합니다 (설치되어 있지 않음)." \
                "    The converter needs Python 3.12, which is not installed."
            read -r -p                 "    Homebrew 로 지금 설치할까요? / Install it with Homebrew now? [Y/n] " reply
            case "$reply" in
                [nN]*) say "    설치를 중단합니다. python@3.12 설치 후 다시 실행해 주세요." \
                           "    Aborting. Install python@3.12 and run this again."
                       exit 1 ;;
                *)     "$BREW" install python@3.12 ;;
            esac
            find_python || { fail "Python 설치 후에도 찾지 못했습니다." \
                                  "Python still not found after installing."; exit 1; }
        elif ! has_clt; then
            # 완전히 새 맥이면 여기로 온다. 애플 명령어 도구 안에 파이썬이
            # 들어 있으므로 그것만 깔면 된다 — Homebrew 보다 가볍고, 애플이
            # 직접 배포하는 것이라 받으시는 분 입장에서도 덜 찜찜하다.
            echo ""
            say "    얼굴 인식 모델을 변환하려면 파이썬이 필요한데, 이 맥에는 아직 없습니다." \
                "    Converting the model needs Python, which this Mac doesn't have yet."
            say "    애플이 배포하는 '명령어 도구(Command Line Tools)' 에 들어 있습니다." \
                "    It comes with Apple's Command Line Tools."
            read -r -p                 "    지금 설치할까요? / Install it now? [Y/n] " reply
            case "$reply" in
                [nN]*) say "    설치를 중단합니다. 나중에 터미널에서 xcode-select --install 후 다시 실행해 주세요." \
                           "    Aborting. Run xcode-select --install later, then run this file again."
                       exit 1 ;;
            esac

            xcode-select --install >/dev/null 2>&1 || true
            say "    애플 설치 창이 떴습니다. '설치' 를 눌러 끝날 때까지 기다려 주세요." \
                "    Apple's installer has opened. Click Install and let it finish."
            say "    (이 창은 그대로 두시면 됩니다 — 끝나면 알아서 이어집니다)" \
                "    (Leave this window open — it continues on its own when done)"

            # 설치 프로그램은 바로 반환된다. 끝날 때까지 기다린다. 용량이 커서
            # 회선에 따라 오래 걸리므로 30분까지 본다.
            waited=0
            while [ "$waited" -lt 1800 ]; do
                if has_clt && find_python; then break; fi
                sleep 10
                waited=$((waited + 10))
                printf "."
            done
            echo ""

            find_python || { fail "명령어 도구 설치를 확인하지 못했습니다.
      설치를 마치신 뒤 이 파일을 다시 실행해 주세요." \
                                  "Could not confirm the tools were installed.
      Finish the install, then run this file again."; exit 1; }
        else
            fail "쓸 수 있는 Python (3.9~3.12) 을 찾지 못했습니다.
      터미널에서 xcode-select --install 로 애플 명령어 도구를 설치한 뒤
      이 파일을 다시 실행해 주세요." \
                 "No usable Python (3.9-3.12) was found.
      Run xcode-select --install in Terminal, then run this file again."
            exit 1
        fi
    fi
    echo "    Python: $PY"

    # 작업 폴더는 캐시에 둔다. 중간에 실패해도 내려받은 파일이 남아 이어서 진행된다.
    mkdir -p "$WORK/tools"
    cp "$DIR/.tools/fetch_arcface.py" "$WORK/tools/"

    # pip 캐시도 작업 폴더 안에 둔다. 기본값(~/Library/Caches/pip)에 두면
    # 아래에서 $WORK 를 지워도 torch 휠 등 수백 MB 가 그대로 남는다.
    export PIP_CACHE_DIR="$WORK/pipcache"

    if [ ! -d "$WORK/.venv" ]; then
        "$PY" -m venv "$WORK/.venv"
    fi
    say "    변환 도구 설치 중… (수백 MB, 몇 분 걸립니다. 끝나면 지워집니다)" \
        "    Installing conversion tools… (a few hundred MB, takes minutes; removed afterwards)"
    "$WORK/.venv/bin/pip" install --quiet --upgrade pip
    "$WORK/.venv/bin/pip" install --quiet torch onnx onnx2torch coremltools numpy pillow

    say "    모델 내려받기 + CoreML 변환" \
        "    Downloading and converting the model"
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
