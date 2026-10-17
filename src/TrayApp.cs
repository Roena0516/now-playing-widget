using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace PearNowPlaying
{
    internal sealed class TrayApp : ApplicationContext
    {
        Config cfg;
        readonly PearClient pear;
        readonly LyricsProvider lyricsProvider;
        readonly OverlayWindow cardWin, lyricsWin;
        readonly Hotkeys hotkeys;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip menu;
        readonly ToolStripMenuItem statusItem, pinItem, lyricsItem, retryLyricsItem, ytmLyricsItem, lyricsInfoItem, offsetMenu, posMenu, sizeMenu;
        readonly HttpClient artHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        readonly SynchronizationContext ui;
        readonly double dpiScale;
        readonly System.Windows.Forms.Timer lyricsTimer = new System.Windows.Forms.Timer { Interval = 100 };
        readonly System.Windows.Forms.Timer frameTimer = new System.Windows.Forms.Timer { Interval = 15 };
        readonly LyricsView lyricsView = new LyricsView();
        readonly System.Windows.Forms.Timer cardFrameTimer = new System.Windows.Forms.Timer { Interval = 16 };
        // a short message card (ShowInfo) temporarily takes the song card's place; this brings the song back
        readonly System.Windows.Forms.Timer infoTimer = new System.Windows.Forms.Timer();
        DateTime infoUntil = DateTime.MinValue;
        readonly Stopwatch marquee = new Stopwatch();
        CardFrame cardFrame;

        string artUrl;
        Image artImage;
        CardKind lastKind = CardKind.NowPlaying;
        int lastShownSecond = -1;
        bool everConnected;

        // lyrics state
        LyricsResult lyrics;
        string lyricsKey;
        CancellationTokenSource lyricsCts;
        CancellationTokenSource prefetchCts;
        bool lyricPaused;
        string announceKey;   // set by a manual retry: say how it went when that song's lookup finishes
        string lyricsLayoutKey;

        // local playback clock: Pear reports whole seconds, so we interpolate between reports
        double basePos;
        readonly Stopwatch clock = new Stopwatch();

        public TrayApp()
        {
            ui = SynchronizationContext.Current;
            cfg = Config.Load();
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpiScale = g.DpiX / 96.0;

            cardWin = new OverlayWindow();
            lyricsWin = new OverlayWindow();
            var h1 = cardWin.Handle; var h2 = lyricsWin.Handle;
            lyricsWin.FadedOut += (s, e) => Reposition();
            cardWin.FadedOut += (s, e) => Reposition();

            // tray menu
            menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem("연결 준비 중") { Enabled = false };
            lyricsInfoItem = new ToolStripMenuItem("가사: -") { Enabled = false };
            pinItem = new ToolStripMenuItem("곡 정보 계속 표시", null, (s, e) => TogglePin());
            lyricsItem = new ToolStripMenuItem("가사 표시", null, (s, e) => ToggleLyrics());
            retryLyricsItem = new ToolStripMenuItem("가사 다시 찾기", null, (s, e) => RetryLyrics());
            ytmLyricsItem = new ToolStripMenuItem("YouTube Music 가사 먼저 찾기", null, (s, e) => ToggleYtmLyrics());
            offsetMenu = new ToolStripMenuItem("가사 타이밍");
            foreach (var pair in new[] { Tuple.Create("1초 빠르게", 1300), Tuple.Create("0.5초 빠르게", 800), Tuple.Create("기본", 300),
                                         Tuple.Create("0.5초 늦게", -200), Tuple.Create("1초 늦게", -700) })
            {
                var v = pair.Item2;
                offsetMenu.DropDownItems.Add(new ToolStripMenuItem(pair.Item1, null, (s, e) => SetOffset(v)) { Tag = v });
            }
            posMenu = new ToolStripMenuItem("위치");
            foreach (OverlayPosition p in Enum.GetValues(typeof(OverlayPosition)))
            {
                var pos = p;
                posMenu.DropDownItems.Add(new ToolStripMenuItem(PositionName(pos), null, (s, e) => SetPosition(pos)) { Tag = pos });
            }
            sizeMenu = new ToolStripMenuItem("크기");
            foreach (var pair in new[] { Tuple.Create("작게", 0.8), Tuple.Create("보통", 1.0), Tuple.Create("크게", 1.25), Tuple.Create("아주 크게", 1.5) })
            {
                var v = pair.Item2;
                sizeMenu.DropDownItems.Add(new ToolStripMenuItem(pair.Item1, null, (s, e) => SetScale(v)) { Tag = v });
            }
            menu.Items.Add(statusItem);
            menu.Items.Add(lyricsInfoItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("지금 곡 보기", null, (s, e) => ShowNow(CurrentKind())));
            menu.Items.Add(pinItem);
            menu.Items.Add(lyricsItem);
            menu.Items.Add(retryLyricsItem);
            menu.Items.Add(ytmLyricsItem);
            menu.Items.Add(offsetMenu);
            menu.Items.Add(posMenu);
            menu.Items.Add(sizeMenu);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("이전 곡", null, (s, e) => pear.Previous()));
            menu.Items.Add(new ToolStripMenuItem("재생 / 일시정지", null, (s, e) => pear.TogglePlay()));
            menu.Items.Add(new ToolStripMenuItem("다음 곡", null, (s, e) => pear.Next()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Pear 연결 권한 다시 요청", null, (s, e) => { Config.WriteToken(null); pear.RetryAuth(); }));
            menu.Items.Add(new ToolStripMenuItem("설정 파일 열기", null, (s, e) => OpenFile(Config.FilePath)));
            menu.Items.Add(new ToolStripMenuItem("설정 다시 불러오기", null, (s, e) => ReloadConfig()));
            menu.Items.Add(new ToolStripMenuItem("오류 기록 열기", null, (s, e) => OpenFile(Config.LogPath)));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("종료", null, (s, e) => ExitThread()));
            menu.Opening += (s, e) => SyncMenuChecks();

            tray = new NotifyIcon
            {
                Icon = CardRenderer.MakeTrayIcon(32),
                Text = "Pear Now Playing",
                ContextMenuStrip = menu,
                Visible = true
            };
            tray.DoubleClick += (s, e) => ShowNow(CurrentKind());

            hotkeys = new Hotkeys();
            RegisterHotkeys();

            lyricsProvider = new LyricsProvider(cfg.LyricsServer) { Ytm = new YtmLyrics() };
            ApplyLyricsSources();
            lyricsTimer.Tick += (s, e) => TickLyrics();
            lyricsTimer.Start();
            frameTimer.Tick += (s, e) => LyricsFrame();
            cardFrameTimer.Tick += (s, e) => CardFrameTick();
            infoTimer.Tick += (s, e) => EndInfo();

            pear = new PearClient(ui, cfg);
            pear.StatusChanged += OnStatus;
            pear.SongUpdated += OnSong;
            pear.PlayStateChanged += OnPlayState;
            pear.PositionChanged += OnPosition;
            pear.Start();
        }

        // ---- pear events -----------------------------------------------------

        void OnStatus(PearStatus s)
        {
            statusItem.Text = StatusText(s);
            tray.Text = Truncate("Pear Now Playing - " + StatusText(s), 63);
            switch (s)
            {
                case PearStatus.Authorizing:
                    Balloon("Pear Desktop에서 연결 요청 창이 떴어요. '허용'을 눌러주세요.");
                    ShowInfo("Pear Desktop에서 '허용'을 눌러주세요");
                    break;
                case PearStatus.Denied:
                    Balloon("Pear Desktop에서 연결이 거부됐어요. 트레이 메뉴의 '권한 다시 요청'으로 다시 시도할 수 있어요.");
                    break;
                case PearStatus.Connected:
                    if (!everConnected)
                    {
                        everConnected = true;
                        if (!pear.Current.HasData) ShowInfo("Pear Desktop에 연결됐어요");
                    }
                    break;
                case PearStatus.Waiting:
                    clock.Stop();
                    lyricsWin.Dismiss();
                    break;
            }
        }

        void OnSong(SongInfo song, bool isNew)
        {
            if (!song.HasData) return;
            SyncClock(song.Elapsed, pear.IsPlaying);
            if (song.ImageSrc != artUrl)
            {
                artUrl = song.ImageSrc;
                var old = artImage; artImage = null;
                if (old != null) old.Dispose();
                LoadArt(song.ImageSrc);
            }
            if (isNew)
            {
                lastKind = CardKind.NowPlaying;
                ShowNow(CardKind.NowPlaying);
            }
            else if (cardWin.IsShowing) Rerender();
            EnsureLyrics(song);
        }

        void OnPlayState(bool playing)
        {
            SyncClock(pear.Current.Elapsed, playing);
            if (cfg.ShowOnPause || cardWin.IsShowing)
            {
                lastKind = playing ? CardKind.Resumed : CardKind.Paused;
                if (cfg.ShowOnPause) ShowNow(lastKind); else Rerender();
            }
            else lastKind = playing ? CardKind.NowPlaying : CardKind.Paused;
            TickLyrics(true);
        }

        void OnPosition(double pos)
        {
            // Pear sends the player's whole-second value right as it ticks over, so it is close to exact;
            // a fractional value comes from a seek.
            SyncClock(pos + (pos == Math.Floor(pos) ? 0.05 : 0), pear.IsPlaying);
            int sec = (int)pos;
            if (sec == lastShownSecond) return;
            lastShownSecond = sec;
            if (cardWin.IsShowing) Rerender();
        }

        void SyncClock(double pos, bool playing)
        {
            basePos = pos;
            if (playing) clock.Restart(); else clock.Reset();
        }

        double PlaybackPosition { get { return basePos + clock.Elapsed.TotalSeconds; } }

        // ---- lyrics -------------------------------------------------------------

        void EnsureLyrics(SongInfo song)
        {
            var key = song.VideoId + "|" + song.Title;
            if (key == lyricsKey) return;
            lyricsKey = key;
            lyrics = null;
            lyricsLayoutKey = null;
            lyricsInfoItem.Text = "가사: 찾는 중";
            lyricsWin.Dismiss();
            if (lyricsCts != null) lyricsCts.Cancel();
            if (prefetchCts != null) prefetchCts.Cancel();
            lyricsCts = new CancellationTokenSource();
            var ct = lyricsCts.Token;
            var snapshot = song;
            Task.Run(async () =>
            {
                // LRCLIB is sometimes slow or briefly down: retry a few times while the same song plays
                var waits = new[] { 0, 15000, 45000 };
                LyricsResult r = null;
                for (int i = 0; i < waits.Length; i++)
                {
                    try
                    {
                        if (waits[i] > 0)
                        {
                            int attempt = i;
                            ui.Post(_ => { if (key == lyricsKey) lyricsInfoItem.Text = "가사: 연결 실패, 다시 시도 중 (" + attempt + "/" + (waits.Length - 1) + ")"; }, null);
                            await Task.Delay(waits[i], ct);
                        }
                        r = await lyricsProvider.Find(snapshot, ct);
                    }
                    catch (OperationCanceledException) { return; }
                    if (!r.Failed) break;
                }
                var result = r;
                ui.Post(_ =>
                {
                    if (ct.IsCancellationRequested || key != lyricsKey) return;
                    lyrics = result;
                    lyricsLayoutKey = null;
                    lyricsInfoItem.Text = result.HasSynced ? ("가사: 싱크 가사 있음 (" + result.Source + ")")
                                        : result.Instrumental ? "가사: 연주곡"
                                        : result.Failed ? "가사: 가사 서버에 연결하지 못함" : "가사: 찾지 못함";
                    if (!result.Failed) PrefetchNext(key);
                    if (announceKey == key)
                    {
                        announceKey = null;
                        if (result.Failed) ShowInfo("가사 서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요");
                        else if (result.Instrumental) ShowInfo("연주곡이에요");
                        else if (!result.HasSynced) ShowInfo("이 곡은 싱크 가사를 찾지 못했어요");
                        else ShowNow(CurrentKind());   // lyrics card appears under the song card
                    }
                    TickLyrics(true);
                }, null);
            });
        }

        void TickLyrics(bool force = false)
        {
            if (!cfg.ShowLyrics || lyrics == null || !lyrics.HasSynced || !pear.Current.HasData)
            {
                if (lyricsWin.IsPresent) lyricsWin.Dismiss();
                return;
            }

            // (re)layout when the song, size or width changed
            var layoutKey = lyricsKey + "|" + Scale.ToString("0.###") + "|" + PanelWidth;
            if (layoutKey != lyricsLayoutKey)
            {
                lyricsView.SetLines(lyrics.Lines, Scale, PanelWidth);
                lyricsLayoutKey = layoutKey;
                force = true;
            }

            int ms = (int)Math.Round(PlaybackPosition * 1000) + cfg.LyricsOffsetMs;
            int entry = lyricsView.EntryFor(lyrics.IndexAt(ms));
            bool paused = !pear.IsPlaying;

            if (!lyricsWin.IsPresent)
            {
                // appear at the right line without scrolling through everything before it
                lyricsView.SetCurrent(entry, false);
                lyricPaused = paused;
                var bmp = lyricsView.Render(paused, cfg.Opacity);
                lyricsWin.ShowCard(bmp, PlaceLyrics(bmp.Size), null);
                Reposition();
                return;
            }

            bool changed = entry != lyricsView.Current;
            if (changed) lyricsView.SetCurrent(entry, true);
            if (changed || paused != lyricPaused || force)
            {
                lyricPaused = paused;
                LyricsFrame();
                if (lyricsView.Animating) frameTimer.Start();
            }
        }

        /// <summary>One animation frame of the lyrics panel (runs at ~60fps only while it scrolls).</summary>
        void LyricsFrame()
        {
            if (!lyricsWin.IsShowing || !lyricsView.HasLines) { frameTimer.Stop(); return; }
            var bmp = lyricsView.Render(lyricPaused, cfg.Opacity);
            lyricsWin.UpdateCard(bmp, PlaceLyrics(bmp.Size));
            if (!lyricsView.Animating) frameTimer.Stop();
        }

        /// <summary>
        /// While this song plays, look up the next one in Pear's queue so its lyrics are ready when it starts.
        /// Waits a little first so quickly skipped songs don't trigger lookups.
        /// </summary>
        void PrefetchNext(string forKey)
        {
            if (!cfg.ShowLyrics) return;
            if (prefetchCts != null) prefetchCts.Cancel();
            prefetchCts = new CancellationTokenSource();
            var ct = prefetchCts.Token;
            Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(10000, ct);
                    var next = await pear.GetNextSong(ct);
                    if (next == null || ct.IsCancellationRequested) return;
                    if (next.VideoId + "|" + next.Title == forKey) return;
                    await lyricsProvider.Prefetch(next, ct);
                }
                catch (OperationCanceledException) { }
                catch (Exception ex) { Log.Write("INFO fetching ahead failed: " + ex.Message); }
            });
        }

        void RetryLyrics()
        {
            var song = pear.Current;
            if (!song.HasData) { ShowInfo("재생 중인 곡이 없어요"); return; }
            lyricsProvider.Forget(song);
            lyricsProvider.Ytm.ResetPause();
            lyricsKey = null;
            announceKey = song.VideoId + "|" + song.Title;
            ShowInfo("가사를 다시 찾는 중이에요");
            EnsureLyrics(song);
        }

        void ToggleLyrics()
        {
            cfg.ShowLyrics = !cfg.ShowLyrics;
            cfg.Save();
            if (cfg.ShowLyrics) TickLyrics(true); else lyricsWin.Dismiss();
            if (!cfg.ShowLyrics) ShowInfo("가사 표시를 껐어요");
            else if (lyrics != null && lyrics.Failed) ShowInfo("가사 서버에 연결하지 못했어요");
            else if (lyrics != null && !lyrics.HasSynced) ShowInfo("이 곡은 싱크 가사를 찾지 못했어요");
        }

        void SetOffset(int ms)
        {
            cfg.LyricsOffsetMs = ms;
            cfg.Save();
            TickLyrics(true);
        }

        // ---- card rendering ---------------------------------------------------------

        CardKind CurrentKind()
        {
            return pear.IsPlaying ? CardKind.NowPlaying : CardKind.Paused;
        }

        void ShowNow(CardKind kind)
        {
            var song = pear.Current;
            if (!song.HasData)
            {
                ShowInfo(pear.Status == PearStatus.Connected ? "재생 중인 곡이 없어요" : StatusText(pear.Status));
                return;
            }
            lastKind = kind;
            infoTimer.Stop();
            infoUntil = DateTime.MinValue;
            song.Elapsed = PlaybackPositionFor(song);
            if (!cardWin.IsPresent || kind == CardKind.NowPlaying) marquee.Restart();
            SetCardFrame(CardRenderer.BuildCard(song, kind, null, artImage, cfg.ShowAlbumArt, Scale, cfg.Opacity, PanelWidth, true));
            var bmp = cardFrame.Compose(MarqueeOffset());
            cardWin.ShowCard(bmp, PlaceCard(bmp.Size), cfg.AlwaysShow ? (double?)null : cfg.ShowSeconds);
            Reposition();
            StartMarquee();
        }

        void ShowInfo(string text)
        {
            marquee.Restart();
            SetCardFrame(CardRenderer.BuildCard(null, CardKind.Info, text, null, false, Scale, cfg.Opacity, PanelWidth, true));
            var bmp = cardFrame.Compose(MarqueeOffset());
            // While "always show" keeps the song card up, the message only borrows its place for a few seconds
            // and the song card comes back; otherwise the message fades out like a normal card.
            bool restore = cfg.AlwaysShow && pear.Current.HasData;
            double secs = restore ? 3.5 : Math.Max(3, cfg.ShowSeconds);
            cardWin.ShowCard(bmp, PlaceCard(bmp.Size), restore ? (double?)null : secs);
            infoUntil = DateTime.Now.AddSeconds(secs);
            infoTimer.Stop();
            if (restore) { infoTimer.Interval = (int)(secs * 1000); infoTimer.Start(); }
            Reposition();
            StartMarquee();
        }

        void EndInfo()
        {
            infoTimer.Stop();
            infoUntil = DateTime.MinValue;
            if (cfg.AlwaysShow && pear.Current.HasData) ShowNow(CurrentKind());
        }

        void Rerender()
        {
            var song = pear.Current;
            if (!song.HasData) return;
            if (DateTime.Now < infoUntil) return;   // a message card is up; don't paint the song over it
            var kind = lastKind;
            if (cardWin.IsPinned && kind == CardKind.Resumed) kind = CardKind.NowPlaying;
            song.Elapsed = PlaybackPositionFor(song);
            SetCardFrame(CardRenderer.BuildCard(song, kind, null, artImage, cfg.ShowAlbumArt, Scale, cfg.Opacity, PanelWidth, true));
            var bmp = cardFrame.Compose(MarqueeOffset());
            cardWin.UpdateCard(bmp, PlaceCard(bmp.Size));
            StartMarquee();
        }

        // ---- scrolling title ---------------------------------------------------------

        void SetCardFrame(CardFrame f)
        {
            var old = cardFrame;
            cardFrame = f;
            if (old != null) old.Dispose();
        }

        void StartMarquee()
        {
            if (cardFrame != null && cardFrame.Scrolls) cardFrameTimer.Start(); else cardFrameTimer.Stop();
        }

        /// <summary>Hold the start for a moment, slide left at a steady speed, loop seamlessly, hold again.</summary>
        float MarqueeOffset()
        {
            if (cardFrame == null || !cardFrame.Scrolls) return 0;
            const double hold = 1.8;
            double speed = 36 * Scale;
            double travel = cardFrame.Cycle / speed;
            double t = marquee.Elapsed.TotalSeconds % (hold + travel);
            return t < hold ? 0f : (float)((t - hold) * speed);
        }

        void CardFrameTick()
        {
            if (!cardWin.IsShowing || cardFrame == null || !cardFrame.Scrolls) { cardFrameTimer.Stop(); return; }
            var bmp = cardFrame.Compose(MarqueeOffset());
            cardWin.UpdateCard(bmp, PlaceCard(bmp.Size));
        }

        double PlaybackPositionFor(SongInfo song)
        {
            var p = PlaybackPosition;
            return song.Duration > 0 ? Math.Min(p, song.Duration) : p;
        }

        /// <summary>Glide both panels to where they belong now (after a card or lyrics panel appears or leaves).</summary>
        void Reposition()
        {
            var c = cardWin.ContentSize;
            if (!c.IsEmpty) cardWin.MoveTo(PlaceCard(c));
            var l = lyricsWin.ContentSize;
            if (!l.IsEmpty) lyricsWin.MoveTo(PlaceLyrics(l));
        }

        double Scale { get { return cfg.Scale * dpiScale; } }
        int PanelWidth { get { return (int)Math.Round(cfg.PanelWidth * Scale); } }
        int Gap { get { return (int)Math.Round(10 * Scale); } }

        // The song card and the lyrics panel form one column, lyrics always under the card.
        // Bottom corners: the lyrics sit on the margin and the card stacks above them.
        // Top corners: the card sits on the margin and the lyrics hang below it (and move up when it leaves).
        Point PlaceCard(Size size)
        {
            var b = ScreenBounds();
            int y;
            if (IsTop) y = b.Top + MarginY;
            else
            {
                var lyr = lyricsWin.IsPresent ? lyricsWin.ContentSize : Size.Empty;
                y = b.Bottom - MarginY - size.Height - (lyr.IsEmpty ? 0 : lyr.Height + Gap);
            }
            return new Point(AlignX(b, size.Width), y);
        }

        Point PlaceLyrics(Size size)
        {
            var b = ScreenBounds();
            int y;
            if (IsTop)
            {
                var card = cardWin.IsPresent ? cardWin.ContentSize : Size.Empty;
                y = b.Top + MarginY + (card.IsEmpty ? 0 : card.Height + Gap);
            }
            else y = b.Bottom - MarginY - size.Height;
            return new Point(AlignX(b, size.Width), y);
        }

        bool IsTop
        {
            get { return cfg.Position == OverlayPosition.TopLeft || cfg.Position == OverlayPosition.TopCenter || cfg.Position == OverlayPosition.TopRight; }
        }

        int MarginY { get { return (int)Math.Round(cfg.MarginY * dpiScale); } }

        int AlignX(Rectangle b, int width)
        {
            int mx = (int)Math.Round(cfg.MarginX * dpiScale);
            switch (cfg.Position)
            {
                case OverlayPosition.TopLeft: case OverlayPosition.BottomLeft: return b.Left + mx;
                case OverlayPosition.TopRight: case OverlayPosition.BottomRight: return b.Right - width - mx;
                default: return b.Left + (b.Width - width) / 2;
            }
        }

        Rectangle ScreenBounds()
        {
            var screens = Screen.AllScreens;
            return (cfg.Monitor < screens.Length ? screens[cfg.Monitor] : Screen.PrimaryScreen).Bounds;
        }

        void LoadArt(string url)
        {
            if (string.IsNullOrEmpty(url)) return;
            Task.Run(async () =>
            {
                try
                {
                    var bytes = await artHttp.GetByteArrayAsync(url);
                    Bitmap bmp;
                    using (var ms = new MemoryStream(bytes))
                    using (var img = Image.FromStream(ms)) bmp = new Bitmap(img);
                    ui.Post(_ =>
                    {
                        if (url != artUrl) { bmp.Dispose(); return; }
                        var old = artImage; artImage = bmp;
                        if (old != null) old.Dispose();
                        if (cardWin.IsShowing) Rerender();
                    }, null);
                }
                catch (Exception ex) { Log.Error("album art", ex); }
            });
        }

        // ---- menu actions --------------------------------------------------------

        void TogglePin()
        {
            cfg.AlwaysShow = !cfg.AlwaysShow;
            cfg.Save();
            if (cfg.AlwaysShow) ShowNow(CurrentKind());
            else if (cardWin.IsShowing) ShowNow(lastKind == CardKind.Resumed ? CardKind.NowPlaying : lastKind);
        }

        void SetPosition(OverlayPosition p)
        {
            cfg.Position = p;
            cfg.Save();
            TickLyrics(true);
            ShowNow(CurrentKind());
        }

        void SetScale(double v)
        {
            cfg.Scale = v;
            cfg.Save();
            TickLyrics(true);
            ShowNow(CurrentKind());
        }

        void ApplyLyricsSources()
        {
            lyricsProvider.UseYtm = cfg.YtmLyrics;
            lyricsProvider.Ytm.ProxyBase = string.IsNullOrWhiteSpace(cfg.YtmLyricsProxy) ? YtmLyrics.DefaultProxy : cfg.YtmLyricsProxy.Trim();
        }

        void ToggleYtmLyrics()
        {
            cfg.YtmLyrics = !cfg.YtmLyrics;
            cfg.Save();
            ApplyLyricsSources();
            lyricsProvider.Ytm.ResetPause();
            ShowInfo(cfg.YtmLyrics ? "YouTube Music 가사를 먼저 찾아요" : "LRCLIB에서만 가사를 찾아요");
        }

        void ReloadConfig()
        {
            var old = cfg;
            cfg = Config.Load();
            RegisterHotkeys();
            lyricsProvider.BaseUrl = (cfg.LyricsServer ?? "https://lrclib.net").TrimEnd('/');
            ApplyLyricsSources();
            if (old.Host != cfg.Host || old.Port != cfg.Port || old.Https != cfg.Https) pear.Reconnect(cfg);
            TickLyrics(true);
            ShowNow(CurrentKind());
        }

        void RegisterHotkeys()
        {
            hotkeys.UnregisterAll();
            var errors = new[]
            {
                hotkeys.Register(cfg.HotkeyShow, () => ShowNow(CurrentKind())),
                hotkeys.Register(cfg.HotkeyToggle, () => pear.TogglePlay()),
                hotkeys.Register(cfg.HotkeyNext, () => pear.Next()),
                hotkeys.Register(cfg.HotkeyPrevious, () => pear.Previous()),
                hotkeys.Register(cfg.HotkeyAlwaysShow, TogglePin),
                hotkeys.Register(cfg.HotkeyLyrics, ToggleLyrics),
            }.Where(e => e != null).ToArray();
            if (errors.Length > 0) Balloon("단축키를 등록하지 못했어요: " + string.Join(", ", errors));
        }

        void SyncMenuChecks()
        {
            pinItem.Checked = cfg.AlwaysShow;
            lyricsItem.Checked = cfg.ShowLyrics;
            ytmLyricsItem.Checked = cfg.YtmLyrics;
            foreach (ToolStripMenuItem it in offsetMenu.DropDownItems) it.Checked = (int)it.Tag == cfg.LyricsOffsetMs;
            foreach (ToolStripMenuItem it in posMenu.DropDownItems) it.Checked = (OverlayPosition)it.Tag == cfg.Position;
            foreach (ToolStripMenuItem it in sizeMenu.DropDownItems) it.Checked = Math.Abs((double)it.Tag - cfg.Scale) < 0.01;
        }

        static void OpenFile(string path)
        {
            try
            {
                if (!File.Exists(path)) File.WriteAllText(path, "");
                Process.Start("notepad.exe", "\"" + path + "\"");
            }
            catch (Exception ex) { Log.Error("open " + path, ex); }
        }

        void Balloon(string text)
        {
            try { tray.ShowBalloonTip(4000, "Pear Now Playing", text, ToolTipIcon.Info); } catch { }
        }

        static string StatusText(PearStatus s)
        {
            switch (s)
            {
                case PearStatus.Waiting: return "Pear Desktop 기다리는 중 (API 서버 확인)";
                case PearStatus.Authorizing: return "Pear Desktop에서 허용 대기 중";
                case PearStatus.Denied: return "Pear Desktop에서 연결 거부됨";
                case PearStatus.Connected: return "Pear Desktop에 연결됨";
                default: return "연결 준비 중";
            }
        }

        static string PositionName(OverlayPosition p)
        {
            switch (p)
            {
                case OverlayPosition.TopLeft: return "왼쪽 위";
                case OverlayPosition.TopCenter: return "가운데 위";
                case OverlayPosition.TopRight: return "오른쪽 위";
                case OverlayPosition.BottomLeft: return "왼쪽 아래";
                case OverlayPosition.BottomCenter: return "가운데 아래";
                default: return "오른쪽 아래";
            }
        }

        static string Truncate(string s, int max) { return s.Length <= max ? s : s.Substring(0, max); }

        protected override void ExitThreadCore()
        {
            try { tray.Visible = false; } catch { }
            try { lyricsTimer.Stop(); frameTimer.Stop(); cardFrameTimer.Stop(); infoTimer.Stop(); if (lyricsCts != null) lyricsCts.Cancel(); if (prefetchCts != null) prefetchCts.Cancel(); } catch { }
            try { pear.Dispose(); } catch { }
            try { hotkeys.Dispose(); } catch { }
            try { cardWin.Close(); cardWin.Dispose(); lyricsWin.Close(); lyricsWin.Dispose(); } catch { }
            try { tray.Dispose(); menu.Dispose(); artHttp.Dispose(); lyricsProvider.Dispose(); } catch { }
            base.ExitThreadCore();
        }
    }
}
