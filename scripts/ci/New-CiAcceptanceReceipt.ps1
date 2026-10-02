[CmdletBinding()]
param(
	[string] $InputPath,
	[string] $EvidenceRoot,
	[string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AcceptanceReceiptSchema = 'aetheln.ci-acceptance-receipt/v1'
$script:AttemptAnchorSchema = 'aetheln.current-attempt-anchor/v1'
$script:AcceptanceInputLimit = 64KB
$script:AcceptanceReceiptLimit = 64KB
$script:AcceptanceEvidenceFileLimit = 4MB
$script:AcceptanceEvidenceAggregateLimit = 16MB
$script:AcceptanceResultLimit = 32
$script:AcceptanceEvidenceLimit = 63
$script:AcceptanceEvidencePerResultLimit = 16
$script:AcceptanceUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:AcceptanceUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:AcceptanceCheckIds = @(
	'clean-package-provenance-smoke',
	'content-reference-validation',
	'controller-contract',
	'controller-operational-proof',
	'native-client-server-compile',
	'portable',
	'unreal-editor-automation',
	'visual-package'
)
# Opaque hashes and caller-declared summaries are not success evidence. Keep an
# obligation unsupported until this producer can parse its exact report schema.
$script:AcceptanceReceiptUnsupportedCheckIds = @(
	'clean-package-provenance-smoke',
	'content-reference-validation'
)
$script:AcceptancePortableCheckNames = @(
	'formatting-policy','markdown-links','source-control-policy','observability-contract','build-packaged-artifacts-tests','host-tool-provisioning-tests',
	'packaged-smoke-test-tests','network-authority-spike-tests','engine-runner-gate-tests','unreal-automation-tests',
	'server-cook-reference-tests','target-composition-tests','build-provenance-tests','markdown-link-tests',
	'formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests',
	'prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests',
	'ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-acceptance-publisher-tests','ci-acceptance-context-tests',
	'ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests',
	'managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests',
	'routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests',
	'psscriptanalyzer'
)
# controller-contract revalidates the exact portable report and also requires every required tests/ci suite to pass.
$script:AcceptanceControllerContractCheckNames = @('engine-runner-gate-tests','unreal-automation-tests','markdown-link-tests','formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests','prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests','ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-acceptance-publisher-tests','ci-acceptance-context-tests','ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests','managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests','routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests')

function Assert-AcceptanceClosedObject {
	param($Value, [string[]] $PropertyNames)
	if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw 'receipt_invalid' }
	$Actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($Actual.Count -ne $PropertyNames.Count) { throw 'receipt_invalid' }
	foreach ($Name in $PropertyNames) { if ($Actual -cnotcontains $Name) { throw 'receipt_invalid' } }
}

function Assert-AcceptanceUniqueJsonProperties {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates every property scope in one JSON document.')]
	param([string] $Raw)
	$Scopes = New-Object System.Collections.Stack
	$PendingName = $null
	$Index = 0
	while ($Index -lt $Raw.Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object System.Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index]); $Index++
					if ($Index -ge $Raw.Length) { throw 'receipt_json_invalid' }
				}
				[void] $Builder.Append($Raw[$Index]); $Index++
			}
			if ($Index -ge $Raw.Length) { throw 'receipt_json_invalid' }
			try { $PendingName = [string] (ConvertFrom-Json -InputObject ('"' + $Builder.ToString() + '"')) } catch { throw 'receipt_json_invalid' }
			$Index++; continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)))
			$PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw 'receipt_json_invalid' }
			[void] $Scopes.Pop(); $PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) { throw 'receipt_json_duplicate_property' }
			$PendingName = $null
		} elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw 'receipt_json_invalid' }
}

