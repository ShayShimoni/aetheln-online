[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WorkflowPath = Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml'
$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-MatchCount([string] $Text, [string] $Pattern, [int] $Expected, [string] $Message) {
	$Actual = [regex]::Matches($Text, $Pattern).Count
	Assert-True ($Actual -eq $Expected) "$Message Expected $Expected match(es), found $Actual."
}

function Get-JobBody([string] $JobName, [string] $NextJobName) {
	$Start = "  ${JobName}:"
	$End = "  ${NextJobName}:"
	$StartIndex = $Workflow.IndexOf($Start, [StringComparison]::Ordinal)
	$EndIndex = $Workflow.IndexOf($End, $StartIndex + $Start.Length, [StringComparison]::Ordinal)
	Assert-True ($StartIndex -ge 0 -and $EndIndex -gt $StartIndex) "Workflow job '$JobName' should exist before '$NextJobName'."
	return $Workflow.Substring($StartIndex, $EndIndex - $StartIndex)
}

$QualityGates = Get-JobBody 'quality-gates' 'trusted-candidate-compile'
$TrustedCompile = Get-JobBody 'trusted-candidate-compile' 'scheduled-packaged-smoke'
$ScheduledSmoke = Get-JobBody 'scheduled-packaged-smoke' 'manual-packaged-smoke'
$ManualSmokeStart = $Workflow.IndexOf('  manual-packaged-smoke:', [StringComparison]::Ordinal)
Assert-True ($ManualSmokeStart -ge 0) "Workflow job 'manual-packaged-smoke' should exist."
$ManualSmoke = $Workflow.Substring($ManualSmokeStart)

Assert-True ($Workflow -match '(?m)^permissions:\r?\n  contents: read\r?$') 'Workflow permissions must remain contents read.'
Assert-True ($Workflow -notmatch '\$\{\{\s*secrets\.' -and $Workflow -notmatch '(?m)^\s*secrets\s*:') 'Workflow must not consume or declare secrets.'
Assert-True ($QualityGates -match 'git lfs pull --include "Content/Maps/StarterMap\.umap"') 'The portable job must materialize the StarterMap LFS fixture.'

Assert-True ($TrustedCompile -match "github\.event_name == 'pull_request'") 'Trusted compile must remain limited to pull requests.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository') 'Trusted compile must require the head repository to match this repository.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.user\.login == github\.repository_owner') 'Trusted compile must require the pull request author to be the repository owner.'
Assert-True ($TrustedCompile -match 'github\.triggering_actor == github\.repository_owner') 'Trusted compile must require the triggering actor to be the repository owner.'
Assert-MatchCount $TrustedCompile '(?m)^\s+-Mode Compile `\r?$' 1 'Trusted owner pull-request validation must select Compile exactly once.'
Assert-True ($TrustedCompile -notmatch '(?m)^\s+-Mode PackagedSmoke `\r?$') 'Trusted owner pull-request validation must not select PackagedSmoke.'
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Routine trusted compile must not be configured as a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '(?i)clean[^\r\n]*packag|packag[^\r\n]*clean') 'Routine trusted compile must not be described as a clean package gate.'

Assert-True ($ScheduledSmoke -match "if:\s*github\.event_name == 'schedule'") 'Scheduled packaged smoke must remain limited to the schedule event.'
Assert-True ($ManualSmoke -match "github\.event_name == 'workflow_dispatch'") 'Manual packaged smoke must remain limited to workflow dispatch.'
Assert-True ($ManualSmoke -match 'github\.triggering_actor == github\.repository_owner') 'Manual packaged smoke must require the repository owner as triggering actor.'
foreach ($Job in @(
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke },
	@{ Name = 'manual-packaged-smoke'; Body = $ManualSmoke }
)) {
	Assert-MatchCount $Job.Body '(?m)^\s+-Mode PackagedSmoke `\r?$' 1 "$($Job.Name) must select PackagedSmoke exactly once."
	Assert-True ($Job.Body -notmatch '(?m)^\s+-Mode Compile `\r?$') "$($Job.Name) must not select Compile."
	Assert-True ($Job.Body -match 'timeout-minutes:\s*1440') "$($Job.Name) must retain the milestone gate timeout."
}

foreach ($Job in @(
	@{ Name = 'trusted-candidate-compile'; Body = $TrustedCompile },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke },
	@{ Name = 'manual-packaged-smoke'; Body = $ManualSmoke }
)) {
	Assert-True ($Job.Body -match 'git lfs pull --include "Content/\*\*"') "$($Job.Name) must materialize every Unreal Content LFS object before build or cook."
	Assert-True ($Job.Body -notmatch 'git lfs pull --include "Content/Maps/StarterMap\.umap"') "$($Job.Name) must not fetch only StarterMap."
	Assert-True ($Job.Body -match '(?m)^\s+group: aetheln-engine-runner\r?$') "$($Job.Name) must use the shared engine-runner concurrency group."
	Assert-True ($Job.Body -match '(?m)^\s+cancel-in-progress: false\r?$') "$($Job.Name) must serialize without cancelling an active engine job."
	Assert-True ($Job.Body -match '(?m)^\s+path: TestResults/engine-runner-report\.json\r?$') "$($Job.Name) must upload only its machine-readable engine report."
}

$UploadPaths = @([regex]::Matches($Workflow, '(?m)^\s+path:\s*(TestResults/[^\r\n]+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
Assert-True ($UploadPaths.Count -eq 4) 'Workflow must publish exactly one JSON report for each portable or selected engine job.'
foreach ($UploadPath in $UploadPaths) {
	Assert-True ($UploadPath -match '^TestResults/(ci-report|engine-runner-report)\.json$') "Upload path '$UploadPath' must be an approved JSON report."
}
Assert-True ($Workflow -notmatch '(?m)^\s+path:\s*.*(?:archives?|logs?|Saved|StagedBuilds)') 'Workflow must not upload packages, archives, logs, or generated Unreal output.'

Write-Output 'PASS: workflow preserves trusted incremental compile and milestone packaged-smoke selection'
Write-Output 'PASS: workflow preserves LFS, serialization, report-only upload, and no-secret policy'
exit 0
