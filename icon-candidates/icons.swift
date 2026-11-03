import AppKit
import CoreGraphics

// iVNC 아이콘 후보 그리기 (1024x1024). 사용: swift icons.swift <출력 폴더>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 위가 0 인 좌표로
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func gradient(_ ctx: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors.map { rgb($0) } as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

func shadow(_ ctx: CGContext, _ blur: CGFloat, _ y: CGFloat, _ a: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: -y), blur: blur, color: rgb(0x000000, a))
}

/// 마우스 포인터 (끝이 (0,0), 높이 1 기준)
func cursorPath(at p: CGPoint, size h: CGFloat) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.78), (0.19, 0.61), (0.31, 0.90), (0.44, 0.85), (0.32, 0.56), (0.56, 0.56)]
    let path = CGMutablePath()
    path.addLines(between: pts.map { CGPoint(x: p.x + $0.0 * h, y: p.y + $0.1 * h) })
    path.closeSubpath()
    return path
}

func bolt(at c: CGPoint, size h: CGFloat) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [(0.10, -0.5), (-0.28, 0.06), (-0.02, 0.06), (-0.12, 0.5), (0.28, -0.08), (0.02, -0.08)]
    let path = CGMutablePath()
    path.addLines(between: pts.map { CGPoint(x: c.x + $0.0 * h, y: c.y + $0.1 * h) })
    path.closeSubpath()
    return path
}

