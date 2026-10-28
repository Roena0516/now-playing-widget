import AppKit

/// What the menu header's update button shows (the Windows version's UpdateButton has the same states).
enum UpdateButton: Equatable {
    case check, checking, upToDate, install(String), installing
    var text: String {
        switch self {
        case .check: return "업데이트 확인"
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전"
        case .install(let version): return "\(version) 설치"
        case .installing: return "설치 중…"
        }
    }
    var busy: Bool { self == .checking || self == .installing }
}

/// The menu's first item, like the Windows version's MenuHeaderItem: the app's name and version, and a round button on
/// the right for updates ("업데이트 확인", "2.0.6 설치"). Only the button reacts. A click doesn't close the menu (the view
/// takes it), so a check's result shows on the button; installing closes the menu first.
final class MenuHeader: NSView {
    var button: UpdateButton { didSet { if button != oldValue { needsDisplay = true } } }
    var onButton: ((UpdateButton) -> Void)?
    private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    private static let titleFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    private static let smallFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
    private static let buttonFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    // the title lines up with the menu's other items (no checkmark column in this menu, measured on macOS 26)
    private static let inset: CGFloat = 15, height: CGFloat = 46

    init(button: UpdateButton) {
        self.button = button
        let widest = ["업데이트 확인", "88.88.88 설치"].map { Self.width($0, Self.buttonFont) }.max()! + 24
        let left = max(Self.width("Now Playing Widget", Self.titleFont), Self.width(Self.versionText, Self.smallFont))
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(Self.inset + left + 28 + widest + 12), height: Self.height))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private static var versionText: String { "버전 \(appVersion)" }
    private static func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    override var isFlipped: Bool { true }

    private var buttonRect: CGRect {
        let width = ceil(Self.width(button.text, Self.buttonFont)) + 24, height: CGFloat = 22
        return CGRect(x: bounds.maxX - 12 - width, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleH = Self.titleFont.ascender - Self.titleFont.descender, smallH = Self.smallFont.ascender - Self.smallFont.descender
        let top = ((bounds.height - titleH - smallH - 1) / 2).rounded()
        ("Now Playing Widget" as NSString).draw(at: CGPoint(x: Self.inset, y: top), withAttributes: [.font: Self.titleFont, .foregroundColor: NSColor.labelColor])
        (Self.versionText as NSString).draw(at: CGPoint(x: Self.inset, y: top + titleH + 1), withAttributes: [.font: Self.smallFont, .foregroundColor: NSColor.secondaryLabelColor])

        let rect = buttonRect, path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let fill: NSColor, ink: NSColor
        if case .install = button {
            fill = hover ? NSColor.controlAccentColor.blended(withFraction: 0.15, of: .black) ?? .controlAccentColor : .controlAccentColor
            ink = .white
        } else {
            fill = NSColor.labelColor.withAlphaComponent(hover && !button.busy ? 0.18 : 0.1)
            ink = button.busy ? .secondaryLabelColor : .labelColor
        }
        fill.setFill(); path.fill()
        let text = NSAttributedString(string: button.text, attributes: [.font: Self.buttonFont, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: (rect.midY - size.height / 2).rounded()))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func over(_ event: NSEvent) -> Bool { buttonRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hover = over(event) }
    override func mouseEntered(with event: NSEvent) { hover = over(event) }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        guard over(event), !button.busy else { return }
        let pressed = button
        if case .install = pressed { enclosingMenuItem?.menu?.cancelTracking() }
        onButton?(pressed)
    }
}
