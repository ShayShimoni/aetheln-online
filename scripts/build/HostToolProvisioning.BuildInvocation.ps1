[CmdletBinding()]
param(
	[Parameter(Mandatory)][ValidateSet('UnrealEditor', 'UnrealPak', 'ShaderCompileWorker')][string] $Target,
	[Parameter(Mandatory)][ValidateRange(1, 4)][int] $ActionLimit,
	[Parameter(Mandatory)][string] $EngineRoot,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[string] $TempRoot,
	[string] $UbaRootDir,
	[string] $UbtLogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
$ResultStream = $null
$NativeExit = $null
$Failure = 'build_capture_failed'
try {
	foreach ($Root in @($EngineRoot, $EvidenceRoot) + @($TempRoot, $UbaRootDir | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
		if ($Root -cnotmatch '^[A-Za-z]:[\\/]' -or $Root.Length -gt 240 -or
			$Root.Substring(2) -match '[:";%!&|<>^()\x00-\x1f]' -or -not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'build_path_invalid' }
		Assert-InitialPreparationPlainPath -Path $Root -Reason 'build_path_invalid'
	}
	if (-not [string]::IsNullOrWhiteSpace($TempRoot)) { $env:TEMP = $TempRoot; $env:TMP = $TempRoot }
	$Batch = Join-Path $EngineRoot 'Engine/Build/BatchFiles/Build.bat'
	$DotnetRoot = Join-Path $EngineRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	$Dotnet = Join-Path $DotnetRoot 'dotnet.exe'
	foreach ($Path in @($Batch, $Dotnet)) {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'build_input_missing' }
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'build_path_invalid'
	}
	$Command = Get-HostToolBuildCommand -Target $Target -ActionLimit $ActionLimit -BuildBatch $Batch -UbaRootDir $UbaRootDir -LogPath $UbtLogPath
	$ResultStream = [IO.File]::Open((Join-Path $EvidenceRoot 'native-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
public static class HostToolProvisioningCapture {
 public static int? LastNativeExit;
 public static bool OutputLimitExceeded;
 public static int Run(string cmd, string arguments, string cwd, string dotnetRoot, string log, string tempRoot) {
  using(FileStream output=new FileStream(log,FileMode.CreateNew,FileAccess.Write,FileShare.Read))
  using(Process process=new Process()) {
   process.StartInfo=new ProcessStartInfo(cmd,arguments) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=cwd };
   process.StartInfo.EnvironmentVariables["UE_USE_SYSTEM_DOTNET"]="0";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_VERSION"]="10.0";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_ARCH"]="win-x64";
   process.StartInfo.EnvironmentVariables["UE_DOTNET_DIR"]=dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_ROOT"]=dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_ROOT_X64"]=dotnetRoot;
   process.StartInfo.EnvironmentVariables["DOTNET_HOST_PATH"]=Path.Combine(dotnetRoot,"dotnet.exe");
   process.StartInfo.EnvironmentVariables["DOTNET_MULTILEVEL_LOOKUP"]="0";
   process.StartInfo.EnvironmentVariables["DOTNET_ROLL_FORWARD"]="LatestMajor";
   process.StartInfo.EnvironmentVariables["PATH"]=dotnetRoot+";"+process.StartInfo.EnvironmentVariables["PATH"];
   process.StartInfo.EnvironmentVariables["NoDefaultCurrentDirectoryInExePath"]="1";
   process.StartInfo.EnvironmentVariables["PATHEXT"]=".EXE;.COM;.BAT;.CMD";
   if(!String.IsNullOrWhiteSpace(tempRoot)) {
    process.StartInfo.EnvironmentVariables["TEMP"]=tempRoot;
    process.StartInfo.EnvironmentVariables["TMP"]=tempRoot;
   }
   process.Start();
   object gate=new object(); long count=0; bool overflow=false;
   Action<Stream> drain=delegate(Stream input) {
    byte[] buffer=new byte[8192]; int n;
    try { while((n=input.Read(buffer,0,buffer.Length))>0) {
     lock(gate) {
      if(count+n>16777216) { overflow=true; OutputLimitExceeded=true; try { process.Kill(); } catch {} throw new IOException("build_output_limit"); }
      output.Write(buffer,0,n); count+=n; output.Flush(false);
     }
    } } catch { try { process.Kill(); } catch {} throw; }
   };
   Task stdout=Task.Run(()=>drain(process.StandardOutput.BaseStream));
   Task stderr=Task.Run(()=>drain(process.StandardError.BaseStream));
   try {
    process.WaitForExit(); LastNativeExit=process.ExitCode;
    bool drained;
    try { drained=Task.WaitAll(new[]{stdout,stderr},5000); }
    catch(AggregateException) { if(OutputLimitExceeded) throw new IOException("build_output_limit"); throw; }
    if(OutputLimitExceeded || overflow) throw new IOException("build_output_limit");
    if(!drained) throw new IOException("build_capture_incomplete");
    output.Flush(true); return process.ExitCode;
   } finally { if(!process.HasExited) { try { process.Kill(); } catch {} } }
  }
 }
}
'@
	$Arguments = $Command.arguments -join ' '
	$CommandLine = '""{0}" {1}"' -f $Batch, $Arguments
	$Cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
	$NativeExit = [HostToolProvisioningCapture]::Run($Cmd, ('/d /s /c ' + $CommandLine), $EngineRoot, $DotnetRoot, (Join-Path $EvidenceRoot 'build.log'), $TempRoot)
	$Failure = $null
} catch {
	if ('HostToolProvisioningCapture' -as [type]) { $NativeExit = [HostToolProvisioningCapture]::LastNativeExit }
	$Failure = if (('HostToolProvisioningCapture' -as [type]) -and [HostToolProvisioningCapture]::OutputLimitExceeded) {
		'build_output_limit'
	} else { 'build_capture_failed' }
} finally {
	if ($null -ne $ResultStream) {
		try {
			$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ schemaVersion = 1; target = $Target; nativeExitCode = $NativeExit; infrastructureFailure = $Failure } | ConvertTo-Json -Compress))
			$ResultStream.Write($Bytes, 0, $Bytes.Length); $ResultStream.Flush($true)
		} finally { $ResultStream.Dispose() }
	}
}
if ($null -ne $Failure) { exit 1 }
exit $NativeExit