func save(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

// A: 번개 화면
let a = canvas { ctx in
    gradient(ctx, [0x3B82F6, 0x4F46E5, 0x312E81], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    let screen = CGRect(x: 212, y: 262, width: 600, height: 420)
    ctx.saveGState(); shadow(ctx, 40, 18, 0.35)
    ctx.addPath(rr(screen, 56)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(rr(screen.insetBy(dx: 30, dy: 30), 32))
    ctx.saveGState(); ctx.clip()
    gradient(ctx, [0x1E1B4B, 0x312E81], from: CGPoint(x: 0, y: screen.minY), to: CGPoint(x: 0, y: screen.maxY))
    ctx.restoreGState()
    ctx.addPath(rr(CGRect(x: 462, y: 682, width: 100, height: 70), 8)); ctx.setFillColor(rgb(0xFFFFFF, 0.9)); ctx.fillPath()
    ctx.addPath(rr(CGRect(x: 372, y: 740, width: 280, height: 36), 18)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.saveGState(); shadow(ctx, 30, 0, 0.6)
    ctx.addPath(bolt(at: CGPoint(x: 512, y: 472), size: 300)); ctx.setFillColor(rgb(0xFDE047)); ctx.fillPath()
    ctx.restoreGState()
}
save(a, "icon-A")

// B: 원격 창 + 포인터
let b = canvas { ctx in
    gradient(ctx, [0x22D3EE, 0x2563EB], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    let win = CGRect(x: 150, y: 220, width: 660, height: 500)
    ctx.saveGState(); shadow(ctx, 50, 24, 0.3)
    ctx.addPath(rr(win, 60)); ctx.setFillColor(rgb(0xFFFFFF, 0.96)); ctx.fillPath()
    ctx.restoreGState()
    // 제목 막대와 신호등
    ctx.addPath(rr(CGRect(x: win.minX, y: win.minY, width: win.width, height: 110), 60)); ctx.setFillColor(rgb(0xE2E8F0)); ctx.fillPath()
    ctx.setFillColor(rgb(0xE2E8F0)); ctx.fill(CGRect(x: win.minX, y: win.minY + 60, width: win.width, height: 50))
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(rgb(UInt32(c))); ctx.fillEllipse(in: CGRect(x: win.minX + 50 + CGFloat(i) * 62, y: win.minY + 34, width: 42, height: 42))
    }
    // 창 안 내용 줄
    for (i, w) in [420.0, 330.0, 380.0].enumerated() {
        ctx.addPath(rr(CGRect(x: win.minX + 60, y: win.minY + 170 + CGFloat(i) * 80, width: w, height: 36), 18))
        ctx.setFillColor(rgb(0xCBD5E1)); ctx.fillPath()
    }
    // 큰 포인터
    let cur = cursorPath(at: CGPoint(x: 560, y: 470), size: 400)
    ctx.saveGState(); shadow(ctx, 30, 14, 0.35)
    ctx.addPath(cur); ctx.setFillColor(rgb(0x0F172A)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(cur); ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(22); ctx.setLineJoin(.round); ctx.strokePath()
}
save(b, "icon-B")

// C: 포인터 질주
let c = canvas { ctx in
    gradient(ctx, [0xF97316, 0xEC4899, 0x8B5CF6], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    // 속도선
    ctx.setLineCap(.round)
    for (i, len) in [260.0, 340.0, 220.0].enumerated() {
        let y = 520 + CGFloat(i) * 90
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55 - Double(i) * 0.12)); ctx.setLineWidth(34)
        ctx.move(to: CGPoint(x: 440 - len, y: y)); ctx.addLine(to: CGPoint(x: 400, y: y)); ctx.strokePath()
    }
    let cur = cursorPath(at: CGPoint(x: 400, y: 210), size: 620)
    ctx.saveGState(); shadow(ctx, 40, 20, 0.35)
    ctx.addPath(cur); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(cur); ctx.setStrokeColor(rgb(0x1F2937, 0.15)); ctx.setLineWidth(8); ctx.setLineJoin(.round); ctx.strokePath()
}
save(c, "icon-C")

// D: 폰과 맥
let d = canvas { ctx in
    gradient(ctx, [0x0F172A, 0x1E3A8A], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    // 맥 화면
    let mac = CGRect(x: 140, y: 230, width: 600, height: 400)
    ctx.addPath(rr(mac, 44)); ctx.setFillColor(rgb(0xE2E8F0)); ctx.fillPath()
    ctx.addPath(rr(mac.insetBy(dx: 22, dy: 22), 26))
    ctx.saveGState(); ctx.clip()
    gradient(ctx, [0x38BDF8, 0x6366F1], from: CGPoint(x: mac.minX, y: mac.minY), to: CGPoint(x: mac.maxX, y: mac.maxY))
    ctx.restoreGState()
    ctx.addPath(rr(CGRect(x: 395, y: 630, width: 90, height: 60), 8)); ctx.setFillColor(rgb(0xCBD5E1)); ctx.fillPath()
    ctx.addPath(rr(CGRect(x: 320, y: 680, width: 240, height: 30), 15)); ctx.setFillColor(rgb(0xE2E8F0)); ctx.fillPath()
    // 아이폰 (맥 화면이 비친다)
    let phone = CGRect(x: 600, y: 400, width: 260, height: 470)
    ctx.saveGState(); shadow(ctx, 40, 16, 0.5)
    ctx.addPath(rr(phone, 60)); ctx.setFillColor(rgb(0x0B1120)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(rr(phone.insetBy(dx: 16, dy: 16), 46))
    ctx.saveGState(); ctx.clip()
    gradient(ctx, [0x38BDF8, 0x6366F1], from: CGPoint(x: phone.minX, y: phone.minY), to: CGPoint(x: phone.maxX, y: phone.maxY))
    ctx.restoreGState()
    ctx.addPath(rr(CGRect(x: phone.midX - 45, y: phone.minY + 30, width: 90, height: 26), 13)); ctx.setFillColor(rgb(0x0B1120)); ctx.fillPath()
    ctx.addPath(cursorPath(at: CGPoint(x: phone.midX - 30, y: phone.midY - 40), size: 130)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
}
save(d, "icon-D")

// 모아 보기: 아이콘 모양(둥근 사각형)으로 잘라 한 줄에
let names = ["A", "B", "C", "D"]
let imgs = [a, b, c, d]
let cell: CGFloat = 300, gap: CGFloat = 60, label: CGFloat = 70
let W = Int(gap + CGFloat(imgs.count) * (cell + gap)), H = Int(gap + cell + label + gap / 2)
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(rgb(0xF1F5F9)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
for (i, img) in imgs.enumerated() {
    let r = CGRect(x: gap + CGFloat(i) * (cell + gap), y: label + gap / 2, width: cell, height: cell)
    sheet.saveGState()
    sheet.addPath(rr(r, cell * 0.225)); sheet.clip()
    sheet.draw(img, in: r)
    sheet.restoreGState()
    let s = NSAttributedString(string: names[i], attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.darkGray])
    s.draw(at: CGPoint(x: r.midX - s.size().width / 2, y: 18))
}
save(sheet.makeImage()!, "icons-sheet")
print("저장:", out)
