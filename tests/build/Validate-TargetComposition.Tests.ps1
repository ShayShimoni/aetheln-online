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
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[string[]] $ClientModules,
		[Parameter(Mandatory)]
		[string[]] $ServerModules,
		[string] $EngineConfig = "[/Script/Engine.Engine]`nGameViewportClientClassName=/Script/Engine.GameViewportClient",
		[string] $InputConfig = $null
	)

	if (-not $PSCmdlet.ShouldProcess($Root, 'Create target source and configuration fixture files')) {
		return
	}

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

	$ConfigDirectory = Join-Path $Root 'Config'
	New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $ConfigDirectory 'DefaultEngine.ini') -Value $EngineConfig -Encoding UTF8
	if ($null -ne $InputConfig) {
		Set-Content -LiteralPath (Join-Path $ConfigDirectory 'DefaultInput.ini') -Value $InputConfig -Encoding UTF8
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

	$DeclinedRoot = Join-Path $FixtureRoot 'declined'
	New-TargetFixture -Root $DeclinedRoot -ClientModules @('GameCore', 'GameUI') -ServerModules @('GameCore', 'GameServer') -WhatIf
	Assert-True -Condition (-not (Test-Path -LiteralPath $DeclinedRoot)) -Message 'A declined fixture must not create its target sources or configuration files.'
	Write-Output 'PASS: target fixture creation is declined without mutating the filesystem'

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

	$SharedConfigViolationRoot = Join-Path $FixtureRoot 'shared-config-has-ui'
	New-TargetFixture -Root $SharedConfigViolationRoot -ClientModules @('GameCore', 'GameUI') -ServerModules @('GameCore', 'GameServer') -EngineConfig "[/Script/Engine.Engine]`nGameViewportClientClassName=/Script/CommonUI.CommonGameViewportClient"
	Invoke-ExpectedFailure -Root $SharedConfigViolationRoot -ExpectedPattern 'DefaultEngine\.ini.*CommonUI.*dedicated-server'
	Write-Output 'PASS: client-only script packages in shared config are rejected'

	$SharedContentViolationRoot = Join-Path $FixtureRoot 'shared-config-has-client-content'
	New-TargetFixture -Root $SharedContentViolationRoot -ClientModules @('GameCore', 'GameUI') -ServerModules @('GameCore', 'GameServer') -InputConfig "[/Script/CommonUI.CommonUIInputSettings]`nDefaultVirtualPointerClass=/CommonUI/WBP_VirtualPointer.WBP_VirtualPointer_C"
	Invoke-ExpectedFailure -Root $SharedContentViolationRoot -ExpectedPattern 'DefaultInput\.ini.*client-only content package.*CommonUI'
	Write-Output 'PASS: client-only content references in root shared config are rejected'

	$CommentedConfigRoot = Join-Path $FixtureRoot 'commented-config-ui'
	New-TargetFixture -Root $CommentedConfigRoot -ClientModules @('GameCore', 'GameUI') -ServerModules @('GameCore', 'GameServer') -EngineConfig ";GameViewportClientClassName=/Script/CommonUI.CommonGameViewportClient`n[/Script/Engine.Engine]`nGameViewportClientClassName=/Script/Engine.GameViewportClient"
	$CommentedOutput = & $Validator -ProjectRoot $CommentedConfigRoot | Out-String
	Assert-True -Condition ($CommentedOutput -match 'Target composition validation passed\.') -Message 'Commented client-only config references should be ignored.'
	Write-Output 'PASS: commented client-only config references are ignored'

	Write-Output 'All target composition tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
