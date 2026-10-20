using System;
using System.Net;
using System.Reflection;
using System.Runtime.Versioning;
using System.Threading;
using System.Windows.Forms;

[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]
[assembly: AssemblyTitle("Now Playing Widget")]
[assembly: AssemblyProduct("Now Playing Widget")]
[assembly: AssemblyDescription("브라우저나 Pear Desktop에서 재생하는 YouTube Music 곡과 가사를 화면 위에 표시")]
[assembly: AssemblyVersion("1.9.4.0")]
[assembly: AssemblyFileVersion("1.9.4.0")]

namespace PearNowPlaying
{
    /// <summary>The app's version, from AssemblyVersion above (the one place to change it; see VERSIONING.md).</summary>
    internal static class AppInfo
    {
        public static readonly string Version = typeof(AppInfo).Assembly.GetName().Version.ToString(3);

        /// <summary>
        /// " (built yyyy-MM-dd HH:mm)": when this exe was built (its modification time, kept by the release zip and
        /// updates), so logs of builds that share a version number can be told apart.
        /// </summary>
        public static string BuildStamp
        {
            get
            {
                try { return " (built " + System.IO.File.GetLastWriteTime(Application.ExecutablePath).ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture) + ")"; }
                catch { return ""; }
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length >= 1 && args[0] == "--browser-probe")
            {
                double seconds;
                BrowserProbe.Run(args.Length > 1 && double.TryParse(args[1], out seconds) ? seconds : 60);
                return;
            }
            // started by an update: wait for the old instance to exit so the single-instance check lets us in
            int pid;
            if (args.Length == 2 && args[0] == "--wait-for" && int.TryParse(args[1], out pid))
            {
                try { System.Diagnostics.Process.GetProcessById(pid).WaitForExit(15000); } catch { }
            }
            bool created;
            // the old name is kept so a running older version (Pear Now Playing) and this one still exclude each other
            using (var mutex = new Mutex(true, "Local\\PearNowPlaying_SingleInstance", out created))
            {
                if (!created)
                {
                    MessageBox.Show("Now Playing Widget이 이미 실행 중입니다.\n작업 표시줄 오른쪽의 트레이 아이콘을 확인해 주십시오.",
                        "Now Playing Widget", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                try { Native.SetProcessDPIAware(); } catch { }
                try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (s, e) => Log.Error("ui thread", e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Write("FATAL " + e.ExceptionObject);

                SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
                Log.Info("start " + AppInfo.Version + AppInfo.BuildStamp);
                Updater.CleanupOld(Application.ExecutablePath);
                Application.Run(new TrayApp());
                Log.Info("exit");
            }
        }
    }
}
