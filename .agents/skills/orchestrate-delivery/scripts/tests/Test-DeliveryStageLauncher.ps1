[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SkillRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $SkillRoot '..\..\..')).Path
$SourceCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
$ValidateScript = Join-Path $ScriptRoot 'Validate-DeliveryHandoff.ps1'
$LaunchScript = Join-Path $ScriptRoot 'Invoke-DeliveryStage.ps1'
$SnapshotScript = Join-Path $ScriptRoot 'Get-DeliveryRepositorySnapshot.ps1'
$PatchValidationScript = Join-Path $ScriptRoot 'Validate-DeliveryPatch.ps1'
$ReparseCheckScript = Join-Path $ScriptRoot 'Assert-DeliveryPathNoReparse.ps1'
$PathSplitScript = Join-Path $ScriptRoot 'Split-DeliveryGitPathList.ps1'
$SensitivePathScript = Join-Path $ScriptRoot 'Test-DeliverySensitivePath.ps1'
$EvidenceProtectionScript = Join-Path $ScriptRoot 'Protect-DeliveryEvidence.ps1'
$EvidenceValidationScript = Join-Path $ScriptRoot 'Test-DeliveryEvidence.ps1'
$EventTelemetryScript = Join-Path $ScriptRoot 'Get-DeliveryEventTelemetry.ps1'
$EfficiencyComparisonScript = Join-Path $ScriptRoot 'Compare-DeliveryEfficiency.ps1'
$SchemaPath = Join-Path $SkillRoot 'references\handoff-schemas.json'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-stage-tests-' + [guid]::NewGuid().ToString('N')
)

New-Item -ItemType Directory -Path $TestRoot | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter(Mandatory)]
		[bool]$Passed,

		[string]$Detail = ''
	)

	$Results.Add([pscustomobject]@{
		Name = $Name
		Passed = $Passed
		Detail = $Detail
	})
}

function Invoke-ExpectedFailure {
	param(
		[Parameter(Mandatory)]
		[scriptblock]$Action,

		[Parameter(Mandatory)]
		[string]$Pattern
	)

	try {
		& $Action
		return $false
	}
	catch {
		return $_.Exception.Message -match $Pattern
	}
}

function Invoke-TestGitText {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
		$Result = [System.Text.Encoding]::UTF8.GetString($Output.ToArray())
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}

	if ($ExitCode -ne 0) {
		throw "Git command '$Arguments' failed: $StandardError"
	}

	return $Result
}

function Invoke-TestGitBytes {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments,

		[hashtable]$Environment = @{}
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	foreach ($Name in $Environment.Keys) {
		$StartInfo.EnvironmentVariables[[string]$Name] = [string]$Environment[$Name]
	}

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
		$Result = $Output.ToArray()
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}

	if ($ExitCode -ne 0) {
		throw "Git command '$Arguments' failed: $StandardError"
	}

	return [byte[]]$Result
}

function Get-TestSha256 {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes
	)

	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function New-NeutralEvidenceByteRecord {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('text', 'command_log', 'artifact', 'diff', 'status', 'path_list')]
		[string]$Kind,

		[Parameter(Mandatory)]
		[ValidateSet('control_plane', 'repository', 'launcher', 'stage', 'external')]
		[string]$Provenance,

		[Parameter(Mandatory)]
		[string]$Source,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[ValidateSet('utf8', 'base64')]
		[string]$Encoding
	)

	$Content = if ($Encoding -eq 'base64') {
		[System.Convert]::ToBase64String($Bytes)
	}
	else {
		$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
		$StrictUtf8.GetString($Bytes)
	}

	return [pscustomobject][ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = $Encoding
		source = $Source
		sha256 = Get-TestSha256 -Bytes $Bytes
		content = $Content
	}
}

function Test-TestByteArrayEqual {
	param(
		[byte[]]$Left,
		[byte[]]$Right
	)

	return [System.Linq.Enumerable]::SequenceEqual(
		[byte[]]$Left,
		[byte[]]$Right
	)
}

function New-NeutralEvidenceRecord {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('text', 'command_log', 'artifact', 'diff', 'status', 'path_list')]
		[string]$Kind,

		[Parameter(Mandatory)]
		[ValidateSet('control_plane', 'repository', 'launcher', 'stage', 'external')]
		[string]$Provenance,

		[Parameter(Mandatory)]
		[string]$Source,

		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Text,

		[ValidateSet('utf8', 'base64')]
		[string]$Encoding = 'utf8'
	)

	$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Hash = [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}

	$Content = if ($Encoding -eq 'base64') {
		[System.Convert]::ToBase64String($Bytes)
	} else {
		$Text
	}

	return [pscustomobject][ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = $Encoding
		source = $Source
		sha256 = $Hash
		content = $Content
	}
}

