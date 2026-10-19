import AppKit
import QuartzCore

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayCanvas: NSView {
    var render: (() -> Void)?
    var scale: CGFloat = 1
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
@MainActor final class OverlayController {
    let panel: OverlayPanel
    let lyricsPanel: OverlayPanel
    let client: PearClient
    private let cardCanvas = OverlayCanvas(), lyricsCanvas = OverlayCanvas()
    private let lyrics = NativeLyricsLayout()
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var cardVisible = false, lyricsVisible = false
    private var kind: NativeCardKind = .info
    private var infoText: String?
    private var identity = "", wasPaused = true
    private var marqueeStart = Date()
    private var marqueeActive = false
    private var lastSecond = -1
    private var lines: [LyricLine] = []
    private var current = -1, previous = -1
    private var scrollFrom: CGFloat = 0, scrollTo: CGFloat = 0
    private var lyricStart = Date.distantPast
    private var lyricDuration: Double = 0.46
    private let preview: Bool
    // dragging the widget: the panels normally let every click through (they sit over other apps)
    private(set) var moveMode = false
    private var dragging = false
    private var dragStart = CGPoint.zero, cardStart = CGPoint.zero, lyricsStart = CGPoint.zero
    init(client: PearClient, preview: Bool) {
        self.client = client; self.preview = preview
        panel = Self.makePanel(); lyricsPanel = Self.makePanel()
        panel.contentView = cardCanvas; lyricsPanel.contentView = lyricsCanvas
        cardCanvas.render = { [weak self] in
            guard let self else { return }
            NativeRenderer.drawCard(self.client, kind: self.kind, marqueeTime: Date().timeIntervalSince(self.marqueeStart), infoText: self.infoText)
        }
        lyricsCanvas.render = { [weak self] in
            guard let self else { return }
            self.lyrics.draw(paused: self.client.song.paused, opacity: self.client.settings.opacity,
                             current: self.current, previous: self.previous, progress: self.progress, scroll: self.scroll)
        }
        timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        for canvas in [cardCanvas, lyricsCanvas] {
            canvas.onDragBegan = { [weak self] in self?.beginDrag($0) }
            canvas.onDragged = { [weak self] in self?.drag(to: $0) }
            canvas.onDragEnded = { [weak self] in self?.endDrag() }
        }
        layout()
    }

    /// "위젯 끌어서 옮기기": both panels take the mouse and stay up until the mode is turned off again.
    func setMoveMode(_ on: Bool) {
        guard on != moveMode else { return }
        moveMode = on
        for (panel, canvas) in [(self.panel, cardCanvas), (lyricsPanel, lyricsCanvas)] {
            panel.ignoresMouseEvents = !on
            canvas.movable = on
        }
        if on { showInfo("위젯을 끌어서 옮긴 뒤, 메뉴에서 '위젯 끌어서 옮기기'를 다시 눌러 끝내세요") }
        else {
            if dragging { endDrag() }
            if client.song.title.isEmpty { hide() } else { show() }   // back to the normal show time
        }
    }

    private func beginDrag(_ mouse: CGPoint) {
        dragging = true; dragStart = mouse
        cardStart = panel.frame.origin; lyricsStart = lyricsPanel.frame.origin
    }

    private func drag(to mouse: CGPoint) {
        guard dragging else { return }
        let dx = mouse.x - dragStart.x, dy = mouse.y - dragStart.y
        if cardVisible { panel.setFrameOrigin(CGPoint(x: cardStart.x + dx, y: cardStart.y + dy)) }
        if lyricsVisible { lyricsPanel.setFrameOrigin(CGPoint(x: lyricsStart.x + dx, y: lyricsStart.y + dy)) }
    }

    /// Save where the widget landed (screen, offsets, top or bottom anchor) as the "Custom" position.
    private func endDrag() {
        guard dragging else { return }
        dragging = false
        var column = CGRect.null
        if cardVisible { column = column.union(panel.frame) }
        if lyricsVisible { column = column.union(lyricsPanel.frame) }
        guard !column.isNull else { return }
        let drop = NativePlacement.fromDrop(column: column, screens: NSScreen.screens.map(\.visibleFrame))
        client.settings.position = "Custom"; client.settings.monitor = drop.monitor
        client.settings.customX = drop.x; client.settings.customY = drop.y; client.settings.customFromBottom = drop.fromBottom
        client.settings.save()
        layout()
    }
    private static func makePanel() -> OverlayPanel {
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
        if lyricsVisible {
            let index = lyrics.entry(at: client.elapsed + client.settings.lyricsOffsetMs / 1000, lines: lines)
            if index != current && lyrics.entries.indices.contains(index) {
                scrollFrom = scroll; scrollTo = lyrics.entries[index].y - lyrics.anchor
                previous = current; current = index
                lyricDuration = abs(current - previous) > 2 ? 0.26 : 0.46; lyricStart = Date()
            }
            if previous >= 0 { lyricsCanvas.needsDisplay = true }
            if progress >= 1 { previous = -1; scrollFrom = scrollTo }
        }
        if cardVisible {
            let second = Int(client.elapsed)
            if marqueeActive || second != lastSecond { cardCanvas.needsDisplay = true; lastSecond = second }
        }
    }
    func refresh() {
        let rebuild = lines != client.lines || lyrics.width != client.settings.panelWidth
        if rebuild {
            lines = client.lines; lyrics.setLines(lines, width: client.settings.panelWidth)
            current = lyrics.entry(at: client.elapsed + client.settings.lyricsOffsetMs / 1000, lines: lines)
            previous = -1
            scrollTo = lyrics.entries.indices.contains(current) ? lyrics.entries[current].y - lyrics.anchor : 0
            scrollFrom = scrollTo; lyricStart = .distantPast
        }
        let shouldShow = client.settings.showLyrics && !lines.isEmpty && !client.song.title.isEmpty
        if shouldShow != lyricsVisible {
            lyricsVisible = shouldShow
            if shouldShow {
                layout(); lyricsPanel.alphaValue = 0; lyricsPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; lyricsPanel.animator().alphaValue = 1 }
            } else {
                NSAnimationContext.runAnimationGroup({ context in context.duration = 0.45; lyricsPanel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.lyricsVisible else { return }; self.lyricsPanel.orderOut(nil)
                    }
                })
            }
        }
        let title = kind == .info ? (infoText ?? client.status) : client.cardTitle
        marqueeActive = NativeTheme.width(title, font: NativeTheme.font(17, medium: true)) > NativeRenderer.cardLayout(client, kind: kind).textWidth + 0.5
        cardCanvas.needsDisplay = true; lyricsCanvas.needsDisplay = true
        layout(); tick()
    }
    func layout() {
        if dragging { return }   // the mouse decides for now
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let config = client.settings
        let screen = screens[min(max(0, config.monitor), screens.count - 1)].visibleFrame
        let scale = config.scale
        let cardHeight = NativeRenderer.cardLayout(client, kind: kind).height * scale
        let lyricHeight = lyrics.height * scale
        let frames = NativePlacement.frames(screen: screen, config: config, cardHeight: cardHeight, lyricHeight: lyricHeight, cardVisible: cardVisible, lyricsVisible: lyricsVisible)
        cardCanvas.scale = scale; lyricsCanvas.scale = scale
        move(panel, to: frames.card)
        move(lyricsPanel, to: frames.lyrics)
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
        if !wasVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; panel.animator().alphaValue = 1 }
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
        if !wasVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; panel.animator().alphaValue = 1 }
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
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.45; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil); self.cardVisible = false; self.layout()
            }
        })
    }
    func stop() { timer?.invalidate(); timer = nil; hideTask?.cancel() }
}
