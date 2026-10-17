import AppKit
import SwiftUI

private let accent = Color(red: 0.62, green: 0.80, blue: 0.64)
struct Marquee: View {
    let text: String
    let width: CGFloat
    @State private var start = Date()
    var body: some View {
        let measured = (text as NSString).size(withAttributes: [.font: NSFont(name: "PretendardJP-Medium", size: 17) ?? NSFont.systemFont(ofSize: 17, weight: .semibold)]).width
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let distance = measured + 40
            let elapsed = max(0, context.date.timeIntervalSince(start) - 1.8)
            let shift = measured > width ? (elapsed * 28).truncatingRemainder(dividingBy: distance) : 0
            HStack(spacing: 40) {
                Text(text).fixedSize()
                if measured > width { Text(text).fixedSize() }
            }
            .font(.custom("PretendardJP-Medium", size: 17)).foregroundStyle(.white)
            .offset(x: -shift).frame(width: width, alignment: .leading).clipped()
        }
        .onChange(of: text) { _ in start = Date() }
    }
}
struct OverlayView: View {
    @ObservedObject var client: PearClient
    let preview: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let width = client.settings.panelWidth
            let song = client.song
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Group {
                        if let data = client.artwork, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
                        else { ZStack { Color.white.opacity(0.07); Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(accent) } }
                    }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 7) {
                        Marquee(text: song.title.isEmpty ? "Pear Now Playing" : song.title, width: width - 114)
                        Text(song.title.isEmpty ? "Pear Desktop의 API 서버를 켜 주세요" : [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.custom("PretendardJP-Regular", size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(song.paused ? Color.gray : accent).frame(width: geometry.size.width * min(1, max(0, song.duration > 0 ? client.elapsed / song.duration : 0)))
                            }
                        }.frame(height: 3)
                    }
                }.padding(18).frame(width: width).background(card)
                if client.settings.showLyrics && !client.lines.isEmpty {
                    let current = activeLyric(client.lines, at: client.elapsed + client.settings.lyricsOffsetMs / 1000) ?? -1
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                Color.clear.frame(height: 60)
                                ForEach(client.lines) { line in
                                    Text(line.text).font(.custom(line.id == current ? "PretendardJP-Medium" : "PretendardJP-Regular", size: 18))
                                        .foregroundStyle(line.id == current ? .white : .white.opacity(0.3))
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                                }
                                Color.clear.frame(height: 60)
                            }.padding(.horizontal, 22)
                        }
                        .onAppear { if current >= 0 { proxy.scrollTo(current, anchor: .center) } }
                        .onChange(of: current) { index in if index >= 0 { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(index, anchor: .center) } } }
                    }
                    .frame(width: width, height: 180)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .background(card)
                }
                Spacer(minLength: 0)
            }.frame(width: width, height: 300, alignment: .top).scaleEffect(client.settings.scale, anchor: .topLeading)
        }.frame(width: client.settings.panelWidth * client.settings.scale, height: 300 * client.settings.scale)
    }
    private var card: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.075, green: 0.085, blue: 0.09).opacity(client.settings.opacity))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3).padding(.vertical, 16) }
    }
}
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayController {
    let panel: OverlayPanel
    let client: PearClient
    private var hideTask: Task<Void, Never>?
    init(client: PearClient, preview: Bool) {
        self.client = client
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(client: client, preview: preview))
        layout()
    }
    func layout() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let config = client.settings
        let screen = screens[min(max(0, config.monitor), screens.count - 1)].visibleFrame
        let size = NSSize(width: config.panelWidth * config.scale, height: 300 * config.scale)
        let x: CGFloat
        if config.position.hasSuffix("Right") { x = screen.maxX - size.width - config.marginX }
        else if config.position.hasSuffix("Center") { x = screen.midX - size.width / 2 }
        else { x = screen.minX + config.marginX }
        let y = config.position.hasPrefix("Top") ? screen.maxY - size.height - config.marginY : screen.minY + config.marginY
        panel.setFrame(NSRect(x: max(screen.minX, min(x, screen.maxX - size.width)), y: max(screen.minY, min(y, screen.maxY - size.height)), width: size.width, height: size.height), display: true)
    }
    func show(temporary: Bool = true) {
        hideTask?.cancel(); layout()
        panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; panel.animator().alphaValue = 1 }
        if temporary && !client.settings.alwaysShow && !(client.settings.showLyrics && !client.lines.isEmpty && !client.song.title.isEmpty) {
            hideTask = Task { try? await Task.sleep(for: .seconds(client.settings.showSeconds)); guard !Task.isCancelled else { return }; hide() }
        }
    }
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: { [weak panel] in if panel?.alphaValue == 0 { panel?.orderOut(nil) } })
    }
}
