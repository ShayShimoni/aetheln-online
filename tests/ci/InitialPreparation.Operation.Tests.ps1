Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Revision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Fixture repository identity unavailable.' }
$Status = @(& git --no-optional-locks -C $RepositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Fixture repository status unavailable.' }
$Identity = Get-InitialPreparationCheckoutIdentity -Root $RepositoryRoot -ExpectedRevision $Revision
if ($Identity.revision -cne $Revision -or $Identity.clean -isnot [bool] -or $Identity.clean -ne ($Status.Count -eq 0)) { throw 'Checkout cleanliness did not match actual Git status.' }
foreach ($Case in @(
	@{ Root = $RepositoryRoot; ExpectedRevision = ('0' * 40) },
	@{ Root = (Join-Path $RepositoryRoot 'scripts'); ExpectedRevision = $Revision },
	@{ Root = 'D:relative'; ExpectedRevision = $Revision }
)) {
	$Rejected = $false
	try { $null = Get-InitialPreparationCheckoutIdentity @Case } catch { $Rejected = $_.Exception.Message -ceq 'checkout_identity_invalid' }
	if (-not $Rejected) { throw 'Wrong revision, nested directory or relative root accepted.' }
}
$Launcher = Join-Path $RepositoryRoot 'scripts/ci/Invoke-InitialPreparation.ps1'
$Operation = Join-Path $RepositoryRoot 'scripts/ci/InitialPreparation.Operation.ps1'
$OperationHash = (Get-FileHash -LiteralPath $Operation -Algorithm SHA256).Hash.ToLowerInvariant()
$EvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnOperationFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $EvidenceRoot
foreach ($Case in @('execute', 'overlap')) {
	$Request = [ordered]@{ schemaVersion = 2; repository = 'owner/repository'; targetRevision = $Revision;
		engineRevision = '9ab6767ecaaa724d01371ffaea14317311ae8371'; runnerId = 21; runnerName = 'fixture';
		engineRoot = 'D:\engine'; targetRoot = $RepositoryRoot; leasePath = 'D:\control\host.lease';
		yamlAssemblyPath = 'D:\control\YamlDotNet.dll'; linuxToolchainRoot = 'D:\toolchain';
		sourceRoot = 'D:\source'; lfsStorageRoot = 'D:\lfs-cache';
		compilerPath = 'D:\tools\cl.exe'; resourceCompilerPath = 'D:\tools\rc.exe';
		mode = $(if ($Case -ceq 'execute') { 'execute' } else { 'inspect' }); authorizationReference = 'fixture-only' }
	$RequestPath = Join-Path $EvidenceRoot ($Case + '.json')
	$Stream = [IO.File]::Open($RequestPath, [IO.FileMode]::CreateNew)
	try { $Bytes = [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Compress)); $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
	$Hash = (Get-FileHash -LiteralPath $RequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$Output = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision $Revision -TargetRevision $Revision -AttemptId $Case -OperationScript $Operation -OperationSha256 $OperationHash -EvidenceRoot $EvidenceRoot -RequestPath $RequestPath -RequestSha256 $Hash -OperationTimeoutSeconds 30
	if ($LASTEXITCODE -ne 1) { throw 'Missing reviewed controller identity or overlapping source roots did not reject.' }
	$Parent = ($Output -join "`n") | ConvertFrom-Json
	if ($Parent.operationSucceeded -or -not $Parent.cleanupVerified -or $Parent.baselineVerified) { throw 'Failed preflight promoted to acceptance or cleanup unproven.' }
	$Preflight = Get-Content -LiteralPath (Join-Path $EvidenceRoot "$Case/preflight.json") -Raw | ConvertFrom-Json
	$Expected = if ($Case -ceq 'execute') { 'execution_controller_identity_missing' } else { 'operation_roots_overlap' }
	if ($Preflight.failureCode -cne $Expected -or $Preflight.complete -or $Preflight.executionReady -or $Preflight.baselineVerified) { throw 'Preflight failure evidence is incomplete or contradictory.' }
}
Write-Output ('PASS: bounded real Git and supervised production operation rejection fixtures; retained ' + $EvidenceRoot)

# Exercise the real Operation entry point in an isolated dependency closure.
# Only Execution is synthetic: it never loads production execution, transport,
# materialization, or engine code and records exactly what Operation supplied.
function Write-OperationFixtureText {
	param([string] $Path, [string] $Text)
	$FixtureBytes = [Text.Encoding]::UTF8.GetBytes($Text)
	$FixtureStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
	try { $FixtureStream.Write($FixtureBytes, 0, $FixtureBytes.Length) } finally { $FixtureStream.Dispose() }
}
$DispatchRoot = Join-Path $EvidenceRoot 'synthetic-dispatch'
$null = New-Item -ItemType Directory -Path $DispatchRoot
foreach ($Case in @('dispatch-success', 'dispatch-nonzero')) {
	$CaseRoot = Join-Path $DispatchRoot $Case
	$CodeRoot = Join-Path $CaseRoot 'code'
	$CaseEvidence = Join-Path $CaseRoot 'evidence'
	$null = New-Item -ItemType Directory -Path $CodeRoot
	$null = New-Item -ItemType Directory -Path $CaseEvidence
	foreach ($Dependency in @('Core', 'GitHub', 'Operation')) {
		$Name = 'InitialPreparation.' + $Dependency + '.ps1'
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot ('scripts/ci/' + $Name)) -Destination (Join-Path $CodeRoot $Name) -ErrorAction Stop
	}
	$DispatchAttempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision $Revision -TargetRevision $Revision -AttemptId $Case
	$DispatchAttemptPath = Join-Path $CaseRoot 'attempt.json'
	Write-OperationFixtureText -Path $DispatchAttemptPath -Text ($DispatchAttempt | ConvertTo-Json -Depth 4 -Compress)
	$DispatchRequest = [ordered]@{ schemaVersion = 2; repository = 'owner/repository'; targetRevision = $Revision;
		engineRevision = '9ab6767ecaaa724d01371ffaea14317311ae8371'; runnerId = 21; runnerName = 'synthetic-only';
		engineRoot = 'D:\unused-engine'; targetRoot = 'D:\unused-target'; sourceRoot = 'D:\unused-source';
		lfsStorageRoot = 'D:\unused-cache'; linuxToolchainRoot = 'D:\unused-toolchain'; compilerPath = 'D:\unused-tools\cl.exe';
		resourceCompilerPath = 'D:\unused-tools\rc.exe'; leasePath = 'D:\unused-lease'; yamlAssemblyPath = 'D:\unused-yaml.dll';
		mode = 'execute'; authorizationReference = 'synthetic fixture; no runner or engine authorization' }
	$DispatchRequestPath = Join-Path $CaseRoot 'request.json'
	# Trailing whitespace ensures the forwarded hash represents actual source
	# bytes, not a parsed-and-reserialized approximation of the request.
	Write-OperationFixtureText -Path $DispatchRequestPath -Text (($DispatchRequest | ConvertTo-Json -Compress) + "`n ")
	$DispatchHash = (Get-FileHash -LiteralPath $DispatchRequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$FakeExecution = @'
function Invoke-InitialPreparationExecution {
	param($Attempt, $Request, $EvidenceRoot, $RequestSha256, $ControllerManifestSha256, $BuildInvocationSha256)
	if ($RequestSha256 -cne '__REQUEST_HASH__' -or $ControllerManifestSha256 -cne ('c' * 64) -or $BuildInvocationSha256 -cne ('d' * 64) -or
		$Request.mode -cne 'execute' -or $Request.runnerName -cne 'synthetic-only' -or $Request.sourceRoot -cne 'D:\unused-source' -or
		$Request.targetRevision -cne $Attempt.targetRevision -or $Request.repository -cne $Attempt.repository) { throw 'synthetic_dispatch_binding_failed' }
	$NativeExit = if ($Attempt.attemptId -ceq 'dispatch-success') { 0 } else { 7 }
	$Record = [ordered]@{ attemptId = $Attempt.attemptId; evidenceRoot = $EvidenceRoot; requestSha256 = $RequestSha256;
		controllerManifestSha256 = $ControllerManifestSha256; buildInvocationSha256 = $BuildInvocationSha256; nativeExitCode = $NativeExit }
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Compress))
	$Stream = [IO.File]::Open((Join-Path $EvidenceRoot 'synthetic-dispatch.json'), [IO.FileMode]::CreateNew)
	try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
	return [pscustomobject]@{ nativeExitCode = $NativeExit; baselineVerified = ($NativeExit -eq 0); failureCode = $(if ($NativeExit -eq 0) { $null } else { 'synthetic_execution_failure' }) }
}
'@
	Write-OperationFixtureText -Path (Join-Path $CodeRoot 'InitialPreparation.Execution.ps1') -Text $FakeExecution.Replace('__REQUEST_HASH__', $DispatchHash)
	$ExpectedExit = if ($Case -ceq 'dispatch-success') { 0 } else { 7 }
	& powershell.exe -NoProfile -File (Join-Path $CodeRoot 'InitialPreparation.Operation.ps1') -AttemptPath $DispatchAttemptPath -RequestPath $DispatchRequestPath -EvidenceRoot $CaseEvidence -ControllerManifestSha256 ('c' * 64) -BuildInvocationSha256 ('d' * 64)
	if ($LASTEXITCODE -ne $ExpectedExit) { throw ('Synthetic Operation native exit mismatch: ' + $Case + '/' + $LASTEXITCODE) }
	$Dispatch = Get-Content -LiteralPath (Join-Path $CaseEvidence 'synthetic-dispatch.json') -Raw | ConvertFrom-Json
	$Final = Get-Content -LiteralPath (Join-Path $CaseEvidence 'preflight.json') -Raw | ConvertFrom-Json
	if ($Dispatch.attemptId -cne $Case -or $Dispatch.evidenceRoot -cne $CaseEvidence -or $Dispatch.requestSha256 -cne $DispatchHash -or
		$Dispatch.controllerManifestSha256 -cne ('c' * 64) -or $Dispatch.buildInvocationSha256 -cne ('d' * 64) -or $Dispatch.nativeExitCode -ne $ExpectedExit) { throw 'Synthetic dispatch argument evidence mismatch' }
	if ($Final.scope -cne 'bounded_preparation_execution' -or $Final.complete -isnot [bool] -or -not $Final.complete -or
		$Final.executionReady -isnot [bool] -or -not $Final.executionReady -or $Final.baselineVerified -isnot [bool] -or
		$Final.baselineVerified -ne ($ExpectedExit -eq 0) -or $Final.observations.execution.nativeExitCode -ne $ExpectedExit -or
		$Final.requestSha256 -cne $DispatchHash -or $Final.controllerManifestSha256 -cne ('c' * 64) -or $Final.buildInvocationSha256 -cne ('d' * 64) -or
		$null -ne $Final.failurePhase -or $null -ne $Final.failureCode -or [string]::IsNullOrWhiteSpace($Final.finishedUtc)) { throw 'Operation final evidence lost synthetic execution result' }
	if ($ExpectedExit -ne 0 -and $Final.observations.execution.failureCode -cne 'synthetic_execution_failure') { throw 'Synthetic Execution failure reason lost' }
}
Write-Output ('PASS: real Operation dispatch to synthetic success/nonzero Execution, including byte-bound hashes and final evidence; retained ' + $DispatchRoot)