function Read-AcceptanceJson {
	param([string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'receipt_input_missing' }
	$Item = Get-Item -LiteralPath $Path
	if ($Item.Length -gt $script:AcceptanceInputLimit) { throw 'receipt_input_limit' }
	if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_input_invalid' }
	try {
		$RawBytes = [IO.File]::ReadAllBytes($Item.FullName)
		if ($RawBytes.Length -gt $script:AcceptanceInputLimit) { throw 'receipt_input_limit' }
		$Raw = $script:AcceptanceUtf8.GetString($RawBytes)
	} catch {
		if ($_.Exception.Message -ceq 'receipt_input_limit') { throw }
		throw 'receipt_json_invalid'
	}
	Assert-AcceptanceUniqueJsonProperties -Raw $Raw
	try { return ConvertFrom-Json -InputObject $Raw } catch { throw 'receipt_json_invalid' }
}

function ConvertFrom-AcceptanceEvidenceJson {
	param([byte[]] $Bytes, [string] $CheckId)
	$Reason = 'receipt_semantic_evidence_invalid:' + $CheckId
	if ($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt $script:AcceptanceEvidenceFileLimit) { throw $Reason }
	try { $Raw = $script:AcceptanceUtf8.GetString($Bytes) }
	catch { throw $Reason }
	try { Assert-AcceptanceUniqueJsonProperties -Raw $Raw }
	catch { throw $Reason }
	try {
		$ConvertCommand = Get-Command -Name ConvertFrom-Json -ErrorAction Stop
		if ($ConvertCommand.Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $Raw -DateKind String }
		return ConvertFrom-Json -InputObject $Raw
	}
	catch { throw $Reason }
}

function Test-AcceptanceBoundedInteger {
	param($Value, [long] $Minimum, [long] $Maximum)
	return ($Value -is [int] -or $Value -is [long]) -and [long] $Value -ge $Minimum -and [long] $Value -le $Maximum
}

function Test-AcceptanceBoundedNumber {
	param($Value, [double]$Minimum, [double]$Maximum)
	if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
	$Number = [double]$Value
	return -not [double]::IsNaN($Number) -and -not [double]::IsInfinity($Number) -and $Number -ge $Minimum -and $Number -le $Maximum
}

function Assert-AcceptanceCompileBuildRecord {
	param($Build, [string]$ExpectedCheck, [string]$ExpectedTarget, [string]$ExpectedPlatform, [string]$CheckId = 'native-client-server-compile')
	$Reason = "receipt_semantic_evidence_invalid:$CheckId"
	Assert-AcceptanceClosedObject $Build @('check','target','platform','configuration','intermediateBuildDirectoryPresentBeforeRun','makefilePresentBeforeRun','outputState','lastObservedAction','observedTotalActions','actionCounterState','plannedActionCount','observedTargetNames','makefileObservation','makefileReason','makefileCreationCount','upToDateObserved','executorSummaryCount')
	if ($Build.check -isnot [string] -or $Build.check -cne $ExpectedCheck -or $Build.target -isnot [string] -or $Build.target -cne $ExpectedTarget -or
		$Build.platform -isnot [string] -or $Build.platform -cne $ExpectedPlatform -or $Build.configuration -isnot [string] -or $Build.configuration -cne 'Development' -or
		$Build.intermediateBuildDirectoryPresentBeforeRun -isnot [bool] -or $Build.makefilePresentBeforeRun -isnot [bool] -or
		$Build.outputState -isnot [string] -or $Build.outputState -cne 'captured' -or $Build.actionCounterState -isnot [string] -or
		$Build.actionCounterState -cnotin @('observed','not_observed') -or $Build.makefileObservation -isnot [string] -or
		$Build.makefileObservation -cnotin @('created','not_observed') -or $Build.upToDateObserved -isnot [bool] -or
		-not (Test-AcceptanceBoundedInteger -Value $Build.makefileCreationCount -Minimum 0 -Maximum 10000000) -or -not (Test-AcceptanceBoundedInteger -Value $Build.executorSummaryCount -Minimum 0 -Maximum 10000000)) { throw $Reason }
	if ($Build.actionCounterState -ceq 'observed') {
		if (-not (Test-AcceptanceBoundedInteger -Value $Build.lastObservedAction -Minimum 1 -Maximum 10000000) -or -not (Test-AcceptanceBoundedInteger -Value $Build.observedTotalActions -Minimum 1 -Maximum 10000000) -or $Build.lastObservedAction -gt $Build.observedTotalActions) { throw $Reason }
	} elseif ($null -ne $Build.lastObservedAction -or $null -ne $Build.observedTotalActions) { throw $Reason }
	if ($null -ne $Build.plannedActionCount -and -not (Test-AcceptanceBoundedInteger -Value $Build.plannedActionCount -Minimum 0 -Maximum 10000000)) { throw $Reason }
	if ($null -ne $Build.observedTargetNames -and ($Build.observedTargetNames -isnot [string] -or $Build.observedTargetNames.Length -gt 512 -or $Build.observedTargetNames -cnotmatch '^(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other)(?:,(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other))*$')) { throw $Reason }
	if ($Build.makefileObservation -ceq 'created') {
		if ($Build.makefileCreationCount -lt 1 -or $Build.makefileReason -isnot [string] -or $Build.makefileReason -cnotmatch '^[a-z0-9_]{1,128}$') { throw $Reason }
	} elseif ($Build.makefileCreationCount -ne 0 -or $null -ne $Build.makefileReason) { throw $Reason }
}

function Assert-AcceptanceManagedCompileProof {
	param($Report, $Identity, [string]$CheckId = 'native-client-server-compile')
	$Reason = "receipt_semantic_evidence_invalid:$CheckId"
	try {
		Assert-AcceptanceClosedObject $Report.managedWorkspace @('schemaVersion','registrationId','registrationSha256','preparationReceiptSha256','revision','synchronized')
		Assert-AcceptanceClosedObject $Report.compileResources @('schemaVersion','sampleIntervalMilliseconds','recoveryFloorBytes','pressureThresholdBytes','sampleCount','measurementCount','maximumSampleGapMilliseconds','consecutivePressureSamples','maximumConsecutivePressureSamples','minimumAvailableRamBytes','minimumCommitHeadroomBytes','physicalCores','targetAdmissionCount','minimumActionLimit','maximumActionLimit','failureReason','volumes')
	} catch { throw $Reason }
	$Workspace = $Report.managedWorkspace
	if (-not (Test-AcceptanceBoundedInteger -Value $Workspace.schemaVersion -Minimum 1 -Maximum 1) -or $Workspace.registrationId -isnot [string] -or $Workspace.registrationId -cnotmatch '^[a-f0-9]{32}$' -or
		-not (Test-AcceptanceDigest $Workspace.registrationSha256) -or -not (Test-AcceptanceDigest $Workspace.preparationReceiptSha256) -or
		$Workspace.revision -isnot [string] -or $Workspace.revision -cne $Identity.source.testedRevision -or $Workspace.synchronized -isnot [bool] -or -not $Workspace.synchronized) { throw $Reason }
	$Resources = $Report.compileResources
	if (-not (Test-AcceptanceBoundedInteger -Value $Resources.schemaVersion -Minimum 1 -Maximum 1) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.sampleIntervalMilliseconds -Minimum 5000 -Maximum 5000) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.recoveryFloorBytes -Minimum 20GB -Maximum 20GB) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.pressureThresholdBytes -Minimum 2GB -Maximum 2GB) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.sampleCount -Minimum 1 -Maximum 10000000) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.measurementCount -Minimum 1 -Maximum 10000000) -or $Resources.measurementCount -lt $Resources.sampleCount -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.maximumSampleGapMilliseconds -Minimum 0 -Maximum 3600000) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.consecutivePressureSamples -Minimum 0 -Maximum 2) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.maximumConsecutivePressureSamples -Minimum 0 -Maximum 2) -or
		$Resources.consecutivePressureSamples -gt $Resources.maximumConsecutivePressureSamples -or -not (Test-AcceptanceBoundedInteger -Value $Resources.minimumAvailableRamBytes -Minimum 0 -Maximum ([long]::MaxValue)) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.minimumCommitHeadroomBytes -Minimum 0 -Maximum ([long]::MaxValue)) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.physicalCores -Minimum 1 -Maximum ([int]::MaxValue)) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.targetAdmissionCount -Minimum 2 -Maximum 2) -or -not (Test-AcceptanceBoundedInteger -Value $Resources.minimumActionLimit -Minimum 1 -Maximum 4) -or
		-not (Test-AcceptanceBoundedInteger -Value $Resources.maximumActionLimit -Minimum 1 -Maximum 4) -or $Resources.minimumActionLimit -gt $Resources.maximumActionLimit -or
		$null -ne $Resources.failureReason -or $Resources.volumes -isnot [array] -or @($Resources.volumes).Count -lt 1 -or @($Resources.volumes).Count -gt 7) { throw $Reason }
	$VolumeIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Volume in $Resources.volumes) {
		try { Assert-AcceptanceClosedObject $Volume @('volumeId','knownAllocationBytes','minimumAvailableBytes') } catch { throw $Reason }
		if ($Volume.volumeId -isnot [string] -or $Volume.volumeId -cnotmatch '^[^\x00-\x1f]{1,256}$' -or -not $VolumeIds.Add($Volume.volumeId) -or
			-not (Test-AcceptanceBoundedInteger -Value $Volume.knownAllocationBytes -Minimum 0 -Maximum ([long]::MaxValue - 20GB)) -or
			-not (Test-AcceptanceBoundedInteger -Value $Volume.minimumAvailableBytes -Minimum 0 -Maximum ([long]::MaxValue)) -or
			[decimal] $Volume.minimumAvailableBytes -le ([decimal] $Volume.knownAllocationBytes + 20GB)) { throw $Reason }
	}
}