try {
	$AnalystHandoffPath = Join-Path $TestRoot 'analyst.json'
	@{
		schema_version = 1
		stage = 'analyst'
		run_id = 'test-analyst'
		workspace_root = $RepositoryRoot
		source_commit = $SourceCommit
		ticket = 'Issue #123'
		acceptance_criteria = @('Criterion')
		canonical_sources = @('AGENTS.md')
		output_contract = 'Return readiness evidence.'
		board_export = 'board.json'
		repository_tree = 'tree.txt'
		repository_state = 'status.txt'
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AnalystHandoffPath -Encoding UTF8

	$AnalystValidation = & $ValidateScript `
		-HandoffPath $AnalystHandoffPath `
		-SchemaPath $SchemaPath
	Add-Result -Name 'Valid analyst handoff passes' -Passed $true

	$OriginalHandoffBytes = [System.IO.File]::ReadAllBytes($AnalystHandoffPath)
	$ChangedHandoff = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
	$ChangedHandoff.run_id = 'replacement-run'
	$ChangedHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $AnalystHandoffPath `
		-Encoding UTF8
	$OriginalHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$OriginalHash = [System.BitConverter]::ToString(
			$OriginalHasher.ComputeHash($OriginalHandoffBytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$OriginalHasher.Dispose()
	}
	Add-Result `
		-Name 'Validated handoff bytes remain frozen' `
		-Passed (
			$AnalystValidation.RunId -eq 'test-analyst' -and
			$AnalystValidation.HandoffJson -match '"test-analyst"' -and
			$AnalystValidation.HandoffHash -eq $OriginalHash
		)
	[System.IO.File]::WriteAllBytes($AnalystHandoffPath, $OriginalHandoffBytes)

	$DefaultPolicy = $AnalystValidation.ExecutionPolicy
	Add-Result `
		-Name 'Absent execution policy receives normalized defaults' `
		-Passed (
			$DefaultPolicy.AttemptOrdinal -eq 1 -and
			$DefaultPolicy.AttemptClass -eq 'initial' -and
			$DefaultPolicy.CapabilityClass -eq 'standard' -and
			$null -eq $DefaultPolicy.RetryCause -and
			@($DefaultPolicy.Limits.PSObject.Properties.Value |
				Where-Object { $null -ne $_ }).Count -eq 0
		)

	$CompletePolicyPath = Join-Path $TestRoot 'complete-policy.json'
	$CompletePolicyHandoff = Get-Content -Raw -LiteralPath $AnalystHandoffPath |
		ConvertFrom-Json
	$CompletePolicyHandoff.run_id = 'complete-policy'
	$CompletePolicyHandoff | Add-Member -NotePropertyName execution_policy -NotePropertyValue ([pscustomobject]@{
		attempt_ordinal = 2
		attempt_class = 'replacement'
		capability_class = 'elevated'
		retry_cause = 'transient execution failure'
		limits = [pscustomobject]@{
			total_tokens = 100
			elapsed_milliseconds = 200
			concurrent_stages = 3
			execution_retries = 1
			fix_cycles = 2
			provenance = 'user-approved'
			approved_at_utc = '2026-07-27T12:34:56.123Z'
		}
	})
	$CompletePolicyHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $CompletePolicyPath -Encoding UTF8
	$CompletePolicyBytes = [System.IO.File]::ReadAllBytes($CompletePolicyPath)
	$CompletePolicyValidation = & $ValidateScript `
		-HandoffPath $CompletePolicyPath -SchemaPath $SchemaPath
	$CompletePolicyHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$CompletePolicyHash = [System.BitConverter]::ToString(
			$CompletePolicyHasher.ComputeHash($CompletePolicyBytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$CompletePolicyHasher.Dispose()
	}
	Add-Result `
		-Name 'Complete execution policy is normalized without changing handoff evidence' `
		-Passed (
			$CompletePolicyValidation.ExecutionPolicy.AttemptOrdinal -eq 2 -and
			$CompletePolicyValidation.ExecutionPolicy.AttemptClass -eq 'replacement' -and
			$CompletePolicyValidation.ExecutionPolicy.CapabilityClass -eq 'elevated' -and
			$CompletePolicyValidation.ExecutionPolicy.RetryCause -eq 'transient execution failure' -and
			$CompletePolicyValidation.ExecutionPolicy.Limits.TotalTokens -eq 100 -and
			$CompletePolicyValidation.ExecutionPolicy.Limits.ApprovedAtUtc -eq '2026-07-27T12:34:56.123Z' -and
			$CompletePolicyValidation.HandoffJson -eq [System.Text.Encoding]::UTF8.GetString($CompletePolicyBytes) -and
			$CompletePolicyValidation.HandoffHash -eq $CompletePolicyHash -and
			[object]::ReferenceEquals(
				$CompletePolicyValidation.Handoff.execution_policy,
				$CompletePolicyValidation.ExecutionPolicy
			) -eq $false
		)

	$InvalidPolicies = @(
		@('unknown policy property', '{"unexpected":true}', 'not allowed'),
		@('unknown limits property', '{"limits":{"unexpected":true}}', 'not allowed'),
		@('boolean ordinal', '{"attempt_ordinal":true}', 'attempt_ordinal'),
		@('string ordinal', '{"attempt_ordinal":"1"}', 'attempt_ordinal'),
		@('zero ordinal', '{"attempt_ordinal":0}', 'attempt_ordinal'),
		@('fractional ordinal', '{"attempt_ordinal":1.5}', 'attempt_ordinal'),
		@('invalid attempt class', '{"attempt_class":"retry"}', 'attempt_class'),
		@('invalid capability class', '{"capability_class":"premium"}', 'capability_class'),
		@('blank retry cause', '{"retry_cause":" "}', 'retry_cause'),
		@('numeric retry cause', '{"retry_cause":5}', 'retry_cause'),
		@('boolean numeric limit', '{"limits":{"total_tokens":true}}', 'total_tokens'),
		@('string numeric limit', '{"limits":{"total_tokens":"1"}}', 'total_tokens'),
		@('negative numeric limit', '{"limits":{"total_tokens":-1}}', 'total_tokens'),
		@('fractional numeric limit', '{"limits":{"total_tokens":1.5}}', 'total_tokens'),
		@('total tokens without approval', '{"limits":{"total_tokens":1}}', 'require.*provenance.*approved_at_utc'),
		@('elapsed milliseconds without approval', '{"limits":{"elapsed_milliseconds":1}}', 'require.*provenance.*approved_at_utc'),
		@('concurrent stages without approval', '{"limits":{"concurrent_stages":1}}', 'require.*provenance.*approved_at_utc'),
		@('execution retries without approval', '{"limits":{"execution_retries":1}}', 'require.*provenance.*approved_at_utc'),
		@('fix cycles without approval', '{"limits":{"fix_cycles":1}}', 'require.*provenance.*approved_at_utc'),
		@('numeric limit without approval time', '{"limits":{"total_tokens":1,"provenance":"user-approved"}}', 'require.*provenance.*approved_at_utc'),
		@('numeric limit without provenance', '{"limits":{"total_tokens":1,"approved_at_utc":"2026-07-27T12:34:56Z"}}', 'require.*provenance.*approved_at_utc'),
		@('blank provenance', '{"limits":{"provenance":" "}}', 'provenance'),
		@('numeric provenance', '{"limits":{"provenance":5}}', 'provenance'),
		@('offset timestamp', '{"limits":{"approved_at_utc":"2026-07-27T12:34:56+00:00"}}', 'approved_at_utc'),
		@('invalid timestamp', '{"limits":{"approved_at_utc":"2026-02-30T12:34:56Z"}}', 'approved_at_utc'),
		@('numeric timestamp', '{"limits":{"approved_at_utc":5}}', 'approved_at_utc'),
		@('null policy', 'null', 'JSON object'),
		@('array limits', '{"limits":[]}', 'JSON object')
	)
	foreach ($InvalidPolicy in $InvalidPolicies) {
		$InvalidPolicyPath = Join-Path $TestRoot (
			'invalid-policy-' + ($InvalidPolicy[0] -replace ' ', '-') + '.json'
		)
		$InvalidPolicyJson = Get-Content -Raw -LiteralPath $AnalystHandoffPath |
			ConvertFrom-Json
		$InvalidPolicyJson.run_id = 'invalid-policy-' + ($InvalidPolicy[0] -replace ' ', '-')
		$InvalidPolicyValue = $InvalidPolicy[1] | ConvertFrom-Json
		$InvalidPolicyJson | Add-Member `
			-NotePropertyName execution_policy `
			-NotePropertyValue $InvalidPolicyValue
		$InvalidPolicyJson | ConvertTo-Json -Depth 8 | Set-Content `
			-LiteralPath $InvalidPolicyPath -Encoding UTF8
		$InvalidPolicyRejected = Invoke-ExpectedFailure `
			-Pattern $InvalidPolicy[2] `
			-Action {
				& $ValidateScript `
					-HandoffPath $InvalidPolicyPath `
					-SchemaPath $SchemaPath | Out-Null
			}
		Add-Result `
			-Name "Execution policy rejects $($InvalidPolicy[0])" `
			-Passed $InvalidPolicyRejected
	}

	$GateStages = @('verifier', 'reviewer', 'approver', 'adjudicator', 'qa')
	foreach ($GateStage in $GateStages) {
		$GateHandoffPath = Join-Path $TestRoot "economy-$GateStage.json"
		$GateSchema = (Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json).stages.$GateStage
		$GateHandoff = [ordered]@{
			schema_version = 1; stage = $GateStage; run_id = "economy-$GateStage"
			workspace_root = $RepositoryRoot; source_commit = $SourceCommit
			ticket = 'Issue #123'; acceptance_criteria = @('Criterion')
			canonical_sources = @('AGENTS.md'); output_contract = 'Return evidence.'
			execution_policy = @{ capability_class = 'economy' }
		}
		foreach ($RequiredName in @($GateSchema.required)) {
			$NeutralField = $GateSchema.neutral_evidence_fields.PSObject.Properties[
				$RequiredName
			]
			if ($null -eq $NeutralField) {
				$GateHandoff[$RequiredName] = 'raw evidence'
				continue
			}

			$NeutralParts = [string]$NeutralField.Value -split ':', 3
			$Cardinality = $NeutralParts[0]
			$Kind = ($NeutralParts[1] -split '\|')[0]
			$Provenance = ($NeutralParts[2] -split '\|')[0]
			$NeutralRecord = New-NeutralEvidenceRecord `
				-Kind $Kind `
				-Provenance $Provenance `
				-Source "economy-$GateStage-$RequiredName" `
				-Text 'raw evidence'
			if ($Cardinality -eq 'array') {
				$GateHandoff[$RequiredName] = [object[]]@($NeutralRecord)
			} else {
				$GateHandoff[$RequiredName] = $NeutralRecord
			}
		}
		$GateHandoff | ConvertTo-Json -Depth 8 | Set-Content `
			-LiteralPath $GateHandoffPath -Encoding UTF8
		$EconomyRejected = Invoke-ExpectedFailure -Pattern 'economy.*not allowed' -Action {
			& $ValidateScript -HandoffPath $GateHandoffPath -SchemaPath $SchemaPath | Out-Null
		}
		Add-Result -Name "Economy capability is rejected for $GateStage" -Passed $EconomyRejected
	}

	$AdjudicatorDefaultPath = Join-Path $TestRoot 'adjudicator-default.json'
	@{
		schema_version = 1; stage = 'adjudicator'; run_id = 'adjudicator-default'
		workspace_root = $RepositoryRoot; source_commit = $SourceCommit
		ticket = 'Issue #123'; acceptance_criteria = @('Criterion')
		canonical_sources = @('AGENTS.md'); output_contract = 'Return decision.'
		neutral_question = 'What evidence governs?'
		raw_evidence = @(
			New-NeutralEvidenceRecord -Kind text -Provenance control_plane `
				-Source 'adjudicator-default' -Text 'raw evidence'
		)
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AdjudicatorDefaultPath -Encoding UTF8
	$AdjudicatorDefault = & $ValidateScript `
		-HandoffPath $AdjudicatorDefaultPath -SchemaPath $SchemaPath
	Add-Result `
		-Name 'Adjudicator defaults to elevated capability' `
		-Passed ($AdjudicatorDefault.ExecutionPolicy.CapabilityClass -eq 'elevated')

	$AnalystDryRun = & $LaunchScript -HandoffPath $AnalystHandoffPath -DryRun -PassThru
	Add-Result `
		-Name 'Read-only stage dry run disables external tools' `
		-Passed (
			$AnalystDryRun.SandboxMode -eq 'read-only' -and
			$AnalystDryRun.Arguments -contains '--ignore-user-config' -and
			$AnalystDryRun.Arguments -contains 'apps' -and
			$AnalystDryRun.Arguments -contains 'mcp_servers={}'
		)
}
catch {
	Add-Result -Name 'Valid analyst handoff passes' -Passed $false -Detail $_.Exception.Message
	Add-Result `
		-Name 'Validated handoff bytes remain frozen' `
		-Passed $false `
		-Detail $_.Exception.Message
	Add-Result `
		-Name 'Read-only stage dry run disables external tools' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$VerifierHandoffPath = Join-Path $TestRoot 'verifier-with-verdict.json'
@{
	schema_version = 1
	stage = 'verifier'
	run_id = 'test-verifier'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return verification evidence.'
	candidate_artifact = New-NeutralEvidenceRecord -Kind artifact `
		-Provenance launcher -Source 'candidate.patch' -Text 'candidate patch'
	test_environment = 'local'
	commands = @('git diff --check')
	raw_check_output = @(
		New-NeutralEvidenceRecord -Kind command_log -Provenance launcher `
			-Source 'verifier-check-output' -Text 'check completed'
	)
	prior_findings = @('Expected to pass')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $VerifierHandoffPath -Encoding UTF8

$BlindFailure = Invoke-ExpectedFailure -Pattern 'not allowed|prohibited' -Action {
	& $ValidateScript -HandoffPath $VerifierHandoffPath -SchemaPath $SchemaPath | Out-Null
}
Add-Result -Name 'Blind verifier rejects prior verdict fields' -Passed $BlindFailure

$VerifierStringBypassPath = Join-Path $TestRoot 'verifier-string-bypass.json'
$VerifierStringBypass = Get-Content -Raw -LiteralPath $VerifierHandoffPath |
	ConvertFrom-Json
$VerifierStringBypass.PSObject.Properties.Remove('prior_findings')
$VerifierStringBypass.run_id = 'test-verifier-string-bypass'
$VerifierStringBypass.candidate_artifact = New-NeutralEvidenceRecord `
	-Kind artifact -Provenance launcher -Source 'candidate.patch' `
	-Text 'candidate.patch with prior_verdict embedded'
$VerifierStringBypass | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $VerifierStringBypassPath -Encoding UTF8
& $ValidateScript `
	-HandoffPath $VerifierStringBypassPath `
	-SchemaPath $SchemaPath | Out-Null
Add-Result `
	-Name 'Blind verifier treats validated typed content as opaque' `
	-Passed $true

$VerifierNestedBypassPath = Join-Path $TestRoot 'verifier-nested-bypass.json'
$VerifierNestedBypass = Get-Content -Raw -LiteralPath $VerifierHandoffPath |
	ConvertFrom-Json
$VerifierNestedBypass.PSObject.Properties.Remove('prior_findings')
$VerifierNestedBypass.run_id = 'test-verifier-nested-bypass'
$VerifierNestedBypass.candidate_artifact = New-NeutralEvidenceRecord `
	-Kind artifact -Provenance launcher -Source 'candidate.patch' `
	-Text 'candidate patch'
$NestedEvidenceValue = 'do-not-expose-agent-summary'
$VerifierNestedBypass.candidate_artifact | Add-Member `
	-NotePropertyName agent_summary `
	-NotePropertyValue $NestedEvidenceValue
$VerifierNestedBypass | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $VerifierNestedBypassPath -Encoding UTF8
$BlindNestedBypassError = ''
try {
	& $ValidateScript `
		-HandoffPath $VerifierNestedBypassPath `
		-SchemaPath $SchemaPath | Out-Null
}
catch {
	$BlindNestedBypassError = $_.Exception.Message
}
Add-Result `
	-Name 'Blind verifier rejects an extra neutral evidence key without exposing its value' `
	-Passed (
		$BlindNestedBypassError -match 'neutral_evidence_keys_invalid' -and
		$BlindNestedBypassError -notmatch [regex]::Escape($NestedEvidenceValue)
	)

$UnsafeRunIdPath = Join-Path $TestRoot 'unsafe-run-id.json'
@{
	schema_version = 1
	stage = 'analyst'
	run_id = '..\AGENTS'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return readiness evidence.'
	board_export = 'board.json'
	repository_tree = 'tree.txt'
	repository_state = 'status.txt'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $UnsafeRunIdPath -Encoding UTF8

$UnsafeRunIdFailure = Invoke-ExpectedFailure -Pattern 'run_id|safe' -Action {
	& $ValidateScript -HandoffPath $UnsafeRunIdPath -SchemaPath $SchemaPath | Out-Null
}
Add-Result -Name 'Unsafe run ID is rejected' -Passed $UnsafeRunIdFailure

$InvalidSourcePath = Join-Path $TestRoot 'invalid-source.json'
$InvalidSource = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
$InvalidSource.run_id = 'test-invalid-source'
$InvalidSource.source_commit = '0000000000000000000000000000000000000000'
$InvalidSource | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InvalidSourcePath -Encoding UTF8
$InvalidSourceFailure = Invoke-ExpectedFailure -Pattern 'source_commit|valid Git' -Action {
	& $LaunchScript -HandoffPath $InvalidSourcePath -DryRun | Out-Null
}
Add-Result -Name 'Unknown source commit is rejected' -Passed $InvalidSourceFailure

$ExternalRootPath = Join-Path $TestRoot 'external-root.json'
$ExternalRoot = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
$ExternalRoot.run_id = 'test-external-root'
$ExternalRoot.workspace_root = $TestRoot
$ExternalRoot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ExternalRootPath -Encoding UTF8
$ExternalRootFailure = Invoke-ExpectedFailure -Pattern 'configured repository' -Action {
	& $LaunchScript -HandoffPath $ExternalRootPath -DryRun | Out-Null
}
Add-Result -Name 'External workspace root is rejected' -Passed $ExternalRootFailure

$SensitiveRepositoryRoot = Join-Path $TestRoot 'snapshot-sensitive-repository'
New-Item -ItemType Directory -Path $SensitiveRepositoryRoot | Out-Null
& git -C $SensitiveRepositoryRoot init --quiet
$SensitiveFixturePath = Join-Path $SensitiveRepositoryRoot 'snapshot-sensitive-test.pem'
Set-Content -LiteralPath $SensitiveFixturePath -Value 'not-a-secret' -Encoding UTF8
$SensitivePathRejected = Invoke-ExpectedFailure -Pattern 'sensitive path' -Action {
	& $SnapshotScript -RepositoryRoot $SensitiveRepositoryRoot | Out-Null
}
Add-Result -Name 'Sensitive repository path fails closed' -Passed $SensitivePathRejected

$SpecialPathList = "plain.txt`0folder`tname.pem`0line`nname.txt`0"
$ParsedSpecialPaths = @(& $PathSplitScript -RawPaths $SpecialPathList)
Add-Result `
	-Name 'NUL path parser preserves special characters' `
	-Passed (
		$ParsedSpecialPaths.Count -eq 3 -and
		$ParsedSpecialPaths[1] -eq "folder`tname.pem" -and
		$ParsedSpecialPaths[2] -eq "line`nname.txt"
	)
$SnapshotSource = Get-Content -Raw -LiteralPath $SnapshotScript
Add-Result `
	-Name 'Git inventory uses binary-safe output capture' `
	-Passed (
		$SnapshotSource -match 'StandardOutput\.BaseStream\.CopyTo' -and
		$SnapshotSource -notmatch '\& git .+ ls-files'
	)
Add-Result `
	-Name 'Special-character sensitive path is classified' `
	-Passed (& $SensitivePathScript -RelativePath "folder`tname.pem")

$SensitiveCases = @(
	'id_rsa',
	'.npmrc',
	'.netrc',
	'auth.json',
	'kubeconfig',
	'.docker/credentials.json',
	'config/client_secret_game.json',
	'service-account-development.json'
)
$NonSensitiveCases = @(
	'docs/security-and-operations.md',
	'docs/authentication-overview.md',
	'Config/DefaultGame.ini'
)
$SensitiveTablePassed = @(
	$SensitiveCases | Where-Object {
		-not (& $SensitivePathScript -RelativePath $_)
	}
).Count -eq 0 -and @(
	$NonSensitiveCases | Where-Object {
		& $SensitivePathScript -RelativePath $_
	}
).Count -eq 0
Add-Result `
	-Name 'Credential filename table is fail-closed' `
	-Passed $SensitiveTablePassed

$ReparseTarget = Join-Path $TestRoot 'reparse-target'
$ReparseLink = Join-Path $TestRoot 'reparse-link'
New-Item -ItemType Directory -Path $ReparseTarget | Out-Null
Set-Content -LiteralPath (Join-Path $ReparseTarget 'fixture.txt') -Value 'fixture' -Encoding UTF8
$ReparseCreated = $true
try {
	New-Item -ItemType Junction -Path $ReparseLink -Target $ReparseTarget | Out-Null
}
catch {
	$ReparseCreated = $false
}
$ReparseRejected = if ($ReparseCreated) {
	Invoke-ExpectedFailure -Pattern 'reparse point' -Action {
		& $ReparseCheckScript `
			-Path (Join-Path $ReparseLink 'fixture.txt') `
			-Root $TestRoot
	}
}
else {
	$false
}
Add-Result `
	-Name 'Reparse-point ancestor fails closed' `
	-Passed $ReparseRejected `
	-Detail $(if ($ReparseCreated) { '' } else { 'Could not create test junction.' })

$ReparseRepositoryRoot = Join-Path $TestRoot 'snapshot-reparse-repository'
New-Item -ItemType Directory -Path $ReparseRepositoryRoot | Out-Null
& git -C $ReparseRepositoryRoot init --quiet
$RepositoryReparseLink = Join-Path $ReparseRepositoryRoot (
	'snapshot-reparse-' + [guid]::NewGuid().ToString('N')
)
$RepositoryReparseCreated = $true
try {
	New-Item `
		-ItemType Junction `
		-Path $RepositoryReparseLink `
		-Target $ReparseTarget | Out-Null
}
catch {
	$RepositoryReparseCreated = $false
}
$RepositoryReparseRejected = if ($RepositoryReparseCreated) {
	Invoke-ExpectedFailure -Pattern 'reparse point' -Action {
		& $SnapshotScript -RepositoryRoot $ReparseRepositoryRoot | Out-Null
	}
}
else {
	$false
}
Add-Result `
	-Name 'Repository inventory rejects directory reparse entry' `
	-Passed $RepositoryReparseRejected `
	-Detail $(if ($RepositoryReparseCreated) { '' } else { 'Could not create repository test junction.' })

$RepositoryOutputFailure = Invoke-ExpectedFailure -Pattern 'artifact root|outside' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-OutputPath (Join-Path $RepositoryRoot 'AGENTS.md') `
		-DryRun | Out-Null
}
Add-Result -Name 'Repository output path is rejected' -Passed $RepositoryOutputFailure

$RepositoryAuditFailure = Invoke-ExpectedFailure -Pattern 'artifact root|outside' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-AuditPath (Join-Path $RepositoryRoot 'AGENTS.md') `
		-DryRun | Out-Null
}
Add-Result -Name 'Repository audit path is rejected' -Passed $RepositoryAuditFailure

$AliasedArtifactRoot = Join-Path $TestRoot 'aliased-artifacts'
$ArtifactAliasFailure = Invoke-ExpectedFailure -Pattern 'resolve to the same path' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-OutputPath 'delivery-stage-test-analyst-audit.json' `
		-ArtifactRoot $AliasedArtifactRoot `
		-DryRun | Out-Null
}
Add-Result -Name 'Aliased artifact targets are rejected before launch' -Passed $ArtifactAliasFailure

$ReviewerBaselineStatus = Invoke-TestGitText `
	-Arguments 'status --short --untracked-files=all'
$ReviewerBaselineDiff = Invoke-TestGitText -Arguments 'diff --binary --no-ext-diff'
$ReviewerStatusBytes = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
$ReviewerSnapshotBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$RealIndexPath = (Invoke-TestGitText -Arguments 'rev-parse --git-path index').Trim()
if (-not [System.IO.Path]::IsPathRooted($RealIndexPath)) {
	$RealIndexPath = Join-Path $RepositoryRoot $RealIndexPath
}
$RealIndexHashBefore = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))

$ReviewerGitRoot = Join-Path $TestRoot 'reviewer-git'
$ReviewerIndexPath = Join-Path $ReviewerGitRoot 'index'
$ReviewerObjectPath = Join-Path $ReviewerGitRoot 'objects'
[void][System.IO.Directory]::CreateDirectory($ReviewerObjectPath)
$RealObjectPath = (Invoke-TestGitText -Arguments 'rev-parse --git-path objects').Trim()
if (-not [System.IO.Path]::IsPathRooted($RealObjectPath)) {
	$RealObjectPath = Join-Path $RepositoryRoot $RealObjectPath
}
$ReviewerGitEnvironment = @{
	GIT_INDEX_FILE = $ReviewerIndexPath
	GIT_OBJECT_DIRECTORY = $ReviewerObjectPath
	GIT_ALTERNATE_OBJECT_DIRECTORIES = (Resolve-Path -LiteralPath $RealObjectPath).Path
	GIT_OPTIONAL_LOCKS = '0'
}
$null = Invoke-TestGitBytes `
	-Arguments "read-tree $SourceCommit" `
	-Environment $ReviewerGitEnvironment
$null = Invoke-TestGitBytes `
	-Arguments 'add --all -- .' `
	-Environment $ReviewerGitEnvironment
$ReviewerFinalDiffBytes = Invoke-TestGitBytes `
	-Arguments 'diff --cached --binary --full-index --no-ext-diff' `
	-Environment $ReviewerGitEnvironment

$RealIndexHashAfterFixture = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))
$ReviewerSnapshotAfterFixture = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$ReviewerStatusAfterFixture = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
Add-Result `
	-Name 'Reviewer fixture construction preserves repository state' `
	-Passed (
		$RealIndexHashBefore -eq $RealIndexHashAfterFixture -and
		$ReviewerSnapshotBefore.Hash -eq $ReviewerSnapshotAfterFixture.Hash -and
		(Test-TestByteArrayEqual $ReviewerStatusBytes $ReviewerStatusAfterFixture)
	)

