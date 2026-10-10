[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($null -eq (Get-Variable -Name EngineRunnerHostLeases -Scope Script -ErrorAction SilentlyContinue)) {
	$script:EngineRunnerHostLeases = @{}
}
$script:EngineRunnerHostLeaseRepository = [IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot)))

function Initialize-EngineRunnerLeaseNative {
	if ($null -ne ('Aetheln.RoutineLeaseFile' -as [type])) { return }
	Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Aetheln {
 public static class RoutineLeaseFile {
  [StructLayout(LayoutKind.Sequential)] struct Information {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
   public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Information info);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
  static SafeFileHandle Open(string path,bool directory) {
   var handle=CreateFile(path,directory?0x80U:0xC0000000U,directory?3U:0U,IntPtr.Zero,directory?3U:4U,0x02200000,IntPtr.Zero);
   if(handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
   try {
    Information info;
    if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
    if((info.Attributes&0x400)!=0 || ((info.Attributes&0x10)!=0)!=directory || (!directory && info.Links!=1)) throw new InvalidOperationException("lease_path_invalid");
    var finalPath=new StringBuilder(1024);
    uint length=GetFinalPathNameByHandle(handle,finalPath,1024,0);
    if(length==0 || length>=1024 || !String.Equals(finalPath.ToString(),@"\\?\"+path,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("lease_path_invalid");
    return handle;
   } catch { handle.Dispose(); throw; }
  }
  public static SafeFileHandle Pin(string path) { return Open(path,true); }
  public static FileStream Acquire(string path) {
   var handle=Open(path,false);
   try { return new FileStream(handle,FileAccess.ReadWrite); } catch { handle.Dispose(); throw; }
  }
 }
}
'@
}

function Resolve-EngineRunnerLeasePath {
	param([string] $Path)
	# Only local, canonical drive paths; reject sensitive names before opening anything.
	if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 240 -or
		$Path.Substring(2) -match '[:*?"<>|\x00-\x1f]' -or
		$Path -match '(^|[\\/])(\.env[^\\/]*|\.ssh|\.aws|\.azure|\.credentials[^\\/]*|credentials[^\\/]*|secrets?[^\\/]*|id_rsa[^\\/]*|id_ed25519[^\\/]*)([\\/]|$)' -or
		$Path -match '\.(pem|key|pfx|p12)$') { throw 'lease_path_invalid' }
	$Full = [IO.Path]::GetFullPath($Path)
	if ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Full))).DriveType -ne [IO.DriveType]::Fixed) { throw 'lease_path_invalid' }
	if ($Full -cne $Path.Replace('/', '\') -or [IO.Path]::GetFileName($Full) -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.lease(?:\.json)?$') { throw 'lease_path_invalid' }
	foreach ($Root in @($script:EngineRunnerHostLeaseRepository)) {
		if ($Full.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'lease_path_invalid' }
	}
	$Repo = Get-Variable -Name RepositoryRoot -Scope Script -ErrorAction SilentlyContinue
	if ($null -ne $Repo -and -not [string]::IsNullOrWhiteSpace([string] $Repo.Value)) {
		$Root = [IO.Path]::GetFullPath([string] $Repo.Value).TrimEnd('\')
		if ($Full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'lease_path_invalid' }
	}
	return $Full
}

function Assert-EngineRunnerLeaseJournal {
	param([IO.FileStream] $Stream)
	if ($Stream.Length -gt 65536) { throw 'lease_journal_limit' }
	if ($Stream.Length -eq 0) { return }
	try {
		$Bytes = New-Object byte[] ([int] $Stream.Length)
		$Offset = 0
		while ($Offset -lt $Bytes.Length) {
			$Count = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
			if ($Count -lt 1) { throw 'lease_owner_ambiguous' }
			$Offset += $Count
		}
		$Journal = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes)
		if (-not $Journal.EndsWith("`n") -or $Journal.Contains('\')) { throw 'lease_owner_ambiguous' }
		$Held = $null
		$Seen = @{}
		foreach ($Line in @($Journal.Split([char] 10) | Where-Object { $_.Length -gt 0 })) {
			$Record = $Line | ConvertFrom-Json
			$Fields = @('schemaVersion', 'state', 'leaseId', 'attemptId', 'cleanupVerified')
			if ($Record.state -ceq 'held') { $Fields = @('schemaVersion', 'state', 'leaseId', 'attemptId', 'ownerPid', 'ownerStartUtc') }
			$Keys = [regex]::Matches($Line, '"([^"\\]+)"\s*:')
			if ($Keys.Count -ne $Fields.Count -or @($Record.PSObject.Properties).Count -ne $Fields.Count) { throw 'lease_owner_ambiguous' }
			foreach ($Field in $Fields) {
				if (@($Keys | Where-Object { $_.Groups[1].Value -ceq $Field }).Count -ne 1 -or $Record.PSObject.Properties.Name -cnotcontains $Field) { throw 'lease_owner_ambiguous' }
			}
			if ($Record.schemaVersion -isnot [int] -or $Record.schemaVersion -ne 1 -or
				$Record.leaseId -isnot [string] -or $Record.leaseId -cnotmatch '^[a-f0-9]{32}$' -or
				$Record.attemptId -isnot [string] -or $Record.attemptId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'lease_owner_ambiguous' }
			if ($Record.state -ceq 'held') {
				$Start = [DateTime]::MinValue
				if ($null -ne $Held -or $Seen.ContainsKey($Record.leaseId) -or $Record.ownerPid -isnot [int] -or $Record.ownerPid -le 0 -or
					$Record.ownerStartUtc -isnot [string] -or -not [DateTime]::TryParseExact($Record.ownerStartUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $Start) -or $Start.Kind -ne [DateTimeKind]::Utc) { throw 'lease_owner_ambiguous' }
				$Held = $Record
				$Seen[$Record.leaseId] = $true
			} elseif ($Record.state -ceq 'released') {
				if ($null -eq $Held -or $Record.leaseId -cne $Held.leaseId -or $Record.attemptId -cne $Held.attemptId -or
					$Record.cleanupVerified -isnot [bool] -or -not $Record.cleanupVerified) { throw 'lease_owner_ambiguous' }
				$Held = $null
			} else { throw 'lease_owner_ambiguous' }
		}
		if ($Seen.Count -eq 0 -or $null -ne $Held) { throw 'lease_owner_ambiguous' }
	} catch { throw 'lease_owner_ambiguous' }
}

function Get-EngineRunnerLeaseRemainingMillisecondCount {
	param($Context)
	$LocalRemaining = $Context.limit - $Context.clock.Elapsed.TotalMilliseconds
	if ($null -ne $Context.budget) {
		if ($LocalRemaining -le 0) { throw 'compile_timeout' }
		try { $Fresh = & $Context.budget } catch {
			if ($_.Exception.Message -cin @('compile_timeout', 'compile_clock_invalid', 'resource_pressure', 'disk_floor_reached')) { throw }
			throw 'compile_clock_invalid'
		}
		if ($null -eq $Fresh -or $Fresh.GetType().FullName -cnotin @('System.Int32', 'System.Int64', 'System.Double', 'System.Decimal', 'System.Single', 'System.UInt32', 'System.UInt64', 'System.Int16', 'System.UInt16', 'System.Byte', 'System.SByte') -or [double]::IsNaN([double] $Fresh) -or [double]::IsInfinity([double] $Fresh)) { throw 'compile_clock_invalid' }
		if ($Fresh -le 0) { throw 'compile_timeout' }
		$Context.limit = [Math]::Min($Context.limit, $Context.clock.Elapsed.TotalMilliseconds + [double] $Fresh)
		$Remaining = $Context.limit - $Context.clock.Elapsed.TotalMilliseconds
		if ($Remaining -le 0) { throw 'compile_timeout' }
	} else {
		$Remaining = [Math]::Min($LocalRemaining, ($Context.deadline - [DateTime]::UtcNow).TotalMilliseconds)
		if ($Remaining -le 0) { throw 'lease_deadline_elapsed' }
	}
	return $Remaining
}

function Get-EngineRunnerLeaseProgressBudget {
	param($Context)
	$null = Get-EngineRunnerLeaseRemainingMillisecondCount -Context $Context
	if ($null -ne $Context.progress) { & $Context.progress | Out-Null }
	return Get-EngineRunnerLeaseRemainingMillisecondCount -Context $Context
}

function Enter-EngineRunnerHostLease {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $LeasePath, [Parameter(Mandatory)][string] $OwnerId,
		[Parameter(Mandatory)] $DeadlineUtc, [scriptblock] $OnProgress, [scriptblock] $RemainingBudget)
	if ($OwnerId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'lease_owner_invalid' }
	if ($DeadlineUtc -isnot [DateTime] -or $DeadlineUtc.Kind -ne [DateTimeKind]::Utc) { throw 'lease_deadline_invalid' }
	if ($PSBoundParameters.ContainsKey('RemainingBudget') -and $null -eq $RemainingBudget) { throw 'compile_clock_invalid' }
	$BudgetContext = @{ deadline = $DeadlineUtc; clock = [Diagnostics.Stopwatch]::StartNew(); limit = [double]::PositiveInfinity; budget = $RemainingBudget; progress = $OnProgress }
	if ($null -eq $RemainingBudget) { $BudgetContext.limit = ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds }
	$null = Get-EngineRunnerLeaseProgressBudget -Context $BudgetContext
	$Full = Resolve-EngineRunnerLeasePath -Path $LeasePath
	if ($script:EngineRunnerHostLeases.ContainsKey($Full)) { throw 'lease_nested' }
	Initialize-EngineRunnerLeaseNative
	$Pins = New-Object 'Collections.Generic.List[IDisposable]'
	$Stream = $null
	try {
		$Ancestors = New-Object 'Collections.Generic.List[string]'
		$Parent = [IO.Path]::GetDirectoryName($Full)
		while ($Parent) { $Ancestors.Insert(0, $Parent); $Parent = [IO.Path]::GetDirectoryName($Parent) }
		foreach ($Ancestor in $Ancestors) {
			$null = Get-EngineRunnerLeaseProgressBudget -Context $BudgetContext
			try { $Pins.Add([Aetheln.RoutineLeaseFile]::Pin($Ancestor)) } catch { throw 'lease_path_invalid' }
		}
		while ($null -eq $Stream) {
			$null = Get-EngineRunnerLeaseProgressBudget -Context $BudgetContext
			try { $Stream = [Aetheln.RoutineLeaseFile]::Acquire($Full) } catch {
				$Cause = $_.Exception
				while ($null -ne $Cause.InnerException) { $Cause = $Cause.InnerException }
				if ($Cause -isnot [ComponentModel.Win32Exception] -or $Cause.NativeErrorCode -notin @(32, 33)) { throw 'lease_path_invalid' }
				$Milliseconds = Get-EngineRunnerLeaseProgressBudget -Context $BudgetContext
				Start-Sleep -Milliseconds ([int] [Math]::Max(1, [Math]::Min(200, [Math]::Ceiling($Milliseconds))))
			}
		}
		Assert-EngineRunnerLeaseJournal -Stream $Stream
		$Lease = [pscustomobject][ordered]@{ leaseId = [guid]::NewGuid().ToString('N'); ownerId = $OwnerId;
			ownerPid = $PID; ownerStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); path = $Full }
		$Held = [ordered]@{ schemaVersion = 1; state = 'held'; leaseId = $Lease.leaseId; attemptId = $OwnerId;
			ownerPid = $Lease.ownerPid; ownerStartUtc = $Lease.ownerStartUtc }
		$Release = [ordered]@{ schemaVersion = 1; state = 'released'; leaseId = $Lease.leaseId; attemptId = $OwnerId; cleanupVerified = $true }
		$HeldBytes = [Text.Encoding]::UTF8.GetBytes(($Held | ConvertTo-Json -Compress) + "`n")
		$ReleaseBytes = [Text.Encoding]::UTF8.GetBytes(($Release | ConvertTo-Json -Compress) + "`n")
		$null = Get-EngineRunnerLeaseProgressBudget -Context $BudgetContext
		# The journal passed Assert-EngineRunnerLeaseJournal, so every held record is released: no owner needs the old pairs.
		if ($Stream.Length + $HeldBytes.Length + $ReleaseBytes.Length -gt 65536) { $Stream.SetLength(0); $Stream.Position = 0 }
		$Stream.Write($HeldBytes, 0, $HeldBytes.Length)
		$Stream.Flush($true)
		$script:EngineRunnerHostLeases[$Full] = @{ lease = $Lease; identity = ($Lease | ConvertTo-Json -Compress);
			stream = $Stream; pins = $Pins; release = $ReleaseBytes }
		return $Lease
	} catch {
		if ($null -ne $Stream) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
		throw
	}
}

