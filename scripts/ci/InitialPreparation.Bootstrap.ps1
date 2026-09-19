[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $AttemptJson,
	[Parameter(Mandatory)][string] $OperationScript,
	[Parameter(Mandatory)][string] $OperationSha256,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[string] $RequestPath,
	[string] $RequestSha256,
	[string] $ControllerManifestSha256,
	[string] $BuildInvocationSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
$SourceStream = $null
$SourceHandle = $null
$AttemptStream = $null
$RequestSourceStream = $null
$RequestSourceHandle = $null
$RequestCopyStream = $null
$ExitCode = 1
$DirectoryPins = New-Object Collections.ArrayList
$CreatedAttemptRoot = $false
$Phase = 'input'
$FailurePhase = $null
try {
	if ($AttemptJson.Length -gt 16384) { throw 'attempt_input_limit' }
	$Attempt = $AttemptJson | ConvertFrom-Json
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'operation_deadline_elapsed' }
	if (-not [IO.Path]::IsPathRooted($EvidenceRoot) -or -not [IO.Path]::IsPathRooted($OperationScript) -or
		[IO.Path]::GetExtension($OperationScript) -ine '.ps1' -or $OperationSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'bootstrap_path_invalid' }
	Assert-InitialPreparationPlainPath -Path $EvidenceRoot -Reason 'bootstrap_path_invalid'
	Assert-InitialPreparationPlainPath -Path $OperationScript -Reason 'bootstrap_path_invalid'
	if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'bootstrap_path_invalid' }
	$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
	if (Test-InitialPreparationWithin -Candidate $EvidenceRoot -Parent $RepositoryRoot) { throw 'bootstrap_path_invalid' }
	if (-not (Test-InitialPreparationWithin -Candidate $OperationScript -Parent $RepositoryRoot)) { throw 'bootstrap_path_invalid' }
	$Phase = 'directory_pins'
	foreach ($Directory in @($EvidenceRoot, [IO.Path]::GetDirectoryName($OperationScript))) {
		foreach ($Handle in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $DirectoryPins.Add($Handle) }
	}
	$AttemptRoot = Join-Path $EvidenceRoot $Attempt.attemptId
	# New-Item without Force refuses a prior attempt: never reuse or overwrite it.
	$Phase = 'attempt_directory'
	$null = New-Item -ItemType Directory -Path $AttemptRoot -ErrorAction Stop
	$CreatedAttemptRoot = $true
	foreach ($Handle in (Get-InitialPreparationDirectoryPin -Directory $AttemptRoot)) { [void] $DirectoryPins.Add($Handle) }
	$Phase = 'attempt_record'
	$AttemptPath = Join-Path $AttemptRoot 'attempt.json'
	$Bytes = [Text.Encoding]::UTF8.GetBytes($AttemptJson)
	$AttemptStream = [IO.File]::Open($AttemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
	$AttemptStream.Write($Bytes, 0, $Bytes.Length); $AttemptStream.Flush($true)
	$Phase = 'worker_source'
	$SourceHandle = [Aetheln.PreparationDirectory]::OpenSource($OperationScript)
	$SourceStream = [IO.FileStream]::new($SourceHandle, [IO.FileAccess]::Read)
	if ($SourceStream.Length -gt 262144 -or $SourceStream.Length -lt 1) { throw 'operation_source_limit' }
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($SourceStream))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
	if ($Digest -cne $OperationSha256) { throw 'operation_source_mismatch' }
	$WorkerArguments = @{ AttemptPath = $AttemptPath; EvidenceRoot = $AttemptRoot }
	if ($ControllerManifestSha256) {
		$WorkerArguments.ControllerManifestSha256 = $ControllerManifestSha256
		$WorkerArguments.BuildInvocationSha256 = $BuildInvocationSha256
	}
	if ([string]::IsNullOrEmpty($RequestPath) -ne [string]::IsNullOrEmpty($RequestSha256)) { throw 'request_identity_incomplete' }
	if ($RequestPath) {
		$Phase = 'worker_request'
		if (-not [IO.Path]::IsPathRooted($RequestPath) -or [IO.Path]::GetExtension($RequestPath) -ine '.json' -or $RequestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'request_identity_invalid' }
		foreach ($Handle in (Get-InitialPreparationDirectoryPin -Directory ([IO.Path]::GetDirectoryName($RequestPath)))) { [void] $DirectoryPins.Add($Handle) }
		$RequestSourceHandle = [Aetheln.PreparationDirectory]::OpenSource($RequestPath)
		$RequestSourceStream = [IO.FileStream]::new($RequestSourceHandle, [IO.FileAccess]::Read)
		if ($RequestSourceStream.Length -lt 1 -or $RequestSourceStream.Length -gt 65536) { throw 'request_size_invalid' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $RequestDigest = ([BitConverter]::ToString($Hasher.ComputeHash($RequestSourceStream))).Replace('-', '').ToLowerInvariant() }
		finally { $Hasher.Dispose() }
		if ($RequestDigest -cne $RequestSha256) { throw 'request_source_mismatch' }
		$FrozenRequestPath = Join-Path $AttemptRoot 'request.json'
		$RequestCopyStream = [IO.File]::Open($FrozenRequestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
		$RequestSourceStream.Position = 0
		$RequestSourceStream.CopyTo($RequestCopyStream); $RequestCopyStream.Flush($true)
		$WorkerArguments.RequestPath = $FrozenRequestPath
	}
	# Retain both input handles until the worker returns; the worker sees the
	# original parent deadline and cannot overwrite its attempt or script bytes.
	$global:LASTEXITCODE = 0
	$Phase = 'worker'
	& $OperationScript @WorkerArguments | Out-Null
	$ExitCode = $LASTEXITCODE
} catch { $ExitCode = 1; $FailurePhase = $Phase }
finally {
	if ($CreatedAttemptRoot) {
		try {
			$Record = [pscustomobject]@{ schemaVersion = 1; scope = 'bootstrap'; attemptId = $Attempt.attemptId;
				operationSha256 = $OperationSha256; requestSha256 = $RequestSha256; nativeExitCode = $ExitCode; failurePhase = $FailurePhase }
			$RecordBytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Compress))
			if ($RecordBytes.Length -gt 4096) { throw 'bootstrap_record_limit' }
			$RecordStream = [IO.File]::Open((Join-Path $AttemptRoot 'bootstrap-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
			try { $RecordStream.Write($RecordBytes, 0, $RecordBytes.Length); $RecordStream.Flush($true) } finally { $RecordStream.Dispose() }
		} catch { $ExitCode = 1 }
	}
	if ($null -ne $SourceStream) { $SourceStream.Dispose() }
	if ($null -ne $SourceHandle) { $SourceHandle.Dispose() }
	if ($null -ne $AttemptStream) { $AttemptStream.Dispose() }
	if ($null -ne $RequestCopyStream) { $RequestCopyStream.Dispose() }
	if ($null -ne $RequestSourceStream) { $RequestSourceStream.Dispose() }
	if ($null -ne $RequestSourceHandle) { $RequestSourceHandle.Dispose() }
	foreach ($Handle in $DirectoryPins) { $Handle.Dispose() }
}
exit $ExitCode
