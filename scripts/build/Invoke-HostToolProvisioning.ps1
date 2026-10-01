<#
.SYNOPSIS
Explicit, bounded, non-clean provisioning of the pinned Windows host tools.
.DESCRIPTION
This operator-only entry point never runs UAT, never adds -clean, and never
creates a host-tools attestation. The separate Build-PackagedArtifacts.ps1
-Stage AttestHostTools step is required after reviewing a successful receipt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
	[switch] $Execute,
	[Parameter(Mandatory)][string] $EngineRoot,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[Parameter(Mandatory)][string] $HostLeasePath,
	[Parameter(Mandatory)][string] $CompilerPath,
	[Parameter(Mandatory)][string] $ResourceCompilerPath,
	[int] $UsefulWorkMinutes = 330,
	[int] $VerificationMinutes = 0,
	[string] $SupervisorEvidenceRoot,
	[string] $TempRoot,
	[string] $UbaRootDir,
	[string] $NativeLogRoot,
	[string] $ResumeReceiptPath,
	[string] $ResumeReceiptSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Publication.ps1')
. (Join-Path $PSScriptRoot '../ci/EngineRunnerHostLease.ps1')
$script:HostToolDiskWarningSent = $false

function Assert-HostToolPlainRoot {
	param([string] $Path, [string] $Reason)
	if ($Path -cnotmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 240 -or
		$Path.Substring(2) -match '[:";%!&|<>^\x00-\x1f]' -or
		[IO.Path]::GetFullPath($Path) -cne $Path.Replace('/', '\')) { throw $Reason }
	Assert-InitialPreparationPlainPath -Path $Path -Reason $Reason
	return [IO.Path]::GetFullPath($Path)
}

function Resolve-HostToolChildPowerShellPath {
	param([string] $SystemDirectory = [Environment]::SystemDirectory)
	if ([string]::IsNullOrWhiteSpace($SystemDirectory)) { throw 'child_powershell_unavailable' }
	# PSHOME is the pwsh installation under PowerShell 7, not Windows PowerShell.
	$PlainSystemDirectory = Assert-HostToolPlainRoot -Path $SystemDirectory -Reason 'child_powershell_unavailable'
	$Executable = Join-Path $PlainSystemDirectory 'WindowsPowerShell/v1.0/powershell.exe'
	if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'child_powershell_unavailable' }
	Assert-InitialPreparationPlainPath -Path $Executable -Reason 'child_powershell_unavailable'
	return $Executable
}

function Get-HostToolGitState {
	param([string] $Root, [switch] $IgnoreUntrackedGenerated)
	$Safe = 'safe.directory=' + $Root.Replace('\', '/')
	$Head = (& git -c $Safe -C $Root rev-parse HEAD 2>$null)
	if ($LASTEXITCODE -ne 0 -or @($Head).Count -ne 1) { throw 'git_identity_unavailable' }
	$Status = @(& git -c $Safe -C $Root status --porcelain=v1 --untracked-files=all 2>$null)
	if ($LASTEXITCODE -ne 0) { throw 'git_identity_unavailable' }
	if ($IgnoreUntrackedGenerated) {
		$Status = @($Status | Where-Object {
			$_ -cnotmatch '^\?\? Engine/(Binaries/Win64|Intermediate/Build|Binaries/DotNET/UnrealBuildTool)/' -and
			$_ -cnotmatch '^\?\? Engine/Plugins/.+/(Binaries/Win64|Intermediate/Build|bin|obj)/' -and
			$_ -cnotmatch '^\?\? Engine/Source/Programs/.+/(bin|obj)/'
		})
	}
	return [pscustomobject]@{ head = [string] $Head; status = ($Status -join "`n") }
}

function Get-HostToolRemainingMilliseconds {
	param([long] $DeadlineTicks)
	$Now = Get-InitialPreparationTick
	$Remaining = [Math]::Floor(([decimal] $DeadlineTicks - [decimal] $Now) * 1000 / [Diagnostics.Stopwatch]::Frequency)
	if ($Remaining -le 0) { throw 'cleanup_deadline' }
	return [double] $Remaining
}

function Get-HostToolCleanupWaitMilliseconds {
	param([long] $DeadlineTicks, [long] $NowTicks = (Get-InitialPreparationTick),
		[long] $Frequency = [Diagnostics.Stopwatch]::Frequency)
	if ($Frequency -lt 1) { throw 'monotonic_clock_unavailable' }
	$Remaining = [Math]::Floor(([decimal] $DeadlineTicks - [decimal] $NowTicks) * 1000 / $Frequency)
	return [int] [Math]::Min(600000, [Math]::Max(0, $Remaining))
}

function Invoke-HostToolPublicationWorker {
	param([string] $SupervisorRoot, [string] $EvidenceRoot, [Collections.IDictionary] $Receipt,
		[string] $ControllerRoot, $ResourceMonitor, [long] $DeadlineTicks)
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 9 -Compress))
	if ($Bytes.Length -lt 1 -or $Bytes.Length -gt 65536) { throw 'receipt_limit' }
	$MapName = 'AethelnHostToolPublication-' + [guid]::NewGuid().ToString('N')
	$Map = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($MapName, 65540)
	$ResultPath = Join-Path $SupervisorRoot ('publication-result-' + [guid]::NewGuid().ToString('N') + '.json')
	$Job = $null; $Process = $null; $Cleanup = $false
	try {
		$View = $Map.CreateViewAccessor()
		try {
			$View.Write(0, [int] $Bytes.Length)
			$View.WriteArray(4, $Bytes, 0, $Bytes.Length)
		} finally { $View.Dispose() }
		$Arguments = @('-NoProfile', '-NonInteractive', '-File',
			(Join-Path $PSScriptRoot 'HostToolProvisioning.PublicationWorker.ps1'),
			'-MapName', $MapName, '-SupervisorRoot', $SupervisorRoot,
			'-EvidenceRoot', $EvidenceRoot, '-DeadlineTicks', [string] $DeadlineTicks,
			'-ResultPath', $ResultPath)
		Initialize-InitialPreparationJob
		$Job = [Aetheln.PreparationJob]::new($DeadlineTicks)
		$Process = $Job.Start((Resolve-HostToolChildPowerShellPath), $Arguments, $ControllerRoot)
		while (-not $Process.WaitForExit(200)) {
			if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'publication_deadline' }
			if ($null -ne $ResourceMonitor) {
				$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
				Write-HostToolDiskWarning -ResourceMonitor $ResourceMonitor
			}
		}
		if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'publication_deadline' }
		$ExitCode = $Process.ExitCode
	} finally {
		if ($null -ne $Job) {
			try {
				$Wait = Get-HostToolCleanupWaitMilliseconds -DeadlineTicks $DeadlineTicks
				$Job.StopAndWait($Wait); $Cleanup = $Job.ActiveCount -eq 0
			} catch { $Cleanup = $false }
			$Job.Dispose()
			if (-not $Cleanup) { $script:HostToolOwnedCleanupVerified = $false }
		}
		if ($null -ne $Process) { $Process.Dispose() }
		$Map.Dispose()
	}
	if (-not $Cleanup) { throw 'publication_cleanup_unproven' }
	if ($ExitCode -ne 0) { throw 'publication_worker_failed' }
	$Result = Assert-HostToolPublicationResult -SupervisorRoot $SupervisorRoot -ResultPath $ResultPath -DeadlineTicks $DeadlineTicks
	$ConfirmedTicks = Get-InitialPreparationTick
	$CommitGuardTicks = 10L * [Diagnostics.Stopwatch]::Frequency
	if ($DeadlineTicks - $ConfirmedTicks -le $CommitGuardTicks) { throw 'publication_deadline' }
	$ConfirmationTempPath = Join-Path $SupervisorRoot ('publication-confirmed-' + [guid]::NewGuid().ToString('N') + '.tmp')
	$ConfirmationPath = Join-Path $SupervisorRoot 'publication-confirmed.json'
	$null = Write-HostToolProvisioningReceipt -Path $ConfirmationTempPath -Receipt ([ordered]@{
		schemaVersion = 1; scope = 'host_tool_supervisor_confirmation'; confirmed = $true;
		resultPath = $ResultPath; resultSha256 = $Result.resultSha256;
		dReceiptSha256 = $Result.dReceiptSha256; fReceiptSha256 = $Result.fReceiptSha256;
		confirmedTicks = $ConfirmedTicks; deadlineTicks = $DeadlineTicks })
	if ($DeadlineTicks - (Get-InitialPreparationTick) -le $CommitGuardTicks) { throw 'publication_deadline' }
	[IO.File]::Move($ConfirmationTempPath, $ConfirmationPath)
	if ((Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'publication_deadline' }
	return $Result
}

