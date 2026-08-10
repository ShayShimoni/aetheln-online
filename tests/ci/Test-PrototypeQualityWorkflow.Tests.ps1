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

function Get-JobBody([string] $JobName, [string] $NextJobName) {
	$Start = "  ${JobName}:"
	$End = "  ${NextJobName}:"
	$StartIndex = $Workflow.IndexOf($Start, [StringComparison]::Ordinal)
	$EndIndex = $Workflow.IndexOf($End, $StartIndex + $Start.Length, [StringComparison]::Ordinal)
	Assert-True ($StartIndex -ge 0 -and $EndIndex -gt $StartIndex) "Workflow job '$JobName' should exist before '$NextJobName'."
	return $Workflow.Substring($StartIndex, $EndIndex - $StartIndex)
}

$TrustedCompile = Get-JobBody 'trusted-candidate-compile' 'scheduled-packaged-smoke'
$ScheduledSmoke = Get-JobBody 'scheduled-packaged-smoke' 'manual-packaged-smoke'
$ManualSmokeStart = $Workflow.IndexOf('  manual-packaged-smoke:', [StringComparison]::Ordinal)
Assert-True ($ManualSmokeStart -ge 0) "Workflow job 'manual-packaged-smoke' should exist."
$ManualSmoke = $Workflow.Substring($ManualSmokeStart)

foreach ($Job in @(
	@{ Name = 'trusted-candidate-compile'; Body = $TrustedCompile },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke },
	@{ Name = 'manual-packaged-smoke'; Body = $ManualSmoke }
)) {
	Assert-True ($Job.Body -match 'git lfs pull --include "Content/\*\*"') "$($Job.Name) must materialize every Unreal Content LFS object before build or cook."
	Assert-True ($Job.Body -notmatch 'git lfs pull --include "Content/Maps/StarterMap\.umap"') "$($Job.Name) must not fetch only StarterMap."
	Assert-True ($Job.Body -match 'timeout-minutes:\s*1440') "$($Job.Name) must allow a full clean source-engine gate to run for up to 24 hours."
}

Write-Output 'PASS: every self-hosted engine job materializes all Unreal Content LFS objects'
exit 0
