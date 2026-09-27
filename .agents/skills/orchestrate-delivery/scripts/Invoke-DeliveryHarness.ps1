[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RepositoryRoot,
	[Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository,
	[Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceRevision,
	[Parameter(Mandatory)] [ValidatePattern('^[1-9][0-9]{0,18}$')] [string] $RunId,
	[Parameter(Mandatory)] [ValidateRange(1, 1000000)] [int] $RunAttempt,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputPath,
	[ValidateRange(1, 3600)] [int] $PerTestTimeoutSeconds = 900,
	[ValidateRange(1, 14400)] [int] $OverallTimeoutSeconds = 7200,
	[ValidateRange(1024, 1048576)] [int] $MaximumChildOutputBytes = 262144,
	[ValidateRange(25, 5000)] [int] $CleanupGraceMilliseconds = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CanonicalTests = @(
	'Test-DeliveryAdaptiveRouting.ps1',
	'Test-DeliveryArtifactSchemas.ps1',
	'Test-DeliveryCompositeCandidate.ps1',
	'Test-DeliveryExternalFileIngest.ps1',
	'Test-DeliveryHandoffValidation.ps1',
	'Test-DeliverySourceInspection.ps1',
	'Test-DeliveryStageLauncher.ps1',
	'Test-DeliveryStagePreflight.ps1',
	'Test-DeliveryVerifierProfileContract.ps1'
)
$MaximumReportBytes = 4MB
$PowerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$RunClock = [Diagnostics.Stopwatch]::StartNew()
$RunStartedUtc = [DateTime]::UtcNow
$Results = [Collections.Generic.List[object]]::new()
$InfrastructureFailure = $false
$RunFailureReason = 'none'
$Terminal = $true
$WorkRoot = $null
$WorkRootCleanupVerified = $false

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace AethelnDeliveryHarness {
 public sealed class ProcessJob : IDisposable {
  IntPtr handle;
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long processTime,jobTime; public uint flags; public UIntPtr minimum,maximum; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits basic; public IoCounters io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
  [StructLayout(LayoutKind.Sequential)] struct Accounting { public long userTime,kernelTime,periodUser,periodKernel; public uint faults,total,active,terminated; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr returned);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr value);
  public ProcessJob() {
   handle=CreateJobObject(IntPtr.Zero,null);
   if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed");
   ExtendedLimits limits=new ExtendedLimits(); limits.basic.flags=0x2000;
   if(!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { int error=Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error,"SetInformationJobObject failed"); }
  }
  public void Assign(IntPtr process) { if(handle==IntPtr.Zero) throw new ObjectDisposedException("ProcessJob"); if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed"); }
  public uint ActiveProcesses() { if(handle==IntPtr.Zero) throw new ObjectDisposedException("ProcessJob"); Accounting info; if(!QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(),"QueryInformationJobObject failed"); return info.active; }
  public void Terminate() { if(handle==IntPtr.Zero) throw new ObjectDisposedException("ProcessJob"); if(!TerminateJobObject(handle,1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"TerminateJobObject failed"); }
  public void Dispose() { IntPtr current=handle; handle=IntPtr.Zero; if(current!=IntPtr.Zero) CloseHandle(current); GC.SuppressFinalize(this); }
  ~ProcessJob() { Dispose(); }
 }
}
'@

function Get-Sha256Hex([byte[]] $Bytes) {
	$Algorithm = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Algorithm.Dispose() }
}

function Get-FileSha256Hex([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function ConvertTo-SingleQuotedLiteral([string] $Value) {
	return "'" + $Value.Replace("'", "''") + "'"
}

function Get-FileLength([string] $Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [long] 0 }
	return [IO.FileInfo]::new($Path).Length
}

function Wait-JobEmpty {
	param($Job, [int] $Milliseconds)
	$Clock = [Diagnostics.Stopwatch]::StartNew()
	do {
		$Remaining = $Job.ActiveProcesses()
		if ($Remaining -eq 0) { return $true }
		if ($Clock.ElapsedMilliseconds -ge $Milliseconds) { return $false }
		Start-Sleep -Milliseconds 25
	} while ($true)
}

function Stop-OwnedJob {
	param($Job)
	try { $Job.Terminate() } catch { return $false }
	try { return Wait-JobEmpty -Job $Job -Milliseconds 5000 } catch { return $false }
}

function Get-ActualRevision([string] $Root) {
	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git.exe -ErrorAction Stop).Source
	# ProcessStartInfo does not interpret PowerShell quotes; use ordinary quoted
	# command-line syntax after excluding a quote from the resolved path.
	if ($Root.Contains('"')) { throw 'repository_path_invalid' }
	$StartInfo.Arguments = '-C "' + $Root + '" rev-parse HEAD'
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) { throw 'revision_query_start_failed' }
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		if (-not $Process.WaitForExit(10000)) {
			try { $Process.Kill() } catch { Write-Verbose "Revision query termination failed: $($_.Exception.Message)" }
			throw 'revision_query_timeout'
		}
		$Process.WaitForExit()
		$Output = $OutputTask.GetAwaiter().GetResult().Trim()
		$null = $ErrorTask.GetAwaiter().GetResult()
		if ($Process.ExitCode -ne 0 -or $Output -cnotmatch '^[0-9a-f]{40}$') { throw 'revision_query_failed' }
		return $Output
	} finally { $Process.Dispose() }
}

function Get-DeliveryTestInventory([string] $TestRoot) {
	$Expected = @($CanonicalTests)
	$Files = @(Get-ChildItem -LiteralPath $TestRoot -Filter 'Test-Delivery*.ps1' -File -Recurse -Force -ErrorAction Stop)
	$Discovered = @($Files | ForEach-Object {
		$Relative = $_.FullName.Substring($TestRoot.Length).TrimStart('\', '/') -replace '\\', '/'
		$Relative
	} | Sort-Object -CaseSensitive)
	$Missing = @($Expected | Where-Object { $Discovered -cnotcontains $_ })
	$Unexpected = @($Discovered | Where-Object { $Expected -cnotcontains $_ })
	$Duplicates = @($Files | Group-Object -Property Name | Where-Object Count -gt 1 | ForEach-Object Name | Sort-Object -CaseSensitive)
	$UnsafePaths = @($Files | Where-Object {
		([IO.File]::GetAttributes($_.FullName) -band [IO.FileAttributes]::ReparsePoint) -ne 0
	} | ForEach-Object {
		$_.FullName.Substring($TestRoot.Length).TrimStart('\', '/') -replace '\\', '/'
	} | Sort-Object -CaseSensitive)
	return [pscustomobject][ordered]@{
		expected = $Expected
		discovered = $Discovered
		missing = $Missing
		unexpected = $Unexpected
		duplicates = $Duplicates
		unsafePaths = $UnsafePaths
		valid = ($Missing.Count -eq 0 -and $Unexpected.Count -eq 0 -and $Duplicates.Count -eq 0 -and $UnsafePaths.Count -eq 0 -and $Discovered.Count -eq $Expected.Count)
	}
}

function Read-ChildOutput {
	param([string] $Path, [bool] $Allowed)
	$Length = Get-FileLength $Path
	$Hash = Get-FileSha256Hex $Path
	if (-not $Allowed) {
		return [pscustomobject]@{ bytes = $Length; sha256 = $Hash; base64 = $null; captured = $false }
	}
	$Bytes = [IO.File]::ReadAllBytes($Path)
	if ($Bytes.Length -ne $Length -or (Get-FileLength $Path) -ne $Length) {
		return [pscustomobject]@{ bytes = (Get-FileLength $Path); sha256 = (Get-FileSha256Hex $Path); base64 = $null; captured = $false }
	}
	return [pscustomobject]@{
		bytes = [long] $Bytes.Length
		sha256 = Get-Sha256Hex $Bytes
		base64 = [Convert]::ToBase64String($Bytes)
		captured = $true
	}
}

function Invoke-DeliveryTest {
	param([string] $Name, [string] $Path, [string] $LogRoot, [int] $Ordinal)
	$StartedUtc = [DateTime]::UtcNow
	$Clock = [Diagnostics.Stopwatch]::StartNew()
	$StdOutPath = Join-Path $LogRoot ("$Ordinal-stdout.bin")
	$StdErrPath = Join-Path $LogRoot ("$Ordinal-stderr.bin")
	$ReceiptPath = Join-Path $LogRoot ("$Ordinal-exit.txt")
	[IO.File]::WriteAllBytes($StdOutPath, [byte[]] @())
	[IO.File]::WriteAllBytes($StdErrPath, [byte[]] @())
	$GateName = 'Local\AethelnDeliveryHarness-' + [guid]::NewGuid().ToString('N')
	$Gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $GateName)
	$ResultGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, ($GateName + '-result'))
	$Job = $null
	$Process = $null
	$TimedOut = $false
	$OutputLimitExceeded = $false
	$CleanupVerified = $false
	$ResultSignaled = $false
	$ExitCode = $null
	$FailureReason = 'none'
	try {
		$Bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$Gate = [Threading.EventWaitHandle]::OpenExisting('$GateName')
try { if (-not `$Gate.WaitOne(30000)) { throw 'ownership_handshake_timeout' } }
finally { `$Gate.Dispose() }
`$Info = [Diagnostics.ProcessStartInfo]::new()
`$Info.FileName = $(ConvertTo-SingleQuotedLiteral $PowerShellPath)
`$Info.Arguments = $(ConvertTo-SingleQuotedLiteral ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Path + '"'))
`$Info.WorkingDirectory = $(ConvertTo-SingleQuotedLiteral $RepositoryRoot)
`$Info.UseShellExecute = `$false
`$Info.CreateNoWindow = `$true
`$Info.RedirectStandardOutput = `$true
`$Info.RedirectStandardError = `$true
`$Child = [Diagnostics.Process]::new()
`$Child.StartInfo = `$Info
try {
	if (-not `$Child.Start()) { throw 'child_start_failed' }
	`$StdOutFile = [IO.File]::Open($(ConvertTo-SingleQuotedLiteral $StdOutPath), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
	`$StdErrFile = [IO.File]::Open($(ConvertTo-SingleQuotedLiteral $StdErrPath), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
	try {
		`$StdOutCopy = `$Child.StandardOutput.BaseStream.CopyToAsync(`$StdOutFile)
		`$StdErrCopy = `$Child.StandardError.BaseStream.CopyToAsync(`$StdErrFile)
		`$Child.WaitForExit()
		if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @(`$StdOutCopy, `$StdErrCopy), 5000)) { throw 'output_drain_incomplete' }
		`$StdOutFile.Flush(`$true)
		`$StdErrFile.Flush(`$true)
	} finally {
		`$StdOutFile.Dispose()
		`$StdErrFile.Dispose()
	}
	`$Exit = `$Child.ExitCode
	[IO.File]::WriteAllBytes($(ConvertTo-SingleQuotedLiteral $ReceiptPath), [Text.Encoding]::ASCII.GetBytes(([string] `$Exit)))
	`$Result = [Threading.EventWaitHandle]::OpenExisting('$GateName-result')
	try { [void] `$Result.Set() } finally { `$Result.Dispose() }
	exit `$Exit
} finally { `$Child.Dispose() }
"@
		$StartInfo = [Diagnostics.ProcessStartInfo]::new()
		$StartInfo.FileName = $PowerShellPath
		$StartInfo.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Bootstrap))
		$StartInfo.WorkingDirectory = $RepositoryRoot
		$StartInfo.UseShellExecute = $false
		$StartInfo.CreateNoWindow = $true
		$Job = [AethelnDeliveryHarness.ProcessJob]::new()
		$Process = [Diagnostics.Process]::new()
		$Process.StartInfo = $StartInfo
		if (-not $Process.Start()) { throw 'process_start_failed' }
		$Job.Assign($Process.Handle)
		[void] $Gate.Set()
		while (-not $Process.WaitForExit(25)) {
			$OutputBytes = (Get-FileLength $StdOutPath) + (Get-FileLength $StdErrPath)
			if ($OutputBytes -gt $MaximumChildOutputBytes) {
				$OutputLimitExceeded = $true
				$FailureReason = 'output_limit_exceeded'
				break
			}
			if ($Clock.Elapsed.TotalSeconds -ge $PerTestTimeoutSeconds -or $RunClock.Elapsed.TotalSeconds -ge $OverallTimeoutSeconds) {
				$TimedOut = $true
				$FailureReason = 'timeout'
				break
			}
		}
		if ($TimedOut -or $OutputLimitExceeded) {
			$CleanupVerified = Stop-OwnedJob $Job
			try { [void] $Process.WaitForExit(5000) } catch { $CleanupVerified = $false }
		} else {
			$Process.WaitForExit()
			$ResultSignaled = $ResultGate.WaitOne(0)
			if (-not (Wait-JobEmpty -Job $Job -Milliseconds $CleanupGraceMilliseconds)) {
				$FailureReason = 'leaked_child'
				$CleanupVerified = Stop-OwnedJob $Job
			} elseif (-not $ResultSignaled -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
				$FailureReason = 'result_incomplete'
				$CleanupVerified = $true
			} else {
				$CleanupVerified = $true
				$Receipt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($ReceiptPath)).Trim()
				$ParsedExit = 0
				if ($Receipt -cnotmatch '^-?[0-9]+$' -or -not [int]::TryParse($Receipt, [ref] $ParsedExit)) {
					$FailureReason = 'result_incomplete'
				} else { $ExitCode = $ParsedExit }
				if ($FailureReason -ceq 'none' -and $ExitCode -ne 0) { $FailureReason = 'nonzero_exit' }
			}
		}
	} catch {
		if ($FailureReason -ceq 'none') { $FailureReason = 'launch_or_capture_failed' }
		if ($null -ne $Job) { $CleanupVerified = Stop-OwnedJob $Job }
	} finally {
		if ($null -ne $Job) { $Job.Dispose() }
		if ($null -ne $Process) { $Process.Dispose() }
		$Gate.Dispose()
		$ResultGate.Dispose()
		$Clock.Stop()
	}

	$FinalBytes = (Get-FileLength $StdOutPath) + (Get-FileLength $StdErrPath)
	if ($FinalBytes -gt $MaximumChildOutputBytes) { $OutputLimitExceeded = $true }
	$CaptureAllowed = -not $OutputLimitExceeded
	$StdOut = Read-ChildOutput -Path $StdOutPath -Allowed $CaptureAllowed
	$StdErr = Read-ChildOutput -Path $StdErrPath -Allowed $CaptureAllowed
	$OutputCaptured = $StdOut.captured -and $StdErr.captured
	if (-not $OutputCaptured -and -not $OutputLimitExceeded) {
		$FailureReason = 'output_capture_changed'
	}
	if (-not $CleanupVerified) {
		$FailureReason = 'cleanup_incomplete'
	}
	$Passed = $FailureReason -ceq 'none' -and $ExitCode -eq 0 -and $ResultSignaled -and $OutputCaptured -and $CleanupVerified
	return [pscustomobject][ordered]@{
		name = $Name
		path = '.agents/skills/orchestrate-delivery/scripts/tests/' + $Name
		status = $(if ($Passed) { 'passed' } else { 'failed' })
		exitCode = $ExitCode
		timedOut = $TimedOut
		outputLimitExceeded = $OutputLimitExceeded
		outputCaptured = $OutputCaptured
		cleanupVerified = $CleanupVerified
		startedUtc = $StartedUtc.ToString('O')
		finishedUtc = [DateTime]::UtcNow.ToString('O')
		durationMilliseconds = [long] $Clock.ElapsedMilliseconds
		failureReason = $FailureReason
		stdoutBytes = [long] $StdOut.bytes
		stdoutSha256 = $StdOut.sha256
		stdoutBase64 = $StdOut.base64
		stderrBytes = [long] $StdErr.bytes
		stderrSha256 = $StdErr.sha256
		stderrBase64 = $StdErr.base64
		resultSignaled = $ResultSignaled
		terminal = ($ResultSignaled -or $TimedOut -or $OutputLimitExceeded -or $FailureReason -cne 'none')
	}
}

function Write-AtomicReport($Report, [string] $Path) {
	$Directory = Split-Path -Parent $Path
	if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = (Get-Location).Path }
	$null = New-Item -ItemType Directory -Path $Directory -Force
	$ResolvedDirectory = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
	$FinalPath = Join-Path $ResolvedDirectory (Split-Path -Leaf $Path)
	$Bytes = $Utf8NoBom.GetBytes(($Report | ConvertTo-Json -Depth 8 -Compress))
	if ($Bytes.Length -gt $MaximumReportBytes) { throw 'report_size_limit' }
	$TemporaryPath = Join-Path $ResolvedDirectory ('.delivery-harness-' + [guid]::NewGuid().ToString('N') + '.tmp')
	try {
		[IO.File]::WriteAllBytes($TemporaryPath, $Bytes)
		if ([IO.FileInfo]::new($TemporaryPath).Length -ne $Bytes.Length) { throw 'report_write_incomplete' }
		if (Test-Path -LiteralPath $FinalPath) { throw 'report_output_exists' }
		Move-Item -LiteralPath $TemporaryPath -Destination $FinalPath -ErrorAction Stop
		$Published = [IO.File]::ReadAllBytes($FinalPath)
		if ($Published.Length -ne $Bytes.Length -or (Get-Sha256Hex $Published) -cne (Get-Sha256Hex $Bytes)) { throw 'report_publication_mismatch' }
	} finally {
		if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force }
	}
}

$ResolvedRepository = $null
$ActualRevision = $null
$TestRoot = $null
$Inventory = [pscustomobject][ordered]@{
	expected = @($CanonicalTests); discovered = @(); missing = @($CanonicalTests)
	unexpected = @(); duplicates = @(); unsafePaths = @(); valid = $false
}

try {
	$ResolvedRepository = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
	$ExpectedRunner = Join-Path $ResolvedRepository '.agents\skills\orchestrate-delivery\scripts\Invoke-DeliveryHarness.ps1'
	if (-not [string]::Equals((Resolve-Path -LiteralPath $PSCommandPath).Path, (Resolve-Path -LiteralPath $ExpectedRunner).Path, [StringComparison]::OrdinalIgnoreCase)) {
		throw 'runner_identity_mismatch'
	}
	$ActualRevision = Get-ActualRevision $ResolvedRepository
	if ($ActualRevision -cne $SourceRevision) {
		$RunFailureReason = 'identity_mismatch'
		$InfrastructureFailure = $true
	} else {
		$TestRoot = Join-Path $ResolvedRepository '.agents\skills\orchestrate-delivery\scripts\tests'
		$Inventory = Get-DeliveryTestInventory $TestRoot
		if (-not $Inventory.valid) {
			$RunFailureReason = 'inventory_invalid'
			$InfrastructureFailure = $true
		} else {
			$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-delivery-harness-' + [guid]::NewGuid().ToString('N'))
			$null = New-Item -ItemType Directory -Path $WorkRoot
			for ($Index = 0; $Index -lt $CanonicalTests.Count; $Index++) {
				if ($RunClock.Elapsed.TotalSeconds -ge $OverallTimeoutSeconds) {
					$RunFailureReason = 'overall_timeout'
					$InfrastructureFailure = $true
					$Terminal = $true
					break
				}
				$Name = $CanonicalTests[$Index]
				$Result = Invoke-DeliveryTest -Name $Name -Path (Join-Path $TestRoot $Name) -LogRoot $WorkRoot -Ordinal ($Index + 1)
				$Results.Add($Result)
				if ($Result.status -cne 'passed') {
					$RunFailureReason = 'test_failure'
					if ($Result.failureReason -cne 'nonzero_exit') { $InfrastructureFailure = $true }
				}
				if (-not $Result.cleanupVerified) { break }
			}
		}
	}
} catch {
	$RunFailureReason = if ($RunFailureReason -ceq 'none') { 'runner_failure' } else { $RunFailureReason }
	$InfrastructureFailure = $true
	$Terminal = $true
} finally {
	if ($null -ne $WorkRoot) {
		try {
			if (Test-Path -LiteralPath $WorkRoot -PathType Container) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop }
			$WorkRootCleanupVerified = -not (Test-Path -LiteralPath $WorkRoot)
		} catch { $WorkRootCleanupVerified = $false }
	} else { $WorkRootCleanupVerified = $true }
}

if (-not $WorkRootCleanupVerified) {
	$InfrastructureFailure = $true
	$RunFailureReason = 'cleanup_incomplete'
}
$PassedCount = @($Results | Where-Object status -ceq 'passed').Count
$FailedCount = @($Results | Where-Object status -ceq 'failed').Count
$NotRunCount = $CanonicalTests.Count - $Results.Count
$AllChildCleanup = @($Results | Where-Object { -not $_.cleanupVerified }).Count -eq 0
$CleanupVerified = $WorkRootCleanupVerified -and $AllChildCleanup
$Complete = $Inventory.valid -and $Results.Count -eq $CanonicalTests.Count -and $NotRunCount -eq 0 -and $CleanupVerified -and @($Results | Where-Object { -not $_.terminal }).Count -eq 0
$Succeeded = $Complete -and $FailedCount -eq 0 -and -not $InfrastructureFailure
if ($Succeeded) { $RunFailureReason = 'none' }

$Report = [pscustomobject][ordered]@{
	schemaVersion = 1
	reportType = 'delivery-harness-v1'
	repository = $Repository
	revision = $SourceRevision
	actualRevision = $ActualRevision
	runId = $RunId
	runAttempt = $RunAttempt
	startedUtc = $RunStartedUtc.ToString('O')
	finishedUtc = [DateTime]::UtcNow.ToString('O')
	terminal = $Terminal
	complete = $Complete
	succeeded = $Succeeded
	cleanupVerified = $CleanupVerified
	infrastructureFailure = $InfrastructureFailure
	failureReason = $RunFailureReason
	inventory = $Inventory
	tests = $Results.ToArray()
	summary = [pscustomobject][ordered]@{
		total = $CanonicalTests.Count
		passed = $PassedCount
		failed = $FailedCount
		notRun = $NotRunCount
	}
}

try { Write-AtomicReport -Report $Report -Path $OutputPath }
catch {
	Write-Error "Delivery harness report publication failed: $($_.Exception.Message)"
	exit 1
}
if ($Succeeded) { exit 0 }
exit 1