function Test-AcceptanceCanonicalValidatorPath {
	param($Value, [string] $Expected)
	if ($Value -isnot [string] -or $Value.Length -gt 4096) { return $false }
	$Normalized = $Value.Replace('\', '/')
	if ($Normalized.StartsWith('./', [StringComparison]::Ordinal)) { $Normalized = $Normalized.Substring(2) }
	return $Normalized -ceq $Expected
}

function Test-AcceptanceTimestampRange {
	param($StartedValue, $FinishedValue)
	if ($StartedValue -isnot [string] -or $FinishedValue -isnot [string]) { return $false }
	[datetime] $Started = [datetime]::MinValue
	[datetime] $Finished = [datetime]::MinValue
	$Style = [Globalization.DateTimeStyles]::RoundtripKind
	return [datetime]::TryParseExact($StartedValue, 'o', [Globalization.CultureInfo]::InvariantCulture, $Style, [ref]$Started) -and
		[datetime]::TryParseExact($FinishedValue, 'o', [Globalization.CultureInfo]::InvariantCulture, $Style, [ref]$Finished) -and $Finished -ge $Started
}

function Assert-AcceptancePortableEvidence {
	param([byte[]] $Bytes, $Identity, [string] $CheckId = 'portable')
	$Report = ConvertFrom-AcceptanceEvidenceJson -Bytes $Bytes -CheckId $CheckId
	try {
		Assert-AcceptanceClosedObject -Value $Report -PropertyNames @('schemaVersion','revision','startedUtc','finishedUtc','checks','summary')
		Assert-AcceptanceClosedObject -Value $Report.summary -PropertyNames @('total','passed','failed','skipped','requiredFailed')
	} catch { throw "receipt_semantic_evidence_invalid:$CheckId" }
	if (-not (Test-AcceptanceBoundedInteger -Value $Report.schemaVersion -Minimum 1 -Maximum 1) -or $Report.revision -cne $Identity.source.testedRevision -or
		-not (Test-AcceptanceTimestampRange $Report.startedUtc $Report.finishedUtc) -or $Report.checks -isnot [array] -or
		@($Report.checks).Count -ne $script:AcceptancePortableCheckNames.Count) { throw "receipt_semantic_evidence_invalid:$CheckId" }
	$Passed = 0; $Skipped = 0
	for ($Index = 0; $Index -lt $script:AcceptancePortableCheckNames.Count; $Index++) {
		$Check = $Report.checks[$Index]
		try { Assert-AcceptanceClosedObject -Value $Check -PropertyNames @('name','tier','status','durationSeconds','command','message') }
		catch { throw "receipt_semantic_evidence_invalid:$CheckId" }
		$ExpectedName = $script:AcceptancePortableCheckNames[$Index]
		$ExpectedTier = if ($ExpectedName -ceq 'psscriptanalyzer') { 'advisory' } else { 'required' }
		if ($Check.name -isnot [string] -or $Check.name -cne $ExpectedName -or $Check.tier -isnot [string] -or $Check.tier -cne $ExpectedTier -or
			$Check.status -isnot [string] -or -not (Test-AcceptanceBoundedNumber -Value $Check.durationSeconds -Minimum 0 -Maximum 86400) -or
			$Check.command -isnot [string] -or $Check.command.Length -gt 32768 -or $Check.message -isnot [string] -or $Check.message.Length -gt 131072) {
			throw "receipt_semantic_evidence_invalid:$CheckId"
		}
		if ($Check.status -cnotin @('passed','skipped') -or (($ExpectedTier -ceq 'required' -or $ExpectedName -ceq 'psscriptanalyzer') -and $Check.status -cne 'passed')) {
			throw "receipt_semantic_evidence_failure:$CheckId"
		}
		if ($Check.status -ceq 'passed') { $Passed++ } else { $Skipped++ }
	}
	if (-not (Test-AcceptanceBoundedInteger -Value $Report.summary.total -Minimum 0 -Maximum 1024) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.passed -Minimum 0 -Maximum 1024) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.failed -Minimum 0 -Maximum 1024) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.skipped -Minimum 0 -Maximum 1024) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.requiredFailed -Minimum 0 -Maximum 1024)) { throw "receipt_semantic_evidence_invalid:$CheckId" }
	if ($Report.summary.total -ne $Report.checks.Count -or $Report.summary.passed -ne $Passed -or $Report.summary.failed -ne 0 -or
		$Report.summary.skipped -ne $Skipped -or $Report.summary.requiredFailed -ne 0) { throw "receipt_semantic_evidence_failure:$CheckId" }
	if ($CheckId -ceq 'controller-contract') {
		foreach ($Name in $script:AcceptanceControllerContractCheckNames) {
			$Matched = @($Report.checks | Where-Object { $_.name -ceq $Name -and $_.tier -ceq 'required' })
			if ($Matched.Count -ne 1) { throw 'receipt_semantic_evidence_invalid:controller-contract' }
			if ($Matched[0].status -cne 'passed') { throw 'receipt_semantic_evidence_failure:controller-contract' }
		}
	}
}

