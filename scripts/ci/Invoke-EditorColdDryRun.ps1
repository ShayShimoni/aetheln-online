[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $EngineRoot,
	[Parameter(Mandatory)][string] $TargetRoot,
	[Parameter(Mandatory)][string] $BaselineReceipt,
	[Parameter(Mandatory)][string] $LinuxToolchainRoot,
	[Parameter(Mandatory)][string] $EvidenceRoot
)
# Issue #267 owner step B: the cold proof that a fresh-worktree -NoEngineChanges
# AethelnOnlineEditor build leaves every host-tools closure file unchanged. It
# hashes the closure from an existing contributor receipt (-BaselineReceipt),
# runs this checkout's reviewed wrapper against the fresh -TargetRoot, then
# hashes the closure from the receipt that build wrote. Passing requires exit 0
# and identical path, SHA-256 and size sets. Local only, never run by CI; the
# operator first checks runner 21 is idle, holds engine.lock, and confirms no
# engine process runs. Evidence stays under -EvidenceRoot; the one printed line
# carries no path, so it can be posted on the issue.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrEmpty($env:UE_ADDITIONAL_PLUGIN_PATHS)) { throw 'cold_dry_run_plugin_paths_set' }
# A warm workspace proves only the warm case that CI already shows.
foreach ($Name in @('Binaries', 'Intermediate')) { if (Test-Path -LiteralPath (Join-Path $TargetRoot $Name)) { throw 'cold_dry_run_target_not_fresh' } }

function Get-ClosureHash([string] $Receipt) {
	# The closure product types and path normalization of Build-PackagedArtifacts.ps1:
	# $(EngineDir) products of the editor and ShaderCompileWorker receipts, plus that receipt.
	$Types = @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package')
	$Paths = @('Engine/Binaries/Win64/ShaderCompileWorker.target')
	foreach ($Path in @($Receipt, (Join-Path $EngineRoot 'Engine/Binaries/Win64/ShaderCompileWorker.target'))) {
		foreach ($Product in (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).BuildProducts) {
			if ($Types -ccontains $Product.Type -and $Product.Path.StartsWith('$(EngineDir)/', [StringComparison]::Ordinal)) { $Paths += 'Engine/' + $Product.Path.Substring(13) }
		}
	}
	$Paths | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique | ForEach-Object {
		$Full = Join-Path $EngineRoot $_
		[pscustomobject]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant(); sizeBytes = (Get-Item -LiteralPath $Full).Length }
	}
}

$Before = @(Get-ClosureHash $BaselineReceipt)
$Before | Export-Csv -LiteralPath (Join-Path $EvidenceRoot 'hashes-before.csv') -NoTypeInformation -NoClobber
$BuildEvidence = Join-Path $EvidenceRoot 'build'
$null = New-Item -ItemType Directory -Path $BuildEvidence
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'InitialPreparation.BuildInvocation.ps1') `
	-Target AethelnOnlineEditor -Platform Win64 -ActionLimit 4 -EngineRoot $EngineRoot -TargetRoot $TargetRoot `
	-LinuxToolchainRoot $LinuxToolchainRoot -EvidenceRoot $BuildEvidence
$Exit = $LASTEXITCODE
# A failed build writes no receipt; the baseline then shows whether any closure file still changed.
$AfterReceipt = if ($Exit -eq 0) { Join-Path $TargetRoot 'Binaries/Win64/AethelnOnlineEditor.target' } else { $BaselineReceipt }
$After = @(Get-ClosureHash $AfterReceipt)
$After | Export-Csv -LiteralPath (Join-Path $EvidenceRoot 'hashes-after.csv') -NoTypeInformation -NoClobber
$Changed = @(Compare-Object $Before $After -Property path, sha256, sizeBytes)
$Changed | Export-Csv -LiteralPath (Join-Path $EvidenceRoot 'hashes-changed.csv') -NoTypeInformation -NoClobber
$ChangedPaths = @($Changed | ForEach-Object { $_.path } | Sort-Object -Unique).Count
$Status = if ($Exit -eq 0 -and $Changed.Count -eq 0) { 'passed' } else { 'failed' }
Write-Output ('cold_dry_run {0} exit={1} closure={2} changed={3}' -f $Status, $Exit, $After.Count, $ChangedPaths)
if ($Status -cne 'passed') { exit 1 }
