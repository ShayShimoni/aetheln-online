[CmdletBinding()]
param(
	[string] $TagSourceRoot,
	[string] $TagRegistryPath,
	[switch] $SkipMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $TagSourceRoot) { $TagSourceRoot = Join-Path $PSScriptRoot '..\..\Source' }
if (-not $TagRegistryPath) { $TagRegistryPath = Join-Path $PSScriptRoot '..\..\design\combat-registry\registry.json' }

# Parameters carry a Tag prefix because Test-CombatRegistry.ps1 dot-sources this file and a shared name would overwrite its own.
# #84 P3b: every native Ability. tag maps to exactly one semantic ID in the combat registry.
# The tag declaration's comment names the ID (docs/combat-and-networking-architecture.md,
# Gameplay Tag and Content-Version Conventions). A test-only Ability.Test. tag is exempt.
# Pending: tags whose ID the registry does not hold yet (#106 owns registry growth). Remove an entry when its ID lands;
# the check fails on a stale entry so this list only shrinks.
$PendingRegistryIds = @{
	'Ability.Dodge' = 'combat.action.dodge'
	'Ability.Block' = 'combat.action.block'
	'Ability.Enemy.Greybox.Strike' = 'enemy.greybox.ability.strike'
}

function Test-CombatTagMapping {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $SourceRoot, [Parameter(Mandatory)][string] $RegistryPath, [hashtable] $Pending = $PendingRegistryIds)
	$Errors = New-Object 'System.Collections.Generic.List[string]'
	$Registry = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8)
	$RegistryIds = @{}
	foreach ($Definition in @($Registry.definitions)) { $RegistryIds[[string]$Definition.id] = $true }
	$Declaration = [regex]'UE_DEFINE_GAMEPLAY_TAG(?:_COMMENT|_STATIC)?\(\s*\w+\s*,\s*"(Ability\.[^"]+)"(?:\s*,\s*"([^"]*)")?\s*\)'
	$Tags = @{}
	foreach ($File in (Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | Where-Object { $_.Extension -ceq '.cpp' -or $_.Extension -ceq '.h' })) {
		foreach ($Match in $Declaration.Matches((Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8))) {
			$Tag = $Match.Groups[1].Value
			$Comment = if ($Match.Groups[2].Success) { $Match.Groups[2].Value } else { '' }
			if ($Tags.ContainsKey($Tag)) { $Errors.Add("${Tag}: declared more than once"); continue }
			$Tags[$Tag] = $Comment
		}
	}
	$Claimed = @{}
	foreach ($Tag in ($Tags.Keys | Sort-Object)) {
		$Comment = $Tags[$Tag]
		if ($Tag.StartsWith('Ability.Test.', [StringComparison]::Ordinal) -and $Comment.StartsWith('Test-only', [StringComparison]::Ordinal)) { continue }
		$Id = if ($Comment -cmatch '^([a-z][a-z0-9]*(?:\.[a-z][a-z0-9_]*)+)(?:\s|$)') { $Matches[1] } else { $null }
		if ($null -eq $Id) { $Errors.Add("${Tag}: the declaration comment does not start with a registry semantic ID"); continue }
		if ($Pending.ContainsKey($Tag)) {
			if ($Pending[$Tag] -cne $Id) { $Errors.Add("${Tag}: pending ID '$($Pending[$Tag])' differs from the declared ID '$Id'"); continue }
			if ($RegistryIds.ContainsKey($Id)) { $Errors.Add("${Tag}: '$Id' is in the registry now; remove the tag from the pending list"); continue }
		}
		elseif (-not $RegistryIds.ContainsKey($Id)) { $Errors.Add("${Tag}: '$Id' is not a registry definition ID"); continue }
		if ($Claimed.ContainsKey($Id)) { $Errors.Add("${Tag}: '$Id' is already mapped by $($Claimed[$Id])"); continue }
		$Claimed[$Id] = $Tag
	}
	foreach ($Tag in $Pending.Keys) {
		if (-not $Tags.ContainsKey($Tag)) { $Errors.Add("${Tag}: pending entry names a tag that is no longer declared") }
	}
	return [pscustomobject]@{ passed = ($Errors.Count -eq 0); errors = @($Errors.ToArray()); tagCount = $Tags.Count }
}

if (-not $SkipMain) {
	$Result = Test-CombatTagMapping -SourceRoot $TagSourceRoot -RegistryPath $TagRegistryPath
	if (-not $Result.passed) {
		$Result.errors | ForEach-Object { Write-Output "FAIL: $_" }
		exit 1
	}
	Write-Output "PASS: combat tag mapping ($($Result.tagCount) native Ability. tags)"
}