function Assert-HostToolExternalVolume {
	param([string] $Path, [string] $Reason)
	if ($Path -cnotmatch '^[Ff]:\\') { throw $Reason }
	$Volume = Get-Volume -DriveLetter F -ErrorAction Stop
	if ($Volume.UniqueId -cne '\\?\Volume{fd18ede5-0de4-431c-839e-3163c3427d30}\' -or
		$Volume.FileSystem -cne 'NTFS' -or $Volume.AllocationUnitSize -ne 4096) { throw 'external_volume_mismatch' }
	return $Volume
}

function Assert-HostToolAcPower {
	if (-not ('HostToolPowerStatus' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HostToolPowerStatus {
 [StructLayout(LayoutKind.Sequential)] struct PowerStatus {
  public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
  public UInt32 BatteryLifeTime, BatteryFullLifeTime;
 }
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetSystemPowerStatus(out PowerStatus status);
 public static bool IsOnAC() { PowerStatus status; if(!GetSystemPowerStatus(out status)) throw new InvalidOperationException("power_status_unavailable"); return status.ACLineStatus==1; }
}
'@
	}
	if (-not [HostToolPowerStatus]::IsOnAC()) { throw 'ac_power_required' }
}

function Enter-HostToolSleepPrevention {
	if (-not ('HostToolSleepPrevention' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HostToolSleepPrevention {
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint SetThreadExecutionState(uint flags);
 public static void Begin() { if(SetThreadExecutionState(0x80000001)==0) throw new InvalidOperationException("sleep_prevention_unavailable"); }
 public static void End() { SetThreadExecutionState(0x80000000); }
}
'@
	}
	[HostToolSleepPrevention]::Begin()
}

function Write-HostToolDiskWarning {
	param($ResourceMonitor)
	if ($script:HostToolDiskWarningSent -or $null -eq $ResourceMonitor) { return }
	foreach ($Volume in $ResourceMonitor.volumes) {
		if ($Volume.mount -match '^[Ff]:\\' -and $Volume.minimumAvailableBytes -lt 100GB) {
			Write-Warning 'F: free space has fallen below 100 GiB; the 20 GiB emergency floor remains enforced.'
			$script:HostToolDiskWarningSent = $true
			return
		}
	}
}

function Invoke-HostToolCheckpointWorker {
	param([ValidateSet('Create','Verify')][string] $Mode, [string] $EngineRoot, [string] $ManifestPath,
		$Header, [string] $SupervisorRoot, [string] $ControllerRoot, $ResourceMonitor, [long] $DeadlineTicks,
		[string] $ExpectedManifestSha256)
	$HeaderBytes = [Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Depth 15 -Compress))
	# Base64 expands by 4/3; leave room below Windows' 32,766-character
	# process command-line limit for quoted paths and all other arguments.
	if ($HeaderBytes.Length -gt 16000) { throw 'checkpoint_header_limit' }
	$ResultPath = Join-Path $SupervisorRoot ('checkpoint-' + $Mode.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N') + '.json')
	$Arguments = @('-NoProfile', '-NonInteractive', '-File',
		(Join-Path $PSScriptRoot 'HostToolProvisioning.CheckpointWorker.ps1'),
		'-Mode', $Mode, '-EngineRoot', $EngineRoot, '-ManifestPath', $ManifestPath,
		'-HeaderBase64', [Convert]::ToBase64String($HeaderBytes), '-ResultPath', $ResultPath)
	if ($Mode -ceq 'Verify') { $Arguments += @('-ExpectedManifestSha256', $ExpectedManifestSha256) }
	$ChildPowerShell = Resolve-HostToolChildPowerShellPath
	$Job = $null; $Process = $null; $Cleanup = $false
	try {
		Initialize-InitialPreparationJob
		$Job = [Aetheln.PreparationJob]::new($DeadlineTicks)
		$Process = $Job.Start($ChildPowerShell, $Arguments, $ControllerRoot)
		while (-not $Process.WaitForExit(200)) {
			if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'checkpoint_deadline' }
			$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
			Write-HostToolDiskWarning -ResourceMonitor $ResourceMonitor
		}
		if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'checkpoint_deadline' }
		$ExitCode = $Process.ExitCode
	} finally {
		if ($null -ne $Job) {
			try {
				$Wait = Get-HostToolCleanupWaitMilliseconds -DeadlineTicks $DeadlineTicks
				$Job.StopAndWait($Wait); $Cleanup = $Job.ActiveCount -eq 0
			} catch { $Cleanup = $false }
			$Job.Dispose()
			if (-not $Cleanup) { $script:HostToolOwnedCleanupVerified = $false }
		}
		if ($null -ne $Process) { $Process.Dispose() }
	}
	if (-not $Cleanup) { throw 'checkpoint_cleanup_unproven' }
	if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 65536) { throw 'checkpoint_worker_result_invalid' }
	$Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
	if ($Result.schemaVersion -ne 1 -or $Result.mode -cne $Mode -or $Result.success -ne $true -or
		$ExitCode -ne 0) { throw ('checkpoint_worker_failed:' + $Result.failure) }
	return $Result
}

