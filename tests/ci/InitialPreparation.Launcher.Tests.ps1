Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $RepositoryRoot 'scripts/ci/InitialPreparation.Controller.ps1')
$Launcher = Join-Path $RepositoryRoot 'scripts/ci/Invoke-InitialPreparation.ps1'
$Worker = Join-Path $PSScriptRoot 'fixtures/InitialPreparation.Worker.ps1'
if (-not (Test-Path -LiteralPath $Launcher)) { throw 'Preparation executable launcher is missing.' }
$EvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnLauncherFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $EvidenceRoot
$WorkerHash = (Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash.ToLowerInvariant()
foreach ($Case in @('zero', 'native-failure', 'bad-hash', 'descendant')) {
	$Hash = if ($Case -ceq 'bad-hash') { '0' * 64 } else { $WorkerHash }
	$Output = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId $Case -OperationScript $Worker -OperationSha256 $Hash -EvidenceRoot $EvidenceRoot
	$Expected = if ($Case -in @('native-failure', 'bad-hash')) { 1 } else { 0 }
	if ($LASTEXITCODE -ne $Expected) { throw "Unexpected launcher exit for $Case" }
	$Result = ($Output -join "`n") | ConvertFrom-Json
	if ($Result.attemptId -cne $Case -or $Result.controllerRevision -cne ('a' * 40) -or $Result.targetRevision -cne ('b' * 40) -or
		$Result.baselineVerified -isnot [bool] -or $Result.baselineVerified -or -not $Result.cleanupVerified -or $Result.timedOut) { throw 'Launcher evidence identity or cleanup mismatch.' }
	if ($Case -ceq 'native-failure' -and ($Result.nativeExitCode -ne 7 -or $Result.operationSucceeded)) { throw 'Launcher lost the actual native failure.' }
	if ($Case -in @('zero', 'descendant') -and ($Result.nativeExitCode -ne 0 -or -not $Result.operationSucceeded)) { throw 'Successful fixture evidence is contradictory.' }
	$AttemptRoot = Join-Path $EvidenceRoot $Case
	if ($Case -ceq 'bad-hash' -and (Test-Path -LiteralPath (Join-Path $AttemptRoot 'worker-started'))) { throw 'Hash mismatch executed the worker.' }
	$BootstrapResult = Get-Content -LiteralPath (Join-Path $AttemptRoot 'bootstrap-result.json') -Raw | ConvertFrom-Json
	if ($BootstrapResult.operationSha256 -cne $Hash -or $BootstrapResult.nativeExitCode -ne $Result.nativeExitCode) { throw 'Bootstrap evidence does not bind the worker source and exit.' }
	if ($Case -ceq 'bad-hash' -and $BootstrapResult.failurePhase -cne 'worker_source') { throw 'Missing bounded hash-failure diagnosis.' }
	if ($Case -ceq 'descendant') {
		$Identity = Get-Content -LiteralPath (Join-Path $AttemptRoot 'descendant.json') -Raw | ConvertFrom-Json
		$Child = Get-Process -Id $Identity.processId -ErrorAction SilentlyContinue
		if ($null -ne $Child) {
			try { if ($Child.StartTime.ToUniversalTime().Ticks -eq $Identity.creationTicks) { throw 'Owned descendant survived parent cleanup.' } }
			finally { $Child.Dispose() }
		}
	}
}
$Before = (Get-FileHash -LiteralPath (Join-Path $EvidenceRoot 'zero/attempt.json') -Algorithm SHA256).Hash
$RequestPath = Join-Path $EvidenceRoot 'request-input.json'
$RequestStream = [IO.File]::Open($RequestPath, [IO.FileMode]::CreateNew)
try { $RequestBytes = [Text.Encoding]::UTF8.GetBytes('{"fixtureValue":42}'); $RequestStream.Write($RequestBytes, 0, $RequestBytes.Length) } finally { $RequestStream.Dispose() }
$RequestHash = (Get-FileHash -LiteralPath $RequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$RequestOutput = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId request -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -RequestPath $RequestPath -RequestSha256 $RequestHash
if ($LASTEXITCODE -ne 0) { throw 'Frozen worker request failed.' }
$RequestResult = ($RequestOutput -join "`n") | ConvertFrom-Json
if (-not $RequestResult.operationSucceeded -or $RequestResult.requestSha256 -cne $RequestHash -or
	(Get-FileHash -LiteralPath (Join-Path $EvidenceRoot 'request/request.json') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $RequestHash) { throw 'Staged worker request bytes were not bound in evidence.' }
$null = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId request-mismatch -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -RequestPath $RequestPath -RequestSha256 ('0' * 64)
if ($LASTEXITCODE -ne 1 -or (Test-Path -LiteralPath (Join-Path $EvidenceRoot 'request-mismatch/worker-started'))) { throw 'Request mismatch did not prevent execution.' }
$Timer = [Diagnostics.Stopwatch]::StartNew()
$DeadlineOutput = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId deadline -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -OperationTimeoutSeconds 3
$DeadlineResult = ($DeadlineOutput -join "`n") | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or -not $DeadlineResult.timedOut -or -not $DeadlineResult.cleanupVerified -or $DeadlineResult.operationSucceeded -or $Timer.Elapsed.TotalSeconds -gt 12) { throw 'Launcher did not bound the stalled worker independently.' }
& powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId zero -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot
if ($LASTEXITCODE -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $EvidenceRoot 'zero/attempt.json') -Algorithm SHA256).Hash -cne $Before) { throw 'Repeated attempt overwrote prior evidence.' }
Write-Output ('PASS: launcher native/failure/hash/descendant/repeated-attempt fixtures; evidence retained at ' + $EvidenceRoot)

