[CmdletBinding()]
param(
	[Parameter()]
	[string] $ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceDirectory = Join-Path $ProjectRoot 'Source'
$RequiredTargets = @(
	@{ File = 'AethelnOnline.Target.cs'; ExpectedType = 'Game' },
	@{ File = 'AethelnOnlineClient.Target.cs'; ExpectedType = 'Client' },
	@{ File = 'AethelnOnlineServer.Target.cs'; ExpectedType = 'Server' }
)

function Read-TargetDefinition {
	param(
		[Parameter(Mandatory)]
		[string] $Path
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Target composition validation could not find required target file '$Path'."
	}

	$Content = Get-Content -LiteralPath $Path -Raw
	$ClassMatch = [regex]::Match($Content, 'public\s+class\s+(?<Name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*TargetRules')
	if (-not $ClassMatch.Success) {
		throw "Target composition validation could not determine the TargetRules class in '$Path'."
	}

	$TypeMatch = [regex]::Match($Content, 'Type\s*=\s*TargetType\.(?<Type>Game|Client|Server|Editor)\s*;')
	if (-not $TypeMatch.Success) {
		throw "Target composition validation could not determine TargetType for '$($ClassMatch.Groups['Name'].Value)' in '$Path'."
	}

	$Modules = [System.Collections.Generic.List[string]]::new()
	$AddMatches = [regex]::Matches(
		$Content,
		'ExtraModuleNames\.Add(?:Range)?\s*\((?<Arguments>.*?)\)\s*;',
		[System.Text.RegularExpressions.RegexOptions]::Singleline
	)
	foreach ($AddMatch in $AddMatches) {
		foreach ($ModuleMatch in [regex]::Matches($AddMatch.Groups['Arguments'].Value, '"(?<Module>[A-Za-z_][A-Za-z0-9_]*)"')) {
			$Modules.Add($ModuleMatch.Groups['Module'].Value)
		}
	}

	if ($Modules.Count -eq 0) {
		throw "Target composition validation found no ExtraModuleNames for '$($ClassMatch.Groups['Name'].Value)' in '$Path'."
	}

	return [pscustomobject]@{
		Name = $ClassMatch.Groups['Name'].Value
		Type = $TypeMatch.Groups['Type'].Value
		Modules = @($Modules)
		Path = $Path
	}
}

$Targets = foreach ($RequiredTarget in $RequiredTargets) {
	$TargetPath = Join-Path $SourceDirectory $RequiredTarget.File
	$Target = Read-TargetDefinition -Path $TargetPath
	if ($Target.Type -ne $RequiredTarget.ExpectedType) {
		throw "Target composition violation: '$($Target.Name)' in '$TargetPath' declares TargetType.$($Target.Type); expected TargetType.$($RequiredTarget.ExpectedType)."
	}
	$Target
}

$Violations = [System.Collections.Generic.List[string]]::new()
foreach ($Target in $Targets) {
	if ($Target.Type -in @('Game', 'Client') -and $Target.Modules -contains 'GameServer') {
		$Violations.Add("Target '$($Target.Name)' ($($Target.Type)) includes forbidden module 'GameServer' in '$($Target.Path)'. Client-capable targets must exclude server-only code.")
	}
	if ($Target.Type -eq 'Server' -and $Target.Modules -contains 'GameUI') {
		$Violations.Add("Target '$($Target.Name)' ($($Target.Type)) includes forbidden module 'GameUI' in '$($Target.Path)'. Dedicated-server targets must exclude client-only presentation code.")
	}
}

if ($Violations.Count -gt 0) {
	throw "Target composition validation failed:`n - $($Violations -join "`n - ")"
}

foreach ($Target in $Targets) {
	Write-Output "Validated $($Target.Name) ($($Target.Type)): $($Target.Modules -join ', ')"
}
Write-Output 'Target composition validation passed.'
