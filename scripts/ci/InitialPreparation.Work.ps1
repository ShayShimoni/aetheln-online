# Admitted work composition only. Maintenance owns process cleanup, lease
# release and routing restoration; this module cannot certify a baseline.
foreach ($Library in @('Core', 'GitHub', 'Input', 'Materialize', 'Monitor', 'Build', 'Progress', 'Host')) {
	. (Join-Path $PSScriptRoot ('InitialPreparation.' + $Library + '.ps1'))
}

function Invoke-InitialPreparationAdmittedWork {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Context,
		[Parameter(Mandatory)][string] $SourceRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $LinuxToolchainRoot,
		[Parameter(Mandatory)][string] $CompilerPath, [Parameter(Mandatory)][string] $ResourceCompilerPath,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedInvocationSha256,
		[string] $LfsStorageRoot,
		[Parameter(Mandatory)][string] $YamlAssemblyPath, [Parameter(Mandatory)][string] $EvidenceRoot,
		[Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)][scriptblock] $AssertSourceTrust,
		[scriptblock] $OnProgress = {},
		[hashtable] $KnownAllocations = @{})
	# Admission and the live caller-owned lease are prerequisites for every write.
	if ($null -eq $Context.admission -or $Context.admission.admitted -isnot [bool] -or
		-not $Context.admission.admitted -or $null -eq $Context.admission.observation) { throw 'work_not_admitted' }
	Assert-InitialPreparationInputLease -Attempt $Context.attempt -Lease $Context.lease
	Assert-InitialPreparationPlainPath -Path $EvidenceRoot -Reason 'work_evidence_invalid'
	if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'work_evidence_invalid' }
	$Directories = @{}
	foreach ($Name in @('monitor', 'materialization', 'builds')) {
		$Directories[$Name] = Join-Path $EvidenceRoot $Name
		if (Test-Path -LiteralPath $Directories[$Name]) { throw 'work_evidence_exists' }
	}
	$HostEvidencePath = Join-Path $EvidenceRoot 'host-inputs.json'
	if (Test-Path -LiteralPath $HostEvidencePath) { throw 'work_evidence_exists' }
	$WorkFailurePath = Join-Path $EvidenceRoot 'work-failure.json'
	if (Test-Path -LiteralPath $WorkFailurePath) { throw 'work_evidence_exists' }
	$Proof = $null; $HostProof = $null; $HostEvidenceStream = $null; $ProgressContext = $null
	$WorkPhase = 'resource_setup'
	try {
		$ProgressContext = New-InitialPreparationProgressContext -Attempt $Context.attempt -Roots $Roots -EvidenceRoot $EvidenceRoot -KnownAllocations $KnownAllocations
		Invoke-InitialPreparationProgress -Context $ProgressContext
		foreach ($Name in @('monitor', 'materialization', 'builds')) {
			$null = New-Item -ItemType Directory -Path $Directories[$Name] -ErrorAction Stop
		}
		$WorkPhase = 'monitor'
		$Monitor = Start-InitialPreparationMonitor -Attempt $Context.attempt -Lease $Context.lease -Runner $Context.runner -SeedObservation $Context.admission.observation -YamlAssemblyPath $YamlAssemblyPath -EvidenceRoot $Directories.monitor
		# Resource enforcement is mandatory and owned here, not delegated to an
		# optional informational callback. One context gates expensive measurement
		# across all synchronous Git/hash stages while preserving pressure history.
		$CallerWorkProgress = $OnProgress
		$WorkProgress = {
			Invoke-InitialPreparationProgress -Context $ProgressContext
			$null = Get-InitialPreparationMonitorState -Monitor $Monitor
			& $CallerWorkProgress | Out-Null
		}
		& $WorkProgress
		$ReviewedSourceCallback = $AssertSourceTrust
		$AdmittedSourceTrust = {
			param($TrustRoot, $TrustRepository, $TrustRevision, $TrustCache)
			& $ReviewedSourceCallback $TrustRoot $TrustRepository $TrustRevision $TrustCache $WorkProgress
		}
		$WorkPhase = 'materialization'
		$Proof = New-InitialPreparationMaterialization -SourceRoot $SourceRoot -TargetRoot $TargetRoot -Attempt $Context.attempt -Lease $Context.lease -OnProgress $WorkProgress -AssertSourceTrust $AdmittedSourceTrust -EvidenceRoot $Directories.materialization -ResourceRoots $Roots -LfsStorageRoot $LfsStorageRoot
		$WorkPhase = 'host_identity'
		$HostProof = Get-InitialPreparationHostProof -Attempt $Context.attempt -Lease $Context.lease -EngineRoot $EngineRoot -LinuxToolchainRoot $LinuxToolchainRoot -CompilerPath $CompilerPath -ResourceCompilerPath $ResourceCompilerPath -OnProgress $WorkProgress
		# Local-only raw identities survive handle closure. Publication should bind
		# this artifact by digest, not expose absolute host paths. Retain the new
		# stream against writes/replacement until all admitted work has finished.
		$WorkPhase = 'host_evidence'
		$HostRecord = [ordered]@{ schemaVersion = 1; scope = 'compile_host_file_identity';
			attemptId = $Context.attempt.attemptId; targetRevision = $Context.attempt.targetRevision;
			engineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'; digest = $HostProof.digest;
			invocationSha256 = $HostProof.invocationSha256; files = @($HostProof.records);
			engineRoot = $EngineRoot; linuxToolchainRoot = $LinuxToolchainRoot;
			compilerPath = $CompilerPath; resourceCompilerPath = $ResourceCompilerPath; dotnetPath = $HostProof.dotnetPath;
			requiredWindowsArguments = @($HostProof.requiredWindowsArguments); baselineVerified = $false; consumptionVerified = $false }
		$HostBytes = [Text.Encoding]::UTF8.GetBytes(($HostRecord | ConvertTo-Json -Depth 5))
		if ($HostBytes.Length -gt 8388608) { throw 'work_host_evidence_limit' }
		& $WorkProgress
		$HostEvidenceStream = [IO.File]::Open($HostEvidencePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		$HostEvidenceStream.Write($HostBytes, 0, $HostBytes.Length); $HostEvidenceStream.Flush($true)
		$ValidateInputs = { Assert-InitialPreparationInputProof -Proof $Proof -OnProgress $WorkProgress }
		# Retain the real host proof across all six builds; caller callbacks cannot
		# substitute a true literal for pinned inputs and reviewed invocation bytes.
		$ReviewedInvocationHash = $ExpectedInvocationSha256
		$HostReadiness = { Assert-InitialPreparationHostReadiness -Proof $HostProof -ExpectedInvocationSha256 $ReviewedInvocationHash -OnProgress $WorkProgress }
		$BuildSample = { & $WorkProgress }
		$WorkPhase = 'builds'
		$Builds = Invoke-InitialPreparationBuildSequence -Attempt $Context.attempt -Lease $Context.lease -EngineRoot $EngineRoot -TargetRoot $TargetRoot -LinuxToolchainRoot $LinuxToolchainRoot -EvidenceRoot $Directories.builds -InputDigest $Proof.digest -Roots $Roots -ValidateInputs $ValidateInputs -AssertReadiness $HostReadiness -OnSample $BuildSample -KnownAllocations $KnownAllocations
		& $WorkProgress
		return [pscustomobject]@{ nativeExitCode = 0; builds = $Builds; inputDigest = $Proof.digest;
			hostInputDigest = $HostProof.digest; invocationSha256 = $HostProof.invocationSha256;
			baselineVerified = $false; cleanupVerified = $false }
	} catch {
		$OriginalWorkFailure = $_
		try {
			# A regex-shaped message is not proof that text is safe. Only these
			# known controller codes may enter evidence; unknown text stays private.
			$AllowedFailureCodes = @(
				'resource_pressure', 'resource_measurement_unavailable', 'disk_recovery_floor_reached',
				'resource_evidence_failed', 'resource_evidence_limit', 'resource_allocation_invalid', 'resource_root_invalid',
				'monotonic_clock_unavailable', 'useful_work_deadline',
				'monitor_start_failed', 'monitor_observation_stale', 'monitor_observation_invalid', 'monitor_worker_exited',
				'monitor_snapshot_invalid', 'monitor_snapshot_unreadable',
				'materialization_native_failed', 'materialization_monitor_failed', 'materialization_input_limit',
				'materialization_source_trust_required', 'materialization_revision_mismatch', 'materialization_lfs_storage_required',
				'input_content_mismatch', 'input_revision_mismatch', 'input_git_failed', 'input_inventory_changed',
				'input_lfs_unhydrated', 'input_file_unavailable', 'input_path_invalid', 'input_sensitive_or_external_path',
				'host_engine_identity_invalid', 'host_input_inventory_changed', 'host_input_path_invalid', 'host_input_size_limit',
				'host_inventory_limit', 'host_invocation_identity_mismatch', 'host_linux_version_invalid', 'host_proof_closed',
				'host_required_input_missing', 'host_tool_path_invalid', 'work_host_evidence_limit',
				'build_readiness_unproven', 'build_failed', 'build_ubt_readiness_unproven', 'build_input_drift',
				'build_monitor_failed', 'build_result_missing', 'build_result_invalid'
			)
			$SafeCode = 'work_exception'
			$FailureException = $OriginalWorkFailure.Exception
			for ($Depth = 0; $Depth -lt 8 -and $null -ne $FailureException; $Depth++) {
				if ($FailureException.Message.Length -le 80 -and $FailureException.Message -cmatch '\A[a-z_]{1,80}\z' -and $AllowedFailureCodes -ccontains $FailureException.Message) { $SafeCode = $FailureException.Message; break }
				$FailureException = $FailureException.InnerException
			}
			$FailureRecord = [ordered]@{ schemaVersion = 1; attemptId = $Context.attempt.attemptId;
				targetRevision = $Context.attempt.targetRevision; phase = $WorkPhase; failureCode = $SafeCode }
			$FailureBytes = [Text.Encoding]::UTF8.GetBytes(($FailureRecord | ConvertTo-Json -Compress))
			if ($FailureBytes.Length -gt 4096) { throw 'work_failure_evidence_limit' }
			$FailureStream = [IO.File]::Open($WorkFailurePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
			try { $FailureStream.Write($FailureBytes, 0, $FailureBytes.Length); $FailureStream.Flush($true) } finally { $FailureStream.Dispose() }
		} catch {
			# An unavailable/colliding evidence destination cannot overwrite earlier
			# evidence, erase the original failure, or bypass the cleanup below.
			throw $OriginalWorkFailure
		}
		throw $OriginalWorkFailure
	} finally {
		try {
			if ($null -ne $Proof) { $null = Close-InitialPreparationInputProof -Proof $Proof }
		} finally {
			try {
				if ($null -ne $HostProof) { $null = Close-InitialPreparationHostProof -Proof $HostProof }
			} finally {
				try {
					if ($null -ne $HostEvidenceStream) { $HostEvidenceStream.Dispose() }
				} finally {
					if ($null -ne $ProgressContext) { $null = Close-InitialPreparationProgress -Context $ProgressContext }
				}
			}
		}
	}
}
