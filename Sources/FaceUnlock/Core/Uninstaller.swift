import AppKit
import Foundation
import ServiceManagement

/// 앱과 앱이 만든 것을 전부 지운다.
///
/// macOS 에는 "앱을 휴지통에 넣으면 그 앱이 만든 파일도 함께 지운다" 는 장치가
/// 없다. Finder 로 지우는 순간 우리 코드가 실행될 기회 자체가 사라지므로,
/// 남는 것들(내려받은 모델·봉인된 얼굴·Keychain 항목·로그인 항목)을 스스로
/// 치울 방법이 없다. 그래서 지우는 일을 앱 안에 둔다 — 데이터를 먼저 지우고,
/// 마지막에 자기 자신을 휴지통으로 보낸다.
///
/// 같은 일을 하는 스크립트가 `scripts/uninstall.command` 에 있다. 앱을 이미
/// 휴지통에 넣어버려 이 버튼을 누를 수 없는 사람을 위한 것이다.
/// **한쪽 목록을 고치면 다른 쪽도 같이 고쳐야 한다.**
enum Uninstaller {

    /// 지운 것과 못 지운 것. 실패해도 나머지는 계속 지운다 — 하나가 막혔다고
    /// 멈추면 어중간하게 남은 상태가 되고, 그게 제일 곤란하다.
    struct Report {
        var removed: [String] = []
        var failed: [String] = []
        var isClean: Bool { failed.isEmpty }
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? Keychain.service
    }

    // MARK: 데이터

    /// 앱 번들을 뺀 전부를 지운다. 반환된 [Report] 로 결과를 사용자에게 보여준다.
    @MainActor
    static func removeUserData() -> Report {
        var report = Report()

        // 잠금 해제 루프부터 멈춘다. 지우는 도중에 카메라가 도는 일은 없어야 한다.
        Settings.shared.faceUnlockEnabled = false

        // 로그인 항목은 가장 먼저 푼다. 앱을 지운 뒤에는 해제할 수단이 없어
        // "없는 앱을 실행하려 했습니다" 알림만 남는다.
        if SMAppService.mainApp.status == .enabled {
            let label = T("로그인 시 자동 실행 등록", "Launch-at-login registration")
            do {
                try SMAppService.mainApp.unregister()
                report.removed.append(label)
            } catch {
                report.failed.append("\(label) — \(error.localizedDescription)")
            }
        }

        // 등록된 얼굴과 비밀번호. 파일과 Keychain 양쪽을 건드리므로 전용 API 를
        // 먼저 부르고(메모리 상태까지 맞춰진다), 그 다음 남은 흔적을 지운다.
        FaceStore.shared.deleteAll()
        Vault.deletePassword()
        EnclaveCrypto.destroyKeys()
        if Keychain.deleteAll() {
            report.removed.append(T("Keychain 항목(봉인 키, 저장된 비밀번호)",
                                    "Keychain items (sealing key, saved password)"))
        } else {
            report.failed.append(T("Keychain 항목", "Keychain items"))
        }

        // 파일
        let fm = FileManager.default
        for location in dataLocations() {
            guard fm.fileExists(atPath: location.url.path) else { continue }
            do {
                try fm.removeItem(at: location.url)
                report.removed.append(location.label)
            } catch {
                report.failed.append("\(location.label) — \(error.localizedDescription)")
            }
        }

        // 설정값. 파일을 지워도 cfprefsd 가 메모리에 들고 있다가 종료할 때 다시
        // 쓸 수 있어서, 파일 삭제와 별개로 도메인 자체를 비운다. 그래도 빈
        // plist 가 하나 남는 경우가 있는데, 값이 없으므로 해로울 건 없다.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)

        // 카메라·손쉬운 사용 허용 기록. 시스템이 거부할 수 있어 결과를 따지지
        // 않는다. 실패하면 시스템 설정 목록에 항목만 남는데, 앱이 사라지면
        // 아무 동작도 하지 않는 죽은 줄이다.
        resetPrivacyApprovals()

        return report
    }

    /// 이 앱이 디스크에 만드는 것 전부.
    ///
    /// `scripts/uninstall.command` 의 목록과 **같아야 한다.**
    static func dataLocations() -> [(label: String, url: URL)] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        return [
            (T("등록한 얼굴과 내려받은 얼굴 인식 모델",
               "Enrolled faces and the downloaded recognition model"),
             library.appendingPathComponent("Application Support/FaceUnlock", isDirectory: true)),
            (T("설정값", "Preferences"),
             library.appendingPathComponent("Preferences/\(bundleID).plist")),
            (T("캐시", "Caches"),
             library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true)),
            (T("저장된 창 상태", "Saved window state"),
             library.appendingPathComponent("Saved Application State/\(bundleID).savedState",
                                            isDirectory: true)),
        ]
    }

    /// TCC(개인정보 보호) 허용 기록을 지운다. 되면 좋고 안 돼도 그만이다.
    private static func resetPrivacyApprovals() {
        for service in ["Camera", "Accessibility"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            // 반드시 번들 ID 를 함께 넘긴다. 빼면 그 항목의 **모든 앱** 허용이
            // 초기화된다 — 남의 앱 권한까지 날리는 짓이다.
            task.arguments = ["reset", service, bundleID]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: 앱 자신

    /// 앱 번들을 휴지통으로 보내고 종료한다.
    ///
    /// 실행 중인 자기 자신을 옮겨도 문제없다. 이미 열린 실행 파일은 경로가
    /// 아니라 inode 로 붙어 있어서, 번들이 휴지통으로 가도 지금 돌아가는
    /// 프로세스는 멀쩡하다. 그래서 옮긴 **뒤에** 종료한다.
    ///
    /// 지우지 않고 휴지통에 넣는 이유는 되돌릴 여지를 남기기 위해서다. 실수로
    /// 눌렀다면 휴지통에서 꺼내면 된다(데이터는 이미 지워졌으므로 다시 등록해야
    /// 한다).
    static func trashAppAndQuit(onFailure: @escaping (String) -> Void) {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    onFailure(error.localizedDescription)
                    return
                }
                Log.app.info("완전 삭제 완료 — 앱을 휴지통으로 옮기고 종료합니다")
                NSApp.terminate(nil)
            }
        }
    }
}