$Files = @(foreach ($RelativePath in (Get-InitialPreparationControllerPath)) {
	$SourcePath = Join-Path $RepositoryRoot $RelativePath
	[pscustomobject]@{ path = $RelativePath; sha256 = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = [long] (Get-Item -LiteralPath $SourcePath).Length }
})
$Manifest = [ordered]@{ schemaVersion = 1; repository = 'owner/repository'; controllerRevision = ('a' * 40); files = $Files }
$ManifestPath = Join-Path $EvidenceRoot 'controller-manifest.json'
$Stream = [IO.File]::Open($ManifestPath, [IO.FileMode]::CreateNew)
try { $Bytes = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 5 -Compress)); $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
$ManifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ControllerOutput = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId controller -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -ControllerManifestPath $ManifestPath -ControllerManifestSha256 $ManifestHash
if ($LASTEXITCODE -ne 0) { throw 'Reviewed controller launch failed' }
$ControllerResult = ($ControllerOutput -join "`n") | ConvertFrom-Json
if (-not $ControllerResult.operationSucceeded -or $ControllerResult.controllerManifestSha256 -cne $ManifestHash) { throw 'Full controller proof not propagated' }
$BadControllerOutput = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId controller-bad -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -ControllerManifestPath $ManifestPath -ControllerManifestSha256 ('0' * 64)
if ($LASTEXITCODE -ne 1 -or (Test-Path -LiteralPath (Join-Path $EvidenceRoot 'controller-bad/worker-started'))) { throw 'Bad controller digest launched worker' }
if ((($BadControllerOutput -join "`n") | ConvertFrom-Json).operationSucceeded) { throw 'Bad controller accepted' }
$ExecutionRequest = [ordered]@{ schemaVersion = 2; repository = 'owner/repository'; targetRevision = ('b' * 40); engineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'; runnerId = 21; runnerName = 'fixture'; engineRoot = 'D:\engine'; targetRoot = 'D:\target'; sourceRoot = 'D:\source'; lfsStorageRoot = 'D:\cache'; leasePath = 'D:\lease\fixture'; yamlAssemblyPath = 'D:\fixture.dll'; linuxToolchainRoot = 'D:\toolchain'; mode = 'execute'; authorizationReference = 'fixture-only-no-runner-operation' }
$ExecutionRequest['compilerPath'] = 'D:\tools\cl.exe'; $ExecutionRequest['resourceCompilerPath'] = 'D:\tools\rc.exe'
$RequestDirectory = Join-Path $EvidenceRoot 'request-source'
$null = New-Item -ItemType Directory -Path $RequestDirectory
$ExecutionRequestPath = Join-Path $RequestDirectory 'execution-request.json'
$Stream = [IO.File]::Open($ExecutionRequestPath, [IO.FileMode]::CreateNew)
try { $Bytes = [Text.Encoding]::UTF8.GetBytes(($ExecutionRequest | ConvertTo-Json -Compress)); $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
$ExecutionRequestHash = (Get-FileHash -LiteralPath $ExecutionRequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$DeathOutput = & powershell.exe -NoProfile -File $Launcher -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId controller-death -OperationScript $Worker -OperationSha256 $WorkerHash -EvidenceRoot $EvidenceRoot -ControllerManifestPath $ManifestPath -ControllerManifestSha256 $ManifestHash -RequestPath $ExecutionRequestPath -RequestSha256 $ExecutionRequestHash
$DeathResult = ($DeathOutput -join "`n") | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $DeathResult.nativeExitCode -ne 13 -or -not $DeathResult.cleanupVerified -or $DeathResult.operationSucceeded -or $DeathResult.recovery.failureCode -cne 'recovery_intent_missing' -or -not $DeathResult.recovery.recoveryRequired) { throw 'Abrupt worker exit did not run parent-side recovery assessment' }
if (-not (Test-Path -LiteralPath (Join-Path $EvidenceRoot 'controller-death/parent-recovery.json'))) { throw 'Parent recovery evidence missing after worker death' }
Write-Output 'PASS: frozen controller launch and abrupt worker death recovery assessment (no runner API)'
