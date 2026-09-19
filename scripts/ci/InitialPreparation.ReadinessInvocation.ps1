[CmdletBinding()]
param([Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $EvidenceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
$Result = [ordered]@{ schemaVersion = 1; scope = 'ubt_dependency_rebuild_branch'; ready = $false;
	scanExitCode = $null; comparisonExitCode = $null; dependencySha256 = $null; scanSha256 = $null; failureCode = 'ubt_readiness_capture_failed' }
$ResultStream = $null
$Pins = New-Object Collections.ArrayList
$SourceStreams = New-Object Collections.ArrayList
try {
	foreach ($Path in @($EngineRoot, $EvidenceRoot)) {
		if ($Path -cnotmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or $Path -match '[";%!&|<>^()\x00-\x1f]' -or
			-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'ubt_readiness_path_invalid' }
	}
	if ($EvidenceRoot -match '\s' -or (Test-InitialPreparationWithin -Candidate $EvidenceRoot -Parent $EngineRoot) -or
		(Test-InitialPreparationWithin -Candidate $EngineRoot -Parent $EvidenceRoot)) { throw 'ubt_readiness_path_invalid' }
	foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot)) { [void] $Pins.Add($Pin) }
	$ResultStream = [IO.File]::Open((Join-Path $EvidenceRoot 'readiness-native-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	$Batch = Join-Path $EngineRoot 'Engine/Build/BatchFiles/DotnetDepends.bat'
	$Receipt = Join-Path $EngineRoot 'Engine/Intermediate/Build/UnrealBuildTool.dep.csv'
	$Dll = Join-Path $EngineRoot 'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll'
	$Solution = Join-Path $EngineRoot 'Engine/Source/Programs/UnrealBuildTool/UnrealBuildTool.sln'
	$DotnetRoot = Join-Path $EngineRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	$Dotnet = Join-Path $DotnetRoot 'dotnet.exe'
	$ReceiptStream = $null
	foreach ($Path in @($Batch, $Receipt, $Dll, $Solution, $Dotnet)) {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'ubt_readiness_input_missing' }
		foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $Path))) { [void] $Pins.Add($Pin) }
		$Stream = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($Path), [IO.FileAccess]::Read)
		[void] $SourceStreams.Add($Stream)
		if ($Path -ceq $Receipt) { $ReceiptStream = $Stream }
	}
	if ($ReceiptStream.Length -lt 1 -or $ReceiptStream.Length -gt 16MB) { throw 'ubt_dependency_scan_invalid' }
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { $Result.dependencySha256 = [BitConverter]::ToString($Hash.ComputeHash($ReceiptStream)).Replace('-', '').ToLowerInvariant() } finally { $Hash.Dispose() }
	$ScanPath = Join-Path $EvidenceRoot 'dependencies.csv'
	$Scratch = Join-Path $EvidenceRoot 'scan-temp'
	if ((Test-Path -LiteralPath $ScanPath) -or (Test-Path -LiteralPath $Scratch)) { throw 'ubt_readiness_capture_failed' }
	$null = New-Item -ItemType Directory -Path $Scratch
	foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Scratch)) { [void] $Pins.Add($Pin) }
	Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public static class PreparationReadinessCapture {
 public static int? LastExitCode;
 public static string Quote(string value) {
  StringBuilder result=new StringBuilder("\""); int slashes=0;
  foreach(char ch in value) {
   if(ch=='\\') { slashes++; continue; }
   if(ch=='"') { result.Append('\\',slashes*2+1); result.Append(ch); slashes=0; continue; }
   result.Append('\\',slashes); slashes=0; result.Append(ch);
  }
  result.Append('\\',slashes*2); result.Append('"'); return result.ToString();
 }
 public static int Run(string executable,string arguments,string cwd,string scratch,string dotnetRoot,string log) {
  LastExitCode=null;
  using(FileStream output=new FileStream(log,FileMode.CreateNew,FileAccess.Write,FileShare.Read))
  using(Process process=new Process()) {
   process.StartInfo=new ProcessStartInfo(executable,arguments) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=cwd };
   process.StartInfo.EnvironmentVariables["TEMP"]=scratch;
   process.StartInfo.EnvironmentVariables["TMP"]=scratch;
   // Same pinned bundled SDK selection as the build child. Never inherit the
   // system-dotnet or already-initialized branch from the invoking process.
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
   process.Start(); object gate=new object(); long count=0;
   Action<Stream> drain=delegate(Stream input) {
    byte[] buffer=new byte[8192]; int n;
    try { while((n=input.Read(buffer,0,buffer.Length))>0) { lock(gate) {
     if(count+n>1048576) throw new IOException("ubt_readiness_output_limit");
     output.Write(buffer,0,n); count+=n;
    } } } catch { try { process.Kill(); } catch {} throw; }
   };
   Task stdout=Task.Run(()=>drain(process.StandardOutput.BaseStream));
   Task stderr=Task.Run(()=>drain(process.StandardError.BaseStream));
   try {
    process.WaitForExit(); LastExitCode=process.ExitCode;
    if(!Task.WaitAll(new[]{stdout,stderr},5000)) throw new IOException("ubt_readiness_capture_incomplete");
    output.Flush(true); return process.ExitCode;
   } finally { if(!process.HasExited) { try { process.Kill(); } catch {} } }
  }
 }
}
'@
	# Pinned BuildUBT.bat uses this exact solution/Development Scan helper,
	# whose native concat + sort /+64 /unique preserves its CSV comparison.
	# Never call BuildUBT.bat: its mismatch branch builds and republishes UBT.
	$Command = '""{0}" Programs\UnrealBuildTool\UnrealBuildTool.sln {1} quiet"' -f $Batch, $ScanPath
	try {
		$Result.scanExitCode = [PreparationReadinessCapture]::Run((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), ('/d /s /c ' + $Command),
			(Join-Path $EngineRoot 'Engine/Source'), $Scratch, $DotnetRoot, (Join-Path $EvidenceRoot 'scan.log'))
	} catch { $Result.scanExitCode = [PreparationReadinessCapture]::LastExitCode; throw 'ubt_readiness_capture_failed' }
	if ($Result.scanExitCode -ne 0) { throw 'ubt_dependency_scan_failed' }
	if (-not (Test-Path -LiteralPath $ScanPath -PathType Leaf)) { throw 'ubt_dependency_scan_invalid' }
	$Scan = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($ScanPath), [IO.FileAccess]::Read)
	[void] $SourceStreams.Add($Scan)
	if ($Scan.Length -lt 1 -or $Scan.Length -gt 16MB) { throw 'ubt_dependency_scan_invalid' }
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { $Result.scanSha256 = [BitConverter]::ToString($Hash.ComputeHash($Scan)).Replace('-', '').ToLowerInvariant() } finally { $Hash.Dispose() }
	# Hold both CSVs against writes/replacement until native fc /C finishes.
	# fc /C compares ordered text case-insensitively, not parsed CSV dictionaries.
	$CompareArguments = '/C ' + [PreparationReadinessCapture]::Quote($ScanPath) + ' ' + [PreparationReadinessCapture]::Quote($Receipt)
	try {
		$Result.comparisonExitCode = [PreparationReadinessCapture]::Run((Join-Path ([Environment]::SystemDirectory) 'fc.exe'), $CompareArguments,
			$EvidenceRoot, $Scratch, $DotnetRoot, (Join-Path $EvidenceRoot 'comparison.log'))
	} catch { $Result.comparisonExitCode = [PreparationReadinessCapture]::LastExitCode; throw 'ubt_readiness_capture_failed' }
	if ($Result.comparisonExitCode -eq 1) { throw 'ubt_dependencies_changed' }
	if ($Result.comparisonExitCode -ne 0) { throw 'ubt_dependency_comparison_failed' }
	$Result.ready = $true
	$Result.failureCode = $null
} catch {
	$Codes = @('ubt_readiness_input_missing', 'ubt_readiness_path_invalid', 'ubt_dependency_scan_failed', 'ubt_dependency_scan_invalid', 'ubt_dependencies_changed', 'ubt_dependency_comparison_failed', 'ubt_readiness_capture_failed')
	$Result.failureCode = if ($_.Exception.Message -cin $Codes) { $_.Exception.Message } else { 'ubt_readiness_capture_failed' }
} finally {
	try {
		if ($null -ne $ResultStream) {
			$Bytes = [Text.Encoding]::UTF8.GetBytes(($Result | ConvertTo-Json -Compress))
			$ResultStream.Write($Bytes, 0, $Bytes.Length); $ResultStream.Flush($true)
		}
	} finally {
		if ($null -ne $ResultStream) { $ResultStream.Dispose() }
		foreach ($Stream in $SourceStreams) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
	}
}
if ($Result.ready) { exit 0 }
exit 1
