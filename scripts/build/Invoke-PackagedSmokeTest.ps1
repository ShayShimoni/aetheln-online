<#
.SYNOPSIS
Proves that two packaged Windows clients connect to a packaged Linux dedicated server.

.DESCRIPTION
Starts the Linux server through a configurable launcher (WSL by default), starts two
Windows clients against an explicit endpoint, correlates server- and client-side log
observations, and writes script-owned JSONL evidence to smoke-evidence.jsonl.
LogRoot must be absent or empty so evidence from separate smoke runs cannot be mixed.

.EXAMPLE
.\scripts\build\Invoke-PackagedSmokeTest.ps1 `
  -ServerExecutable '/mnt/d/build/LinuxServer/AethelnOnlineServer.sh' `
  -ServerLauncherExecutable 'wsl.exe' `
  -ServerLauncherArguments @('-d','Ubuntu','-u','aethelnqa','--exec','{ServerExecutable}','{ServerMap}','-port=7777','-stdout','-FullStdOutLogOutput') `
  -ClientExecutable 'D:\build\WindowsClient\AethelnOnlineClient.exe' `
  -ClientBaseArguments @('{ServerEndpoint}','-stdout','-FullStdOutLogOutput') `
  -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' `
  -LogRoot 'D:\smoke\run-001' `
  -ServerReadyPattern 'GameNetDriver.*Listening.*{ServerEndpoint}' `
  -ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' `
  -ClientConnectedPattern 'Join succeeded.*{ServerEndpoint}' `
  -ClientMapPattern 'Bringing World.*{ServerMap}'

.PARAMETER ServerLauncherExecutable
Windows executable used to launch the packaged Linux server. Defaults to wsl.exe.

.PARAMETER ServerLauncherArguments
Launcher and server arguments. Must contain {ServerExecutable}, {ServerMap}, and
may contain {ServerEndpoint}. Server readiness is monitored from redirected launcher
stdout. {LogPath} is optional and requires ServerLogPath to be a Linux/WSL path.

.PARAMETER ServerLogPath
Optional Linux/WSL-compatible Unreal server log path substituted for {LogPath} in
ServerLauncherArguments. Windows LogRoot paths are never passed into WSL implicitly.

.PARAMETER ClientBaseArguments
Packaged-client arguments. Must contain {ServerEndpoint}; {ServerMap}, {ClientId},
and {LogPath} are also available. Client evidence is monitored from redirected stdout.

.PARAMETER ClientLogPath
Optional absolute client log-path template substituted for {LogPath}. Use {ClientId}
to give each process a distinct path. No LogRoot path is passed implicitly.

.PARAMETER ServerClientConnectedPattern
Regex applied to redirected server stdout. It must contain a named ConnectionId
capture. The smoke requires two unique captured values; they are transport evidence
and are intentionally not mapped to client names.

.PARAMETER CaptureStartup
Opt in to a create-only startup-capture.json record. Requires BuildProvenancePath
and ServerProvenanceExecutable. The record measures the two live Windows client
game processes, not the packaged root bootstrap. A WSL launcher is never
treated as a Linux server metric.
For capture only, ClientExecutable must be the provenance-listed inner
AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe. The general example
above uses the root bootstrap for the default smoke without capture.

.PARAMETER ServerProvenanceExecutable
Host-visible packaged Linux server launcher corresponding to ServerExecutable.
This path must uniquely match the server inventory in build-provenance.json.
Capture mode requires the default WSL /mnt/<drive>/ mapping of that exact path.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerExecutable,
	[string] $ServerLauncherExecutable = 'wsl.exe',
	[Parameter(Mandatory)] [string[]] $ServerLauncherArguments,
	[string] $ServerLogPath,
	[Parameter(Mandatory)] [string] $ClientExecutable,
	[Parameter(Mandatory)] [string[]] $ClientBaseArguments,
	[string] $ClientLogPath,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerEndpoint,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerMap,
	[Parameter(Mandatory)] [string] $LogRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerClientConnectedPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientConnectedPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientMapPattern,
	[ValidateNotNullOrEmpty()] [string] $ErrorPattern = '(?i)(fatal error|network\s+failure|connection\s+failed|connection\s+timed\s+out|connectiontimeout|failed to load package)',
	[ValidateRange(1, 3600)] [int] $TimeoutSeconds = 120,
	[switch] $CaptureStartup,
	[string] $BuildProvenancePath,
	[string] $ServerProvenanceExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Executable([string] $Name, [string] $Path) {
	if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
	$Command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $Command) { throw "$Name '$Path' does not exist and is not available on PATH." }
	return [string] $Command.Source
}

function Get-ProcessesUnderPath([string] $Root) {
	$ResolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$Prefix = $ResolvedRoot + [System.IO.Path]::DirectorySeparatorChar
	foreach ($Process in @(Get-Process -ErrorAction Stop)) {
		try { $ProcessPath = [string] $Process.Path } catch { continue }
		if ([string]::IsNullOrWhiteSpace($ProcessPath)) { continue }
		try { $FullProcessPath = [System.IO.Path]::GetFullPath($ProcessPath) } catch { continue }
		if ($FullProcessPath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $Process }
	}
}

function Resolve-ProcessIdentity($Process, [hashtable] $Baseline, [long] $BaselineTicks = 0) {
	# Baseline absence is not ownership proof: enumeration/path observation can miss
	# a pre-launch process. Require a readable start time beyond the captured boundary.
	# An observed PID with an unreadable baseline identity remains protected even if
	# its current identity becomes readable; an unknown identity never permits a kill.
	$ProcessId = [string] $Process.Id
	$Observed = $Baseline.ContainsKey($ProcessId)
	if ($Observed -and $null -eq $Baseline[$ProcessId]) { return 'unresolved' }
	try { $StartTicks = [long] $Process.StartTime.ToUniversalTime().Ticks } catch [System.SystemException] { return 'unresolved' }
	if ($Observed -and $StartTicks -eq [long] $Baseline[$ProcessId]) { return 'preexisting' }
	if (-not $Observed) {
		if ($BaselineTicks -le 0) { return 'unresolved' }
		if ($StartTicks -le $BaselineTicks) { return 'preexisting' }
	}
	return 'new'
}

function Test-IsPreexistingProcessIdentity($Process, [hashtable] $Baseline, [long] $BaselineTicks = 0) {
	# True when the process must not be terminated: proven preexisting or unresolved.
	return (Resolve-ProcessIdentity -Process $Process -Baseline $Baseline -BaselineTicks $BaselineTicks) -ne 'new'
}

function Get-PreexistingProcessIdentityBaseline([object[]] $Processes) {
	$Baseline = @{}
	foreach ($Process in @($Processes)) {
		# StartTime throws Win32Exception (access denied) or InvalidOperationException
		# (exited between enumeration and read). Record the PID with an unknown identity
		# so cleanup protects it instead of treating it as smoke-owned.
		try { $Baseline[[string] $Process.Id] = [long] $Process.StartTime.ToUniversalTime().Ticks } catch [System.SystemException] { $Baseline[[string] $Process.Id] = $null }
	}
	return $Baseline
}

function Initialize-EmptyLogRoot([string] $Path) {
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "LogRoot '$Path' exists but is not a directory." }
		$Existing = @(Get-ChildItem -LiteralPath $Path -Force)
		if ($Existing.Count -gt 0) { throw "LogRoot '$Path' must be absent or empty; found $($Existing.Count) existing item(s). Use a unique clean directory for each smoke run." }
	}
	else { New-Item -ItemType Directory -Path $Path | Out-Null }
	return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Placeholder([string[]] $Arguments, [string] $Placeholder, [string] $Name) {
	if (-not (($Arguments -join ' ') -like "*$Placeholder*")) { throw "$Name must contain $Placeholder so the smoke target is explicit." }
}

function Expand-ArgumentList([string[]] $Arguments, [string] $ClientId, [string] $LogPath, [string] $ServerExecutable) {
	$LogReplacement = if ($null -eq $LogPath) { '' } else { $LogPath }
	return @($Arguments | ForEach-Object {
		$_.Replace('{ClientId}', $ClientId).Replace('{LogPath}', $LogReplacement).Replace('{ServerExecutable}', $ServerExecutable).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap)
	})
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap))
}

function Write-Evidence([string] $Process, [string] $Role, [string] $EventName, [string] $Source, [string] $Detail, [string] $ConnectionId = '') {
	$Record = [ordered]@{
		schema = 'aetheln.packaged-smoke.evidence/v1'
		timestamp = [DateTime]::UtcNow.ToString('o')
		process = $Process
		role = $Role
		event = $EventName
		source = $Source
		detail = $Detail
	}
	if ($ConnectionId) { $Record['connection_id'] = $ConnectionId }
	$SerializedRecord = $Record | ConvertTo-Json -Compress
	$Encoding = [System.Text.UTF8Encoding]::new($true)
	$RecordBytes = $Encoding.GetBytes($SerializedRecord + [Environment]::NewLine)
	$Stream = $null
	# One orchestrator owns writes; observers may read concurrently. Opening with
	# write access avoids Add-Content's encoding-read fallback on a write-only
	# stream. Retry only sharing/lock failures before any record bytes are written.
	for ($Attempt = 1; $Attempt -le 50; $Attempt++) {
		try {
			$Stream = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
			break
		} catch [System.IO.IOException] {
			$ErrorCode = $_.Exception.GetBaseException().HResult -band 0xffff
			if ($ErrorCode -notin @(32, 33) -or $Attempt -eq 50) { throw }
			Start-Sleep -Milliseconds 20
		}
	}
	try {
		# Preserve Windows PowerShell's UTF-8 BOM, once at the start of a new file.
		if ($Stream.Length -eq 0) {
			$Preamble = $Encoding.GetPreamble()
			$Stream.Write($Preamble, 0, $Preamble.Length)
		}
		$Stream.Write($RecordBytes, 0, $RecordBytes.Length)
		$Stream.Flush()
	} finally { $Stream.Dispose() }
}

function Wait-ForEvidence([string] $ProcessName, [string] $Role, [System.Diagnostics.Process] $Process, [string] $Description, [string] $Path, [string] $ErrorPath, [string] $Pattern, [string] $EventName, [string] $ErrorPattern, [int] $TimeoutSeconds) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
			$ErrorLine = $Lines | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { throw "$ProcessName reported an error while waiting for $Description in '$Path': $ErrorLine" }
			$Match = $Lines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
			if ($Match) {
				Write-Evidence -Process $ProcessName -Role $Role -EventName $EventName -Source $Path -Detail $Match
				return
			}
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			$ExitCode = $Process.ExitCode
			if ($null -eq $ExitCode) { $ExitCode = 'unavailable from launcher' }
			throw "$ProcessName exited early with exit code $ExitCode while waiting for $Description. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for $Description for $ProcessName in '$Path' (pattern '$Pattern')."
}

function Wait-ForUniqueServerConnectionPair([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [string] $Pattern, [string] $ErrorPattern, [int] $TimeoutSeconds) {
	$Expression = [regex]::new($Pattern)
	if ($Expression.GetGroupNames() -notcontains 'ConnectionId') {
		throw 'ServerClientConnectedPattern must contain a named regex capture (?<ConnectionId>...).'
	}
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	$Connections = @{}
	do {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
			$ErrorLine = $Lines | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { throw "server reported an error while waiting for two unique server connections in '$Path': $ErrorLine" }
			foreach ($Line in $Lines) {
				$Match = $Expression.Match($Line)
				if ($Match.Success) {
					$ConnectionId = $Match.Groups['ConnectionId'].Value
					if ($ConnectionId -and -not $Connections.ContainsKey($ConnectionId)) { $Connections[$ConnectionId] = $Line }
				}
			}
			if ($Connections.Count -ge 2) {
				foreach ($ConnectionId in @($Connections.Keys | Sort-Object | Select-Object -First 2)) {
					Write-Evidence -Process 'server' -Role 'server-observation' -EventName 'server_observed_connection' -Source $Path -Detail $Connections[$ConnectionId] -ConnectionId $ConnectionId
				}
				return
			}
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			$ExitCode = $Process.ExitCode
			if ($null -eq $ExitCode) { $ExitCode = 'unavailable from launcher' }
			throw "server exited early with exit code $ExitCode while waiting for two unique server connections; observed only $($Connections.Count) unique. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for two unique server connections; observed only $($Connections.Count) unique in '$Path' (pattern '$Pattern')."
}

function Wait-ForOwnedProcessExit($Process, [int] $TimeoutMilliseconds, [string] $Source) {
	# WaitForExit throws Win32Exception (handle could not be opened) or a SystemException
	# when no process is associated any more. Neither decides cleanup: the bounded rescan
	# loop does. Record the failure as evidence with PID and exception type only.
	try {
		if ($Process.WaitForExit($TimeoutMilliseconds)) { return $true }
		Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_wait_failed' -Source $Source -Detail "PID $($Process.Id): exit not confirmed within $TimeoutMilliseconds milliseconds."
	}
	catch [System.SystemException] {
		Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_wait_failed' -Source $Source -Detail "PID $($Process.Id): $($_.Exception.GetBaseException().GetType().Name)"
	}
	return $false
}

function Assert-NoReparsePath([string] $Root, [string] $FilePath) {
	$Current = $Root
	while ($true) {
		if (((Get-Item -LiteralPath $Current -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Packaged provenance executable path contains a reparse point.' }
		if ($Current -ieq $FilePath) { break }
		$Suffix = $FilePath.Substring($Current.Length).TrimStart([char[]]@('\', '/'))
		$Part = ($Suffix -split '[\\/]')[0]
		if (-not $Part) { throw 'Packaged provenance executable path is not canonical.' }
		$Current = Join-Path $Current $Part
	}
}

function Get-PackagedExecutableBinding([string] $Name, [string] $Path, [string] $ArchiveRoot, [object[]] $Inventory, [string] $Kind) {
	if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Packaged provenance $Name identity is missing." }
	$Root = (Resolve-Path -LiteralPath $ArchiveRoot).Path.TrimEnd([char[]]@('\', '/'))
	$Executable = (Resolve-Path -LiteralPath $Path).Path
	$Prefix = $Root + [System.IO.Path]::DirectorySeparatorChar
	if (-not $Executable.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Packaged provenance $Name identity is outside its archive." }
	Assert-NoReparsePath -Root $Root -FilePath $Executable
	$RelativePath = $Executable.Substring($Prefix.Length).Replace('\', '/')
	$InventoryEntries = @($Inventory | Where-Object { $_.kind -ceq $Kind -and $_.path -ceq $RelativePath })
	if ($InventoryEntries.Count -ne 1) { throw "Packaged provenance $Name identity is not unique in inventory." }
	$InventoryHash = [string] $InventoryEntries[0].sha256
	$ActualHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
	$ActualSize = (Get-Item -LiteralPath $Executable).Length
	if ($InventoryHash -cnotmatch '^[0-9a-f]{64}$' -or $ActualHash -cne $InventoryHash -or $ActualSize -ne $InventoryEntries[0].sizeBytes) { throw "Packaged provenance $Name identity does not match executable bytes." }
	return [ordered]@{ archiveRoot = $Root; relativePath = $RelativePath; sha256 = $ActualHash; sizeBytes = $ActualSize }
}

function Get-StartupProvenance([string] $Path, [string] $ClientPath, [string] $ServerPath, [scriptblock] $AfterProvenanceRead) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'BuildProvenancePath must identify an existing build-provenance.json file.' }
	$ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
	try {
		$ProvenanceBytes = [System.IO.File]::ReadAllBytes($ResolvedPath)
		$Json = [System.Text.UTF8Encoding]::new($false, $true).GetString($ProvenanceBytes)
		if ($Json.Length -gt 0 -and $Json[0] -eq [char] 0xfeff) { $Json = $Json.Substring(1) }
		if ($AfterProvenanceRead) { & $AfterProvenanceRead }
		$Document = $Json | ConvertFrom-Json
	} catch { throw 'BuildProvenancePath must contain valid UTF-8 JSON.' }
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try { $ProvenanceHash = ([BitConverter]::ToString($Hasher.ComputeHash($ProvenanceBytes))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
	$Revision = [string] $Document.source.revision
	$Configuration = [string] $Document.build.configuration
	if ($Document.schemaVersion -ne 2 -or $Document.source.clean -ne $true -or $Revision -cnotmatch '^[0-9a-f]{40}$' -or $Configuration -cnotin @('Development', 'Shipping', 'Test') -or $Document.build.clientPlatform -cne 'Win64' -or $Document.build.serverPlatform -cne 'Linux' -or $Document.host.buildIdentity -cne "AethelnOnline@$Revision/$Configuration") { throw 'Packaged provenance source and build identity is invalid.' }
	$Inventory = @($Document.artifacts.inventory)
	if ($Inventory.Count -lt 2) { throw 'Packaged provenance inventory is incomplete.' }
	$Client = Get-PackagedExecutableBinding -Name 'client' -Path $ClientPath -ArchiveRoot ([string] $Document.artifacts.clientArchive) -Inventory $Inventory -Kind 'client'
	if ($Client.relativePath -ine 'AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe') { throw 'CaptureStartup requires the inner packaged Win64 game executable, not a root bootstrap or unknown client layout.' }
	$Server = Get-PackagedExecutableBinding -Name 'server' -Path $ServerPath -ArchiveRoot ([string] $Document.artifacts.serverArchive) -Inventory $Inventory -Kind 'server'
	return [ordered]@{ path = $ResolvedPath; sha256 = $ProvenanceHash; sourceRevision = $Revision; configuration = $Configuration; client = $Client; server = $Server }
}

function Assert-ServerWslMapping([string] $LinuxPath, [string] $HostPath) {
	$CanonicalHostPath = (Resolve-Path -LiteralPath $HostPath).Path
	if ($CanonicalHostPath -cnotmatch '^(?<Drive>[A-Za-z]):\\(?<Relative>.+)$') { throw 'Startup capture requires a host-visible fixed-drive server executable.' }
	$ExpectedLinuxPath = '/mnt/' + $Matches.Drive.ToLowerInvariant() + '/' + $Matches.Relative.Replace('\', '/')
	if ($LinuxPath -cne $ExpectedLinuxPath) { throw 'ServerExecutable does not map to ServerProvenanceExecutable through the default WSL drive mount.' }
}

function Assert-StableStartupProvenance($Binding) {
	if ((Get-FileHash -LiteralPath $Binding.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Binding.sha256) { throw 'Startup capture provenance changed during smoke.' }
	foreach ($Kind in @('client', 'server')) {
		$ExecutableBinding = $Binding[$Kind]
		$Path = Join-Path $ExecutableBinding.archiveRoot ($ExecutableBinding.relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Startup capture $Kind executable changed during smoke." }
		Assert-NoReparsePath -Root $ExecutableBinding.archiveRoot -FilePath $Path
		if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExecutableBinding.sha256 -or (Get-Item -LiteralPath $Path).Length -ne $ExecutableBinding.sizeBytes) { throw "Startup capture $Kind executable changed during smoke." }
	}
}

function Get-LiveClientSample([string] $ClientId, [System.Diagnostics.Process] $Process, [string] $ExpectedExecutable, [DateTime] $LaunchUtc, [DateTime] $MapConfirmedUtc) {
	$Process.Refresh()
	if ($Process.HasExited) { throw "Startup capture requires $ClientId to remain alive at the measurement boundary." }
	try {
		$ActualPath = [System.IO.Path]::GetFullPath([string] $Process.Path)
		$StartedUtc = $Process.StartTime.ToUniversalTime()
		$CpuMilliseconds = [math]::Round($Process.TotalProcessorTime.TotalMilliseconds, 3)
		$WorkingSet = [long] $Process.WorkingSet64
		$PeakWorkingSet = [long] $Process.PeakWorkingSet64
		$PrivateMemory = [long] $Process.PrivateMemorySize64
	} catch [System.SystemException] { throw "Startup capture could not read live Windows process metrics for $ClientId." }
	if (-not $ActualPath.Equals($ExpectedExecutable, [System.StringComparison]::OrdinalIgnoreCase) -or $StartedUtc -lt $LaunchUtc.AddSeconds(-1) -or $MapConfirmedUtc -lt $LaunchUtc -or $WorkingSet -le 0 -or $PeakWorkingSet -le 0 -or $PrivateMemory -le 0) { throw "Startup capture Windows process identity or measurements are invalid for $ClientId." }
	return [ordered]@{ id = $ClientId; pid = $Process.Id; processStartUtc = $StartedUtc.ToString('o'); launchUtc = $LaunchUtc.ToString('o'); mapObservedUtc = $MapConfirmedUtc.ToString('o'); launchToMapObservationMilliseconds = [math]::Round(($MapConfirmedUtc - $LaunchUtc).TotalMilliseconds, 3); cpuMilliseconds = $CpuMilliseconds; workingSetBytes = $WorkingSet; peakWorkingSetBytes = $PeakWorkingSet; privateMemoryBytes = $PrivateMemory }
}

function Initialize-CaptureDirectoryPin {
	if ($null -ne ('Aetheln.PackagedSmokeCaptureDirectory' -as [type])) { return }
	Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Aetheln {
 public static class PackagedSmokeCaptureDirectory {
  [StructLayout(LayoutKind.Sequential)] struct Information {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
   public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
  }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct RenameInfo {
   public uint ReplaceIfExists; public IntPtr RootDirectory; public uint FileNameLength; public char FileName;
  }
  [StructLayout(LayoutKind.Sequential)] struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
  [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length,MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
   public uint Length; public IntPtr RootDirectory,ObjectName; public uint Attributes;
   public IntPtr SecurityDescriptor,SecurityQualityOfService;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Information info);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle handle,int kind,IntPtr information,uint length);
  [DllImport("ntdll.dll",ExactSpelling=true)] static extern int NtSetInformationFile(SafeFileHandle handle,out IoStatusBlock result,IntPtr information,uint length,int kind);
  [DllImport("ntdll.dll",ExactSpelling=true)] static extern int NtCreateFile(out SafeFileHandle handle,uint access,ref ObjectAttributes attributes,out IoStatusBlock result,IntPtr allocation,uint fileAttributes,uint share,uint disposition,uint options,IntPtr extendedAttributes,uint extendedAttributesLength);
  public static SafeFileHandle Pin(string path) {
   // OPEN_REPARSE_POINT permits rejecting links. Some hosts still permit an
   // ancestor rename, so publication and disposal use file handles below.
   var handle=CreateFile(path,0xA0U,3U,IntPtr.Zero,3U,0x02200000U,IntPtr.Zero);
   if(handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error,"capture_directory_pin_failed"); }
   try {
    Information info;
    if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error(),"capture_directory_identity_failed");
    if((info.Attributes&0x400)!=0 || (info.Attributes&0x10)==0) throw new InvalidOperationException("capture_directory_reparse_or_kind_rejected");
    return handle;
   } catch { handle.Dispose(); throw; }
  }
  public static void RequirePath(SafeFileHandle directory,string expected) {
   Information info;
   if(!GetFileInformationByHandle(directory,out info) || (info.Attributes&0x400)!=0) throw new InvalidOperationException("capture_output_ancestor_changed");
   var path=new StringBuilder(4096);
   uint length=GetFinalPathNameByHandle(directory,path,(uint)path.Capacity,0);
   if(length==0 || length>=path.Capacity || !String.Equals(path.ToString(),@"\\?\"+expected,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("capture_output_ancestor_changed");
  }
  public static SafeFileHandle CreateTemporary(SafeFileHandle directory,string leaf) {
   if(String.IsNullOrEmpty(leaf) || leaf.IndexOfAny(new char[]{'\\','/',':'})>=0 || leaf.Length>32766) throw new InvalidOperationException("capture_temp_name_invalid");
   IntPtr name=Marshal.StringToHGlobalUni(leaf);
   IntPtr unicode=IntPtr.Zero;
   try {
    var text=new UnicodeString { Length=(ushort)(leaf.Length*2), MaximumLength=(ushort)(leaf.Length*2+2), Buffer=name };
    unicode=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
    Marshal.StructureToPtr(text,unicode,false);
    var attributes=new ObjectAttributes { Length=(uint)Marshal.SizeOf(typeof(ObjectAttributes)), RootDirectory=directory.DangerousGetHandle(), ObjectName=unicode, Attributes=0x1040U };
    SafeFileHandle handle;
    IoStatusBlock result;
    int status=NtCreateFile(out handle,0x40110080U,ref attributes,out result,IntPtr.Zero,0x80U,3U,2U,0x60U,IntPtr.Zero,0U);
    if(status<0) { if(handle!=null) handle.Dispose(); throw new InvalidOperationException("capture_temp_create_failed_ntstatus_"+((uint)status).ToString("X8")); }
    return handle;
   } finally { if(unicode!=IntPtr.Zero) Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(name); }
  }
  public static void Publish(SafeFileHandle file,SafeFileHandle directory,string leaf) {
   if(String.IsNullOrEmpty(leaf) || leaf.IndexOfAny(new char[]{'\\','/',':'})>=0) throw new InvalidOperationException("capture_final_name_invalid");
   byte[] name=Encoding.Unicode.GetBytes(leaf);
   int offset=(int)Marshal.OffsetOf(typeof(RenameInfo),"FileName");
   int size=Math.Max(Marshal.SizeOf(typeof(RenameInfo))+name.Length,offset+name.Length+2);
   IntPtr info=Marshal.AllocHGlobal(size);
   try {
    for(int i=0;i<size;i++) Marshal.WriteByte(info,i,0);
    Marshal.WriteIntPtr(info,(int)Marshal.OffsetOf(typeof(RenameInfo),"RootDirectory"),directory.DangerousGetHandle());
    Marshal.WriteInt32(info,(int)Marshal.OffsetOf(typeof(RenameInfo),"FileNameLength"),name.Length);
    Marshal.Copy(name,0,IntPtr.Add(info,offset),name.Length);
    IoStatusBlock result;
    int status=NtSetInformationFile(file,out result,info,(uint)size,10);
    if(status<0) throw new InvalidOperationException("capture_publish_failed_ntstatus_"+((uint)status).ToString("X8"));
   } finally { Marshal.FreeHGlobal(info); }
  }
  public static void Discard(SafeFileHandle file) {
   IntPtr info=Marshal.AllocHGlobal(1);
   try {
    Marshal.WriteByte(info,0,1);
    if(!SetFileInformationByHandle(file,4,info,1U)) throw new Win32Exception(Marshal.GetLastWin32Error(),"capture_temp_discard_failed");
   } finally { Marshal.FreeHGlobal(info); }
  }
 }
}
'@
}

function Get-CaptureDirectoryPins([string] $Directory) {
	if (-not [System.IO.Path]::IsPathRooted($Directory) -or $Directory -match '^[\\/]{2}') { throw 'Startup capture output directory must be a local absolute path.' }
	$Full = [System.IO.Path]::GetFullPath($Directory)
	Initialize-CaptureDirectoryPin
	$Pins = [System.Collections.Generic.List[object]]::new()
	$Current = [System.IO.Path]::GetPathRoot($Full)
	try {
		$Pins.Add([pscustomobject]@{ Path = $Current; Handle = [Aetheln.PackagedSmokeCaptureDirectory]::Pin($Current) })
		foreach ($Part in $Full.Substring($Current.Length).Split([char[]]'\/', [System.StringSplitOptions]::RemoveEmptyEntries)) {
			$Current = Join-Path $Current $Part
			$Pins.Add([pscustomobject]@{ Path = $Current; Handle = [Aetheln.PackagedSmokeCaptureDirectory]::Pin($Current) })
		}
		return ,$Pins
	} catch {
		for ($Index = $Pins.Count - 1; $Index -ge 0; $Index--) { $Pins[$Index].Handle.Dispose() }
		throw
	}
}

function Assert-CaptureDirectoryPins($Pins) {
	foreach ($Pin in $Pins) { [Aetheln.PackagedSmokeCaptureDirectory]::RequirePath($Pin.Handle, $Pin.Path) }
}

function Write-StartupCapture([string] $Path, $Document, [scriptblock] $AfterTempWrite, [scriptblock] $AfterDirectoryPin) {
	$Bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes(($Document | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
	$Parent = Split-Path -Parent $Path
	$DirectoryPins = Get-CaptureDirectoryPins -Directory $Parent
	$OutputDirectory = $DirectoryPins[$DirectoryPins.Count - 1].Handle
	$TempPath = Join-Path $Parent ('.startup-capture-' + [guid]::NewGuid().ToString('N') + '.tmp')
	$Stream = $null
	$Published = $false
	try {
		Assert-CaptureDirectoryPins -Pins $DirectoryPins
		if ($AfterDirectoryPin) { & $AfterDirectoryPin }
		$TempHandle = [Aetheln.PackagedSmokeCaptureDirectory]::CreateTemporary($OutputDirectory, [System.IO.Path]::GetFileName($TempPath))
		try {
			# The create is relative to the held directory, not a path that a
			# replaced mount point could redirect into unrelated output.
			Assert-CaptureDirectoryPins -Pins $DirectoryPins
			[Aetheln.PackagedSmokeCaptureDirectory]::RequirePath($TempHandle, $TempPath)
			$Stream = [System.IO.FileStream]::new($TempHandle, [System.IO.FileAccess]::Write)
		} catch {
			try { [Aetheln.PackagedSmokeCaptureDirectory]::Discard($TempHandle) } finally { $TempHandle.Dispose() }
			throw
		}
		$Stream.Write($Bytes, 0, $Bytes.Length)
		$Stream.Flush($true)
		if ($AfterTempWrite) { & $AfterTempWrite }
		[Aetheln.PackagedSmokeCaptureDirectory]::RequirePath($Stream.SafeFileHandle, $TempPath)
		Assert-CaptureDirectoryPins -Pins $DirectoryPins
		# The source and destination are handle-bound, not re-resolved path
		# strings. ReplaceIfExists is false, preserving any existing final file.
		[Aetheln.PackagedSmokeCaptureDirectory]::Publish($Stream.SafeFileHandle, $OutputDirectory, [System.IO.Path]::GetFileName($Path))
		Assert-CaptureDirectoryPins -Pins $DirectoryPins
		$Published = $true
	} finally {
		try {
			if ($null -ne $Stream) {
				try { if (-not $Published) { [Aetheln.PackagedSmokeCaptureDirectory]::Discard($Stream.SafeFileHandle) } } finally { $Stream.Dispose() }
			}
		} finally {
			for ($Index = $DirectoryPins.Count - 1; $Index -ge 0; $Index--) { $DirectoryPins[$Index].Handle.Dispose() }
		}
	}
}

Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerExecutable}' -Name 'ServerLauncherArguments'
Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerMap}' -Name 'ServerLauncherArguments'
Assert-Placeholder -Arguments $ClientBaseArguments -Placeholder '{ServerEndpoint}' -Name 'ClientBaseArguments'
if (($ServerLauncherArguments -join ' ') -like '*{LogPath}*' -and [string]::IsNullOrWhiteSpace($ServerLogPath)) {
	throw 'ServerLogPath must be supplied with a Linux/WSL-compatible path when ServerLauncherArguments contains {LogPath}.'
}
if (($ClientBaseArguments -join ' ') -like '*{LogPath}*' -and [string]::IsNullOrWhiteSpace($ClientLogPath)) {
	throw 'ClientLogPath must be supplied when ClientBaseArguments contains {LogPath}.'
}
if ($CaptureStartup) {
	if ([string]::IsNullOrWhiteSpace($BuildProvenancePath) -or [string]::IsNullOrWhiteSpace($ServerProvenanceExecutable)) { throw 'CaptureStartup requires BuildProvenancePath and ServerProvenanceExecutable.' }
} elseif ($BuildProvenancePath -or $ServerProvenanceExecutable) { throw 'BuildProvenancePath and ServerProvenanceExecutable require CaptureStartup.' }

$ResolvedLauncher = Resolve-Executable 'ServerLauncherExecutable' $ServerLauncherExecutable
$ResolvedClient = Resolve-Executable 'ClientExecutable' $ClientExecutable
$StartupProvenance = if ($CaptureStartup) { Get-StartupProvenance -Path $BuildProvenancePath -ClientPath $ResolvedClient -ServerPath $ServerProvenanceExecutable } else { $null }
if ($CaptureStartup) { Assert-ServerWslMapping -LinuxPath $ServerExecutable -HostPath $ServerProvenanceExecutable }
$ResolvedLogs = Initialize-EmptyLogRoot $LogRoot
$ClientPackageRoot = Split-Path -Parent $ResolvedClient
$EvidencePath = Join-Path $ResolvedLogs 'smoke-evidence.jsonl'
# Capture identities before filtering by executable path. A process whose Path is
# unreadable now may be visible under the package root later and must stay protected.
# Enumeration errors fail before any smoke process is launched.
$PreexistingClientProcessIdentities = Get-PreexistingProcessIdentityBaseline -Processes @(Get-Process -ErrorAction Stop)
$ClientProcessBaselineTicks = [DateTime]::UtcNow.Ticks
foreach ($UnknownProcessId in @($PreexistingClientProcessIdentities.Keys | Where-Object { $null -eq $PreexistingClientProcessIdentities[$_] })) {
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'preexisting_identity_unknown' -Source $ClientPackageRoot -Detail "PID $UnknownProcessId start time unreadable; protected from cleanup."
}
$ServerStdOutLog = Join-Path $ResolvedLogs 'server.stdout.log'
$ServerStdErrLog = Join-Path $ResolvedLogs 'server.stderr.log'
$Processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$ClientLaunchUtc = @{}
$ClientMapConfirmedUtc = @{}
$StartupCapture = $null
$SmokeSucceeded = $false

try {
	$ExpandedServerArguments = Expand-ArgumentList -Arguments $ServerLauncherArguments -ClientId 'server' -LogPath $ServerLogPath -ServerExecutable $ServerExecutable
	$ServerProcess = Start-Process -FilePath $ResolvedLauncher -ArgumentList $ExpandedServerArguments -RedirectStandardOutput $ServerStdOutLog -RedirectStandardError $ServerStdErrLog -WindowStyle Hidden -PassThru
	$Processes.Add($ServerProcess)
	Write-Evidence -Process 'server' -Role 'server' -EventName 'process_started' -Source $ResolvedLauncher -Detail ($ExpandedServerArguments -join ' ')
	Wait-ForEvidence -ProcessName 'server' -Role 'server' -Process $ServerProcess -Description 'server listen readiness' -Path $ServerStdOutLog -ErrorPath $ServerStdErrLog -Pattern (Expand-Pattern $ServerReadyPattern 'server') -EventName 'server_listening' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds

	$Clients = @{}
	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$ResolvedClientLogPath = if ($null -eq $ClientLogPath) { $null } else { $ClientLogPath.Replace('{ClientId}', $ClientId) }
		$ExpandedClientArguments = Expand-ArgumentList -Arguments $ClientBaseArguments -ClientId $ClientId -LogPath $ResolvedClientLogPath -ServerExecutable $ServerExecutable
		$ClientLaunchUtc[$ClientId] = [DateTime]::UtcNow
		$ClientProcess = Start-Process -FilePath $ResolvedClient -ArgumentList $ExpandedClientArguments -RedirectStandardOutput $ClientStdOutLog -RedirectStandardError $ClientStdErrLog -WindowStyle Hidden -PassThru
		$Processes.Add($ClientProcess)
		$Clients[$ClientId] = $ClientProcess
		Write-Evidence -Process $ClientId -Role 'client' -EventName 'process_started' -Source $ResolvedClient -Detail ($ExpandedClientArguments -join ' ')
	}
	Wait-ForUniqueServerConnectionPair -Process $ServerProcess -Path $ServerStdOutLog -ErrorPath $ServerStdErrLog -Pattern (Expand-Pattern $ServerClientConnectedPattern 'server') -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds

	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientProcess = $Clients[$ClientId]
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		Wait-ForEvidence -ProcessName $ClientId -Role 'client' -Process $ClientProcess -Description 'client connection confirmation' -Path $ClientStdOutLog -ErrorPath $ClientStdErrLog -Pattern (Expand-Pattern $ClientConnectedPattern $ClientId) -EventName 'client_connected' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds
		Wait-ForEvidence -ProcessName $ClientId -Role 'client' -Process $ClientProcess -Description 'client map confirmation' -Path $ClientStdOutLog -ErrorPath $ClientStdErrLog -Pattern (Expand-Pattern $ClientMapPattern $ClientId) -EventName 'client_map_confirmed' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds
		$ClientMapConfirmedUtc[$ClientId] = [DateTime]::UtcNow
	}
	if ($CaptureStartup) {
		$ServerProcess.Refresh()
		if ($ServerProcess.HasExited) { throw 'Startup capture requires the server launcher to remain alive at the measurement boundary.' }
		try { $ObservedServerLauncherPath = [System.IO.Path]::GetFullPath([string] $ServerProcess.Path) } catch [System.SystemException] { throw 'Startup capture could not identify the live Windows server launcher.' }
		if (-not $ObservedServerLauncherPath.Equals($ResolvedLauncher, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Startup capture observed a different Windows server launcher than was started.' }
		$SampleUtc = [DateTime]::UtcNow
		$ClientSamples = @(foreach ($ClientNumber in 1..2) {
			$ClientId = "client-$ClientNumber"
			Get-LiveClientSample -ClientId $ClientId -Process $Clients[$ClientId] -ExpectedExecutable $ResolvedClient -LaunchUtc $ClientLaunchUtc[$ClientId] -MapConfirmedUtc $ClientMapConfirmedUtc[$ClientId]
		})
		$StartupCapture = [ordered]@{
			schema = 'aetheln.packaged-smoke.startup-capture/v1'
			classification = 'measured'
			method = 'windows_host_launch_to_stdout_map_observation_upper_bound'
			issue = 45
			captureUtc = $SampleUtc.ToString('o')
			sourceRevision = $StartupProvenance.sourceRevision
			buildConfiguration = $StartupProvenance.configuration
			provenance = [ordered]@{ sha256 = $StartupProvenance.sha256; path = $StartupProvenance.path }
			package = [ordered]@{ client = $StartupProvenance.client; server = ([ordered]@{ archiveRoot = $StartupProvenance.server.archiveRoot; relativePath = $StartupProvenance.server.relativePath; sha256 = $StartupProvenance.server.sha256; sizeBytes = $StartupProvenance.server.sizeBytes; identityBasis = 'declared_provenance_inventory' }) }
			host = [ordered]@{ machineName = [Environment]::MachineName; os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString(); processorCount = [Environment]::ProcessorCount }
			scenario = [ordered]@{ id = 'two-client-packaged-smoke'; map = $ServerMap; endpoint = $ServerEndpoint; topology = [ordered]@{ status = 'unknown'; reason = 'configurable_launcher_no_process_to_host_topology_attestation' }; networkProfile = 'unknown'; actorMix = 'unknown'; representativeCombat = $false }
			serverLauncher = [ordered]@{ path = $ObservedServerLauncherPath; pid = $ServerProcess.Id; sha256 = (Get-FileHash -LiteralPath $ObservedServerLauncherPath -Algorithm SHA256).Hash.ToLowerInvariant(); identityBasis = 'observed_windows_process' }
			serverExecution = [ordered]@{ status = 'unknown'; reason = 'configured_launcher_stdout_does_not_attest_linux_server_process' }
			clients = $ClientSamples
			serverMetrics = [ordered]@{ status = 'unknown'; reason = 'linux_server_not_observed_by_windows_process_snapshot' }
			combatMetrics = [ordered]@{ status = 'unknown'; reason = 'two_client_smoke_not_representative_combat' }
			clientFrameGpuMetrics = [ordered]@{ status = 'unknown'; reason = 'process_snapshot_does_not_measure_frame_or_gpu_time' }
		}
	}
	Write-Evidence -Process 'orchestrator' -Role 'smoke' -EventName 'smoke_passed' -Source $EvidencePath -Detail "Two distinct clients connected to $ServerEndpoint on $ServerMap."
	$SmokeSucceeded = $true
	Write-Output "Packaged smoke test passed: the Linux server listened on '$ServerEndpoint' and observed two unique connections; both packaged Windows clients confirmed '$ServerMap'. Evidence: '$EvidencePath'."
}
finally {
	$CleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
	$DirectCleanupFailures = [System.Collections.Generic.List[string]]::new()
	foreach ($Process in $Processes) {
		try {
			try {
				if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop }
			} catch [System.SystemException] {
				Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_stop_failed' -Source $EvidencePath -Detail "PID $($Process.Id): $($_.Exception.GetBaseException().GetType().Name)"
			}
			$WaitMilliseconds = [int] [Math]::Max(0, [Math]::Min(5000, ($CleanupDeadline - [DateTime]::UtcNow).TotalMilliseconds))
			if (-not (Wait-ForOwnedProcessExit -Process $Process -TimeoutMilliseconds $WaitMilliseconds -Source $EvidencePath)) { $DirectCleanupFailures.Add([string] $Process.Id) }
		} finally { $Process.Dispose() }
	}
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_started' -Source $EvidencePath -Detail 'Scanning for smoke-owned package processes.'
	$QuiescentSince = $null
	do {
		$PackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot)
		$NewPackageProcesses = @($PackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'new' })
		$UnresolvedPackageProcesses = @($PackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'unresolved' })
		if ($NewPackageProcesses.Count -gt 0) {
			$QuiescentSince = $null
			foreach ($Process in $NewPackageProcesses) {
				Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
				$WaitMilliseconds = [int] [Math]::Max(0, [Math]::Min(5000, ($CleanupDeadline - [DateTime]::UtcNow).TotalMilliseconds))
				[void] (Wait-ForOwnedProcessExit -Process $Process -TimeoutMilliseconds $WaitMilliseconds -Source $ClientPackageRoot)
				$Process.Dispose()
			}
		} elseif ($UnresolvedPackageProcesses.Count -gt 0) {
			# Never terminate an unresolved process. Keep waiting, inside the same deadline,
			# for its identity to resolve or for it to vanish; quiescence cannot start yet.
			$QuiescentSince = $null
		} elseif ($null -eq $QuiescentSince) {
			$QuiescentSince = [DateTime]::UtcNow
		} elseif (([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -ge 2) {
			break
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $CleanupDeadline)
	$FinalPackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot)
	$UnresolvedProcessIds = @($FinalPackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'unresolved' } | ForEach-Object { [string] $_.Id })
	if ($UnresolvedProcessIds.Count -gt 0) {
		foreach ($UnresolvedProcessId in $UnresolvedProcessIds) {
			Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_unresolved' -Source $ClientPackageRoot -Detail "PID $UnresolvedProcessId identity unresolved; not terminated."
		}
		throw "Packaged client process cleanup found $($UnresolvedProcessIds.Count) process(es) with unresolved identity under the package root (PID $($UnresolvedProcessIds -join ', ')) within 10 seconds; they were not terminated and cleanup is not complete."
	}
	$RemainingPackageProcesses = @($FinalPackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'new' })
	if ($DirectCleanupFailures.Count -gt 0) {
		throw "Packaged smoke direct process cleanup could not confirm exit for PID $($DirectCleanupFailures -join ', ') within the bounded cleanup window; cleanup is not complete."
	}
	if ($RemainingPackageProcesses.Count -gt 0 -or $null -eq $QuiescentSince -or ([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -lt 2) {
		throw 'Packaged client process cleanup did not reach quiescence within 10 seconds.'
	}
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_complete' -Source $EvidencePath -Detail 'No smoke-owned package processes remained after the quiescence window.'
}
if ($CaptureStartup -and $SmokeSucceeded) {
	Assert-StableStartupProvenance -Binding $StartupProvenance
	$StartupCapture['smokeEvidence'] = [ordered]@{ sha256 = (Get-FileHash -LiteralPath $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant(); relativePath = 'smoke-evidence.jsonl'; cleanup = 'complete' }
	Write-StartupCapture -Path (Join-Path $ResolvedLogs 'startup-capture.json') -Document $StartupCapture
	Write-Output "Packaged startup capture written to '$(Join-Path $ResolvedLogs 'startup-capture.json')'."
}
