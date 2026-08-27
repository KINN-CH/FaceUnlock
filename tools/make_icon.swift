// 앱 아이콘을 코드로 그린다.
//
// 디자인 도구 없이 저장소만으로 아이콘을 재현할 수 있도록 벡터로 그려서
// 각 크기별 PNG 로 내보낸다 (작은 크기를 축소 리샘플링하면 흐려진다).
// 사용: swift tools/make_icon.swift <iconset출력폴더>
// 이후 iconutil -c icns 로 .icns 를 만든다 (Makefile 의 `make icon`).
//
// 그림: 남색 그라데이션 둥근 사각형 + Face ID 브래킷 + 윙크하는 얼굴.
// 윙크는 장식이 아니라 이 앱의 깜빡임 liveness 를 그대로 그린 것이다.

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("사용법: swift tools/make_icon.swift <iconset폴더>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    let c = s / 2

    // macOS 아이콘 그리드: 캔버스의 약 80% 를 차지하는 둥근 사각형, 주변은 투명 여백.
    let inset = 0.098 * s
    let plate = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let platePath = NSBezierPath(roundedRect: plate,
                                 xRadius: 0.225 * plate.width, yRadius: 0.225 * plate.width)
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.51, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.38, alpha: 1)])!
        .draw(in: platePath, angle: -90)

    NSColor.white.setStroke()
    NSColor.white.setFill()

    // Face ID 브래킷 — 네 모서리만 그린다.
    let b = 0.46 * s                 // 브래킷 정사각형 한 변
    let r = 0.105 * s                // 모서리 곡률 반경
    let arm = 0.045 * s              // 곡선 끝에서 더 뻗는 직선 팔
    let bx0 = c - b / 2, bx1 = c + b / 2
    let by0 = c - b / 2 + 0.01 * s, by1 = c + b / 2 + 0.01 * s
    let corners: [(cx: CGFloat, cy: CGFloat, start: CGFloat)] = [
        (bx0 + r, by1 - r,  90),   // 좌상: 90°→180° 호
        (bx1 - r, by1 - r,   0),   // 우상: 0°→90°
        (bx0 + r, by0 + r, 180),   // 좌하: 180°→270°
        (bx1 - r, by0 + r, 270),   // 우하: 270°→360°
    ]
    for corner in corners {
        let path = NSBezierPath()
        path.lineWidth = 0.055 * s
        path.lineCapStyle = .round
        path.appendArc(withCenter: NSPoint(x: corner.cx, y: corner.cy), radius: r,
                       startAngle: corner.start, endAngle: corner.start + 90)
        path.stroke()
        // 호 양 끝에서 변 방향으로 짧은 팔을 잇는다.
        for angle in [corner.start, corner.start + 90] {
            let rad = angle * .pi / 180
            let end = NSPoint(x: corner.cx + r * cos(rad), y: corner.cy + r * sin(rad))
            // 끝점에서 사각형 변과 평행한 방향 (호의 접선 방향)
            let tangent: NSPoint
            switch (Int(angle) % 360 + 360) % 360 {
            case 0:   tangent = NSPoint(x: 0, y: corner.cy < c ? 1 : -1)
            case 90:  tangent = NSPoint(x: corner.cx < c ? 1 : -1, y: 0)
            case 180: tangent = NSPoint(x: 0, y: corner.cy < c ? 1 : -1)
            default:  tangent = NSPoint(x: corner.cx < c ? 1 : -1, y: 0)
            }
            let armPath = NSBezierPath()
            armPath.lineWidth = 0.055 * s
            armPath.lineCapStyle = .round
            armPath.move(to: end)
            armPath.line(to: NSPoint(x: end.x + tangent.x * arm, y: end.y + tangent.y * arm))
            armPath.stroke()
        }
    }

    // 눈 — 왼쪽은 뜨고, 오른쪽은 감았다 (깜빡임 챌린지).
    let eyeY = c + 0.075 * s
    let eyeDX = 0.085 * s
    let eyeR = 0.031 * s
    NSBezierPath(ovalIn: NSRect(x: c - eyeDX - eyeR, y: eyeY - eyeR,
                                width: eyeR * 2, height: eyeR * 2)).fill()
    let wink = NSBezierPath()
    wink.lineWidth = 0.042 * s
    wink.lineCapStyle = .round
    wink.move(to: NSPoint(x: c + eyeDX - 0.042 * s, y: eyeY))
    wink.line(to: NSPoint(x: c + eyeDX + 0.042 * s, y: eyeY))
    wink.stroke()

    // 입 — 아래로 볼록한 호 (미소).
    let smile = NSBezierPath()
    smile.lineWidth = 0.048 * s
    smile.lineCapStyle = .round
    smile.appendArc(withCenter: NSPoint(x: c, y: c - 0.015 * s), radius: 0.105 * s,
                    startAngle: 215, endAngle: 325)
    smile.stroke()

    return rep
}

// iconset 규격: 이름과 실제 픽셀 수.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for size in sizes {
    let rep = render(size.px)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(size.name).png"))
}
print("아이콘 \(sizes.count)장 생성됨 → \(outDir.path)")