function Assert-AcceptanceEngineRunnerEvidence {
	# controller-operational-proof and native-client-server-compile are the same exact compile report; only the reported check id differs.
	param([byte[]] $Bytes, $Identity, [string] $CheckId = 'native-client-server-compile')
	$Reason = "receipt_semantic_evidence_invalid:$CheckId"
	$Failure = "receipt_semantic_evidence_failure:$CheckId"
	$Report = ConvertFrom-AcceptanceEvidenceJson -Bytes $Bytes -CheckId $CheckId
	$RequiredProperties = @('schemaVersion','mode','policy','revision','runnerName','startedUtc','finishedUtc','checks','summary','compileEvidence','managedWorkspace','compileResources','supervisor')
	foreach ($Name in $RequiredProperties) { if ($Report -isnot [pscustomobject] -or $Report.PSObject.Properties.Name -cnotcontains $Name) { throw $Reason } }
	if (@($Report.PSObject.Properties.Name | Where-Object { $RequiredProperties -cnotcontains $_ }).Count -ne 0) { throw $Reason }
	try {
		Assert-AcceptanceClosedObject $Report.summary @('total','passed','failed','skipped','requiredFailed')
		Assert-AcceptanceClosedObject $Report.supervisor @('childExitCode','timedOut','cleanupVerified')
	} catch { throw $Reason }
	if (-not (Test-AcceptanceBoundedInteger -Value $Report.schemaVersion -Minimum 1 -Maximum 1) -or $Report.mode -isnot [string] -or $Report.mode -cne 'Compile' -or
		$Report.policy -isnot [string] -or $Report.policy -cne 'incremental-target-compilation' -or $Report.revision -isnot [string] -or
		$Report.revision -cne $Identity.source.testedRevision -or $Report.runnerName -isnot [string] -or [string]::IsNullOrWhiteSpace($Report.runnerName) -or $Report.runnerName.Length -gt 128 -or
		-not (Test-AcceptanceTimestampRange $Report.startedUtc $Report.finishedUtc) -or $Report.checks -isnot [array] -or @($Report.checks).Count -lt 8 -or @($Report.checks).Count -gt 32 -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.supervisor.childExitCode -Minimum 0 -Maximum 0) -or $Report.supervisor.timedOut -isnot [bool] -or $Report.supervisor.timedOut -or
		$Report.supervisor.cleanupVerified -isnot [bool] -or -not $Report.supervisor.cleanupVerified) {
		throw $Reason
	}
	$Names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Check in $Report.checks) {
		try { Assert-AcceptanceClosedObject $Check @('name','tier','status','durationSeconds','command','message') } catch { throw $Reason }
		if ($Check.name -isnot [string] -or $Check.name.Length -lt 1 -or $Check.name.Length -gt 128 -or -not $Names.Add($Check.name) -or
			$Check.tier -isnot [string] -or $Check.status -isnot [string] -or -not (Test-AcceptanceBoundedNumber -Value $Check.durationSeconds -Minimum 0 -Maximum 86400) -or
			$Check.command -isnot [string] -or $Check.command.Length -gt 32768 -or $Check.message -isnot [string] -or $Check.message.Length -gt 131072) {
			throw $Reason
		}
		if ($Check.tier -cne 'required' -or $Check.status -cne 'passed') { throw $Failure }
	}
	foreach ($Expected in @('runner-input-validation','managed-compile-workspace','repository-state-before-work','incremental-client-build','incremental-client-build-repository-state','incremental-server-build','incremental-server-build-repository-state','repository-state-at-completion')) {
		if (-not $Names.Contains($Expected)) { throw $Failure }
	}
	if (-not (Test-AcceptanceBoundedInteger -Value $Report.summary.total -Minimum 0 -Maximum 32) -or $Report.summary.total -ne $Report.checks.Count -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.passed -Minimum 0 -Maximum 32) -or $Report.summary.passed -ne $Report.checks.Count -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.failed -Minimum 0 -Maximum 0) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.skipped -Minimum 0 -Maximum 0) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.requiredFailed -Minimum 0 -Maximum 0)) { throw $Reason }
	Assert-AcceptanceManagedCompileProof -Report $Report -Identity $Identity -CheckId $CheckId
	if ($Report.compileEvidence -isnot [pscustomobject] -or -not (Test-AcceptanceBoundedInteger -Value $Report.compileEvidence.schemaVersion -Minimum 1 -Maximum 1) -or $Report.compileEvidence.builds -isnot [array] -or @($Report.compileEvidence.builds).Count -ne 2) { throw $Reason }
	try {
		Assert-AcceptanceClosedObject $Report.compileEvidence @('schemaVersion','identity','builds')
		Assert-AcceptanceClosedObject $Report.compileEvidence.identity @('engineGitRevision','engineGitRevisionStatus','engineBuildVersionSha256','engineBuildVersionSha256Status','linuxToolchainCompilerSha256','linuxToolchainCompilerSha256Status','runnerName','durationSeconds')
	} catch { throw $Reason }
	$CompileIdentity = $Report.compileEvidence.identity
	if ($CompileIdentity.engineGitRevision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43' -or $CompileIdentity.engineGitRevisionStatus -cne 'verified' -or
		-not (Test-AcceptanceDigest $CompileIdentity.engineBuildVersionSha256) -or $CompileIdentity.engineBuildVersionSha256Status -cne 'verified' -or
		-not (Test-AcceptanceDigest $CompileIdentity.linuxToolchainCompilerSha256) -or $CompileIdentity.linuxToolchainCompilerSha256Status -cne 'verified' -or
		$CompileIdentity.runnerName -isnot [string] -or $CompileIdentity.runnerName -cne $Report.runnerName -or -not (Test-AcceptanceBoundedNumber -Value $CompileIdentity.durationSeconds -Minimum 0 -Maximum 3600)) {
		throw $Reason
	}
	$ExpectedBuilds = @(@('incremental-client-build','AethelnOnlineClient','Win64'),@('incremental-server-build','AethelnOnlineServer','Linux'))
	for ($Index = 0; $Index -lt 2; $Index++) {
		$Build = $Report.compileEvidence.builds[$Index]; $Expected = $ExpectedBuilds[$Index]
		try { Assert-AcceptanceCompileBuildRecord -Build $Build -ExpectedCheck $Expected[0] -ExpectedTarget $Expected[1] -ExpectedPlatform $Expected[2] -CheckId $CheckId }
		catch { throw $Reason }
	}
}

function Assert-AcceptanceUnrealAutomationEvidence {
	param([byte[]] $Bytes, $Identity)
	$Report = ConvertFrom-AcceptanceEvidenceJson -Bytes $Bytes -CheckId 'unreal-editor-automation'
	try {
		Assert-AcceptanceClosedObject $Report @('schemaId','schemaVersion','mode','sourceRevision','engineRevision','projectName','filter','timeoutSeconds','startedUtc','finishedUtc','processExitCode','repositoryCleanBefore','repositoryCleanAfter','outputs','tests','summary','result','failureReason')
		Assert-AcceptanceClosedObject $Report.outputs @('unrealReport','log')
		Assert-AcceptanceClosedObject $Report.summary @('total','passed','passedWithWarnings','failed','notRun','missing','requiredFailed')
	} catch { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
	if ($Report.schemaId -isnot [string] -or $Report.schemaId -cne 'aetheln.unreal-automation' -or -not (Test-AcceptanceBoundedInteger -Value $Report.schemaVersion -Minimum 1 -Maximum 1) -or
		$Report.mode -isnot [string] -or $Report.mode -cne 'production' -or $Report.sourceRevision -isnot [string] -or $Report.sourceRevision -cne $Identity.source.testedRevision -or
		$Report.engineRevision -isnot [string] -or $Report.engineRevision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43' -or
		$Report.projectName -isnot [string] -or $Report.projectName -cne 'AethelnOnline' -or $Report.filter -isnot [string] -or $Report.filter -cne '^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$' -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.timeoutSeconds -Minimum 1 -Maximum 86400) -or -not (Test-AcceptanceTimestampRange $Report.startedUtc $Report.finishedUtc) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.processExitCode -Minimum 0 -Maximum 0) -or $Report.repositoryCleanBefore -isnot [bool] -or -not $Report.repositoryCleanBefore -or
		$Report.repositoryCleanAfter -isnot [bool] -or -not $Report.repositoryCleanAfter -or $Report.outputs.unrealReport -isnot [string] -or
		$Report.outputs.unrealReport -cne 'TestResults/UnrealAutomation/index.json' -or $Report.outputs.log -isnot [string] -or $Report.outputs.log -cne 'Saved/Logs/AethelnUnrealAutomation.log' -or
		$Report.result -isnot [string] -or $Report.result -cne 'passed' -or $Report.failureReason -isnot [string] -or $Report.failureReason -cne 'none' -or
		$Report.tests -isnot [array] -or @($Report.tests).Count -ne 2) { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
	$ExpectedTests = @('Aetheln.GameCombat.NetworkSpike.Authority','Aetheln.Harness.ProjectAndModuleLoad')
	for ($Index = 0; $Index -lt 2; $Index++) {
		$Test = $Report.tests[$Index]
		try { Assert-AcceptanceClosedObject $Test @('fullTestPath','state','status','durationSeconds','warningCount','errorCount') } catch { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
		if ($Test.fullTestPath -isnot [string] -or $Test.fullTestPath -cne $ExpectedTests[$Index] -or $Test.state -isnot [string] -or $Test.state -cne 'Success' -or
			$Test.status -isnot [string] -or $Test.status -cne 'passed' -or -not (Test-AcceptanceBoundedNumber -Value $Test.durationSeconds -Minimum 0 -Maximum 86400) -or
			-not (Test-AcceptanceBoundedInteger -Value $Test.warningCount -Minimum 0 -Maximum 0) -or -not (Test-AcceptanceBoundedInteger -Value $Test.errorCount -Minimum 0 -Maximum 0)) { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
	}
	if (-not (Test-AcceptanceBoundedInteger -Value $Report.summary.total -Minimum 2 -Maximum 2) -or $Report.summary.total -ne $Report.tests.Count -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.passed -Minimum 2 -Maximum 2) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.passedWithWarnings -Minimum 0 -Maximum 0) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.failed -Minimum 0 -Maximum 0) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.notRun -Minimum 0 -Maximum 0) -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.summary.missing -Minimum 0 -Maximum 0) -or -not (Test-AcceptanceBoundedInteger -Value $Report.summary.requiredFailed -Minimum 0 -Maximum 0)) {
		throw 'receipt_semantic_evidence_invalid:unreal-editor-automation'
	}
}

