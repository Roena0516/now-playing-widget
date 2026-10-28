import AppKit

/// A menu row that runs its action without closing the menu (a menu closes after a click on a normal item), for the
/// 가사 타이밍 steps that are clicked several times in a row while the lyrics move. Drawn like a normal item: the menu font
/// at a normal item's height and title position (measured on macOS 26), the selection under the mouse, greyed out when
/// disabled.
final class MenuRow: NSView {
    var title: String { didSet { needsDisplay = true } }
    var isEnabled: Bool { didSet { enclosingMenuItem?.isEnabled = isEnabled; needsDisplay = true } }
    var perform: (() -> Void)?
    private static let font = NSFont.menuFont(ofSize: 0)
    private static let height: CGFloat = 24, inset: CGFloat = 24

    /// Added with NSMenu.addRow; the menu needs autoenablesItems = false (the items have no action of their own).
    init(_ title: String, enabled: Bool = true, perform: (() -> Void)? = nil) {
        self.title = title; isEnabled = enabled; self.perform = perform
        let width = (title as NSString).size(withAttributes: [.font: Self.font]).width + Self.inset * 2
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: Self.height))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var lit: Bool { isEnabled && enclosingMenuItem?.isHighlighted == true }
    override func draw(_ dirtyRect: NSRect) {
        if lit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = !isEnabled ? .disabledControlTextColor : lit ? .selectedMenuItemTextColor : .controlTextColor
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        text.draw(at: NSPoint(x: Self.inset, y: ((bounds.height - text.size().height) / 2).rounded()))
    }
    // the menu marks the item highlighted as the mouse moves over it; redraw then too
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        perform?()
        needsDisplay = true
    }
}

extension NSMenu {
    /// Adds a MenuRow in an item of its own (the item keeps the row; the row finds it as enclosingMenuItem).
    func addRow(_ row: MenuRow) {
        let item = NSMenuItem(); item.view = row; item.isEnabled = row.isEnabled
        addItem(item)
    }
}
