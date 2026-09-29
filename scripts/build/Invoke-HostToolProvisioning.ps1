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
	[Parameter(Mandatory)][string] $ResourceCompilerPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
. (Join-Path $PSScriptRoot '../ci/EngineRunnerHostLease.ps1')

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
	param([string] $Root)
	$Safe = 'safe.directory=' + $Root.Replace('\', '/')
	$Head = (& git -c $Safe -C $Root rev-parse HEAD 2>$null)
	if ($LASTEXITCODE -ne 0 -or @($Head).Count -ne 1) { throw 'git_identity_unavailable' }
	$Status = @(& git -c $Safe -C $Root status --porcelain=v1 --untracked-files=all 2>$null)
	if ($LASTEXITCODE -ne 0) { throw 'git_identity_unavailable' }
	return [pscustomobject]@{ head = [string] $Head; status = ($Status -join "`n") }
}

function Get-HostToolRemainingMilliseconds {
	param([long] $DeadlineTicks)
	$Now = Get-InitialPreparationTick
	$Remaining = [Math]::Floor(([decimal] $DeadlineTicks - [decimal] $Now) * 1000 / [Diagnostics.Stopwatch]::Frequency)
	if ($Remaining -le 0) { throw 'cleanup_deadline' }
	return [double] $Remaining
}

function Write-HostToolProvisioningReceipt {
	param([string] $Path, $Receipt)
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 9 -Compress))
	if ($Bytes.Length -lt 1 -or $Bytes.Length -gt 65536) { throw 'receipt_limit' }
	$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
}

function Invoke-HostToolNativeBuild {
	param([string] $Target, [int] $ActionLimit, [string] $ResolvedEngine, [string] $ResolvedController, [string] $ResolvedEvidence,
		[string] $ToolDirectory, [string] $SdkDirectory, [long] $UsefulDeadlineTicks,
		$ResourceMonitor, [Collections.ArrayList] $InvocationRecords)
	$TargetEvidence = Join-Path $ResolvedEvidence $Target
	if (Test-Path -LiteralPath $TargetEvidence) { throw 'evidence_target_exists' }
	$null = New-HostToolEvidenceDirectory -Path $TargetEvidence
	$Before = Get-HostToolProductState -EngineRoot $ResolvedEngine -Target $Target
	$Build = Get-HostToolBuildCommand -Target $Target -ActionLimit $ActionLimit -BuildBatch (Join-Path $ResolvedEngine 'Engine/Build/BatchFiles/Build.bat')
	$Record = [pscustomobject]@{ target = $Target; command = @($Build.executable) + @($Build.arguments); nativeExitCode = $null;
		logSha256 = $null; actionCount = $null; progressCount = $null; cleanupVerified = $false; productsVerified = $false; products = $null }
	[void] $InvocationRecords.Add($Record)
	$Job = $null; $Process = $null; $Cleanup = $false
	try {
		$null = Assert-HostToolControllerInputIdentity -ControllerRoot $ResolvedController
		$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine
		$ChildPowerShell = Resolve-HostToolChildPowerShellPath
		Initialize-InitialPreparationJob
		$Job = [Aetheln.PreparationJob]::new($UsefulDeadlineTicks)
		$Arguments = @('-NoProfile', '-NonInteractive', '-File',
			(Join-Path $PSScriptRoot 'HostToolProvisioning.BuildInvocation.ps1'), '-Target', $Target,
			'-ActionLimit', [string] $ActionLimit, '-EngineRoot', $ResolvedEngine, '-EvidenceRoot', $TargetEvidence)
		$Process = $Job.Start($ChildPowerShell, $Arguments, $ResolvedEngine)
		while (-not $Process.WaitForExit(200)) {
			if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $UsefulDeadlineTicks) { throw 'useful_work_deadline' }
			$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
		}
		if ($Job.TimedOut -or (Get-InitialPreparationTick) -ge $UsefulDeadlineTicks) { throw 'useful_work_deadline' }
		$Record.nativeExitCode = [int] $Process.ExitCode
		$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
	} finally {
		if ($null -ne $Job) {
			try {
				$Remaining = [int] [Math]::Min(5000, [Math]::Max(0, [Math]::Floor((Get-HostToolRemainingMilliseconds -DeadlineTicks $script:HostToolCleanupDeadlineTicks))))
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
		$Record.cleanupVerified = $Cleanup
	}
	if (-not $Cleanup) { throw 'cleanup_unproven' }
	$ResultPath = Join-Path $TargetEvidence 'native-result.json'
	if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 4096) { throw 'build_result_missing' }
	$Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
	if (($Result.schemaVersion -isnot [int] -and $Result.schemaVersion -isnot [long]) -or $Result.schemaVersion -ne 1 -or
		$Result.target -cne $Target -or $null -ne $Result.infrastructureFailure -or
		($Result.nativeExitCode -isnot [int] -and $Result.nativeExitCode -isnot [long]) -or $Result.nativeExitCode -ne $Record.nativeExitCode) { throw 'build_result_invalid' }
	if ($Record.nativeExitCode -ne 0) { throw 'native_build_failed' }
	$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine
	$LogPath = Join-Path $TargetEvidence 'build.log'
	if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf) -or (Get-Item -LiteralPath $LogPath).Length -lt 1 -or
		(Get-Item -LiteralPath $LogPath).Length -gt 16777216) { throw 'build_log_invalid' }
	Assert-InitialPreparationPlainPath -Path $LogPath -Reason 'build_log_invalid'
	$Lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
	$Proof = Get-HostToolBuildProof -Lines $Lines -ToolDirectory $ToolDirectory -SdkDirectory $SdkDirectory
	$After = Get-HostToolProductState -EngineRoot $ResolvedEngine -Target $Target
	$null = Assert-HostToolProductChange -Target $Target -Before $Before -After $After
	$Record.logSha256 = (Get-FileHash -LiteralPath $LogPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$Record.actionCount = $Proof.actionCount; $Record.progressCount = $Proof.progressCount; $Record.productsVerified = $true; $Record.products = $After
	return [pscustomobject]@{ target = $Target; nativeExitCode = 0; actionCount = $Proof.actionCount;
		progressCount = $Proof.progressCount; selectionVerified = $true; productsVerified = $true;
		cleanupVerified = $true; command = $Record.command; logSha256 = $Record.logSha256 }
}

