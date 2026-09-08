[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
$ProfilePath = Join-Path $RepositoryRoot '.codex\agents\delivery-verifier.toml'
$Results = [Collections.Generic.List[object]]::new()

# This is a regression for the injected instruction contract, not a substitute
# for evidence-composition tests or an actual independent verifier execution.
# Fixtures are strings only: the candidate and every repository file stay read-only.
$ConfigurationTemplate = @'
name = "delivery_verifier"
description = "Fresh independent verifier for reproducing behavior, running checks, and judging acceptance criteria."
sandbox_mode = "read-only"
developer_instructions = """
__INSTRUCTIONS__
"""
web_search = "disabled"

[features]
apps = false

[mcp_servers]
'@

$RequiredInstructions = [ordered]@{
	independent_inspection = 'Independently inspect the candidate and relevant source, reproduce the required behavior, and run every applicable focused and repository-defined check when permitted.'
	independent_raw_evidence = 'Independently evaluate complete, source-matched raw launcher-produced command and test logs criterion by criterion; never substitute another stage''s narrative or claimed result.'
	exact_evidence_binding = 'Require correctly typed evidence with matching provenance, source identity, encoding, exact content bytes, SHA-256, and candidate source commit under the existing evidence contract.'
	unreliable_evidence = 'Missing, stale, substituted, incomplete, or incorrectly typed or hash-bound evidence must remain failed or not verifiable; a passing summary cannot repair missing evidence.'
	denial_neutrality = 'A sandbox denial prevents that check from being rerun here, but does not erase valid raw evidence from an external launcher execution; denial alone is not evidence that the externally executed check failed.'
	execution_attribution = 'Distinguish external executions from checks rerun in this stage, and explicitly record every check not rerun and why.'
	read_only_execution = 'Run potentially writing checks only against a disposable operating-system-temporary snapshot when permitted, while the original candidate remains read-only.'
	snapshot_unavailable = 'If that snapshot cannot be created, do not run write-requiring checks here; independently judge the supplied raw evidence and report any unsupported criterion as not verifiable.'
	readable_evidence = 'Consume complete readable candidate and raw evidence directly without requiring forbidden decoding commands; preserve the exact evidence bytes and hashes and do not normalize, reconstruct, merge, or substitute evidence.'
	contamination_evidence = 'Compare original-repository status before and after verification when permitted; otherwise evaluate the source-bound launcher before/after snapshot attestations together with raw status and diff records for contamination.'
	unobserved_state = 'Never fabricate an unobserved snapshot or status result; if neither permitted observation nor complete source-bound raw evidence establishes candidate integrity, report it as not verifiable.'
	preserved_gates = 'Preserve required-evidence composition preflight, source/path/snapshot attestation, all required checks, fresh independent stages, and bounded retries; do not broaden permissions or weaken any gate.'
	contamination_failure = 'If the candidate or any repository artifact changes, fail verification and report the contamination without cleaning or deleting it.'
	normative_inputs = 'Ticket acceptance criteria, non-goals, required check commands, the output schema or contract, required response labels, and raw machine-generated command and test logs are normative neutral inputs, not prior conclusions.'
	criterion_reporting = 'Report each acceptance criterion as passed, failed, or not verifiable, with exact commands, environments, results, and reproduction evidence.'
	no_external_mutation = 'Do not mutate Git, GitHub issues, project fields, pull requests, comments, branches, commits, deployments, or external systems.'
}

$ObsoleteInstructions = @(
	'Independently reproduce the required behavior and run every applicable focused and repository-defined check.',
	'If a disposable snapshot cannot be created under current permissions, report write-requiring checks as not verifiable.',
	'Compare the original repository status before and after verification.'
)

function Get-VerifierContractFailure {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

	$Normalized = $Text.Replace("`r`n", "`n")
	$Blocks = [regex]::Matches(
		$Normalized,
		'(?ms)^developer_instructions = """\n(?<body>.*?)\n"""$'
	)
	if ($Blocks.Count -ne 1) {
		return 'instruction_block'
	}
	$Body = $Blocks[0].Groups['body']
	$Configuration = $Normalized.Remove($Body.Index, $Body.Length).Insert(
		$Body.Index, '__INSTRUCTIONS__'
	)
	if ($Configuration.Trim() -cne $ConfigurationTemplate.Trim()) {
		'isolation_configuration'
	}
	$InstructionLines = @($Body.Value -split "`n" | ForEach-Object { $_.Trim() })
	foreach ($Entry in $RequiredInstructions.GetEnumerator()) {
		if ($InstructionLines -cnotcontains $Entry.Value) {
			'missing_' + $Entry.Key
		}
	}
	foreach ($Obsolete in $ObsoleteInstructions) {
		if ($Body.Value.Contains($Obsolete)) {
			'obsolete_unconditional_requirement'
		}
	}
}

function Add-Result {
	param([string]$Name, [bool]$Passed)
	$Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
}

$ControlBody = [string]::Join("`n", [string[]]@($RequiredInstructions.Values))
$Control = $ConfigurationTemplate.Replace('__INSTRUCTIONS__', $ControlBody)
Add-Result -Name 'Complete instruction and isolation control is accepted' -Passed (
	@(Get-VerifierContractFailure -Text $Control).Count -eq 0
)
foreach ($Entry in $RequiredInstructions.GetEnumerator()) {
	$Missing = $Control.Replace($Entry.Value, '')
	Add-Result -Name ('Reject removal: ' + $Entry.Key) -Passed (
		@(Get-VerifierContractFailure -Text $Missing) -ccontains ('missing_' + $Entry.Key)
	)
	$Commented = $Control.Replace($Entry.Value, '# ' + $Entry.Value)
	Add-Result -Name ('Comment cannot satisfy: ' + $Entry.Key) -Passed (
		@(Get-VerifierContractFailure -Text $Commented) -ccontains ('missing_' + $Entry.Key)
	)
}
foreach ($Obsolete in $ObsoleteInstructions) {
	$Contradictory = $ConfigurationTemplate.Replace(
		'__INSTRUCTIONS__', $ControlBody + "`n" + $Obsolete
	)
	Add-Result -Name ('Reject unconditional rule: ' + $Obsolete) -Passed (
		@(Get-VerifierContractFailure -Text $Contradictory) -ccontains (
			'obsolete_unconditional_requirement'
		)
	)
}
foreach ($Setting in @(
	@('sandbox_mode = "read-only"', 'sandbox_mode = "workspace-write"'),
	@('web_search = "disabled"', 'web_search = "live"'),
	@('apps = false', 'apps = true'),
	@('[mcp_servers]', "[mcp_servers.extra]`ncommand = 'unexpected'")
)) {
	$Weakened = $Control.Replace($Setting[0], $Setting[1])
	Add-Result -Name ('Reject changed isolation: ' + $Setting[0]) -Passed (
		@(Get-VerifierContractFailure -Text $Weakened) -ccontains 'isolation_configuration'
	)
}
Add-Result -Name 'Reject missing instruction block' -Passed (
	@(Get-VerifierContractFailure -Text '') -ccontains 'instruction_block'
)

$ProfileText = [IO.File]::ReadAllText($ProfilePath, [Text.UTF8Encoding]::new($false, $true))
$ProfileFailures = @(Get-VerifierContractFailure -Text $ProfileText)
Add-Result -Name 'Actual injected verifier profile satisfies the contract' -Passed (
	$ProfileFailures.Count -eq 0
)
$Results | Format-Table -AutoSize -Wrap
if ($ProfileFailures.Count -gt 0) {
	Write-Output ('Actual profile violations: ' + ($ProfileFailures -join ', '))
}
$Failures = @($Results | Where-Object { -not $_.Passed })
if ($Failures.Count -gt 0) {
	throw "Verifier profile contract failed: $($Failures.Name -join '; ')"
}
Write-Output "Verifier profile contract passed ($($Results.Count) cases)."
