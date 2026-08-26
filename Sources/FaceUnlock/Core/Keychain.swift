import Foundation
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

    static func save(_ data: Data, for account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessible

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.os(status) }
    }

    static func load(_ account: Account) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
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

    static func exists(_ account: Account) -> Bool { load(account) != nil }

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