$ReviewerHandoffPath = Join-Path $TestRoot 'reviewer-mapped-baselines.json'
@{
	schema_version = 1
	stage = 'reviewer'
	run_id = 'test-reviewer-mapped-baselines'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return review evidence.'
	baseline_status = New-NeutralEvidenceRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'baseline-status' `
		-Text $ReviewerBaselineStatus
	baseline_diff = New-NeutralEvidenceRecord `
		-Kind diff `
		-Provenance launcher `
		-Source 'baseline-diff' `
		-Text $ReviewerBaselineDiff `
		-Encoding base64
	allowed_paths = @('AGENTS.md')
	non_goals = @('Everything else')
	final_diff = New-NeutralEvidenceByteRecord `
		-Kind diff `
		-Provenance launcher `
		-Source 'final-diff' `
		-Bytes $ReviewerFinalDiffBytes `
		-Encoding base64
	artifact_state = New-NeutralEvidenceByteRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'artifact-state' `
		-Bytes $ReviewerStatusBytes `
		-Encoding base64
	raw_check_output = @(
		New-NeutralEvidenceRecord `
			-Kind command_log `
			-Provenance launcher `
			-Source 'check-output' `
			-Text 'check completed' `
			-Encoding base64
	)
} | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ReviewerHandoffPath -Encoding UTF8

