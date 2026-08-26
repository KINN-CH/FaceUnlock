import Foundation
import OpenDirectory

/// 로그인 비밀번호 금고.
///
/// **이 앱의 본질적 위험이 여기에 있다.** 잠금화면에서 비밀번호를 타이핑해 주려면
/// 그 비밀번호를 복호화 가능한 형태로 기기에 보관할 수밖에 없다. 사용자 확인을 받을 수
/// 없는 상황(잠금 상태)에서 써야 하므로 생체·암호 잠금을 걸 수도 없다.
/// 숨기지 말고 UI 와 README 에 그대로 적는다.
///
/// 대신 할 수 있는 최선을 한다:
///   - 대칭키를 Secure Enclave 밖으로 꺼내지 않는다 ([EnclaveCrypto])
///   - Keychain 에는 암호문만 넣는다
///   - 평문은 `[UInt16]` 로만 다루고 사용 직후 0 으로 덮는다 (String 은 지울 수 없다)
enum Vault {

    enum VaultError: LocalizedError {
        case wrongPassword
        case notStored
        case directoryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .wrongPassword:
                return "로그인 비밀번호가 올바르지 않습니다."
            case .notStored:
                return "저장된 비밀번호가 없습니다. 설정에서 다시 등록해 주세요."
            case .directoryUnavailable(let m):
                return "비밀번호를 확인할 수 없습니다: \(m)"
            }
        }
    }

    static var hasPassword: Bool { Keychain.exists(.password) }

    // MARK: 등록

    /// 실제 로그인 비밀번호가 맞는지 확인한 뒤에만 저장한다.
    /// 틀린 값을 저장하면 잠금화면에서 오입력이 반복되고, 계정이 잠길 수도 있다.
    static func store(password: String) throws {
        try verify(password: password)

        var utf16 = Array(password.utf16)
        defer { utf16.resetBytes() }

        let data = utf16.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        var mutable = data
        defer { mutable.resetBytes(in: 0..<mutable.count) }

        let sealed = try EnclaveCrypto.seal(mutable)
        try Keychain.save(sealed, for: .password)
        Log.vault.info("비밀번호 저장됨 (Secure Enclave: \(EnclaveCrypto.usesSecureEnclave))")
    }

    /// OpenDirectory 로 검증한다. `dscl` 을 호출하면 비밀번호가 프로세스 인자로 노출되어
    /// `ps` 에 잠깐이라도 보일 수 있으므로 쓰지 않는다.
    static func verify(password: String) throws {
        do {
            let node = try ODNode(session: ODSession.default(),
                                  type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers,
                                         name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
        } catch let error as NSError {
            // 인증 실패와 시스템 오류를 구분한다. 전자는 사용자 탓, 후자는 우리 탓이다.
            if error.domain == "com.apple.OpenDirectory" || error.domain == ODFrameworkErrorDomain {
                throw VaultError.wrongPassword
            }
            throw VaultError.directoryUnavailable(error.localizedDescription)
        }
    }

    // MARK: 사용

    /// 평문을 UTF-16 코드 유닛 배열로 잠깐 꺼내 준다.
    /// 클로저가 끝나면 배열은 0 으로 덮인다. **배열을 밖으로 복사해 나가지 말 것.**
    static func withPassword<T>(_ body: (inout [UInt16]) throws -> T) throws -> T {
        guard let sealed = Keychain.load(.password) else { throw VaultError.notStored }

        var plain = try EnclaveCrypto.open(sealed)
        defer { plain.resetBytes(in: 0..<plain.count) }

        var units = [UInt16](repeating: 0, count: plain.count / 2)
        _ = units.withUnsafeMutableBytes { plain.copyBytes(to: $0) }
        defer { units.resetBytes() }

        return try body(&units)
    }

    // MARK: 삭제

    static func deletePassword() {
        Keychain.delete(.password)
        Log.vault.info("저장된 비밀번호 삭제됨")
    }
}

extension Array where Element == UInt16 {
    /// 평문이 메모리에 남지 않도록 즉시 덮어쓴다.
    mutating func resetBytes() {
        withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}
