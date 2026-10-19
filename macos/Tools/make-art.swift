// Draws the macOS app icon and the DMG window background.
// Run from the repository root:  xcrun swift macos/Tools/make-art.swift
// Writes macos/Resources/AppIcon.icns and macos/Resources/dmg-background.tiff (1x + 2x), which are committed,
// so normal builds and CI don't need to run this.
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("macos/Resources")
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pear-art-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
for name in ["PretendardJP-Regular", "PretendardJP-Medium"] {
    CTFontManagerRegisterFontsForURL(root.appendingPathComponent("assets/fonts/\(name).ttf") as CFURL, .process, nil)
}

func hex(_ s: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
}

/// Renders `draw` (in a top-left origin space of `size` points) into a PNG of `size * scale` pixels.
func render(_ size: CGSize, scale: CGFloat, to url: URL, _ draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext
    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)   // top-left origin, like the C# renderer
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// ---- app icon -------------------------------------------------------------------------------------

/// The Windows icon (assets/app.ico): a white note on a #ff4e45 rounded square, redrawn on the macOS icon grid
/// (824pt body in a 1024pt canvas, soft shadow, gentle gradient).
func drawIcon(in canvas: CGFloat) {
    let u = canvas / 1024
    let body = CGRect(x: 100 * u, y: 92 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 26 * u
    shadow.shadowOffset = NSSize(width: 0, height: -12 * u)
    shadow.set()
    hex("#ff4e45").setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [hex("#ff7466"), hex("#ff4e45"), hex("#ec3a35")], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: 90)
    // a faint sheen on the upper half
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.5), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    hex("#000000", 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1 * u, dy: 1 * u), xRadius: 184 * u, yRadius: 184 * u)
    rim.lineWidth = 2 * u; rim.stroke()

    // the note, in the 256-unit space of app.ico, placed on the 824pt body
    let s = 824 * u / 256
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * s, y: body.minY + y * s) }
    let note = NSBezierPath()
    let head = NSBezierPath(ovalIn: CGRect(x: -38 * s, y: -29 * s, width: 76 * s, height: 58 * s))
    var turn = AffineTransform(); turn.rotate(byDegrees: -22); head.transform(using: turn)
    head.transform(using: AffineTransform(translationByX: p(92, 172).x, byY: p(92, 172).y))
    note.append(head)
    note.append(NSBezierPath(roundedRect: CGRect(origin: p(117, 50), size: CGSize(width: 15 * s, height: 124 * s)), xRadius: 2 * s, yRadius: 2 * s))
    let flag = NSBezierPath()
    flag.move(to: p(117, 50)); flag.line(to: p(192, 68)); flag.line(to: p(192, 92)); flag.line(to: p(132, 76)); flag.close()
    note.append(flag)
    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(srgbRed: 0.45, green: 0.05, blue: 0.04, alpha: 0.35)
    glyphShadow.shadowBlurRadius = 18 * u
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * u)
    glyphShadow.set()
    NSColor.white.setFill(); note.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        let pixels = CGFloat(points * scale)
        try render(CGSize(width: pixels, height: pixels), scale: 1, to: iconset.appendingPathComponent(name)) { drawIcon(in: pixels) }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

// ---- DMG background (640 x 400 pt; icons sit at (160, 200) and (480, 200), see macos/dmg-settings.py) ---------

func text(_ string: String, size: CGFloat, medium: Bool = false, color: NSColor, centerX: CGFloat, top: CGFloat) {
    let font = NSFont(name: medium ? "PretendardJP-Medium" : "PretendardJP-Regular", size: size) ?? .systemFont(ofSize: size)
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let width = attributed.size().width
    attributed.draw(at: CGPoint(x: centerX - width / 2, y: top))
}

func drawBackground() {
    let size = CGSize(width: 640, height: 400)
    NSGradient(colors: [hex("#232326"), hex("#19191b")])!.draw(in: CGRect(origin: .zero, size: size), angle: -90)
    // a soft coral glow behind the app
    NSGradient(colors: [hex("#ff4e45", 0.20), hex("#ff4e45", 0)])!
        .draw(fromCenter: CGPoint(x: 160, y: 200), radius: 0, toCenter: CGPoint(x: 160, y: 200), radius: 150, options: [])

    // arrow from the app to Applications
    let arrow = NSBezierPath()
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.setLineDash([2, 12], count: 2, phase: 0)
    arrow.move(to: CGPoint(x: 262, y: 200)); arrow.line(to: CGPoint(x: 362, y: 200))
    hex("#ff9294").setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.lineWidth = 5; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: CGPoint(x: 362, y: 186)); head.line(to: CGPoint(x: 378, y: 200)); head.line(to: CGPoint(x: 362, y: 214))
    head.stroke()

    text("처음 실행할 때 열리지 않으면 시스템 설정 → 개인정보 보호 및 보안에서 '그래도 열기'를 눌러요",
         size: 11.5, color: hex("#8a8087"), centerX: 320, top: 340)
}

let bg1 = work.appendingPathComponent("bg.png"), bg2 = work.appendingPathComponent("bg@2x.png")
try render(CGSize(width: 640, height: 400), scale: 1, to: bg1, drawBackground)
try render(CGSize(width: 640, height: 400), scale: 2, to: bg2, drawBackground)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", bg1.path, bg2.path, "-out", resources.appendingPathComponent("dmg-background.tiff").path]
try tiffutil.run(); tiffutil.waitUntilExit()
precondition(tiffutil.terminationStatus == 0, "tiffutil failed")

try? FileManager.default.removeItem(at: work)
print("Wrote \(resources.path)/AppIcon.icns and dmg-background.tiff")
