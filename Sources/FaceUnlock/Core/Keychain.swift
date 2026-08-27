import Foundation
import LocalAuthentication
import Security

/// 얇은 Keychain 래퍼. 저장하는 건 **암호문뿐**이다 (평문 비밀번호를 여기 직접 넣지 않는다).
enum Keychain {

    static let service = "io.github.kinnch.FaceUnlock"

    enum Account: String {
        case enclaveKey  = "enclave-key"      // Secure Enclave 개인키 blob
        case fallbackKey = "fallback-key"     // SE 없는 기기용 대칭키 (열등한 경로)
        case password    = "login-password"   // AES-GCM 봉인된 로그인 비밀번호
    }

    /// 잠금화면에서 읽어야 하므로 `AfterFirstUnlock` 이 최대한의 보호 수준이다.
    /// `WhenUnlocked` 로 올리면 정작 필요한 순간에 못 읽는다.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// 이 앱만 신뢰하는 ACL.
    ///
    /// 기본 ACL 로 만든 항목은 앱 서명이 바뀔 때마다 macOS 가
    /// "키체인의 키를 사용하려고 합니다" 를 묻는다. 그 창이 **잠금화면에서 뜨면
    /// 답할 방법이 없어** 잠금 해제가 통째로 멈춘다. 미리 이 앱을 신뢰 목록에
    /// 넣어두면 묻지 않는다. 신뢰 기록은 경로가 아니라 지정 요구사항(designated
    /// requirement)으로 남으므로, 고정 인증서로 서명하는 한 재빌드해도 유지된다.
    ///
    /// 아래 두 API 는 deprecated 로 표시되지만 **대체재가 없다.** 샌드박스 밖
    /// 앱의 파일 키체인 ACL 을 다루는 유일한 경로다. 경고를 없애려고 지우면
    /// 확인 창이 그대로 돌아온다.
    private static func selfAccess() -> SecAccess? {
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess,
              let app else { return nil }

        var access: SecAccess?
        guard SecAccessCreate("FaceUnlock" as CFString, [app] as CFArray, &access)
                == errSecSuccess else { return nil }
        return access
    }

    static func save(_ data: Data, for account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data

        // kSecAttrAccess(파일 키체인 ACL)와 kSecAttrAccessible(데이터 보호)은
        // 서로 다른 키체인의 개념이라 함께 넣으면 errSecParam 이 난다.
        // ACL 을 우선하고, 못 만들면 종전 방식으로 되돌린다.
        if let access = selfAccess() {
            attributes[kSecAttrAccess as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = accessible
        }

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecParam, attributes[kSecAttrAccess as String] != nil {
            attributes.removeValue(forKey: kSecAttrAccess as String)
            attributes[kSecAttrAccessible as String] = accessible
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error.os(status) }
    }

    /// 이미 저장된 항목을 현재 ACL 규칙으로 다시 저장한다.
    ///
    /// 예전 빌드가 만들어 둔 항목은 기본 ACL 이라 서명이 바뀔 때마다 확인 창을
    /// 띄운다. 한 번 읽는 데 성공했다면(= 사용자가 그 창에 답해줬다면) 그 값을
    /// 그대로 다시 저장해 ACL 만 갈아끼운다. 데이터는 바뀌지 않는다.
    @discardableResult
    static func migrateAccess(_ account: Account) -> Bool {
        guard let data = load(account) else { return false }
        do {
            try save(data, for: account)
            return true
        } catch {
            Log.vault.error("Keychain ACL 이전 실패 (\(account.rawValue, privacy: .public))")
            return false
        }
    }

    /// 데이터를 실제로 복호화해 가져온다.
    ///
    /// **주의: 이 호출은 다이얼로그를 띄울 수 있다.** 로그인 키체인 항목은 ACL 로
    /// 보호되는데, 앱 서명이 바뀌면 macOS 가 "키체인의 키를 사용하려고 합니다" 를
    /// 물어본다. 잠금화면에서는 이 창에 답할 방법이 없어 **그대로 멈춘다** —
    /// 카메라만 켜진 채 영원히 해제되지 않는 상태가 된다.
    ///
    /// 그래서 잠금화면 경로는 `allowInteraction: false` 로 부른다. 물어보는 대신
    /// `errSecInteractionNotAllowed` 로 즉시 실패해서, 최소한 이유가 로그에 남는다.
    static func load(_ account: Account, allowInteraction: Bool = true) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed {
                Log.vault.error("""
                    Keychain 접근에 사용자 확인이 필요합니다 (\(account.rawValue, privacy: .public)). \
                    잠금화면에서는 답할 수 없어 중단합니다 — 화면이 풀린 상태에서 설정을 열어 \
                    비밀번호를 다시 등록해 주세요.
                    """)
            } else if status != errSecItemNotFound {
                Log.vault.error("Keychain 읽기 실패 (\(account.rawValue, privacy: .public)): \(status)")
            }
            return nil
        }
        return item as? Data
    }

    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// 존재만 확인한다. **데이터를 요청하지 않는 것이 핵심이다.**
    ///
    /// `kSecReturnData: true` 로 물으면 Keychain 이 복호화를 시도하고, 그 순간
    /// ACL 다이얼로그가 뜬다. 메인 스레드에서 이걸 부르면 앱이 통째로 멈춘다.
    /// 속성만 요청하면 복호화가 일어나지 않아 조용히 true/false 만 돌아온다.
    static func exists(_ account: Account) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    enum Error: LocalizedError {
        case os(OSStatus)
        var errorDescription: String? {
            switch self {
            case .os(let s):
                let message = SecCopyErrorMessageString(s, nil) as String? ?? "알 수 없는 오류"
                return "Keychain 오류 \(s): \(message)"
            }
        }
    }
}
