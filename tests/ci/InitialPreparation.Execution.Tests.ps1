Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Execution.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Production execution adapter missing' }
. $Module
function Test-ExecutionAdapter {
	$Attempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId execution-fixture
	$Request = [pscustomobject]@{ mode = 'execute'; repository = $Attempt.repository; targetRevision = $Attempt.targetRevision; runnerId = 21; runnerName = 'fixture'; engineRoot = 'D:\engine'; sourceRoot = 'D:\source'; targetRoot = 'D:\target'; lfsStorageRoot = 'D:\cache'; linuxToolchainRoot = 'D:\linux'; compilerPath = 'D:\tools\cl.exe'; resourceCompilerPath = 'D:\tools\rc.exe'; yamlAssemblyPath = 'D:\yaml.dll'; leasePath = 'D:\lease'; authorizationReference = 'fixture-only' }
	function Assert-InitialPreparationExecutionRoot { param($Request, $EvidenceRoot) if ($Request.targetRoot -cne 'D:\target') { throw 'root binding lost' }; return @{ evidence = $EvidenceRoot } }
	function Test-InitialPreparationSourceBinding { param($ReviewedRequest, $SourceRoot, $Repository, $TargetRevision, $LfsStorageRoot, $Attempt, $OnProgress) if ($ReviewedRequest.sourceRoot -cne $SourceRoot -or $Repository -cne $Attempt.repository -or $TargetRevision -cne $Attempt.targetRevision -or $LfsStorageRoot -cne 'D:\cache') { throw 'source binding lost' }; & $OnProgress; return $true }
	function Get-InitialPreparationRunner { param($Repository, $RunnerId, $ExpectedName) return [pscustomobject]@{ repository = $Repository; id = $RunnerId; name = $ExpectedName; originalLabels = @('self-hosted', 'Windows', 'X64', 'aetheln-engine') } }
	function Get-InitialPreparationAdmissionInventory { param($Runner, $YamlAssemblyPath, $Cache) if ($Runner.id -ne 21 -or $YamlAssemblyPath -cne 'D:\yaml.dll' -or $Cache -isnot [hashtable]) { throw 'inventory binding lost' }; return [pscustomobject]@{ complete = $true } }
	function Get-InitialPreparationLocalWork { param($EngineRoot) if ($EngineRoot -cne 'D:\engine') { throw 'local probe binding lost' }; return [pscustomobject]@{ complete = $true; activeProcessCount = 0 } }
	function Write-InitialPreparationRecoveryIntent { param($Path, $Attempt, $Runner, $RequestSha256) if ($Runner.id -ne 21 -or $Attempt.attemptId -cne 'execution-fixture' -or $RequestSha256 -cne ('c' * 64) -or (Split-Path -Leaf $Path) -cne 'quarantine-intent.json') { throw 'intent binding lost' }; return $true }
	function Invoke-InitialPreparationAdmittedWork {
		param($Context, $SourceRoot, $TargetRoot, $EngineRoot, $LinuxToolchainRoot, $LfsStorageRoot, $CompilerPath, $ResourceCompilerPath, $ExpectedInvocationSha256, $YamlAssemblyPath, $EvidenceRoot, $Roots, $AssertSourceTrust)
		if ($Context.attempt.attemptId -cne 'execution-fixture' -or $SourceRoot -cne 'D:\source' -or $TargetRoot -cne 'D:\target' -or $EngineRoot -cne 'D:\engine' -or $LinuxToolchainRoot -cne 'D:\linux' -or $LfsStorageRoot -cne 'D:\cache' -or $CompilerPath -cne 'D:\tools\cl.exe' -or $ResourceCompilerPath -cne 'D:\tools\rc.exe' -or $ExpectedInvocationSha256 -cne ('e' * 64) -or $YamlAssemblyPath -cne 'D:\yaml.dll' -or $Roots.Count -ne 1 -or -not (Test-Path -LiteralPath $EvidenceRoot)) { throw 'work binding lost' }
		if (-not (& $AssertSourceTrust $SourceRoot 'owner/repository' ('b' * 40) $LfsStorageRoot { $State.admittedTrustProgress++ })) { throw 'source callback lost' }
		if ($State.admittedTrustProgress -lt 1) { throw 'Admitted source checks bypass resource and quarantine progress' }
		if ($State.mode -ceq 'work_failure') { throw 'fixture_build_failed' }
		return [pscustomobject]@{ nativeExitCode = 0; builds = @(1..6); inputDigest = ('f' * 64); hostInputDigest = ('a' * 64); invocationSha256 = ('e' * 64) }
	}
	function Invoke-InitialPreparationMaintenance {
		param($Attempt, $Runner, $LeasePath, $InventoryProbe, $LocalWorkerProbe, $Work, $FreezeEvidence, $PersistQuarantineIntent)
		if ($LeasePath -cne 'D:\lease' -or -not (& $InventoryProbe).complete -or -not (& $LocalWorkerProbe).complete -or -not (& $PersistQuarantineIntent $Attempt $Runner)) { throw 'maintenance callback lost' }
		$Context = [pscustomobject]@{ attempt = $Attempt; runner = $Runner; lease = [pscustomobject]@{ fixture = $true }; admission = [pscustomobject]@{ admitted = $true } }
		$Result = $null; $Errors = @()
		try { $Result = & $Work $Context } catch { if ($_.Exception.Message -cne 'fixture_build_failed') { throw }; $Errors = @('work_failed') }
		& $FreezeEvidence ([pscustomobject]@{ attempt = $Attempt; runner = $Runner; lease = $Context.lease; workResult = $Result })
		if ($State.mode -ceq 'restoration_failure') { $Errors += 'routing_restoration_failed' }
		return [pscustomobject]@{ admitted = $true; cycleCompleted = ($Errors.Count -eq 0); leaseReleased = $true; routingRestored = ($State.mode -cne 'restoration_failure'); errors = $Errors; workResult = $Result; cleanup = [pscustomobject]@{ cleanupVerified = $true; remainingOwnedProcesses = @() } }
	}
	function Write-InitialPreparationExecutionFreeze { param($Context, $EvidenceRoot) if ($Context.attempt.attemptId -cne 'execution-fixture' -or -not (Test-Path -LiteralPath $EvidenceRoot)) { throw 'freeze binding lost' }; $State.frozen = $true; return ,@() }
	function Get-InitialPreparationToolSelection {
		param($Attempt, $Builds, $EvidenceRoot, $CompilerPath, $ResourceCompilerPath, $InputDigest)
		if ($Attempt.attemptId -cne 'execution-fixture' -or $Builds.Count -ne 6 -or -not (Test-Path -LiteralPath $EvidenceRoot) -or $CompilerPath -cne 'D:\tools\cl.exe' -or $ResourceCompilerPath -cne 'D:\tools\rc.exe' -or $InputDigest -cne ('f' * 64)) { throw 'selection binding lost' }
		if ($State.mode -ceq 'selection_failure') { throw 'selection_unproven' }
		return [pscustomobject]@{ verified = $true; digest = ('b' * 64); records = @() }
	}
	function Write-InitialPreparationReceipt {
		param($State, $Artifacts, $Path)
		if ($State.outcome -ceq 'warm_baseline_verified' -and ($Artifacts.Count -ne 1 -or $Artifacts[0].name -cne 'tool-selection.json' -or $State.requestSha256 -cne ('c' * 64) -or $State.controllerManifestSha256 -cne ('d' * 64))) { throw 'Selection artifact or terminal source bindings lost' }
		if ((Split-Path -Leaf $Path) -cne 'preparation-receipt.json') { throw 'receipt location lost' }
		return [pscustomobject]@{ bytes = 1; sha256 = ('a' * 64) }
	}
	foreach ($Mode in @('work_failure', 'restoration_failure', 'selection_failure', 'success')) {
		$State = @{ mode = $Mode; frozen = $false; admittedTrustProgress = 0 }
		$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnExecution-' + [guid]::NewGuid().ToString('N'))
		$null = New-Item -ItemType Directory -Path $Root
		$Result = Invoke-InitialPreparationExecution -Attempt $Attempt -Request $Request -EvidenceRoot $Root -RequestSha256 ('c' * 64) -ControllerManifestSha256 ('d' * 64) -BuildInvocationSha256 ('e' * 64)
		if (-not $State.frozen) { throw 'Evidence not frozen' }
		if ($Mode -ceq 'success') {
			if ($Result.nativeExitCode -ne 0 -or -not $Result.baselineVerified -or -not $Result.maintenance.cycleCompleted -or -not (Test-Path -LiteralPath (Join-Path $Root 'tool-selection.json'))) { throw 'Successful wiring failed' }
		} elseif ($Result.nativeExitCode -ne 1 -or $Result.baselineVerified) { throw 'Failed lifecycle promoted to success' }
	}
}
Test-ExecutionAdapter

