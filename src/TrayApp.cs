using System;
using System.Collections.Generic;
using Microsoft.Win32;
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
        // one song card and one lyrics panel per widget (monitor); see RebuildWidgets
        readonly OverlayGroup cardWin = new OverlayGroup(), lyricsWin = new OverlayGroup();
        List<WidgetPlace> shown = new List<WidgetPlace>();   // the widgets on monitors that are connected now
        readonly Hotkeys hotkeys;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip menu;
        readonly ToolStripMenuItem statusItem, pinItem, lyricsItem, albumOnlyItem, retryLyricsItem, lyricsInfoItem, offsetMenu, sizeMenu, displayMenu, placeMenu, transparencyMenu, moveItem, titleMenu;
        readonly HttpClient artHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        readonly Updater updater = new Updater();
        readonly ToolStripMenuItem updateItem, sourceMenu, retryAuthItem, discordMenu, discordItem, discordButtonItem;
        readonly DiscordPresence discord = new DiscordPresence();
        UpdateInfo update;          // a newer release found on GitHub
        string announcedUpdate;     // told the user about this version already
        bool installing;
        readonly SynchronizationContext ui;
        readonly double dpiScale;
        readonly System.Windows.Forms.Timer lyricsTimer = new System.Windows.Forms.Timer { Interval = 100 };
        readonly System.Windows.Forms.Timer frameTimer = new System.Windows.Forms.Timer { Interval = 15 };
        readonly System.Windows.Forms.Timer cardFrameTimer = new System.Windows.Forms.Timer { Interval = 16 };
        // a short message card (ShowInfo) temporarily takes the song card's place; this brings the song back
        readonly System.Windows.Forms.Timer infoTimer = new System.Windows.Forms.Timer();
        DateTime infoUntil = DateTime.MinValue;
        readonly Stopwatch marquee = new Stopwatch();
        // One look per distinct widget size: the card and the lyrics are drawn once per size and every window of
        // that size gets the picture (see PerLook). All lyrics views get the same calls, so the first answers for all.
        readonly List<double> lookScales = new List<double>();
        readonly List<LyricsView> lyricsViews = new List<LyricsView>();
        readonly List<CardFrame> cardFrames = new List<CardFrame>();
        LyricsView MainView { get { return lyricsViews[0]; } }

        string artUrl;
        Image artImage;
        CardKind lastKind = CardKind.NowPlaying;
        int lastShownSecond = -1;
        bool everConnected;

        // lyrics state
        LyricsResult lyrics;
        string lyricsKey;
        string lyricsViewSong;      // the song whose lyrics the lyrics view last laid out
        List<LyricLine> nextLines;  // the next song's lyrics (fetched ahead), shown below this song's last line
        string nextLinesFor;        // the lyricsKey they were fetched after
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

            ResetWidgetWindows();
            lyricsWin.FadedOut += (s, e) => Reposition();
            cardWin.FadedOut += (s, e) => Reposition();
            foreach (var g in new[] { cardWin, lyricsWin })
            {
                g.DragBegan += BeginDrag;
                g.Dragged += DragTo;
                g.DragEnded += EndDrag;
            }
            // monitors plugged in or out: widgets for monitors that are gone are hidden (and come back with them)
            SystemEvents.DisplaySettingsChanged += OnDisplaysChanged;

            // tray menu
            menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem("연결 준비 중") { Enabled = false };
            lyricsInfoItem = new ToolStripMenuItem("가사: -") { Enabled = false };
            pinItem = new ToolStripMenuItem("곡 정보 계속 표시", null, (s, e) => TogglePin());
            lyricsItem = new ToolStripMenuItem("가사 표시", null, (s, e) => ToggleLyrics());
            albumOnlyItem = new ToolStripMenuItem("앨범 곡만 가사 표시", null, (s, e) => ToggleAlbumOnly());
            retryLyricsItem = new ToolStripMenuItem("가사 다시 찾기", null, (s, e) => RetryLyrics());
            offsetMenu = new ToolStripMenuItem("가사 타이밍");
            foreach (var pair in new[] { Tuple.Create("1초 빠르게", 1300), Tuple.Create("0.5초 빠르게", 800), Tuple.Create("기본", 300),
                                         Tuple.Create("0.5초 늦게", -200), Tuple.Create("1초 늦게", -700) })
            {
                var v = pair.Item2;
                offsetMenu.DropDownItems.Add(new ToolStripMenuItem(pair.Item1, null, (s, e) => SetOffset(v)) { Tag = v });
            }
            // filled when the menu opens (screens and widgets can change)
            displayMenu = new ToolStripMenuItem("표시");
            placeMenu = new ToolStripMenuItem("위치");
            sizeMenu = new ToolStripMenuItem("크기");
            transparencyMenu = new ToolStripMenuItem("투명도");
            foreach (var m in new[] { displayMenu, placeMenu, sizeMenu, transparencyMenu }) m.DropDownItems.Add(new ToolStripMenuItem("-"));
            moveItem = new ToolStripMenuItem("위젯 끌어서 옮기기", null, (s, e) => SetMoveMode(!moveMode));
            titleMenu = new ToolStripMenuItem("영상 곡 제목");
            titleMenu.DropDownItems.Add(new ToolStripMenuItem("곡 제목", null, (s, e) => SetVideoTitle(false)) { Tag = false });
            titleMenu.DropDownItems.Add(new ToolStripMenuItem("영상 제목", null, (s, e) => SetVideoTitle(true)) { Tag = true });

            // widget (song card, where and how big) and lyrics settings live in separate submenus
            var widgetMenu = new ToolStripMenuItem("위젯");
            widgetMenu.DropDownItems.AddRange(new ToolStripItem[] { pinItem, titleMenu, displayMenu, placeMenu, sizeMenu, transparencyMenu, new ToolStripSeparator(), moveItem });
            var lyricsMenu = new ToolStripMenuItem("가사");
            lyricsMenu.DropDownItems.AddRange(new ToolStripItem[] { lyricsItem, albumOnlyItem, retryLyricsItem, offsetMenu });
            // where songs come from (same items as the macOS version's 재생 앱 menu)
            sourceMenu = new ToolStripMenuItem("재생 앱");
            foreach (var pair in new[] { Tuple.Create("auto", "자동 (브라우저, Pear Desktop)"), Tuple.Create("browser", "브라우저"), Tuple.Create("pear", "Pear Desktop") })
            {
                var v = pair.Item1;
                sourceMenu.DropDownItems.Add(new ToolStripMenuItem(pair.Item2, null, (s, e) => SetSource(v)) { Tag = v });
            }
            // Discord's "Listening to" for the browser's songs (same items as the macOS version)
            discordItem = new ToolStripMenuItem("듣는 중 표시", null, (s, e) => { cfg.DiscordPresence = !cfg.DiscordPresence; cfg.Save(); SyncDiscord();
                ShowInfo(cfg.DiscordPresence ? "듣는 곡을 Discord에 표시합니다" : "Discord에 듣는 곡을 표시하지 않습니다"); });
            discordButtonItem = new ToolStripMenuItem("GitHub 버튼 표시", null, (s, e) => { cfg.DiscordButton = !cfg.DiscordButton; cfg.Save(); SyncDiscord(); });
            discordMenu = new ToolStripMenuItem("Discord");
            discordMenu.DropDownItems.AddRange(new ToolStripItem[] { discordItem, discordButtonItem });
            retryAuthItem = new ToolStripMenuItem("Pear Desktop 연결 요청", null, (s, e) => { Config.WriteToken(null); pear.RetryAuth(); });

            // at the top, so a new version ("업데이트 설치 (x.y.z)") is seen first
            updateItem = new ToolStripMenuItem("업데이트 확인", null, (s, e) => UpdateClicked());
            menu.Items.Add(updateItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(statusItem);
            menu.Items.Add(lyricsInfoItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("지금 곡 보기", null, (s, e) => ShowNow(CurrentKind())));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("이전 곡", null, (s, e) => pear.Previous()));
            menu.Items.Add(new ToolStripMenuItem("재생 / 일시정지", null, (s, e) => pear.TogglePlay()));
            menu.Items.Add(new ToolStripMenuItem("다음 곡", null, (s, e) => pear.Next()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(widgetMenu);
            menu.Items.Add(lyricsMenu);
            menu.Items.Add(sourceMenu);
            menu.Items.Add(discordMenu);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(retryAuthItem);
            menu.Items.Add(new ToolStripMenuItem("설정 파일 열기", null, (s, e) => OpenFile(Config.FilePath)));
            menu.Items.Add(new ToolStripMenuItem("설정 다시 불러오기", null, (s, e) => ReloadConfig()));
            menu.Items.Add(new ToolStripMenuItem("오류 기록 열기", null, (s, e) => OpenFile(Config.LogPath)));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("종료", null, (s, e) => ExitThread()));
            menu.Opening += (s, e) => SyncMenuChecks();

            tray = new NotifyIcon
            {
                Icon = CardRenderer.MakeTrayIcon(32),
                Text = "Now Playing Widget",
                ContextMenuStrip = menu,
                Visible = true
            };
            tray.DoubleClick += (s, e) => ShowNow(CurrentKind());

            hotkeys = new Hotkeys();
            RegisterHotkeys();

            lyricsProvider = new LyricsProvider(cfg.LyricsServer) { Ytm = new YtmLyrics(), More = new MoreLyrics(), Disk = new LyricsDiskCache(LyricsDiskCache.DefaultDir) };
            ApplyLyricsSources();
            lyricsTimer.Tick += (s, e) => TickLyrics();
            lyricsTimer.Start();
            frameTimer.Tick += (s, e) => LyricsFrame();
            cardFrameTimer.Tick += (s, e) => CardFrameTick();
            infoTimer.Tick += (s, e) => EndInfo();

            pear = new PearClient(ui, cfg, lyricsProvider.Ytm);
            pear.StatusChanged += OnStatus;
            pear.StatusLineChanged += OnStatusLine;
            pear.Notice += ShowInfo;
            pear.SongUpdated += OnSong;
            pear.PlayStateChanged += OnPlayState;
            pear.PositionChanged += OnPosition;
            pear.Start();
            StartUpdateChecks();
        }

        // ---- pear events -----------------------------------------------------

        void OnStatusLine()
        {
            statusItem.Text = pear.StatusLine;
            tray.Text = Truncate("Now Playing Widget - " + pear.StatusLine, 63);
            SyncDiscord();
        }

        /// <summary>
        /// Discord's "Listening to": the song shown while it plays (from the browser or Pear Desktop; with Pear's own Discord
        /// plugin on too, Discord gets two and picks one), nothing otherwise. DiscordPresence sends only real changes (a
        /// new song, play / pause, a seek), so this can be called on every position.
        /// </summary>
        void SyncDiscord()
        {
            var song = pear.Current;
            if (!cfg.DiscordPresence || !song.HasData || !pear.IsPlaying || song.Duration <= 0)
            {
                discord.Show(null);
                return;
            }
            var start = DateTime.UtcNow.AddSeconds(-PlaybackPosition);
            discord.Show(new DiscordActivity
            {
                Title = ForCard(song).Title, Artist = song.Artist, Album = song.Album, ImageUrl = song.ImageSrc ?? "", VideoId = song.VideoId ?? "",
                Start = start, End = start.AddSeconds(song.Duration), Button = cfg.DiscordButton,
            });
        }

        void OnStatus(PearStatus s)
        {
            switch (s)
            {
                case PearStatus.Authorizing:
                    Balloon("Pear Desktop에 연결 요청 창이 나타났습니다. '허용'을 눌러 주십시오.");
                    ShowInfo("Pear Desktop에서 '허용'을 눌러 주십시오");
                    break;
                case PearStatus.Denied:
                    Balloon("Pear Desktop에서 연결이 거부되었습니다. 트레이 메뉴의 'Pear Desktop 연결 요청'으로 다시 시도할 수 있습니다.");
                    break;
                case PearStatus.Connected:
                    if (!everConnected)
                    {
                        everConnected = true;
                        if (!pear.Current.HasData) ShowInfo("Pear Desktop에 연결되었습니다");
                    }
                    break;
                case PearStatus.Waiting:
                    if (pear.Source != SongSource.Pear) break;   // the browser's song is shown
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
            SyncDiscord();
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
            SyncDiscord();
        }

        void OnPosition(double pos)
        {
            // Pear sends the player's whole-second value right as it ticks over, so it is close to exact;
            // a fractional value comes from a seek.
            SyncClock(pos + (pos == Math.Floor(pos) ? 0.05 : 0), pear.IsPlaying);
            SyncDiscord();
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
            lyricsLayoutKey = null;
            if (lyricsCts != null) lyricsCts.Cancel();
            if (prefetchCts != null) prefetchCts.Cancel();
            // already known (fetched ahead, cached): swap the lyrics in place, so the lyrics card doesn't close and
            // reopen (which made the song card drop down and come back up)
            var known = WantsLyrics(song) ? lyricsProvider.Known(song) : null;
            if (known != null)
            {
                ApplyLyrics(key, song, known);
                // found on Kugou / NetEase: LRCLIB was busy then, or may have the song by now
                if (lyricsProvider.ShouldRecheck(song, known)) LookUp(key, song, known);
                return;
            }
            lyrics = null;
            lyricsInfoItem.Text = "가사: 찾는 중";
            lyricsWin.Dismiss();
            if (!WantsLyrics(song))
            {
                // "앨범 곡만 가사 표시": not an album track, so no lookup at all
                lyricsInfoItem.Text = "가사: 앨범 곡이 아니라 찾지 않음";
                if (announceKey == key) { announceKey = null; ShowInfo("앨범 곡이 아니어서 가사를 표시하지 않습니다"); }
                PrefetchNext(key);
                return;
            }
            LookUp(key, song, null);
        }

        /// <summary>
        /// Look up the song's lyrics, and while it plays retry when LRCLIB was busy (or unreachable). Lyrics found on
        /// Kugou / NetEase are shown at once when LRCLIB should be asked again (it was busy, or it may have the song
        /// by now: ShouldRecheck), and LRCLIB alone is asked: its lyrics replace them, its "none" keeps them.
        /// </summary>
        /// <param name="shown">Kugou / NetEase lyrics already on screen to ask LRCLIB about at once, or null</param>
        void LookUp(string key, SongInfo song, LyricsResult shown)
        {
            lyricsCts = new CancellationTokenSource();
            var ct = lyricsCts.Token;
            var snapshot = song;
            Task.Run(async () =>
            {
                // LRCLIB is sometimes busy or briefly down: keep asking while the same song plays, as often as its
                // Retry-After allows (up to 10 minutes, e.g. while paused)
                var until = DateTime.UtcNow.AddMinutes(10);
                LyricsResult r = null;
                for (int i = 0; i == 0 || DateTime.UtcNow < until; i++)
                {
                    try
                    {
                        if (i > 0)
                        {
                            int attempt = i;
                            if (shown == null)
                                ui.Post(_ => { if (key == lyricsKey) lyricsInfoItem.Text = "가사: 연결 실패, 다시 시도 중 (" + attempt + ")"; }, null);
                            await Task.Delay(lyricsProvider.RetryWait, ct);
                        }
                        r = shown != null ? await lyricsProvider.Recheck(snapshot, ct) : await lyricsProvider.Find(snapshot, ct);
                    }
                    catch (OperationCanceledException) { return; }
                    if (shown != null) { if (r != null) break; continue; }   // null: LRCLIB still busy
                    if (r.Failed) continue;
                    if (!lyricsProvider.ShouldRecheck(snapshot, r)) break;
                    // a stand-in for a busy LRCLIB: shown now, LRCLIB asked again later
                    shown = r;
                    Log.Info("LRCLIB busy: showing " + r.Source + " lyrics meanwhile, asking LRCLIB again later");
                    var standIn = r;
                    ui.Post(_ =>
                    {
                        if (ct.IsCancellationRequested || key != lyricsKey) return;
                        ApplyLyrics(key, snapshot, standIn);
                    }, null);
                }
                // LRCLIB still busy, or has none: the lyrics shown stay (no need to lay them out again)
                if (shown != null && (r == null || r.Lines == shown.Lines)) return;
                var result = r;
                ui.Post(_ =>
                {
                    if (ct.IsCancellationRequested || key != lyricsKey) return;
                    ApplyLyrics(key, snapshot, result);
                }, null);
            });
        }

        /// <summary>A lookup's result for the current song: status line, look-ahead, title, and the lyrics card.</summary>
        void ApplyLyrics(string key, SongInfo song, LyricsResult result)
        {
            lyrics = result;
            lyricsLayoutKey = null;
            lyricsInfoItem.Text = result.HasSynced ? ("가사: 싱크 가사 있음 (" + result.Source + ")")
                                : result.Instrumental ? "가사: 연주곡"
                                : result.Failed ? "가사: 가사 서버에 연결하지 못함" : "가사: 찾지 못함";
            if (!result.Failed) PrefetchNext(key);
            UpdateDisplayTitle(song);
            if (announceKey == key)
            {
                announceKey = null;
                if (result.Failed) ShowInfo("가사 서버에 연결하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오");
                else if (result.Instrumental) ShowInfo("연주곡입니다");
                else if (!result.HasSynced) ShowInfo("이 곡의 싱크 가사를 찾지 못했습니다");
                else ShowNow(CurrentKind());   // lyrics card appears under the song card
            }
            TickLyrics(true);
            Reposition();   // the new lyrics may be taller or shorter than the last song's
        }

        void TickLyrics(bool force = false)
        {
            if (!cfg.ShowLyrics || lyrics == null || !lyrics.HasSynced || !pear.Current.HasData)
            {
                if (lyricsWin.IsPresent) lyricsWin.Dismiss();
                return;
            }

            // (re)layout when the song, size or width changed
            var layoutKey = lyricsKey + "|" + string.Join(",", lookScales.Select(v => v.ToString("0.###"))) + "|" + cfg.PanelWidth;
            if (layoutKey != lyricsLayoutKey)
            {
                // the next song's lyrics while the panel is open: scroll on from the last song's line
                bool carry = lyricsWin.IsPresent && lyricsViewSong != null && lyricsViewSong != lyricsKey;
                for (int k = 0; k < lyricsViews.Count; k++)
                {
                    lyricsViews[k].SetLines(lyrics.Lines, lookScales[k], PanelWidthFor(lookScales[k]), carry);
                    lyricsViews[k].SetNext(nextLinesFor == lyricsKey ? nextLines : null);
                }
                lyricsViewSong = lyricsKey;
                lyricsLayoutKey = layoutKey;
                force = true;
            }

            int ms = (int)Math.Round(PlaybackPosition * 1000) + cfg.LyricsOffsetMs;
            int entry = MainView.EntryFor(lyrics.IndexAt(ms));
            bool paused = !pear.IsPlaying;

            if (!lyricsWin.IsPresent)
            {
                // appear at the right line without scrolling through everything before it
                foreach (var v in lyricsViews) v.SetCurrent(entry, false);
                lyricPaused = paused;
                lyricsWin.ShowCard(PerLook(k => lyricsViews[k].Render(paused, cfg.Opacity)), PlaceLyrics, null);
                Reposition();
                return;
            }

            bool changed = entry != MainView.Current;
            if (changed) foreach (var v in lyricsViews) v.SetCurrent(entry, true);
            if (changed || paused != lyricPaused || force)
            {
                lyricPaused = paused;
                LyricsFrame();
                if (MainView.Animating) frameTimer.Start();
            }
        }

        /// <summary>One animation frame of the lyrics panel (runs at ~60fps only while it scrolls).</summary>
        void LyricsFrame()
        {
            if (!lyricsWin.IsShowing || !MainView.HasLines) { frameTimer.Stop(); return; }
            lyricsWin.UpdateCard(PerLook(k => lyricsViews[k].Render(lyricPaused, cfg.Opacity)), PlaceLyrics);
            if (!MainView.Animating) frameTimer.Stop();
        }

        /// <summary>
        /// While this song plays, look up the next one in Pear's queue so its lyrics are ready when it starts.
        /// Waits a little first so quickly skipped songs don't trigger lookups. LRCLIB's "busy" answers usually clear
        /// within seconds, so a failed look-ahead is tried again later in the song instead of when the next one starts.
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
                    foreach (var wait in new[] { 10000, 30000, 90000 })
                    {
                        await Task.Delay(wait, ct);
                        var next = await pear.GetNextSong(ct);   // asked each time: the queue may have changed
                        if (next == null || ct.IsCancellationRequested) return;
                        if (next.VideoId + "|" + next.Title == forKey) return;
                        if (cfg.LyricsAlbumOnly)
                        {
                            // the queue doesn't say whether it's an album track; YouTube Music does (this is the
                            // lookup's first request anyway, remembered for when the song starts)
                            if (!cfg.YtmLyrics) return;
                            var track = await lyricsProvider.Ytm.Lookup(next.VideoId, ct);
                            if (track.VideoType != "MUSIC_VIDEO_TYPE_ATV") return;
                            next.MediaType = "AUDIO";
                        }
                        if (await lyricsProvider.Prefetch(next, ct))
                        {
                            var known = lyricsProvider.Ahead(next);
                            if (known != null && known.HasSynced)
                                ui.Post(_ =>
                                {
                                    if (ct.IsCancellationRequested || forKey != lyricsKey) return;
                                    ShowNextLines(known.Lines);
                                }, null);
                            return;
                        }
                        Log.Info("fetching ahead failed (lyrics server busy or unreachable), will try again while this song plays");
                    }
                }
                catch (OperationCanceledException) { }
                catch (Exception ex) { Log.Write("INFO fetching ahead failed: " + ex.Message); }
            });
        }

        /// <summary>The next song's lyrics below this song's, so its first lines come into view as this one ends.</summary>
        void ShowNextLines(List<LyricLine> lines)
        {
            nextLines = lines;
            nextLinesFor = lyricsKey;
            if (lyricsLayoutKey == null || !MainView.HasLines) return;   // laid out with them when it happens
            foreach (var v in lyricsViews) v.SetNext(lines);
            TickLyrics(true);
        }

        void RetryLyrics()
        {
            var song = pear.Current;
            if (!song.HasData) { ShowInfo("재생 중인 곡이 없습니다"); return; }
            lyricsProvider.Forget(song);
            lyricsProvider.Ytm.ResetPause();
            lyricsProvider.More.ResetPause();
            lyricsKey = null;
            announceKey = song.VideoId + "|" + song.Title;
            ShowInfo("가사를 다시 찾고 있습니다");
            EnsureLyrics(song);
        }

        /// <summary>Whether this song's lyrics are wanted ("앨범 곡만 가사 표시" skips everything but album tracks).</summary>
        bool WantsLyrics(SongInfo song)
        {
            return !cfg.LyricsAlbumOnly || song.MediaType == "AUDIO";
        }

        void ToggleAlbumOnly()
        {
            cfg.LyricsAlbumOnly = !cfg.LyricsAlbumOnly;
            cfg.Save();
            ShowInfo(cfg.LyricsAlbumOnly ? "앨범 곡에서만 가사를 표시합니다" : "모든 곡에서 가사를 표시합니다");
            lyricsKey = null;   // decide again for the current song
            if (pear.Current.HasData) EnsureLyrics(pear.Current);
        }

        void ToggleLyrics()
        {
            cfg.ShowLyrics = !cfg.ShowLyrics;
            cfg.Save();
            if (cfg.ShowLyrics) TickLyrics(true); else lyricsWin.Dismiss();
            if (!cfg.ShowLyrics) ShowInfo("가사 표시를 껐습니다");
            else if (lyrics != null && lyrics.Failed) ShowInfo("가사 서버에 연결하지 못했습니다");
            else if (lyrics != null && !lyrics.HasSynced) ShowInfo("이 곡의 싱크 가사를 찾지 못했습니다");
        }

        void SetOffset(int ms)
        {
            cfg.LyricsOffsetMs = ms;
            cfg.Save();
            TickLyrics(true);
        }

        // ---- updates ---------------------------------------------------------------------
        // GitHub's latest release is checked 30 s after start and then daily ("checkUpdates"); installing happens
        // only when the user picks it from the menu, never mid-game on its own.

        void StartUpdateChecks()
        {
            Task.Run(async () =>
            {
                await Task.Delay(30000);
                while (true)
                {
                    if (cfg.CheckUpdates) await CheckForUpdate(false);
                    await Task.Delay(TimeSpan.FromHours(24));
                }
            });
        }

        async Task CheckForUpdate(bool manual)
        {
            try
            {
                var found = await updater.Check(AppInfo.Version, CancellationToken.None);
                ui.Post(_ =>
                {
                    update = found;
                    if (found != null)
                    {
                        Log.Info("update available: " + found.Version + " (" + found.AssetName + ")");
                        if (manual || found.Version != announcedUpdate)
                        {
                            announcedUpdate = found.Version;
                            ShowInfo("새 버전 " + found.Version + "이 나왔습니다. 메뉴에서 업데이트할 수 있습니다");
                        }
                    }
                    else if (manual) ShowInfo("최신 버전입니다 (" + AppInfo.Version + ")");
                }, null);
            }
            catch (Exception ex)
            {
                Log.Write("INFO update check failed: " + (ex is OperationCanceledException ? "timeout" : ex.Message));
                if (manual) ui.Post(_ => ShowInfo("업데이트를 확인하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오"), null);
            }
        }

        void UpdateClicked()
        {
            if (update == null) { ShowInfo("업데이트를 확인하고 있습니다"); Task.Run(() => CheckForUpdate(true)); return; }
            if (installing) return;
            installing = true;
            var target = update;
            var exe = Application.ExecutablePath;
            ShowInfo("업데이트를 받고 있습니다 (" + target.Version + ")");
            Task.Run(async () =>
            {
                try
                {
                    var dir = Path.Combine(Path.GetTempPath(), "NowPlayingWidget-update-" + target.Version);
                    var zip = await updater.Download(target, dir, CancellationToken.None);
                    Updater.Install(zip, exe, target.Version);
                    Log.Info("updated to " + target.Version + ", restarting");
                    ui.Post(_ =>
                    {
                        Process.Start(exe, "--wait-for " + Process.GetCurrentProcess().Id);
                        ExitThread();
                    }, null);
                }
                catch (Exception ex)
                {
                    Log.Write("WARN update to " + target.Version + " failed: " + ex.GetType().Name + ": " + ex.Message);
                    ui.Post(_ =>
                    {
                        installing = false;
                        ShowInfo("업데이트하지 못했습니다. 릴리스 페이지를 엽니다");
                        try { Process.Start(target.PageUrl); } catch (Exception e2) { Log.Error("open release page", e2); }
                    }, null);
                }
            });
        }

        // ---- album track titles -----------------------------------------------------------

        /// <summary>
        /// The song as the card shows it: an album track whose title Pear gives only as a translation is shown as
        /// "original - translation" (see CoverLyrics.DisplayTitle), once YouTube Music's queue entry is known.
        /// </summary>
        SongInfo ForCard(SongInfo song)
        {
            // videos (MVs, covers, uploads): the song title, or the video's own title if the user prefers it
            if (song.MediaType != "AUDIO")
                return cfg.VideoTitle && !string.IsNullOrWhiteSpace(song.AltTitle) && song.AltTitle != song.Title ? song.WithTitle(song.AltTitle) : song;
            var track = lyricsProvider.Ytm.Known(song.VideoId);
            if (track == null) return song;
            var title = CoverLyrics.DisplayTitle(song.Title, track.Title);
            return title == song.Title ? song : song.WithTitle(title);
        }

        /// <summary>
        /// After the lyrics lookup: its YouTube Music answer carries the queue title, so show it. If the lyrics came
        /// from a cache without asking YouTube Music, or the relay was paused, ask for the title alone (once per video
        /// and session). The title comes from music.youtube.com itself, not the relay, so the pause doesn't apply.
        /// </summary>
        void UpdateDisplayTitle(SongInfo song)
        {
            if (song.MediaType != "AUDIO" || string.IsNullOrEmpty(song.VideoId)) return;
            if (lyricsProvider.Ytm.Known(song.VideoId) != null) { if (cardWin.IsShowing) Rerender(); return; }
            if (!cfg.YtmLyrics) return;
            var ct = lyricsCts != null ? lyricsCts.Token : CancellationToken.None;
            Task.Run(async () =>
            {
                try { await lyricsProvider.Ytm.Lookup(song.VideoId, ct, false); }
                catch (OperationCanceledException) { return; }
                catch (Exception ex) { Log.Write("INFO title lookup failed for " + song.VideoId + ": " + ex.Message); return; }
                ui.Post(_ => { if (pear.Current.VideoId == song.VideoId && cardWin.IsShowing) Rerender(); }, null);
            });
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
                ShowInfo(pear.IsConnected ? "재생 중인 곡이 없습니다" : pear.StatusLine);
                return;
            }
            lastKind = kind;
            infoTimer.Stop();
            infoUntil = DateTime.MinValue;
            song.Elapsed = PlaybackPositionFor(song);
            if (!cardWin.IsPresent || kind == CardKind.NowPlaying) marquee.Restart();
            var forCard = ForCard(song);
            BuildCards(scale => CardRenderer.BuildCard(forCard, kind, null, artImage, cfg.ShowAlbumArt, scale, cfg.Opacity, PanelWidthFor(scale), true));
            cardWin.ShowCard(PerLook(ComposeCard), PlaceCard, KeepCard ? (double?)null : cfg.ShowSeconds);
            Reposition();
            StartMarquee();
        }

        void ShowInfo(string text)
        {
            marquee.Restart();
            BuildCards(scale => CardRenderer.BuildCard(null, CardKind.Info, text, null, false, scale, cfg.Opacity, PanelWidthFor(scale), true));
            // While "always show" keeps the song card up, the message only borrows its place for a few seconds
            // and the song card comes back; otherwise the message fades out like a normal card.
            bool restore = KeepCard && pear.Current.HasData;
            double secs = restore ? 3.5 : Math.Max(3, cfg.ShowSeconds);
            // while dragging the widget around, a message with no song behind it stays until the mode ends
            cardWin.ShowCard(PerLook(ComposeCard), PlaceCard, restore || moveMode ? (double?)null : secs);
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
            if (KeepCard && pear.Current.HasData) ShowNow(CurrentKind());
        }

        /// <summary>The song card stays up: "always show", or the widget is being moved.</summary>
        bool KeepCard { get { return cfg.AlwaysShow || moveMode; } }

        void Rerender()
        {
            var song = pear.Current;
            if (!song.HasData) return;
            if (DateTime.Now < infoUntil) return;   // a message card is up; don't paint the song over it
            var kind = lastKind;
            if (cardWin.IsPinned && kind == CardKind.Resumed) kind = CardKind.NowPlaying;
            song.Elapsed = PlaybackPositionFor(song);
            var forCard = ForCard(song);
            BuildCards(scale => CardRenderer.BuildCard(forCard, kind, null, artImage, cfg.ShowAlbumArt, scale, cfg.Opacity, PanelWidthFor(scale), true));
            cardWin.UpdateCard(PerLook(ComposeCard), PlaceCard);
            StartMarquee();
        }

        // ---- scrolling title ---------------------------------------------------------

        /// <summary>The card at every look's size.</summary>
        void BuildCards(Func<double, CardFrame> build)
        {
            var old = cardFrames.ToList();
            cardFrames.Clear();
            foreach (var scale in lookScales) cardFrames.Add(build(scale));
            foreach (var f in old) f.Dispose();
        }

        Bitmap ComposeCard(int look) { return cardFrames[look].Compose(MarqueeOffset(look)); }

        bool CardScrolls { get { return cardFrames.Any(f => f.Scrolls); } }

        void StartMarquee()
        {
            if (CardScrolls) cardFrameTimer.Start(); else cardFrameTimer.Stop();
        }

        /// <summary>Hold the start for a moment, slide left at a steady speed, loop seamlessly, hold again.</summary>
        float MarqueeOffset(int look)
        {
            var cardFrame = cardFrames[look];
            if (!cardFrame.Scrolls) return 0;
            const double hold = 1.8;
            double speed = 36 * lookScales[look];
            double travel = cardFrame.Cycle / speed;
            double t = marquee.Elapsed.TotalSeconds % (hold + travel);
            return t < hold ? 0f : (float)((t - hold) * speed);
        }

        void CardFrameTick()
        {
            if (!cardWin.IsShowing || !CardScrolls) { cardFrameTimer.Stop(); return; }
            cardWin.UpdateCard(PerLook(ComposeCard), PlaceCard);
        }

        double PlaybackPositionFor(SongInfo song)
        {
            var p = PlaybackPosition;
            return song.Duration > 0 ? Math.Min(p, song.Duration) : p;
        }

        /// <summary>Glide both panels to where they belong now (after a card or lyrics panel appears or leaves).</summary>
        void Reposition()
        {
            cardWin.MoveTo(PlaceCard);
            lyricsWin.MoveTo(PlaceLyrics);
        }

        /// <summary>Widget i's size in device pixels per 96-dpi pixel.</summary>
        double ScaleOf(int i) { return shown[i].Scale * dpiScale; }
        int PanelWidthFor(double scale) { return (int)Math.Round(cfg.PanelWidth * scale); }
        int GapOf(int i) { return (int)Math.Round(10 * ScaleOf(i)); }
        int LookOf(int i) { return lookScales.IndexOf(ScaleOf(i)); }

        /// <summary>
        /// Each window's bitmap for OverlayGroup: drawn once per look (draw(look)); the last window of a look takes
        /// the bitmap and the others a copy, since every window owns and disposes its own.
        /// </summary>
        Func<int, Bitmap> PerLook(Func<int, Bitmap> draw)
        {
            var made = new Bitmap[lookScales.Count];
            var left = new int[lookScales.Count];
            for (int i = 0; i < shown.Count; i++) left[LookOf(i)]++;
            return i =>
            {
                int k = LookOf(i);
                if (made[k] == null) made[k] = draw(k);
                return --left[k] == 0 ? made[k] : made[k].Clone(new Rectangle(Point.Empty, made[k].Size), System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            };
        }

        /// <summary>One look per distinct widget size (call after the widgets or their sizes change).</summary>
        void UpdateLooks()
        {
            var scales = shown.Select((w, i) => ScaleOf(i)).Distinct().ToList();
            for (int i = 0; i < shown.Count; i++)
            {
                cardWin.SetMaxAlpha(i, 1 - shown[i].Transparency);
                lyricsWin.SetMaxAlpha(i, 1 - shown[i].Transparency);
            }
            if (scales.SequenceEqual(lookScales)) return;
            lookScales.Clear();
            lookScales.AddRange(scales);
            lyricsViews.Clear();
            foreach (var scale in scales) lyricsViews.Add(new LyricsView());
            foreach (var f in cardFrames) f.Dispose();
            cardFrames.Clear();
            lyricsLayoutKey = null;
            lyricsViewSong = null;   // laid out afresh, nothing to carry over
        }

        // The song card and the lyrics panel form one column, lyrics always under the card, on each widget's monitor.
        // Bottom corners: the lyrics sit on the margin and the card stacks above them.
        // Top corners: the card sits on the margin and the lyrics hang below it (and move up when it leaves).
        Point PlaceCard(int i, Size size)
        {
            if (dragging && dragIndex == i && cardWin.IsShowingAt(i)) return cardWin.LocationOf(i);   // the mouse decides for now
            var w = shown[i];
            var b = ScreenBounds(w);
            int y;
            if (IsTop(w)) y = b.Top + MarginY(w);
            else
            {
                var lyr = lyricsWin.IsPresent ? lyricsWin.ContentSizeAt(i) : Size.Empty;
                y = b.Bottom - MarginY(w) - size.Height - (lyr.IsEmpty ? 0 : lyr.Height + GapOf(i));
            }
            return new Point(AlignX(w, b, size.Width), y);
        }

        Point PlaceLyrics(int i, Size size)
        {
            if (dragging && dragIndex == i && lyricsWin.IsShowingAt(i)) return lyricsWin.LocationOf(i);
            var w = shown[i];
            var b = ScreenBounds(w);
            int y;
            if (IsTop(w))
            {
                var card = cardWin.IsPresent ? cardWin.ContentSizeAt(i) : Size.Empty;
                y = b.Top + MarginY(w) + (card.IsEmpty ? 0 : card.Height + GapOf(i));
            }
            else y = b.Bottom - MarginY(w) - size.Height;
            return new Point(AlignX(w, b, size.Width), y);
        }

        static bool IsTop(WidgetPlace w)
        {
            if (w.Position == OverlayPosition.Custom) return !w.CustomFromBottom;
            return w.Position == OverlayPosition.TopLeft || w.Position == OverlayPosition.TopCenter || w.Position == OverlayPosition.TopRight;
        }

        // a dragged position is kept in screen pixels, the preset margins in 96-dpi pixels
        int MarginY(WidgetPlace w) { return w.Position == OverlayPosition.Custom ? w.CustomY : (int)Math.Round(cfg.MarginY * dpiScale); }

        int AlignX(WidgetPlace w, Rectangle b, int width)
        {
            int mx = (int)Math.Round(cfg.MarginX * dpiScale);
            switch (w.Position)
            {
                case OverlayPosition.TopLeft: case OverlayPosition.BottomLeft: return b.Left + mx;
                case OverlayPosition.TopRight: case OverlayPosition.BottomRight: return b.Right - width - mx;
                case OverlayPosition.Custom: return Math.Max(b.Left, Math.Min(b.Left + w.CustomX, b.Right - width));
                default: return b.Left + (b.Width - width) / 2;
            }
        }

        static Rectangle ScreenBounds(WidgetPlace w)
        {
            var screens = Screen.AllScreens;
            return (w.Monitor < screens.Length ? screens[w.Monitor] : Screen.PrimaryScreen).Bounds;
        }

        // ---- widgets (one per monitor) -------------------------------------------------

        /// <summary>The widgets turned on whose monitor is connected; the first of them on the main monitor if none is.</summary>
        static List<WidgetPlace> ShownWidgets(List<WidgetPlace> all, int monitorCount)
        {
            var widgets = all.Where(w => !w.Hidden).ToList();
            var list = widgets.Where(w => w.Monitor < monitorCount).ToList();
            if (list.Count == 0 && widgets.Count > 0)
            {
                var main = Array.IndexOf(Screen.AllScreens, Screen.PrimaryScreen);
                list.Add(widgets[0].CopyTo(Math.Max(0, main)));
            }
            return list;
        }

        void ResetWidgetWindows()
        {
            shown = ShownWidgets(cfg.Widgets, Screen.AllScreens.Length);
            cardWin.Reset(shown.Count);
            lyricsWin.Reset(shown.Count);
            cardWin.Interactive = lyricsWin.Interactive = moveMode;
            UpdateLooks();
        }

        /// <summary>Widgets added, removed or moved to another monitor: new windows, then show what was showing.</summary>
        void RebuildWidgets()
        {
            if (dragging) dragging = false;
            bool cardWasUp = cardWin.IsPresent;
            ResetWidgetWindows();
            lyricsLayoutKey = null;
            if (cardWasUp || KeepCard) ShowNow(CurrentKind());
            TickLyrics(true);
        }

        void OnDisplaysChanged(object sender, EventArgs e)
        {
            ui.Post(_ => RebuildWidgets(), null);   // monitor numbers and sizes may all have changed
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


        static readonly Tuple<string, double>[] Sizes =
            { Tuple.Create("작게", 0.8), Tuple.Create("보통", 1.0), Tuple.Create("크게", 1.25), Tuple.Create("아주 크게", 1.5) };
        static readonly Tuple<string, double>[] Transparencies =
            { Tuple.Create("없음", 0.0), Tuple.Create("20%", 0.2), Tuple.Create("40%", 0.4), Tuple.Create("60%", 0.6) };

        /// <summary>The saved widget behind the one shown on this monitor (the first one when it stands in on the main monitor).</summary>
        WidgetPlace SavedWidget(int monitor)
        {
            return cfg.OnWidgets.FirstOrDefault(w => w.Monitor == monitor) ?? (shown.Count == 1 ? cfg.OnWidgets[0] : null);
        }

        void SetWidgetScale(int monitor, double v)
        {
            var widget = SavedWidget(monitor);
            if (widget == null) return;
            widget.Scale = v;
            cfg.Save();
            shown = ShownWidgets(cfg.Widgets, Screen.AllScreens.Length);   // same widgets, new sizes
            UpdateLooks();
            TickLyrics(true);
            ShowNow(CurrentKind());
        }

        void SetWidgetTransparency(int monitor, double v)
        {
            var widget = SavedWidget(monitor);
            if (widget == null) return;
            widget.Transparency = v;
            cfg.Save();
            shown = ShownWidgets(cfg.Widgets, Screen.AllScreens.Length);
            UpdateLooks();
            ShowNow(CurrentKind());   // so the change can be seen
        }

        void SetVideoTitle(bool videoTitle)
        {
            cfg.VideoTitle = videoTitle;
            cfg.Save();
            if (cardWin.IsShowing) ShowNow(CurrentKind());
        }

        static string MonitorName(Screen[] screens, int i)
        {
            var b = screens[i].Bounds;
            return "모니터 " + (i + 1) + " (" + (screens[i].Primary ? "주 모니터, " : "") + b.Width + "×" + b.Height + ")";
        }

        /// <summary>
        /// 표시: which monitors have a widget (only with several monitors). 위치 / 크기 / 투명도: set per widget,
        /// one submenu per monitor with a widget, or the choices directly when there is one widget.
        /// </summary>
        void BuildWidgetMenus()
        {
            var screens = Screen.AllScreens;

            displayMenu.DropDownItems.Clear();
            displayMenu.Available = screens.Length > 1;   // nothing to choose with one monitor
            for (int i = 0; i < screens.Length; i++)
            {
                int index = i;
                var on = cfg.OnWidgets.Any(w => w.Monitor == i);
                displayMenu.DropDownItems.Add(new ToolStripMenuItem(MonitorName(screens, i), null, (s, e) => ToggleMonitor(index))
                {
                    Checked = on,
                    Enabled = !on || cfg.OnWidgets.Count > 1,   // the last widget can't be turned off
                });
            }

            FillPerWidget(placeMenu, screens, w =>
            {
                var items = new List<ToolStripItem>();
                foreach (OverlayPosition p in Enum.GetValues(typeof(OverlayPosition)))
                {
                    var pos = p; var monitor = w.Monitor;
                    if (pos == OverlayPosition.Custom) items.Add(new ToolStripSeparator());
                    items.Add(new ToolStripMenuItem(PositionName(pos), null, (s, e) => SetWidgetPosition(monitor, pos)) { Checked = w.Position == pos });
                }
                return items;
            });
            FillPerWidget(sizeMenu, screens, w => Choices(w, Sizes, w.Scale, SetWidgetScale));
            FillPerWidget(transparencyMenu, screens, w => Choices(w, Transparencies, w.Transparency, SetWidgetTransparency));
        }

        static List<ToolStripItem> Choices(WidgetPlace w, Tuple<string, double>[] choices, double current, Action<int, double> set)
        {
            return choices.Select(c =>
            {
                var monitor = w.Monitor; var v = c.Item2;
                return (ToolStripItem)new ToolStripMenuItem(c.Item1, null, (s, e) => set(monitor, v)) { Checked = Math.Abs(current - v) < 0.01 };
            }).ToList();
        }

        /// <summary>Each shown widget's items: one submenu per monitor, or the items directly for a single widget.</summary>
        void FillPerWidget(ToolStripMenuItem menu, Screen[] screens, Func<WidgetPlace, List<ToolStripItem>> itemsFor)
        {
            menu.DropDownItems.Clear();
            var widgets = shown.ToList();
            foreach (var w in widgets)
            {
                var items = itemsFor(w).ToArray();
                if (widgets.Count == 1) { menu.DropDownItems.AddRange(items); break; }
                var item = new ToolStripMenuItem(w.Monitor < screens.Length ? MonitorName(screens, w.Monitor) : "모니터 " + (w.Monitor + 1));
                item.DropDownItems.AddRange(items);
                menu.DropDownItems.Add(item);
            }
        }

        void ToggleMonitor(int monitor)
        {
            var widget = cfg.Widgets.FirstOrDefault(w => w.Monitor == monitor);
            if (widget != null && !widget.Hidden)
            {
                if (cfg.OnWidgets.Count == 1) return;
                widget.Hidden = true;   // kept: turning it on again brings its position, size and transparency back
            }
            else if (widget != null) widget.Hidden = false;
            else
            {
                // a new widget starts where the first one is (as a preset or the same dragged offsets)
                cfg.Widgets.Add(cfg.OnWidgets[0].CopyTo(monitor));
                cfg.Widgets = cfg.Widgets.OrderBy(w => w.Monitor).ToList();
            }
            cfg.Save();
            RebuildWidgets();
        }

        void SetWidgetPosition(int monitor, OverlayPosition pos)
        {
            var widget = SavedWidget(monitor);
            if (widget == null) return;
            widget.Position = pos;
            cfg.Save();
            shown = ShownWidgets(cfg.Widgets, Screen.AllScreens.Length);
            TickLyrics(true);
            ShowNow(CurrentKind());
        }

        // ---- dragging the widget -------------------------------------------------------
        // The overlay normally lets every click through (it sits over games). "위젯 끌어서 옮기기" turns that off
        // for both windows until it is chosen again; a drop saves a Custom position on the monitor it landed on.

        bool moveMode, dragging;
        int dragIndex = -1;
        Point dragStart, cardStart, lyricsStart;

        void SetMoveMode(bool on)
        {
            if (on == moveMode) return;
            moveMode = on;
            cardWin.Interactive = on;
            lyricsWin.Interactive = on;
            if (on)
            {
                Balloon("위젯을 끌어서 원하는 곳에 놓아 주십시오. 다 옮긴 뒤에는 트레이 메뉴의 '위젯 끌어서 옮기기'를 다시 눌러 주십시오.");
                ShowNow(CurrentKind());
                TickLyrics(true);
            }
            else
            {
                if (dragging) EndDrag(dragIndex);
                if (pear.Current.HasData) ShowNow(CurrentKind());   // back to the normal show time
                else cardWin.Dismiss();
            }
        }

        void BeginDrag(int i, Point cursor)
        {
            dragging = true;
            dragIndex = i;
            dragStart = cursor;
            cardStart = cardWin.LocationOf(i);
            lyricsStart = lyricsWin.LocationOf(i);
        }

        void DragTo(int i, Point cursor)
        {
            if (!dragging || i != dragIndex) return;
            int dx = cursor.X - dragStart.X, dy = cursor.Y - dragStart.Y;
            if (cardWin.IsShowingAt(i)) cardWin.JumpTo(i, new Point(cardStart.X + dx, cardStart.Y + dy));
            if (lyricsWin.IsShowingAt(i)) lyricsWin.JumpTo(i, new Point(lyricsStart.X + dx, lyricsStart.Y + dy));
        }

        /// <summary>Save where widget i landed as its Custom position on its own monitor (it stays on that monitor).</summary>
        void EndDrag(int i)
        {
            if (!dragging || i != dragIndex) return;
            dragging = false;
            dragIndex = -1;
            var column = Rectangle.Empty;
            if (cardWin.IsPresent) column = new Rectangle(cardWin.LocationOf(i), cardWin.ContentSizeAt(i));
            if (lyricsWin.IsPresent)
            {
                var l = new Rectangle(lyricsWin.LocationOf(i), lyricsWin.ContentSizeAt(i));
                column = column.IsEmpty ? l : Rectangle.Union(column, l);
            }
            if (column.IsEmpty || i >= shown.Count) return;
            var widget = shown[i];
            int monitor, x, y; bool fromBottom;
            Placement.FromDrop(column, new[] { ScreenBounds(widget) }, out monitor, out x, out y, out fromBottom);
            widget.Position = OverlayPosition.Custom;
            widget.CustomX = x;
            widget.CustomY = y;
            widget.CustomFromBottom = fromBottom;
            cfg.Save();
            Reposition();   // settles onto the saved spot (kept on its monitor)
        }

        void ApplyLyricsSources()
        {
            lyricsProvider.UseYtm = cfg.YtmLyrics;
            lyricsProvider.UseMore = cfg.MoreLyrics;
            lyricsProvider.Ytm.ProxyBase = string.IsNullOrWhiteSpace(cfg.YtmLyricsProxy) ? YtmLyrics.DefaultProxy : cfg.YtmLyricsProxy.Trim();
        }

        void ReloadConfig()
        {
            var old = cfg;
            cfg = Config.Load();
            RegisterHotkeys();
            lyricsProvider.BaseUrl = (cfg.LyricsServer ?? "https://lrclib.net").TrimEnd('/');
            ApplyLyricsSources();
            if (old.Host != cfg.Host || old.Port != cfg.Port || old.Https != cfg.Https || old.Source != cfg.Source) pear.Reconnect(cfg);
            RebuildWidgets();
            TickLyrics(true);
            ShowNow(CurrentKind());
            SyncDiscord();
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
            if (errors.Length > 0) Balloon("단축키를 등록하지 못했습니다: " + string.Join(", ", errors));
        }

        void SyncMenuChecks()
        {
            pinItem.Checked = cfg.AlwaysShow;
            lyricsItem.Checked = cfg.ShowLyrics;
            albumOnlyItem.Checked = cfg.LyricsAlbumOnly;
            moveItem.Checked = moveMode;
            updateItem.Text = update != null ? "업데이트 설치 (" + update.Version + ")" : "업데이트 확인";
            foreach (ToolStripMenuItem it in titleMenu.DropDownItems) it.Checked = (bool)it.Tag == cfg.VideoTitle;
            BuildWidgetMenus();
            foreach (ToolStripMenuItem it in offsetMenu.DropDownItems) it.Checked = (int)it.Tag == cfg.LyricsOffsetMs;
            foreach (ToolStripMenuItem it in sourceMenu.DropDownItems) it.Checked = (string)it.Tag == cfg.Source;
            discordItem.Checked = cfg.DiscordPresence;
            discordButtonItem.Checked = cfg.DiscordButton;
            discordButtonItem.Enabled = cfg.DiscordPresence;
            retryAuthItem.Visible = cfg.Source != "browser";
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
            try { tray.ShowBalloonTip(4000, "Now Playing Widget", text, ToolTipIcon.Info); } catch { }
        }

        void SetSource(string value)
        {
            if (cfg.Source == value) return;
            cfg.Source = value;
            cfg.Save();
            pear.Reconnect(cfg);
            ShowInfo(value == "browser" ? "브라우저에서 재생하는 YouTube Music을 표시합니다" : value == "pear" ? "Pear Desktop에서 재생하는 곡을 표시합니다" : "브라우저와 Pear Desktop 중에서 재생 중인 곡을 표시합니다");
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
                case OverlayPosition.Custom: return "직접 옮긴 위치";
                default: return "오른쪽 아래";
            }
        }

        static string Truncate(string s, int max) { return s.Length <= max ? s : s.Substring(0, max); }

        protected override void ExitThreadCore()
        {
            try { tray.Visible = false; } catch { }
            try { lyricsTimer.Stop(); frameTimer.Stop(); cardFrameTimer.Stop(); infoTimer.Stop(); if (lyricsCts != null) lyricsCts.Cancel(); if (prefetchCts != null) prefetchCts.Cancel(); } catch { }
            try { pear.Dispose(); } catch { }
            try { discord.Dispose(); } catch { }
            try { hotkeys.Dispose(); } catch { }
            try { SystemEvents.DisplaySettingsChanged -= OnDisplaysChanged; cardWin.Dispose(); lyricsWin.Dispose(); } catch { }
            try { tray.Dispose(); menu.Dispose(); artHttp.Dispose(); lyricsProvider.Dispose(); updater.Dispose(); } catch { }
            base.ExitThreadCore();
        }
    }
}
