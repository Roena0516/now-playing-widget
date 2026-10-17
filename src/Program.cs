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
[assembly: AssemblyVersion("1.4.1.0")]
[assembly: AssemblyFileVersion("1.4.1.0")]

namespace PearNowPlaying
{
    internal static class Program
    {
        [STAThread]
        static void Main()
        {
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
                Log.Info("start");
                Application.Run(new TrayApp());
                Log.Info("exit");
            }
        }
    }
}