$ReviewerDryRun = $null
$ReviewerDryRunError = ''
try {
	$ReviewerDryRun = & $LaunchScript `
		-HandoffPath $ReviewerHandoffPath `
		-DryRun `
		-PassThru
}
catch {
	$ReviewerDryRunError = $_.Exception.Message
}
$RealIndexHashAfterDryRun = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))
$ReviewerSnapshotAfterDryRun = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$ReviewerStatusAfterDryRun = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
Add-Result `
	-Name 'Mapped reviewer baseline envelopes are decoded before comparison' `
	-Passed (
		$null -ne $ReviewerDryRun -and
		$ReviewerDryRun.Stage -eq 'reviewer' -and
		$ReviewerDryRun.SandboxMode -eq 'read-only'
	) `
	-Detail $ReviewerDryRunError
Add-Result `
	-Name 'Reviewer dry-run attestation preserves repository state' `
	-Passed (
		$RealIndexHashBefore -eq $RealIndexHashAfterDryRun -and
		$ReviewerSnapshotBefore.Hash -eq $ReviewerSnapshotAfterDryRun.Hash -and
		(Test-TestByteArrayEqual $ReviewerStatusBytes $ReviewerStatusAfterDryRun)
	)

$ReviewerUtf8Path = Join-Path $TestRoot 'reviewer-utf8-attestation.json'
$ReviewerUtf8 = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$ReviewerUtf8.run_id = 'test-reviewer-utf8-attestation'
$ReviewerUtf8.final_diff = New-NeutralEvidenceByteRecord `
	-Kind diff `
	-Provenance launcher `
	-Source 'final-diff-utf8' `
	-Bytes $ReviewerFinalDiffBytes `
	-Encoding utf8
$ReviewerUtf8.artifact_state = New-NeutralEvidenceByteRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'artifact-state-utf8' `
	-Bytes $ReviewerStatusBytes `
	-Encoding utf8
$ReviewerUtf8 | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ReviewerUtf8Path -Encoding UTF8
$ReviewerUtf8Error = ''
try {
	$null = & $LaunchScript `
		-HandoffPath $ReviewerUtf8Path `
		-DryRun `
		-PassThru
}
catch {
	$ReviewerUtf8Error = $_.Exception.Message
}
Add-Result `
	-Name 'Reviewer attestation accepts exact valid UTF-8 evidence bytes' `
	-Passed ([string]::IsNullOrEmpty($ReviewerUtf8Error)) `
	-Detail $ReviewerUtf8Error

$StaleReviewerPath = Join-Path $TestRoot 'reviewer-stale-final-diff.json'
$StaleReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$StaleReviewer.run_id = 'test-reviewer-stale-final-diff'
$StaleReviewer.final_diff = New-NeutralEvidenceRecord `
	-Kind diff `
	-Provenance launcher `
	-Source 'stale-final-diff' `
	-Text $ReviewerBaselineDiff `
	-Encoding base64
$StaleReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $StaleReviewerPath -Encoding UTF8
$StaleReviewerFailure = Invoke-ExpectedFailure `
	-Pattern 'final_diff does not match' `
	-Action {
	& $LaunchScript -HandoffPath $StaleReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Stale tracked-only reviewer final diff is rejected' `
	-Passed $StaleReviewerFailure

$FabricatedReviewerPath = Join-Path $TestRoot 'reviewer-fabricated-final-diff.json'
$FabricatedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$FabricatedReviewer.run_id = 'test-reviewer-fabricated-final-diff'
$FabricatedReviewer.final_diff = New-NeutralEvidenceRecord `
	-Kind diff `
	-Provenance launcher `
	-Source 'fabricated-final-diff' `
	-Text "diff --git a/fabricated b/fabricated`n" `
	-Encoding base64
$FabricatedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $FabricatedReviewerPath -Encoding UTF8
$FabricatedReviewerFailure = Invoke-ExpectedFailure `
	-Pattern 'final_diff does not match' `
	-Action {
	& $LaunchScript -HandoffPath $FabricatedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Fabricated reviewer final diff is rejected' `
	-Passed $FabricatedReviewerFailure

$OmittedReviewerPath = Join-Path $TestRoot 'reviewer-omitted-final-diff.json'
$OmittedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$OmittedReviewer.run_id = 'test-reviewer-omitted-final-diff'
$OmittedReviewer.PSObject.Properties.Remove('final_diff')
$OmittedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $OmittedReviewerPath -Encoding UTF8
$OmittedReviewerFailure = Invoke-ExpectedFailure `
	-Pattern 'final_diff|required' `
	-Action {
	& $LaunchScript -HandoffPath $OmittedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Omitted reviewer final diff is rejected' `
	-Passed $OmittedReviewerFailure

$ArtifactMismatchPath = Join-Path $TestRoot 'reviewer-artifact-state-mismatch.json'
$ArtifactMismatch = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$ArtifactMismatch.run_id = 'test-reviewer-artifact-state-mismatch'
$ArtifactMismatch.artifact_state = New-NeutralEvidenceRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'mismatched-artifact-state' `
	-Text 'candidate ready' `
	-Encoding base64
$ArtifactMismatch | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ArtifactMismatchPath -Encoding UTF8
$ArtifactMismatchFailure = Invoke-ExpectedFailure `
	-Pattern 'artifact_state does not match' `
	-Action {
	& $LaunchScript -HandoffPath $ArtifactMismatchPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Mismatched reviewer artifact state is rejected' `
	-Passed $ArtifactMismatchFailure

$MismatchedReviewerPath = Join-Path $TestRoot 'reviewer-mapped-baseline-mismatch.json'
$MismatchedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$MismatchedReviewer.run_id = 'test-reviewer-mapped-baseline-mismatch'
$MismatchedReviewer.baseline_status = New-NeutralEvidenceRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'mismatched-baseline-status' `
	-Text ($ReviewerBaselineStatus + 'mismatch')
$MismatchedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $MismatchedReviewerPath -Encoding UTF8
$ReviewerBaselineMismatchFailure = Invoke-ExpectedFailure `
	-Pattern 'baseline_status' `
	-Action {
	& $LaunchScript -HandoffPath $MismatchedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Rehashed reviewer baseline mismatch is rejected before child launch' `
	-Passed $ReviewerBaselineMismatchFailure

$WorkerBaselineStatus = Invoke-TestGitText `
	-Arguments 'status --short --untracked-files=all'
$WorkerBaselineDiff = Invoke-TestGitText -Arguments 'diff --binary --no-ext-diff'
$WorkerHandoffPath = Join-Path $TestRoot 'worker.json'
@{
	schema_version = 1
	stage = 'worker'
	run_id = 'test-worker'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return a unified diff.'
	work_package = 'Propose an AGENTS.md change.'
	allowed_paths = @('AGENTS.md')
	non_goals = @('Everything else')
	required_checks = @('git diff --check')
	baseline_status = $WorkerBaselineStatus
	baseline_diff = $WorkerBaselineDiff
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WorkerHandoffPath -Encoding UTF8

$MismatchedWorkerPath = Join-Path $TestRoot 'worker-baseline-mismatch.json'
$MismatchedWorker = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
$MismatchedWorker.run_id = 'test-worker-baseline-mismatch'
$MismatchedWorker.baseline_status = ([string]$MismatchedWorker.baseline_status) + 'mismatch'
$MismatchedWorker | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $MismatchedWorkerPath -Encoding UTF8
$BaselineMismatchFailure = Invoke-ExpectedFailure -Pattern 'baseline_status' -Action {
	& $LaunchScript -HandoffPath $MismatchedWorkerPath -DryRun | Out-Null
}
Add-Result -Name 'Baseline mismatch is rejected before child launch' -Passed $BaselineMismatchFailure

$FixtureBin = Join-Path $TestRoot 'fixture-bin'
New-Item -ItemType Directory -Path $FixtureBin | Out-Null
$FixtureCodexPath = Join-Path $FixtureBin 'codex.exe'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

public static class FixtureCodex
{
	public static int Main(string[] args)
	{
		string outputPath = null;
		for (int index = 0; index < args.Length - 1; index++)
		{
			if (args[index] == "--output-last-message")
			{
				outputPath = args[index + 1];
				break;
			}
		}

		string scenario = Environment.GetEnvironmentVariable("DELIVERY_FIXTURE_SCENARIO");
		if (scenario == "nonzero")
		{
			Console.Error.WriteLine("NONZERO_FIXTURE_STDERR_DIAGNOSTIC");
			return 23;
		}
		if (scenario == "missing-output")
		{
			return 0;
		}
		if (scenario == "malformed-event")
		{
			string malformedOutput = "{\"stage\":\"worker\",\"status\":\"blocked\"," +
				"\"summary\":\"fixture blocked\",\"evidence\":[],\"changed_paths\":[]," +
				"\"findings\":[],\"artifact\":\"\"}";
			File.WriteAllText(outputPath, malformedOutput, new UTF8Encoding(false));
			Console.WriteLine("MALFORMED_EVENT_FIXTURE");
			return 0;
		}

		string status = scenario == "blocked" ? "blocked" :
			scenario == "failed" ? "failed" : "passed";
		string summary = "fixture " + status;
		string output = "{\"stage\":\"worker\",\"status\":\"" + status +
			"\",\"summary\":\"" + summary +
			"\",\"evidence\":[],\"changed_paths\":[],\"findings\":[],\"artifact\":\"\"}";
		File.WriteAllText(outputPath, output, new UTF8Encoding(false));
		Console.Error.WriteLine("IGNORED_FIXTURE_DIAGNOSTIC");
		Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}");
		Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{" +
			"\"input_tokens\":100,\"cached_input_tokens\":40," +
			"\"cache_write_input_tokens\":0,\"output_tokens\":20," +
			"\"reasoning_output_tokens\":5}}");
		return 0;
	}
}
'@ -OutputAssembly $FixtureCodexPath -OutputType ConsoleApplication

function Invoke-FailureEvidenceCase {
	param(
		[Parameter(Mandatory)]
		[string]$Scenario,

		[Parameter(Mandatory)]
		[string]$ExpectedError,

		[Parameter(Mandatory)]
		[int]$ExpectedFileCount,

		[Parameter(Mandatory)]
		[bool]$ExpectOutput
	)

	$RunId = "test-worker-$Scenario"
	$HandoffPath = Join-Path $TestRoot "$RunId.json"
	$Handoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
	$Handoff.run_id = $RunId
	$Handoff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $HandoffPath -Encoding UTF8
	$ArtifactRoot = Join-Path $TestRoot "$RunId-artifacts"
	$AuditPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-audit.json"
	$ManifestPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-evidence.json"
	$OutputPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-output.json"
	$StandardErrorPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-stderr.log"
	$PatchPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-candidate.patch"
	$OriginalPath = $env:PATH
	$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
	$ErrorMessage = $null
	try {
		$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $Scenario
		try {
			& $LaunchScript `
				-HandoffPath $HandoffPath `
				-ArtifactRoot $ArtifactRoot | Out-Null
		}
		catch {
			$ErrorMessage = $_.Exception.Message
		}
	}
	finally {
		$env:PATH = $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
	}

	$AuditExists = Test-Path -LiteralPath $AuditPath -PathType Leaf
	$ManifestExists = Test-Path -LiteralPath $ManifestPath -PathType Leaf
	$Manifest = if ($ManifestExists) {
		Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
	}
	else {
		$null
	}
	$Audit = if ($AuditExists) {
		Get-Content -Raw -LiteralPath $AuditPath | ConvertFrom-Json
	}
	else {
		$null
	}
	$StandardError = if (Test-Path -LiteralPath $StandardErrorPath -PathType Leaf) {
		Get-Content -Raw -LiteralPath $StandardErrorPath
	}
	$ManifestFiles = @($Manifest.Files)
	$OnlyExistingEvidence = $ManifestExists -and @(
		$ManifestFiles | Where-Object {
			-not (Test-Path -LiteralPath $_.Path -PathType Leaf)
		}
	).Count -eq 0

	$StandardErrorPassed = if ($Scenario -eq 'nonzero') {
		$StandardError -match 'NONZERO_FIXTURE_STDERR_DIAGNOSTIC' -and
		$ErrorMessage -notmatch 'NONZERO_FIXTURE_STDERR_DIAGNOSTIC' -and
		[string]$Audit.StandardErrorPath -eq $StandardErrorPath -and
		@($ManifestFiles | Where-Object { $_.Path -eq $StandardErrorPath }).Count -eq 1 -and
		(Get-Item -LiteralPath $StandardErrorPath -Force).IsReadOnly
	}
	else {
		$true
	}

	return [pscustomobject]@{
		Passed = (
			$ErrorMessage -match $ExpectedError -and
			$AuditExists -and
			$ManifestExists -and
			$OnlyExistingEvidence -and
			$ManifestFiles.Count -eq $ExpectedFileCount -and
			(Test-Path -LiteralPath $OutputPath -PathType Leaf) -eq $ExpectOutput -and
			-not (Test-Path -LiteralPath $PatchPath) -and
			@($ManifestFiles | Where-Object { $_.Path -eq $PatchPath }).Count -eq 0 -and
			$StandardErrorPassed
		)
		Detail = $ErrorMessage
	}
}

$FailureEvidenceCases = @(
	@('blocked', "reported status 'blocked': fixture blocked", 5, $true,
		'Blocked writer preserves stage status and seals existing evidence'),
	@('failed', "reported status 'failed': fixture failed", 5, $true,
		'Failed writer preserves stage status and seals existing evidence'),
	@('nonzero', 'failed with exit code 23', 4, $false,
		'Nonzero child exit preserves primary error and seals existing evidence'),
	@('missing-output', 'output artifact.+was not created', 4, $false,
		'Missing output preserves validation error and seals existing evidence'),
	@('passed-no-patch', 'returned no unified diff', 5, $true,
		'Passed writer without patch still fails closed')
)
foreach ($FailureEvidenceCase in $FailureEvidenceCases) {
	$FailureEvidenceResult = Invoke-FailureEvidenceCase `
		-Scenario $FailureEvidenceCase[0] `
		-ExpectedError $FailureEvidenceCase[1] `
		-ExpectedFileCount $FailureEvidenceCase[2] `
		-ExpectOutput $FailureEvidenceCase[3]
	Add-Result `
		-Name $FailureEvidenceCase[4] `
		-Passed $FailureEvidenceResult.Passed `
		-Detail $FailureEvidenceResult.Detail
}

try {
	$DryRun = & $LaunchScript -HandoffPath $WorkerHandoffPath -DryRun -PassThru
	$RequiredArguments = @(
		'--ephemeral',
		'--ignore-user-config',
		'--strict-config',
		'--disable',
		'apps',
		'--sandbox',
		'read-only',
		'mcp_servers={}',
		'web_search="disabled"'
	)
	$MissingArguments = @($RequiredArguments | Where-Object {
		$DryRun.Arguments -notcontains $_
	})

	Add-Result `
		-Name 'Artifact-producing worker is read-only' `
		-Passed (
			$MissingArguments.Count -eq 0 -and
			-not [string]::IsNullOrWhiteSpace($DryRun.PatchPath)
		) `
		-Detail ($MissingArguments -join ', ')
}
catch {
	Add-Result `
		-Name 'Artifact-producing worker is read-only' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$WorkerArtifactAliases = @(
	@('delivery-stage-test-worker-events.jsonl', 'event log'),
	@('delivery-stage-test-worker-evidence.json', 'evidence manifest'),
	@('delivery-stage-test-worker-candidate.patch', 'candidate patch')
)
foreach ($ArtifactAlias in $WorkerArtifactAliases) {
	$ArtifactAliasFailure = Invoke-ExpectedFailure `
		-Pattern 'resolve to the same path' `
		-Action {
			& $LaunchScript `
				-HandoffPath $WorkerHandoffPath `
				-OutputPath $ArtifactAlias[0] `
				-ArtifactRoot $AliasedArtifactRoot `
				-DryRun | Out-Null
		}
	Add-Result `
		-Name "Output collision with $($ArtifactAlias[1]) is rejected before launch" `
		-Passed $ArtifactAliasFailure
}

$LauncherTokens = $null
$LauncherParseErrors = $null
$LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile(
	$LaunchScript,
	[ref]$LauncherTokens,
	[ref]$LauncherParseErrors
)
$PatchWriterAst = $LauncherAst.Find({
	param($Node)
	$Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Node.Name -eq 'Write-CandidatePatchArtifact'
}, $true)
$PatchSerializationPassed = $false
$PatchSerializationDetail = ''
try {
	if ($LauncherParseErrors.Count -gt 0 -or $null -eq $PatchWriterAst) {
		throw 'Could not load the production candidate-patch serializer.'
	}

	Invoke-Expression $PatchWriterAst.Extent.Text
	$SerializedPatchPath = Join-Path $TestRoot 'serialized-candidate.patch'
	$SerializedPatch = "diff --git a/cafÃ© b/cafÃ©`n-no-newline`n+replacement"
	Write-CandidatePatchArtifact `
		-Path $SerializedPatchPath `
		-Content $SerializedPatch
	$SerializedBytes = [System.IO.File]::ReadAllBytes($SerializedPatchPath)
	$ExpectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($SerializedPatch)
	$PatchSerializationPassed = (
		[System.Convert]::ToBase64String($SerializedBytes) -ceq [System.Convert]::ToBase64String($ExpectedBytes) -and
		-not ($SerializedBytes.Length -ge 3 -and
			$SerializedBytes[0] -eq 0xEF -and
			$SerializedBytes[1] -eq 0xBB -and
			$SerializedBytes[2] -eq 0xBF) -and
		$SerializedBytes[$SerializedBytes.Length - 1] -ne 0x0A
	)
}
catch {
	$PatchSerializationDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Candidate patch serialization is BOM-free and preserves no terminal newline' `
	-Passed $PatchSerializationPassed `
	-Detail $PatchSerializationDetail

Add-Result `
	-Name 'Production launcher has no command override' `
	-Passed (-not (Get-Command $LaunchScript).Parameters.ContainsKey('CodexCommand'))

$LauncherSource = Get-Content -Raw -LiteralPath $LaunchScript
$MutationGateIndex = $LauncherSource.IndexOf('$ChangedPaths.Count -eq 0')
$ArtifactReadIndex = $LauncherSource.IndexOf(
	'Get-Content -Raw -LiteralPath $OutputPath'
)
Add-Result `
	-Name 'Mutation gate precedes stage-output consumption' `
	-Passed (
		$MutationGateIndex -ge 0 -and
		$ArtifactReadIndex -gt $MutationGateIndex
	)

$EvidenceFile = Join-Path $TestRoot 'evidence-output.json'
$EvidenceManifest = Join-Path $TestRoot 'evidence-manifest.json'
Set-Content -LiteralPath $EvidenceFile -Value '{"result":"fixture"}' -Encoding UTF8

$InvalidEvidenceCases = @(
	[pscustomobject]@{
		Name = 'Blank declared evidence path is rejected'
		Path = ' '
		Pattern = 'must not be blank'
	},
	[pscustomobject]@{
		Name = 'Missing declared evidence path is rejected'
		Path = Join-Path $TestRoot 'missing-evidence.json'
		Pattern = 'does not exist'
	},
	[pscustomobject]@{
		Name = 'Non-file declared evidence path is rejected'
		Path = $TestRoot
		Pattern = 'not a file'
	}
)
foreach ($InvalidEvidenceCase in $InvalidEvidenceCases) {
	$RejectedManifest = Join-Path $TestRoot (
		[guid]::NewGuid().ToString('N') + '-rejected-manifest.json'
	)
	$InvalidEvidenceRejected = Invoke-ExpectedFailure `
		-Pattern $InvalidEvidenceCase.Pattern `
		-Action {
			& $EvidenceProtectionScript `
				-EvidencePaths @($EvidenceFile, $InvalidEvidenceCase.Path) `
				-ManifestPath $RejectedManifest `
				-HandoffHash ('a' * 64) | Out-Null
		}
	Add-Result `
		-Name $InvalidEvidenceCase.Name `
		-Passed ($InvalidEvidenceRejected -and -not (Test-Path -LiteralPath $RejectedManifest))
}

$EvidenceProtection = & $EvidenceProtectionScript `
	-EvidencePaths @($EvidenceFile) `
	-ManifestPath $EvidenceManifest `
	-HandoffHash ('a' * 64)
$EvidenceValidation = & $EvidenceValidationScript `
	-ManifestPath $EvidenceManifest `
	-ExpectedManifestHash $EvidenceProtection.ManifestHash `
	-ExpectedHandoffHash ('a' * 64)
$EvidenceOverwriteRejected = Invoke-ExpectedFailure -Pattern 'read-only|access|denied' -Action {
	Set-Content -LiteralPath $EvidenceFile -Value 'tampered' -ErrorAction Stop
}
$EvidenceManifestContent = Get-Content -Raw -LiteralPath $EvidenceManifest | ConvertFrom-Json
Add-Result `
	-Name 'Evidence files are hash-bound and read-only' `
	-Passed (
		$EvidenceOverwriteRejected -and
		(Get-Item -LiteralPath $EvidenceFile).IsReadOnly -and
		(Get-Item -LiteralPath $EvidenceManifest).IsReadOnly -and
		$EvidenceValidation.FileCount -eq 1 -and
		$EvidenceManifestContent.Files[0].Sha256 -eq (
			Get-FileHash -LiteralPath $EvidenceFile -Algorithm SHA256
		).Hash.ToLowerInvariant()
	)

$WrongHandoffRejected = Invoke-ExpectedFailure -Pattern 'different handoff' -Action {
	& $EvidenceValidationScript `
		-ManifestPath $EvidenceManifest `
		-ExpectedManifestHash $EvidenceProtection.ManifestHash `
		-ExpectedHandoffHash ('b' * 64) | Out-Null
}
Add-Result `
	-Name 'Evidence from another handoff is rejected' `
	-Passed $WrongHandoffRejected

$EvidenceItem = Get-Item -LiteralPath $EvidenceFile -Force
$EvidenceItem.IsReadOnly = $false
Set-Content -LiteralPath $EvidenceFile -Value 'tampered' -Encoding UTF8
$EvidenceItem = Get-Item -LiteralPath $EvidenceFile -Force
$EvidenceItem.IsReadOnly = $true
$EvidenceTamperDetected = Invoke-ExpectedFailure -Pattern 'manifest hash' -Action {
	& $EvidenceValidationScript `
		-ManifestPath $EvidenceManifest `
		-ExpectedManifestHash $EvidenceProtection.ManifestHash `
		-ExpectedHandoffHash ('a' * 64) | Out-Null
}
Add-Result `
	-Name 'Evidence manifest detects attribute-bypass tampering' `
	-Passed $EvidenceTamperDetected

$MutationSentinelPath = Join-Path (
	$ScriptRoot
) 'tests\fixtures\mutation-sentinel.txt'
$SentinelBytes = [System.IO.File]::ReadAllBytes($MutationSentinelPath)
$SentinelTimestamp = (Get-Item -LiteralPath $MutationSentinelPath).LastWriteTimeUtc
$BeforeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$MutationDetected = $false
try {
	$ReplacementBytes = [byte[]]::new($SentinelBytes.Length)
	for ($Index = 0; $Index -lt $ReplacementBytes.Length; $Index++) {
		$ReplacementBytes[$Index] = [byte][char]'x'
	}
	[System.IO.File]::WriteAllBytes($MutationSentinelPath, $ReplacementBytes)
	[System.IO.File]::SetLastWriteTimeUtc($MutationSentinelPath, $SentinelTimestamp)
	$AfterMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
	$MutationDetected = (
		$BeforeMutation.Hash -ne $AfterMutation.Hash -and
		$BeforeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		] -ne $AfterMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		]
	)
}
finally {
	[System.IO.File]::WriteAllBytes($MutationSentinelPath, $SentinelBytes)
	[System.IO.File]::SetLastWriteTimeUtc($MutationSentinelPath, $SentinelTimestamp)
}
Add-Result -Name 'Snapshot detects same-length timestamp-restored mutation' -Passed $MutationDetected

$BeforeAttributeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$OriginalReadOnly = (Get-Item -LiteralPath $MutationSentinelPath -Force).IsReadOnly
$AttributeMutationDetected = $false
try {
	$MutationSentinelItem = Get-Item -LiteralPath $MutationSentinelPath -Force
	$MutationSentinelItem.IsReadOnly = -not $OriginalReadOnly
	$AfterAttributeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
	$AttributeMutationDetected = (
		$BeforeAttributeMutation.Hash -ne $AfterAttributeMutation.Hash -and
		$BeforeAttributeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		] -ne $AfterAttributeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		]
	)
}
finally {
	$MutationSentinelItem = Get-Item -LiteralPath $MutationSentinelPath -Force
	$MutationSentinelItem.IsReadOnly = $OriginalReadOnly
}
Add-Result `
	-Name 'Snapshot detects metadata-only read-only attribute mutation' `
	-Passed $AttributeMutationDetected

$OutOfScopePatchPath = Join-Path $TestRoot 'out-of-scope.patch'
@'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-before
+after
'@ | Set-Content -LiteralPath $OutOfScopePatchPath -Encoding UTF8
$OutOfScopeFailure = Invoke-ExpectedFailure -Pattern 'outside allowed paths|invalid artifact' -Action {
	& $PatchValidationScript `
		-PatchPath $OutOfScopePatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('AGENTS.md') | Out-Null
}
Add-Result -Name 'Out-of-scope candidate patch is rejected' -Passed $OutOfScopeFailure

$OutOfScopeRenamePatchPath = Join-Path $TestRoot 'out-of-scope-rename.patch'
@'
diff --git a/README.md b/.delivery-scope/renamed-readme.md
similarity index 100%
rename from README.md
rename to .delivery-scope/renamed-readme.md
'@ | Set-Content -LiteralPath $OutOfScopeRenamePatchPath -Encoding UTF8
$OutOfScopeRenameFailure = Invoke-ExpectedFailure `
	-Pattern 'rename or copy metadata.*delete and add patches' `
	-Action {
		& $PatchValidationScript `
			-PatchPath $OutOfScopeRenamePatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('.delivery-scope/**') | Out-Null
	}
Add-Result `
	-Name 'Out-of-scope rename source is rejected' `
	-Passed $OutOfScopeRenameFailure

$PatchValidatorSource = Get-Content -Raw -LiteralPath $PatchValidationScript
Add-Result `
	-Name 'Patch paths use binary-safe Git output capture' `
	-Passed (
		$PatchValidatorSource -match 'StandardOutput\.BaseStream\.CopyToAsync' -and
		$PatchValidatorSource -match '--numstat -z'
	)

$WildcardPatchPath = Join-Path $TestRoot 'wildcard-scope.patch'
@'
diff --git a/.delivery-scope/child/file.txt b/.delivery-scope/child/file.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/child/file.txt
@@ -0,0 +1 @@
+fixture
'@ | Set-Content -LiteralPath $WildcardPatchPath -Encoding UTF8