function Assert-AcceptanceVisualPackageEvidence {
	param([byte[]] $Bytes, $Identity)
	$Report = ConvertFrom-AcceptanceEvidenceJson -Bytes $Bytes -CheckId 'visual-package'
	try {
		Assert-AcceptanceClosedObject -Value $Report -PropertyNames @('schemaVersion','repository','revision','run','results','conclusion')
		Assert-AcceptanceClosedObject -Value $Report.run -PropertyNames @('id','attempt')
	} catch { throw 'receipt_semantic_evidence_invalid:visual-package' }
	if ($Report.schemaVersion -cne 'aetheln.visual-package-report/v1' -or
		$Report.repository -cne $Identity.repository.fullName -or
		$Report.revision -cne $Identity.source.testedRevision -or
		$Report.run.id -cne $Identity.run.id -or
		-not (Test-AcceptanceBoundedInteger -Value $Report.run.attempt -Minimum 1 -Maximum ([int]::MaxValue)) -or $Report.run.attempt -ne $Identity.run.attempt -or
		$Report.results -isnot [array] -or @($Report.results).Count -ne 2) {
		throw 'receipt_semantic_evidence_invalid:visual-package'
	}

	$ExpectedValidators = @(
		[pscustomobject]@{ id='visual-package'; path='visuals/Test-VisualPackage.ps1' },
		[pscustomobject]@{ id='visual-package-regressions'; path='visuals/tests/Test-VisualPackageValidation.ps1' }
	)
	[long] $TotalCapturedLines = 0
	for ($Index = 0; $Index -lt $ExpectedValidators.Count; $Index++) {
		$Result = $Report.results[$Index]
		try {
			Assert-AcceptanceClosedObject -Value $Result -PropertyNames @('id','path','startedUtc','finishedUtc','nativeExitCode','conclusion','capture','output')
			Assert-AcceptanceClosedObject -Value $Result.capture -PropertyNames @('maxLineUtf8Bytes','maxLines','maxAggregateUtf8Bytes','observedLineCount','capturedLineCount','capturedUtf8Bytes','truncatedLineCount','droppedLineCount')
		} catch { throw 'receipt_semantic_evidence_invalid:visual-package' }
		$Expected = $ExpectedValidators[$Index]
		[datetime] $Started = [datetime]::MinValue
		[datetime] $Finished = [datetime]::MinValue
		$TimestampStyle = [Globalization.DateTimeStyles]::RoundtripKind
		if ($Result.id -cne $Expected.id -or -not (Test-AcceptanceCanonicalValidatorPath -Value $Result.path -Expected $Expected.path) -or
			$Result.startedUtc -isnot [string] -or $Result.finishedUtc -isnot [string] -or
			-not [datetime]::TryParseExact($Result.startedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, $TimestampStyle, [ref] $Started) -or
			-not [datetime]::TryParseExact($Result.finishedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, $TimestampStyle, [ref] $Finished) -or
			$Finished -lt $Started -or -not (Test-AcceptanceBoundedInteger -Value $Result.nativeExitCode -Minimum 0 -Maximum 0) -or
			$Result.conclusion -cne 'success' -or $Result.output -isnot [array]) {
			throw 'receipt_semantic_evidence_failure:visual-package'
		}
		$Capture = $Result.capture
		if (-not (Test-AcceptanceBoundedInteger -Value $Capture.maxLineUtf8Bytes -Minimum 1 -Maximum 16384) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.maxLines -Minimum 1 -Maximum 1000) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.maxAggregateUtf8Bytes -Minimum 1 -Maximum 1048576) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.observedLineCount -Minimum 0 -Maximum ([int]::MaxValue)) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.capturedLineCount -Minimum 0 -Maximum $Capture.maxLines) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.capturedUtf8Bytes -Minimum 0 -Maximum $Capture.maxAggregateUtf8Bytes) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.truncatedLineCount -Minimum 0 -Maximum $Capture.capturedLineCount) -or
			-not (Test-AcceptanceBoundedInteger -Value $Capture.droppedLineCount -Minimum 0 -Maximum $Capture.observedLineCount) -or
			[long] $Capture.observedLineCount -ne ([long] $Capture.capturedLineCount + [long] $Capture.droppedLineCount) -or
			@($Result.output).Count -ne [long] $Capture.capturedLineCount) {
			throw 'receipt_semantic_evidence_invalid:visual-package'
		}
		[long] $CapturedBytes = 0
		foreach ($Line in @($Result.output)) {
			if ($Line -isnot [string]) { throw 'receipt_semantic_evidence_invalid:visual-package' }
			$LineBytes = $script:AcceptanceUtf8NoBom.GetByteCount($Line)
			if ($LineBytes -gt [long] $Capture.maxLineUtf8Bytes) { throw 'receipt_semantic_evidence_invalid:visual-package' }
			$CapturedBytes += $LineBytes
		}
		if ($CapturedBytes -ne [long] $Capture.capturedUtf8Bytes) { throw 'receipt_semantic_evidence_invalid:visual-package' }
		$TotalCapturedLines += [long] $Capture.capturedLineCount
		if ($TotalCapturedLines -gt 1000) { throw 'receipt_semantic_evidence_invalid:visual-package' }
	}
	if ($Report.conclusion -cne 'success') { throw 'receipt_semantic_evidence_failure:visual-package' }
}

function Test-AcceptanceRevision($Value) {
	return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{40}$'
}

function Test-AcceptanceDigest($Value) {
	return $Value -is [string] -and $Value -cmatch '\A[0-9a-f]{64}\z'
}

function Test-AcceptanceDecimalIdentity($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
	[long] $Parsed = 0
	return [long]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $Parsed) -and $Parsed -gt 0
}

function Assert-AcceptanceAttemptAnchor {
	param($Anchor, $Run)
	Assert-AcceptanceClosedObject -Value $Anchor -PropertyNames @('schemaVersion','runId','runAttempt','nonce')
	if ($Anchor.schemaVersion -isnot [string] -or $Anchor.schemaVersion -cne $script:AttemptAnchorSchema -or
		-not (Test-AcceptanceDecimalIdentity $Anchor.runId) -or $Anchor.runAttempt -isnot [int] -or $Anchor.runAttempt -lt 1 -or
		$Anchor.nonce -isnot [string] -or $Anchor.nonce -cnotmatch '\A[0-9a-f]{64}\z' -or $Anchor.nonce -cmatch '\A0{64}\z' -or
		$Anchor.runId -cne $Run.id -or $Anchor.runAttempt -ne $Run.attempt) { throw 'receipt_invalid' }
}

