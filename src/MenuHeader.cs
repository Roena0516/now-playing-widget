using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace PearNowPlaying
{
    /// <summary>What the tray menu header's update button shows (the macOS version's MenuHeader has the same states).</summary>
    internal enum UpdateButton { Check, Checking, UpToDate, Install, Installing }

    /// <summary>
    /// The tray menu's first item: the app's name and version, and a round button on the right for updates ("업데이트 확인",
    /// "2.0.6 설치"). The item is painted here instead of by the menu (a menu item has one line of text), and only a click on
    /// the button does anything. Clicks don't close the menu, so a check's result shows on the button; installing closes it.
    /// </summary>
    internal sealed class MenuHeaderItem : ToolStripMenuItem
    {
        /// <summary>The button's state and the new version (for Install), asked whenever the item is painted.</summary>
        public Func<UpdateButton> ButtonState = () => UpdateButton.Check;
        public Func<string> NewVersion = () => "";
        public event EventHandler ButtonClicked;
        bool hover;

        public MenuHeaderItem() : base("Now Playing Widget") { }

        public override Size GetPreferredSize(Size constrainingSize) { return Measure(Font, ButtonState(), NewVersion()); }

        Point Pointer()
        {
            var p = Owner != null ? Owner.PointToClient(Control.MousePosition) : Point.Empty;
            return new Point(p.X - Bounds.X, p.Y - Bounds.Y);
        }

        bool OverButton() { return ButtonRect(new Rectangle(Point.Empty, Size), Font, ButtonState(), NewVersion()).Contains(Pointer()); }

        protected override void OnMouseEnter(EventArgs e)
        {
            base.OnMouseEnter(e);
            // clicks here leave the menu open (AutoClose is back on once the mouse leaves, so clicking elsewhere still closes it)
            if (Owner is ToolStripDropDown) ((ToolStripDropDown)Owner).AutoClose = false;
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (Owner is ToolStripDropDown) ((ToolStripDropDown)Owner).AutoClose = true;
            if (hover) { hover = false; Invalidate(); }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            bool over = OverButton();
            if (over != hover) { hover = over; Invalidate(); }
        }

        protected override void OnClick(EventArgs e)
        {
            var state = ButtonState();
            if (state == UpdateButton.Checking || state == UpdateButton.Installing || !OverButton()) return;
            if (state == UpdateButton.Install && Owner is ToolStripDropDown) { ((ToolStripDropDown)Owner).AutoClose = true; ((ToolStripDropDown)Owner).Close(); }
            if (ButtonClicked != null) ButtonClicked(this, EventArgs.Empty);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Draw(e.Graphics, new Rectangle(Point.Empty, Size), Font, ButtonState(), NewVersion(), hover);
        }

        // ---- drawing (static, so it can also be drawn into a picture away from Windows) ----------------------------------

        static float Unit(Font font) { return font.Height / 15f; }   // 1 at Segoe UI 9 pt, 96 dpi
        static Font Bold(Font font) { return new Font(font, FontStyle.Bold); }
        static Font Small(Font font) { return new Font(font.FontFamily, font.SizeInPoints - 0.75f, FontStyle.Regular, GraphicsUnit.Point); }

        public static string ButtonText(UpdateButton state, string newVersion)
        {
            switch (state)
            {
                case UpdateButton.Checking: return "확인 중…";
                case UpdateButton.UpToDate: return "최신 버전";
                case UpdateButton.Install: return newVersion + " 설치";
                case UpdateButton.Installing: return "설치 중…";
                default: return "업데이트 확인";
            }
        }

        public static Size Measure(Font font, UpdateButton state, string newVersion)
        {
            float u = Unit(font);
            using (var bold = Bold(font))
            using (var small = Small(font))
            {
                var title = TextRenderer.MeasureText("Now Playing Widget", bold);
                var sub = TextRenderer.MeasureText(VersionText, small);
                // the widest the button gets, so the menu doesn't change width as the text changes
                int button = 0;
                foreach (UpdateButton s in Enum.GetValues(typeof(UpdateButton)))
                    button = Math.Max(button, TextRenderer.MeasureText(ButtonText(s, newVersion), small).Width);
                int width = (int)(12 * u) + Math.Max(title.Width, sub.Width) + (int)(24 * u) + button + (int)(24 * u) + (int)(10 * u);
                int height = (int)(8 * u) + title.Height + sub.Height + (int)(8 * u);
                return new Size(width, height);
            }
        }

        static string VersionText { get { return "버전 " + AppInfo.Version; } }

        public static Rectangle ButtonRect(Rectangle bounds, Font font, UpdateButton state, string newVersion)
        {
            float u = Unit(font);
            using (var small = Small(font))
            {
                var text = TextRenderer.MeasureText(ButtonText(state, newVersion), small);
                int height = text.Height + (int)(8 * u), width = text.Width + (int)(22 * u);
                return new Rectangle(bounds.Right - (int)(10 * u) - width, bounds.Top + (bounds.Height - height) / 2, width, height);
            }
        }

        static Color Mix(Color a, Color b, float t)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        public static void Draw(Graphics g, Rectangle bounds, Font font, UpdateButton state, string newVersion, bool hover)
        {
            float u = Unit(font);
            var back = ProfessionalColors.ToolStripDropDownBackground;
            using (var fill = new SolidBrush(back)) g.FillRectangle(fill, bounds);   // over the image margin: a header band
            using (var bold = Bold(font))
            using (var small = Small(font))
            {
                var title = TextRenderer.MeasureText("Now Playing Widget", bold);
                var sub = TextRenderer.MeasureText(VersionText, small);
                int top = bounds.Top + (bounds.Height - title.Height - sub.Height) / 2, left = bounds.Left + (int)(12 * u);
                TextRenderer.DrawText(g, "Now Playing Widget", bold, new Point(left, top), SystemColors.MenuText, TextFormatFlags.NoPadding);
                TextRenderer.DrawText(g, VersionText, small, new Point(left, top + title.Height), SystemColors.GrayText, TextFormatFlags.NoPadding);

                var rect = ButtonRect(bounds, font, state, newVersion);
                bool busy = state == UpdateButton.Checking || state == UpdateButton.Installing;
                Color face, edge, ink;
                if (state == UpdateButton.Install)
                {
                    face = hover ? Mix(SystemColors.Highlight, Color.Black, 0.12f) : SystemColors.Highlight;
                    edge = face; ink = SystemColors.HighlightText;
                }
                else if (hover && !busy)
                {
                    face = ProfessionalColors.MenuItemSelected; edge = ProfessionalColors.MenuItemBorder; ink = SystemColors.MenuText;
                }
                else
                {
                    face = Mix(back, SystemColors.MenuText, 0.08f); edge = Mix(back, SystemColors.MenuText, 0.2f);
                    ink = busy ? SystemColors.GrayText : SystemColors.MenuText;
                }
                var smoothing = g.SmoothingMode;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var path = Pill(rect))
                using (var brush = new SolidBrush(face))
                using (var pen = new Pen(edge))
                {
                    g.FillPath(brush, path);
                    g.DrawPath(pen, path);
                }
                g.SmoothingMode = smoothing;
                TextRenderer.DrawText(g, ButtonText(state, newVersion), small, rect, ink,
                                      TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
        }

        static GraphicsPath Pill(Rectangle r)
        {
            var path = new GraphicsPath();
            int d = r.Height - 1;
            path.AddArc(r.Left, r.Top, d, d, 90, 180);
            path.AddArc(r.Right - 1 - d, r.Top, d, d, 270, 180);
            path.CloseFigure();
            return path;
        }
    }
}
