// DMG 배경 이미지를 코드로 그린다.
//
// 디자인 도구 없이 저장소만으로 재현할 수 있도록 벡터로 그린다.
// 사용: swift tools/make_dmg_background.swift <출력.png>
// 창 논리 크기 640×460pt, 레티나용 2x 픽셀 + 144dpi 메타데이터.
//
// 문구는 한국어·영어 병기. 공증이 없어 첫 실행이 Gatekeeper 에 차단되는
// 실제 절차('그래도 열기' → 암호 입력 → 다시 열기)를 하단에 그대로 적는다.
//
// 좌표 배치는 scripts/dmg_settings.py 의 아이콘 위치와 맞춰져 있다:
//   FaceUnlock.app (170, 185) · Applications (470, 185)
//   설치 도우미 (320, 345) · 먼저 읽어주세요 (560, 345)
//   (Finder 좌표: 좌상단 원점, 아이콘 중심)

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("사용법: swift tools/make_dmg_background.swift <출력.png>\n".data(using: .utf8)!)
    exit(1)
}

let W: CGFloat = 640, H: CGFloat = 460
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 144dpi → Finder 가 640×460pt 로 표시

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

func drawText(_ text: String, center: NSPoint, size: CGFloat,
              weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.size()
    str.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
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
let arrowY = Y(185)
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

// ② 설치 도우미 — 아이콘(320, 345) 위쪽
drawText("② '설치 도우미'를 우클릭 → 열기 — 나머지는 자동입니다",
         center: NSPoint(x: W / 2, y: Y(266)), size: 14, weight: .medium, color: gray)
drawText("Right-click 'Install Helper' → Open — the rest is automatic",
         center: NSPoint(x: W / 2, y: Y(286)), size: 11.5, weight: .regular, color: faint)

// 하단 — Gatekeeper 차단 절차 안내 (실제 겪는 순서 그대로)
drawText("처음 실행은 macOS가 차단합니다: 시스템 설정 → 개인정보 보호 및 보안 → '그래도 열기' → 암호 입력 → 다시 열기",
         center: NSPoint(x: W / 2, y: Y(424)), size: 10.5, weight: .regular, color: faint)
drawText("First run is blocked by macOS: System Settings → Privacy & Security → 'Open Anyway' → enter password → open again",
         center: NSPoint(x: W / 2, y: Y(441)), size: 10.5, weight: .regular, color: faint)

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try png.write(to: out)
print("배경 이미지 생성됨 → \(out.path)")