function Get-AcceptanceSha256 {
	param([byte[]] $Bytes)
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
	finally { $Hash.Dispose() }
}

function Assert-AcceptanceOrderedUniqueStringSet {
	param($Value, [string[]] $Allowed = $null)
	if ($Value -isnot [Array] -or $Value.Count -lt 1) { throw 'receipt_invalid' }
	$Previous = $null
	foreach ($Entry in $Value) {
		if ($Entry -isnot [string] -or $Entry.Length -lt 1 -or $Entry.Length -gt 128) { throw 'receipt_invalid' }
		if ($null -ne $Allowed -and $Allowed -cnotcontains $Entry) { throw 'receipt_invalid' }
		if ($null -ne $Previous -and [StringComparer]::Ordinal.Compare($Previous, $Entry) -ge 0) { throw 'receipt_invalid' }
		$Previous = $Entry
	}
}

function Test-AcceptanceEvidenceName {
	param($Value)
	if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 240 -or
		$Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Value.Contains('//') -or
		$Value.Contains('\') -or $Value.Contains(':') -or $Value.StartsWith('/') -or $Value.EndsWith('/')) { return $false }
	foreach ($Segment in $Value.Split('/')) {
		if ($Segment -in @('.', '..') -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ')) { return $false }
	}
	return $true
}

function Get-AcceptanceEvidenceFile {
	param([string] $Root, [string] $Name)
	if (-not (Test-AcceptanceEvidenceName -Value $Name)) { throw 'receipt_invalid' }
	if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'receipt_evidence_root_invalid' }
	$RootItem = Get-Item -LiteralPath $Root
	if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_evidence_root_invalid' }
	$RootFull = [IO.Path]::GetFullPath($RootItem.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	$Current = $RootFull
	foreach ($Segment in $Name.Split('/')) {
		$Current = Join-Path -Path $Current -ChildPath $Segment
		if (Test-Path -LiteralPath $Current) {
			$CurrentItem = Get-Item -LiteralPath $Current
			if (($CurrentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_evidence_path_invalid' }
		}
	}
	$Full = [IO.Path]::GetFullPath($Current)
	if (-not $Full.StartsWith($RootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw 'receipt_evidence_path_invalid' }
	return Get-Item -LiteralPath $Full
}

function New-CiAcceptanceReceipt {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [string] $InputPath,
		[Parameter(Mandatory)] [string] $EvidenceRoot,
		[Parameter(Mandatory)] [string] $OutputPath
	)
	if (Test-Path -LiteralPath $OutputPath) { throw 'receipt_exists' }
	if ((Split-Path -Path $OutputPath -Leaf) -cne 'ci-acceptance-receipt.json') { throw 'receipt_output_name_invalid' }
	$ReceiptInput = Read-AcceptanceJson -Path $InputPath
	Assert-AcceptanceClosedObject -Value $ReceiptInput -PropertyNames @('repository','event','source','workflow','controller','policy','actions','run','attemptAnchor','selection','results')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.repository -PropertyNames @('fullName')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.event -PropertyNames @('kind','classification','actor','triggeringActor')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.source -PropertyNames @('baseRevision','headRevision','testedRevision')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.workflow -PropertyNames @('id','revision','parents','sha256')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.controller -PropertyNames @('revision','blobOid','sha256')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.policy -PropertyNames @('version','digest')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.actions -PropertyNames @('manifestSha256','items')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.run -PropertyNames @('id','attempt')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.attemptAnchor -PropertyNames @('schemaVersion','runId','runAttempt','nonce')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.selection -PropertyNames @('checks')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.results -PropertyNames @('checks')

	if ($ReceiptInput.repository.fullName -isnot [string] -or $ReceiptInput.repository.fullName -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$') { throw 'receipt_invalid' }
	if ($ReceiptInput.event.kind -isnot [string] -or $ReceiptInput.event.classification -isnot [string]) { throw 'receipt_invalid' }
	if (($ReceiptInput.event.kind -ceq 'pull_request' -and $ReceiptInput.event.classification -cne 'pull_request_acceptance') -or
		($ReceiptInput.event.kind -ceq 'push' -and $ReceiptInput.event.classification -cne 'post_merge_hosted_health') -or
		$ReceiptInput.event.kind -cnotin @('pull_request','push')) { throw 'receipt_invalid' }
	foreach ($ActorName in @('actor','triggeringActor')) {
		$Actor = $ReceiptInput.event.$ActorName
		if ($Actor -isnot [string] -or $Actor -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_\-\[\]]{0,99}$') { throw 'receipt_invalid' }
	}
	foreach ($Name in @('baseRevision','headRevision','testedRevision')) { if (-not (Test-AcceptanceRevision -Value $ReceiptInput.source.$Name)) { throw 'receipt_invalid' } }
	if ($ReceiptInput.source.baseRevision -ceq $ReceiptInput.source.headRevision) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDecimalIdentity -Value $ReceiptInput.workflow.id) -or
		-not (Test-AcceptanceRevision -Value $ReceiptInput.workflow.revision) -or -not (Test-AcceptanceDigest -Value $ReceiptInput.workflow.sha256)) { throw 'receipt_invalid' }
	if ($ReceiptInput.workflow.parents -isnot [Array] -or $ReceiptInput.workflow.parents.Count -lt 1 -or $ReceiptInput.workflow.parents.Count -gt 2) { throw 'receipt_invalid' }
	foreach ($Parent in $ReceiptInput.workflow.parents) { if (-not (Test-AcceptanceRevision -Value $Parent)) { throw 'receipt_invalid' } }
	if (@($ReceiptInput.workflow.parents | Select-Object -Unique).Count -ne $ReceiptInput.workflow.parents.Count) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceRevision -Value $ReceiptInput.controller.revision) -or -not (Test-AcceptanceRevision -Value $ReceiptInput.controller.blobOid) -or -not (Test-AcceptanceDigest -Value $ReceiptInput.controller.sha256)) { throw 'receipt_invalid' }
	if ($ReceiptInput.policy.version -isnot [string] -or $ReceiptInput.policy.version -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or -not (Test-AcceptanceDigest -Value $ReceiptInput.policy.digest)) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDigest -Value $ReceiptInput.actions.manifestSha256) -or $ReceiptInput.actions.items -isnot [Array] -or $ReceiptInput.actions.items.Count -lt 1 -or $ReceiptInput.actions.items.Count -gt 32) { throw 'receipt_invalid' }
	$ActionCopies = New-Object System.Collections.Generic.List[object]
	$ActionLines = New-Object System.Text.StringBuilder
	$PreviousAction = $null
	foreach ($Action in $ReceiptInput.actions.items) {
		Assert-AcceptanceClosedObject -Value $Action -PropertyNames @('uses','revision')
		if ($Action.uses -isnot [string] -or $Action.uses -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
			-not (Test-AcceptanceRevision -Value $Action.revision) -or
			($null -ne $PreviousAction -and [StringComparer]::Ordinal.Compare($PreviousAction, [string] $Action.uses) -ge 0)) { throw 'receipt_invalid' }
		$PreviousAction = [string] $Action.uses
		[void] $ActionLines.Append([string] $Action.uses).Append('@').Append([string] $Action.revision).Append("`n")
		$ActionCopies.Add([pscustomobject][ordered]@{ uses=[string]$Action.uses; revision=[string]$Action.revision })
	}
	if ((Get-AcceptanceSha256 -Bytes $script:AcceptanceUtf8NoBom.GetBytes($ActionLines.ToString())) -cne $ReceiptInput.actions.manifestSha256) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDecimalIdentity -Value $ReceiptInput.run.id) -or $ReceiptInput.run.attempt -isnot [int] -or $ReceiptInput.run.attempt -lt 1) { throw 'receipt_invalid' }
	Assert-AcceptanceAttemptAnchor -Anchor $ReceiptInput.attemptAnchor -Run $ReceiptInput.run

	if ($ReceiptInput.event.kind -ceq 'pull_request') {
		if ($ReceiptInput.source.testedRevision -cne $ReceiptInput.workflow.revision -or $ReceiptInput.controller.revision -cne $ReceiptInput.source.baseRevision -or
			$ReceiptInput.workflow.parents.Count -ne 2 -or $ReceiptInput.workflow.parents[0] -cne $ReceiptInput.source.baseRevision -or $ReceiptInput.workflow.parents[1] -cne $ReceiptInput.source.headRevision) { throw 'receipt_invalid' }
	} else {
		if ($ReceiptInput.source.testedRevision -cne $ReceiptInput.source.headRevision -or $ReceiptInput.workflow.revision -cne $ReceiptInput.source.headRevision -or
			$ReceiptInput.controller.revision -cne $ReceiptInput.source.headRevision -or $ReceiptInput.workflow.parents[0] -cne $ReceiptInput.source.baseRevision) { throw 'receipt_invalid' }
	}

	Assert-AcceptanceOrderedUniqueStringSet -Value $ReceiptInput.selection.checks -Allowed $script:AcceptanceCheckIds
	if ($ReceiptInput.selection.checks.Count -gt $script:AcceptanceCheckIds.Count -or $ReceiptInput.results.checks -isnot [Array] -or
		$ReceiptInput.results.checks.Count -ne $ReceiptInput.selection.checks.Count -or $ReceiptInput.results.checks.Count -gt $script:AcceptanceResultLimit) { throw 'receipt_invalid' }

	$EvidenceNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	# A repeated evidence name is one shared file only when name, digest, and size are identical.
	$SharedEvidence = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$ReceiptJobName = $null
	$EvidenceCount = 0
	$EvidenceBytes = 0L
	$CleanupApplicable = $false
	$ResultCopies = New-Object System.Collections.Generic.List[object]
	for ($Index = 0; $Index -lt $ReceiptInput.results.checks.Count; $Index++) {
		$Result = $ReceiptInput.results.checks[$Index]
		Assert-AcceptanceClosedObject -Value $Result -PropertyNames @('id','jobName','conclusion','nativeExitCode','infrastructureFailure','terminal','cleanupVerified','evidence')
		if ($Result.id -isnot [string] -or $Result.id -cne $ReceiptInput.selection.checks[$Index] -or
			$Result.jobName -isnot [string] -or $Result.jobName.Length -lt 1 -or $Result.jobName.Length -gt 100 -or $Result.jobName -cnotmatch '^[\x20-\x7e]+$' -or
			$Result.conclusion -cne 'success' -or $Result.terminal -isnot [bool] -or -not $Result.terminal -or $null -ne $Result.infrastructureFailure) { throw 'receipt_invalid' }
		if ($null -eq $ReceiptJobName) { $ReceiptJobName = [string] $Result.jobName }
		elseif ([string] $Result.jobName -cne $ReceiptJobName) { throw 'receipt_invalid' }
		if ($script:AcceptanceReceiptUnsupportedCheckIds -ccontains $Result.id) { throw ('receipt_semantic_evidence_unsupported:' + $Result.id) }
		if ($null -ne $Result.nativeExitCode -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_invalid' }
		if ($Result.id -ceq 'visual-package' -and $null -ne $Result.nativeExitCode) { throw 'receipt_semantic_evidence_invalid:visual-package' }
		if ($Result.id -cin @('portable','controller-contract') -and $null -ne $Result.nativeExitCode) { throw ('receipt_semantic_evidence_invalid:' + $Result.id) }
		if ($Result.id -ceq 'unreal-editor-automation' -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
		$RequiresCleanup = $Result.id -in @('native-client-server-compile','controller-operational-proof','clean-package-provenance-smoke')
		if ($RequiresCleanup -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_invalid' }
		if ($RequiresCleanup) {
			if ($Result.cleanupVerified -isnot [bool] -or -not $Result.cleanupVerified) { throw 'receipt_invalid' }
			$CleanupApplicable = $true
		} elseif ($null -ne $Result.cleanupVerified) { throw 'receipt_invalid' }
		if ($Result.evidence -isnot [Array] -or $Result.evidence.Count -lt 1 -or $Result.evidence.Count -gt $script:AcceptanceEvidencePerResultLimit) { throw 'receipt_invalid' }
		if ($Result.id -in @('portable','controller-contract','controller-operational-proof','native-client-server-compile','unreal-editor-automation','visual-package') -and $Result.evidence.Count -ne 1) { throw ('receipt_semantic_evidence_duplicate:' + $Result.id) }
		$EvidenceCopies = New-Object System.Collections.Generic.List[object]
		$PreviousEvidenceName = $null
		$SemanticEvidenceBytes = $null
		$SemanticEvidenceName = switch ($Result.id) {
			'portable' { 'ci-report.json' }
			'controller-contract' { 'ci-report.json' }
			'controller-operational-proof' { 'engine-runner-report.json' }
			'native-client-server-compile' { 'engine-runner-report.json' }
			'unreal-editor-automation' { 'unreal-automation-report.json' }
			'visual-package' { 'visual-package-report.json' }
			default { throw ('receipt_semantic_evidence_unsupported:' + $Result.id) }
		}
		foreach ($Evidence in $Result.evidence) {
			Assert-AcceptanceClosedObject -Value $Evidence -PropertyNames @('name','sha256','sizeBytes')
			if (-not (Test-AcceptanceEvidenceName -Value $Evidence.name) -or -not (Test-AcceptanceDigest -Value $Evidence.sha256) -or
				$Evidence.sizeBytes -isnot [long] -and $Evidence.sizeBytes -isnot [int]) { throw 'receipt_invalid' }
			$DeclaredSize = [long] $Evidence.sizeBytes
			if ($DeclaredSize -lt 0 -or $DeclaredSize -gt $script:AcceptanceEvidenceFileLimit) { throw 'receipt_invalid' }
			$SharedEvidenceKey = [string] $Evidence.name + '|' + [string] $Evidence.sha256 + '|' + $DeclaredSize
			if ($EvidenceNames.Add([string] $Evidence.name)) { [void] $SharedEvidence.Add($SharedEvidenceKey) }
			elseif (-not $SharedEvidence.Contains($SharedEvidenceKey)) { throw 'receipt_invalid' }
			if ($null -ne $PreviousEvidenceName -and [StringComparer]::Ordinal.Compare($PreviousEvidenceName, [string] $Evidence.name) -ge 0) { throw 'receipt_invalid' }
			$PreviousEvidenceName = [string] $Evidence.name
			$EvidenceCount++
			$EvidenceBytes += $DeclaredSize
			if ($EvidenceCount -gt $script:AcceptanceEvidenceLimit -or $EvidenceBytes -gt $script:AcceptanceEvidenceAggregateLimit) { throw 'receipt_invalid' }
			$File = Get-AcceptanceEvidenceFile -Root $EvidenceRoot -Name $Evidence.name
			if ($File.Length -ne $DeclaredSize) { throw 'receipt_invalid' }
			$FileBytes = [IO.File]::ReadAllBytes($File.FullName)
			$ActualDigest = Get-AcceptanceSha256 -Bytes $FileBytes
			$After = Get-Item -LiteralPath $File.FullName
			if ($FileBytes.Length -ne $DeclaredSize -or $After.Length -ne $DeclaredSize -or $ActualDigest -cne $Evidence.sha256) { throw 'receipt_invalid' }
			if ($null -ne $SemanticEvidenceName) {
				if ($Evidence.name -cne $SemanticEvidenceName) { throw ('receipt_semantic_evidence_missing:' + $Result.id) }
				$SemanticEvidenceBytes = $FileBytes
			}
			$EvidenceCopies.Add([pscustomobject][ordered]@{ name=[string]$Evidence.name; sha256=[string]$Evidence.sha256; sizeBytes=$DeclaredSize })
		}
		if ($null -ne $SemanticEvidenceName) {
			if ($null -eq $SemanticEvidenceBytes) { throw ('receipt_semantic_evidence_missing:' + $Result.id) }
			switch ($Result.id) {
				'portable' { Assert-AcceptancePortableEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput }
				'controller-contract' { Assert-AcceptancePortableEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput -CheckId 'controller-contract' }
				'controller-operational-proof' { Assert-AcceptanceEngineRunnerEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput -CheckId 'controller-operational-proof' }
				'native-client-server-compile' { Assert-AcceptanceEngineRunnerEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput }
				'unreal-editor-automation' { Assert-AcceptanceUnrealAutomationEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput }
				'visual-package' { Assert-AcceptanceVisualPackageEvidence -Bytes $SemanticEvidenceBytes -Identity $ReceiptInput }
				default { throw ('receipt_semantic_evidence_unsupported:' + $Result.id) }
			}
		}
		$ResultCopies.Add([pscustomobject][ordered]@{
			id=[string]$Result.id; jobName=[string]$Result.jobName; conclusion='success'; nativeExitCode=$Result.nativeExitCode
			infrastructureFailure=$null; terminal=$true; cleanupVerified=$Result.cleanupVerified; evidence=$EvidenceCopies.ToArray()
		})
	}

	$Receipt = [pscustomobject][ordered]@{
		schemaVersion = $script:AcceptanceReceiptSchema
		repository = [pscustomobject][ordered]@{ fullName=[string]$ReceiptInput.repository.fullName }
		event = [pscustomobject][ordered]@{ kind=[string]$ReceiptInput.event.kind; classification=[string]$ReceiptInput.event.classification; actor=[string]$ReceiptInput.event.actor; triggeringActor=[string]$ReceiptInput.event.triggeringActor }
		source = [pscustomobject][ordered]@{ baseRevision=[string]$ReceiptInput.source.baseRevision; headRevision=[string]$ReceiptInput.source.headRevision; testedRevision=[string]$ReceiptInput.source.testedRevision }
		workflow = [pscustomobject][ordered]@{ id=[string]$ReceiptInput.workflow.id; revision=[string]$ReceiptInput.workflow.revision; parents=@($ReceiptInput.workflow.parents); sha256=[string]$ReceiptInput.workflow.sha256 }
		controller = [pscustomobject][ordered]@{ revision=[string]$ReceiptInput.controller.revision; blobOid=[string]$ReceiptInput.controller.blobOid; sha256=[string]$ReceiptInput.controller.sha256 }
		policy = [pscustomobject][ordered]@{ version=[string]$ReceiptInput.policy.version; digest=[string]$ReceiptInput.policy.digest }
		actions = [pscustomobject][ordered]@{ manifestSha256=[string]$ReceiptInput.actions.manifestSha256; items=$ActionCopies.ToArray() }
		run = [pscustomobject][ordered]@{ id=[string]$ReceiptInput.run.id; attempt=[int]$ReceiptInput.run.attempt }
		attemptAnchor = [pscustomobject][ordered]@{ schemaVersion=$script:AttemptAnchorSchema; runId=[string]$ReceiptInput.attemptAnchor.runId; runAttempt=[int]$ReceiptInput.attemptAnchor.runAttempt; nonce=[string]$ReceiptInput.attemptAnchor.nonce }
		selection = [pscustomobject][ordered]@{ checks=@($ReceiptInput.selection.checks) }
		results = [pscustomobject][ordered]@{ checks=$ResultCopies.ToArray() }
		acceptance = [pscustomobject][ordered]@{ shadow=$true; authoritative=$false; grantsAcceptance=$false; terminal=$true; infrastructureFailure=$false; cleanupVerified=$(if ($CleanupApplicable) { $true } else { $null }) }
	}
	$Json = ConvertTo-Json -InputObject $Receipt -Depth 12 -Compress
	$Bytes = $script:AcceptanceUtf8NoBom.GetBytes($Json + "`n")
	if ($Bytes.Length -gt $script:AcceptanceReceiptLimit) { throw 'receipt_output_limit' }
	if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Create CI acceptance receipt')) { throw 'receipt_publication_declined' }
	$Parent = Split-Path -Path $OutputPath -Parent
	if ([string]::IsNullOrWhiteSpace($Parent)) { $Parent = (Get-Location).Path }
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { [void] (New-Item -ItemType Directory -Path $Parent -Force) }
	$Temporary = Join-Path -Path $Parent -ChildPath ('.ci-acceptance-receipt-' + [guid]::NewGuid().ToString('N') + '.tmp')
	try {
		[IO.File]::WriteAllBytes($Temporary, $Bytes)
		[IO.File]::Move($Temporary, [IO.Path]::GetFullPath($OutputPath))
	} finally {
		if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
	}
	return $Receipt
}

if ($InputPath -or $EvidenceRoot -or $OutputPath) {
	if (-not $InputPath -or -not $EvidenceRoot -or -not $OutputPath) { throw 'InputPath, EvidenceRoot, and OutputPath are required together.' }
	New-CiAcceptanceReceipt -InputPath $InputPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath | Out-Null
}
