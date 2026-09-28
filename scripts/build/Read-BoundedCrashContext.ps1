<#
.SYNOPSIS
Validates an already acquired, size-bounded Unreal crash-context XML byte array.
.DESCRIPTION
This is a pure parsing component, not a capture runner. The caller must first
prove local-only isolation, direct Linux process identity, exclusive no-follow
file acquisition, and marker provenance. It never opens a path or emits raw XML.
#>
Set-StrictMode -Version Latest

function ConvertFrom-BoundedCrashContextXml {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [byte[]] $XmlBytes,
		[Parameter(Mandatory)] [ValidateRange(1, 2147483647)] [int] $ExpectedProcessId,
		[Parameter(Mandatory)] [string] $ExpectedCrashRunId,
		[Parameter(Mandatory)] [string] $ExpectedEngineRevision,
		[Parameter(Mandatory)] [string] $ExpectedFlowKind
	)

	if ($XmlBytes.Length -eq 0 -or $XmlBytes.Length -gt 1048576) { throw 'Crash XML byte limit rejected.' }
	if ($ExpectedCrashRunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Expected marker ID format rejected.' }
	$AllowedFlows = @('prototype-authority', 'admission', 'lease', 'persistent-command', 'transaction', 'outbox', 'reward', 'transfer', 'allocation', 'dependency', 'restore', 'reconciliation')
	if (-not ($AllowedFlows -ccontains $ExpectedFlowKind)) { throw 'Expected flow kind rejected.' }

	$Settings = [System.Xml.XmlReaderSettings]::new()
	$Settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
	$Settings.XmlResolver = $null
	$Settings.MaxCharactersInDocument = 1048576
	$Settings.MaxCharactersFromEntities = 0
	$Settings.IgnoreComments = $true
	$Settings.IgnoreProcessingInstructions = $true
	$Stream = [System.IO.MemoryStream]::new($XmlBytes, $false)
	$Reader = $null
	try {
		$Reader = [System.Xml.XmlReader]::Create($Stream, $Settings)
		$Document = [System.Xml.XmlDocument]::new()
		$Document.XmlResolver = $null
		$Document.Load($Reader)
	} catch {
		throw 'Crash XML parse rejected.'
	} finally {
		if ($null -ne $Reader) { $Reader.Dispose() }
		$Stream.Dispose()
	}

	if ($null -eq $Document.DocumentElement -or $Document.DocumentElement.Name -cne 'FGenericCrashContext' -or $Document.DocumentElement.Attributes.Count -ne 0) {
		throw 'Crash XML root rejected.'
	}

	function Get-OnlyChild([System.Xml.XmlNode] $Parent, [string] $Name) {
		$Matches = @($Parent.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.Name -ceq $Name })
		if ($Matches.Count -ne 1 -or $Matches[0].Attributes.Count -ne 0) { throw 'Crash XML required field rejected.' }
		return $Matches[0]
	}
	function Get-OnlyText([System.Xml.XmlNode] $Parent, [string] $Name) {
		$Node = Get-OnlyChild $Parent $Name
		if (@($Node.ChildNodes | Where-Object { $_.NodeType -ne [System.Xml.XmlNodeType]::Text -and $_.NodeType -ne [System.Xml.XmlNodeType]::CDATA }).Count -gt 0) {
			throw 'Crash XML nested field rejected.'
		}
		$Value = $Node.InnerText
		if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 128) { throw 'Crash XML field bound rejected.' }
		return $Value
	}

	$Runtime = Get-OnlyChild $Document.DocumentElement 'RuntimeProperties'
	$Data = Get-OnlyChild $Document.DocumentElement 'GameData'
	$PidText = Get-OnlyText $Runtime 'ProcessId'
	if ($PidText -cnotmatch '^[1-9][0-9]{0,9}$' -or $PidText -cne [string]$ExpectedProcessId) { throw 'Crash XML process identity rejected.' }
	$EngineGuid = Get-OnlyText $Runtime 'CrashGUID'
	if ($EngineGuid -cnotmatch '^UECC-Linux-[0-9A-Fa-f]{32}_[0-9]{4}$') { throw 'Crash XML engine GUID format rejected.' }

	$Fixed = [ordered]@{
		AethelnObservabilitySchema = 'aetheln.observability-event'
		AethelnServerLifecycle = 'crashing'
		AethelnCrashContextState = 'active'
		AethelnCrashContextSchemaVersion = '1'
		AethelnSourceRevision = 'unknown'
		AethelnBuildIdentity = 'unknown'
		AethelnBuildConfiguration = 'Development'
		AethelnToolchainIdentity = 'unknown'
		AethelnNetworkProfileSchema = 'aetheln.network-profile'
		AethelnNetworkProfileVersion = '1'
		AethelnNetworkProfileId = 'network-profile.unset'
		AethelnServerInstance = 'game-server'
		AethelnConnectionPseudonym = 'excluded'
	}
	$SeenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$AllowedAethelnNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($Key in $Fixed.Keys) { $null = $AllowedAethelnNames.Add($Key) }
	$null = $AllowedAethelnNames.Add('AethelnEngineRevision')
	$null = $AllowedAethelnNames.Add('AethelnFlowKind')
	$null = $AllowedAethelnNames.Add('AethelnCrashRunId')
	foreach ($Node in $Data.ChildNodes) {
		if ($Node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($Node.Prefix.Length -ne 0 -or $Node.NamespaceURI.Length -ne 0 -or $Node.Attributes.Count -ne 0) {
			throw 'Crash XML namespaced or attributed GameData key rejected.'
		}
		if (-not $SeenNames.Add($Node.Name)) { throw 'Crash XML duplicate GameData key rejected.' }
		if ($Node.Name.StartsWith('Aetheln', [StringComparison]::OrdinalIgnoreCase) -and -not $AllowedAethelnNames.Contains($Node.Name)) {
			throw 'Crash XML unexpected Aetheln GameData key rejected.'
		}
	}
	foreach ($Key in $Fixed.Keys) {
		if ((Get-OnlyText $Data $Key) -cne $Fixed[$Key]) { throw 'Crash XML closed GameData value rejected.' }
	}
	$Run = Get-OnlyText $Data 'AethelnCrashRunId'
	if ($Run -cnotmatch '^[0-9a-f]{32}$' -or $Run -cne $ExpectedCrashRunId) { throw 'Crash XML marker binding rejected.' }
	$Flow = Get-OnlyText $Data 'AethelnFlowKind'
	if ($Flow -cne $ExpectedFlowKind) { throw 'Crash XML flow binding rejected.' }
	$EngineRevision = Get-OnlyText $Data 'AethelnEngineRevision'
	if ($EngineRevision -cnotmatch '^[A-Za-z0-9.+_-]{1,128}$' -or $EngineRevision -cne $ExpectedEngineRevision) { throw 'Crash XML engine revision binding rejected.' }

	# XML CrashGUID is engine-generated and deliberately not compared with a
	# launcher -CrashGUID override, folder name, or AethelnCrashRunId.
	[pscustomobject] [ordered]@{
		SchemaVersion = 1
		ProcessId = $ExpectedProcessId
		EngineCrashGuid = $EngineGuid
		CrashRunId = $Run
		BuildConfiguration = 'Development'
		EngineRevision = $EngineRevision
		NetworkProfileId = 'network-profile.unset'
		FlowKind = $Flow
	}
}