function Invoke-HostToolIdentityProbe {
	param([ValidateSet('Controller','Engine','Fresh','Receipt','Product','Git','ReusedLog')][string] $Mode, [string] $Root,
		[bool] $Bootstrap, [string] $SupervisorRoot, [string] $ControllerRoot,
		$ResourceMonitor, [long] $DeadlineTicks,
		[ValidateSet('UnrealEditor','UnrealPak','ShaderCompileWorker')][string] $Target,
		[string] $ExpectedLogSha256, [switch] $IgnoreUntrackedGenerated)
	if (-not $Bootstrap) {
		if ($Mode -ceq 'Git') { return Get-HostToolGitState -Root $Root -IgnoreUntrackedGenerated:$IgnoreUntrackedGenerated }
		if ($Mode -ceq 'ReusedLog') { throw 'reused_log_bootstrap_only' }
		if ($Mode -ceq 'Controller') { return Assert-HostToolControllerInputIdentity -ControllerRoot $Root }
		if ($Mode -ceq 'Fresh') { throw 'fresh_probe_bootstrap_only' }
		if ($Mode -ceq 'Receipt') {
			if ([string]::IsNullOrWhiteSpace($Target)) { return Assert-HostToolReceiptSet -EngineRoot $Root }
			return Assert-HostToolReceiptSet -EngineRoot $Root -Targets @($Target)
		}
		if ($Mode -ceq 'Product') { return Get-HostToolProductState -EngineRoot $Root -Target $Target }
		return Assert-HostToolEngineInputIdentity -EngineRoot $Root
	}
	$ResultPath = Join-Path $SupervisorRoot ('identity-' + $Mode.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N') + '.json')
	$Arguments = @('-NoProfile', '-NonInteractive', '-File',
		(Join-Path $PSScriptRoot 'HostToolProvisioning.IdentityWorker.ps1'),
		'-Mode', $Mode, '-Root', $Root, '-ResultPath', $ResultPath)
	if ($Mode -in @('Product','ReusedLog') -or ($Mode -ceq 'Receipt' -and -not [string]::IsNullOrWhiteSpace($Target))) { $Arguments += @('-Target', $Target) }
	if ($Mode -ceq 'ReusedLog') { $Arguments += @('-ExpectedLogSha256', $ExpectedLogSha256) }
	if ($Mode -ceq 'Git' -and $IgnoreUntrackedGenerated) { $Arguments += '-IgnoreUntrackedGenerated' }
	$Job = $null; $Process = $null; $Cleanup = $false
	$DeadlineReason = Get-HostToolProbeDeadlineReason -DeadlineTicks $DeadlineTicks -UsefulDeadlineTicks $script:HostToolUsefulDeadlineTicks
	try {
		Initialize-InitialPreparationJob
		$Job = [Aetheln.PreparationJob]::new($DeadlineTicks)
		$Process = $Job.Start((Resolve-HostToolChildPowerShellPath), $Arguments, $ControllerRoot)
		while (-not $Process.WaitForExit(200)) {
			if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw $DeadlineReason }
			$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
			Write-HostToolDiskWarning -ResourceMonitor $ResourceMonitor
		}
		if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $DeadlineTicks) { throw $DeadlineReason }
		$ExitCode = $Process.ExitCode
	} finally {
		if ($null -ne $Job) {
			try {
				$CleanupDeadline = if ($DeadlineTicks -eq $script:HostToolUsefulDeadlineTicks) {
					$script:HostToolCleanupDeadlineTicks
				} else { $DeadlineTicks }
				$Wait = Get-HostToolCleanupWaitMilliseconds -DeadlineTicks $CleanupDeadline
				$Job.StopAndWait($Wait); $Cleanup = $Job.ActiveCount -eq 0
			} catch { $Cleanup = $false }
			$Job.Dispose()
			if (-not $Cleanup) { $script:HostToolOwnedCleanupVerified = $false }
		}
		if ($null -ne $Process) { $Process.Dispose() }
	}
	if (-not $Cleanup) { throw 'identity_probe_cleanup_unproven' }
	if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 4096) { throw 'identity_probe_result_invalid' }
	$Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
	if ($Result.schemaVersion -ne 1 -or $Result.mode -cne $Mode -or $Result.success -ne $true -or $ExitCode -ne 0) {
		throw ('identity_probe_failed:' + $Result.failure)
	}
	if ($Mode -eq 'Product') {
		$State = [ordered]@{}
		foreach ($Property in $Result.proof.PSObject.Properties) { $State[$Property.Name] = $Property.Value }
		return $State
	}
	if ($Mode -in @('Fresh','Receipt','Git','ReusedLog')) { return $Result.proof }
	return $true
}

function Assert-HostToolNativeResult {
	param($Result, [string] $Target, [int] $NativeExitCode)
	if (($Result.schemaVersion -isnot [int] -and $Result.schemaVersion -isnot [long]) -or
		$Result.schemaVersion -ne 1 -or $Result.target -cne $Target) { throw 'build_result_invalid' }
	if ($Result.infrastructureFailure -ceq 'build_output_limit') { throw 'build_output_limit' }
	if ($null -ne $Result.infrastructureFailure -or
		($Result.nativeExitCode -isnot [int] -and $Result.nativeExitCode -isnot [long]) -or
		$Result.nativeExitCode -ne $NativeExitCode) { throw 'build_result_invalid' }
}

function Test-HostToolQuietAlert {
	param([DateTime] $NowUtc, [DateTime] $LastAlertUtc, [DateTime] $LastOutputUtc)
	return (($NowUtc - $LastAlertUtc).TotalSeconds -ge 1800 -and
		($NowUtc - $LastOutputUtc).TotalSeconds -ge 1800)
}

function Assert-HostToolTargetDiskAdmission {
	param([long] $FreeBytes, [int] $NativeTargetsStarted)
	if ($FreeBytes -lt 0 -or $NativeTargetsStarted -lt 0) { throw 'disk_warning_admission_refused' }
	$MinimumFree = if ($NativeTargetsStarted -eq 0) { 300GB } else { 100GB }
	if ($FreeBytes -lt $MinimumFree) { throw 'disk_warning_admission_refused' }
	return [long] $MinimumFree
}

function Assert-HostToolCompletedTargetReceipt {
	param([ValidateSet('UnrealEditor','UnrealPak','ShaderCompileWorker')][string] $Target,
		[string] $EngineRoot, [bool] $Bootstrap, [string] $SupervisorRoot,
		[string] $ControllerRoot, $ResourceMonitor, [long] $DeadlineTicks)
	$Proof = Invoke-HostToolIdentityProbe -Mode Receipt -Root $EngineRoot -Target $Target -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ControllerRoot -ResourceMonitor $ResourceMonitor -DeadlineTicks $DeadlineTicks
	if ($Proof.semanticsVerified -ne $true -or $Proof.productCount -lt 1 -or $Proof.totalBytes -lt 1) { throw 'target_receipt_unproven' }
	return $Proof
}

