[CmdletBinding()]
param(
	[Parameter(Mandatory)][ValidateSet('AethelnOnlineClient', 'AethelnOnlineEditor', 'AethelnOnlineServer')][string] $Target,
	[Parameter(Mandatory)][ValidateSet('Win64', 'Linux')][string] $Platform,
	[Parameter(Mandatory)][ValidateRange(1, 4)][int] $ActionLimit,
	[Parameter(Mandatory)][string] $EngineRoot,
	[Parameter(Mandatory)][string] $TargetRoot,
	[Parameter(Mandatory)][string] $LinuxToolchainRoot,
	[Parameter(Mandatory)][string] $EvidenceRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$NativeExit = $null
$Failure = 'build_capture_failed'
$ResultStream = $null
try {
	# Linux builds only the server; client and editor targets build only on Win64.
	if (($Target -ceq 'AethelnOnlineServer') -ne ($Platform -ceq 'Linux')) { throw 'build_target_invalid' }
	foreach ($Path in @($EngineRoot, $TargetRoot, $LinuxToolchainRoot, $EvidenceRoot)) {
		if ($Path -cnotmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or $Path -match '[";%!&|<>^()\x00-\x1f]' -or -not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'build_path_invalid' }
		$Probe = [IO.Path]::GetFullPath($Path)
		while ($Probe) {
			if ((Get-Item -LiteralPath $Probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'build_path_invalid' }
			$Probe = Split-Path -Parent $Probe
		}
	}
	$Batch = Join-Path $EngineRoot 'Engine/Build/BatchFiles/Build.bat'
	$DotnetRoot = Join-Path $EngineRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	$Dotnet = Join-Path $DotnetRoot 'dotnet.exe'
	$Project = Join-Path $TargetRoot 'AethelnOnline.uproject'
	if (-not (Test-Path -LiteralPath $Batch -PathType Leaf) -or -not (Test-Path -LiteralPath $Project -PathType Leaf) -or -not (Test-Path -LiteralPath $Dotnet -PathType Leaf)) { throw 'build_input_missing' }
	foreach ($SourcePath in @($Batch, $Project, $Dotnet)) {
		$Probe = $SourcePath
		while ($Probe) {
			if ((Get-Item -LiteralPath $Probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'build_path_invalid' }
			$Probe = Split-Path -Parent $Probe
		}
	}
	$ResultStream = [IO.File]::Open((Join-Path $EvidenceRoot 'native-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
public static class PreparationBuildCapture {
 public static int? LastNativeExit;
 public static int Run(string cmd, string arguments, string cwd, string toolchain, string dotnetRoot, string log) {
  using (FileStream output = new FileStream(log, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
  using (Process process = new Process()) {
   process.StartInfo = new ProcessStartInfo(cmd, arguments) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=cwd };
   process.StartInfo.EnvironmentVariables["LINUX_MULTIARCH_ROOT"] = toolchain;
   // Pinned GetDotnetPath.bat accepts an already initialized bundled SDK.
   // Set every value in this child only; inherited system-dotnet overrides
   // cannot redirect the invocation, and no parent/global environment changes.
   process.StartInfo.EnvironmentVariables["UE_USE_SYSTEM_DOTNET"] = "0";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_VERSION"] = "10.0";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_ARCH"] = "win-x64";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_DIR"] = dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_ROOT"] = dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_ROOT_X64"] = dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_HOST_PATH"] = Path.Combine(dotnetRoot, "dotnet.exe");
   process.StartInfo.EnvironmentVariables["DOTNET_MULTILEVEL_LOOKUP"] = "0";
   process.StartInfo.EnvironmentVariables["DOTNET_ROLL_FORWARD"] = "LatestMajor";
   process.StartInfo.EnvironmentVariables["PATH"] = dotnetRoot + ";" + process.StartInfo.EnvironmentVariables["PATH"];
   // cmd honors this documented switch when resolving an unqualified executable.
   process.StartInfo.EnvironmentVariables["NoDefaultCurrentDirectoryInExePath"] = "1";
   process.StartInfo.EnvironmentVariables["PATHEXT"] = ".EXE;.COM;.BAT;.CMD";
   process.Start();
   object gate = new object(); long count=0; bool overflow=false;
   Action<Stream> drain = delegate(Stream input) {
    byte[] buffer=new byte[8192]; int n;
    try { while ((n=input.Read(buffer,0,buffer.Length))>0) {
     lock(gate) {
      if (count+n>16777216) { overflow=true; try { process.Kill(); } catch {} throw new IOException("build_output_limit"); }
      output.Write(buffer,0,n); count+=n;
      // Publish captured bytes to the OS before an owned hard stop can kill
      // this process. Do not force a physical disk sync for every log chunk.
      output.Flush(false);
     }
    } } catch { try { process.Kill(); } catch {} throw; }
   };
   Task stdout=Task.Run(()=>drain(process.StandardOutput.BaseStream));
   Task stderr=Task.Run(()=>drain(process.StandardError.BaseStream));
   try {
    process.WaitForExit();
    LastNativeExit = process.ExitCode;
    if (!Task.WaitAll(new[]{stdout,stderr},5000) || overflow) throw new IOException("build_capture_incomplete");
    output.Flush(true);
    return process.ExitCode;
   } finally { if (!process.HasExited) { try { process.Kill(); } catch {} } }
  }
 }
}
'@
	$Command = '""{0}" {1} {2} Development "{3}" -WaitMutex -NoHotReloadFromIDE -UBA -UBADisableRemote -NoXGE -NoSNDBS -NoFASTBuild -MaxParallelActions={4}"' -f $Batch, $Target, $Platform, $Project, $ActionLimit
	if ($Platform -ceq 'Win64') {
		# Supported by the pinned UEBuildWindows.cs and BuildMode.cs CommandLine attributes.
		# The editor shares the engine tree with contributor builds (TA-020): it omits
		# -Compiler so UBT resolves the same toolchain enum, and -NoEngineChanges makes
		# UBT exit 5 instead of rebuilding existing engine files.
		$Selection = if ($Target -ceq 'AethelnOnlineEditor') { ' -NoEngineChanges' } else { ' -Compiler=VisualStudio2022' }
		$Command = $Command.TrimEnd('"') + $Selection + ' -CompilerVersion=14.44.35207 -WindowsSDKVersion=10.0.26100.0"'
	}
	$Cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
	$NativeExit = [PreparationBuildCapture]::Run($Cmd, ('/d /s /c ' + $Command), $TargetRoot, $LinuxToolchainRoot, $DotnetRoot, (Join-Path $EvidenceRoot 'build.log'))
	$Failure = $null
} catch {
	if ('PreparationBuildCapture' -as [type]) { $NativeExit = [PreparationBuildCapture]::LastNativeExit }
	$Failure = 'build_capture_failed'
} finally {
	if ($null -ne $ResultStream) {
		try {
			$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ schemaVersion = 1; target = $Target; platform = $Platform; nativeExitCode = $NativeExit; infrastructureFailure = $Failure } | ConvertTo-Json -Compress))
			$ResultStream.Write($Bytes, 0, $Bytes.Length)
			$ResultStream.Flush($true)
		} finally { $ResultStream.Dispose() }
	}
}
if ($null -ne $Failure) { exit 1 }
exit $NativeExit
