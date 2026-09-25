# Production lifecycle composition. The launcher supplies frozen reviewed code
# and request identities; caller authorization precedes the execute request.
foreach ($Library in @('Core', 'GitHub', 'Work', 'Recovery', 'Source', 'ToolSelection')) {
	. (Join-Path $PSScriptRoot ('InitialPreparation.' + $Library + '.ps1'))
}

function Assert-InitialPreparationExecutionRoot {
	[CmdletBinding()]
	[OutputType([hashtable])]
	param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)][string] $EvidenceRoot)
	$ControllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
	foreach ($Root in @($Request.sourceRoot, $Request.engineRoot, $Request.targetRoot, $EvidenceRoot)) {
		Assert-InitialPreparationPlainPath -Path $Root -Reason 'execution_root_invalid'
		if ((Test-InitialPreparationWithin -Candidate $Root -Parent $ControllerRoot) -or
			(Test-InitialPreparationWithin -Candidate $ControllerRoot -Parent $Root)) { throw 'execution_roots_overlap' }
	}
	$Disjoint = @($Request.sourceRoot, $Request.engineRoot, $Request.targetRoot, $EvidenceRoot)
	for ($Index = 0; $Index -lt $Disjoint.Count; $Index++) {
		for ($Other = $Index + 1; $Other -lt $Disjoint.Count; $Other++) {
			if ((Test-InitialPreparationWithin -Candidate $Disjoint[$Index] -Parent $Disjoint[$Other]) -or
				(Test-InitialPreparationWithin -Candidate $Disjoint[$Other] -Parent $Disjoint[$Index])) { throw 'execution_roots_overlap' }
		}
	}
	if (Test-Path -LiteralPath $Request.targetRoot) { throw 'materialization_target_exists' }
	$Roots = @{ source = $Request.sourceRoot; engine = $Request.engineRoot; target = (Split-Path -Parent $Request.targetRoot);
		evidence = $EvidenceRoot; cache = $Request.lfsStorageRoot; toolchain = $Request.linuxToolchainRoot;
		compiler = (Split-Path -Parent $Request.compilerPath); resourceCompiler = (Split-Path -Parent $Request.resourceCompilerPath); temp = [IO.Path]::GetTempPath() }
	foreach ($Root in $Roots.Values) {
		Assert-InitialPreparationPlainPath -Path $Root -Reason 'execution_root_invalid'
		if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'execution_root_invalid' }
	}
	return $Roots
}