function Invoke-HostToolNativeBuild {
	param([string] $Target, [int] $ActionLimit, [string] $ResolvedEngine, [string] $ResolvedController, [string] $ResolvedEvidence,
		[string] $ToolDirectory, [string] $SdkDirectory, [long] $UsefulDeadlineTicks,
		$ResourceMonitor, [Collections.ArrayList] $InvocationRecords,
		[string] $TempRoot, [string] $UbaRootDir, [string] $NativeLogRoot,
		[bool] $Bootstrap, [string] $SupervisorRoot, [bool] $AllowRecoveredNoOp,
		[string] $RecoverySourceReceiptSha256)
	$TargetEvidence = Join-Path $ResolvedEvidence $Target
	if (Test-Path -LiteralPath $TargetEvidence) { throw 'evidence_target_exists' }
	$null = New-HostToolEvidenceDirectory -Path $TargetEvidence
	$Before = Invoke-HostToolIdentityProbe -Mode Product -Root $ResolvedEngine -Target $Target -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
	$BuildParameters = @{ Target = $Target; ActionLimit = $ActionLimit; BuildBatch = (Join-Path $ResolvedEngine 'Engine/Build/BatchFiles/Build.bat') }
	if (-not [string]::IsNullOrWhiteSpace($NativeLogRoot)) {
		$BuildParameters.UbaRootDir = $UbaRootDir
		$BuildParameters.LogPath = Join-Path $NativeLogRoot ($Target + '.ubt.log')
	}
	$Build = Get-HostToolBuildCommand @BuildParameters
	$Record = [pscustomobject]@{ target = $Target; command = @($Build.executable) + @($Build.arguments); nativeExitCode = $null;
		logPath = (Join-Path $TargetEvidence 'build.log'); logSha256 = $null; actionCount = $null; progressCount = $null;
		selectionVerified = $false; recoveredNoOp = $false; targetReceiptVerified = $false;
		recoverySourceReceiptSha256 = $(if ($AllowRecoveredNoOp) { $RecoverySourceReceiptSha256 } else { $null });
		cleanupVerified = $false; productsVerified = $false; products = $null }
	[void] $InvocationRecords.Add($Record)
	$Job = $null; $Process = $null; $Cleanup = $false
	try {
		$null = Invoke-HostToolIdentityProbe -Mode Controller -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
		$null = Invoke-HostToolIdentityProbe -Mode Engine -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
		$ChildPowerShell = Resolve-HostToolChildPowerShellPath
		Initialize-InitialPreparationJob
		$Job = [Aetheln.PreparationJob]::new($UsefulDeadlineTicks)
		$Arguments = @('-NoProfile', '-NonInteractive', '-File',
			(Join-Path $PSScriptRoot 'HostToolProvisioning.BuildInvocation.ps1'), '-Target', $Target,
			'-ActionLimit', [string] $ActionLimit, '-EngineRoot', $ResolvedEngine, '-EvidenceRoot', $TargetEvidence)
		if (-not [string]::IsNullOrWhiteSpace($NativeLogRoot)) {
			$Arguments += @('-TempRoot', $TempRoot, '-UbaRootDir', $UbaRootDir,
				'-UbtLogPath', (Join-Path $NativeLogRoot ($Target + '.ubt.log')))
		}
		Assert-HostToolAcPower
		$Process = $Job.Start($ChildPowerShell, $Arguments, $ResolvedEngine)
		$LastOutputAlert = [DateTime]::UtcNow
		$CaptureStartedUtc = $LastOutputAlert
		while (-not $Process.WaitForExit(200)) {
			if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $UsefulDeadlineTicks) { throw 'useful_work_deadline' }
			$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
			Write-HostToolDiskWarning -ResourceMonitor $ResourceMonitor
			$CapturePath = Join-Path $TargetEvidence 'build.log'
			$NowUtc = [DateTime]::UtcNow
			$LastOutputUtc = if (Test-Path -LiteralPath $CapturePath -PathType Leaf) {
				(Get-Item -LiteralPath $CapturePath).LastWriteTimeUtc
			} else { $CaptureStartedUtc }
			if (Test-HostToolQuietAlert -NowUtc $NowUtc -LastAlertUtc $LastOutputAlert -LastOutputUtc $LastOutputUtc) {
				Write-Warning ('Host tool ' + $Target + ' has emitted no captured output for at least 30 minutes; process remains supervised.')
				$LastOutputAlert = $NowUtc
			}
		}
		if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $UsefulDeadlineTicks) { throw 'useful_work_deadline' }
		$Record.nativeExitCode = [int] $Process.ExitCode
		$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
	} finally {
		if ($null -ne $Job) {
			try {
				$Remaining = [int] [Math]::Min(600000, [Math]::Max(0, [Math]::Floor((Get-HostToolRemainingMilliseconds -DeadlineTicks $script:HostToolCleanupDeadlineTicks))))
				$Job.StopAndWait($Remaining)
				$Cleanup = $Job.ActiveCount -eq 0
			} catch { $Cleanup = $false }
			$Job.Dispose()
			if (-not $Cleanup) { $script:HostToolOwnedCleanupVerified = $false }
		}
		if ($null -ne $Process) {
			if ($Process.HasExited) { $Record.nativeExitCode = [int] $Process.ExitCode }
			$Process.Dispose()
		}
		if ($Cleanup -and $null -eq $Record.progressCount) {
			try {
				$ProgressLog = Join-Path $TargetEvidence 'build.log'
				$Partial = Get-HostToolBuildLogProof -LogPath $ProgressLog -ToolDirectory $ToolDirectory -SdkDirectory $SdkDirectory
				$Record.progressCount = $Partial.progressCount; $Record.actionCount = $Partial.actionCount
				$Record.selectionVerified = $Partial.selectionVerified; $Record.logSha256 = $Partial.logSha256
			} catch {
				try {
					$ProgressLog = Join-Path $TargetEvidence 'build.log'
					if ((Test-Path -LiteralPath $ProgressLog -PathType Leaf) -and
						(Get-Item -LiteralPath $ProgressLog).Length -le 16777216) {
						Assert-InitialPreparationPlainPath -Path $ProgressLog -Reason 'build_log_invalid'
						$Record.progressCount = [int] @(Select-String -LiteralPath $ProgressLog -Pattern '^\[[0-9]+/[0-9]+\] ' -ErrorAction Stop).Count
					}
				} catch { $Record.progressCount = $null }
			}
		}
		$Record.cleanupVerified = $Cleanup
	}
	if (-not $Cleanup) { throw 'cleanup_unproven' }
	$ResultPath = Join-Path $TargetEvidence 'native-result.json'
	if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 4096) { throw 'build_result_missing' }
	$Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
	Assert-HostToolNativeResult -Result $Result -Target $Target -NativeExitCode $Record.nativeExitCode
	if ($Record.nativeExitCode -ne 0) { throw 'native_build_failed' }
	$null = Invoke-HostToolIdentityProbe -Mode Engine -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $script:HostToolVerificationDeadlineTicks
	$LogPath = Join-Path $TargetEvidence 'build.log'
	$Proof = Get-HostToolBuildLogProof -LogPath $LogPath -ToolDirectory $ToolDirectory -SdkDirectory $SdkDirectory -AllowNoAction:$AllowRecoveredNoOp
	$After = Invoke-HostToolIdentityProbe -Mode Product -Root $ResolvedEngine -Target $Target -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $script:HostToolVerificationDeadlineTicks
	$TargetReceiptProof = $null
	if ($Proof.recoveredNoOp) {
		$TargetReceiptProof = Invoke-HostToolIdentityProbe -Mode Receipt -Root $ResolvedEngine -Target $Target -Bootstrap $Bootstrap -SupervisorRoot $SupervisorRoot -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $script:HostToolVerificationDeadlineTicks
		if ($TargetReceiptProof.semanticsVerified -ne $true) { throw 'target_receipt_invalid' }
		$Record.targetReceiptVerified = $true
	} else { $null = Assert-HostToolProductChange -Target $Target -Before $Before -After $After }
	$Record.logSha256 = $Proof.logSha256
	$Record.actionCount = $Proof.actionCount; $Record.progressCount = $Proof.progressCount
	$Record.selectionVerified = $Proof.selectionVerified; $Record.recoveredNoOp = $Proof.recoveredNoOp
	$Record.productsVerified = $true; $Record.products = $After
	return [pscustomobject]@{ target = $Target; nativeExitCode = 0; actionCount = $Proof.actionCount;
		progressCount = $Proof.progressCount; selectionVerified = $Proof.selectionVerified; productsVerified = $true;
		recoveredNoOp = $Proof.recoveredNoOp; targetReceiptVerified = ($null -ne $TargetReceiptProof);
		recoverySourceReceiptSha256 = $Record.recoverySourceReceiptSha256;
		cleanupVerified = $true; command = $Record.command; logPath = $Record.logPath; logSha256 = $Record.logSha256 }
}

