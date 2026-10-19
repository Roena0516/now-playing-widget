using System;
using System.Net;
using System.Reflection;
using System.Runtime.Versioning;
using System.Threading;
using System.Windows.Forms;

[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]
[assembly: AssemblyTitle("Pear Now Playing")]
[assembly: AssemblyProduct("Pear Now Playing")]
[assembly: AssemblyDescription("Pear Desktop(YouTube Music) 재생 곡을 화면 위에 표시")]
[assembly: AssemblyVersion("1.7.2.0")]
[assembly: AssemblyFileVersion("1.7.2.0")]

namespace PearNowPlaying
{
    /// <summary>The app's version, from AssemblyVersion above (the one place to change it; see VERSIONING.md).</summary>
    internal static class AppInfo
    {
        public static readonly string Version = typeof(AppInfo).Assembly.GetName().Version.ToString(3);
    }

    internal static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            // started by an update: wait for the old instance to exit so the single-instance check lets us in
            int pid;
            if (args.Length == 2 && args[0] == "--wait-for" && int.TryParse(args[1], out pid))
            {
                try { System.Diagnostics.Process.GetProcessById(pid).WaitForExit(15000); } catch { }
            }
            bool created;
            using (var mutex = new Mutex(true, "Local\\PearNowPlaying_SingleInstance", out created))
            {
                if (!created)
                {
                    MessageBox.Show("Pear Now Playing이 이미 실행 중이에요.\n작업 표시줄 오른쪽의 트레이 아이콘을 확인해 주세요.",
                        "Pear Now Playing", MessageBoxButtons.OK, MessageBoxIcon.Information);
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
                Log.Info("start " + AppInfo.Version);
                Updater.CleanupOld(Application.ExecutablePath);
                Application.Run(new TrayApp());
                Log.Info("exit");
            }
        }
    }
}
