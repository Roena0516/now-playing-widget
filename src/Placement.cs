using System;
using System.Drawing;

namespace PearNowPlaying
{
    /// <summary>Where a widget dragged by the user belongs (pure, so it can be tested without windows).</summary>
    internal static class Placement
    {
        /// <summary>
        /// The monitor holding the dropped column's center (the nearest one if the center is off every screen), and
        /// the column's offset from that monitor's left edge and from its top or bottom edge, whichever half the
        /// center is in: a widget dropped low stays anchored to the bottom like the Bottom* positions. The offsets
        /// are clamped so the column stays on that monitor.
        /// </summary>
        public static void FromDrop(Rectangle column, Rectangle[] screens, out int monitor, out int x, out int y, out bool fromBottom)
        {
            var center = new Point(column.Left + column.Width / 2, column.Top + column.Height / 2);
            monitor = 0;
            double best = double.MaxValue;
            for (int i = 0; i < screens.Length; i++)
            {
                var s = screens[i];
                if (s.Contains(center)) { monitor = i; best = -1; break; }
                double dx = Math.Max(0, Math.Max(s.Left - center.X, center.X - s.Right));
                double dy = Math.Max(0, Math.Max(s.Top - center.Y, center.Y - s.Bottom));
                double d = dx * dx + dy * dy;
                if (d < best) { best = d; monitor = i; }
            }
            var b = screens.Length > 0 ? screens[monitor] : Rectangle.Empty;
            fromBottom = center.Y >= b.Top + b.Height / 2;
            x = Clamp(column.Left - b.Left, 0, Math.Max(0, b.Width - column.Width));
            y = Clamp(fromBottom ? b.Bottom - column.Bottom : column.Top - b.Top, 0, Math.Max(0, b.Height - column.Height));
        }

        static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
    }
}
