using System;
using System.Collections.Generic;
using System.Windows.Forms;

namespace PearNowPlaying
{
    /// <summary>System-wide hotkeys (RegisterHotKey). They work while another app (e.g. a fullscreen game) has focus.</summary>
    internal sealed class Hotkeys : NativeWindow, IDisposable
    {
        readonly Dictionary<int, Action> actions = new Dictionary<int, Action>();
        int nextId = 1;

        public Hotkeys() { CreateHandle(new CreateParams()); }

        /// <returns>null on success (or when the spec is empty), otherwise an error message</returns>
        public string Register(string spec, Action action)
        {
            if (string.IsNullOrWhiteSpace(spec)) return null;
            uint mods; Keys key;
            if (!TryParse(spec, out mods, out key)) return spec + " (인식할 수 없는 키)";
            int id = nextId++;
            if (!Native.RegisterHotKey(Handle, id, mods | Native.MOD_NOREPEAT, (uint)key))
                return spec + " (다른 프로그램이 사용 중)";
            actions[id] = action;
            return null;
        }

        public void UnregisterAll()
        {
            foreach (var id in actions.Keys) Native.UnregisterHotKey(Handle, id);
            actions.Clear();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY)
            {
                Action a;
                if (actions.TryGetValue(m.WParam.ToInt32(), out a))
                {
                    try { a(); } catch (Exception ex) { Log.Error("hotkey", ex); }
                }
                return;
            }
            base.WndProc(ref m);
        }

        static bool TryParse(string spec, out uint mods, out Keys key)
        {
            mods = 0; key = Keys.None;
            foreach (var raw in spec.Split('+'))
            {
                var t = raw.Trim();
                if (t.Length == 0) return false;
                switch (t.ToLowerInvariant())
                {
                    case "ctrl": case "control": mods |= Native.MOD_CONTROL; continue;
                    case "alt": mods |= Native.MOD_ALT; continue;
                    case "shift": mods |= Native.MOD_SHIFT; continue;
                    case "win": case "windows": mods |= Native.MOD_WIN; continue;
                }
                if (key != Keys.None) return false;
                if (t.Length == 1 && char.IsDigit(t[0])) t = "D" + t;   // "1" -> Keys.D1
                Keys k;
                if (!Enum.TryParse(t, true, out k) || k == Keys.None) return false;
                key = k & Keys.KeyCode;
            }
            return key != Keys.None;
        }

        public void Dispose()
        {
            UnregisterAll();
            DestroyHandle();
        }
    }
}