function Get-EngineRunnerHostLeaseEntry {
	param($Lease)
	try {
		$Entry = $script:EngineRunnerHostLeases[$Lease.path]
		if ($null -eq $Entry -or -not [object]::ReferenceEquals($Entry.lease, $Lease) -or
			($Lease | ConvertTo-Json -Compress) -cne $Entry.identity -or $Lease.ownerPid -ne $PID -or
			$Lease.ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') -or -not $Entry.stream.CanWrite) { throw 'lease_lost' }
		return $Entry
	} catch { throw 'lease_lost' }
}

function Close-EngineRunnerHostLease {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Lease)
	# Abandonment closes handles only. The held record intentionally blocks reuse.
	$Entry = Get-EngineRunnerHostLeaseEntry -Lease $Lease
	$Entry.stream.Dispose()
	foreach ($Pin in $Entry.pins) { $Pin.Dispose() }
	$script:EngineRunnerHostLeases.Remove($Lease.path)
}

function Exit-EngineRunnerHostLease {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Lease, [Parameter(Mandatory)] $CleanupVerified)
	$Entry = Get-EngineRunnerHostLeaseEntry -Lease $Lease
	if ($CleanupVerified -isnot [bool] -or -not $CleanupVerified) { throw 'cleanup_unproven' }
	# The supervising parent supplies literal true only after its owned job is quiescent.
	$Entry.stream.Write($Entry.release, 0, $Entry.release.Length)
	$Entry.stream.Flush($true)
	Close-EngineRunnerHostLease -Lease $Lease
}
