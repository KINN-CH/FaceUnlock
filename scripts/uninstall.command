#!/bin/bash
# FaceUnlock 완전 삭제 — 앱과 앱이 만든 것 전부. / FaceUnlock uninstaller.
#
# 보통은 이 스크립트가 필요 없다. 앱을 열어 설정 → '완전 삭제' 버튼을 누르면
# 같은 일을 한다. 이 파일은 **앱을 이미 휴지통에 넣어버린 뒤**에 쓰는 것이다 —
# 그러면 버튼을 누를 방법이 없는데, 봉인된 로그인 비밀번호와 얼굴 임베딩은
# 그대로 남아 있다.
#
# 지우는 목록은 Sources/FaceUnlock/Core/Uninstaller.swift 와 **같아야 한다.**
# 한쪽만 고치면 남는 파일이 생긴다.
set -uo pipefail

BUNDLE_ID="io.github.kinnch.FaceUnlock"
APP="/Applications/FaceUnlock.app"
SUPPORT="$HOME/Library/Application Support/FaceUnlock"

# 시스템 UI 언어 감지 — 한국어가 아니면 영어. (install_helper.command 와 동일)
UILANG=en
if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"ko'; then
    UILANG=ko
elif [ "${LANG:-}" != "${LANG#ko}" ]; then
    UILANG=ko
fi
say()  { if [ "$UILANG" = ko ]; then echo "$1"; else echo "$2"; fi; }
step() { echo ""; if [ "$UILANG" = ko ]; then echo "==> $1"; else echo "==> $2"; fi; }

say "FaceUnlock 완전 삭제" "Uninstall FaceUnlock"
echo "────────────────────────────────────────"
say "지워지는 것:" "This will remove:"
say "  · 등록한 얼굴 (봉인 파일)" "  · your enrolled faces (sealed file)"
say "  · 저장된 로그인 비밀번호 (Keychain)" "  · the saved login password (Keychain)"
say "  · 내려받은 얼굴 인식 모델" "  · the downloaded face recognition model"
say "  · 설정값·캐시" "  · settings and caches"
say "  · 로그인 시 자동 실행 등록" "  · the launch-at-login registration"
say "  · 응용 프로그램 폴더의 FaceUnlock.app" "  · FaceUnlock.app in your Applications folder"
echo ""
say "macOS 계정 비밀번호 자체는 바뀌지 않습니다." \
    "Your actual macOS account password is not changed."
echo ""
printf '%s' "$(say '계속할까요? [y/N] ' 'Continue? [y/N] ')"
read -r reply
case "$reply" in
    y|Y|yes|YES) ;;
    *) say "취소했습니다." "Cancelled."; exit 0 ;;
esac

step "앱 종료" "Quitting the app"
# 실행 중이면 먼저 내린다. 안 그러면 방금 지운 Keychain 항목을 다시 쓸 수 있다.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
pkill -x FaceUnlock >/dev/null 2>&1
sleep 1

step "로그인 항목 해제" "Removing the login item"
# 등록을 푸는 건 SMAppService 로 앱 자신만 할 수 있다. 그래서 앱에 이 일만
# 하고 끝내는 인자를 하나 두었다(App/FaceUnlockApp.swift 의 AppLauncher).
# 앱이 이미 없으면 건너뛴다 — 번들이 사라지면 macOS 가 알아서 항목을 버린다.
if [ -d "$APP" ]; then
    "$APP/Contents/MacOS/FaceUnlock" --unregister-login-item >/dev/null 2>&1 \
        && say "  해제했습니다" "  unregistered" \
        || say "  해제하지 못했습니다 (앱을 지우면 함께 사라집니다)" \
               "  could not unregister (it goes away when the app is deleted)"
else
    say "  앱이 없어 건너뜁니다" "  app is gone — skipping"
fi

step "Keychain 항목 삭제" "Deleting Keychain items"
# 계정마다 하나씩 들어 있어 없어질 때까지 반복한다. security(1) 은 한 번에
# 하나만 지운다.
removed=0
while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do
    removed=$((removed + 1))
    [ "$removed" -gt 20 ] && break   # 무한 루프 방지
done
say "  $removed 개 삭제" "  removed $removed item(s)"

step "파일 삭제" "Deleting files"
for path in \
    "$SUPPORT" \
    "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
    "$HOME/Library/Caches/$BUNDLE_ID" \
    "$HOME/Library/Caches/FaceUnlock" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
do
    if [ -e "$path" ]; then
        rm -rf "$path" && echo "  $path"
    fi
done
# 파일을 지워도 cfprefsd 가 메모리에 들고 있다가 다시 쓸 수 있다.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1
killall cfprefsd >/dev/null 2>&1

step "카메라·손쉬운 사용 허용 기록 초기화" "Resetting privacy approvals"
# 번들 ID 를 반드시 함께 넘긴다. 빼면 그 항목의 **모든 앱** 허용이 초기화된다.
tccutil reset Camera "$BUNDLE_ID" >/dev/null 2>&1
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1

step "앱 삭제" "Removing the app"
if [ -d "$APP" ]; then
    # 지우지 않고 휴지통으로 보낸다 — 실수로 실행했다면 되돌릴 수 있게.
    osascript -e "tell application \"Finder\" to delete POSIX file \"$APP\"" >/dev/null 2>&1 \
        && say "  휴지통으로 옮겼습니다" "  moved to the Trash" \
        || say "  옮기지 못했습니다. Finder 에서 직접 휴지통에 넣어 주세요: $APP" \
               "  could not move it. Please drag it to the Trash yourself: $APP"
else
    say "  응용 프로그램 폴더에 없습니다 (이미 지우셨군요)" \
        "  not in Applications (already removed)"
fi

echo ""
say "끝났습니다." "Done."
say "손쉬운 사용 목록에 FaceUnlock 이 남아 있다면 '−' 로 지워 주세요." \
    "If FaceUnlock still appears in the Accessibility list, remove it there with '−'."
