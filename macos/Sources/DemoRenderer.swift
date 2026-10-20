import AppKit

/// "--render-demo <folder>": the README's animations as numbered PNG frames, drawn by the app's own renderer (one
/// folder per scene; macos/Tools/make-gifs.py turns them into docs/*.gif). The example song is the README's
/// (코가네 랑's cover of 호랑풍류가); the lyric lines are sample sentences about the widget, not the song's lyrics, and
/// the cover is a plain gradient, not the video's thumbnail.
@MainActor func renderDemo(to folder: URL) throws {
    NativeTheme.registerFonts()
    let client = PearClient(loadRemoteAssets: false)
    client.settings.panelWidth = 420; client.settings.opacity = 0.92
    client.artwork = demoCover()
    let song: [String: Any] = ["title": "호랑풍류가 [나와 호랑이님 OST] / 코가네 랑 (Cogane Rang) Cover", "artist": "코가네 랑 COGANE RANG",
                               "videoId": "iAoU1UGPoXc", "songDuration": 253, "mediaType": "USER_GENERATED_CONTENT"]
    client.handle(["type": "PLAYER_INFO", "isPlaying": false, "position": 0, "song": song])
    let lines = parseLRC("""
    [00:46.00]노래에 맞춰 가사가 한 줄씩 올라갑니다
    [00:49.50]지금 부르는 줄은 밝게 표시됩니다
    [00:53.00]긴 줄은 화면 밖으로 넘치지 않도록 두 줄로 나누어 보여 줍니다
    [00:57.50]
    [01:00.00]日本語の歌詞もそのまま表示されます
    [01:03.50]English lines look just as clean
    [01:07.00]가사 타이밍은 메뉴에서 조절할 수 있습니다
    [01:11.00]
    """)
    let fps = 20.0
    let card = NativeRenderer.cardLayout(client, kind: .nowPlaying).height

    // the clock of each frame: the player paused at `position`, so client.elapsed is exactly that
    func at(_ position: Double) { client.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": false, "position": position]) }

    /// Lyrics as the overlay animates them (Overlay.tick): a new line glides up over 0.46 s, easing out.
    @MainActor final class Scroller {
        let layout = NativeLyricsLayout()
        var current = -1, previous = -1, scrollFrom: CGFloat = 0, scrollTo: CGFloat = 0, start = -10.0
        func update(_ position: Double, lines: [LyricLine], time: Double) -> (CGFloat, CGFloat) {
            let index = layout.entry(at: position + 0.3, lines: lines)
            if current < 0 { current = index; scrollTo = layout.entries[index].y - layout.anchor; scrollFrom = scrollTo }
            let progress = progressAt(time)
            if index != current {
                scrollFrom = scrollFrom + (scrollTo - scrollFrom) * progress
                scrollTo = layout.entries[index].y - layout.anchor
                previous = current; current = index; start = time
            }
            let p = progressAt(time)
            if p >= 1 { previous = -1 }
            return (p, scrollFrom + (scrollTo - scrollFrom) * p)
        }
        func progressAt(_ time: Double) -> CGFloat { let t = min(1, max(0, (time - start) / 0.46)); return CGFloat(1 - pow(1 - t, 3)) }
    }

    // 1) the song card and its lyrics, playing (the long title scrolls along)
    let hero = Scroller(); hero.layout.setLines(lines, width: 420)
    try frames(folder.appendingPathComponent("hero"), size: CGSize(width: 500, height: card + 10 + hero.layout.height + 60), count: Int(15 * fps)) { i in
        let time = Double(i) / fps, position = 47 + time
        at(position)
        let (progress, scroll) = hero.update(position, lines: lines, time: time)
        NativeRenderer.drawCard(client, kind: .nowPlaying, marqueeTime: time)
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: card + 10)
        hero.layout.draw(paused: false, opacity: 0.92, current: hero.current, previous: hero.previous, progress: progress, scroll: scroll)
    }

    // 2) the long title, one full cycle of its scroll
    let font = NativeTheme.font(17, medium: true)
    let titleWidth = NativeTheme.width(client.cardTitle, font: font)
    let cycle = 1.8 + Double(titleWidth + 40) / 36
    try frames(folder.appendingPathComponent("marquee"), size: CGSize(width: 500, height: card + 40), count: Int(cycle * fps)) { i in
        let time = Double(i) / fps
        at(120 + time)
        NativeRenderer.drawCard(client, kind: .nowPlaying, marqueeTime: time)
    }

    // 3) pause and play again: the card says so, the progress and the lyrics' bar turn grey
    let pause = Scroller(); pause.layout.setLines(lines, width: 420)
    try frames(folder.appendingPathComponent("pause"), size: CGSize(width: 500, height: card + 10 + pause.layout.height + 60), count: Int(7 * fps)) { i in
        let time = Double(i) / fps
        let paused = time >= 2.2 && time < 5
        let position = 51 + (time < 2.2 ? time : time < 5 ? 2.2 : time - 2.8)
        at(position)
        let (progress, scroll) = pause.update(position, lines: lines, time: time)
        NativeRenderer.drawCard(client, kind: paused ? .paused : time >= 5 ? .resumed : .nowPlaying, marqueeTime: 0)
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: card + 10)
        pause.layout.draw(paused: paused, opacity: 0.92, current: pause.current, previous: pause.previous, progress: progress, scroll: scroll)
    }
    print("Rendered demo frames into \(folder.path)")
}

/// Frames of one scene: a soft wallpaper, the widget 40 pt from the left and 30 pt from the top, drawn at 2x.
@MainActor private func frames(_ folder: URL, size: CGSize, count: Int, draw: (Int) -> Void) throws {
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let scale: CGFloat = 2
    for i in 0..<count {
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let wallpaper = NSGradient(colors: [NativeTheme.color(0x7a8fb0), NativeTheme.color(0xc9b8a6)])
        wallpaper?.draw(in: CGRect(origin: .zero, size: size), angle: 90)
        context.translateBy(x: 40, y: 30)
        draw(i)
        NSGraphicsContext.current = previous
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: folder.appendingPathComponent(String(format: "%04d.png", i)))
    }
}

/// A plain cover: a warm gradient with a record's label in the middle.
@MainActor private func demoCover() -> Data? {
    let side: CGFloat = 240
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    NSGradient(colors: [NativeTheme.color(0xf08a7e), NativeTheme.color(0x7b5ea7)])?.draw(in: CGRect(x: 0, y: 0, width: side, height: side), angle: -45)
    NativeTheme.color(0xf6e9e4).setFill()
    NSBezierPath(ovalIn: CGRect(x: side / 2 - 28, y: side / 2 - 28, width: 56, height: 56)).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