function Write-InitialPreparationExecutionFreeze {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $EvidenceRoot)
	$Artifacts = @()
	$Limits = [ordered]@{ 'work/host-inputs.json' = 8388608L; 'work/builds/sequence-result.json' = 32768L; 'work/synchronous-resources.jsonl' = 16777216L; 'work/work-failure.json' = 4096L }
	foreach ($Relative in $Limits.Keys) {
		$Path = Join-Path $EvidenceRoot $Relative
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
		$Pins = @(); $Stream = $null; $Hasher = $null
		try {
			$Pins = Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $Path)
			$Stream = [IO.FileStream]::new([Aetheln.PreparationDirectory]::OpenSource($Path), [IO.FileAccess]::Read)
			if ($Stream.Length -gt $Limits[$Relative]) { throw 'execution_evidence_limit' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			$Buffer = New-Object byte[] 65536
			while (($Count = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
				if ((Get-InitialPreparationTick) -ge $Context.attempt.cleanupDeadlineTicks) { throw 'execution_freeze_deadline' }
				[void] $Hasher.TransformBlock($Buffer, 0, $Count, $Buffer, 0)
			}
			[void] $Hasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
			$Artifacts += [pscustomobject]@{ name = $Relative; sha256 = ([BitConverter]::ToString($Hasher.Hash)).Replace('-', '').ToLowerInvariant(); bytes = $Stream.Length }
		} finally {
			if ($null -ne $Hasher) { $Hasher.Dispose() }
			if ($null -ne $Stream) { $Stream.Dispose() }
			foreach ($Pin in $Pins) { $Pin.Dispose() }
		}
	}
	$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ schemaVersion = 1; attemptId = $Context.attempt.attemptId; artifacts = $Artifacts } | ConvertTo-Json -Depth 5))
	if ($Bytes.Length -gt 8192) { throw 'execution_evidence_limit' }
	$Stream = [IO.File]::Open((Join-Path $EvidenceRoot 'frozen-artifacts.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
	return ,$Artifacts
}

function Invoke-InitialPreparationExecution {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Request,
		[Parameter(Mandatory)][string] $EvidenceRoot,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $RequestSha256,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ControllerManifestSha256,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $BuildInvocationSha256)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if ($Request.mode -isnot [string] -or $Request.mode -cne 'execute' -or $Request.repository -cne $Attempt.repository -or
		$Request.targetRevision -cne $Attempt.targetRevision -or $Request.authorizationReference -isnot [string] -or
		[string]::IsNullOrWhiteSpace($Request.authorizationReference)) { throw 'execution_request_invalid' }
	$ExecutionRoots = Assert-InitialPreparationExecutionRoot -Request $Request -EvidenceRoot $EvidenceRoot
	$ExecutionRequest = $Request; $ExecutionAttempt = $Attempt; $ExecutionEvidence = $EvidenceRoot
	$ExecutionRequestHash = $RequestSha256; $ExecutionInvocationHash = $BuildInvocationSha256
	$ExecutionCache = @{}; $ExecutionFrozen = @{ artifacts = @() }
	$ExecutionProgress = { if ((Get-InitialPreparationTick) -ge $ExecutionAttempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' } }
	$SourceBinding = {
		param($SourceRoot, $Repository, $TargetRevision, $LfsStorageRoot, [scriptblock] $AdmittedProgress)
		$SourceProgress = if ($null -eq $AdmittedProgress) { $ExecutionProgress } else { $AdmittedProgress }
		Test-InitialPreparationSourceBinding -ReviewedRequest $ExecutionRequest -SourceRoot $SourceRoot -Repository $Repository -TargetRevision $TargetRevision -LfsStorageRoot $LfsStorageRoot -Attempt $ExecutionAttempt -OnProgress $SourceProgress
	}
	$Trusted = & $SourceBinding $Request.sourceRoot $Request.repository $Request.targetRevision $Request.lfsStorageRoot
	if ($Trusted -isnot [bool] -or -not $Trusted) { throw 'execution_source_unproven' }
	$ExecutionRunner = Get-InitialPreparationRunner -Repository $Request.repository -RunnerId $Request.runnerId -ExpectedName $Request.runnerName
	$Inventory = { Get-InitialPreparationAdmissionInventory -Runner $ExecutionRunner -YamlAssemblyPath $ExecutionRequest.yamlAssemblyPath -Cache $ExecutionCache }
	$LocalWork = { Get-InitialPreparationLocalWork -EngineRoot $ExecutionRequest.engineRoot }
	$Intent = {
		param($IntentAttempt, $IntentRunner)
		Write-InitialPreparationRecoveryIntent -Path (Join-Path $ExecutionEvidence 'quarantine-intent.json') -Attempt $IntentAttempt -Runner $IntentRunner -RequestSha256 $ExecutionRequestHash
	}
	$AdmittedWork = {
		param($WorkContext)
		$WorkRoot = Join-Path $ExecutionEvidence 'work'
		$null = New-Item -ItemType Directory -Path $WorkRoot -ErrorAction Stop
		Invoke-InitialPreparationAdmittedWork -Context $WorkContext -SourceRoot $ExecutionRequest.sourceRoot -TargetRoot $ExecutionRequest.targetRoot -EngineRoot $ExecutionRequest.engineRoot -LinuxToolchainRoot $ExecutionRequest.linuxToolchainRoot -LfsStorageRoot $ExecutionRequest.lfsStorageRoot -CompilerPath $ExecutionRequest.compilerPath -ResourceCompilerPath $ExecutionRequest.resourceCompilerPath -ExpectedInvocationSha256 $ExecutionInvocationHash -YamlAssemblyPath $ExecutionRequest.yamlAssemblyPath -EvidenceRoot $WorkRoot -Roots $ExecutionRoots -AssertSourceTrust $SourceBinding
	}
	$Freeze = { param($FreezeContext) $ExecutionFrozen.artifacts = Write-InitialPreparationExecutionFreeze -Context $FreezeContext -EvidenceRoot $ExecutionEvidence }
	if (-not $PSCmdlet.ShouldProcess($Request.repository, 'Run explicitly authorized preparation maintenance and builds')) { throw 'execution_declined' }
	$Maintenance = Invoke-InitialPreparationMaintenance -Attempt $Attempt -Runner $ExecutionRunner -LeasePath $Request.leasePath -InventoryProbe $Inventory -LocalWorkerProbe $LocalWork -Work $AdmittedWork -FreezeEvidence $Freeze -PersistQuarantineIntent $Intent
	$Verified = $false; $Failure = 'maintenance_incomplete'; $Builds = @(); $InputDigest = $null
	if ($null -ne $Maintenance.workResult) { $Builds = @($Maintenance.workResult.builds); $InputDigest = $Maintenance.workResult.inputDigest }
	if ($Maintenance.cycleCompleted -is [bool] -and $Maintenance.cycleCompleted) {
		try {
			$Selection = Get-InitialPreparationToolSelection -Attempt $Attempt -Builds $Builds -EvidenceRoot (Join-Path $EvidenceRoot 'work') -CompilerPath $Request.compilerPath -ResourceCompilerPath $Request.resourceCompilerPath -InputDigest $InputDigest
			if ($Selection.verified -isnot [bool] -or -not $Selection.verified) { throw 'tool_selection_unproven' }
			$SelectionBytes = [Text.Encoding]::UTF8.GetBytes(($Selection | ConvertTo-Json -Depth 8))
			if ($SelectionBytes.Length -gt 65536) { throw 'tool_selection_evidence_limit' }
			$SelectionStream = [IO.File]::Open((Join-Path $EvidenceRoot 'tool-selection.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
			try { $SelectionStream.Write($SelectionBytes, 0, $SelectionBytes.Length); $SelectionStream.Flush($true) } finally { $SelectionStream.Dispose() }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $SelectionHash = ([BitConverter]::ToString($Hasher.ComputeHash($SelectionBytes))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
			$ExecutionFrozen.artifacts += [pscustomobject]@{ name = 'tool-selection.json'; sha256 = $SelectionHash; bytes = [long] $SelectionBytes.Length }
			$Verified = $true; $Failure = $null
		} catch { $Failure = 'tool_selection_unproven' }
	}
	$Terminal = [pscustomobject]@{ attempt = $Attempt; outcome = $(if ($Verified) { 'warm_baseline_verified' } elseif (-not $Maintenance.admitted) { 'maintenance_not_admitted' } else { 'failed' });
		builds = $Builds; inputDigest = $InputDigest; cleanup = $Maintenance.cleanup;
		resource = [pscustomobject]@{ evidence = 'work/synchronous-resources.jsonl' };
		maintenance = [pscustomobject]@{ cycleCompleted = $Maintenance.cycleCompleted; admitted = $Maintenance.admitted; leaseReleased = $Maintenance.leaseReleased; routingRestored = $Maintenance.routingRestored; errors = @($Maintenance.errors) };
		nativeExitCode = $(if ($Verified) { 0 } else { 1 }); infrastructureFailure = $Failure;
		requestSha256 = $RequestSha256; controllerManifestSha256 = $ControllerManifestSha256 }
	if ($null -eq $Terminal.cleanup) { $Terminal.cleanup = [pscustomobject]@{ cleanupVerified = $false; remainingOwnedProcesses = @() } }
	$Receipt = Write-InitialPreparationReceipt -State $Terminal -Artifacts $ExecutionFrozen.artifacts -Path (Join-Path $EvidenceRoot 'preparation-receipt.json')
	return [pscustomobject]@{ nativeExitCode = $Terminal.nativeExitCode; baselineVerified = $Verified; failureCode = $Failure; maintenance = $Terminal.maintenance; receipt = $Receipt }
}
