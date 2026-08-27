// DMG 배경 이미지를 코드로 그린다.
//
// 디자인 도구 없이 저장소만으로 재현할 수 있도록 벡터로 그린다.
// 사용: swift tools/make_dmg_background.swift <출력.png>
// 창 논리 크기 640×570pt, 레티나용 2x 픽셀 + 144dpi 메타데이터.
//
// 문구는 한국어·영어 병기. 공증이 없어 Gatekeeper 가 설치 도우미를 막는데,
// **같은 절차를 두 번 반복해야** 실제로 열린다. 여기서 막히면 설치가 통째로
// 시작되지 않으므로 하단에 눈에 띄는 상자로 크게 적는다.
//
// 좌표 배치는 scripts/dmg_settings.py 의 아이콘 위치와 맞춰져 있다:
//   FaceUnlock.app (170, 175) · Applications (470, 175)
//   설치 도우미 (170, 336) · 먼저 읽어주세요 (470, 336)
//   (Finder 좌표: 좌상단 원점, 아이콘 중심)
//
// Finder 의 이름표는 아이콘 중심에서 아래로 ~47pt 까지 내려오고, 이름이 길면
// 두 줄로 접힌다('설치 도우미 (Install Helper).command' 가 그렇다).
// 그만큼 비워두지 않으면 이름표가 하단 경고 상자 위에 겹쳐 찍힌다.

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("사용법: swift tools/make_dmg_background.swift <출력.png>\n".data(using: .utf8)!)
    exit(1)
}

let W: CGFloat = 640, H: CGFloat = 570
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 144dpi → Finder 가 640×570pt 로 표시

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Finder 좌표(좌상단 원점) → AppKit 좌표(좌하단 원점) 변환용
func Y(_ finderY: CGFloat) -> CGFloat { H - finderY }

// 바탕 — 밝은 중성색 (DMG 관례상 라이트 고정)
NSColor(calibratedRed: 0.965, green: 0.968, blue: 0.976, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let navy  = NSColor(calibratedRed: 0.24, green: 0.35, blue: 0.78, alpha: 1)
let ink   = NSColor(calibratedWhite: 0.22, alpha: 1)
let gray  = NSColor(calibratedWhite: 0.38, alpha: 1)
let faint = NSColor(calibratedWhite: 0.52, alpha: 1)

/// 가운데 정렬로 한 줄 그린다. `maxWidth` 를 넘으면 경고를 띄운다 —
/// 한국어와 영어는 같은 문장이라도 폭이 배로 차이 나서, 문구를 고칠 때
/// 한쪽이 조용히 창 밖으로 삐져나가기 쉽다.
@discardableResult
func drawText(_ text: String, center: NSPoint, size: CGFloat,
              weight: NSFont.Weight, color: NSColor,
              maxWidth: CGFloat = W - 40) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.size()
    if bounds.width > maxWidth {
        FileHandle.standardError.write(
            "경고: 문구가 \(Int(bounds.width))pt 로 한계 \(Int(maxWidth))pt 를 넘습니다 — \"\(text)\"\n"
                .data(using: .utf8)!)
    }
    str.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
    return bounds.width
}

// 제목
drawText("FaceUnlock 설치 · Install", center: NSPoint(x: W / 2, y: Y(44)), size: 20,
         weight: .semibold, color: ink)

// ① 드래그 — 한국어 위, 영어 아래
drawText("① 앱을 Applications 폴더로 드래그", center: NSPoint(x: W / 2, y: Y(98)),
         size: 14, weight: .medium, color: gray)
drawText("Drag the app into the Applications folder", center: NSPoint(x: W / 2, y: Y(118)),
         size: 11.5, weight: .regular, color: faint)

// 드래그 화살표 — 앱(170)과 Applications(470) 아이콘 사이
let arrowY = Y(175)
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 250, y: arrowY))
arrow.line(to: NSPoint(x: 382, y: arrowY))
navy.setStroke()
arrow.stroke()
let head = NSBezierPath()   // 화살촉
head.move(to: NSPoint(x: 372, y: arrowY + 11))
head.line(to: NSPoint(x: 390, y: arrowY))
head.line(to: NSPoint(x: 372, y: arrowY - 11))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// ② 설치 도우미 — 아이콘(170·470, 336) 위쪽
drawText("② '설치 도우미'를 우클릭 → 열기 — 나머지는 자동입니다",
         center: NSPoint(x: W / 2, y: Y(256)), size: 14, weight: .medium, color: gray)
drawText("Right-click 'Install Helper' → Open — the rest is automatic",
         center: NSPoint(x: W / 2, y: Y(276)), size: 11.5, weight: .regular, color: faint)

// 하단 상자 — Gatekeeper 차단 안내.
//
// 여기서 포기하는 사람이 제일 많다. 공증이 없어 macOS 가 설치 도우미를 막는데,
// '그래도 열기' 를 한 번 눌러서는 열리지 않고 **같은 절차를 두 번** 밟아야 한다.
// 모르면 "안 열리는 앱" 으로 보이므로 회색 각주가 아니라 상자로 강조한다.
let boxRect = NSRect(x: 36, y: Y(552), width: W - 72, height: 112)
NSColor(calibratedRed: 1.0, green: 0.965, blue: 0.90, alpha: 1).setFill()
let box = NSBezierPath(roundedRect: boxRect, xRadius: 10, yRadius: 10)
box.fill()
NSColor(calibratedRed: 0.87, green: 0.72, blue: 0.42, alpha: 1).setStroke()
box.lineWidth = 1
box.stroke()

let warn = NSColor(calibratedRed: 0.45, green: 0.31, blue: 0.05, alpha: 1)
let inner = boxRect.width - 28
drawText("⚠️  아래 과정을 두 번 반복해야 전체 설치가 완료됩니다", center: NSPoint(x: W / 2, y: Y(462)),
         size: 13.5, weight: .semibold, color: warn, maxWidth: inner)
drawText("설치 도우미 우클릭 → 열기 → 시스템 설정 → 개인정보 보호 및 보안 → ‘그래도 열기’ → 암호 입력",
         center: NSPoint(x: W / 2, y: Y(485)), size: 10.5, weight: .regular, color: gray, maxWidth: inner)
drawText("Repeat the steps below twice to finish installing", center: NSPoint(x: W / 2, y: Y(513)),
         size: 12, weight: .semibold, color: warn, maxWidth: inner)
drawText("Right-click Install Helper → Open → System Settings → Privacy & Security → ‘Open Anyway’ → password",
         center: NSPoint(x: W / 2, y: Y(534)), size: 10.5, weight: .regular, color: faint, maxWidth: inner)

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try png.write(to: out)
print("배경 이미지 생성됨 → \(out.path)")
