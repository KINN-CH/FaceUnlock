import os

/// 통합 로깅.
///
/// **절대 규칙**: 로그인 비밀번호, 복호화된 평문, 얼굴 임베딩 원본을 이 로거에 넘기지 않는다.
/// `log stream` 은 다른 프로세스에서도 읽을 수 있고 sysdiagnose 에 남는다.
/// 값을 찍어야 한다면 길이나 해시 접두사만 찍는다.
enum Log {
    private static let subsystem = "io.github.kinnch.FaceUnlock"

    static let app    = Logger(subsystem: subsystem, category: "app")
    static let lock   = Logger(subsystem: subsystem, category: "lock")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let face   = Logger(subsystem: subsystem, category: "face")
    static let vault  = Logger(subsystem: subsystem, category: "vault")
    static let unlock = Logger(subsystem: subsystem, category: "unlock")
}
