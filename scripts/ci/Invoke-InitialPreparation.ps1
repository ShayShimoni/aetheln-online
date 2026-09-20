[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $Repository,
	[Parameter(Mandatory)][string] $ControllerRevision,
	[Parameter(Mandatory)][string] $TargetRevision,
	[Parameter(Mandatory)][string] $AttemptId,
	[Parameter(Mandatory)][string] $OperationScript,
	[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $OperationSha256,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[string] $RequestPath,
	[string] $RequestSha256,
	[string] $ControllerManifestPath,
	[string] $ControllerManifestSha256,
	[ValidateRange(1, 20400)][int] $OperationTimeoutSeconds = 20400
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot 'InitialPreparation.Controller.ps1')
# The original clock starts before staging or worker admission. The parent does
# no target checkout, input hashing, lease acquisition or runner mutation.
$Attempt = New-InitialPreparationAttempt -Repository $Repository -ControllerRevision $ControllerRevision -TargetRevision $TargetRevision -AttemptId $AttemptId
$AttemptJson = $Attempt | ConvertTo-Json -Depth 4 -Compress
$Job = $null
$Process = $null
$NativeExit = $null
$CleanupVerified = $false
$Failure = $null
$ControllerProof = $null
$FrozenRequestStream = $null
$FrozenRequestHandle = $null
$ParentDirectoryPins = New-Object Collections.ArrayList
$ExpectedRequest = $null
$Recovery = $null
try {
	if ([string]::IsNullOrEmpty($RequestPath) -ne [string]::IsNullOrEmpty($RequestSha256)) { throw 'request_identity_incomplete' }
	if ([string]::IsNullOrEmpty($ControllerManifestPath) -ne [string]::IsNullOrEmpty($ControllerManifestSha256)) { throw 'controller_identity_incomplete' }
	if ($ControllerManifestPath) {
		foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot)) { [void] $ParentDirectoryPins.Add($Pin) }
		$ControllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
		$ControllerProof = Get-InitialPreparationControllerProof -Root $ControllerRoot -ManifestPath $ControllerManifestPath -ManifestSha256 $ControllerManifestSha256 -Attempt $Attempt
		if ($RequestPath) {
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $RequestPath))) { [void] $ParentDirectoryPins.Add($Pin) }
			$FrozenRequestHandle = [Aetheln.PreparationDirectory]::OpenSource($RequestPath)
			$FrozenRequestStream = [IO.FileStream]::new($FrozenRequestHandle, [IO.FileAccess]::Read)
			if ($FrozenRequestStream.Length -lt 1 -or $FrozenRequestStream.Length -gt 65536) { throw 'request_size_invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($FrozenRequestStream))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
			if ($Digest -cne $RequestSha256) { throw 'request_source_mismatch' }
			$FrozenRequestStream.Position = 0
			$RequestBytes = New-Object byte[] ([int] $FrozenRequestStream.Length)
			$Offset = 0
			while ($Offset -lt $RequestBytes.Length) {
				$Count = $FrozenRequestStream.Read($RequestBytes, $Offset, $RequestBytes.Length - $Offset)
				if ($Count -le 0) { throw 'request_read_incomplete' }
				$Offset += $Count
			}
			$RequestUtf8 = New-Object Text.UTF8Encoding($false, $true)
			$ExpectedRequest = ConvertFrom-InitialPreparationRequest -Json ($RequestUtf8.GetString($RequestBytes)) -Attempt $Attempt
		}
	}
	Initialize-InitialPreparationJob
	$OperationDeadline = [long] [Math]::Min($Attempt.cleanupDeadlineTicks,
		[long] ([decimal] $Attempt.monotonicStartTicks + [decimal] $OperationTimeoutSeconds * [decimal] $Attempt.monotonicFrequency))
	$Job = [Aetheln.PreparationJob]::new($OperationDeadline)
	$Executable = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
	$Bootstrap = Join-Path $PSScriptRoot 'InitialPreparation.Bootstrap.ps1'
	$Arguments = @('-NoProfile', '-File', $Bootstrap, '-AttemptJson', $AttemptJson,
		'-OperationScript', $OperationScript, '-OperationSha256', $OperationSha256, '-EvidenceRoot', $EvidenceRoot)
	if ($RequestPath) { $Arguments += @('-RequestPath', $RequestPath, '-RequestSha256', $RequestSha256) }
	if ($ControllerManifestPath) {
		$InvocationIdentity = @($ControllerProof.files | Where-Object { $_.path -ceq 'scripts/ci/InitialPreparation.BuildInvocation.ps1' })
		if ($InvocationIdentity.Count -ne 1) { throw 'controller_invocation_identity_missing' }
		$Arguments += @('-ControllerManifestSha256', $ControllerManifestSha256, '-BuildInvocationSha256', $InvocationIdentity[0].sha256)
	}
	$Process = $Job.Start($Executable, $Arguments, $PSScriptRoot)
	while (-not $Process.WaitForExit(200)) {
		if ($Job.TimedOut) { break }
	}
	if ($Process.HasExited) { $NativeExit = $Process.ExitCode }
} catch { $Failure = 'operation_start_or_wait_failed' }
finally {
	if ($null -ne $Job) {
		try {
			$Remaining = [int] [Math]::Min(5000, [Math]::Max(0, [Math]::Floor(
				($Attempt.cleanupDeadlineTicks - (Get-InitialPreparationTick)) * 1000.0 / $Attempt.monotonicFrequency)))
			$Job.StopAndWait($Remaining)
			if ($null -ne $Process -and $Process.HasExited) { $NativeExit = $Process.ExitCode }
			$CleanupVerified = (Get-InitialPreparationTick) -le $Attempt.cleanupDeadlineTicks
		} catch { $Failure = 'operation_cleanup_unproven' }
	}
}
$TimedOut = $null -ne $Job -and $Job.TimedOut
# Run recovery outside the killed operation tree, while reviewed controller and
# expected request bytes remain pinned. Exit code is not proof of quiescence.
if ($null -ne $ExpectedRequest -and $ExpectedRequest.mode -ceq 'execute') {
	try {
		. (Join-Path $PSScriptRoot 'InitialPreparation.GitHub.ps1')
		. (Join-Path $PSScriptRoot 'InitialPreparation.Recovery.ps1')
		$AttemptRoot = Join-Path $EvidenceRoot $Attempt.attemptId
		$ExpectedRunner = [pscustomobject]@{ repository = $ExpectedRequest.repository; id = $ExpectedRequest.runnerId; name = $ExpectedRequest.runnerName }
		if (Test-Path -LiteralPath $AttemptRoot -PathType Container) {
			$Recovery = Invoke-InitialPreparationRecovery -IntentPath (Join-Path $AttemptRoot 'quarantine-intent.json') -ResultPath (Join-Path $AttemptRoot 'parent-recovery.json') -Attempt $Attempt -Runner $ExpectedRunner -RequestSha256 $RequestSha256 -OwnedCleanupVerified $CleanupVerified
			if ($Recovery.recoveryRequired -isnot [bool] -or $Recovery.recoveryRequired -or $Recovery.routingRestored -isnot [bool] -or -not $Recovery.routingRestored) { $Failure = 'routing_recovery_unproven' }
		} else { $Failure = 'recovery_attempt_evidence_missing' }
	} catch { $Failure = 'parent_recovery_failed' }
}
if ($null -ne $Process) { $Process.Dispose() }
if ($null -ne $Job) { $Job.Dispose() }
if ($null -ne $FrozenRequestStream) { $FrozenRequestStream.Dispose() }
if ($null -ne $FrozenRequestHandle) { $FrozenRequestHandle.Dispose() }
if ($null -ne $ControllerProof) { Close-InitialPreparationControllerProof -Proof $ControllerProof }
foreach ($Pin in $ParentDirectoryPins) { $Pin.Dispose() }
$Succeeded = $null -eq $Failure -and $null -ne $NativeExit -and $NativeExit -eq 0 -and $CleanupVerified -and -not $TimedOut
[pscustomobject]@{ schemaVersion = 1; scope = 'windows_operation_supervision'; attemptId = $Attempt.attemptId;
	controllerRevision = $Attempt.controllerRevision; targetRevision = $Attempt.targetRevision;
	requestSha256 = $RequestSha256;
	controllerManifestSha256 = $ControllerManifestSha256; recovery = $Recovery;
	nativeExitCode = $NativeExit; cleanupVerified = $CleanupVerified; timedOut = $TimedOut; failure = $Failure;
	operationSucceeded = $Succeeded; baselineVerified = $false } | ConvertTo-Json -Depth 4
if (-not $Succeeded) { exit 1 }
exit 0
