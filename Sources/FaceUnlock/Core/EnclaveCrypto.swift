import CryptoKit
import Foundation

/// Secure Enclave 기반 봉인/개봉.
///
/// Sapphire 는 대칭키를 암호문과 **같은 Keychain 에 평문으로** 넣어두기 때문에
/// 키체인을 한 번 덤프하면 로그인 비밀번호가 그대로 나온다.
/// 여기서는 Secure Enclave 안에서만 존재하는 P-256 키로 ECDH 를 돌려 대칭키를 유도한다.
/// Keychain 에 들어가는 건 Enclave 가 자기만 풀 수 있게 감싼 키 blob 이라,
/// 다른 기기·다른 앱으로 옮겨도 복호화가 불가능하다.
///
/// ACL 에 생체/암호 요구를 **걸지 않는다** — 잠금화면에서 써야 하는데 사용자 확인을
/// 요구하면 그 순간 앱이 멈춘다. 대신 접근 조건을 `AfterFirstUnlockThisDeviceOnly` 로 묶는다.
enum EnclaveCrypto {

    enum CryptoError: LocalizedError {
        case noKey
        case sealFailed(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .noKey:            return "암호화 키를 만들 수 없습니다."
            case .sealFailed(let m): return "암호화 실패: \(m)"
            case .openFailed(let m): return "복호화 실패: \(m)"
            }
        }
    }

    static var usesSecureEnclave: Bool { SecureEnclave.isAvailable }

    // MARK: 대칭키 유도

    /// Enclave 개인키와 그 자신의 공개키로 ECDH → HKDF. 결과는 매번 같지만
    /// 유도 과정이 Enclave 안에서 일어나므로 키 자체는 밖으로 나오지 않는다.
    private static func symmetricKey(allowInteraction: Bool) throws -> SymmetricKey {
        if usesSecureEnclave {
            let key = try enclaveKey(allowInteraction: allowInteraction)
            let shared = try key.sharedSecretFromKeyAgreement(with: key.publicKey)
            return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                  salt: Data("FaceUnlock.v1".utf8),
                                                  sharedInfo: Data(),
                                                  outputByteCount: 32)
        }
        return try fallbackKey(allowInteraction: allowInteraction)
    }

    private static func enclaveKey(allowInteraction: Bool) throws
            -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = Keychain.load(.enclaveKey, allowInteraction: allowInteraction),
           let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
            return key
        }
        // 읽기가 막혀서 실패한 것일 수도 있다. 그때 새 키를 만들면 기존 암호문을
        // **영구히** 못 여는 상태가 되므로, 물어볼 수 없는 상황에서는 만들지 않는다.
        guard allowInteraction else { throw CryptoError.noKey }

        guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() else {
            throw CryptoError.noKey
        }
        try Keychain.save(key.dataRepresentation, for: .enclaveKey)
        Log.vault.info("Secure Enclave 키 생성됨")
        return key
    }

    /// Secure Enclave 가 없는 기기(구형 Intel Mac)용 폴백.
    /// 대칭키가 Keychain 에 평문으로 남으므로 보호 수준이 한 단계 낮다.
    private static func fallbackKey(allowInteraction: Bool) throws -> SymmetricKey {
        if let data = Keychain.load(.fallbackKey, allowInteraction: allowInteraction) {
            return SymmetricKey(data: data)
        }
        guard allowInteraction else { throw CryptoError.noKey }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try Keychain.save(data, for: .fallbackKey)
        Log.vault.warning("Secure Enclave 없음 — Keychain 대칭키로 폴백")
        return key
    }

    // MARK: 봉인 / 개봉

    static func seal(_ plaintext: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: try symmetricKey(allowInteraction: true))
            guard let combined = box.combined else {
                throw CryptoError.sealFailed("combined 생성 실패")
            }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.sealFailed(error.localizedDescription)
        }
    }

    static func open(_ ciphertext: Data, allowInteraction: Bool = true) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: try symmetricKey(allowInteraction: allowInteraction))
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.openFailed(error.localizedDescription)
        }
    }

    /// 키를 폐기한다. 이후 기존 암호문은 **영구히** 복호화 불가능하다.
    static func destroyKeys() {
        Keychain.delete(.enclaveKey)
        Keychain.delete(.fallbackKey)
        Log.vault.info("암호화 키 폐기됨")
    }
}
