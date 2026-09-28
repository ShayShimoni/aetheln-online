[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/build/Read-BoundedCrashContext.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Rejected([string] $Name, [string] $Xml) {
	$Rejected = $false
	try {
		$null = ConvertFrom-BoundedCrashContextXml -XmlBytes ([Text.Encoding]::UTF8.GetBytes($Xml)) -ExpectedProcessId 27182 -ExpectedCrashRunId ('a' * 32) -ExpectedEngineRevision '5.8.1-123+++UE5+Release' -ExpectedFlowKind 'prototype-authority'
	} catch { $Rejected = $true }
	Assert-True $Rejected $Name
}

$Data = @'
<AethelnObservabilitySchema>aetheln.observability-event</AethelnObservabilitySchema>
<AethelnServerLifecycle>crashing</AethelnServerLifecycle>
<AethelnCrashContextState>active</AethelnCrashContextState>
<AethelnCrashContextSchemaVersion>1</AethelnCrashContextSchemaVersion>
<AethelnSourceRevision>unknown</AethelnSourceRevision>
<AethelnBuildIdentity>unknown</AethelnBuildIdentity>
<AethelnBuildConfiguration>Development</AethelnBuildConfiguration>
<AethelnEngineRevision>5.8.1-123+++UE5+Release</AethelnEngineRevision>
<AethelnToolchainIdentity>unknown</AethelnToolchainIdentity>
<AethelnNetworkProfileSchema>aetheln.network-profile</AethelnNetworkProfileSchema>
<AethelnNetworkProfileVersion>1</AethelnNetworkProfileVersion>
<AethelnNetworkProfileId>network-profile.unset</AethelnNetworkProfileId>
<AethelnFlowKind>prototype-authority</AethelnFlowKind>
<AethelnCrashRunId>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</AethelnCrashRunId>
<AethelnServerInstance>game-server</AethelnServerInstance>
<AethelnConnectionPseudonym>excluded</AethelnConnectionPseudonym>
'@
$Xml = "<FGenericCrashContext><RuntimeProperties><ProcessId>27182</ProcessId><CrashGUID>UECC-Linux-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0000</CrashGUID></RuntimeProperties><GameData>$Data</GameData><Unrestricted>secret-do-not-emit</Unrestricted></FGenericCrashContext>"
$Result = ConvertFrom-BoundedCrashContextXml -XmlBytes ([Text.Encoding]::UTF8.GetBytes($Xml)) -ExpectedProcessId 27182 -ExpectedCrashRunId ('a' * 32) -ExpectedEngineRevision '5.8.1-123+++UE5+Release' -ExpectedFlowKind 'prototype-authority'
Assert-True ($Result.ProcessId -eq 27182) 'The exact Linux process ID must match.'
Assert-True ($Result.CrashRunId -eq ('a' * 32)) 'The marker run must match the crash GameData.'
Assert-True ($Result.EngineCrashGuid -eq 'UECC-Linux-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0000') 'The engine crash GUID may differ from the marker and launch override.'
Assert-True (-not (($Result | ConvertTo-Json -Compress) -match 'secret-do-not-emit')) 'Only allowlisted data may leave the parser.'
Write-Output 'PASS: bounded XML returns only validated allowlisted identities'

Assert-Rejected 'Wrong process must fail.' ($Xml.Replace('<ProcessId>27182</ProcessId>', '<ProcessId>27183</ProcessId>'))
Assert-Rejected 'Duplicate process ID must fail.' ($Xml.Replace('</ProcessId>', '</ProcessId><ProcessId>27182</ProcessId>'))
Assert-Rejected 'Duplicate crash key must fail.' ($Xml.Replace('</AethelnCrashRunId>', '</AethelnCrashRunId><AethelnCrashRunId>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</AethelnCrashRunId>'))
Assert-Rejected 'Unknown Aetheln-prefixed key must fail.' ($Xml.Replace('</GameData>', '<AethelnSecret>should-reject</AethelnSecret></GameData>'))
Assert-Rejected 'Case-spoofed Aetheln key must fail.' ($Xml.Replace('</GameData>', '<aethelnSecret>should-reject</aethelnSecret></GameData>'))
Assert-Rejected 'Namespaced Aetheln key must fail.' ($Xml.Replace('</GameData>', '<x:AethelnSecret xmlns:x="urn:bad">should-reject</x:AethelnSecret></GameData>'))
Assert-Rejected 'Duplicate unknown key must fail.' ($Xml.Replace('</GameData>', '<Other>one</Other><Other>two</Other></GameData>'))
Assert-Rejected 'Missing crash key must fail.' ($Xml.Replace('<AethelnCrashRunId>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</AethelnCrashRunId>', ''))
Assert-Rejected 'Wrong run must fail.' ($Xml.Replace('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccccccccccc'))
Assert-Rejected 'Wrong engine must fail.' ($Xml.Replace('5.8.1-123+++UE5+Release', '5.8.2-123+++UE5+Release'))
Assert-Rejected 'Wrong flow must fail.' ($Xml.Replace('prototype-authority', 'admission'))
Assert-Rejected 'Inactive registration must fail.' ($Xml.Replace('<AethelnCrashContextState>active</AethelnCrashContextState>', '<AethelnCrashContextState>stale</AethelnCrashContextState>'))
Assert-Rejected 'Invalid connection pseudonym must fail.' ($Xml.Replace('<AethelnConnectionPseudonym>excluded</AethelnConnectionPseudonym>', '<AethelnConnectionPseudonym>user@example.com</AethelnConnectionPseudonym>'))
Assert-Rejected 'Nested value must fail.' ($Xml.Replace('<AethelnCrashRunId>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</AethelnCrashRunId>', '<AethelnCrashRunId><x>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</x></AethelnCrashRunId>'))
Assert-Rejected 'Forged engine platform must fail.' ($Xml.Replace('UECC-Linux-', 'UECC-SecretAccount-'))
Assert-Rejected 'DTD must fail.' ($Xml.Replace('<FGenericCrashContext>', '<!DOCTYPE FGenericCrashContext [<!ENTITY x "test">]><FGenericCrashContext>'))
Assert-Rejected 'Oversized XML must fail.' ($Xml + ('x' * 1048576))
Write-Output 'PASS: mismatch, duplicate, missing, stale, nested, DTD, and size cases fail closed'
