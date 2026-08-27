#!/bin/bash
# 로컬 코드서명용 자체 서명 인증서를 만든다. 1회만 실행하면 된다.
#
# ── 왜 필요한가 ────────────────────────────────────────────────────────────
# ad-hoc 서명(`codesign -s -`)의 지정 요구사항은 바이너리 해시 그 자체다:
#
#     # designated => cdhash H"b5e93fc5e2..."
#
# 그래서 코드를 한 줄만 고쳐 다시 빌드해도 해시가 바뀌고, 이전에 부여한
# **손쉬운 사용 권한이 조용히 무효**가 된다. 시스템 설정 목록에는 체크된 채로
# 남아 있어서 더 헷갈린다 — AXIsProcessTrusted() 만 false 를 돌려준다.
#
# 자체 서명 인증서로 서명하면 요구사항이 신원 기반으로 바뀐다:
#
#     # designated => identifier "io.github.kinnch.FaceUnlock"
#                     and certificate leaf = H"<인증서 해시>"
#
# 인증서가 그대로인 한 몇 번을 다시 빌드해도 권한이 유지된다.
# Apple Developer Program($99/년) 없이 무료로 가능하다.
#
# ── 이 스크립트가 하는 일 ──────────────────────────────────────────────────
#   1. 코드서명용 자체 서명 인증서 생성 (10년)
#   2. 로그인 키체인에 가져오기
#   3. 코드서명 용도로 신뢰 설정  ← 여기서 비밀번호를 물어본다
#   4. codesign 이 개인키를 쓸 수 있도록 파티션 목록 설정
#
# 되돌리려면:  ./scripts/make_signing_cert.sh --remove
set -euo pipefail

CN="FaceUnlock Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
    echo "==> '$CN' 인증서를 제거합니다"
    if security delete-certificate -c "$CN" "$KEYCHAIN" 2>/dev/null; then
        echo "    제거됨"
    else
        echo "    (해당 인증서가 없습니다)"
    fi
    exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "✅ '$CN' 인증서가 이미 있습니다. 할 일이 없습니다."
    security find-identity -v -p codesigning | grep -F "$CN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P12PW="$(openssl rand -hex 16)"

echo "==> 1/4  자체 서명 인증서 생성"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Apple 의 Security 프레임워크는 OpenSSL 3 의 기본 PKCS12(AES + SHA256 MAC)를
# 읽지 못한다. 구식 알고리즘을 명시해야 import 가 통과한다.
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12PW" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "==> 2/4  로그인 키체인에 가져오기"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign -A >/dev/null

echo "==> 3/4  코드서명 용도로 신뢰 설정"
echo "    (이 단계에서 macOS 가 비밀번호를 물어봅니다 — 신뢰 설정 변경이라 필요합니다)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> 4/4  codesign 이 개인키를 쓸 수 있도록 설정"
echo "    (키체인 비밀번호를 한 번 더 물어볼 수 있습니다)"
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    건너뜀 — 처음 서명할 때 키체인 접근 허용을 물어봅니다"
fi

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "✅ 완료. Makefile 이 이 인증서를 자동으로 찾아 씁니다."
    security find-identity -v -p codesigning | grep -F "$CN"
    echo
    echo "다음 단계:"
    echo "  1) make debug"
    echo "  2) 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서"
    echo "     FaceUnlock 이 목록에 있으면 '−' 로 지우고 다시 추가 (낡은 항목이라 그렇습니다)"
    echo "  3) 이후로는 몇 번을 다시 빌드해도 권한이 유지됩니다"
else
    echo "❌ 인증서가 유효한 코드서명 신원으로 잡히지 않았습니다."
    echo "   3단계에서 비밀번호 입력을 취소했을 수 있습니다. 다시 실행해 보세요."
    echo "   계속 안 되면 '키체인 접근' 앱 → 인증서 지원 → 인증서 생성 으로"
    echo "   '$CN' (유형: 코드 서명, 자체 서명) 을 직접 만들어도 됩니다."
    exit 1
fi
