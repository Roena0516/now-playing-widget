import AppKit

@MainActor func renderNativePreview(to url: URL) throws {
    NativeTheme.registerFonts()
    let width = 900, height = 570, scale: CGFloat = 2
    guard let context = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.current = previous }
    NativeTheme.color(0x1a1a1c).setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
    let client = PearClient(loadRemoteAssets: false)
    client.settings.panelWidth = 420; client.settings.opacity = 0.92
    client.handle(["type": "PLAYER_INFO", "isPlaying": false, "position": 83, "song": ["title": "夜のメロディ / 밤의 멜로디", "artist": "Pear Music", "album": "Midnight Sessions", "videoId": "preview", "songDuration": 261]])
    let lyricLines = parseLRC("[00:00.00]조용한 밤에 음악이 흐르고\n[00:20.00]좋아하는 멜로디를 따라\n[01:20.00]지금 이 순간을 기억해요\n[01:30.00]언어가 달라도 함께 듣는 노래\n[01:40.00]다음 이야기로 천천히 이어져요")
    let lyrics = NativeLyricsLayout(); lyrics.setLines(lyricLines, width: 420)
    for (column, kind) in [NativeCardKind.nowPlaying, .paused].enumerated() {
        context.saveGState(); context.translateBy(x: CGFloat(20 + column * 440), y: 20)
        NativeRenderer.drawCard(client, kind: kind, marqueeTime: 0)
        context.translateBy(x: 0, y: NativeRenderer.cardLayout(client, kind: kind).height + 10)
        lyrics.draw(paused: kind == .paused, opacity: 0.92, current: 2, previous: -1, progress: 1, scroll: lyrics.entries[2].y - lyrics.anchor)
        context.restoreGState()
    }
    context.saveGState(); context.translateBy(x: 20, y: 330)
    client.song.title = "長い曲名が滑らかにスクロールする · 긴 곡 제목도 원본처럼 자연스럽게 흐릅니다"
    NativeRenderer.drawCard(client, kind: .resumed, marqueeTime: 4)
    context.restoreGState()
    context.saveGState(); context.translateBy(x: 460, y: 330)
    client.song = Song(); client.status = "Pear Desktop에서 '허용'을 눌러 주십시오"
    NativeRenderer.drawCard(client, kind: .info, marqueeTime: 0, infoText: "가사를 다시 찾고 있습니다")
    context.restoreGState()
    guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
    print("Rendered native preview: \(url.path)")
}
