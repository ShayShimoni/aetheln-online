Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Work.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Admitted work integration is missing' }
. $Module
function Assert-WorkCondition {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Test-AdmittedWork {
	function New-InitialPreparationProgressContext {
		[CmdletBinding(SupportsShouldProcess)]
		param($Attempt, $Roots, $EvidenceRoot, $KnownAllocations)
		if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Reserve fixture resource evidence')) { throw 'fixture_declined' }
		Assert-WorkCondition -Condition ($Attempt.attemptId -ceq 'fixture' -and $Roots.fixture -ceq $Root -and $EvidenceRoot -ceq $Root -and $KnownAllocations.fixture -eq 1GB) -Message 'Resource context inputs lost'
		[void] $State.events.Add('resource_new')
		return [pscustomobject]@{ fixture = $true; closed = $false }
	}
	function Invoke-InitialPreparationProgress {
		param($Context)
		Assert-WorkCondition -Condition ($Context.fixture -and -not $Context.closed) -Message 'Invalid or closed resource context used'
		$State.resources++
		if ($State.mode -ceq 'resource_failure') { throw 'resource_pressure' }
	}
	function Close-InitialPreparationProgress {
		param($Context)
		Assert-WorkCondition -Condition (-not $Context.closed) -Message 'Resource context closed twice'
		$Context.closed = $true
		[void] $State.events.Add('resource_close')
	}
	function Assert-InitialPreparationInputLease {
		param($Attempt, $Lease)
		Assert-WorkCondition -Condition ($Attempt.attemptId -ceq 'fixture' -and $Lease.leaseId -ceq 'lease') -Message 'Lease identity lost'
		if ($State.mode -ceq 'lease_failure') { throw 'input_lease_invalid' }
	}
	function Start-InitialPreparationMonitor {
		[CmdletBinding(SupportsShouldProcess)]
		param($Attempt, $Lease, $Runner, $SeedObservation, $YamlAssemblyPath, $EvidenceRoot)
		if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Start fixture monitor')) { throw 'fixture_declined' }
		Assert-WorkCondition -Condition ($Attempt.attemptId -ceq 'fixture' -and $Lease.leaseId -ceq 'lease' -and $Runner.id -eq 21 -and $SeedObservation.seed -ceq 'admitted' -and $YamlAssemblyPath -ceq 'fixture.dll' -and (Test-Path -LiteralPath $EvidenceRoot)) -Message 'Monitor seed or arguments lost'
		[void] $State.events.Add('monitor')
		if ($State.mode -ceq 'monitor_start_failure') { throw 'monitor_start_failed' }
		return [pscustomobject]@{ fixture = $true }
	}
	function Get-InitialPreparationMonitorState {
		param($Monitor)
		Assert-WorkCondition -Condition $Monitor.fixture -Message 'Wrong monitor'
		if ($State.mode -ceq 'monitor_failure') { throw 'monitor_observation_stale' }
	}
	function New-InitialPreparationMaterialization {
		[CmdletBinding(SupportsShouldProcess)]
		param($SourceRoot, $TargetRoot, $Attempt, $Lease, $OnProgress, $AssertSourceTrust, $EvidenceRoot, $ResourceRoots, $LfsStorageRoot)
		if (-not $PSCmdlet.ShouldProcess($TargetRoot, 'Prepare fixture target')) { throw 'fixture_declined' }
		Assert-WorkCondition -Condition ($SourceRoot -ceq 'source' -and $TargetRoot -ceq 'target' -and $Attempt.attemptId -ceq 'fixture' -and $Lease.leaseId -ceq 'lease' -and $ResourceRoots.Count -eq 1 -and $LfsStorageRoot -ceq 'cache' -and (Test-Path -LiteralPath $EvidenceRoot) -and (& $AssertSourceTrust $SourceRoot 'fixture-repository' 'fixture-revision' $LfsStorageRoot)) -Message 'Materialization arguments lost'
		& $OnProgress
		[void] $State.events.Add('materialize')
		if ($State.mode -ceq 'materialization_failure') { throw 'materialization_native_failed' }
		return [pscustomobject]@{ digest = ('a' * 64); closed = $false }
	}
	function Assert-InitialPreparationInputProof {
		param($Proof, $OnProgress)
		& $OnProgress
		if ($Proof.closed) { throw 'Proof closed early' }
		if ($State.mode -ceq 'input_failure') { throw 'input_revision_mismatch' }
		return $Proof.digest
	}
	function Close-InitialPreparationInputProof { param($Proof) $Proof.closed = $true; [void] $State.events.Add('close'); if ($State.mode -ceq 'input_close_failure') { throw 'input_close_failed' } }
	function Get-InitialPreparationHostProof {
		param($Attempt, $Lease, $EngineRoot, $LinuxToolchainRoot, $CompilerPath, $ResourceCompilerPath, $OnProgress)
		Assert-WorkCondition -Condition ($Attempt.attemptId -ceq 'fixture' -and $Lease.leaseId -ceq 'lease' -and $EngineRoot -ceq 'engine' -and $LinuxToolchainRoot -ceq 'toolchain' -and $CompilerPath -ceq 'compiler' -and $ResourceCompilerPath -ceq 'resourcecompiler') -Message 'Host proof arguments lost'
		& $OnProgress
		[void] $State.events.Add('host_new')
		if ($State.mode -ceq 'host_create_failure') { throw 'host_required_input_missing' }
		if ($State.mode -ceq 'wrapped_host_failure') { throw [InvalidOperationException]::new('Synthetic wrapper with private-looking fixture details', [InvalidOperationException]::new('host_required_input_missing')) }
		if ($State.mode -ceq 'raw_host_failure') { throw 'Synthetic wrapper with private-looking fixture details' }
		if ($State.mode -ceq 'unknown_lowercase_failure') { throw 'synthetic_lowercase_unknown_token' }
		if ($State.mode -ceq 'failure_record_collision') {
			$Collision = [IO.File]::Open((Join-Path $Root 'work-failure.json'), [IO.FileMode]::CreateNew)
			try { $Collision.WriteByte(123) } finally { $Collision.Dispose() }
			throw 'host_required_input_missing'
		}
		$HostRecords = @([pscustomobject]@{ path = 'local-host-file'; sha256 = ('e' * 64); bytes = 1 })
		if ($State.mode -ceq 'host_evidence_limit') { $HostRecords[0].path = 'x' * 8388608 }
		return [pscustomobject]@{ fixture = $true; digest = ('b' * 64); invocationSha256 = ('c' * 64); closed = $false; records = $HostRecords; dotnetPath = 'dotnet'; requiredWindowsArguments = @('flag') }
	}
	function Assert-InitialPreparationHostReadiness {
		param($Proof, $ExpectedInvocationSha256, $OnProgress)
		Assert-WorkCondition -Condition ($Proof.fixture -and -not $Proof.closed -and $ExpectedInvocationSha256 -ceq ('c' * 64)) -Message 'Host proof closed early or reviewed hash lost'
		& $OnProgress
		$State.hostChecks++
		if ($State.mode -ceq 'host_readiness_throw') { throw 'host_invocation_identity_mismatch' }
		return ($State.mode -cne 'host_failure')
	}
	function Close-InitialPreparationHostProof {
		param($Proof)
		Assert-WorkCondition -Condition ($Proof.fixture -and -not $Proof.closed) -Message 'Host proof closed twice'
		$Proof.closed = $true
		[void] $State.events.Add('host_close')
		Write-Output 'cleanup output must not enter work result'
		if ($State.mode -ceq 'host_close_failure') { throw 'host_close_failed' }
	}
	function Invoke-InitialPreparationBuildSequence {
		param($Attempt, $Lease, $EngineRoot, $TargetRoot, $LinuxToolchainRoot, $EvidenceRoot, $InputDigest, $Roots, $ValidateInputs, $AssertReadiness, $OnSample, $KnownAllocations)
		Assert-WorkCondition -Condition ($Attempt.attemptId -ceq 'fixture' -and $Lease.leaseId -ceq 'lease' -and $EngineRoot -ceq 'engine' -and $TargetRoot -ceq 'target' -and $LinuxToolchainRoot -ceq 'toolchain' -and (Test-Path -LiteralPath $EvidenceRoot) -and $InputDigest -ceq ('a' * 64) -and $Roots.Count -eq 1 -and $KnownAllocations.fixture -eq 1GB) -Message 'Build arguments lost'
		$HostEvidencePath = Join-Path (Split-Path -Parent $EvidenceRoot) 'host-inputs.json'
		Assert-WorkCondition -Condition (Test-Path -LiteralPath $HostEvidencePath) -Message 'Host evidence not persisted before build'
		$WriteDenied = $false
		try { $Writer = [IO.File]::Open($HostEvidencePath, [IO.FileMode]::Open, [IO.FileAccess]::Write); $Writer.Dispose() } catch [IO.IOException] { $WriteDenied = $true }
		Assert-WorkCondition -Condition $WriteDenied -Message 'Host evidence not retained during builds'
		for ($Index = 0; $Index -lt 6; $Index++) {
			Assert-WorkCondition -Condition ((& $ValidateInputs) -ceq $InputDigest) -Message 'Input proof not wired'
			$Ready = & $AssertReadiness
			if ($Ready -isnot [bool] -or -not $Ready) { throw 'build_readiness_unproven' }
			& $OnSample ([pscustomobject]@{ fixture = $true })
		}
		[void] $State.events.Add('build')
		if ($State.mode -ceq 'build_failure') { throw 'build_failed' }
		return ,@(1..6)
	}
	foreach ($Mode in @('success', 'no_caller_progress', 'resource_failure', 'monitor_start_failure', 'monitor_failure', 'host_failure', 'host_create_failure', 'wrapped_host_failure', 'raw_host_failure', 'unknown_lowercase_failure', 'failure_record_collision', 'host_readiness_throw', 'host_close_failure', 'host_evidence_limit', 'build_failure', 'materialization_failure', 'input_failure', 'input_close_failure', 'lease_failure', 'not_admitted', 'array_admission', 'missing_observation', 'existing_evidence', 'existing_host_evidence', 'existing_failure_evidence')) {
		$State = @{ mode = $Mode; events = (New-Object Collections.ArrayList); progress = 0; resources = 0; hostChecks = 0 }
		$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnWork-' + [guid]::NewGuid().ToString('N'))
		$null = New-Item -ItemType Directory -Path $Root
		$Context = [pscustomobject]@{ attempt = [pscustomobject]@{ attemptId = 'fixture'; targetRevision = ('d' * 40) }; lease = [pscustomobject]@{ leaseId = 'lease' }; runner = [pscustomobject]@{ id = 21 }; admission = [pscustomobject]@{ admitted = $true; observation = [pscustomobject]@{ seed = 'admitted' } } }
		if ($Mode -ceq 'not_admitted') { $Context.admission.admitted = $false }
		if ($Mode -ceq 'array_admission') { $Context.admission.admitted = @($true) }
		if ($Mode -ceq 'missing_observation') { $Context.admission.observation = $null }
		if ($Mode -ceq 'existing_evidence') { $null = New-Item -ItemType Directory -Path (Join-Path $Root 'builds') }
		if ($Mode -ceq 'existing_host_evidence') { $Stream = [IO.File]::Open((Join-Path $Root 'host-inputs.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write); $Stream.WriteByte(123); $Stream.Dispose() }
		if ($Mode -ceq 'existing_failure_evidence') { $Stream = [IO.File]::Open((Join-Path $Root 'work-failure.json'), [IO.FileMode]::CreateNew); $Stream.WriteByte(123); $Stream.Dispose() }
		$Result = $null; $Failure = $null
		$Optional = @{}
		if ($Mode -cne 'no_caller_progress') { $Optional.OnProgress = { $State.progress++; Write-Output 'informational output must not enter result' } }
		try {
			$Result = Invoke-InitialPreparationAdmittedWork -Context $Context -SourceRoot source -TargetRoot target -EngineRoot engine -LinuxToolchainRoot toolchain -CompilerPath compiler -ResourceCompilerPath resourcecompiler -ExpectedInvocationSha256 ('c' * 64) -LfsStorageRoot cache -YamlAssemblyPath fixture.dll -EvidenceRoot $Root -Roots @{ fixture = $Root } -KnownAllocations @{ fixture = 1GB } -AssertSourceTrust {
				param($TrustRoot, $TrustRepository, $TrustRevision, $TrustCache, $TrustProgress)
				Assert-WorkCondition -Condition ($TrustRoot -ceq 'source' -and $TrustRepository -ceq 'fixture-repository' -and $TrustRevision -ceq 'fixture-revision' -and $TrustCache -ceq 'cache' -and $TrustProgress -is [scriptblock]) -Message 'Admitted source trust lost scope or progress'
				& $TrustProgress
				return $true
			} @Optional
		} catch { $Failure = $_.Exception.Message }
		if ($Mode -in @('success', 'no_caller_progress')) {
			Assert-WorkCondition -Condition (-not (Test-Path -LiteralPath (Join-Path $Root 'work-failure.json'))) -Message 'Successful work emitted failure evidence'
			Assert-WorkCondition -Condition ($null -eq $Failure -and $Result.nativeExitCode -eq 0 -and $Result.builds.Count -eq 6 -and -not $Result.baselineVerified -and -not $Result.cleanupVerified -and $Result.inputDigest -ceq ('a' * 64)) -Message ('Successful work contract invalid: ' + $Failure)
			Assert-WorkCondition -Condition ($Result.hostInputDigest -ceq ('b' * 64) -and $Result.invocationSha256 -ceq ('c' * 64) -and $State.hostChecks -eq 6) -Message 'Host evidence or repeated readiness lost'
			$HostEvidence = Get-Content -LiteralPath (Join-Path $Root 'host-inputs.json') -Raw | ConvertFrom-Json
			Assert-WorkCondition -Condition ($HostEvidence.schemaVersion -eq 1 -and $HostEvidence.targetRevision -ceq ('d' * 40) -and $HostEvidence.digest -ceq $Result.hostInputDigest -and $HostEvidence.invocationSha256 -ceq ('c' * 64) -and $HostEvidence.files.Count -eq 1 -and $HostEvidence.files[0].sha256 -ceq ('e' * 64) -and -not $HostEvidence.baselineVerified -and -not $HostEvidence.consumptionVerified) -Message 'Durable host evidence invalid or overclaimed'
			Assert-WorkCondition -Condition (($State.events -join ',') -ceq 'resource_new,monitor,materialize,host_new,build,close,host_close,resource_close' -and $State.resources -gt 0) -Message 'Work order or required resource progress lost'
			if ($Mode -ceq 'success') { Assert-WorkCondition -Condition ($State.progress -gt 0 -and $State.resources -eq ($State.progress + 1)) -Message 'Progress callbacks missing or doubled' }
		} else {
			$Expected = @{ resource_failure = 'resource_pressure'; monitor_start_failure = 'monitor_start_failed'; monitor_failure = 'monitor_observation_stale'; host_failure = 'build_readiness_unproven'; host_create_failure = 'host_required_input_missing'; host_readiness_throw = 'host_invocation_identity_mismatch'; host_close_failure = 'host_close_failed'; host_evidence_limit = 'work_host_evidence_limit'; build_failure = 'build_failed'; materialization_failure = 'materialization_native_failed'; input_failure = 'input_revision_mismatch'; input_close_failure = 'input_close_failed'; lease_failure = 'input_lease_invalid'; not_admitted = 'work_not_admitted'; array_admission = 'work_not_admitted'; missing_observation = 'work_not_admitted'; existing_evidence = 'work_evidence_exists'; existing_host_evidence = 'work_evidence_exists' }[$Mode]
			if ($Mode -in @('wrapped_host_failure', 'raw_host_failure')) { $Expected = 'Synthetic wrapper with private-looking fixture details' }
			if ($Mode -ceq 'unknown_lowercase_failure') { $Expected = 'synthetic_lowercase_unknown_token' }
			if ($Mode -ceq 'failure_record_collision') { $Expected = 'host_required_input_missing' }
			if ($Mode -ceq 'existing_failure_evidence') { $Expected = 'work_evidence_exists' }
			Assert-WorkCondition -Condition ($Failure -ceq $Expected) -Message ('Unexpected work failure: ' + $Failure)
			$FailurePhase = @{ resource_failure = 'resource_setup'; monitor_start_failure = 'monitor'; monitor_failure = 'monitor'; materialization_failure = 'materialization'; host_create_failure = 'host_identity'; wrapped_host_failure = 'host_identity'; raw_host_failure = 'host_identity'; host_evidence_limit = 'host_evidence'; build_failure = 'builds'; input_failure = 'builds'; host_failure = 'builds'; host_readiness_throw = 'builds' }[$Mode]
			if ($Mode -ceq 'unknown_lowercase_failure') { $FailurePhase = 'host_identity' }
			if ($null -ne $FailurePhase) {
				$FailurePath = Join-Path $Root 'work-failure.json'
				Assert-WorkCondition -Condition (Test-Path -LiteralPath $FailurePath -PathType Leaf) -Message 'Work failure evidence missing'
				$FailureText = Get-Content -LiteralPath $FailurePath -Raw
				$FailureRecord = $FailureText | ConvertFrom-Json
				$ExpectedCode = if ($Mode -ceq 'wrapped_host_failure') { 'host_required_input_missing' } elseif ($Mode -in @('raw_host_failure', 'unknown_lowercase_failure')) { 'work_exception' } else { $Expected }
				Assert-WorkCondition -Condition ($FailureRecord.schemaVersion -eq 1 -and $FailureRecord.attemptId -ceq 'fixture' -and $FailureRecord.targetRevision -ceq ('d' * 40) -and $FailureRecord.phase -ceq $FailurePhase -and $FailureRecord.failureCode -ceq $ExpectedCode -and @($FailureRecord.PSObject.Properties).Count -eq 5 -and (Get-Item -LiteralPath $FailurePath).Length -le 4096) -Message 'Bounded safe work failure identity lost'
				Assert-WorkCondition -Condition (-not $FailureText.Contains('Synthetic wrapper') -and -not $FailureText.Contains('private-looking') -and -not $FailureText.Contains('synthetic_lowercase_unknown_token')) -Message 'Raw diagnostic leaked into work evidence'
			}
			if ($Mode -in @('wrapped_host_failure', 'raw_host_failure', 'unknown_lowercase_failure', 'failure_record_collision')) {
				Assert-WorkCondition -Condition (($State.events -join ',') -like '*,close,resource_close' -and $null -eq $Result) -Message 'Failure evidence masked original failure or skipped cleanup'
			}
			if ($Mode -in @('failure_record_collision', 'existing_failure_evidence')) { Assert-WorkCondition -Condition ([IO.File]::ReadAllBytes((Join-Path $Root 'work-failure.json')).Length -eq 1 -and [IO.File]::ReadAllBytes((Join-Path $Root 'work-failure.json'))[0] -eq 123) -Message 'Existing failure record overwritten' }
			if ($Mode -in @('host_failure', 'host_create_failure', 'host_readiness_throw', 'host_close_failure', 'build_failure', 'input_failure', 'input_close_failure')) { Assert-WorkCondition -Condition ($State.events -contains 'close') -Message 'Failed work leaked input handles' }
			if ($Mode -in @('host_failure', 'host_readiness_throw', 'host_close_failure', 'build_failure', 'input_failure', 'input_close_failure')) { Assert-WorkCondition -Condition ($State.events[$State.events.Count - 2] -ceq 'host_close') -Message 'Failed work leaked host handles' }
			if ($Mode -in @('resource_failure', 'monitor_start_failure', 'monitor_failure', 'host_failure', 'host_create_failure', 'host_readiness_throw', 'host_close_failure', 'build_failure', 'materialization_failure', 'input_failure', 'input_close_failure')) { Assert-WorkCondition -Condition ($State.events[$State.events.Count - 1] -ceq 'resource_close') -Message 'Failed work leaked resource handles' }
			if ($Mode -in @('host_failure', 'host_create_failure', 'host_readiness_throw')) { Assert-WorkCondition -Condition ($State.events -notcontains 'build') -Message 'Host failure allowed builds' }
			if ($Mode -ceq 'resource_failure') { Assert-WorkCondition -Condition (($State.events -join ',') -ceq 'resource_new,resource_close') -Message 'Initial resource failure started work' }
			if ($Mode -ceq 'host_evidence_limit') { Assert-WorkCondition -Condition ($State.events -notcontains 'build' -and ($State.events -join ',') -like '*,close,host_close,resource_close') -Message 'Oversized evidence allowed work or leaked handles' }
			if ($Mode -in @('lease_failure', 'not_admitted', 'array_admission', 'missing_observation', 'existing_evidence', 'existing_host_evidence', 'existing_failure_evidence')) {
				$ExpectedDirectories = if ($Mode -in @('existing_evidence', 'existing_host_evidence', 'existing_failure_evidence')) { 1 } else { 0 }
				Assert-WorkCondition -Condition ($State.events.Count -eq 0 -and @(Get-ChildItem -LiteralPath $Root).Count -eq $ExpectedDirectories) -Message 'Rejected work performed side effects'
				if ($Mode -ceq 'existing_host_evidence') { Assert-WorkCondition -Condition ([IO.File]::ReadAllBytes((Join-Path $Root 'host-inputs.json'))[0] -eq 123) -Message 'Existing host evidence overwritten' }
			}
		}
	}
}
Test-AdmittedWork
Write-Output 'PASS: admitted preparation work wiring fixtures'
