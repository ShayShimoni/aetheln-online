[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Validator = Join-Path $RepositoryRoot 'scripts/build/Validate-TargetComposition.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnTargetCompositionTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True {
	param(
		[Parameter(Mandatory)]
		[bool] $Condition,
		[Parameter(Mandatory)]
		[string] $Message
	)

	if (-not $Condition) {
		throw "Assertion failed: $Message"
	}
}

function New-TargetFixture {
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[string[]] $ClientModules,
		[Parameter(Mandatory)]
		[string[]] $ServerModules
	)

	$SourceDirectory = Join-Path $Root 'Source'
	New-Item -ItemType Directory -Path $SourceDirectory -Force | Out-Null

	$Definitions = @(
		@{ File = 'AethelnOnline.Target.cs'; Class = 'AethelnOnlineTarget'; Type = 'Game'; Modules = $ClientModules },
		@{ File = 'AethelnOnlineClient.Target.cs'; Class = 'AethelnOnlineClientTarget'; Type = 'Client'; Modules = $ClientModules },
		@{ File = 'AethelnOnlineServer.Target.cs'; Class = 'AethelnOnlineServerTarget'; Type = 'Server'; Modules = $ServerModules }
	)

	foreach ($Definition in $Definitions) {
		$QuotedModules = ($Definition.Modules | ForEach-Object { '"{0}"' -f $_ }) -join ', '
		$Content = @"
using UnrealBuildTool;
using System.Collections.Generic;

public class $($Definition.Class) : TargetRules
{
	public $($Definition.Class)(TargetInfo Target) : base(Target)
	{
		Type = TargetType.$($Definition.Type);
		ExtraModuleNames.AddRange(new string[] { $QuotedModules });
	}
}
"@
		Set-Content -LiteralPath (Join-Path $SourceDirectory $Definition.File) -Value $Content -Encoding UTF8
	}
}

function Invoke-ExpectedFailure {
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[string] $ExpectedPattern
	)

	$FailureMessage = $null
	try {
		& $Validator -ProjectRoot $Root | Out-Null
	}
	catch {
		$FailureMessage = $_.Exception.Message
	}

	Assert-True -Condition ($null -ne $FailureMessage) -Message "Expected validation to fail for fixture '$Root'."
	Assert-True -Condition ($FailureMessage -match $ExpectedPattern) -Message "Failure '$FailureMessage' did not match '$ExpectedPattern'."
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	$ValidRoot = Join-Path $FixtureRoot 'valid'
	New-TargetFixture -Root $ValidRoot -ClientModules @('GameCore', 'GameCombat', 'GameUI', 'GameNet') -ServerModules @('GameCore', 'GameCombat', 'GameNet', 'GameServer')
	$ValidOutput = & $Validator -ProjectRoot $ValidRoot | Out-String
	Assert-True -Condition ($ValidOutput -match 'Target composition validation passed\.') -Message 'The valid target graph should pass.'
	Write-Output 'PASS: valid target graph'

	$ClientViolationRoot = Join-Path $FixtureRoot 'client-has-server'
	New-TargetFixture -Root $ClientViolationRoot -ClientModules @('GameCore', 'GameUI', 'GameServer') -ServerModules @('GameCore', 'GameServer')
	Invoke-ExpectedFailure -Root $ClientViolationRoot -ExpectedPattern "AethelnOnline(?:Client)?Target.*(?:Game|Client).*GameServer"
	Write-Output 'PASS: GameServer in a client-capable target is rejected with target and module names'

	$ServerViolationRoot = Join-Path $FixtureRoot 'server-has-ui'
	New-TargetFixture -Root $ServerViolationRoot -ClientModules @('GameCore', 'GameUI') -ServerModules @('GameCore', 'GameServer', 'GameUI')
	Invoke-ExpectedFailure -Root $ServerViolationRoot -ExpectedPattern 'AethelnOnlineServerTarget.*Server.*GameUI'
	Write-Output 'PASS: GameUI in the server target is rejected with target and module names'

	Write-Output 'All target composition tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
