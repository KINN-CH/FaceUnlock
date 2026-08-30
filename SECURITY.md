# Security Policy

This app types your login password into the macOS lock screen. That is the whole
point of it, and it is also the reason this file exists. Please read the limits
below before reporting something — several of the scariest-sounding properties
of this project are known, documented, and unfixable by design.

한국어 안내는 [아래쪽](#보안-정책)에 있습니다.

## Supported versions

Only the latest release. There is no backport branch.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Anything older | ❌ — [update](https://github.com/KINN-CH/FaceUnlock/releases/latest) |

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. It is enabled, and it keeps the report out of public view until
there is a fix.

Please do not open a public issue for anything that would let someone else get
into a stranger's Mac.

This is one person's side project, not a funded product. There is no bounty.
Expect a first reply within about a week, and expect honesty rather than speed —
if something cannot be fixed, the answer will say so instead of going quiet.

## Already known — please don't report these

**A video of your face defeats it.** A built-in webcam sees one flat image and
cannot measure depth. The blink check stops a printed photo; it does not stop a
recording of you blinking, played back on a phone. Fixing this needs a depth
sensor the machine does not have, so it will not be fixed.

**Your login password is stored in a form that can be decrypted.** macOS gives
third-party apps no public API for unlocking the screen, so the password has to
be typed. The protections that exist are in place — the symmetric key is derived
only inside the Secure Enclave (P-256 ECDH → AES-GCM), only the ciphertext is
kept in the Keychain, copying it to another Mac makes it unreadable, and the
plaintext is handled as `[UInt16]` and zeroed after use. None of that helps
against someone who already has this Mac unlocked. It cannot: the password must
be usable *from the lock screen*, so it cannot be gated behind another secret.

**It does not cover the FileVault boot screen.** That screen runs before macOS
is up, where no app exists.

**The DMG is not notarized and not signed by a paid Developer ID.** That is a
distribution limitation, not a defect. Building from source avoids it.

**The face model is downloaded at install time.** The ArcFace weights are under
InsightFace's non-commercial research license and cannot ship in the repo or the
DMG. The installer fetches them from the official release.

## In scope

Things that would genuinely surprise a careful reader:

- Any path that exposes the stored password outside the unlock moment
- Anything that lets a face that was never registered unlock the Mac
- Anything that writes face embeddings or the password somewhere unsealed
- Anything the app sends over the network beyond the once-a-day release check
  (which is a single unauthenticated GET to GitHub and can be turned off)

---

# 보안 정책

이 앱은 로그인 비밀번호를 잠금 화면에 대신 입력합니다. 그게 이 앱이 하는
일이고, 이 문서가 있는 이유이기도 합니다. 무서워 보이는 성질 몇 가지는 이미
알려져 있고 문서에 적혀 있으며 구조상 고칠 수 없습니다. 신고 전에 아래를
먼저 읽어주세요.

## 지원 버전

최신 릴리스만 지원합니다. 이전 버전으로 되돌려 고치는 브랜치는 없습니다.

## 신고 방법

이 저장소의 **Security → Report a vulnerability** 를 이용해주세요. 비공개
신고가 켜져 있어서, 고쳐지기 전까지 내용이 공개되지 않습니다.

남의 맥에 들어갈 수 있게 되는 종류의 문제는 공개 이슈로 올리지 말아주세요.

혼자 만드는 프로젝트라 포상금은 없습니다. 첫 답은 일주일 안에 드리려고
합니다. 빠른 답보다는 솔직한 답을 드리겠습니다 — 못 고치는 것이면 조용히
넘어가지 않고 못 고친다고 적겠습니다.

## 이미 알려진 것 — 신고하지 않으셔도 됩니다

**얼굴 영상이면 뚫립니다.** 내장 웹캠은 평면 이미지 하나를 볼 뿐 깊이를
재지 못합니다. 눈 깜빡임 확인은 인쇄된 사진을 막지만, 깜빡이는 영상을
휴대폰으로 재생하는 것은 막지 못합니다. 깊이 센서 없이는 해결되지 않아
고칠 계획이 없습니다.

**로그인 비밀번호는 복호화 가능한 형태로 보관됩니다.** macOS 는 서드파티
앱에 화면 잠금 해제 API 를 주지 않아서, 비밀번호를 직접 입력하는 수밖에
없습니다. 가능한 보호는 전부 걸려 있습니다 — 대칭키는 Secure Enclave
안에서만 만들어지고(P-256 ECDH → AES-GCM), 키체인에는 암호문만 들어가며,
다른 맥으로 옮기면 읽히지 않고, 평문은 `String` 대신 `[UInt16]` 로 다루다
사용 직후 0으로 덮습니다. 이 맥에 이미 로그인해 있는 사람 앞에서는 아무
소용이 없습니다. 그럴 수밖에 없습니다 — 비밀번호가 *잠금 화면에서* 쓰여야
하므로 또 다른 비밀 뒤에 숨길 수가 없습니다.

**FileVault 부팅 화면은 다루지 못합니다.** macOS 가 올라오기 전 화면이라
어떤 앱도 그곳에 없습니다.

**DMG 는 공증도 유료 Developer ID 서명도 없습니다.** 배포상의 한계이지
결함이 아닙니다. 소스에서 빌드하면 해당되지 않습니다.

**얼굴 모델은 설치할 때 내려받습니다.** ArcFace 가중치가 비상업 연구용
라이선스라 저장소에도 DMG 에도 넣을 수 없습니다.

## 신고 대상

주의 깊은 사람이 보면 놀랄 만한 것들입니다.

- 잠금 해제 순간 외에 저장된 비밀번호가 드러나는 경로
- 등록한 적 없는 얼굴로 잠금이 풀리는 경우
- 얼굴 임베딩이나 비밀번호가 봉인되지 않은 채 어딘가에 기록되는 경우
- 하루 한 번의 릴리스 확인(끌 수 있는, GitHub 로의 인증 없는 GET 하나)
  외에 앱이 네트워크로 내보내는 것
