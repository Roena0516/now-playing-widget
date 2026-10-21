import AppKit
import QuartzCore

final class OverlayPanel: NSPanel {
    /// The widget's own opacity (its transparency setting); fades go between 0 and this.
    var maxAlpha: CGFloat = 1
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayCanvas: NSView {
    var render: (() -> Void)?
    var scale: CGFloat = 1 { didSet { if scale != oldValue { showMarquee() } } }
    /// The card's title when it scrolls; render() leaves it out (see MarqueeView).
    var marquee: MarqueeTitle? { didSet { if marquee != oldValue { showMarquee() } } }
    private var marqueeView: MarqueeView?
    private func showMarquee() {
        if marquee != nil && marqueeView == nil { let view = MarqueeView(); addSubview(view); marqueeView = view }
        marqueeView?.show(marquee, scale: scale)
    }
    /// Drag callbacks (screen coordinates) while the panels take mouse input ("위젯 끌어서 옮기기").
    var onDragBegan: ((CGPoint) -> Void)?, onDragged: ((CGPoint) -> Void)?, onDragEnded: (() -> Void)?
    var movable = false { didSet { window?.invalidateCursorRects(for: self) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // the panels never become key
    override func mouseDown(with event: NSEvent) { if movable { NSCursor.closedHand.set(); onDragBegan?(NSEvent.mouseLocation) } }
    override func mouseDragged(with event: NSEvent) { if movable { onDragged?(NSEvent.mouseLocation) } }
    override func mouseUp(with event: NSEvent) { if movable { NSCursor.openHand.set(); onDragEnded?() } }
    override func resetCursorRects() { if movable { addCursorRect(bounds, cursor: .openHand) } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        render?()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A card title too wide for its place, scrolling. It is drawn once into a layer that Core Animation moves, so the
/// card itself is redrawn once a second instead of 60 times (redrawing the whole card for a long cover title kept
/// the app near 55% CPU, 2026-10-21). Same motion as NativeRenderer.drawTitle: still for 1.8 s, then 36 pt/s, and
/// the left edge fades while it moves.
struct MarqueeTitle: Equatable {
    var text: String
    var rect: CGRect   // in card points
    var start: Date
}
@MainActor final class MarqueeView: NSView {
    private let strip = CALayer(), edges = CAGradientLayer()
    private struct Shown: Equatable { var title: MarqueeTitle; var scale: CGFloat; var backing: CGFloat }
    private var shown: Shown?
    init() {
        super.init(frame: .zero)
        layer = CALayer(); wantsLayer = true   // layer-hosting: its layers are ours
        layer?.masksToBounds = true; layer?.addSublayer(strip); layer?.mask = edges
        strip.anchorPoint = .zero; strip.contentsGravity = .resize
        edges.startPoint = CGPoint(x: 0, y: 0.5); edges.endPoint = CGPoint(x: 1, y: 0.5)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // drags go to the card
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let shown { self.shown = nil; show(shown.title, scale: shown.scale) }
    }

    func show(_ title: MarqueeTitle?, scale: CGFloat) {
        guard let title else {
            shown = nil; isHidden = true
            strip.removeAllAnimations(); edges.removeAllAnimations(); strip.contents = nil
            return
        }
        let backing = window?.backingScaleFactor ?? 2
        let next = Shown(title: title, scale: scale, backing: backing)
        guard next != shown else { return }
        shown = next
        let font = NativeRenderer.titleFont
        let textWidth = NativeTheme.width(title.text, font: font), cycle = textWidth + 40
        // the text twice, one cycle apart: when the first has moved a cycle on, the second stands where it began
        let size = CGSize(width: cycle + textWidth + 4, height: title.rect.height), px = scale * backing
        let width = Int(ceil(size.width * px)), height = Int((size.height * px).rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: px, y: px); context.translateBy(x: 0, y: CGFloat(height) / px); context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for x in [0, cycle] { NativeTheme.text(title.text, font: font, color: NativeTheme.ink, rect: CGRect(x: x, y: 0, width: textWidth + 4, height: size.height)) }
        NSGraphicsContext.current = previous

        let frame = CGRect(x: title.rect.minX * scale, y: title.rect.minY * scale, width: title.rect.width * scale, height: title.rect.height * scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.frame = frame; isHidden = false
        strip.contents = context.makeImage(); strip.contentsScale = backing
        strip.bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / backing, height: frame.height); strip.position = .zero
        edges.frame = CGRect(origin: .zero, size: frame.size)
        let edge = min(0.5, 18 / title.rect.width)
        let solid = NSColor.white.cgColor, clear = NSColor.white.withAlphaComponent(0).cgColor
        edges.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        edges.colors = [solid, solid, solid, clear]
        CATransaction.commit()

        let period = 1.8 + cycle / 36
        let begin = strip.convertTime(CACurrentMediaTime(), from: nil) - Date().timeIntervalSince(title.start)
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [0, 0, -cycle * scale]; move.keyTimes = [0, NSNumber(value: 1.8 / period), 1]
        let fade = CAKeyframeAnimation(keyPath: "colors")   // the left edge fades once the text has moved
        fade.values = [[solid, solid, solid, clear], [clear, solid, solid, clear]]
        fade.keyTimes = [0, NSNumber(value: min(1, (1.8 + 0.5 / 36) / period)), 1]; fade.calculationMode = .discrete
        for animation in [move, fade] {
            animation.duration = period; animation.repeatCount = .infinity; animation.beginTime = begin
            animation.isRemovedOnCompletion = false
        }
        strip.add(move, forKey: "marquee"); edges.add(fade, forKey: "marquee")
    }
}

/// One widget's song card and lyrics panel, on its own screen.
@MainActor final class WidgetPanels {
    let card = OverlayController.makePanel(), lyrics = OverlayController.makePanel()
    let cardCanvas = OverlayCanvas(), lyricsCanvas = OverlayCanvas()
    var place: WidgetSetting
    init(_ place: WidgetSetting) {
        self.place = place
        card.contentView = cardCanvas; lyrics.contentView = lyricsCanvas
        card.maxAlpha = place.opacity; lyrics.maxAlpha = place.opacity
    }
}

/// The song card and lyrics panel on every widget's screen (like the Windows version's OverlayGroup): they all
/// show the same thing and appear, fade and scroll together; only their positions differ, each following its
/// widget's rule.
@MainActor final class OverlayController {
    let client: PearClient
    private(set) var widgets: [WidgetPanels] = []
    private let lyrics = NativeLyricsLayout()
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var cardVisible = false, lyricsVisible = false
    private var kind: NativeCardKind = .info
    private var infoText: String?
    private var identity = "", wasPaused = true
    private var marqueeStart = Date()
    private var lastSecond = -1
    private var lines: [LyricLine] = []
    private var linesSong = ""   // the song whose lyrics `lines` holds
    private var shownNext: [LyricLine] = []   // the next song's lines shown below this song's
    private var current = -1, previous = -1
    private var scrollFrom: CGFloat = 0, scrollTo: CGFloat = 0
    private var lyricStart = Date.distantPast
    private var lyricDuration: Double = 0.46
    private let preview: Bool
    // dragging a widget: the panels normally let every click through (they sit over other apps)
    private(set) var moveMode = false
    private var dragging: WidgetPanels?
    private var dragStart = CGPoint.zero, cardStart = CGPoint.zero, lyricsStart = CGPoint.zero
    init(client: PearClient, preview: Bool) {
        self.client = client; self.preview = preview
        timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        rebuildWidgets()
    }

    /// One pair of panels per shown widget (call when widgets are added, removed or screens change).
    func rebuildWidgets() {
        dragging = nil
        for w in widgets { w.card.orderOut(nil); w.lyrics.orderOut(nil) }
        widgets = client.settings.shownWidgets(screenCount: NSScreen.screens.count).map { place in
            let w = WidgetPanels(place)
            w.cardCanvas.render = { [weak self] in
                guard let self else { return }
                NativeRenderer.drawCard(self.client, kind: self.kind, marqueeTime: Date().timeIntervalSince(self.marqueeStart), infoText: self.infoText, titleOnLayer: true)
            }
            w.lyricsCanvas.render = { [weak self] in
                guard let self else { return }
                self.lyrics.draw(paused: self.client.song.paused, opacity: self.client.settings.opacity,
                                 current: self.current, previous: self.previous, progress: self.progress, scroll: self.scroll)
            }
            for canvas in [w.cardCanvas, w.lyricsCanvas] {
                canvas.onDragBegan = { [weak self, weak w] in if let self, let w { self.beginDrag(w, $0) } }
                canvas.onDragged = { [weak self] in self?.drag(to: $0) }
                canvas.onDragEnded = { [weak self] in self?.endDrag() }
                canvas.movable = moveMode
            }
            w.card.ignoresMouseEvents = !moveMode; w.lyrics.ignoresMouseEvents = !moveMode
            return w
        }
        layout()
        for w in widgets {
            if cardVisible { w.card.alphaValue = w.card.maxAlpha; w.card.orderFrontRegardless() }
            if lyricsVisible { w.lyrics.alphaValue = w.lyrics.maxAlpha; w.lyrics.orderFrontRegardless() }
        }
        redraw()
    }

    private var cardPanels: [OverlayPanel] { widgets.map(\.card) }
    private var lyricsPanels: [OverlayPanel] { widgets.map(\.lyrics) }
    private func redraw(card: Bool = true, lyrics: Bool = true) {
        if card { updateMarquee() }
        for w in widgets { if card { w.cardCanvas.needsDisplay = true }; if lyrics { w.lyricsCanvas.needsDisplay = true } }
    }
    /// The card's title for every widget's MarqueeView when it doesn't fit (the cards draw the rest).
    private func updateMarquee() {
        let title = NativeRenderer.titleText(client, kind: kind, infoText: infoText)
        let rect = NativeRenderer.titleRect(NativeRenderer.cardLayout(client, kind: kind))
        let marquee = NativeRenderer.titleScrolls(title, width: rect.width) ? MarqueeTitle(text: title, rect: rect, start: marqueeStart) : nil
        for w in widgets { w.cardCanvas.marquee = marquee }
    }
    private func fade(_ panels: [OverlayPanel], to alpha: CGFloat, duration: Double, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            for p in panels { p.animator().alphaValue = alpha * p.maxAlpha }
        }, completionHandler: { MainActor.assumeIsolated { done?() } })
    }

    /// "위젯 끌어서 옮기기": every widget's panels take the mouse and stay up until the mode is turned off again.
    func setMoveMode(_ on: Bool) {
        guard on != moveMode else { return }
        moveMode = on
        for w in widgets {
            w.card.ignoresMouseEvents = !on; w.lyrics.ignoresMouseEvents = !on
            w.cardCanvas.movable = on; w.lyricsCanvas.movable = on
        }
        if on { showInfo("위젯을 끌어서 옮긴 뒤에 메뉴에서 '위젯 끌어서 옮기기'를 다시 눌러 끝내 주십시오") }
        else {
            if dragging != nil { endDrag() }
            if client.song.title.isEmpty { hide() } else { show() }   // back to the normal show time
        }
    }

    private func beginDrag(_ widget: WidgetPanels, _ mouse: CGPoint) {
        dragging = widget; dragStart = mouse
        cardStart = widget.card.frame.origin; lyricsStart = widget.lyrics.frame.origin
    }

    private func drag(to mouse: CGPoint) {
        guard let w = dragging else { return }
        let dx = mouse.x - dragStart.x, dy = mouse.y - dragStart.y
        if cardVisible { w.card.setFrameOrigin(CGPoint(x: cardStart.x + dx, y: cardStart.y + dy)) }
        if lyricsVisible { w.lyrics.setFrameOrigin(CGPoint(x: lyricsStart.x + dx, y: lyricsStart.y + dy)) }
    }

    /// Save where the widget landed as its "Custom" position on its own screen (it stays on that screen).
    private func endDrag() {
        guard let w = dragging else { return }
        dragging = nil
        var column = CGRect.null
        if cardVisible { column = column.union(w.card.frame) }
        if lyricsVisible { column = column.union(w.lyrics.frame) }
        let screens = NSScreen.screens
        guard !column.isNull, w.place.monitor < screens.count else { layout(); return }
        let drop = NativePlacement.fromDrop(column: column, screens: [screens[w.place.monitor].visibleFrame])
        w.place.position = "Custom"; w.place.customX = drop.x; w.place.customY = drop.y; w.place.customFromBottom = drop.fromBottom
        if let index = client.settings.widgets.firstIndex(where: { $0.monitor == w.place.monitor }) {
            client.settings.widgets[index] = w.place
        } else {
            // the shown widget stood in for one on a screen that's gone: it becomes this screen's own widget
            client.settings.widgets.append(w.place); client.settings.widgets.sort { $0.monitor < $1.monitor }
        }
        client.settings.save()
        layout()
    }
    static func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        return panel
    }
    private var progress: CGFloat {
        let t = min(1, max(0, Date().timeIntervalSince(lyricStart) / lyricDuration))
        return 1 - pow(1 - t, 3)
    }
    private var scroll: CGFloat { scrollFrom + (scrollTo - scrollFrom) * progress }
    private func tick() {
        // the song just changed and refresh() hasn't swapped the lyrics yet: the old ones must not follow the new
        // song's position (they scrolled back to the top before the next song's lines came in)
        if lyricsVisible && linesSong == client.song.identity {
            let index = lyrics.entry(at: client.elapsed + client.settings.lyricsOffsetMs / 1000, lines: lines)
            if index != current && lyrics.entries.indices.contains(index) {
                scrollFrom = scroll; scrollTo = lyrics.entries[index].y - lyrics.anchor
                previous = current; current = index
                lyricDuration = abs(current - previous) > 2 && previous >= lyrics.carried ? 0.26 : 0.46; lyricStart = Date()
            }
            if previous >= 0 { redraw(card: false) }
            if progress >= 1 { previous = -1; scrollFrom = scrollTo }
        }
        // the scrolling title moves on its own layer (MarqueeView): the card changes only with the time
        if cardVisible {
            let second = Int(client.elapsed)
            if second != lastSecond { redraw(lyrics: false); lastSecond = second }
        }
    }
    func refresh() {
        let rebuild = lines != client.lines || lyrics.width != client.settings.panelWidth
        if rebuild {
            // the next song's lyrics while the panel is open: scroll on from the last song's line
            let carry = lyricsVisible && !lines.isEmpty && !client.lines.isEmpty && current >= 0 && linesSong != client.song.identity ? current : nil
            lines = client.lines; linesSong = client.song.identity
            lyrics.setLines(lines, width: client.settings.panelWidth, carryFrom: carry)
            lyrics.setNext(client.nextLines); shownNext = client.nextLines
            current = lyrics.carriedCurrent >= 0 ? lyrics.carriedCurrent   // still on the last song's line; tick() glides on
                : lyrics.entry(at: client.elapsed + client.settings.lyricsOffsetMs / 1000, lines: lines)
            previous = -1
            scrollTo = lyrics.entries.indices.contains(current) ? lyrics.entries[current].y - lyrics.anchor : 0
            scrollFrom = scrollTo; lyricStart = .distantPast
        }
        else if shownNext != client.nextLines {
            // the next song's lyrics arrived (or went away): below this song's last line
            lyrics.setNext(client.nextLines); shownNext = client.nextLines
        }
        linesSong = client.song.identity   // the client sets a song and its lyrics together
        let shouldShow = client.settings.showLyrics && !lines.isEmpty && !client.song.title.isEmpty
        if shouldShow != lyricsVisible {
            lyricsVisible = shouldShow
            if shouldShow {
                layout()
                for p in lyricsPanels { p.alphaValue = 0; p.orderFrontRegardless() }
                fade(lyricsPanels, to: 1, duration: 0.18)
            } else {
                let panels = lyricsPanels
                fade(panels, to: 0, duration: 0.45) { [weak self] in
                    guard let self, !self.lyricsVisible else { return }
                    for p in panels { p.orderOut(nil) }
                }
            }
        }
        redraw()
        layout(); tick()
    }
    func layout() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let config = client.settings
        let cardHeight = NativeRenderer.cardLayout(client, kind: kind).height
        for w in widgets where w !== dragging {   // the mouse decides for the one being dragged
            let screen = screens[min(max(0, w.place.monitor), screens.count - 1)].visibleFrame
            let placed = config.placed(w.place), scale = placed.scale   // each widget has its own size
            let frames = NativePlacement.frames(screen: screen, config: placed, cardHeight: cardHeight * scale, lyricHeight: lyrics.height * scale,
                                                cardVisible: cardVisible, lyricsVisible: lyricsVisible)
            w.cardCanvas.scale = scale; w.lyricsCanvas.scale = scale
            move(w.card, to: frames.card)
            move(w.lyrics, to: frames.lyrics)
        }
    }
    private func move(_ panel: NSPanel, to frame: CGRect) {
        guard panel.frame != frame else { return }
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
    private func appear(wasVisible: Bool) {
        if !wasVisible { for p in cardPanels { p.alphaValue = 0; p.orderFrontRegardless() } }
        fade(cardPanels, to: 1, duration: 0.18)
    }
    func show(temporary: Bool = true) {
        hideTask?.cancel()
        infoText = nil
        if kind == .info && !client.song.title.isEmpty { kind = client.song.paused ? .paused : .nowPlaying }
        let newSong = identity != client.song.identity
        if client.song.title.isEmpty { kind = .info }
        else if newSong { kind = .nowPlaying }
        else if wasPaused != client.song.paused { kind = client.song.paused ? .paused : .resumed }
        else if client.settings.alwaysShow && kind == .resumed { kind = .nowPlaying }
        if !cardVisible || newSong { marqueeStart = Date() }
        identity = client.song.identity; wasPaused = client.song.paused
        let wasVisible = cardVisible; cardVisible = true
        refresh()
        appear(wasVisible: wasVisible)
        if temporary && !client.settings.alwaysShow && !moveMode {
            hideTask = Task { try? await Task.sleep(for: .seconds(client.settings.showSeconds)); guard !Task.isCancelled else { return }; hide() }
        }
    }
    /// Play/pause without a song change, like the Windows version's OnPlayState: with "show on pause" the card
    /// appears (Paused / Resumed); otherwise a card already up just updates its label and keeps its timing.
    func playStateChanged() {
        if client.settings.showOnPause { show(); return }
        wasPaused = client.song.paused
        guard cardVisible, kind != .info else { return }
        kind = client.song.paused ? .paused : .nowPlaying
        refresh()
    }

    func showInfo(_ message: String) {
        hideTask?.cancel(); kind = .info; infoText = message; marqueeStart = Date()
        let wasVisible = cardVisible; cardVisible = true
        refresh()
        appear(wasVisible: wasVisible)
        // While "always show" keeps the song card up, the message only borrows its place for a few seconds
        // and the song card comes back; otherwise the message fades out like a normal card.
        let keep = client.settings.alwaysShow || moveMode
        let restore = keep && !client.song.title.isEmpty
        hideTask = Task {
            try? await Task.sleep(for: .seconds(restore ? 3.5 : max(3, client.settings.showSeconds)))
            guard !Task.isCancelled else { return }
            if restore { show() } else if !moveMode { hide() }   // while moving, a message with no song stays up
        }
    }
    func hide() {
        let panels = cardPanels
        fade(panels, to: 0, duration: 0.45) { [weak self] in
            guard let self, let first = panels.first, first.alphaValue == 0 else { return }
            for p in panels { p.orderOut(nil) }
            self.cardVisible = false; self.layout()
        }
    }
    func stop() { timer?.invalidate(); timer = nil; hideTask?.cancel() }
}
