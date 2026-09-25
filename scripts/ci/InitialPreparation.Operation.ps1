[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $AttemptPath,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[Parameter(Mandatory)][string] $RequestPath,
	[string] $ControllerManifestSha256,
	[string] $BuildInvocationSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot 'InitialPreparation.GitHub.ps1')
$Phase = 'input'
$ExitCode = 1
$Record = [ordered]@{ schemaVersion = 1; scope = 'read_only_preparation_preflight'; complete = $false;
	baselineVerified = $false; executionReady = $false; failurePhase = $null; failureCode = $null; observations = [ordered]@{} }
try {
	foreach ($InputPath in @($AttemptPath, $RequestPath)) {
		Assert-InitialPreparationPlainPath -Path $InputPath -Reason 'operation_input_invalid'
		if ((Get-Item -LiteralPath $InputPath).Length -gt 65536) { throw 'operation_input_limit' }
	}
	$Attempt = Get-Content -LiteralPath $AttemptPath -Raw | ConvertFrom-Json
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Request = ConvertFrom-InitialPreparationRequest -Json (Get-Content -LiteralPath $RequestPath -Raw) -Attempt $Attempt
	$Record['attempt'] = $Attempt
	$Record['controllerManifestSha256'] = $ControllerManifestSha256
	$Record['buildInvocationSha256'] = $BuildInvocationSha256
	# Bootstrap retains a ReadWrite handle that denies subsequent writers. The
	# reader must share the existing write access; this does not grant new writes.
	$RequestStream = [IO.File]::Open($RequestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $Record['requestSha256'] = ([BitConverter]::ToString($Hasher.ComputeHash($RequestStream))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose(); $RequestStream.Dispose() }
	# Execute is a separate, explicitly authorized lifecycle. The supported
	# launcher retains the reviewed complete controller and request byte proofs.
	if ($Request.mode -ceq 'execute') {
		if ($ControllerManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $BuildInvocationSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'execution_controller_identity_missing' }
		. (Join-Path $PSScriptRoot 'InitialPreparation.Execution.ps1')
		$Phase = 'execution'
		$Record.scope = 'bounded_preparation_execution'
		$ExecutionResult = Invoke-InitialPreparationExecution -Attempt $Attempt -Request $Request -EvidenceRoot $EvidenceRoot -RequestSha256 $Record.requestSha256 -ControllerManifestSha256 $ControllerManifestSha256 -BuildInvocationSha256 $BuildInvocationSha256
		$Record.observations['execution'] = $ExecutionResult
		$Record.complete = $true
		$Record.executionReady = $true
		$Record.baselineVerified = $ExecutionResult.baselineVerified
		$ExitCode = $ExecutionResult.nativeExitCode
		exit $ExitCode
	}
	$ControllerRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
	$Phase = 'root_separation'
	foreach ($Root in @($Request.engineRoot, $Request.targetRoot)) {
		if ((Test-InitialPreparationWithin -Candidate $Root -Parent $ControllerRoot) -or
			(Test-InitialPreparationWithin -Candidate $ControllerRoot -Parent $Root)) { throw 'operation_roots_overlap' }
	}
	if ((Test-InitialPreparationWithin -Candidate $Request.targetRoot -Parent $Request.engineRoot) -or
		(Test-InitialPreparationWithin -Candidate $Request.engineRoot -Parent $Request.targetRoot)) { throw 'operation_roots_overlap' }
	$Phase = 'target_identity'
	$Target = Get-InitialPreparationCheckoutIdentity -Root $Request.targetRoot -ExpectedRevision $Request.targetRevision
	$Record.observations['target'] = $Target
	if (-not $Target.clean) { throw 'target_source_dirty' }
	$Phase = 'engine_identity'
	$Engine = Get-InitialPreparationCheckoutIdentity -Root $Request.engineRoot -ExpectedRevision $Request.engineRevision
	$Record.observations['engine'] = $Engine
	if (-not $Engine.clean) { throw 'engine_source_dirty' }
	$Phase = 'resources'
	$Roots = @{ engine = $Request.engineRoot; target = $Request.targetRoot; evidence = $EvidenceRoot;
		temp = [IO.Path]::GetTempPath(); toolchain = $Request.linuxToolchainRoot }
	$Capacity = Get-InitialPreparationCapacity -Roots $Roots -Attempt $Attempt
	$Record.observations['capacity'] = $Capacity
	$Record.observations['actionLimit'] = Get-InitialPreparationActionLimit -Capacity $Capacity
	$Phase = 'local_work'
	$Record.observations['localWork'] = Get-InitialPreparationLocalWork -EngineRoot $Request.engineRoot
	$Phase = 'runner'
	$Runner = Get-InitialPreparationRunner -Repository $Request.repository -RunnerId $Request.runnerId -ExpectedName $Request.runnerName
	$Record.observations['runner'] = $Runner
	$Phase = 'admission_inventory'
	$Cache = @{}
	$Record.observations['admissionInventory'] = Get-InitialPreparationAdmissionInventory -Runner $Runner -YamlAssemblyPath $Request.yamlAssemblyPath -Cache $Cache
	$Record.observations['sourceProofs'] = $Cache.entries
	$Record['remainingExecutionGates'] = @('independent_controller_verification', 'exact_runner_outage_authorization', 'real_preparation_experiment')
	$Record.complete = $true
	$ExitCode = 0
} catch {
	$Record.failurePhase = $Phase
	$Record.failureCode = if ($_.Exception.Message -cmatch '^[a-z_]{1,80}$') { $_.Exception.Message } else { 'preflight_failed' }
}
finally {
	$Record['finishedUtc'] = [DateTime]::UtcNow.ToString('o')
	$OutputPath = Join-Path $EvidenceRoot 'preflight.json'
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 16))
	if ($Bytes.Length -gt 1048576) { throw 'preflight_evidence_limit' }
	$OutputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	try { $OutputStream.Write($Bytes, 0, $Bytes.Length); $OutputStream.Flush($true) }
	finally { $OutputStream.Dispose() }
}
exit $ExitCode
