// 저장소 상단 배너 · GitHub 소셜 프리뷰 이미지 생성기
//
//   swift tools/make_banner.swift docs
//
// 아이콘(Resources/AppIcon.icns)을 왼쪽에 놓고 오른쪽에 이름과 한 줄 설명을 적는다.
// 1280×640 은 GitHub 소셜 프리뷰 권장 크기라 저장소 설정에 그대로 올릴 수 있다.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_banner.swift <출력 디렉토리>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W: CGFloat = 1280, H: CGFloat = 640

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 바탕 — 아이콘의 남색을 아주 어둡게 깐다. 라이트/다크 어느 쪽에 놓여도 튀지 않는 값.
let ink = NSColor(calibratedRed: 0.043, green: 0.055, blue: 0.086, alpha: 1)
ink.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// 아이콘 뒤 은은한 광. 배너가 밋밋해지는 걸 막는 유일한 장식이라 이것 하나만 쓴다.
ctx.saveGState()
let glow = NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.51, blue: 0.98, alpha: 0.28),
                               NSColor(calibratedRed: 0.36, green: 0.51, blue: 0.98, alpha: 0)])!
glow.draw(fromCenter: NSPoint(x: 348, y: H / 2), radius: 0,
          toCenter: NSPoint(x: 348, y: H / 2), radius: 300, options: [])
ctx.restoreGState()

// 아이콘
let iconURL = URL(fileURLWithPath: "Resources/AppIcon.icns")
if let icon = NSImage(contentsOf: iconURL) {
    let side: CGFloat = 268
    icon.draw(in: NSRect(x: 348 - side / 2, y: H / 2 - side / 2, width: side, height: side),
              from: .zero, operation: .sourceOver, fraction: 1)
}

// 오른쪽 텍스트 블록
func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ]
    // y 는 위에서부터 재는 게 편해서 뒤집어 준다
    let str = NSAttributedString(string: text, attributes: attrs)
    str.draw(at: NSPoint(x: x, y: H - y - str.size().height))
}

let TX: CGFloat = 560
draw("FaceUnlock", x: TX, y: 186, size: 92, weight: .bold, color: .white, tracking: -1.5)
draw("Macbook을 Face ID로 열수있는 앱", x: TX, y: 300, size: 32, weight: .medium,
     color: NSColor(calibratedWhite: 0.80, alpha: 1))
draw("Face unlock for the Mac lock screen", x: TX, y: 350, size: 27, weight: .regular,
     color: NSColor(calibratedRed: 0.52, green: 0.64, blue: 0.98, alpha: 1))

// 밑줄 대신 얇은 구분선 — 사양 한 줄을 본문에서 떼어 놓는다
NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
NSRect(x: TX, y: H - 430, width: 300, height: 1).fill()

draw("macOS 14+  ·  Apple Silicon  ·  MIT", x: TX, y: 448, size: 21, weight: .medium,
     color: NSColor(calibratedWhite: 0.55, alpha: 1), tracking: 0.6)

NSGraphicsContext.restoreGraphicsState()

let out = outDir.appendingPathComponent("banner.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("==> \(out.path)  \(Int(W))×\(Int(H))")