function Invoke-HostToolFinalReceiptPublication {
	param([bool] $Bootstrap, [string] $SupervisorRoot, [string] $EvidenceRoot,
		[Collections.IDictionary] $Receipt, [string] $ControllerRoot, $ResourceMonitor,
		[long] $DeadlineTicks, [string] $StartedUtc, [AllowNull()][string] $PrePublicationFailure,
		[bool] $CleanupVerified, [bool] $LeaseReleased)
	try {
		if ($Bootstrap) {
			$null = Invoke-HostToolPublicationWorker -SupervisorRoot $SupervisorRoot -EvidenceRoot $EvidenceRoot `
				-Receipt $Receipt -ControllerRoot $ControllerRoot -ResourceMonitor $ResourceMonitor -DeadlineTicks $DeadlineTicks
		} else {
			Write-HostToolProvisioningReceipt -Path (Join-Path $EvidenceRoot 'host-tool-provisioning-receipt.json') -Receipt $Receipt
		}
	} catch {
		$PublicationFailure = $_.Exception.Message
		if ($Bootstrap -and (Test-Path -LiteralPath $SupervisorRoot -PathType Container)) {
			try {
				$null = Write-HostToolResourceFailureReceiptIfNeeded -Path (Join-Path $SupervisorRoot 'resource-failure.json') `
					-StartedUtc $StartedUtc -PrePublicationFailure $PrePublicationFailure -ResourceMonitor $ResourceMonitor `
					-CleanupVerified $CleanupVerified -LeaseReleased $LeaseReleased
			} catch { Write-Warning 'Could not write the independent D: resource-failure receipt.' }
		}
		if ($Bootstrap -and -not (Test-Path -LiteralPath (Join-Path $SupervisorRoot 'publication-failed.json') -PathType Leaf)) {
			try {
				$null = Write-HostToolProvisioningReceipt -Path (Join-Path $SupervisorRoot 'publication-failed.json') -Receipt ([ordered]@{
					schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $false; reason = $PublicationFailure })
			} catch { Write-Warning 'Could not write the D: publication-failed marker.' }
		}
		throw ('host_tool_provisioning_failed: ' + $PublicationFailure)
	}
}

if (-not $Execute) { throw 'execute_required' }
if (-not $PSCmdlet.ShouldProcess($EngineRoot, 'Run bounded non-clean host-tool provisioning')) { throw 'execute_declined' }
$StartedUtc = [DateTime]::UtcNow.ToString('o')
$StartedTicks = Get-InitialPreparationTick
$Frequency = [Diagnostics.Stopwatch]::Frequency
$Envelope = New-HostToolAttemptEnvelope -StartTicks $StartedTicks -Frequency $Frequency -UsefulWorkMinutes $UsefulWorkMinutes -VerificationMinutes $VerificationMinutes
$Bootstrap = $UsefulWorkMinutes -eq 1440
$Resume = -not [string]::IsNullOrWhiteSpace($ResumeReceiptPath) -or -not [string]::IsNullOrWhiteSpace($ResumeReceiptSha256)
if ($Resume -and (-not $Bootstrap -or [string]::IsNullOrWhiteSpace($ResumeReceiptPath) -or
	[string]::IsNullOrWhiteSpace($ResumeReceiptSha256))) { throw 'resume_parameters_invalid' }
if ($Bootstrap -and $VerificationMinutes -ne 120) { throw 'bootstrap_envelope_invalid' }
$UsefulDeadlineTicks = $Envelope.usefulDeadlineTicks
$script:HostToolUsefulDeadlineTicks = $UsefulDeadlineTicks
$CleanupDeadlineTicks = $Envelope.cleanupDeadlineTicks
$VerificationDeadlineTicks = $Envelope.verificationDeadlineTicks
$PublicationDeadlineTicks = $Envelope.publicationDeadlineTicks
$script:HostToolCleanupDeadlineTicks = $CleanupDeadlineTicks
$script:HostToolVerificationDeadlineTicks = $VerificationDeadlineTicks
$ControllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ResolvedEngine = Assert-HostToolPlainRoot -Path $EngineRoot -Reason 'engine_root_invalid'
$ResolvedController = Assert-HostToolPlainRoot -Path $ControllerRoot -Reason 'controller_root_invalid'
$ResolvedEvidence = Assert-HostToolPlainRoot -Path $EvidenceRoot -Reason 'evidence_root_invalid'
$ResolvedCompiler = Assert-HostToolPlainRoot -Path $CompilerPath -Reason 'compiler_path_invalid'
$ResolvedResourceCompiler = Assert-HostToolPlainRoot -Path $ResourceCompilerPath -Reason 'resource_compiler_path_invalid'
$ResolvedSupervisor = $null; $ResolvedTemp = $null; $ResolvedUba = $null; $ResolvedNativeLog = $null; $ExternalVolume = $null
if ($Bootstrap) {
	if ($ResolvedController -cnotmatch '^[Dd]:\\' -or
		$ResolvedEngine -cne 'F:\UnrealEngine\UE-5.8.1-source' -or
		@(@($SupervisorEvidenceRoot, $TempRoot, $UbaRootDir, $NativeLogRoot) | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'bootstrap_paths_invalid' }
	$ResolvedSupervisor = Assert-HostToolPlainRoot -Path $SupervisorEvidenceRoot -Reason 'supervisor_root_invalid'
	$ResolvedTemp = Assert-HostToolPlainRoot -Path $TempRoot -Reason 'temp_root_invalid'
	$ResolvedUba = Assert-HostToolPlainRoot -Path $UbaRootDir -Reason 'uba_root_invalid'
	$ResolvedNativeLog = Assert-HostToolPlainRoot -Path $NativeLogRoot -Reason 'native_log_root_invalid'
	if ($ResolvedSupervisor -cnotmatch '^[Dd]:\\' -or (Test-Path -LiteralPath $ResolvedSupervisor) -or
		-not (Test-Path -LiteralPath (Split-Path -Parent $ResolvedSupervisor) -PathType Container)) { throw 'supervisor_root_invalid' }
	foreach ($Path in @($ResolvedTemp, $ResolvedUba, $ResolvedNativeLog)) {
		$null = Assert-HostToolExternalVolume -Path $Path -Reason 'bootstrap_paths_invalid'
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'bootstrap_paths_invalid' }
	}
	$ExternalVolume = Assert-HostToolExternalVolume -Path $ResolvedEngine -Reason 'external_volume_mismatch'
	$null = Assert-HostToolExternalVolume -Path $ResolvedEvidence -Reason 'external_volume_mismatch'
	Assert-HostToolAcPower
	if ([long] $ExternalVolume.SizeRemaining -lt 300GB) { throw 'bootstrap_disk_admission_refused' }
}
if ($ResolvedEvidence -cnotmatch '^[Ff]:\\' -or (Test-Path -LiteralPath $ResolvedEvidence) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedEvidence -Parent $ResolvedEngine) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedEvidence -Parent $ResolvedController) -or
	(-not (Test-Path -LiteralPath (Split-Path -Parent $ResolvedEvidence) -PathType Container))) { throw 'evidence_root_invalid' }
if ((Test-InitialPreparationWithin -Candidate $ResolvedEngine -Parent $ResolvedController) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedController -Parent $ResolvedEngine)) { throw 'roots_overlap' }
$ResolvedLease = Resolve-EngineRunnerLeasePath -Path $HostLeasePath
if (-not (Test-Path -LiteralPath $ResolvedLease -PathType Leaf)) { throw 'lease_path_invalid' }
$SupervisorPins = @(); $EvidencePins = @()
$InvocationRecords = New-Object Collections.ArrayList
$Lease = $null; $ResourceMonitor = $null; $LeaseReleased = $false; $Completed = $false; $Failure = $null; $Sequence = @()
$ControllerRevision = $null; $EngineRevision = $null; $FreshOutputProof = $null
$CompilerSha256 = $null; $ResourceCompilerSha256 = $null; $ReceiptClosureProof = $null
$ConfigurationSha256 = $null; $CheckpointPath = $null; $CheckpointSha256 = $null; $CheckpointFileCount = $null
$CheckpointFailure = $null
$NativeLogAttemptRoot = $null
$AttemptOrdinal = 1; $PriorUsefulSeconds = 0; $CompletedTargets = New-Object Collections.ArrayList
$ReusedTargets = New-Object Collections.ArrayList; $RecoverableTarget = $null; $PowerRequest = $false
$script:HostToolOwnedCleanupVerified = $true
try {
	$LeaseBudgetTicks = if ($Bootstrap) { $PublicationDeadlineTicks } else { $CleanupDeadlineTicks }
	$LeaseDeadline = [DateTime]::UtcNow.AddMilliseconds((Get-HostToolRemainingMilliseconds -DeadlineTicks $LeaseBudgetTicks))
	$Lease = Enter-EngineRunnerHostLease -LeasePath $ResolvedLease -OwnerId ('host-tools-' + [guid]::NewGuid().ToString('N')) -DeadlineUtc $LeaseDeadline -RemainingBudget { Get-HostToolRemainingMilliseconds -DeadlineTicks $LeaseBudgetTicks }
	if ($Bootstrap) { Enter-HostToolSleepPrevention; $PowerRequest = $true }
	if ($Bootstrap) {
		$null = New-HostToolEvidenceDirectory -Path $ResolvedSupervisor
		$SupervisorPins = @(Get-InitialPreparationDirectoryPin -Directory $ResolvedSupervisor)
	}
	$null = New-HostToolEvidenceDirectory -Path $ResolvedEvidence
	Assert-InitialPreparationPlainPath -Path $ResolvedEvidence -Reason 'evidence_root_invalid'
	$EvidencePins = @(Get-InitialPreparationDirectoryPin -Directory $ResolvedEvidence)
	if ($Bootstrap) {
		$NativeLogAttemptRoot = New-HostToolNativeLogAttemptRoot -NativeLogRoot $ResolvedNativeLog
		$null = Assert-HostToolExternalVolume -Path $NativeLogAttemptRoot -Reason 'native_log_volume_mismatch'
	}
	foreach ($Required in @($ResolvedCompiler, $ResolvedResourceCompiler,
		(Join-Path $ResolvedEngine 'Engine/Build/BatchFiles/Build.bat'),
		(Join-Path $ResolvedEngine 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe'))) {
		if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw 'tool_input_missing' }
		Assert-InitialPreparationPlainPath -Path $Required -Reason 'tool_path_invalid'
	}
	if ($ResolvedCompiler -notmatch '^(?<root>.+[\\/]MSVC[\\/]14\.44\.35207)[\\/]bin[\\/]Hostx64[\\/]x64[\\/]cl\.exe$') { throw 'compiler_path_invalid' }
	$ToolDirectory = $Matches.root
	if ($ResolvedResourceCompiler -notmatch '^(?<root>.+)[\\/]bin[\\/]10\.0\.26100\.0[\\/]x64[\\/]rc\.exe$') { throw 'resource_compiler_path_invalid' }
	$SdkDirectory = $Matches.root
	$Roots = @{ controller = $ResolvedController; engine = $ResolvedEngine; evidence = $ResolvedEvidence;
		compiler = (Split-Path -Parent $ResolvedCompiler); resourceCompiler = (Split-Path -Parent $ResolvedResourceCompiler);
		temp = $(if ($Bootstrap) { $ResolvedTemp } else { [IO.Path]::GetTempPath() }) }
	$ResourceMonitor = New-RoutineCompileResourceMonitor -Roots $Roots
	$ControllerGit = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
	$ControllerRevision = Assert-HostToolGitState -Head $ControllerGit.head -Status $ControllerGit.status -Expected $ControllerGit.head -Kind controller
	$null = Invoke-HostToolIdentityProbe -Mode Controller -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
	$EngineGit = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedEngine -IgnoreUntrackedGenerated:$Resume -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
	$EngineRevision = Assert-HostToolGitState -Head $EngineGit.head -Status $EngineGit.status -Expected $script:HostToolEnginePin
	$null = Invoke-HostToolIdentityProbe -Mode Engine -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
	if ($Bootstrap) {
		if (-not $Resume) {
			$FreshOutputProof = Invoke-HostToolIdentityProbe -Mode Fresh -Root $ResolvedEngine -Bootstrap $true -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $UsefulDeadlineTicks
		}
	} else {
		$TrackedOutputPaths = @(& git -c ('safe.directory=' + $ResolvedEngine.Replace('\', '/')) -C $ResolvedEngine ls-files --cached -- 'Engine/Build' 'Engine/Binaries/Win64' 'Engine/Binaries/DotNET/UnrealBuildTool' 'Engine/Intermediate/Build' 'Engine/Plugins' 'Engine/Source/Programs' ':(glob)**/*.gitdeps.xml' 2>$null)
		if ($LASTEXITCODE -ne 0 -or $TrackedOutputPaths.Count -lt 1 -or $TrackedOutputPaths.Count -gt 100000) { throw 'fresh_output_unproven' }
		foreach ($ManifestRelative in $TrackedOutputPaths) {
			if ($ManifestRelative -cnotmatch '^[^/]+/Build/[^/]+\.gitdeps\.xml$' -and
				$ManifestRelative -cnotmatch '^[^/]+/Plugins/.+/Build/[^/]+\.gitdeps\.xml$') { continue }
			$ExpectedBlob = [string] (& git -c ('safe.directory=' + $ResolvedEngine.Replace('\', '/')) -C $ResolvedEngine rev-parse ('HEAD:' + $ManifestRelative) 2>$null)
			if ($LASTEXITCODE -ne 0) { throw 'gitdeps_manifest_identity_mismatch' }
			$ActualBlob = [string] (& git -c ('safe.directory=' + $ResolvedEngine.Replace('\', '/')) -C $ResolvedEngine hash-object -- $ManifestRelative 2>$null)
			if ($LASTEXITCODE -ne 0) { throw 'gitdeps_manifest_identity_mismatch' }
			$null = Assert-HostToolGitDependencyManifestIdentity -ExpectedBlob $ExpectedBlob -ActualBlob $ActualBlob
		}
		$FreshOutputProof = Assert-HostToolFreshOutputState -EngineRoot $ResolvedEngine -TrackedPaths $TrackedOutputPaths
	}
	$CompilerSha256 = Get-HostToolFileDigest -Path $ResolvedCompiler -Algorithm SHA256
	$ResourceCompilerSha256 = Get-HostToolFileDigest -Path $ResolvedResourceCompiler -Algorithm SHA256
	if ($Bootstrap) {
		$ConfigurationSha256 = Get-HostToolConfigurationSha256 -EngineRoot $ResolvedEngine -UbaRootDir $ResolvedUba -TempRoot $ResolvedTemp -NativeLogRoot $ResolvedNativeLog
	}
	if ($Resume) {
		$ExpectedHeader = [pscustomobject]@{ engineRoot = $ResolvedEngine; engineRevision = $EngineRevision;
			controllerRevision = $ControllerRevision; compilerSha256 = $CompilerSha256;
			resourceCompilerSha256 = $ResourceCompilerSha256; volumeId = $ExternalVolume.UniqueId;
			configurationSha256 = $ConfigurationSha256 }
		$Prior = Get-HostToolResumeReceipt -ReceiptPath $ResumeReceiptPath -ExpectedSha256 $ResumeReceiptSha256 -ExpectedHeader $ExpectedHeader
		$null = Assert-HostToolExternalVolume -Path $Prior.evidenceRoot -Reason 'resume_evidence_volume_mismatch'
		$PriorProof = Invoke-HostToolCheckpointWorker -Mode Verify -EngineRoot $ResolvedEngine -ManifestPath $Prior.checkpointPath -Header $ExpectedHeader -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks -ExpectedManifestSha256 $Prior.checkpointSha256
		$ParsedHeader = $PriorProof.verifiedHeader
		$null = Assert-HostToolCheckpointHeader -Header $ParsedHeader -Expected $ExpectedHeader
		foreach ($PriorTarget in @($ParsedHeader.completedTargets)) { [void] $CompletedTargets.Add($PriorTarget) }
		foreach ($PriorTarget in $CompletedTargets) {
			$LiveReceiptProof = Assert-HostToolCompletedTargetReceipt -Target $PriorTarget.target -EngineRoot $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			try {
				if ($PriorTarget.receiptProof.semanticsVerified -ne $true -or
					$PriorTarget.receiptProof.productCount -ne $LiveReceiptProof.productCount -or
					$PriorTarget.receiptProof.totalBytes -ne $LiveReceiptProof.totalBytes) { throw 'checkpoint_target_receipt_mismatch' }
			} catch { throw 'checkpoint_target_receipt_mismatch' }
			$ExpectedLogPath = Join-Path (Join-Path $Prior.evidenceRoot $PriorTarget.target) 'build.log'
			if ($PriorTarget.result.logPath -cne $ExpectedLogPath -or
				$PriorTarget.result.logSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'checkpoint_log_path_mismatch' }
			$LogProof = Invoke-HostToolIdentityProbe -Mode ReusedLog -Root $Prior.evidenceRoot -Target $PriorTarget.target -ExpectedLogSha256 $PriorTarget.result.logSha256 -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			[void] $ReusedTargets.Add([pscustomobject]@{ target = $PriorTarget.target; priorReceiptSha256 = $ResumeReceiptSha256;
				logPath = $LogProof.path; logSha256 = $LogProof.sha256; logSizeBytes = $LogProof.sizeBytes })
			$State = Invoke-HostToolIdentityProbe -Mode Product -Root $ResolvedEngine -Target $PriorTarget.target -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			foreach ($Relative in $script:HostToolProducts[$PriorTarget.target]) {
				if ($null -eq $PriorTarget.productState.PSObject.Properties[$Relative] -or
					$State[$Relative].sha256 -cne $PriorTarget.productState.$Relative.sha256 -or
					$State[$Relative].sizeBytes -ne $PriorTarget.productState.$Relative.sizeBytes) { throw 'checkpoint_product_mismatch' }
			}
		}
		if ($CompletedTargets.Count -lt $script:HostToolTargets.Count) {
			$NextTarget = $script:HostToolTargets[$CompletedTargets.Count]
			$Interrupted = @($Prior.invocations | Where-Object { $_.target -ceq $NextTarget -and
				$_.cleanupVerified -eq $true -and $_.selectionVerified -eq $true -and
				$_.progressCount -gt 0 -and $_.logSha256 -cmatch '^[0-9a-f]{64}$' })
			if ($Interrupted.Count -eq 1) {
				$ExpectedPartialLogPath = Join-Path (Join-Path $Prior.evidenceRoot $NextTarget) 'build.log'
				if ($Interrupted[0].logPath -cne $ExpectedPartialLogPath) { throw 'resume_partial_log_path_mismatch' }
				$null = Invoke-HostToolIdentityProbe -Mode ReusedLog -Root $Prior.evidenceRoot -Target $NextTarget -ExpectedLogSha256 $Interrupted[0].logSha256 -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
				$RecoverableTarget = $NextTarget
			}
		}
		$AttemptOrdinal = 2; $PriorUsefulSeconds = 86400
		$FreshOutputProof = [pscustomobject]@{ fresh = $false; resumedFromSha256 = $ResumeReceiptSha256 }
	}
	$Sequence = Invoke-HostToolProvisioningSequence -Targets $script:HostToolTargets -ReadTicks { Get-InitialPreparationTick } -UsefulDeadlineTicks $UsefulDeadlineTicks -CleanupDeadlineTicks $CleanupDeadlineTicks -AdmitTarget {
		Assert-HostToolAcPower
		if ($Bootstrap) {
			$LiveVolume = Assert-HostToolExternalVolume -Path $ResolvedEngine -Reason 'external_volume_mismatch'
			if ($LiveVolume.UniqueId -cne $ExternalVolume.UniqueId) { throw 'external_volume_mismatch' }
			$null = Assert-HostToolTargetDiskAdmission -FreeBytes ([IO.DriveInfo]::new('F:\')).AvailableFreeSpace -NativeTargetsStarted $InvocationRecords.Count
		}
		Get-RoutineCompileActionLimit -Monitor $ResourceMonitor
	} -InvokeBuild {
		param($Target, $Limit)
		Invoke-HostToolNativeBuild -Target $Target -ActionLimit $Limit -ResolvedEngine $ResolvedEngine -ResolvedController $ResolvedController -ResolvedEvidence $ResolvedEvidence -ToolDirectory $ToolDirectory -SdkDirectory $SdkDirectory -UsefulDeadlineTicks $UsefulDeadlineTicks -ResourceMonitor $ResourceMonitor -InvocationRecords $InvocationRecords -TempRoot $ResolvedTemp -UbaRootDir $ResolvedUba -NativeLogRoot $NativeLogAttemptRoot -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -AllowRecoveredNoOp:($Target -ceq $RecoverableTarget) -RecoverySourceReceiptSha256 $ResumeReceiptSha256
	} -CompletedResults @($CompletedTargets | ForEach-Object { $_.result }) -RecoverableTarget $RecoverableTarget -OnTargetCompleted {
		param($Target, $Results)
		if ($Bootstrap) {
			$PerTargetReceiptProof = Assert-HostToolCompletedTargetReceipt -Target $Target -EngineRoot $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$ProductState = Invoke-HostToolIdentityProbe -Mode Product -Root $ResolvedEngine -Target $Target -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$Results[-1].targetReceiptVerified = $true
			$TargetProof = [pscustomobject]@{ target = $Target; result = $Results[-1];
				receiptProof = $PerTargetReceiptProof; productState = $ProductState }
			Write-HostToolProvisioningReceipt -Path (Join-Path $ResolvedSupervisor ('completed-' + $Target + '.json')) -Receipt ([ordered]@{
				schemaVersion = 2; engineRevision = $EngineRevision; controllerRevision = $ControllerRevision;
				configurationSha256 = $ConfigurationSha256; volumeId = $ExternalVolume.UniqueId;
				completedUtc = [DateTime]::UtcNow.ToString('o'); proof = $TargetProof })
			[void] $CompletedTargets.Add($TargetProof)
		}
	}
	$ReceiptClosureProof = Invoke-HostToolIdentityProbe -Mode Receipt -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
	$null = Invoke-HostToolIdentityProbe -Mode Controller -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
	$ControllerAfter = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
	$null = Assert-HostToolGitState -Head $ControllerAfter.head -Status $ControllerAfter.status -Expected $ControllerRevision -Kind controller
	$EngineAfter = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedEngine -IgnoreUntrackedGenerated:$Bootstrap -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
	$null = Assert-HostToolGitState -Head $EngineAfter.head -Status $EngineAfter.status -Expected $script:HostToolEnginePin
	$null = Invoke-HostToolIdentityProbe -Mode Engine -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
	if ((Get-HostToolFileDigest -Path $ResolvedCompiler -Algorithm SHA256) -cne $CompilerSha256 -or
		(Get-HostToolFileDigest -Path $ResolvedResourceCompiler -Algorithm SHA256) -cne $ResourceCompilerSha256) { throw 'tool_input_drift' }
	$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
	$null = Get-HostToolRemainingMilliseconds -DeadlineTicks $(if ($Bootstrap) { $VerificationDeadlineTicks } else { $CleanupDeadlineTicks })
	$Completed = $true
} catch { $Failure = $_.Exception.Message }
finally {
	$PrimaryFailure = $Failure
	if ($Bootstrap -and $null -ne $ResourceMonitor -and $ResourceMonitor.failureReason -ceq 'resource_pressure') {
		$CheckpointFailure = 'checkpoint_skipped_resource_pressure'
	}
	if ($Bootstrap -and $null -ne $Lease -and $script:HostToolOwnedCleanupVerified -and
		$null -ne $ResourceMonitor -and $null -eq $ResourceMonitor.failureReason -and
		$null -ne $EngineRevision -and $null -ne $ConfigurationSha256) {
		try {
			$CheckpointPath = Join-Path $ResolvedEvidence 'generated-output-checkpoint.jsonl'
			$Header = [pscustomobject]@{ schemaVersion = 2; engineRoot = $ResolvedEngine;
				engineRevision = $EngineRevision; controllerRevision = $ControllerRevision;
				compilerSha256 = $CompilerSha256; resourceCompilerSha256 = $ResourceCompilerSha256;
				volumeId = $ExternalVolume.UniqueId; configurationSha256 = $ConfigurationSha256;
				attemptOrdinal = $AttemptOrdinal; priorUsefulSeconds = $PriorUsefulSeconds;
				completedTargets = @($CompletedTargets.ToArray()) }
			$CheckpointProof = Invoke-HostToolCheckpointWorker -Mode Create -EngineRoot $ResolvedEngine -ManifestPath $CheckpointPath -Header $Header -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$CheckpointSha256 = [string] $CheckpointProof.manifestSha256
			$CheckpointFileCount = [int] $CheckpointProof.fileCount
			$null = Invoke-HostToolIdentityProbe -Mode Controller -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$FinalControllerGit = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedController -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$null = Assert-HostToolGitState -Head $FinalControllerGit.head -Status $FinalControllerGit.status -Expected $ControllerRevision -Kind controller
			$null = Invoke-HostToolIdentityProbe -Mode Engine -Root $ResolvedEngine -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$FinalEngineGit = Invoke-HostToolIdentityProbe -Mode Git -Root $ResolvedEngine -IgnoreUntrackedGenerated -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $VerificationDeadlineTicks
			$null = Assert-HostToolGitState -Head $FinalEngineGit.head -Status $FinalEngineGit.status -Expected $EngineRevision
			if (
				(Get-HostToolFileDigest -Path $ResolvedCompiler -Algorithm SHA256) -cne $CompilerSha256 -or
				(Get-HostToolFileDigest -Path $ResolvedResourceCompiler -Algorithm SHA256) -cne $ResourceCompilerSha256 -or
				(Assert-HostToolExternalVolume -Path $ResolvedEngine -Reason 'external_volume_mismatch').UniqueId -cne $ExternalVolume.UniqueId) { throw 'checkpoint_final_identity_mismatch' }
		} catch {
			$CheckpointFailure = 'checkpoint_or_final_identity_failed:' + $_.Exception.Message
			if ($PrimaryFailure -cne 'build_output_limit') { $Failure = $CheckpointFailure }
			$Completed = $false
			$CheckpointSha256 = $null; $CheckpointFileCount = $null
		}
	}
	if ($null -ne $Lease -and -not $LeaseReleased) {
		if ($script:HostToolOwnedCleanupVerified) {
			try {
				$null = Get-HostToolRemainingMilliseconds -DeadlineTicks $LeaseBudgetTicks
				Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true
				$LeaseReleased = $true
			} catch {
				$Failure = 'lease_cleanup_unproven'
				$Completed = $false
				try { Close-EngineRunnerHostLease -Lease $Lease } catch { $Failure = 'lease_cleanup_unproven' }
			}
		} else {
			$Completed = $false
			try { Close-EngineRunnerHostLease -Lease $Lease } catch { $Failure = 'lease_cleanup_unproven' }
		}
	}
	try {
	$Receipt = [ordered]@{ schemaVersion = $(if ($Bootstrap) { 2 } else { 1 }); scope = 'bounded_host_tool_provisioning'; startedUtc = $StartedUtc;
		finishedUtc = [DateTime]::UtcNow.ToString('o'); controllerRevision = $ControllerRevision;
		projectRevision = $ControllerRevision; engineRevision = $EngineRevision;
		engineRoot = $ResolvedEngine; evidenceRoot = $ResolvedEvidence; nativeLogAttemptRoot = $NativeLogAttemptRoot;
		volumeId = $(if ($Bootstrap) { $ExternalVolume.UniqueId } else { $null });
		configurationSha256 = $ConfigurationSha256; attemptOrdinal = $AttemptOrdinal;
		priorUsefulSeconds = $PriorUsefulSeconds; cleanupVerified = $script:HostToolOwnedCleanupVerified;
		checkpointPath = $CheckpointPath; checkpointSha256 = $CheckpointSha256; checkpointFileCount = $CheckpointFileCount;
		compilerPath = $ResolvedCompiler; resourceCompilerPath = $ResolvedResourceCompiler;
		compilerSha256 = $CompilerSha256; resourceCompilerSha256 = $ResourceCompilerSha256;
		freshOutputProof = $FreshOutputProof; targetReceiptProof = $ReceiptClosureProof;
		compilerVersion = '14.44.35228'; toolsetDirectoryVersion = '14.44.35207'; windowsSdkVersion = '10.0.26100.0';
		usefulDeadlineSeconds = $Envelope.usefulSeconds; cleanupDeadlineSeconds = $Envelope.cleanupSeconds;
		verificationDeadlineSeconds = $Envelope.verificationSeconds; publicationDeadlineSeconds = $Envelope.publicationSeconds;
		success = $Completed; failure = $Failure; primaryFailure = $PrimaryFailure;
		checkpointFailure = $CheckpointFailure; leaseReleased = $LeaseReleased;
		invocations = @($InvocationRecords); reusedTargets = @($ReusedTargets);
		resource = $(if ($null -ne $ResourceMonitor) { Get-RoutineCompileResourceProof -Monitor $ResourceMonitor } else { $null });
		attestationCreated = $false }
	if ((Get-InitialPreparationTick) -ge $PublicationDeadlineTicks) {
		$Receipt.success = $false; $Receipt.failure = 'publication_deadline'; $Failure = 'publication_deadline'; $Completed = $false
	}
	$PrePublicationFailure = $Failure
	Invoke-HostToolFinalReceiptPublication -Bootstrap $Bootstrap -SupervisorRoot $ResolvedSupervisor -EvidenceRoot $ResolvedEvidence `
		-Receipt $Receipt -ControllerRoot $ResolvedController -ResourceMonitor $ResourceMonitor -DeadlineTicks $PublicationDeadlineTicks `
		-StartedUtc $StartedUtc -PrePublicationFailure $PrePublicationFailure -CleanupVerified $script:HostToolOwnedCleanupVerified -LeaseReleased $LeaseReleased
	} finally {
		if ($PowerRequest) { [HostToolSleepPrevention]::End() }
		foreach ($Pin in $EvidencePins) { $Pin.Dispose() }
		foreach ($Pin in $SupervisorPins) { $Pin.Dispose() }
	}
}
if (-not $Completed) { throw ('host_tool_provisioning_failed: ' + $Failure) }
[pscustomobject] $Receipt
