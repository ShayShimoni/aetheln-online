[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Input.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Materialize.ps1')
function Assert-MaterializeTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-MaterializeRejected {
	param([scriptblock] $Action, [string] $Reason)
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.GetBaseException().Message }
	Assert-MaterializeTest -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; received $Failure"
}
function Invoke-MaterializeFixtureGit {
	param([string] $Root, [string[]] $Arguments)
	$Output = & git -c core.autocrlf=false -C $Root @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $Output" }
	return $Output
}
function Test-MaterializeCapacityRefusal {
	param([hashtable] $Parameters)
	Assert-MaterializeTest -Condition ($Parameters.TargetRoot -is [string]) -Message 'Capacity fixture target missing'
	function Get-InitialPreparationCapacity {
		param($Roots, $Attempt, $KnownAllocations)
		Assert-MaterializeTest -Condition ($Roots.ContainsKey('materializationTarget') -and $Attempt.targetRevision -cmatch '^[0-9a-f]{40}$' -and $KnownAllocations.materializationTarget -eq 13L) -Message 'Prewrite checkout allocation missing'
		return [pscustomobject]@{ physicalCores = 8; availablePhysicalRamGiB = 24.0; commitHeadroomGiB = 24.0;
			volumes = @([pscustomobject]@{ availableBytes = [long](20GB + 13); knownAllocationBytes = 13L; recoveryFloorBytes = 20GB }) }
	}
	Assert-MaterializeRejected -Action { New-InitialPreparationMaterialization @Parameters } -Reason 'resource_admission_refused'
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnMaterializeFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
foreach ($Case in @('normal', 'lfs-cached', 'existing', 'untrusted', 'unsafe-tree', 'failure-retained', 'monitor-failure', 'oversize-lfs', 'aggregate-lfs', 'cache-root-required', 'capacity')) {
	$CaseRoot = Join-Path $FixtureRoot $Case
	$Source = Join-Path $CaseRoot 'source'
	$Target = Join-Path $CaseRoot 'target'
	$Evidence = Join-Path $CaseRoot 'evidence'
	$null = New-Item -ItemType Directory -Path (Join-Path $Source 'Source')
	$null = New-Item -ItemType Directory -Path $Evidence
	$Descriptor = if ($Case -ceq 'failure-retained') { '{"AdditionalRootDirectories":["../external"]}' } else { '{}' }
	[IO.File]::WriteAllText((Join-Path $Source 'AethelnOnline.uproject'), $Descriptor, (New-Object Text.UTF8Encoding($false)))
	[IO.File]::WriteAllText((Join-Path $Source 'Source/input.cpp'), "// fixture`n", (New-Object Text.UTF8Encoding($false)))
	$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('init', '--quiet')
	$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('add', '--', 'AethelnOnline.uproject', 'Source/input.cpp')
	if ($Case -in @('lfs-cached', 'cache-root-required')) {
		# Fixture-only local origin and local storage. Existing cached bytes mean
		# fetch has nothing to transfer; no GitHub or network endpoint is involved.
		$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('remote', 'add', 'origin', $Source)
		$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('config', 'lfs.storage', (Join-Path $Source '.git/lfs'))
		$null = New-Item -ItemType Directory -Path (Join-Path $Source 'Content')
		$Payload = 'fixture cached LFS bytes'
		Initialize-PreparationGitHubTransport
		$Git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
		$Clean = [Aetheln.PreparationGitHubTransport]::Run($Git, ('-C "' + $Source + '" lfs clean -- Content/test.umap'), $Payload, 15000)
		Assert-MaterializeTest -Condition ($Clean.ExitCode -eq 0) -Message 'Fixture LFS cache generation failed'
		[IO.File]::WriteAllText((Join-Path $Source 'Content/test.umap'), $Clean.Output, (New-Object Text.UTF8Encoding($false)))
		[IO.File]::WriteAllText((Join-Path $Source '.gitattributes'), "Content/test.umap filter=lfs diff=lfs merge=lfs -text`n", (New-Object Text.UTF8Encoding($false)))
		$Blob = [string](Invoke-MaterializeFixtureGit -Root $Source -Arguments @('hash-object', '-w', '--no-filters', 'Content/test.umap'))
		$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('update-index', '--add', '--cacheinfo', "100644,$Blob,Content/test.umap")
		$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('add', '--', '.gitattributes')
	}
	if ($Case -in @('oversize-lfs', 'aggregate-lfs')) {
		$null = New-Item -ItemType Directory -Path (Join-Path $Source 'Content')
		$Count = if ($Case -ceq 'oversize-lfs') { 1 } else { 5 }
		$DeclaredSize = if ($Case -ceq 'oversize-lfs') { 2GB + 1 } else { 2GB }
		for ($Index = 0; $Index -lt $Count; $Index++) {
			$PointerPath = 'Content/fixture-' + $Index + '.umap'
			$Pointer = "version https://git-lfs.github.com/spec/v1`noid sha256:$('c' * 64)`nsize $DeclaredSize`n"
			[IO.File]::WriteAllText((Join-Path $Source $PointerPath), $Pointer, (New-Object Text.UTF8Encoding($false)))
			$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('add', '--', $PointerPath)
		}
	}
	if ($Case -ceq 'unsafe-tree') {
		$Blob = [string](Invoke-MaterializeFixtureGit -Root $Source -Arguments @('hash-object', 'Source/input.cpp'))
		$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('update-index', '--add', '--cacheinfo', "100644,$Blob,.lfsconfig")
	}
	$null = Invoke-MaterializeFixtureGit -Root $Source -Arguments @('-c', 'user.name=Preparation Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'fixture')
	$Revision = [string](Invoke-MaterializeFixtureGit -Root $Source -Arguments @('rev-parse', 'HEAD'))
	$Attempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision $Revision -AttemptId ([guid]::NewGuid().ToString('N'))
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $CaseRoot 'owner.lease')
	$Proof = $null
	try {
		$Parameters = @{ SourceRoot = $Source; TargetRoot = $Target; Attempt = $Attempt; Lease = $Lease; OnProgress = {}; AssertSourceTrust = { return $true }; EvidenceRoot = $Evidence; ResourceRoots = @{ fixture = $CaseRoot } }
		if ($Case -ceq 'lfs-cached') { $Parameters.LfsStorageRoot = Join-Path $Source '.git/lfs' }
		if ($Case -ceq 'existing') { $null = New-Item -ItemType Directory -Path $Target }
		if ($Case -ceq 'untrusted') { $Parameters.AssertSourceTrust = { return $false } }
		if ($Case -ceq 'monitor-failure') {
			$CallbackState = @{ afterReservation = 0 }
			$Parameters.OnProgress = {
				if (Test-Path -LiteralPath $Target) {
					$CallbackState.afterReservation++
					if ($CallbackState.afterReservation -ge 2) { throw 'fixture_monitor_stop' }
				}
			}
		}
		if ($Case -ceq 'capacity') {
			Test-MaterializeCapacityRefusal -Parameters $Parameters
			Assert-MaterializeTest -Condition (-not (Test-Path -LiteralPath $Target)) -Message 'Insufficient prewrite capacity created target'
		} elseif ($Case -in @('normal', 'lfs-cached')) {
			$Proof = New-InitialPreparationMaterialization @Parameters
			$ExpectedFiles = if ($Case -ceq 'lfs-cached') { 4 } else { 2 }
			Assert-MaterializeTest -Condition ($Proof.files.Count -eq $ExpectedFiles -and $Proof.digest -cmatch '^[0-9a-f]{64}$') -Message 'Materialized proof missing'
			$Head = [string](Invoke-MaterializeFixtureGit -Root $Target -Arguments @('rev-parse', 'HEAD'))
			$Branch = [string](Invoke-MaterializeFixtureGit -Root $Target -Arguments @('rev-parse', '--abbrev-ref', 'HEAD'))
			Assert-MaterializeTest -Condition ($Head -ceq $Revision -and $Branch -ceq 'HEAD') -Message 'Target is not exact detached revision'
		} else {
			$Reason = @{ existing = 'materialization_target_exists'; untrusted = 'materialization_source_trust_required'; 'unsafe-tree' = 'input_sensitive_or_external_path'; 'failure-retained' = 'input_external_descriptor_root'; 'monitor-failure' = 'resource_evidence_failed'; 'oversize-lfs' = 'materialization_input_limit'; 'aggregate-lfs' = 'materialization_input_limit'; 'cache-root-required' = 'materialization_lfs_storage_required' }[$Case]
			Assert-MaterializeRejected -Action { New-InitialPreparationMaterialization @Parameters } -Reason $Reason
			if ($Case -in @('untrusted', 'unsafe-tree', 'oversize-lfs', 'aggregate-lfs', 'cache-root-required')) { Assert-MaterializeTest -Condition (-not (Test-Path -LiteralPath $Target)) -Message 'Preflight failure mutated target' }
			if ($Case -ceq 'failure-retained') { Assert-MaterializeTest -Condition (Test-Path -LiteralPath (Join-Path $Target 'AethelnOnline.uproject')) -Message 'Failed target evidence was removed' }
			if ($Case -ceq 'monitor-failure') {
				$Held = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })[0]
				foreach ($Job in $Held.supervisedJobs) { Assert-MaterializeTest -Condition ($Job.ActiveCount -eq 0) -Message 'Monitor failure left owned processes' }
				Assert-MaterializeTest -Condition (Test-Path -LiteralPath $Target) -Message 'Monitor failure removed owned reservation'
			}
		}
	} finally {
		if ($null -ne $Proof) { Close-InitialPreparationInputProof -Proof $Proof }
		$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		Exit-InitialPreparationLease -Lease $Lease
	}
}
Write-Output "PASS: materialization fixtures; retained $FixtureRoot"