if (-not $Execute) { throw 'execute_required' }
if (-not $PSCmdlet.ShouldProcess($EngineRoot, 'Run bounded non-clean host-tool provisioning')) { throw 'execute_declined' }
$StartedUtc = [DateTime]::UtcNow.ToString('o')
$StartedTicks = Get-InitialPreparationTick
$Frequency = [Diagnostics.Stopwatch]::Frequency
$Envelope = New-HostToolAttemptEnvelope -StartTicks $StartedTicks -Frequency $Frequency
$UsefulDeadlineTicks = $Envelope.usefulDeadlineTicks
$CleanupDeadlineTicks = $Envelope.cleanupDeadlineTicks
$PublicationDeadlineTicks = $Envelope.publicationDeadlineTicks
$script:HostToolCleanupDeadlineTicks = $CleanupDeadlineTicks
$ControllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ResolvedEngine = Assert-HostToolPlainRoot -Path $EngineRoot -Reason 'engine_root_invalid'
$ResolvedController = Assert-HostToolPlainRoot -Path $ControllerRoot -Reason 'controller_root_invalid'
$ResolvedEvidence = Assert-HostToolPlainRoot -Path $EvidenceRoot -Reason 'evidence_root_invalid'
$ResolvedCompiler = Assert-HostToolPlainRoot -Path $CompilerPath -Reason 'compiler_path_invalid'
$ResolvedResourceCompiler = Assert-HostToolPlainRoot -Path $ResourceCompilerPath -Reason 'resource_compiler_path_invalid'
if ($ResolvedEvidence -cnotmatch '^[Ff]:\\' -or (Test-Path -LiteralPath $ResolvedEvidence) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedEvidence -Parent $ResolvedEngine) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedEvidence -Parent $ResolvedController) -or
	(-not (Test-Path -LiteralPath (Split-Path -Parent $ResolvedEvidence) -PathType Container))) { throw 'evidence_root_invalid' }