# Real local path and freeze boundaries, without GitHub or engine invocation.
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnExecutionEvidence-' + [guid]::NewGuid().ToString('N'))
foreach ($Name in @('source', 'engine', 'target-parent', 'evidence', 'cache', 'toolchain', 'tools', 'control')) { $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $Name) }
$RootRequest = [pscustomobject]@{ sourceRoot = (Join-Path $FixtureRoot 'source'); engineRoot = (Join-Path $FixtureRoot 'engine'); targetRoot = (Join-Path $FixtureRoot 'target-parent/fresh'); lfsStorageRoot = (Join-Path $FixtureRoot 'cache'); linuxToolchainRoot = (Join-Path $FixtureRoot 'toolchain'); compilerPath = (Join-Path $FixtureRoot 'tools/cl.exe'); resourceCompilerPath = (Join-Path $FixtureRoot 'tools/rc.exe') }
$Evidence = Join-Path $FixtureRoot 'evidence'
$Roots = Assert-InitialPreparationExecutionRoot -Request $RootRequest -EvidenceRoot $Evidence
if ($Roots.target -cne (Join-Path $FixtureRoot 'target-parent') -or $Roots.cache -cne $RootRequest.lfsStorageRoot) { throw 'Prewrite resource roots do not include target parent/cache' }
$Overlap = $RootRequest.PSObject.Copy(); $Overlap.targetRoot = Join-Path $RootRequest.sourceRoot 'nested'
$Rejected = $false
try { $null = Assert-InitialPreparationExecutionRoot -Request $Overlap -EvidenceRoot $Evidence } catch { $Rejected = $_.Exception.Message -ceq 'execution_roots_overlap' }
if (-not $Rejected) { throw 'Overlapping source/target roots accepted' }
$null = New-Item -ItemType Directory -Path $RootRequest.targetRoot
$Rejected = $false
try { $null = Assert-InitialPreparationExecutionRoot -Request $RootRequest -EvidenceRoot $Evidence } catch { $Rejected = $_.Exception.Message -ceq 'materialization_target_exists' }
if (-not $Rejected) { throw 'Existing target accepted by execution adapter' }
$null = New-Item -ItemType Directory -Path (Join-Path $Evidence 'work/builds')
foreach ($Name in @('work/host-inputs.json', 'work/builds/sequence-result.json', 'work/synchronous-resources.jsonl', 'work/work-failure.json')) {
	$Stream = [IO.File]::Open((Join-Path $Evidence $Name), [IO.FileMode]::CreateNew)
	try { $Bytes = [Text.Encoding]::UTF8.GetBytes('{}'); $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
}
$FreezeAttempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId freeze-fixture
$Artifacts = Write-InitialPreparationExecutionFreeze -Context ([pscustomobject]@{ attempt = $FreezeAttempt; workResult = $null }) -EvidenceRoot $Evidence
if ($Artifacts.Count -ne 4) { throw 'Partial work evidence discarded when workResult is null' }
foreach ($Artifact in $Artifacts) {
	if ($Artifact.bytes -ne 2 -or $Artifact.sha256 -cne (Get-FileHash -LiteralPath (Join-Path $Evidence $Artifact.name) -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Frozen artifact digest mismatch' }
}
$FrozenPath = Join-Path $Evidence 'frozen-artifacts.json'
$Before = (Get-FileHash -LiteralPath $FrozenPath -Algorithm SHA256).Hash
$Rejected = $false
try { $null = Write-InitialPreparationExecutionFreeze -Context ([pscustomobject]@{ attempt = $FreezeAttempt; workResult = $null }) -EvidenceRoot $Evidence } catch { $Rejected = $true }
if (-not $Rejected -or (Get-FileHash -LiteralPath $FrozenPath -Algorithm SHA256).Hash -cne $Before) { throw 'Frozen evidence was overwritten' }
foreach ($Size in @(4096, 4097)) {
	$BoundaryRoot = Join-Path $FixtureRoot ('failure-limit-' + $Size)
	$null = New-Item -ItemType Directory -Path (Join-Path $BoundaryRoot 'work')
	$Stream = [IO.File]::Open((Join-Path $BoundaryRoot 'work/work-failure.json'), [IO.FileMode]::CreateNew)
	try { $Stream.SetLength($Size) } finally { $Stream.Dispose() }
	$Failure = $null; $BoundaryArtifacts = $null
	try { $BoundaryArtifacts = Write-InitialPreparationExecutionFreeze -Context ([pscustomobject]@{ attempt = $FreezeAttempt; workResult = $null }) -EvidenceRoot $BoundaryRoot } catch { $Failure = $_.Exception.Message }
	if ($Size -eq 4096) {
		if ($null -ne $Failure -or $BoundaryArtifacts.Count -ne 1 -or $BoundaryArtifacts[0].bytes -ne 4096) { throw 'Exact failure evidence limit rejected' }
	} elseif ($Failure -cne 'execution_evidence_limit' -or (Test-Path -LiteralPath (Join-Path $BoundaryRoot 'frozen-artifacts.json'))) { throw 'Oversized failure evidence was accepted or frozen' }
}
Write-Output ('PASS: production execution success/failure wiring and real root/freeze fixtures; evidence ' + $FixtureRoot)