$AllowedScopeCases = @(
	@('.delivery-scope/child/file.txt', 'exact'),
	@('.delivery-scope', 'directory'),
	@('.delivery-scope/*/file.txt', 'single wildcard'),
	@('.delivery-scope/**', 'recursive wildcard')
)
foreach ($ScopeCase in $AllowedScopeCases) {
	try {
		& $PatchValidationScript `
			-PatchPath $WildcardPatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @($ScopeCase[0]) | Out-Null
		$ScopePassed = $true
	}
	catch {
		$ScopePassed = $false
	}
	Add-Result `
		-Name "Safe $($ScopeCase[1]) scope is accepted" `
		-Passed $ScopePassed
}

$SingleWildcardFailure = Invoke-ExpectedFailure -Pattern 'outside allowed paths' -Action {
	& $PatchValidationScript `
		-PatchPath $WildcardPatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('.delivery-scope/*') | Out-Null
}
Add-Result `
	-Name 'Single wildcard does not cross directories' `
	-Passed $SingleWildcardFailure

$UnsafeAllowedScopes = @(
	@('../.delivery-scope/**', 'traversal'),
	@((Join-Path $RepositoryRoot '.delivery-scope'), 'absolute'),
	@('.delivery-scope/*.txt', 'partial wildcard'),
	@('.delivery-scope/***', 'unsupported wildcard')
)
foreach ($ScopeCase in $UnsafeAllowedScopes) {
	$UnsafeScopeFailure = Invoke-ExpectedFailure `
		-Pattern 'unsafe|unsupported wildcard' `
		-Action {
			& $PatchValidationScript `
				-PatchPath $WildcardPatchPath `
				-WorkspaceRoot $RepositoryRoot `
				-AllowedPaths @($ScopeCase[0]) | Out-Null
		}
	Add-Result `
		-Name "Unsafe $($ScopeCase[1]) scope is rejected" `
		-Passed $UnsafeScopeFailure
}

$SafeFirstUnsafeSecondFailure = Invoke-ExpectedFailure -Pattern 'unsafe' -Action {
	& $PatchValidationScript `
		-PatchPath $WildcardPatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @(
			'.delivery-scope/**',
			'../.delivery-scope/**'
		) | Out-Null
}
Add-Result `
	-Name 'Unsafe later scope is rejected after an earlier matching scope' `
	-Passed $SafeFirstUnsafeSecondFailure

$CompleteEventPath = Join-Path $TestRoot 'complete-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-123","extra":"ignored"}
{"type":"item.completed","item":{"type":"agent_message","text":"private payload"}}
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":4,"output_tokens":25,"reasoning_output_tokens":5},"extra":"ignored"}
'@ | Set-Content -LiteralPath $CompleteEventPath -Encoding UTF8
$CompleteTelemetry = & $EventTelemetryScript -EventLogPath $CompleteEventPath
Add-Result `
	-Name 'Complete event telemetry is parsed from observed values' `
	-Passed (
		$CompleteTelemetry.SessionId -eq 'session-123' -and
		$CompleteTelemetry.InputTokens -eq 100 -and
		$CompleteTelemetry.CachedInputTokens -eq 60 -and
		$CompleteTelemetry.CacheWriteInputTokens -eq 4 -and
		$CompleteTelemetry.OutputTokens -eq 25 -and
		$CompleteTelemetry.ReasoningOutputTokens -eq 5 -and
		$CompleteTelemetry.TotalTokens -eq 125 -and
		$null -eq $CompleteTelemetry.Model -and
		$null -eq $CompleteTelemetry.ReasoningTier
	)

$MissingUsagePath = Join-Path $TestRoot 'missing-usage-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-missing"}
{"type":"turn.completed"}
'@ | Set-Content -LiteralPath $MissingUsagePath -Encoding UTF8
$MissingTelemetry = & $EventTelemetryScript -EventLogPath $MissingUsagePath
Add-Result `
	-Name 'Missing usage remains null' `
	-Passed (
		$MissingTelemetry.SessionId -eq 'session-missing' -and
		$null -eq $MissingTelemetry.InputTokens -and
		$null -eq $MissingTelemetry.CachedInputTokens -and
		$null -eq $MissingTelemetry.CacheWriteInputTokens -and
		$null -eq $MissingTelemetry.OutputTokens -and
		$null -eq $MissingTelemetry.ReasoningOutputTokens -and
		$null -eq $MissingTelemetry.TotalTokens
	)

$LastTurnPath = Join-Path $TestRoot 'last-turn-events.jsonl'
@'
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}
'@ | Set-Content -LiteralPath $LastTurnPath -Encoding UTF8
$LastTurnTelemetry = & $EventTelemetryScript -EventLogPath $LastTurnPath
Add-Result `
	-Name 'Last completed turn usage wins' `
	-Passed (
		$LastTurnTelemetry.InputTokens -eq 10 -and
		$LastTurnTelemetry.OutputTokens -eq 20 -and
		$LastTurnTelemetry.TotalTokens -eq 30
	)

$MalformedEventPath = Join-Path $TestRoot 'malformed-events.jsonl'
'{"type":"thread.started"' | Set-Content -LiteralPath $MalformedEventPath -Encoding UTF8
$MalformedEventFailure = Invoke-ExpectedFailure -Pattern 'not valid JSON' -Action {
	& $EventTelemetryScript -EventLogPath $MalformedEventPath | Out-Null
}
Add-Result -Name 'Malformed JSON event is rejected' -Passed $MalformedEventFailure

$ConflictingThreadPath = Join-Path $TestRoot 'conflicting-thread-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-one"}
{"type":"thread.started","thread_id":"session-two"}
'@ | Set-Content -LiteralPath $ConflictingThreadPath -Encoding UTF8
$ConflictingThreadFailure = Invoke-ExpectedFailure -Pattern 'conflicting nonempty thread IDs' -Action {
	& $EventTelemetryScript -EventLogPath $ConflictingThreadPath | Out-Null
}
Add-Result `
	-Name 'Conflicting thread IDs are rejected' `
	-Passed $ConflictingThreadFailure

$InvalidTokenCases = @(
	@('negative', '-1'),
	@('non-integral', '1.5')
)
foreach ($InvalidTokenCase in $InvalidTokenCases) {
	$InvalidTokenPath = Join-Path $TestRoot "$($InvalidTokenCase[0])-token-events.jsonl"
	("{`"type`":`"turn.completed`",`"usage`":{`"input_tokens`":$($InvalidTokenCase[1])}}") |
		Set-Content -LiteralPath $InvalidTokenPath -Encoding UTF8
	$InvalidTokenFailure = Invoke-ExpectedFailure `
		-Pattern 'token observations must be non-negative integers' `
		-Action {
			& $EventTelemetryScript -EventLogPath $InvalidTokenPath | Out-Null
		}
	Add-Result `
		-Name "$($InvalidTokenCase[0]) token observation is rejected" `
		-Passed $InvalidTokenFailure
}

$WrongTypeCases = @(
	@('event type', '{"type":42}', "invalid 'type'"),
	@('thread ID', '{"type":"thread.started","thread_id":42}', "invalid 'thread_id'"),
	@('usage', '{"type":"turn.completed","usage":[]}', "invalid 'usage'"),
	@('token', '{"type":"turn.completed","usage":{"output_tokens":"25"}}', "non-numeric 'output_tokens'")
)
foreach ($WrongTypeCase in $WrongTypeCases) {
	$WrongTypePath = Join-Path $TestRoot (
		'wrong-' + ($WrongTypeCase[0] -replace ' ', '-') + '-events.jsonl'
	)
	$WrongTypeCase[1] | Set-Content -LiteralPath $WrongTypePath -Encoding UTF8
	$WrongTypeFailure = Invoke-ExpectedFailure -Pattern $WrongTypeCase[2] -Action {
		& $EventTelemetryScript -EventLogPath $WrongTypePath | Out-Null
	}
	Add-Result `
		-Name "Wrong $($WrongTypeCase[0]) type is rejected" `
		-Passed $WrongTypeFailure
}

$LeakingEventPath = Join-Path $TestRoot 'payload-leak-events.jsonl'
@'
{"type":"item.started","item":{"type":"command_execution","command":"do-not-expose-command"}}
{"type":"item.completed","item":{"type":"agent_message","text":"do-not-expose-message"}}
'@ | Set-Content -LiteralPath $LeakingEventPath -Encoding UTF8
$LeakingTelemetryJson = & $EventTelemetryScript -EventLogPath $LeakingEventPath |
	ConvertTo-Json -Compress
Add-Result `
	-Name 'Event payload text is not exposed' `
	-Passed (
		$LeakingTelemetryJson -notmatch 'do-not-expose-command' -and
		$LeakingTelemetryJson -notmatch 'do-not-expose-message'
	)

function Get-FixtureTelemetry {
	param([Parameter(Mandatory)][string]$RunId)

	$ArtifactRoot = Join-Path $TestRoot "$RunId-artifacts"
	$AuditPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-audit.json"
	$Audit = Get-Content -Raw -LiteralPath $AuditPath | ConvertFrom-Json
	$TelemetryPath = [string]$Audit.TelemetryPath
	$TelemetryExists = -not [string]::IsNullOrWhiteSpace($TelemetryPath) -and
		(Test-Path -LiteralPath $TelemetryPath -PathType Leaf)
	$Telemetry = if ($TelemetryExists) {
		Get-Content -Raw -LiteralPath $TelemetryPath | ConvertFrom-Json
	} else {
		$null
	}
	$ManifestPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-evidence.json"
	return [pscustomobject]@{
		RunId = $RunId
		ArtifactRoot = $ArtifactRoot
		AuditPath = $AuditPath
		Audit = $Audit
		TelemetryPath = $TelemetryPath
		TelemetryExists = $TelemetryExists
		Telemetry = $Telemetry
		ManifestPath = $ManifestPath
		Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
	}
}

$TelemetryRootProperties = @(
	'SchemaVersion', 'RunId', 'Ticket', 'Stage', 'SourceCommit', 'HandoffHash',
	'BeforeSnapshotHash', 'AfterSnapshotHash', 'StartedAtUtc', 'EndedAtUtc',
	'DurationMilliseconds', 'AttemptOrdinal', 'AttemptClass', 'CapabilityClass',
	'RetryCause', 'Limits', 'SessionId', 'Model', 'ReasoningTier', 'InputTokens',
	'CachedInputTokens', 'CacheWriteInputTokens', 'OutputTokens',
	'ReasoningOutputTokens', 'TotalTokens', 'ExitClass', 'ChangedPathCount',
	'ProposedPathCount', 'OutputBytes', 'PatchBytes', 'StageStatus',
	'EvidenceManifestPath', 'EvidenceManifestHash', 'TelemetryError'
)
$TelemetryLimitsProperties = @(
	'TotalTokens', 'ElapsedMilliseconds', 'ConcurrentStages', 'ExecutionRetries',
	'FixCycles', 'Provenance', 'ApprovedAtUtc'
)

$BlockedTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-blocked'
$BlockedTelemetry = $BlockedTelemetryFixture.Telemetry
$BlockedAudit = $BlockedTelemetryFixture.Audit
$BlockedTelemetryPath = $BlockedTelemetryFixture.TelemetryPath
$BlockedEventLog = Get-Content -Raw -LiteralPath ([string]$BlockedAudit.EventLogPath)
$BlockedManifestTelemetryEntries = @($BlockedTelemetryFixture.Manifest.Files |
	Where-Object { [string]$_.Path -eq $BlockedTelemetryPath })
Add-Result `
	-Name 'Blocked launch exposes distinct telemetry with observed usage' `
	-Passed (
		$BlockedTelemetryFixture.TelemetryExists -and
		@(
			$BlockedTelemetryFixture.AuditPath,
			[string]$BlockedAudit.EventLogPath,
			(Join-Path $BlockedTelemetryFixture.ArtifactRoot 'delivery-stage-test-worker-blocked-output.json'),
			$BlockedTelemetryFixture.ManifestPath
		) -notcontains $BlockedTelemetryPath -and
		$BlockedEventLog -notmatch 'IGNORED_FIXTURE_DIAGNOSTIC' -and
		$BlockedTelemetry.SessionId -eq 'fixture-session' -and
		$BlockedTelemetry.InputTokens -eq 100 -and
		$BlockedTelemetry.CachedInputTokens -eq 40 -and
		$BlockedTelemetry.CacheWriteInputTokens -eq 0 -and
		$BlockedTelemetry.OutputTokens -eq 20 -and
		$BlockedTelemetry.ReasoningOutputTokens -eq 5 -and
		$BlockedTelemetry.TotalTokens -eq 120
	)

Add-Result `
	-Name 'Telemetry receives default execution policy' `
	-Passed (
		$BlockedTelemetry.AttemptOrdinal -eq 1 -and
		$BlockedTelemetry.AttemptClass -eq 'initial' -and
		$BlockedTelemetry.CapabilityClass -eq 'standard' -and
		$null -eq $BlockedTelemetry.RetryCause -and
		@($BlockedTelemetry.Limits.PSObject.Properties.Value |
			Where-Object { $null -ne $_ }).Count -eq 0
	)

$ObservedTelemetryProperties = [string]::Join(
	'|', [string[]]@($BlockedTelemetry.PSObject.Properties.Name)
)
$ExpectedTelemetryProperties = [string]::Join('|', [string[]]$TelemetryRootProperties)
$ObservedLimitsProperties = [string]::Join(
	'|', [string[]]@($BlockedTelemetry.Limits.PSObject.Properties.Name)
)
$ExpectedLimitsProperties = [string]::Join('|', [string[]]$TelemetryLimitsProperties)
Add-Result `
	-Name 'Telemetry schema has exact ordered properties' `
	-Passed (
		$BlockedTelemetry.SchemaVersion -eq 1 -and
		$ObservedTelemetryProperties -ceq $ExpectedTelemetryProperties -and
		$ObservedLimitsProperties -ceq $ExpectedLimitsProperties
	)

Add-Result `
	-Name 'Telemetry records bounded metadata and nullable unavailable values' `
	-Passed (
		[string]$BlockedTelemetry.RunId -eq 'test-worker-blocked' -and
		[string]$BlockedTelemetry.Ticket -eq 'Issue #123' -and
		[string]$BlockedTelemetry.Stage -eq 'worker' -and
		[string]$BlockedTelemetry.StartedAtUtc -cmatch 'Z$' -and
		[string]$BlockedTelemetry.EndedAtUtc -cmatch 'Z$' -and
		$BlockedTelemetry.DurationMilliseconds -ge 0 -and
		$BlockedTelemetry.ChangedPathCount -ge 0 -and
		$BlockedTelemetry.ProposedPathCount -ge 0 -and
		$null -eq $BlockedTelemetry.Model -and
		$null -eq $BlockedTelemetry.ReasoningTier -and
		$BlockedTelemetry.OutputBytes -gt 0 -and
		$null -eq $BlockedTelemetry.PatchBytes -and
		[string]$BlockedTelemetry.StageStatus -eq 'blocked' -and
		$null -eq $BlockedTelemetry.EvidenceManifestHash
	)

Add-Result `
	-Name 'Telemetry is hash-bound and read-only evidence' `
	-Passed (
		$BlockedManifestTelemetryEntries.Count -eq 1 -and
		$BlockedManifestTelemetryEntries[0].Sha256 -eq (
			Get-FileHash -LiteralPath $BlockedTelemetryPath -Algorithm SHA256
		).Hash.ToLowerInvariant() -and
		(Get-Item -LiteralPath $BlockedTelemetryPath -Force).IsReadOnly -and
		[string]$BlockedTelemetry.EvidenceManifestPath -eq $BlockedTelemetryFixture.ManifestPath
	)

$NonzeroTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-nonzero'
$NonzeroTelemetry = $NonzeroTelemetryFixture.Telemetry
Add-Result `
	-Name 'Nonzero child produces telemetry with unavailable observations null' `
	-Passed (
		$NonzeroTelemetryFixture.TelemetryExists -and
		$null -eq $NonzeroTelemetry.SessionId -and
		$null -eq $NonzeroTelemetry.InputTokens -and
		$null -eq $NonzeroTelemetry.CachedInputTokens -and
		$null -eq $NonzeroTelemetry.CacheWriteInputTokens -and
		$null -eq $NonzeroTelemetry.OutputTokens -and
		$null -eq $NonzeroTelemetry.ReasoningOutputTokens -and
		$null -eq $NonzeroTelemetry.TotalTokens -and
		$null -eq $NonzeroTelemetry.OutputBytes -and
		$null -eq $NonzeroTelemetry.PatchBytes
	)

$MalformedFixtureResult = Invoke-FailureEvidenceCase `
	-Scenario 'malformed-event' `
	-ExpectedError "reported status 'blocked': fixture blocked" `
	-ExpectedFileCount 5 `
	-ExpectOutput $true
$MalformedTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-malformed-event'
$MalformedTelemetry = $MalformedTelemetryFixture.Telemetry
Add-Result `
	-Name 'Malformed event is sanitized without replacing the blocked primary error' `
	-Passed (
		$MalformedFixtureResult.Passed -and
		$MalformedTelemetryFixture.TelemetryExists -and
		-not [string]::IsNullOrWhiteSpace([string]$MalformedTelemetry.TelemetryError) -and
		[string]$MalformedTelemetry.TelemetryError -notmatch 'MALFORMED_EVENT_FIXTURE' -and
		$null -eq $MalformedTelemetry.SessionId -and
		$null -eq $MalformedTelemetry.InputTokens -and
		$null -eq $MalformedTelemetry.CachedInputTokens -and
		$null -eq $MalformedTelemetry.CacheWriteInputTokens -and
		$null -eq $MalformedTelemetry.OutputTokens -and
		$null -eq $MalformedTelemetry.ReasoningOutputTokens -and
		$null -eq $MalformedTelemetry.TotalTokens
	) `
	-Detail $MalformedFixtureResult.Detail

function New-EfficiencyFixture {
	param(
		[Parameter(Mandatory)][string]$Name,
		[AllowNull()][object]$Tokens,
		[string]$CriteriaVersion = 'issue-70-quality-v1',
		[string]$EnvironmentId = 'local-windows',
		[bool]$QualityPassed = $true
	)

	$Path = Join-Path $TestRoot "$Name.json"
	[ordered]@{
		schema_version = 1
		quality_criteria_version = $CriteriaVersion
		environment_id = $EnvironmentId
		total_tokens = $Tokens
		quality = [ordered]@{
			mandatory_checks_passed = $QualityPassed
			attestations_passed = $true
			acceptance_evidence_complete = $true
			unresolved_material_findings = 0
			approval_passed = $true
		}
	} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
	return $Path
}

$EfficiencyBaselinePath = New-EfficiencyFixture -Name 'efficiency-baseline' -Tokens 100
$EfficiencyClassificationCases = @(
	@('improved', 80, 'improved', -20),
	@('equal', 100, 'not_improved', 0),
	@('greater', 120, 'not_improved', 20)
)
foreach ($Case in $EfficiencyClassificationCases) {
	$CandidatePath = New-EfficiencyFixture `
		-Name "efficiency-$($Case[0])" `
		-Tokens $Case[1]
	$Comparison = & $EfficiencyComparisonScript `
		-BaselinePath $EfficiencyBaselinePath `
		-CandidatePath $CandidatePath
	Add-Result `
		-Name "Efficiency comparison classifies $($Case[0]) tokens" `
		-Passed (
			$Comparison.Classification -eq $Case[2] -and
			$Comparison.BaselineQualityPassed -and
			$Comparison.CandidateQualityPassed -and
			$Comparison.BaselineTotalTokens -eq 100 -and
			$Comparison.CandidateTotalTokens -eq $Case[1] -and
			$Comparison.TokenDelta -eq $Case[3]
		)
}

foreach ($TokenMode in @('measured', 'missing')) {
	$RegressionBaselineTokens = if ($TokenMode -eq 'measured') { 100 } else { $null }
	$RegressionCandidateTokens = if ($TokenMode -eq 'measured') { 50 } else { $null }
	$RegressionBaselinePath = New-EfficiencyFixture `
		-Name "regression-$TokenMode-baseline" `
		-Tokens $RegressionBaselineTokens
	$RegressionCandidatePath = New-EfficiencyFixture `
		-Name "regression-$TokenMode-candidate" `
		-Tokens $RegressionCandidateTokens `
		-QualityPassed $false
	$RegressionComparison = & $EfficiencyComparisonScript `
		-BaselinePath $RegressionBaselinePath `
		-CandidatePath $RegressionCandidatePath
	Add-Result `
		-Name "Quality regression takes precedence with $TokenMode tokens" `
		-Passed (
			$RegressionComparison.Classification -eq 'quality_regression' -and
			$RegressionComparison.BaselineQualityPassed -and
			-not $RegressionComparison.CandidateQualityPassed -and
			(
				($TokenMode -eq 'measured' -and $RegressionComparison.TokenDelta -eq -50) -or
				($TokenMode -eq 'missing' -and $null -eq $RegressionComparison.TokenDelta)
			)
		)
}

$NotMeasurableCases = @(
	@('environment mismatch', 'issue-70-quality-v1', 'development-linux', 90, $true),
	@('missing tokens', 'issue-70-quality-v1', 'local-windows', $null, $true),
	@('failing baseline quality', 'issue-70-quality-v1', 'local-windows', 90, $false)
)
foreach ($Case in $NotMeasurableCases) {
	if ($Case[0] -eq 'failing baseline quality') {
		$CaseBaselinePath = New-EfficiencyFixture `
			-Name 'failing-baseline' -Tokens 100 -QualityPassed $false
		$CaseCandidatePath = New-EfficiencyFixture `
			-Name 'failing-baseline-candidate' -Tokens $Case[3]
	} else {
		$CaseBaselinePath = $EfficiencyBaselinePath
		$CaseCandidatePath = New-EfficiencyFixture `
			-Name ('not-measurable-' + ($Case[0] -replace ' ', '-')) `
			-Tokens $Case[3] `
			-CriteriaVersion $Case[1] `
			-EnvironmentId $Case[2]
	}
	$NotMeasurableComparison = & $EfficiencyComparisonScript `
		-BaselinePath $CaseBaselinePath `
		-CandidatePath $CaseCandidatePath
	Add-Result `
		-Name "Efficiency comparison rejects $($Case[0])" `
		-Passed ($NotMeasurableComparison.Classification -eq 'not_measurable')
}

$WrongCandidateCriteriaPath = New-EfficiencyFixture `
	-Name 'wrong-candidate-criteria' `
	-Tokens 90 `
	-CriteriaVersion 'issue-70-quality-v2'
$WrongCandidateCriteriaRejected = Invoke-ExpectedFailure `
	-Pattern 'Candidate quality_criteria_version' `
	-Action {
	& $EfficiencyComparisonScript `
		-BaselinePath $EfficiencyBaselinePath `
		-CandidatePath $WrongCandidateCriteriaPath | Out-Null
}
Add-Result `
	-Name 'Efficiency comparison rejects a noncanonical candidate criteria version' `
	-Passed $WrongCandidateCriteriaRejected

$WrongCriteriaBaselinePath = New-EfficiencyFixture `
	-Name 'wrong-criteria-baseline' `
	-Tokens 100 `
	-CriteriaVersion 'anything'
$WrongCriteriaCandidatePath = New-EfficiencyFixture `
	-Name 'wrong-criteria-candidate' `
	-Tokens 90 `
	-CriteriaVersion 'anything'
$WrongCriteriaRejected = Invoke-ExpectedFailure -Pattern 'issue-70-quality-v1' -Action {
	& $EfficiencyComparisonScript `
		-BaselinePath $WrongCriteriaBaselinePath `
		-CandidatePath $WrongCriteriaCandidatePath | Out-Null
}
Add-Result `
	-Name 'Efficiency comparison rejects a shared noncanonical criteria version' `
	-Passed $WrongCriteriaRejected

$ExactOutputCandidatePath = New-EfficiencyFixture `
	-Name 'exact-output-candidate' -Tokens 90
$ExactOutput = & $EfficiencyComparisonScript `
	-BaselinePath $EfficiencyBaselinePath `
	-CandidatePath $ExactOutputCandidatePath
$ExpectedComparisonProperties = @(
	'Classification', 'BaselineQualityPassed', 'CandidateQualityPassed',
	'BaselineTotalTokens', 'CandidateTotalTokens', 'TokenDelta', 'Reason'
)
Add-Result `
	-Name 'Efficiency comparison output has exact ordered fields' `
	-Passed (
		[string]::Join('|', $ExactOutput.PSObject.Properties.Name) -ceq
		[string]::Join('|', $ExpectedComparisonProperties)
	)

$ValidEfficiencyJson = Get-Content -Raw -LiteralPath $EfficiencyBaselinePath |
	ConvertFrom-Json
$InvalidEfficiencyCases = @(
	@('unknown root field', 'root', 'unexpected', $true),
	@('missing root field', 'root', 'environment_id', $null),
	@('unknown quality field', 'quality', 'unexpected', $true),
	@('missing quality field', 'quality', 'approval_passed', $null),
	@('wrong schema type', 'root', 'schema_version', '1'),
	@('wrong criteria type', 'root', 'quality_criteria_version', 1),
	@('wrong environment type', 'root', 'environment_id', 1),
	@('wrong token type', 'root', 'total_tokens', '100'),
	@('wrong quality type', 'root', 'quality', @()),
	@('wrong boolean type', 'quality', 'mandatory_checks_passed', 'true'),
	@('negative tokens', 'root', 'total_tokens', -1),
	@('fractional tokens', 'root', 'total_tokens', 1.5),
	@('negative findings', 'quality', 'unresolved_material_findings', -1),
	@('fractional findings', 'quality', 'unresolved_material_findings', 1.5)
)
foreach ($Case in $InvalidEfficiencyCases) {
	$InvalidRecord = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$Target = if ($Case[1] -eq 'quality') { $InvalidRecord.quality } else { $InvalidRecord }
	if ($Case[0] -like 'missing*') {
		$Target.PSObject.Properties.Remove($Case[2])
	} elseif ($Case[0] -like 'unknown*') {
		$Target | Add-Member -NotePropertyName $Case[2] -NotePropertyValue $Case[3]
	} else {
		$Target.($Case[2]) = $Case[3]
	}
	$InvalidPath = Join-Path $TestRoot (
		'invalid-efficiency-' + ($Case[0] -replace ' ', '-') + '.json'
	)
	$InvalidRecord | ConvertTo-Json -Depth 4 | Set-Content `
		-LiteralPath $InvalidPath -Encoding UTF8
	$InvalidRejected = Invoke-ExpectedFailure -Pattern 'Baseline' -Action {
		& $EfficiencyComparisonScript `
			-BaselinePath $InvalidPath `
			-CandidatePath $ExactOutputCandidatePath | Out-Null
	}
	Add-Result `
		-Name "Efficiency input rejects $($Case[0])" `
		-Passed $InvalidRejected
}

$BlankStringCases = @('quality_criteria_version', 'environment_id')
foreach ($FieldName in $BlankStringCases) {
	$BlankRecord = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$BlankRecord.$FieldName = ' '
	$BlankPath = Join-Path $TestRoot "blank-$FieldName.json"
	$BlankRecord | ConvertTo-Json -Depth 4 | Set-Content `
		-LiteralPath $BlankPath -Encoding UTF8
	$BlankRejected = Invoke-ExpectedFailure -Pattern $FieldName -Action {
		& $EfficiencyComparisonScript `
			-BaselinePath $BlankPath `
			-CandidatePath $ExactOutputCandidatePath | Out-Null
	}
	Add-Result -Name "Efficiency input rejects blank $FieldName" -Passed $BlankRejected
}

$LeakMarker = 'do-not-expose-efficiency-payload'
$LeakingEfficiencyPath = Join-Path $TestRoot 'leaking-efficiency.json'
$LeakingEfficiency = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$LeakingEfficiency.quality.mandatory_checks_passed = $LeakMarker
$LeakingEfficiency | ConvertTo-Json -Depth 4 | Set-Content `
	-LiteralPath $LeakingEfficiencyPath -Encoding UTF8
$LeakError = ''
try {
	& $EfficiencyComparisonScript `
		-BaselinePath $LeakingEfficiencyPath `
		-CandidatePath $ExactOutputCandidatePath | Out-Null
}
catch {
	$LeakError = $_.Exception.Message
}
Add-Result `
	-Name 'Efficiency validation errors do not leak payload values' `
	-Passed (
		-not [string]::IsNullOrWhiteSpace($LeakError) -and
		$LeakError -notmatch [regex]::Escape($LeakMarker)
	)

$IndependentGateProfiles = @(
	@{ Name = 'verifier'; Path = '.codex\agents\delivery-verifier.toml' },
	@{ Name = 'reviewer'; Path = '.codex\agents\delivery-reviewer.toml' },
	@{ Name = 'approver'; Path = '.codex\agents\delivery-approver.toml' },
	@{ Name = 'adjudicator'; Path = '.codex\agents\delivery-adjudicator.toml' }
)
$NeutralInputMarkers = @(
	'ticket acceptance criteria',
	'non-goals',
	'required check commands',
	'output schema or contract',
	'required response labels',
	'raw machine-generated command and test logs',
	'normative neutral inputs',
	'not prior conclusions',
	'must not be rejected'
)
$PriorJudgmentMarkers = @(
	'prior agent-produced',
	'findings',
	'corrections',
	'outcome claims',
	'confidence',
	'severity',
	'preferred framing',
	'narrative'
)
foreach ($GateProfile in $IndependentGateProfiles) {
	$GateProfilePath = Join-Path $RepositoryRoot $GateProfile.Path
	$GateProfileSource = (
		Get-Content -Raw -LiteralPath $GateProfilePath
	).ToLowerInvariant()
	$MissingNeutralMarkers = @($NeutralInputMarkers | Where-Object {
		-not $GateProfileSource.Contains($_)
	})
	Add-Result `
		-Name "$($GateProfile.Name) profile admits normative neutral inputs" `
		-Passed ($MissingNeutralMarkers.Count -eq 0) `
		-Detail ([string]::Join(', ', $MissingNeutralMarkers))
	$MissingPriorJudgmentMarkers = @($PriorJudgmentMarkers | Where-Object {
		-not $GateProfileSource.Contains($_)
	})
	Add-Result `
		-Name "$($GateProfile.Name) profile rejects prior agent judgments" `
		-Passed ($MissingPriorJudgmentMarkers.Count -eq 0) `
		-Detail ([string]::Join(', ', $MissingPriorJudgmentMarkers))
}

$Results | Format-Table -AutoSize

$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) delivery-stage launcher test(s) failed. Test artifacts: $TestRoot"
}

Write-Host "All delivery-stage launcher tests passed. Test artifacts: $TestRoot"