if ((Test-InitialPreparationWithin -Candidate $ResolvedEngine -Parent $ResolvedController) -or
	(Test-InitialPreparationWithin -Candidate $ResolvedController -Parent $ResolvedEngine)) { throw 'roots_overlap' }
$ResolvedLease = Resolve-EngineRunnerLeasePath -Path $HostLeasePath
if (-not (Test-Path -LiteralPath $ResolvedLease -PathType Leaf)) { throw 'lease_path_invalid' }
$null = New-HostToolEvidenceDirectory -Path $ResolvedEvidence
Assert-InitialPreparationPlainPath -Path $ResolvedEvidence -Reason 'evidence_root_invalid'
$EvidencePins = @(Get-InitialPreparationDirectoryPin -Directory $ResolvedEvidence)
$InvocationRecords = New-Object Collections.ArrayList
$Lease = $null; $ResourceMonitor = $null; $LeaseReleased = $false; $Completed = $false; $Failure = $null; $Sequence = @()
$ControllerRevision = $null; $EngineRevision = $null; $FreshOutputProof = $null
$CompilerSha256 = $null; $ResourceCompilerSha256 = $null; $ReceiptClosureProof = $null
$script:HostToolOwnedCleanupVerified = $true
try {
	$LeaseDeadline = [DateTime]::UtcNow.AddMilliseconds((Get-HostToolRemainingMilliseconds -DeadlineTicks $CleanupDeadlineTicks))
	$Lease = Enter-EngineRunnerHostLease -LeasePath $ResolvedLease -OwnerId ('host-tools-' + [guid]::NewGuid().ToString('N')) -DeadlineUtc $LeaseDeadline -RemainingBudget { Get-HostToolRemainingMilliseconds -DeadlineTicks $CleanupDeadlineTicks }
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
	$ControllerGit = Get-HostToolGitState -Root $ResolvedController
	$ControllerRevision = Assert-HostToolGitState -Head $ControllerGit.head -Status $ControllerGit.status -Expected $ControllerGit.head -Kind controller
	$null = Assert-HostToolControllerInputIdentity -ControllerRoot $ResolvedController
	$EngineGit = Get-HostToolGitState -Root $ResolvedEngine
	$EngineRevision = Assert-HostToolGitState -Head $EngineGit.head -Status $EngineGit.status -Expected $script:HostToolEnginePin
	$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine
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
	$CompilerSha256 = (Get-FileHash -LiteralPath $ResolvedCompiler -Algorithm SHA256).Hash.ToLowerInvariant()
	$ResourceCompilerSha256 = (Get-FileHash -LiteralPath $ResolvedResourceCompiler -Algorithm SHA256).Hash.ToLowerInvariant()
	$Roots = @{ controller = $ResolvedController; engine = $ResolvedEngine; evidence = $ResolvedEvidence;
		compiler = (Split-Path -Parent $ResolvedCompiler); resourceCompiler = (Split-Path -Parent $ResolvedResourceCompiler);
		temp = [IO.Path]::GetTempPath() }
	$ResourceMonitor = New-RoutineCompileResourceMonitor -Roots $Roots
	$Sequence = Invoke-HostToolProvisioningSequence -Targets $script:HostToolTargets -ReadTicks { Get-InitialPreparationTick } -UsefulDeadlineTicks $UsefulDeadlineTicks -CleanupDeadlineTicks $CleanupDeadlineTicks -AdmitTarget {
		Get-RoutineCompileActionLimit -Monitor $ResourceMonitor
	} -InvokeBuild {
		param($Target, $Limit)
		Invoke-HostToolNativeBuild -Target $Target -ActionLimit $Limit -ResolvedEngine $ResolvedEngine -ResolvedController $ResolvedController -ResolvedEvidence $ResolvedEvidence -ToolDirectory $ToolDirectory -SdkDirectory $SdkDirectory -UsefulDeadlineTicks $UsefulDeadlineTicks -ResourceMonitor $ResourceMonitor -InvocationRecords $InvocationRecords
	}
	$ReceiptClosureProof = Assert-HostToolReceiptSet -EngineRoot $ResolvedEngine
	$null = Assert-HostToolControllerInputIdentity -ControllerRoot $ResolvedController
	$ControllerAfter = Get-HostToolGitState -Root $ResolvedController
	$null = Assert-HostToolGitState -Head $ControllerAfter.head -Status $ControllerAfter.status -Expected $ControllerRevision -Kind controller
	$EngineAfter = Get-HostToolGitState -Root $ResolvedEngine
	$null = Assert-HostToolGitState -Head $EngineAfter.head -Status $EngineAfter.status -Expected $script:HostToolEnginePin
	$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine
	if ((Get-FileHash -LiteralPath $ResolvedCompiler -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CompilerSha256 -or
		(Get-FileHash -LiteralPath $ResolvedResourceCompiler -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ResourceCompilerSha256) { throw 'tool_input_drift' }
	$null = Update-RoutineCompileResources -Monitor $ResourceMonitor
	$null = Get-HostToolRemainingMilliseconds -DeadlineTicks $CleanupDeadlineTicks
	Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true
	$LeaseReleased = $true; $Completed = $true
} catch { $Failure = $_.Exception.Message }
finally {
	if ($null -ne $Lease -and -not $LeaseReleased) {
		if ($script:HostToolOwnedCleanupVerified) {
			try {
				$null = Get-HostToolRemainingMilliseconds -DeadlineTicks $CleanupDeadlineTicks
				Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true
				$LeaseReleased = $true
			} catch {
				$Failure = 'lease_cleanup_unproven'
				try { Close-EngineRunnerHostLease -Lease $Lease } catch { $Failure = 'lease_cleanup_unproven' }
			}
		} else {
			try { Close-EngineRunnerHostLease -Lease $Lease } catch { $Failure = 'lease_cleanup_unproven' }
		}
	}
	$Receipt = [ordered]@{ schemaVersion = 1; scope = 'bounded_host_tool_provisioning'; startedUtc = $StartedUtc;
		finishedUtc = [DateTime]::UtcNow.ToString('o'); controllerRevision = $ControllerRevision;
		projectRevision = $ControllerRevision; engineRevision = $EngineRevision;
		compilerPath = $ResolvedCompiler; resourceCompilerPath = $ResolvedResourceCompiler;
		compilerSha256 = $CompilerSha256; resourceCompilerSha256 = $ResourceCompilerSha256;
		freshOutputProof = $FreshOutputProof; targetReceiptProof = $ReceiptClosureProof;
		compilerVersion = '14.44.35228'; toolsetDirectoryVersion = '14.44.35207'; windowsSdkVersion = '10.0.26100.0';
		usefulDeadlineSeconds = 19800; cleanupDeadlineSeconds = 20400; publicationDeadlineSeconds = 21600;
		success = $Completed; failure = $Failure; leaseReleased = $LeaseReleased;
		invocations = @($InvocationRecords); resource = $(if ($null -ne $ResourceMonitor) { Get-RoutineCompileResourceProof -Monitor $ResourceMonitor } else { $null });
		attestationCreated = $false }
	if ((Get-InitialPreparationTick) -ge $PublicationDeadlineTicks) {
		$Receipt.success = $false; $Receipt.failure = 'publication_deadline'; $Failure = 'publication_deadline'; $Completed = $false
	}
	try { Write-HostToolProvisioningReceipt -Path (Join-Path $ResolvedEvidence 'host-tool-provisioning-receipt.json') -Receipt $Receipt }
	finally { foreach ($Pin in $EvidencePins) { $Pin.Dispose() } }
}
if (-not $Completed) { throw ('host_tool_provisioning_failed: ' + $Failure) }
[pscustomobject] $Receipt
