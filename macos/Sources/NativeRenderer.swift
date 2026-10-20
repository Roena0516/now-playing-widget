import AppKit
import CoreText

/// Values and geometry ported from Theme.cs, CardRenderer.cs and LyricsView.cs.
enum NativeTheme {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
    static let surface = color(0x242427), surface2 = color(0x2e2e33), border = color(0x33333a)
    static let ink = color(0xf2edef), inkSoft = color(0xcfc6ca), muted = color(0xb3a8ad)
    static let dim = color(0x8a8087), faint = color(0x6f676c)
    static let accent = color(0xff9294), accentSoft = color(0xf2b3bf), accentInk = color(0x3a1e1e)
    static func registerFonts() {
        for name in ["PretendardJP-Regular", "PretendardJP-Medium"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
    static func font(_ size: CGFloat, medium: Bool = false) -> NSFont {
        NSFont(name: medium ? "PretendardJP-Medium" : "PretendardJP-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
    }
    static func lineHeight(_ font: NSFont) -> CGFloat { font.ascender - font.descender + font.leading }
    static func width(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    static func mix(_ a: NSColor, _ b: NSColor, _ fraction: CGFloat) -> NSColor {
        let t = min(1, max(0, fraction))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }
    static func surface(in rect: CGRect, opacity: Double) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        surface.withAlphaComponent(opacity).setFill(); path.fill()
        border.withAlphaComponent(min(1, opacity + 20 / 255)).setStroke(); path.lineWidth = 1; path.stroke()
    }
    static func text(_ text: String, font: NSFont, color: NSColor, rect: CGRect, alignment: NSTextAlignment = .left, wrap: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    /// The menu bar icon: a music note as a template image, so macOS tints it like the other menu bar icons
    /// (light/dark menu bar, highlighted when the menu is open) instead of a colored square standing out.
    static func trayIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: 2.6, y: 1.8, width: 6.6, height: 5.0)).fill()   // note head
            CGRect(x: 7.6, y: 4.2, width: 1.7, height: 12.0).fill()                         // stem
            let flag = NSBezierPath()
            flag.move(to: CGPoint(x: 7.6, y: 16.2)); flag.line(to: CGPoint(x: 15.0, y: 14.2))
            flag.line(to: CGPoint(x: 15.0, y: 11.3)); flag.line(to: CGPoint(x: 7.6, y: 13.0)); flag.close(); flag.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pear Now Playing"
        return image
    }
}
enum NativeCardKind {
    case nowPlaying, paused, resumed, info
    var label: String {
        switch self { case .nowPlaying, .resumed: return "재생중"; case .paused: return "일시정지됨"; case .info: return "Pear Now Playing" }
    }
}
struct NativeCardLayout {
    let width: CGFloat
    let hasArt: Bool, hasSubtitle: Bool, hasBar: Bool
    let headerH = NativeTheme.lineHeight(NativeTheme.font(12, medium: true))
    let titleH = NativeTheme.lineHeight(NativeTheme.font(17, medium: true))
    let subH = NativeTheme.lineHeight(NativeTheme.font(13))
    var textWidth: CGFloat { max(80, width - 32 - (hasArt ? 74 : 0)) }
    var textHeight: CGFloat { headerH + 4 + titleH + (hasSubtitle ? 1 + subH : 0) + (hasBar ? 12 : 0) }
    var contentHeight: CGFloat { max(hasArt ? 60 : 0, ceil(textHeight)) }
    var height: CGFloat { contentHeight + 32 }
    var textX: CGFloat { 16 + (hasArt ? 74 : 0) }
    var textY: CGFloat { 16 + (contentHeight - textHeight) / 2 }
}
@MainActor enum NativeRenderer {
    static func subtitle(_ song: Song) -> String {
        if !song.artist.isEmpty && !song.album.isEmpty && song.album != song.title { return song.artist + " · " + song.album }
        return song.artist.isEmpty ? song.album : song.artist
    }
    static func cardLayout(_ client: PearClient, kind: NativeCardKind) -> NativeCardLayout {
        NativeCardLayout(width: client.settings.panelWidth, hasArt: kind != .info && client.settings.showAlbumArt, hasSubtitle: kind != .info && !subtitle(client.song).isEmpty, hasBar: kind != .info && client.song.duration > 0)
    }
    static func drawCard(_ client: PearClient, kind: NativeCardKind, marqueeTime: Double, infoText: String? = nil) {
        let layout = cardLayout(client, kind: kind)
        NativeTheme.surface(in: CGRect(x: 0, y: 0, width: layout.width, height: layout.height), opacity: client.settings.opacity)
        if layout.hasArt {
            let rect = CGRect(x: 16, y: 16 + (layout.contentHeight - 60) / 2, width: 60, height: 60)
            let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState(); clip.addClip()
            if let data = client.artwork, let image = NSImage(data: data) {
                let side = min(image.size.width, image.size.height)
                image.draw(in: rect, from: CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else {
                NativeTheme.surface2.setFill(); rect.fill()
                NativeTheme.text("♪", font: NativeTheme.font(25.2, medium: true), color: NativeTheme.dim, rect: CGRect(x: rect.minX, y: rect.midY - 16, width: 60, height: 32), alignment: .center)
            }
            NSGraphicsContext.restoreGraphicsState()
            NativeTheme.border.setStroke(); clip.lineWidth = 1; clip.stroke()
        }
        let x = layout.textX
        var y = layout.textY
        let muted = kind == .paused
        let icon = CGRect(x: x, y: y + (layout.headerH - 8) / 2, width: 8, height: 8)
        (muted ? NativeTheme.muted : NativeTheme.accent).setFill()
        if kind == .paused {
            CGRect(x: icon.minX, y: icon.minY, width: 2.72, height: 8).fill()
            CGRect(x: icon.maxX - 2.72, y: icon.minY, width: 2.72, height: 8).fill()
        } else if kind == .info { NSBezierPath(ovalIn: icon).fill() }
        else {
            let path = NSBezierPath(); path.move(to: icon.origin); path.line(to: CGPoint(x: icon.maxX, y: icon.midY)); path.line(to: CGPoint(x: icon.minX, y: icon.maxY)); path.close(); path.fill()
        }
        NativeTheme.text(kind.label, font: NativeTheme.font(12, medium: true), color: muted ? NativeTheme.muted : NativeTheme.accentSoft, rect: CGRect(x: x + 14, y: y, width: layout.textWidth - 14, height: layout.headerH + 2))
        if layout.hasBar {
            NativeTheme.text(NativeTheme.time(client.elapsed) + " / " + NativeTheme.time(client.song.duration), font: NativeTheme.font(12), color: NativeTheme.dim, rect: CGRect(x: x, y: y, width: layout.textWidth, height: layout.headerH + 2), alignment: .right)
        }
        y += layout.headerH + 4
        let title = kind == .info ? (infoText ?? (client.isConnected ? "재생 중인 곡이 없어요" : client.status)) : (client.song.title.isEmpty ? "알 수 없는 곡" : client.cardTitle)
        drawTitle(title, rect: CGRect(x: x, y: y, width: layout.textWidth, height: layout.titleH + 2), elapsed: marqueeTime)
        y += layout.titleH
        if layout.hasSubtitle {
            y += 1
            NativeTheme.text(subtitle(client.song), font: NativeTheme.font(13), color: NativeTheme.muted, rect: CGRect(x: x, y: y, width: layout.textWidth, height: layout.subH + 2)); y += layout.subH
        }
        if layout.hasBar {
            let bar = CGRect(x: x, y: y + 9, width: layout.textWidth, height: 3)
            NativeTheme.surface2.setFill(); NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            let fraction = min(1, max(0, client.elapsed / client.song.duration))
            if fraction > 0.002 {
                (muted ? NativeTheme.dim : NativeTheme.accent).setFill()
                NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(3, bar.width * fraction), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
    static func drawTitle(_ text: String, rect: CGRect, elapsed: Double) {
        let font = NativeTheme.font(17, medium: true)
        let textWidth = NativeTheme.width(text, font: font)
        guard textWidth > rect.width + 0.5, let context = NSGraphicsContext.current?.cgContext else {
            NativeTheme.text(text, font: font, color: NativeTheme.ink, rect: rect); return
        }
        let cycle = textWidth + 40
        let t = elapsed.truncatingRemainder(dividingBy: 1.8 + cycle / 36)
        let offset = t < 1.8 ? 0 : (t - 1.8) * 36
        context.saveGState(); context.clip(to: rect); context.beginTransparencyLayer(auxiliaryInfo: nil)
        NativeTheme.text(text, font: font, color: NativeTheme.ink, rect: CGRect(x: rect.minX - offset, y: rect.minY, width: textWidth + 4, height: rect.height))
        if offset > 0 {
            NativeTheme.text(text, font: font, color: NativeTheme.ink, rect: CGRect(x: rect.minX - offset + cycle, y: rect.minY, width: textWidth + 4, height: rect.height))
        }
        let left: CGFloat = offset > 0.5 ? 18 / rect.width : 0
        let locations: [CGFloat] = [0, left, 1 - 18 / rect.width, 1]
        let colors = [NSColor.white.withAlphaComponent(left > 0 ? 0 : 1).cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) {
            context.setBlendMode(.destinationIn); context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        context.endTransparencyLayer(); context.restoreGState()
    }
}
struct NativeLyricEntry {
    let text: String
    let gap: Bool
    let lines: [String]
    var y: CGFloat
    let height: CGFloat
}
@MainActor final class NativeLyricsLayout {
    var entries: [NativeLyricEntry] = []
    var leadingPseudo = 0
    /// Lines kept from the previous song above this song's first line (see setLines).
    private(set) var carried = 0
    /// Which kept line was current (the line to start from after a carry-over), or -1.
    private(set) var carriedCurrent = -1
    /// This song's entries end here; the next song's (setNext) follow.
    private(set) var ownEnd = 0
    /// This song's opening "♪" is the last kept line of the previous song's.
    private(set) var mergedGap = false
    private var firstOwn: Int { mergedGap ? carried - 1 : carried }
    var width: CGFloat = 420
    let font = NativeTheme.font(18, medium: true)
    var lineH: CGFloat { NativeTheme.lineHeight(font) }
    var anchor: CGFloat { (lineH * 0.9 + 8).rounded() }
    var viewportHeight: CGFloat { (anchor + lineH * 3 + 16).rounded() }
    var height: CGFloat { 24 + viewportHeight }
    var textWidth: CGFloat { max(120, width - 47) }
    /// `carryFrom`: the entry that was current when the next song's lyrics replace the last song's while the panel
    /// stays open. That line and the one before it stay above the new first line, so the list scrolls on into the
    /// new song instead of restarting at the top (like the Windows version's LyricsView.SetLines). When the last song
    /// was at its end, its remaining lines stay too, so the new song's lines land exactly where setNext showed them.
    func setLines(_ lines: [LyricLine], width: CGFloat, carryFrom current: Int? = nil) {
        var keep: [NativeLyricEntry] = []
        carriedCurrent = -1
        if let current, width == self.width, current >= firstOwn, current < ownEnd {
            let from = max(firstOwn, current - 1)
            keep = Array(entries[from...(ownEnd - 1 - current <= Self.nextShownWithin ? ownEnd - 1 : current)])
            carriedCurrent = current - from
        }
        self.width = width; carried = 0; leadingPseudo = (lines.first?.time ?? 0) > 0 ? 1 : 0
        // the last song ending on "♪" and this one opening with one: a single "♪" line, not two in a row
        mergedGap = keep.last?.gap == true && Self.startsWithGap(lines)
        entries = layout(lines, from: 0, skipFirst: mergedGap); ownEnd = entries.count
        guard !keep.isEmpty, !entries.isEmpty || mergedGap else { carriedCurrent = -1; mergedGap = false; return }
        // the kept lines end one gap above the new first line
        var top: CGFloat = -8
        for i in keep.indices.reversed() { top -= keep[i].height; keep[i].y = top; top -= 8 }
        entries.insert(contentsOf: keep, at: 0); carried = keep.count; ownEnd += carried
    }
    /// The lines below the current one that the viewport shows (the next song's are seen this close to the end).
    static let nextShownWithin = 3
    /// The next song's lines (fetched ahead) below this song's last line, so near the end of a song its successor
    /// is already in view and the change just scrolls on. Empty takes them away.
    func setNext(_ next: [LyricLine]) {
        entries.removeSubrange(ownEnd...)
        guard !next.isEmpty, let last = entries.last else { return }
        entries += layout(next, from: last.y + last.height + 8, skipFirst: last.gap && Self.startsWithGap(next))
    }
    /// The song's first panel line is a "♪" (it opens with music, or with a blank line).
    static func startsWithGap(_ lines: [LyricLine]) -> Bool {
        guard let first = lines.first else { return false }
        return first.time > 0 || first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || first.text == "♪"
    }
    /// Entries for a song's lines from `start` down, with a "♪" first if the song opens with music. `skipFirst`
    /// leaves that first "♪" out (the line above already is one).
    private func layout(_ lines: [LyricLine], from start: CGFloat, skipFirst: Bool = false) -> [NativeLyricEntry] {
        var texts = lines.map(\.text)
        if (lines.first?.time ?? 0) > 0 { texts.insert("♪", at: 0) }
        if skipFirst && !texts.isEmpty { texts.removeFirst() }
        var y = start, result: [NativeLyricEntry] = []
        for text in texts {
            let gap = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == "♪"
            let value = gap ? "♪" : text
            let wrapped = wrap(value)
            let h = lineH * CGFloat(wrapped.count)
            result.append(NativeLyricEntry(text: value, gap: gap, lines: wrapped, y: y, height: h)); y += h + 8
        }
        return result
    }
    func entry(at time: Double, lines: [LyricLine]) -> Int {
        // with mergedGap, the song's own first line (its "♪") is the kept one just above
        min(firstOwn + max(0, (activeLyric(lines, at: time) ?? -leadingPseudo) + leadingPseudo), max(firstOwn, ownEnd - 1))
    }
    private func fit(_ text: String) -> String {
        if NativeTheme.width(text, font: font) <= textWidth { return text }
        var chars = Array(text)
        while !chars.isEmpty && NativeTheme.width(String(chars) + "…", font: font) > textWidth { chars.removeLast() }
        return String(chars).trimmingCharacters(in: .whitespaces) + "…"
    }
    private func wrap(_ text: String) -> [String] {
        if NativeTheme.width(text, font: font) <= textWidth { return [text] }
        let chars = Array(text)
        var cut = 1
        while cut < chars.count && NativeTheme.width(String(chars.prefix(cut + 1)), font: font) <= textWidth { cut += 1 }
        if cut < chars.count && chars[cut] != " ", let space = chars.prefix(cut).lastIndex(of: " "), space > 0 { cut = space }
        let first = String(chars.prefix(cut)).trimmingCharacters(in: .whitespaces)
        let rest = String(chars.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
        return [first, fit(rest)]
    }
    func draw(paused: Bool, opacity: Double, current: Int, previous: Int, progress: CGFloat, scroll: CGFloat) {
        NativeTheme.surface(in: CGRect(x: 0, y: 0, width: width, height: height), opacity: opacity)
        guard entries.indices.contains(current) else { return }
        let oldHeight = entries.indices.contains(previous) ? entries[previous].height : entries[current].height
        let barHeight = oldHeight + (entries[current].height - oldHeight) * progress
        (paused ? NativeTheme.faint : NativeTheme.accent).setFill()
        NSBezierPath(roundedRect: CGRect(x: 16, y: 12 + anchor, width: 3, height: barHeight), xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 29, y: 12, width: textWidth + 6, height: viewportHeight)).addClip()
        for (index, entry) in entries.enumerated() {
            let y = 12 + entry.y - scroll
            if y + entry.height < 11 || y > 13 + viewportHeight { continue }
            let highlight: CGFloat = index == current ? (previous >= 0 ? progress : 1) : (index == previous ? 1 - progress : 0)
            let bright = paused ? NativeTheme.inkSoft : NativeTheme.ink
            let color = entry.gap ? NativeTheme.dim : NativeTheme.mix(NativeTheme.dim, bright, highlight)
            let center = y + lineH / 2 - 12
            let edge = min(center, viewportHeight - center)
            let fraction = min(1, max(0, edge / max(1, anchor)))
            let alpha = fraction * fraction * (3 - 2 * fraction) * (0.8 + 0.2 * highlight)
            for (row, text) in entry.lines.enumerated() {
                NativeTheme.text(text, font: font, color: color.withAlphaComponent(alpha), rect: CGRect(x: 31, y: y + CGFloat(row) * lineH, width: textWidth + 4, height: lineH + 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct NativePlacement {
    static func frames(screen: CGRect, config: Settings, cardHeight: CGFloat, lyricHeight: CGFloat, cardVisible: Bool, lyricsVisible: Bool) -> (card: CGRect, lyrics: CGRect) {
        let width = config.panelWidth * config.scale
        let gap = 10 * config.scale
        let custom = config.position == "Custom"
        let x: CGFloat
        if custom { x = screen.minX + config.customX }
        else if config.position.hasSuffix("Right") { x = screen.maxX - width - config.marginX }
        else if config.position.hasSuffix("Center") { x = screen.midX - width / 2 }
        else { x = screen.minX + config.marginX }
        let isTop = custom ? !config.customFromBottom : config.position.hasPrefix("Top")
        let marginY = custom ? config.customY : config.marginY
        let cardY = isTop ? screen.maxY - marginY - cardHeight : screen.minY + marginY + (lyricsVisible ? lyricHeight + gap : 0)
        let lyricY = isTop ? screen.maxY - marginY - lyricHeight - (cardVisible ? cardHeight + gap : 0) : screen.minY + marginY
        let safeX = max(screen.minX, min(x, screen.maxX - width))
        return (CGRect(x: safeX, y: max(screen.minY, min(cardY, screen.maxY - cardHeight)), width: width, height: cardHeight),
                CGRect(x: safeX, y: max(screen.minY, min(lyricY, screen.maxY - lyricHeight)), width: width, height: lyricHeight))
    }

    /// Where a widget dragged by the user belongs: the screen holding the dropped column's center (the nearest one
    /// if it is off every screen), and the column's offset from that screen's left edge and from its top or bottom
    /// edge, whichever half the center is in. Clamped so the column stays on that screen. `screens` are visible
    /// frames in AppKit coordinates (origin at the bottom left).
    static func fromDrop(column: CGRect, screens: [CGRect]) -> (monitor: Int, x: Double, y: Double, fromBottom: Bool) {
        let center = CGPoint(x: column.midX, y: column.midY)
        func distance(_ s: CGRect) -> CGFloat {
            let dx = max(0, s.minX - center.x, center.x - s.maxX), dy = max(0, s.minY - center.y, center.y - s.maxY)
            return dx * dx + dy * dy
        }
        let monitor = screens.firstIndex { $0.contains(center) } ?? screens.indices.min { distance(screens[$0]) < distance(screens[$1]) } ?? 0
        let s = screens.isEmpty ? .zero : screens[monitor]
        let fromBottom = center.y < s.midY
        func clamp(_ v: CGFloat, _ hi: CGFloat) -> Double { Double(min(max(v, 0), max(0, hi))) }
        return (monitor, clamp(column.minX - s.minX, s.width - column.width),
                clamp(fromBottom ? column.minY - s.minY : s.maxY - column.maxY, s.height - column.height), fromBottom)
    }
}
