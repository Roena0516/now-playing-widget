using System;
using System.Collections.Generic;
using System.Drawing;

namespace PearNowPlaying
{
    /// <summary>
    /// The same overlay (song card or lyrics panel) on several monitors: one OverlayWindow per widget, all showing
    /// the same thing and fading together, each placed by its own widget's rule and drawn at its own size (the
    /// caller hands each window its own bitmap, which the window owns and disposes). State questions (showing,
    /// present) are answered by the first window, since all of them change together; sizes differ per window.
    /// </summary>
    internal sealed class OverlayGroup : IDisposable
    {
        readonly List<OverlayWindow> windows = new List<OverlayWindow>();

        /// <summary>The first window finished fading out (the others fade on the same clock).</summary>
        public event EventHandler FadedOut;
        /// <summary>Mouse pressed / moved / released on widget i while Interactive, in screen coordinates.</summary>
        public event Action<int, Point> DragBegan, Dragged;
        public event Action<int> DragEnded;

        bool interactive;

        public int Count { get { return windows.Count; } }

        /// <summary>Make one window per widget (the old ones are closed, so call it when the widgets change).</summary>
        public void Reset(int count)
        {
            foreach (var w in windows) { try { w.Close(); w.Dispose(); } catch { } }
            windows.Clear();
            for (int i = 0; i < Math.Max(1, count); i++)
            {
                int index = i;
                var w = new OverlayWindow();
                var handle = w.Handle;   // created now, so styles (click-through) can be changed right away
                if (i == 0) w.FadedOut += (s, e) => { var h = FadedOut; if (h != null) h(this, e); };
                w.DragBegan += p => { var h = DragBegan; if (h != null) h(index, p); };
                w.Dragged += p => { var h = Dragged; if (h != null) h(index, p); };
                w.DragEnded += () => { var h = DragEnded; if (h != null) h(index); };
                w.Interactive = interactive;
                windows.Add(w);
            }
        }

        OverlayWindow First { get { return windows[0]; } }
        public bool IsShowing { get { return First.IsShowing; } }
        public bool IsPinned { get { return First.IsPinned; } }
        public bool IsPresent { get { return First.IsPresent; } }
        public Size ContentSizeAt(int i) { return windows[i].ContentSize; }
        public Point LocationOf(int i) { return windows[i].ContentLocation; }
        public void SetMaxAlpha(int i, double alpha) { windows[i].MaxAlpha = alpha; }
        public bool IsShowingAt(int i) { return windows[i].IsShowing; }

        public bool Interactive
        {
            get { return interactive; }
            set { interactive = value; foreach (var w in windows) w.Interactive = value; }
        }

        /// <summary>bitmapFor(i) is called once per window, in order.</summary>
        public void ShowCard(Func<int, Bitmap> bitmapFor, Func<int, Size, Point> place, double? holdSeconds)
        {
            for (int i = 0; i < windows.Count; i++) { var bmp = bitmapFor(i); windows[i].ShowCard(bmp, place(i, bmp.Size), holdSeconds); }
        }

        public void UpdateCard(Func<int, Bitmap> bitmapFor, Func<int, Size, Point> place)
        {
            for (int i = 0; i < windows.Count; i++) { var bmp = bitmapFor(i); windows[i].UpdateCard(bmp, place(i, bmp.Size)); }
        }

        /// <summary>Glide every window to where its widget wants it.</summary>
        public void MoveTo(Func<int, Size, Point> place)
        {
            for (int i = 0; i < windows.Count; i++)
            {
                var size = windows[i].ContentSize;
                if (!size.IsEmpty) windows[i].MoveTo(place(i, size));
            }
        }

        public void JumpTo(int i, Point at) { windows[i].JumpTo(at); }

        public void Dismiss() { foreach (var w in windows) w.Dismiss(); }

        public void Dispose()
        {
            foreach (var w in windows) { try { w.Close(); w.Dispose(); } catch { } }
            windows.Clear();
        }
    }
}
