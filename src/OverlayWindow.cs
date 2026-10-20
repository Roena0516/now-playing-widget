using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PearNowPlaying
{
    /// <summary>
    /// Borderless, click-through, always-on-top window that shows a pre-rendered bitmap with per-pixel alpha
    /// (UpdateLayeredWindow). It never takes focus, so the app underneath keeps keyboard/wheel input.
    /// Supports fade in/out and eased moves between positions. While <see cref="Interactive"/> is on (the tray's
    /// "drag to move" mode) it takes mouse input instead and reports drags; it still never takes the focus.
    /// </summary>
    internal sealed class OverlayWindow : Form
    {
        enum Phase { Hidden, FadingIn, Holding, FadingOut, Pinned }

        readonly Timer anim = new Timer { Interval = 15 };
        readonly Timer keepOnTop = new Timer { Interval = 1500 };

        Bitmap current;
        Phase phase = Phase.Hidden;
        double alpha;          // 0..1 fade multiplier
        DateTime holdUntil;
        Point location;

        // eased move
        bool moving;
        Point moveFrom, moveTo;
        readonly Stopwatch moveClock = new Stopwatch();

        const double FadeInMs = 180, FadeOutMs = 450, MoveMs = 320;

        public event EventHandler FadedOut;
        /// <summary>Mouse pressed / moved / released while <see cref="Interactive"/>, in screen coordinates.</summary>
        public event Action<Point> DragBegan, Dragged;
        public event Action DragEnded;

        bool interactive, dragging;

        /// <summary>Take mouse input (for dragging) instead of letting clicks through.</summary>
        public bool Interactive
        {
            get { return interactive; }
            set
            {
                if (interactive == value) return;
                interactive = value;
                Cursor = value ? Cursors.SizeAll : Cursors.Default;
                if (!IsHandleCreated) return;
                int style = Native.GetWindowLong(Handle, Native.GWL_EXSTYLE);
                style = value ? style & ~Native.WS_EX_TRANSPARENT : style | Native.WS_EX_TRANSPARENT;
                Native.SetWindowLong(Handle, Native.GWL_EXSTYLE, style);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (!interactive || e.Button != MouseButtons.Left) return;
            dragging = true;
            Capture = true;
            var h = DragBegan; if (h != null) h(Control.MousePosition);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!dragging) return;
            var h = Dragged; if (h != null) h(Control.MousePosition);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (!dragging) return;
            dragging = false;
            Capture = false;
            var h = DragEnded; if (h != null) h();
        }

        protected override void OnMouseCaptureChanged(EventArgs e)
        {
            base.OnMouseCaptureChanged(e);
            if (!dragging || Capture) return;
            dragging = false;   // capture lost mid-drag (another window took it): end the drag where it is
            var h = DragEnded; if (h != null) h();
        }

        public OverlayWindow()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Text = "Now Playing Widget";
            anim.Tick += OnAnim;
            keepOnTop.Tick += (s, e) => BringToTop();
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST
                            | (interactive ? 0 : Native.WS_EX_TRANSPARENT);
                return cp;
            }
        }

        double maxAlpha = 1;

        /// <summary>The widget's own opacity (its transparency setting), on top of the fade.</summary>
        public double MaxAlpha
        {
            get { return maxAlpha; }
            set { maxAlpha = Math.Max(0, Math.Min(1, value)); if (phase != Phase.Hidden) Push(); }
        }

        public bool IsShowing { get { return phase != Phase.Hidden; } }
        public bool IsPinned { get { return phase == Phase.Pinned; } }
        public bool IsFadingOut { get { return phase == Phase.FadingOut; } }

        /// <summary>Visible and not on its way out.</summary>
        public bool IsPresent { get { return phase != Phase.Hidden && phase != Phase.FadingOut; } }

        /// <summary>Top-left corner of the picture on screen (where it is now, mid-move included).</summary>
        public Point ContentLocation { get { return location; } }

        /// <summary>Size of the picture currently on screen (empty when hidden).</summary>
        public Size ContentSize { get { return phase == Phase.Hidden || current == null ? Size.Empty : current.Size; } }

        /// <summary>Show a card. If holdSeconds is null the card stays until Dismiss() is called.</summary>
        public void ShowCard(Bitmap bmp, Point at, double? holdSeconds)
        {
            bool wasHidden = phase == Phase.Hidden;
            SetContent(bmp);
            if (wasHidden)
            {
                alpha = 0;
                moving = false;
                location = at;
                Show();
                BringToTop();
            }
            else MoveTo(at);

            if (holdSeconds.HasValue)
            {
                holdUntil = DateTime.Now.AddSeconds(holdSeconds.Value);
                phase = alpha >= 1 ? Phase.Holding : Phase.FadingIn;
            }
            else
            {
                holdUntil = DateTime.MaxValue;
                phase = alpha >= 1 ? Phase.Pinned : Phase.FadingIn;
            }
            anim.Start();
            keepOnTop.Start();
            Push();
        }

        /// <summary>Swap the picture without changing the timing (progress bar, lyric frames).</summary>
        public void UpdateCard(Bitmap bmp, Point at)
        {
            if (phase == Phase.Hidden) { bmp.Dispose(); return; }
            SetContent(bmp);
            MoveTo(at);
            Push();
        }

        /// <summary>Glide to a new position (instant while hidden).</summary>
        public void MoveTo(Point at)
        {
            if (phase == Phase.Hidden) { location = at; moving = false; return; }
            var target = moving ? moveTo : location;
            if (at == target) return;
            moveFrom = location;
            moveTo = at;
            moving = true;
            moveClock.Restart();
            anim.Start();
        }

        /// <summary>Move at once, without easing (following the mouse while dragging).</summary>
        public void JumpTo(Point at)
        {
            moving = false;
            location = at;
            if (phase != Phase.Hidden) Push();
        }

        public void Dismiss()
        {
            if (phase == Phase.Hidden || phase == Phase.FadingOut) return;
            phase = Phase.FadingOut;
            anim.Start();
        }

        void SetContent(Bitmap bmp)
        {
            var old = current;
            current = bmp;
            if (old != null && !ReferenceEquals(old, bmp)) old.Dispose();
        }

        void OnAnim(object sender, EventArgs e)
        {
            double step = anim.Interval;
            bool dirty = false;

            if (moving)
            {
                double t = Math.Min(1, moveClock.Elapsed.TotalMilliseconds / MoveMs);
                double k = 1 - Math.Pow(1 - t, 3);
                location = new Point((int)Math.Round(moveFrom.X + (moveTo.X - moveFrom.X) * k),
                                     (int)Math.Round(moveFrom.Y + (moveTo.Y - moveFrom.Y) * k));
                if (t >= 1) { moving = false; location = moveTo; }
                dirty = true;
            }

            switch (phase)
            {
                case Phase.FadingIn:
                    alpha = Math.Min(1, alpha + step / FadeInMs);
                    if (alpha >= 1) phase = holdUntil == DateTime.MaxValue ? Phase.Pinned : Phase.Holding;
                    dirty = true;
                    break;
                case Phase.Holding:
                    if (DateTime.Now >= holdUntil) phase = Phase.FadingOut;
                    break;
                case Phase.FadingOut:
                    alpha = Math.Max(0, alpha - step / FadeOutMs);
                    dirty = true;
                    if (alpha <= 0)
                    {
                        Push();
                        phase = Phase.Hidden;
                        moving = false;
                        anim.Stop();
                        keepOnTop.Stop();
                        Hide();
                        var h = FadedOut;
                        if (h != null) h(this, EventArgs.Empty);
                        return;
                    }
                    break;
            }

            if (dirty) Push();
            if (phase == Phase.Pinned && !moving) anim.Stop();
        }

        void BringToTop()
        {
            if (!IsHandleCreated) return;
            Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0,
                Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        void Push()
        {
            if (current == null || !IsHandleCreated) return;
            IntPtr screenDc = Native.GetDC(IntPtr.Zero);
            IntPtr memDc = Native.CreateCompatibleDC(screenDc);
            IntPtr hBitmap = IntPtr.Zero, oldBitmap = IntPtr.Zero;
            try
            {
                hBitmap = current.GetHbitmap(Color.FromArgb(0));
                oldBitmap = Native.SelectObject(memDc, hBitmap);
                var size = new Native.SIZE(current.Width, current.Height);
                var src = new Native.POINT(0, 0);
                var dst = new Native.POINT(location.X, location.Y);
                var blend = new Native.BLENDFUNCTION
                {
                    BlendOp = Native.AC_SRC_OVER,
                    BlendFlags = 0,
                    SourceConstantAlpha = (byte)Math.Max(0, Math.Min(255, (int)Math.Round(255 * Ease(alpha) * maxAlpha))),
                    AlphaFormat = Native.AC_SRC_ALPHA
                };
                Native.UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, Native.ULW_ALPHA);
            }
            finally
            {
                Native.ReleaseDC(IntPtr.Zero, screenDc);
                if (hBitmap != IntPtr.Zero)
                {
                    Native.SelectObject(memDc, oldBitmap);
                    Native.DeleteObject(hBitmap);
                }
                Native.DeleteDC(memDc);
            }
        }

        static double Ease(double t) { return t * t * (3 - 2 * t); }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                anim.Dispose();
                keepOnTop.Dispose();
                if (current != null) current.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
