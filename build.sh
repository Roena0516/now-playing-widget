#!/bin/sh
# Builds PearNowPlaying.exe (.NET Framework 4.8, no extra runtime needed on Windows 10/11).
# Linux: needs dotnet SDK (for the Roslyn compiler) + mono reference assemblies (/usr/lib/mono/4.8-api).
set -e
cd "$(dirname "$0")"
CSC=$(ls /usr/lib/dotnet/sdk/*/Roslyn/bincore/csc.dll | head -1)
A=/usr/lib/mono/4.8-api
mkdir -p bin
dotnet "$CSC" -nologo -nostdlib -noconfig -optimize+ -warn:4 \
  -target:winexe -platform:anycpu -langversion:7.3 -codepage:65001 \
  -win32icon:assets/app.ico \
  -resource:assets/fonts/PretendardJP-Regular.ttf,PretendardJP-Regular.ttf \
  -resource:assets/fonts/PretendardJP-Medium.ttf,PretendardJP-Medium.ttf \
  -resource:assets/fonts/PretendardJP-coverage.bin,PretendardJP-coverage.bin \
  -out:bin/PearNowPlaying.exe \
  -r:$A/mscorlib.dll -r:$A/System.dll -r:$A/System.Core.dll -r:$A/System.Drawing.dll \
  -r:$A/System.Windows.Forms.dll -r:$A/System.Net.Http.dll -r:$A/System.Web.Extensions.dll -r:$A/System.IO.Compression.dll -r:$A/System.IO.Compression.FileSystem.dll \
  src/*.cs
echo "built bin/PearNowPlaying.exe"
