[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SchemaPath = Join-Path $RepositoryRoot 'Config/ContentValidation/asset-intake-policy.schema.json'
$PolicyPath = Join-Path $RepositoryRoot 'Config/ContentValidation/asset-intake-policy.json'
$RuntimeIntakeSchemaPath = Join-Path $RepositoryRoot 'Config/ContentValidation/runtime-asset-intake.schema.json'
$RuntimeIntakePath = Join-Path $RepositoryRoot 'Config/ContentValidation/runtime-asset-intake.json'
$GameConfigPath = Join-Path $RepositoryRoot 'Config/DefaultGame.ini'
$DocumentationPath = Join-Path $RepositoryRoot 'docs/asset-intake-and-content-validation.md'
$ScannerSourcePath = Join-Path $RepositoryRoot 'Source/GameTests/Private/AethelnContentValidationScanner.cpp'
$PrimaryAssetHeaderPath = Join-Path $RepositoryRoot 'Source/GameCore/Public/AethelnPrimaryAssetDefinition.h'

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-ClosedProperties([object] $Value, [string[]] $Allowed, [string] $Context) {
	$Names = @(Get-JsonPropertyNames $Value)
	foreach ($Name in $Names) {
		Assert-True ($Allowed -contains $Name) "$Context contains unsupported field '$Name'."
	}
	foreach ($Name in $Allowed) {
		Assert-True ($Names -contains $Name) "$Context is missing required field '$Name'."
	}
}

function Copy-JsonObject([object] $Value) {
	return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Test-JsonObject([object] $Value) {
	return ($null -ne $Value -and ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Collections.IDictionary]))
}

function Test-JsonArray([object] $Value) {
	return ($null -ne $Value -and -not (Test-JsonObject $Value) -and -not ($Value -is [string]) -and $Value -is [System.Collections.IEnumerable])
}

function Test-JsonInteger([object] $Value) {
	return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
}

function Test-NonBlankJsonString([object] $Value) {
	return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Get-CanonicalNotApplicableEvidence([string] $FamilyId) {
	return "policy:${FamilyId}:not_applicable:no_observed_checks"
}

function ConvertFrom-JsonUtcTimestamp([object] $Value, [string] $Context) {
	Assert-True (Test-NonBlankJsonString $Value) "$Context must be a non-blank string."
	Assert-True ([string]$Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') "$Context must be a UTC timestamp ending in Z."
	$Parsed = [DateTimeOffset]::MinValue
	$Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
	Assert-True ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Parsed)) "$Context is malformed."
	return $Parsed
}

function Get-JsonPropertyNames([object] $Value) {
	if ($Value -is [System.Collections.IDictionary]) {
		return @($Value.Keys | ForEach-Object { [string]$_ })
	}
	return @($Value.PSObject.Properties.Name)
}

function Get-JsonProperty([object] $Value, [string] $Name) {
	if ($Value -is [System.Collections.IDictionary]) {
		foreach ($Key in $Value.Keys) {
			if ([string]$Key -ceq $Name) {
				return [pscustomobject]@{ Found = $true; Value = $Value[$Key] }
			}
		}
	}
	else {
		$Property = @($Value.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
		if ($Property.Count -eq 1) {
			return [pscustomobject]@{ Found = $true; Value = $Property[0].Value }
		}
	}
	return [pscustomobject]@{ Found = $false; Value = $null }
}

function Get-JsonTypeName([object] $Value) {
	if ($null -eq $Value) { return 'null' }
	if (Test-JsonObject $Value) { return 'object' }
	if (Test-JsonArray $Value) { return 'array' }
	if ($Value -is [string]) { return 'string' }
	if ($Value -is [bool]) { return 'boolean' }
	if (Test-JsonInteger $Value) { return 'integer' }
	if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return 'number' }
	return 'unsupported'
}

function Test-JsonDeepEqual([object] $Left, [object] $Right) {
	$LeftType = Get-JsonTypeName $Left
	$RightType = Get-JsonTypeName $Right
	if ($LeftType -cne $RightType) { return $false }
	if ($LeftType -ceq 'null') { return $true }
	if ($LeftType -ceq 'object') {
		$LeftNames = @(Get-JsonPropertyNames $Left)
		$RightNames = @(Get-JsonPropertyNames $Right)
		if ($LeftNames.Count -ne $RightNames.Count) { return $false }
		foreach ($Name in $LeftNames) {
			if ($RightNames -cnotcontains $Name) { return $false }
			$LeftProperty = Get-JsonProperty $Left $Name
			$RightProperty = Get-JsonProperty $Right $Name
			if (-not (Test-JsonDeepEqual $LeftProperty.Value $RightProperty.Value)) { return $false }
		}
		return $true
	}
	if ($LeftType -ceq 'array') {
		$LeftItems = @($Left)
		$RightItems = @($Right)
		if ($LeftItems.Count -ne $RightItems.Count) { return $false }
		for ($Index = 0; $Index -lt $LeftItems.Count; $Index++) {
			if (-not (Test-JsonDeepEqual $LeftItems[$Index] $RightItems[$Index])) { return $false }
		}
		return $true
	}
	if ($LeftType -ceq 'string') { return ([string]$Left -ceq [string]$Right) }
	return ($Left -eq $Right)
}

$SupportedPolicySchemaKeywords = @(
	'$schema',
	'$id',
	'title',
	'type',
	'additionalProperties',
	'required',
	'properties',
	'$defs',
	'$ref',
	'const',
	'enum',
	'items',
	'minItems',
	'maxItems',
	'uniqueItems',
	'minLength',
	'pattern',
	'minimum'
)

function Assert-SupportedPolicySchema([object] $SchemaNode, [string] $Context) {
	Assert-True (Test-JsonObject $SchemaNode) "$Context must be a JSON Schema object."
	foreach ($Keyword in @(Get-JsonPropertyNames $SchemaNode)) {
		Assert-True ($SupportedPolicySchemaKeywords -ccontains $Keyword) "$Context contains unsupported schema keyword '$Keyword'."
	}

	foreach ($MapKeyword in @('properties', '$defs')) {
		$SchemaMap = Get-JsonProperty $SchemaNode $MapKeyword
		if ($SchemaMap.Found) {
			Assert-True (Test-JsonObject $SchemaMap.Value) "$Context keyword '$MapKeyword' must be an object."
			foreach ($EntryName in @(Get-JsonPropertyNames $SchemaMap.Value)) {
				$Entry = Get-JsonProperty $SchemaMap.Value $EntryName
				Assert-SupportedPolicySchema $Entry.Value "$Context.$MapKeyword.$EntryName"
			}
		}
	}

	$Items = Get-JsonProperty $SchemaNode 'items'
	if ($Items.Found) {
		Assert-SupportedPolicySchema $Items.Value "$Context.items"
	}
}

function Resolve-LocalJsonSchemaReference([object] $RootSchema, [string] $Reference) {
	Assert-True ($Reference.StartsWith('#/')) "Schema reference '$Reference' is not a supported local reference."
	$Current = $RootSchema
	foreach ($RawSegment in $Reference.Substring(2).Split('/')) {
		$Segment = $RawSegment.Replace('~1', '/').Replace('~0', '~')
		Assert-True (Test-JsonObject $Current) "Schema reference '$Reference' traverses a non-object segment."
		$Property = Get-JsonProperty $Current $Segment
		Assert-True $Property.Found "Schema reference '$Reference' does not resolve."
		$Current = $Property.Value
	}
	return $Current
}

function Assert-JsonSchemaNode([object] $Value, [object] $SchemaNode, [object] $RootSchema, [string] $Context, [int] $Depth) {
	Assert-True ($Depth -le 100) "$Context exceeds the supported schema-reference depth."

	$Reference = Get-JsonProperty $SchemaNode '$ref'
	if ($Reference.Found) {
		Assert-True ($Reference.Value -is [string]) "$Context has a non-string schema reference."
		$ReferencedSchema = Resolve-LocalJsonSchemaReference $RootSchema ([string]$Reference.Value)
		Assert-JsonSchemaNode $Value $ReferencedSchema $RootSchema $Context ($Depth + 1)
	}

	$ExpectedType = Get-JsonProperty $SchemaNode 'type'
	if ($ExpectedType.Found) {
		Assert-True ($ExpectedType.Value -is [string] -and @('object', 'array', 'string', 'integer', 'boolean') -ccontains [string]$ExpectedType.Value) "$Context uses an unsupported schema type '$($ExpectedType.Value)'."
		$ActualType = Get-JsonTypeName $Value
		Assert-True ($ActualType -ceq [string]$ExpectedType.Value) "$Context expected type $($ExpectedType.Value) but found $ActualType."
	}

	$Minimum = Get-JsonProperty $SchemaNode 'minimum'
	if ($Minimum.Found) {
		Assert-True (Test-JsonInteger $Minimum.Value) "$Context minimum must be a JSON integer."
		Assert-True (Test-JsonInteger $Value) "$Context minimum can only validate a JSON integer."
		Assert-True ([long]$Value -ge [long]$Minimum.Value) "$Context is less than minimum $($Minimum.Value)."
	}

	$Const = Get-JsonProperty $SchemaNode 'const'
	if ($Const.Found) {
		Assert-True (Test-JsonDeepEqual $Value $Const.Value) "$Context does not match its const value."
	}

	$Enum = Get-JsonProperty $SchemaNode 'enum'
	if ($Enum.Found) {
		Assert-True (Test-JsonArray $Enum.Value) "$Context enum must be an array."
		$MatchesEnum = $false
		foreach ($AllowedValue in @($Enum.Value)) {
			if (Test-JsonDeepEqual $Value $AllowedValue) {
				$MatchesEnum = $true
				break
			}
		}
		Assert-True $MatchesEnum "$Context does not match any enum value."
	}

	if (Test-JsonObject $Value) {
		$Properties = Get-JsonProperty $SchemaNode 'properties'
		$Required = Get-JsonProperty $SchemaNode 'required'
		if ($Required.Found) {
			Assert-True (Test-JsonArray $Required.Value) "$Context required keyword must be an array."
			foreach ($RequiredName in @($Required.Value)) {
				Assert-True ($RequiredName -is [string]) "$Context required entries must be strings."
				$RequiredProperty = Get-JsonProperty $Value ([string]$RequiredName)
				Assert-True $RequiredProperty.Found "$Context is missing required property '$RequiredName'."
			}
		}
		if ($Properties.Found) {
			Assert-True (Test-JsonObject $Properties.Value) "$Context properties keyword must be an object."
			foreach ($PropertyName in @(Get-JsonPropertyNames $Properties.Value)) {
				$PropertyValue = Get-JsonProperty $Value $PropertyName
				if ($PropertyValue.Found) {
					$PropertySchema = Get-JsonProperty $Properties.Value $PropertyName
					Assert-JsonSchemaNode $PropertyValue.Value $PropertySchema.Value $RootSchema "$Context.$PropertyName" ($Depth + 1)
				}
			}
		}

		$AdditionalProperties = Get-JsonProperty $SchemaNode 'additionalProperties'
		if ($AdditionalProperties.Found) {
			Assert-True ($AdditionalProperties.Value -is [bool]) "$Context additionalProperties must be boolean."
			if (-not $AdditionalProperties.Value) {
				$AllowedProperties = if ($Properties.Found) { @(Get-JsonPropertyNames $Properties.Value) } else { @() }
				foreach ($PropertyName in @(Get-JsonPropertyNames $Value)) {
					Assert-True ($AllowedProperties -ccontains $PropertyName) "$Context contains unsupported property '$PropertyName'."
				}
			}
		}
	}

	if (Test-JsonArray $Value) {
		$Items = @($Value)
		$MinItems = Get-JsonProperty $SchemaNode 'minItems'
		if ($MinItems.Found) {
			Assert-True ($Items.Count -ge [long]$MinItems.Value) "$Context contains fewer than $($MinItems.Value) items."
		}
		$MaxItems = Get-JsonProperty $SchemaNode 'maxItems'
		if ($MaxItems.Found) {
			Assert-True ($Items.Count -le [long]$MaxItems.Value) "$Context contains more than $($MaxItems.Value) items."
		}
		$UniqueItems = Get-JsonProperty $SchemaNode 'uniqueItems'
		if ($UniqueItems.Found) {
			Assert-True ($UniqueItems.Value -is [bool]) "$Context uniqueItems must be boolean."
			if ($UniqueItems.Value) {
				for ($LeftIndex = 0; $LeftIndex -lt $Items.Count; $LeftIndex++) {
					for ($RightIndex = $LeftIndex + 1; $RightIndex -lt $Items.Count; $RightIndex++) {
						Assert-True (-not (Test-JsonDeepEqual $Items[$LeftIndex] $Items[$RightIndex])) "$Context contains duplicate items at indexes $LeftIndex and $RightIndex."
					}
				}
			}
		}
		$ItemSchema = Get-JsonProperty $SchemaNode 'items'
		if ($ItemSchema.Found) {
			for ($Index = 0; $Index -lt $Items.Count; $Index++) {
				Assert-JsonSchemaNode $Items[$Index] $ItemSchema.Value $RootSchema "${Context}[$Index]" ($Depth + 1)
			}
		}
	}

	if ($Value -is [string]) {
		$MinLength = Get-JsonProperty $SchemaNode 'minLength'
		if ($MinLength.Found) {
			Assert-True ($Value.Length -ge [long]$MinLength.Value) "$Context is shorter than $($MinLength.Value) characters."
		}
		$Pattern = Get-JsonProperty $SchemaNode 'pattern'
		if ($Pattern.Found) {
			Assert-True ([regex]::IsMatch($Value, [string]$Pattern.Value)) "$Context does not match pattern '$($Pattern.Value)'."
		}
	}
}

function Assert-JsonSchemaConformance([object] $Value, [object] $Schema, [string] $Context) {
	Assert-SupportedPolicySchema $Schema '$schema'
	Assert-JsonSchemaNode $Value $Schema $Schema $Context 0
}

function Assert-JsonSchemaRejects([object] $Value, [object] $Schema, [string] $ExpectedMessage, [string] $Context) {
	$Failure = $null
	try { Assert-JsonSchemaConformance $Value $Schema $Context } catch { $Failure = $_.Exception.Message }
	Assert-True (-not [string]::IsNullOrWhiteSpace($Failure)) "$Context must fail schema validation."
	Assert-True ($Failure -match $ExpectedMessage) "$Context failed with an unexpected diagnostic: $Failure"
}

function Get-IniSectionLines([string] $ConfigText, [string] $SectionName, [string] $Context) {
	$EscapedSectionName = [regex]::Escape($SectionName)
	$Sections = [regex]::Matches($ConfigText, "(?ms)^\[$EscapedSectionName\]\s*(?<Body>.*?)(?=^\[|\z)")
	Assert-True ($Sections.Count -eq 1) "$Context must contain exactly one [$SectionName] section."
	return @(
		$Sections[0].Groups['Body'].Value -split '\r?\n' |
			ForEach-Object { $_.Trim() } |
			Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith(';') }
	)
}

function ConvertFrom-PrimaryAssetScanRecord([string] $Line, [string] $Context) {
	$Pattern = '^\+PrimaryAssetTypesToScan=\(PrimaryAssetType="(?<PrimaryAssetType>[A-Za-z][A-Za-z0-9_]*)",AssetBaseClass=(?:"(?<QuotedBaseClass>/Script/[A-Za-z0-9_.]+)"|(?<BareBaseClass>/Script/[A-Za-z0-9_.]+)),bHasBlueprintClasses=(?<HasBlueprintClasses>True|False),bIsEditorOnly=(?<IsEditorOnly>True|False),Directories=\(\(Path="(?<Directory>/Game(?:/[A-Za-z0-9_]+)*)"\)\),SpecificAssets=(?<SpecificAssets>[^,]*),Rules=\(Priority=(?<Priority>-?\d+),ChunkId=(?<ChunkId>-?\d+),bApplyRecursively=(?<ApplyRecursively>True|False),CookRule=(?<CookRule>[A-Za-z][A-Za-z0-9_]*)\)\)$'
	$RecordMatch = [regex]::Match($Line, $Pattern)
	Assert-True $RecordMatch.Success "$Context is not a canonical PrimaryAssetTypesToScan record: '$Line'."
	$AssetBaseClass = if ($RecordMatch.Groups['QuotedBaseClass'].Success) { $RecordMatch.Groups['QuotedBaseClass'].Value } else { $RecordMatch.Groups['BareBaseClass'].Value }
	return [pscustomobject]@{
		PrimaryAssetType = $RecordMatch.Groups['PrimaryAssetType'].Value
		AssetBaseClass = $AssetBaseClass
		HasBlueprintClasses = $RecordMatch.Groups['HasBlueprintClasses'].Value
		IsEditorOnly = $RecordMatch.Groups['IsEditorOnly'].Value
		Directory = $RecordMatch.Groups['Directory'].Value
		SpecificAssets = $RecordMatch.Groups['SpecificAssets'].Value
		Priority = $RecordMatch.Groups['Priority'].Value
		ChunkId = $RecordMatch.Groups['ChunkId'].Value
		ApplyRecursively = $RecordMatch.Groups['ApplyRecursively'].Value
		CookRule = $RecordMatch.Groups['CookRule'].Value
	}
}

function Assert-AssetManagerConfiguration([string] $ProjectConfig, [string] $PinnedBaseConfig, [string] $Context) {
	$SectionName = '/Script/Engine.AssetManagerSettings'
	$BaseLines = @(Get-IniSectionLines $PinnedBaseConfig $SectionName "$Context pinned BaseGame.ini")
	$KeyCommands = @($BaseLines | Where-Object { $_ -match 'PrimaryAssetTypesToScan' -and $_.StartsWith('@') })
	Assert-True ($KeyCommands.Count -eq 1 -and $KeyCommands[0] -ceq '@PrimaryAssetTypesToScan=PrimaryAssetType') "$Context pinned BaseGame.ini must key PrimaryAssetTypesToScan records by PrimaryAssetType."
	$BaseScanLines = @($BaseLines | Where-Object { $_ -match 'PrimaryAssetTypesToScan' -and -not $_.StartsWith('@') })
	$BaseRecords = @($BaseScanLines | ForEach-Object { ConvertFrom-PrimaryAssetScanRecord $_ "$Context pinned BaseGame.ini" })

	$ProjectLines = @(Get-IniSectionLines $ProjectConfig $SectionName "$Context DefaultGame.ini")
	$ProjectScanLines = @($ProjectLines | Where-Object { $_ -match 'PrimaryAssetTypesToScan' })
	$ProjectRecords = [System.Collections.Generic.List[object]]::new()
	$ProjectTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($ScanLine in $ProjectScanLines) {
		$Record = ConvertFrom-PrimaryAssetScanRecord $ScanLine "$Context DefaultGame.ini"
		Assert-True ($ProjectTypes.Add($Record.PrimaryAssetType)) "$Context DefaultGame.ini contains duplicate or conflicting project PrimaryAssetType '$($Record.PrimaryAssetType)' records."
		$ProjectRecords.Add($Record)
	}
	Assert-True ($ProjectRecords.Count -eq 3) "$Context DefaultGame.ini must define exactly the Map, PrimaryAssetLabel, and AethelnContent keyed scan records."

	$EffectiveRecords = [ordered]@{}
	$EffectiveSources = [ordered]@{}
	foreach ($Record in $BaseRecords) {
		$EffectiveRecords[$Record.PrimaryAssetType] = $Record
		$EffectiveSources[$Record.PrimaryAssetType] = 'BaseGame.ini'
	}
	foreach ($Record in $ProjectRecords) {
		# Reproduce ConfigCacheIni's pinned keyed-struct merge: replace the
		# existing matching PrimaryAssetType in place, otherwise add it.
		$EffectiveRecords[$Record.PrimaryAssetType] = $Record
		$EffectiveSources[$Record.PrimaryAssetType] = 'DefaultGame.ini'
	}

	$ExpectedRecords = [ordered]@{
		Map = [ordered]@{ AssetBaseClass='/Script/Engine.World'; HasBlueprintClasses='False'; IsEditorOnly='False'; Directory='/Game/Maps'; SpecificAssets=''; Priority='0'; ChunkId='-1'; ApplyRecursively='True'; CookRule='Unknown' }
		PrimaryAssetLabel = [ordered]@{ AssetBaseClass='/Script/Engine.PrimaryAssetLabel'; HasBlueprintClasses='False'; IsEditorOnly='True'; Directory='/Game'; SpecificAssets=''; Priority='0'; ChunkId='-1'; ApplyRecursively='True'; CookRule='Unknown' }
		AethelnContent = [ordered]@{ AssetBaseClass='/Script/GameCore.AethelnPrimaryAssetDefinition'; HasBlueprintClasses='False'; IsEditorOnly='False'; Directory='/Game'; SpecificAssets=''; Priority='0'; ChunkId='-1'; ApplyRecursively='True'; CookRule='Unknown' }
	}
	Assert-True ($EffectiveRecords.Count -eq $ExpectedRecords.Count) "$Context merged Asset Manager configuration must contain exactly three effective primary asset types."
	foreach ($AssetType in $ExpectedRecords.Keys) {
		Assert-True ($EffectiveRecords.Contains($AssetType)) "$Context merged Asset Manager configuration is missing '$AssetType'."
		Assert-True ($EffectiveSources[$AssetType] -ceq 'DefaultGame.ini') "$Context '$AssetType' must use the project keyed override."
		foreach ($Field in $ExpectedRecords[$AssetType].Keys) {
			Assert-True ([string]$EffectiveRecords[$AssetType].$Field -ceq [string]$ExpectedRecords[$AssetType][$Field]) "$Context '$AssetType' field '$Field' is '$($EffectiveRecords[$AssetType].$Field)' instead of '$($ExpectedRecords[$AssetType][$Field])'."
		}
	}
}

function Assert-AssetManagerConfigurationRejected([string] $ProjectConfig, [string] $PinnedBaseConfig, [string] $ExpectedMessage, [string] $Context) {
	$Failure = $null
	try { Assert-AssetManagerConfiguration $ProjectConfig $PinnedBaseConfig $Context } catch { $Failure = $_.Exception.Message }
	Assert-True (-not [string]::IsNullOrWhiteSpace($Failure)) "$Context must fail Asset Manager configuration validation."
	Assert-True ($Failure -match $ExpectedMessage) "$Context failed with an unexpected diagnostic: $Failure"
}

Assert-True (Test-Path -LiteralPath $SchemaPath -PathType Leaf) 'The governed intake schema must exist.'
Assert-True (Test-Path -LiteralPath $PolicyPath -PathType Leaf) 'The repository intake policy must exist.'
Assert-True (Test-Path -LiteralPath $RuntimeIntakeSchemaPath -PathType Leaf) 'The closed runtime asset-intake schema must exist.'
Assert-True (Test-Path -LiteralPath $RuntimeIntakePath -PathType Leaf) 'The complete runtime asset-intake registry must exist.'
Assert-True (Test-Path -LiteralPath $GameConfigPath -PathType Leaf) 'The Asset Manager configuration must exist.'
Assert-True (Test-Path -LiteralPath $DocumentationPath -PathType Leaf) 'The contributor asset-intake contract must exist.'
Assert-True (Test-Path -LiteralPath $ScannerSourcePath -PathType Leaf) 'The production content scanner source must exist.'
Assert-True (Test-Path -LiteralPath $PrimaryAssetHeaderPath -PathType Leaf) 'The governed primary asset definition header must exist.'

$Schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
$Policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
$RuntimeIntakeSchema = Get-Content -LiteralPath $RuntimeIntakeSchemaPath -Raw | ConvertFrom-Json
$RuntimeIntake = Get-Content -LiteralPath $RuntimeIntakePath -Raw | ConvertFrom-Json
$GameConfig = Get-Content -LiteralPath $GameConfigPath -Raw
$Documentation = Get-Content -LiteralPath $DocumentationPath -Raw
$DocumentationNormalized = $Documentation -replace '\s+', ' '
$ScannerSource = Get-Content -LiteralPath $ScannerSourcePath -Raw
$PrimaryAssetHeader = Get-Content -LiteralPath $PrimaryAssetHeaderPath -Raw

Assert-True ($Schema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema') 'The policy schema must identify JSON Schema 2020-12.'
Assert-True ($Schema.'$id' -eq 'https://aetheln.invalid/schemas/asset-intake-policy-v2.json') 'The policy schema ID must identify the closed v2 contract.'
Assert-True ($Schema.additionalProperties -eq $false) 'The policy schema must reject unknown top-level fields.'
Assert-True ($RuntimeIntakeSchema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema') 'The runtime intake schema must identify JSON Schema 2020-12.'
Assert-True ($RuntimeIntakeSchema.'$id' -eq 'https://aetheln.invalid/schemas/runtime-asset-intake-v1.json') 'The runtime intake schema ID must be stable.'
Assert-True ($RuntimeIntakeSchema.additionalProperties -eq $false) 'The runtime intake schema must reject unknown top-level fields.'
Assert-True ($ScannerSource -match 'IsDataValid\s*\(' -and $ScannerSource -match 'GetAsset\s*\(') 'The production scanner must load each governed asset and run UObject data validation after registry closure.'
foreach ($ApiFact in @('GetBodySetup','GetNumLODs','GetTextureStreamingMethod','UMaterialInstance','GetSkeleton','GetPhysicsAsset','PersistentLevel','GetWorldSettings','GetWorldPartition','GetDataLayerManager','ANavigationData','GetDependencies','GetModuleFilename','FTargetReceipt','FModuleManifest')) {
	Assert-True ($ScannerSource -match [regex]::Escape($ApiFact)) "The production scanner must derive the pinned UE fact '$ApiFact'."
}
foreach ($PropertyName in @('StableContentId','ContentVersion','Audience')) {
	Assert-True ($PrimaryAssetHeader -match "(?s)AssetRegistrySearchable[^;]*\b$PropertyName\b") "The reflected property '$PropertyName' must be Asset Registry searchable."
	$TagPattern = 'Tags\.FindRef\(TEXT\("{0}"\)\)' -f [regex]::Escape($PropertyName)
	Assert-True ($ScannerSource -match $TagPattern) "The live registry scanner must compare the searchable '$PropertyName' tag."
}
foreach ($VerdictName in @('deterministic_status','promotion_status','check_results')) {
	$VerdictPattern = 'Tag\.Key == TEXT\("{0}"\)' -f [regex]::Escape($VerdictName)
	Assert-True ($ScannerSource -match $VerdictPattern) "Injected snapshots must reject verdict-shaped tag '$VerdictName'."
}

# Portable snapshot from pinned UE commit
# 71fe36aac5a8df5ccd66c763ffc902b29b6a9c43, Engine/Config/BaseGame.ini.
$PinnedBaseGameAssetManagerConfig = @'
[/Script/Engine.AssetManagerSettings]
@PrimaryAssetTypesToScan=PrimaryAssetType
+PrimaryAssetTypesToScan=(PrimaryAssetType="Map",AssetBaseClass=/Script/Engine.World,bHasBlueprintClasses=False,bIsEditorOnly=True,Directories=((Path="/Game/Maps")),SpecificAssets=,Rules=(Priority=-1,ChunkId=-1,bApplyRecursively=True,CookRule=Unknown))
+PrimaryAssetTypesToScan=(PrimaryAssetType="PrimaryAssetLabel",AssetBaseClass=/Script/Engine.PrimaryAssetLabel,bHasBlueprintClasses=False,bIsEditorOnly=True,Directories=((Path="/Game")),SpecificAssets=,Rules=(Priority=-1,ChunkId=-1,bApplyRecursively=True,CookRule=Unknown))
'@
Assert-AssetManagerConfiguration $GameConfig $PinnedBaseGameAssetManagerConfig 'Repository Asset Manager configuration'

$AssetManagerLines = @(Get-IniSectionLines $GameConfig '/Script/Engine.AssetManagerSettings' 'Repository DefaultGame.ini')
$MapScanLine = @($AssetManagerLines | Where-Object { $_ -match 'PrimaryAssetType="Map"' })[0]
$SuffixConfig = $GameConfig.Replace($MapScanLine, "${MapScanLine}suffix")
Assert-AssetManagerConfigurationRejected $SuffixConfig $PinnedBaseGameAssetManagerConfig 'not a canonical.*suffix' 'Suffixed scan record fixture'
$PrefixConfig = $GameConfig.Replace($MapScanLine, "prefix${MapScanLine}")
Assert-AssetManagerConfigurationRejected $PrefixConfig $PinnedBaseGameAssetManagerConfig 'not a canonical.*prefix' 'Prefixed scan record fixture'
$ExtraFieldConfig = $GameConfig.Replace($MapScanLine, $MapScanLine.Replace(',SpecificAssets=', ',UnexpectedField=True,SpecificAssets='))
Assert-AssetManagerConfigurationRejected $ExtraFieldConfig $PinnedBaseGameAssetManagerConfig 'not a canonical.*UnexpectedField' 'Extra-field scan record fixture'
$DuplicateConfig = $GameConfig.TrimEnd() + [Environment]::NewLine + $MapScanLine + [Environment]::NewLine
Assert-AssetManagerConfigurationRejected $DuplicateConfig $PinnedBaseGameAssetManagerConfig 'duplicate or conflicting.*Map' 'Duplicate scan record fixture'
$ConflictingMapLine = $MapScanLine.Replace('bIsEditorOnly=False', 'bIsEditorOnly=True')
$ConflictingConfig = $GameConfig.TrimEnd() + [Environment]::NewLine + $ConflictingMapLine + [Environment]::NewLine
Assert-AssetManagerConfigurationRejected $ConflictingConfig $PinnedBaseGameAssetManagerConfig 'duplicate or conflicting.*Map' 'Conflicting scan record fixture'
Write-Output 'PASS: pinned keyed Asset Manager merge and strict project scan records fail closed'

$ExpectedLifecycle = @('concept_reference', 'temporary_prototype', 'runtime_candidate', 'production_approved')
$ExpectedAudience = @('shared', 'server_only', 'client_only')
$ExpectedFamilies = @('collision', 'rendering_suitability', 'texture', 'material', 'skeletal_animation', 'map_world', 'navigation', 'reference_boundary')
$ExpectedChecksByFamily = [ordered]@{
	collision = @('profile','simple_complex_policy','presentation_equivalence')
	rendering_suitability = @('lod','hlod','nanite_suitability','streaming')
	texture = @('pbr_channels','tiling','compression','mips','streaming')
	material = @('material_instance_policy','shader_complexity_evidence')
	skeletal_animation = @('rig_compatibility','morph_policy','influences','socket_ownership','animation_complexity')
	map_world = @('map_identity','data_layers','pcg_authority','runtime_editor_boundary')
	navigation = @('navigation_data_audience','streaming_boundaries','runtime_rebuild_policy')
	reference_boundary = @('stable_id_unique','redirectors','broken_references','compatible_content_version','audience_reachability','hard_reference_exceptions')
}

Assert-JsonSchemaConformance $Policy $Schema 'Repository policy'
Write-Output 'PASS: repository policy conforms to its closed JSON Schema'

$UnknownTopLevelPolicy = Copy-JsonObject $Policy
Add-Member -InputObject $UnknownTopLevelPolicy -MemberType NoteProperty -Name 'unexpected_top_level' -Value $true
Assert-JsonSchemaRejects $UnknownTopLevelPolicy $Schema 'unexpected_top_level' 'Unknown top-level field'

$UnknownNestedPolicy = Copy-JsonObject $Policy
Add-Member -InputObject $UnknownNestedPolicy.references.hard_reference_exceptions -MemberType NoteProperty -Name 'unexpected_nested' -Value $true
Assert-JsonSchemaRejects $UnknownNestedPolicy $Schema 'unexpected_nested' 'Unknown nested field'

$WrongTypePolicy = Copy-JsonObject $Policy
$WrongTypePolicy.policy_families[0].checks = 'simple_collision'
Assert-JsonSchemaRejects $WrongTypePolicy $Schema 'expected type array' 'Type constraint'

$InvalidEnumPolicy = Copy-JsonObject $Policy
$InvalidEnumPolicy.lifecycle_states[0] = 'unknown_state'
Assert-JsonSchemaRejects $InvalidEnumPolicy $Schema 'enum' 'Enum constraint'

$InvalidConstPolicy = Copy-JsonObject $Policy
$InvalidConstPolicy.lifecycle_gates.repository_presence_implies_approval = $true
Assert-JsonSchemaRejects $InvalidConstPolicy $Schema 'const' 'Const constraint'

$InvalidReferencedPolicy = Copy-JsonObject $Policy
$InvalidReferencedPolicy.references.hard_reference_exceptions.default_allowed = $true
Assert-JsonSchemaRejects $InvalidReferencedPolicy $Schema 'default_allowed.*const' 'Local reference constraint'

$UnsupportedKeywordSchema = Copy-JsonObject $Schema
Add-Member -InputObject $UnsupportedKeywordSchema.properties.schema_id -MemberType NoteProperty -Name 'maxLength' -Value 64
Assert-JsonSchemaRejects $Policy $UnsupportedKeywordSchema "unsupported schema keyword 'maxLength'" 'Unsupported validation keyword'
Write-Output 'PASS: schema rejects unknown fields and type, enum, const, local-ref, and unsupported-keyword violations'

$TrackedRuntimePaths = @(
	& git -C $RepositoryRoot ls-files -- 'Content/**' |
		Where-Object { $_ -cmatch '^Content/.+\.(?:uasset|umap)$' } |
		Sort-Object
)
Assert-True ($LASTEXITCODE -eq 0) 'git ls-files failed while enumerating committed runtime packages.'
Assert-True ($TrackedRuntimePaths.Count -gt 0) 'The repository contains no committed runtime packages to govern.'

$LfsHashesByPath = @{}
$LfsLines = @(& git -C $RepositoryRoot lfs ls-files -l)
Assert-True ($LASTEXITCODE -eq 0) 'git lfs ls-files failed while reading committed runtime package hashes.'
foreach ($Line in $LfsLines) {
	$Match = [regex]::Match([string]$Line, '^(?<Hash>[0-9a-f]{64})\s+[*-]\s+(?<Path>Content/.+\.(?:uasset|umap))$')
	if ($Match.Success) { $LfsHashesByPath[$Match.Groups['Path'].Value] = $Match.Groups['Hash'].Value }
}

$AttributesByPath = @{}
$AttributeLines = @(& git -C $RepositoryRoot check-attr filter lockable -- @TrackedRuntimePaths)
Assert-True ($LASTEXITCODE -eq 0) 'git check-attr failed while verifying runtime package safeguards.'
foreach ($Line in $AttributeLines) {
	$Match = [regex]::Match([string]$Line, '^(?<Path>Content/.+\.(?:uasset|umap)): (?<Attribute>filter|lockable): (?<Value>.+)$')
	if (-not $Match.Success) { continue }
	$Path = $Match.Groups['Path'].Value
	if (-not $AttributesByPath.ContainsKey($Path)) { $AttributesByPath[$Path] = @{} }
	$AttributesByPath[$Path][$Match.Groups['Attribute'].Value] = $Match.Groups['Value'].Value
}

function Assert-LifecycleTransitionEvidence([object] $Asset, [object] $SourceGroup, [string] $Context) {
	$Evidence = $Asset.lifecycle_evidence
	Assert-ClosedProperties $Evidence @('content_identity','temporary_prototype','runtime_candidate','production_approval') "$Context lifecycle evidence"
	Assert-True ($Evidence.content_identity.stable_id -ceq $Asset.stable_id -and [int]$Evidence.content_identity.content_version -eq [int]$Asset.content_version -and $Evidence.content_identity.content_sha256 -ceq $Asset.content_sha256) "$Context lifecycle evidence does not bind the exact content identity."
	$Temporary = @($Evidence.temporary_prototype); $Candidate = @($Evidence.runtime_candidate); $Production = @($Evidence.production_approval)
	if ($Asset.lifecycle_state -ceq 'temporary_prototype') {
		Assert-True ($Temporary.Count -eq 1 -and $Candidate.Count -eq 0 -and $Production.Count -eq 0 -and $SourceGroup.approval_state -ceq 'temporary_prototype_only' -and $Temporary[0].may_be_runtime_candidate -eq $false) "$Context temporary evidence is invalid."
		return
	}
	Assert-True ($Temporary.Count -eq 0 -and $Candidate.Count -eq 1) "$Context runtime-candidate evidence is missing."
	Assert-True ($Candidate[0].review_revision -cmatch '^[0-9a-f]{40}$' -and $Candidate[0].stable_id -ceq $Asset.stable_id -and [int]$Candidate[0].content_version -eq [int]$Asset.content_version -and $Candidate[0].content_sha256 -ceq $Asset.content_sha256) "$Context runtime-candidate evidence does not bind exact revision and content identity."
	if ($Asset.lifecycle_state -ceq 'runtime_candidate') {
		Assert-True ($Production.Count -eq 0 -and $SourceGroup.approval_state -ceq 'runtime_candidate_approved') "$Context runtime-candidate source approval is invalid."
		return
	}
	Assert-True ($Production.Count -eq 1 -and $SourceGroup.approval_state -ceq 'production_approved') "$Context production approval is missing."
	Assert-True ($Production[0].candidate_review_revision -ceq $Candidate[0].review_revision -and $Production[0].candidate_approval_record -ceq $Candidate[0].approval_record -and $Production[0].production_revision -cmatch '^[0-9a-f]{40}$' -and $Production[0].stable_id -ceq $Asset.stable_id -and [int]$Production[0].content_version -eq [int]$Asset.content_version -and $Production[0].content_sha256 -ceq $Asset.content_sha256) "$Context production approval does not bind exact candidate approval and content identity."
}

function Assert-RuntimeIntakeContract([object] $Registry, [string] $Context, [bool] $ValidateSchema = $true) {
	if ($ValidateSchema) { Assert-JsonSchemaConformance $Registry $RuntimeIntakeSchema $Context }
	Assert-True ($Registry.schema_id -ceq 'aetheln.runtime-asset-intake' -and $Registry.schema_version -eq 1) "$Context has an incompatible registry schema identity."
	Assert-True ($Registry.policy_schema_id -ceq $Policy.schema_id -and $Registry.policy_schema_version -eq $Policy.schema_version) "$Context does not bind the current policy schema identity."
	Assert-True ($Registry.content_root -ceq 'Content/' -and $Registry.package_root -ceq '/Game') "$Context has unsupported runtime roots."

	$SourceGroups = @($Registry.source_groups)
	$Assets = @($Registry.assets)
	Assert-True ($Registry.expected_asset_count -eq $Assets.Count) "$Context expected_asset_count does not match its asset records."
	Assert-True ($Assets.Count -eq $TrackedRuntimePaths.Count) "$Context does not contain exactly one record for every committed runtime package."

	$SourceGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($SourceGroup in $SourceGroups) {
		Assert-True ($SourceGroupIds.Add([string]$SourceGroup.id)) "$Context contains duplicate source group '$($SourceGroup.id)'."
		Assert-True ($SourceGroup.approval_state -ceq 'temporary_prototype_only') "$Context source group '$($SourceGroup.id)' implies an unsupported approval state."
	}
	$ExpectedSourceGroups = @(
		'issue-13-starter-map',
		'issue-100-epic-character-template',
		'issue-100-epic-level-prototyping-template',
		'issue-100-repository-authored-poc',
		'issue-100-template-derived-poc-animation'
	)
	Assert-True ($SourceGroupIds.Count -eq $ExpectedSourceGroups.Count) "$Context contains an unexpected source-group count."
	foreach ($SourceGroupId in $ExpectedSourceGroups) {
		Assert-True ($SourceGroupIds.Contains($SourceGroupId)) "$Context is missing source group '$SourceGroupId'."
	}

	$RepositoryPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$AssetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$StableIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$UsedSourceGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($Asset in $Assets) {
		Assert-True ($RepositoryPaths.Add([string]$Asset.repository_path)) "$Context contains duplicate repository_path '$($Asset.repository_path)'."
		Assert-True ($AssetPaths.Add([string]$Asset.asset_path)) "$Context contains duplicate asset_path '$($Asset.asset_path)'."
		Assert-True ($StableIds.Add([string]$Asset.stable_id)) "$Context contains duplicate stable_id '$($Asset.stable_id)'."
		Assert-True ($TrackedRuntimePaths -ccontains [string]$Asset.repository_path) "$Context names untracked runtime package '$($Asset.repository_path)'."
		$ExpectedAssetPath = ([string]$Asset.repository_path -replace '^Content/', '/Game/' -replace '\.(?:uasset|umap)$', '')
		Assert-True ($Asset.asset_path -ceq $ExpectedAssetPath) "$Context asset_path '$($Asset.asset_path)' does not match repository_path '$($Asset.repository_path)'."
		Assert-True ($LfsHashesByPath.ContainsKey([string]$Asset.repository_path)) "$Context package '$($Asset.repository_path)' is not tracked by Git LFS."
		Assert-True ($Asset.content_sha256 -ceq $LfsHashesByPath[[string]$Asset.repository_path]) "$Context package '$($Asset.repository_path)' content_sha256 does not match its committed LFS object."
		Assert-True ($AttributesByPath.ContainsKey([string]$Asset.repository_path)) "$Context package '$($Asset.repository_path)' has no source-control attribute record."
		Assert-True ($AttributesByPath[[string]$Asset.repository_path]['filter'] -ceq 'lfs') "$Context package '$($Asset.repository_path)' does not use the LFS filter."
		Assert-True ($AttributesByPath[[string]$Asset.repository_path]['lockable'] -ceq 'set') "$Context package '$($Asset.repository_path)' is not lockable."
		Assert-True ($SourceGroupIds.Contains([string]$Asset.source_group_id)) "$Context asset '$($Asset.asset_path)' names unknown source group '$($Asset.source_group_id)'."
		[void]$UsedSourceGroups.Add([string]$Asset.source_group_id)
		Assert-LifecycleTransitionEvidence $Asset (@($SourceGroups | Where-Object { $_.id -ceq $Asset.source_group_id })[0]) "$Context asset '$($Asset.asset_path)'"
		Assert-True ($Asset.lifecycle_state -ceq 'temporary_prototype') "$Context current package '$($Asset.asset_path)' must remain an explicit temporary prototype."
		Assert-True (Test-JsonObject $Asset.lifecycle_evidence) "$Context package '$($Asset.asset_path)' must carry closed lifecycle evidence."
		Assert-ClosedProperties $Asset.lifecycle_evidence @('content_identity','temporary_prototype','runtime_candidate','production_approval') "$Context lifecycle evidence"
		Assert-True ($Asset.lifecycle_evidence.content_identity.stable_id -ceq $Asset.stable_id -and [int]$Asset.lifecycle_evidence.content_identity.content_version -eq [int]$Asset.content_version -and $Asset.lifecycle_evidence.content_identity.content_sha256 -ceq $Asset.content_sha256) "$Context lifecycle evidence must bind the exact governed content identity."
		Assert-True (@($Asset.lifecycle_evidence.temporary_prototype).Count -eq 1 -and @($Asset.lifecycle_evidence.runtime_candidate).Count -eq 0 -and @($Asset.lifecycle_evidence.production_approval).Count -eq 0) "$Context temporary package '$($Asset.asset_path)' must have exactly one temporary record and no promotion records."
		$TemporaryEvidence = @($Asset.lifecycle_evidence.temporary_prototype)[0]
		Assert-True ($TemporaryEvidence.may_be_runtime_candidate -eq $false) "$Context temporary package '$($Asset.asset_path)' must not be promotion-capable."
		Assert-True ([string]$TemporaryEvidence.approval_record -match 'not production approval') "$Context temporary package '$($Asset.asset_path)' does not explicitly reject production approval."

		if ($Asset.repository_path -ceq 'Content/Maps/StarterMap.umap') {
			Assert-True ($Asset.source_group_id -ceq 'issue-13-starter-map' -and $TemporaryEvidence.owner -ceq 'Issue #13' -and $Asset.audience -ceq 'shared') "$Context StarterMap governance does not match the Issue #13 bootstrap record."
		}
		else {
			Assert-True ($TemporaryEvidence.owner -ceq 'Issue #100' -and $Asset.audience -ceq 'client_only') "$Context Issue #100 package '$($Asset.asset_path)' must remain client-only temporary POC content."
		}
	}
	foreach ($TrackedRuntimePath in $TrackedRuntimePaths) {
		Assert-True ($RepositoryPaths.Contains($TrackedRuntimePath)) "$Context is missing committed runtime package '$TrackedRuntimePath'."
	}
	foreach ($SourceGroupId in $ExpectedSourceGroups) {
		Assert-True ($UsedSourceGroups.Contains($SourceGroupId)) "$Context source group '$SourceGroupId' is orphaned."
	}
}

Assert-RuntimeIntakeContract $RuntimeIntake 'Repository runtime intake registry'
Write-Output "PASS: closed runtime intake registry covers all $($TrackedRuntimePaths.Count) committed /Game packages and exact LFS objects"

$UnknownRuntimeIntake = Copy-JsonObject $RuntimeIntake
Add-Member -InputObject $UnknownRuntimeIntake -MemberType NoteProperty -Name 'unexpected_top_level' -Value $true
Assert-JsonSchemaRejects $UnknownRuntimeIntake $RuntimeIntakeSchema 'unexpected_top_level' 'Runtime-intake unknown-field fixture'
$InvalidRuntimeVersion = Copy-JsonObject $RuntimeIntake
$InvalidRuntimeVersion.assets[0].content_version = 0
Assert-JsonSchemaRejects $InvalidRuntimeVersion $RuntimeIntakeSchema 'less than minimum' 'Runtime-intake invalid-version fixture'
$DuplicateRuntimePath = Copy-JsonObject $RuntimeIntake
$DuplicateRuntimePath.assets[1].repository_path = $DuplicateRuntimePath.assets[0].repository_path
$DuplicateRuntimePath.assets[1].asset_path = $DuplicateRuntimePath.assets[0].asset_path
$DuplicateRuntimeFailure = $null
try { Assert-RuntimeIntakeContract $DuplicateRuntimePath 'Runtime-intake duplicate-path fixture' $false } catch { $DuplicateRuntimeFailure = $_.Exception.Message }
Assert-True ($DuplicateRuntimeFailure -match 'duplicate repository_path') 'Runtime intake must reject a duplicate package record.'
$DuplicateRuntimeStableId = Copy-JsonObject $RuntimeIntake
$DuplicateRuntimeStableId.assets[1].stable_id = $DuplicateRuntimeStableId.assets[0].stable_id
$DuplicateStableFailure = $null
try { Assert-RuntimeIntakeContract $DuplicateRuntimeStableId 'Runtime-intake duplicate-stable-id fixture' $false } catch { $DuplicateStableFailure = $_.Exception.Message }
Assert-True ($DuplicateStableFailure -match 'duplicate stable_id') 'Runtime intake must reject duplicate stable IDs.'
$MissingRuntimeStableId = Copy-JsonObject $RuntimeIntake
$MissingRuntimeStableId.assets[0].stable_id = ''
Assert-JsonSchemaRejects $MissingRuntimeStableId $RuntimeIntakeSchema 'stable_id.*pattern' 'Runtime-intake missing-stable-id fixture'
$MissingRuntimeRecord = Copy-JsonObject $RuntimeIntake
$MissingRuntimeRecord.assets = @($MissingRuntimeRecord.assets | Select-Object -Skip 1)
$MissingRuntimeRecord.expected_asset_count = $MissingRuntimeRecord.assets.Count
$MissingRuntimeFailure = $null
try { Assert-RuntimeIntakeContract $MissingRuntimeRecord 'Runtime-intake missing-package fixture' $false } catch { $MissingRuntimeFailure = $_.Exception.Message }
Assert-True ($MissingRuntimeFailure -match 'exactly one record for every committed runtime package') 'Runtime intake must fail closed when a committed package lacks a record.'
$WrongRuntimeHash = Copy-JsonObject $RuntimeIntake
$WrongRuntimeHash.assets[0].content_sha256 = ('0' * 64)
$WrongRuntimeHashFailure = $null
try { Assert-RuntimeIntakeContract $WrongRuntimeHash 'Runtime-intake stale-hash fixture' $false } catch { $WrongRuntimeHashFailure = $_.Exception.Message }
Assert-True ($WrongRuntimeHashFailure -match 'does not match its committed LFS object') 'Runtime intake must reject a stale package hash.'

$CandidateAsset = Copy-JsonObject $RuntimeIntake.assets[0]
$CandidateGroup = Copy-JsonObject $RuntimeIntake.source_groups[0]
$CandidateAsset.lifecycle_state = 'runtime_candidate'
$CandidateGroup.approval_state = 'runtime_candidate_approved'
$CandidateAsset.lifecycle_evidence.temporary_prototype = @()
$CandidateAsset.lifecycle_evidence.runtime_candidate = @([ordered]@{ review_revision = ('a' * 40); reviewer = 'reviewer'; approval_record = 'candidate approval'; stable_id = $CandidateAsset.stable_id; content_version = $CandidateAsset.content_version; content_sha256 = $CandidateAsset.content_sha256 })
Assert-LifecycleTransitionEvidence $CandidateAsset $CandidateGroup 'Valid runtime-candidate fixture'
$StaleCandidate = Copy-JsonObject $CandidateAsset
$StaleCandidate.lifecycle_evidence.runtime_candidate[0].content_sha256 = ('0' * 64)
$StaleCandidateFailure = $null
try { Assert-LifecycleTransitionEvidence $StaleCandidate $CandidateGroup 'Stale runtime-candidate fixture' } catch { $StaleCandidateFailure = $_.Exception.Message }
Assert-True ($StaleCandidateFailure -match 'does not bind exact revision and content identity') 'Runtime-candidate evidence must reject stale content identity.'

$ProductionAsset = Copy-JsonObject $CandidateAsset
$ProductionGroup = Copy-JsonObject $CandidateGroup
$ProductionAsset.lifecycle_state = 'production_approved'
$ProductionGroup.approval_state = 'production_approved'
$ProductionAsset.lifecycle_evidence.production_approval = @([ordered]@{ candidate_review_revision = ('a' * 40); candidate_approval_record = 'candidate approval'; production_revision = ('b' * 40); reviewer = 'production reviewer'; approval_record = 'production approval'; stable_id = $ProductionAsset.stable_id; content_version = $ProductionAsset.content_version; content_sha256 = $ProductionAsset.content_sha256 })
Assert-LifecycleTransitionEvidence $ProductionAsset $ProductionGroup 'Valid production fixture'
$StaleProduction = Copy-JsonObject $ProductionAsset
$StaleProduction.lifecycle_evidence.production_approval[0].candidate_approval_record = 'different candidate approval'
$StaleProductionFailure = $null
try { Assert-LifecycleTransitionEvidence $StaleProduction $ProductionGroup 'Stale production fixture' } catch { $StaleProductionFailure = $_.Exception.Message }
Assert-True ($StaleProductionFailure -match 'does not bind exact candidate approval') 'Production evidence must reject a different candidate approval record.'
Write-Output 'PASS: runtime intake rejects unknown fields, invalid versions, duplicate paths, missing packages, and stale LFS hashes'

Assert-True ($Policy.schema_id -eq 'aetheln.asset-intake-policy') 'The policy schema ID must be stable.'
Assert-True ([int]$Policy.schema_version -eq 2) 'The policy schema version must be two.'
Assert-True (@($Policy.lifecycle_states).Count -eq $ExpectedLifecycle.Count) 'Every lifecycle state must be explicit.'
foreach ($State in $ExpectedLifecycle) { Assert-True ($Policy.lifecycle_states -contains $State) "Lifecycle state '$State' is missing." }
Assert-True ($null -ne $Policy.PSObject.Properties['lifecycle_gates']) 'Lifecycle transition gates must be machine readable.'
$LifecycleGates = $Policy.lifecycle_gates
Assert-True ($LifecycleGates.repository_presence_implies_approval -eq $false) 'Repository presence must not imply approval.'
Assert-True ($LifecycleGates.successful_import_implies_approval -eq $false) 'Successful import must not imply approval.'
Assert-True ($LifecycleGates.successful_cook_implies_approval -eq $false) 'Successful cook must not imply approval.'
Assert-True ($LifecycleGates.evidence_change_returns_to_review -eq $true) 'Evidence changes must return an asset to review.'
$ExpectedTransitions = @('concept_reference>temporary_prototype','concept_reference>runtime_candidate','temporary_prototype>runtime_candidate','runtime_candidate>production_approved')
$ActualTransitions = @($LifecycleGates.forward_transitions | ForEach-Object { "$($_.from)>$($_.to)" })
Assert-True ($ActualTransitions.Count -eq $ExpectedTransitions.Count) 'The lifecycle transition set has an unexpected size.'
foreach ($Transition in $ExpectedTransitions) { Assert-True ($ActualTransitions -contains $Transition) "Lifecycle transition '$Transition' is missing." }
	foreach ($Field in @('complete_provenance','rights_evidence','stable_identity_and_version','audience','all_deterministic_families_passed','named_reviewer','approval_record','exact_content_identity')) {
	Assert-True ($LifecycleGates.runtime_candidate_requires -contains $Field) "Runtime-candidate gate '$Field' is missing."
}
	foreach ($Field in @('exact_runtime_candidate_revision','production_reviewer','production_approval_record','exact_content_identity','exact_runtime_candidate_approval_record')) {
	Assert-True ($LifecycleGates.production_approval_requires -contains $Field) "Production-approval gate '$Field' is missing."
}
foreach ($Audience in $ExpectedAudience) { Assert-True ($Policy.audiences -contains $Audience) "Audience '$Audience' is missing." }
Assert-True (@($Policy.policy_families).Count -eq $ExpectedFamilies.Count) 'The policy family set must contain exactly the governed families.'
foreach ($Family in $ExpectedFamilies) {
	Assert-True (@($Policy.policy_families | Where-Object { $_.id -ceq $Family }).Count -eq 1) "Policy family '$Family' must occur exactly once."
}

$ProvenanceFields = @($Policy.provenance.required_fields)
foreach ($Field in @('author_or_provider','source_record','source_version','license_or_permission_evidence','modifications','content_sha256','reviewer','approval_state')) {
	Assert-True ($ProvenanceFields -contains $Field) "Provenance field '$Field' is missing."
}
Assert-True ($ProvenanceFields -contains 'generation_metadata_when_applicable') 'Generated content metadata must remain separate and conditional.'
Assert-True ($Policy.provenance.automation_may_download_or_accept_terms -eq $false) 'Automation must never download content or accept terms.'

Assert-True ($Policy.identity.stable_id_required -eq $true) 'Stable content identity must be required for runtime candidates.'
Assert-True ($Policy.identity.positive_content_version_required -eq $true) 'Positive content versions must be required.'
Assert-True ($Policy.identity.rename_changes_identity -eq $false) 'Display or package renames must not silently change identity.'

Assert-True ($Policy.thresholds.unresolved_value -eq 'TBD') 'Unresolved numeric thresholds must remain explicit TBD values.'
Assert-True ($Policy.thresholds.tbd_requires_owner -eq $true) 'Every TBD threshold must have an owner.'
Assert-True ($Policy.thresholds.tbd_requires_revisit_trigger -eq $true) 'Every TBD threshold must have a revisit trigger.'
Assert-True ($Policy.thresholds.tbd_may_promote_to_production -eq $false) 'A TBD quantitative threshold cannot silently pass production approval.'

$ReportFields = @($Policy.report.required_fields)
foreach ($Field in @('schema_id','schema_version','revision','engine_identity','policy_sha256','intake_sha256','execution_provenance','audience','started_utc','finished_utc','command','counts','assets','findings','result')) {
	Assert-True ($ReportFields -contains $Field) "Report field '$Field' is missing."
}
foreach ($Field in @('policy_id','asset_path','severity','reason','remediation','evidence_field')) {
	Assert-True ($Policy.report.finding_required_fields -contains $Field) "Finding field '$Field' is missing."
}

$Grandfather = $Policy.grandfathered_temporary_prototype
Assert-True ($Grandfather.allowed -eq $true) 'Temporary prototype grandfathering must be explicit.'
Assert-True ($Grandfather.requires_owner -eq $true) 'Grandfathered assets require an owner.'
Assert-True ($Grandfather.requires_recovery_trigger -eq $true) 'Grandfathered assets require a recovery trigger.'
Assert-True ($Grandfather.may_be_runtime_candidate -eq $false) 'Grandfathering must not promote an asset.'

Assert-True ($null -ne $Policy.PSObject.Properties['intake_controls']) 'Source/runtime intake controls must be machine readable.'
$IntakeControls = $Policy.intake_controls
Assert-True ($IntakeControls.source_assets_may_be_cooked -eq $false) 'Source-only assets must never enter a runtime cook.'
Assert-True ($IntakeControls.runtime_assets_require_intake_record -eq $true) 'Runtime assets require an intake record.'
Assert-True ($IntakeControls.naming_owner_required -eq $true) 'Naming ownership must be explicit.'
Assert-True ($IntakeControls.import_settings_required -eq $true -and $IntakeControls.reimport_settings_required -eq $true) 'Import and reimport settings must be recorded.'
Assert-True ($IntakeControls.lock_before_binary_edit -eq $true) 'Lockable binary assets must be locked before editing.'
Assert-True ($IntakeControls.recovery_requires_preserved_copy -eq $true) 'Recovery must preserve the affected working copy.'

$ReferenceRules = $Policy.references
Assert-True ($ReferenceRules.incompatible_content_version_result -eq 'fail') 'Incompatible content versions must fail closed.'
Assert-True ($ReferenceRules.soft_reference_rules.default_allowed -eq $false) 'Soft references must be denied unless one complete declared rule matches.'
Assert-True ($ReferenceRules.soft_reference_rules.match_mode -ceq 'full_package_path_and_audience') 'Soft-reference matching must bind both full package paths and audiences.'
foreach ($Field in @('id','source_package_pattern','source_audience','target_package_pattern','target_audience','justification')) {
	Assert-True ($ReferenceRules.soft_reference_rules.required_fields -contains $Field) "Soft-reference rule field '$Field' is missing."
}
$ExpectedSoftAudiencePairs = @(
	'shared>shared',
	'shared>client_only',
	'server_only>shared',
	'server_only>server_only',
	'client_only>shared',
	'client_only>client_only'
)
$ActualSoftAudiencePairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($Rule in @($ReferenceRules.soft_reference_rules.rules)) {
	Assert-True ($Rule.source_package_pattern.StartsWith('^') -and $Rule.source_package_pattern.EndsWith('$')) "Soft-reference rule '$($Rule.id)' source pattern is not fully anchored."
	Assert-True ($Rule.target_package_pattern.StartsWith('^') -and $Rule.target_package_pattern.EndsWith('$')) "Soft-reference rule '$($Rule.id)' target pattern is not fully anchored."
	$SourcePattern = [regex]::new([string]$Rule.source_package_pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
	$TargetPattern = [regex]::new([string]$Rule.target_package_pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
	Assert-True ($SourcePattern.IsMatch('/Game/Fixtures/DA_Source') -and -not $SourcePattern.IsMatch('/Engine/Fixtures/DA_Source')) "Soft-reference rule '$($Rule.id)' source pattern is not a strict /Game package pattern."
	Assert-True ($TargetPattern.IsMatch('/Game/Fixtures/DA_Target') -and -not $TargetPattern.IsMatch('/Game/Fixtures/DA_Target.Object')) "Soft-reference rule '$($Rule.id)' target pattern is not a strict package path."
	$Pair = "$($Rule.source_audience)>$($Rule.target_audience)"
	Assert-True ($ActualSoftAudiencePairs.Add($Pair)) "Soft-reference audience pair '$Pair' is duplicated."
}
Assert-True ($ActualSoftAudiencePairs.Count -eq $ExpectedSoftAudiencePairs.Count) 'The soft-reference audience matrix has an unexpected size.'
foreach ($Pair in $ExpectedSoftAudiencePairs) { Assert-True ($ActualSoftAudiencePairs.Contains($Pair)) "Soft-reference audience pair '$Pair' is missing." }
Assert-True (-not $ActualSoftAudiencePairs.Contains('shared>server_only')) 'Shared content must not gain an undeclared server-only soft dependency.'
$UnanchoredSoftPolicy = Copy-JsonObject $Policy
$UnanchoredSoftPolicy.references.soft_reference_rules.rules[0].source_package_pattern = '/Game/.*'
Assert-JsonSchemaRejects $UnanchoredSoftPolicy $Schema 'source_package_pattern.*pattern' 'Unanchored-soft-reference fixture'
$UnknownSoftFieldPolicy = Copy-JsonObject $Policy
Add-Member -InputObject $UnknownSoftFieldPolicy.references.soft_reference_rules.rules[0] -MemberType NoteProperty -Name 'allow_prefix' -Value $true
Assert-JsonSchemaRejects $UnknownSoftFieldPolicy $Schema 'allow_prefix' 'Unknown-soft-reference-field fixture'
Assert-True ($ReferenceRules.hard_reference_exceptions.default_allowed -eq $false) 'Hard-reference exceptions must be denied by default.'
foreach ($Field in @('owner','justification','source_audience','target_audience','reviewer','approval_record','revisit_trigger')) {
	Assert-True ($ReferenceRules.hard_reference_exceptions.required_fields -contains $Field) "Hard-reference exception field '$Field' is missing."
}
$ExpectedAudienceRules = @{
	shared = @('shared')
	server_only = @('shared','server_only')
	client_only = @('shared','client_only')
}
foreach ($SourceAudience in $ExpectedAudienceRules.Keys) {
	$Rule = @($ReferenceRules.hard_reference_audience_rules | Where-Object { $_.source -eq $SourceAudience })
	Assert-True ($Rule.Count -eq 1) "Hard-reference audience rule '$SourceAudience' must occur exactly once."
	Assert-True (@($Rule[0].may_reference).Count -eq $ExpectedAudienceRules[$SourceAudience].Count) "Hard-reference audience rule '$SourceAudience' has an unexpected target count."
	foreach ($TargetAudience in $ExpectedAudienceRules[$SourceAudience]) {
		Assert-True ($Rule[0].may_reference -contains $TargetAudience) "Hard-reference audience rule '$SourceAudience' is missing '$TargetAudience'."
	}
}

foreach ($Family in $Policy.policy_families) {
	$ExpectedChecks = @($ExpectedChecksByFamily[[string]$Family.id])
	Assert-True (@($Family.checks).Count -eq $ExpectedChecks.Count) "Policy family '$($Family.id)' must name its exact enforced check count."
	foreach ($Check in $ExpectedChecks) { Assert-True (@($Family.checks) -ccontains $Check) "Policy family '$($Family.id)' is missing exact check '$Check'." }
	Assert-True ([string]$Family.failure_code -match '^content\.[a-z0-9_]+\.failed$') "Policy family '$($Family.id)' must define a stable failure code."
}

$BudgetIds = @(
	'collision_complexity',
	'lod_hlod_nanite',
	'texture_memory_streaming',
	'material_shader_complexity',
	'skeletal_rig_influences_morphs',
	'animation_complexity',
	'map_data_layer_pcg',
	'navigation_runtime'
)
foreach ($BudgetId in $BudgetIds) {
	$Budget = @($Policy.thresholds.unresolved_budgets | Where-Object { $_.id -eq $BudgetId })
	Assert-True ($Budget.Count -eq 1) "Unresolved budget '$BudgetId' must occur exactly once."
	Assert-True ($Budget[0].value -eq 'TBD') "Unresolved budget '$BudgetId' must remain literal TBD."
	Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Budget[0].owner)) "Unresolved budget '$BudgetId' requires an owner."
	Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Budget[0].revisit_trigger)) "Unresolved budget '$BudgetId' requires a revisit trigger."
}
Assert-True (@($Policy.thresholds.unresolved_budgets).Count -eq $BudgetIds.Count) 'The unresolved budget registry must contain only the governed TBD entries.'
$UnresolvedQuantitativeBudgets = @($Policy.thresholds.unresolved_budgets | Where-Object { $_.value -ceq $Policy.thresholds.unresolved_value })
$UnresolvedBudgetIds = @($UnresolvedQuantitativeBudgets | ForEach-Object { [string]$_.id })
$HasUnresolvedQuantitativeThresholds = $UnresolvedQuantitativeBudgets.Count -gt 0

$ReportContract = $Policy.report
foreach ($Field in @('asset_required_fields','provenance_required_fields','lifecycle_evidence_required_fields','execution_provenance_required_fields','family_result_required_fields','check_result_required_fields','artifact_descriptor_required_fields','loaded_project_module_required_fields','loaded_project_module_names','counts_required_fields','allowed_results','allowed_deterministic_statuses','allowed_promotion_statuses','allowed_severities','allowed_registry_sources')) {
	Assert-True ($null -ne $ReportContract.PSObject.Properties[$Field]) "Report contract field '$Field' is missing."
}
foreach ($Field in @('asset_path','stable_id','content_version','audience','lifecycle_state','provenance','lifecycle_evidence','family_results')) {
	Assert-True ($ReportContract.asset_required_fields -contains $Field) "Asset report field '$Field' is missing."
}
Assert-True ($ReportContract.finding_required_fields -contains 'code') 'Findings require a stable machine-readable code.'

function Assert-ArtifactDescriptor([object] $Descriptor, [string] $Context) {
	Assert-True (Test-JsonObject $Descriptor) "$Context must be an object."
	Assert-ClosedProperties $Descriptor @($ReportContract.artifact_descriptor_required_fields) $Context
	if (-not (Test-NonBlankJsonString $Descriptor.path) -or ([string]$Descriptor.path).Contains(':') -or ([string]$Descriptor.path).StartsWith('/') -or ([string]$Descriptor.path).Contains('\\') -or [string]$Descriptor.path -match '(?:^|/)\.\.(?:/|$)') {
		throw "$Context.path must be canonical repository-relative forward-slash form."
	}
	Assert-True (Test-JsonInteger $Descriptor.size_bytes -and $Descriptor.size_bytes -gt 0) "$Context.size_bytes must be a positive integer."
	Assert-True (Test-NonBlankJsonString $Descriptor.sha256 -and $Descriptor.sha256 -cmatch '^[0-9a-f]{64}$') "$Context.sha256 must be a lowercase SHA-256 string."
	Assert-True (Test-NonBlankJsonString $Descriptor.build_id) "$Context.build_id must be non-blank."
}

function Assert-ReportContract([object] $Report, [string] $Context) {
	Assert-True (Test-JsonObject $Report) "$Context must be a JSON object."
	Assert-ClosedProperties $Report @($ReportContract.required_fields) $Context
	Assert-True (Test-NonBlankJsonString $Report.schema_id) "$Context schema_id must be a non-blank string."
	Assert-True (Test-JsonInteger $Report.schema_version) "$Context schema_version must be a JSON integer."
	Assert-True ($Report.schema_id -ceq $ReportContract.schema_id -and $Report.schema_version -eq $ReportContract.schema_version) "$Context has an incompatible schema identity."
	foreach ($Field in @('revision', 'engine_identity', 'command')) {
		Assert-True (Test-NonBlankJsonString $Report.$Field) "$Context $Field must be a non-blank string."
	}
	Assert-True ($Report.revision -cmatch '^[0-9a-f]{40}$') "$Context revision must be an exact lowercase Git commit."
	Assert-True (Test-NonBlankJsonString $Report.policy_sha256 -and $Report.policy_sha256 -cmatch '^[0-9a-f]{64}$') "$Context policy_sha256 must be a lowercase SHA-256 string."
	Assert-True (Test-NonBlankJsonString $Report.intake_sha256 -and $Report.intake_sha256 -cmatch '^[0-9a-f]{64}$') "$Context intake_sha256 must be a lowercase SHA-256 string."
	Assert-True (Test-JsonObject $Report.execution_provenance) "$Context execution_provenance must be a JSON object."
	Assert-ClosedProperties $Report.execution_provenance @($ReportContract.execution_provenance_required_fields) "$Context execution_provenance"
	Assert-True ($Report.execution_provenance.repository_clean -is [bool] -and $Report.execution_provenance.repository_clean) "$Context execution_provenance.repository_clean must be true."
	foreach ($Field in @('engine_binary_sha256','build_version_sha256','editor_build_command_sha256','editor_build_log_sha256','compiler_sha256','resource_compiler_sha256','project_sha256','policy_sha256','intake_sha256','invocation_sha256')) {
		Assert-True (Test-NonBlankJsonString $Report.execution_provenance.$Field -and $Report.execution_provenance.$Field -cmatch '^[0-9a-f]{64}$') "$Context execution_provenance.$Field must be a lowercase SHA-256 string."
	}
	Assert-True (Test-NonBlankJsonString $Report.execution_provenance.engine_revision -and $Report.execution_provenance.engine_revision -cmatch '^[0-9a-f]{40}$') "$Context execution_provenance.engine_revision must be an exact lowercase Git commit."
	foreach ($Field in @('engine_tag','target','platform','configuration','compiler_version','resource_compiler_version','registry_source')) {
		Assert-True (Test-NonBlankJsonString $Report.execution_provenance.$Field) "$Context execution_provenance.$Field must be a non-blank string."
	}
	Assert-ArtifactDescriptor $Report.execution_provenance.target_receipt "$Context execution_provenance.target_receipt"
	Assert-ArtifactDescriptor $Report.execution_provenance.module_manifest "$Context execution_provenance.module_manifest"
	Assert-True (Test-JsonArray $Report.execution_provenance.loaded_project_modules) "$Context execution_provenance.loaded_project_modules must be an array."
	$LoadedModules = @($Report.execution_provenance.loaded_project_modules)
	Assert-True ($LoadedModules.Count -eq 2) "$Context must report exactly GameCore then GameTests."
	foreach ($Index in 0..1) {
		$Module = $LoadedModules[$Index]
		Assert-True (Test-JsonObject $Module) "$Context loaded module $Index must be an object."
		Assert-ClosedProperties $Module @($ReportContract.loaded_project_module_required_fields) "$Context loaded module $Index"
		$ExpectedName = @($ReportContract.loaded_project_module_names)[$Index]
		Assert-True ($Module.name -ceq $ExpectedName) "$Context loaded module $Index must be $ExpectedName."
		$Descriptor = [ordered]@{ path = $Module.path; size_bytes = $Module.size_bytes; sha256 = $Module.sha256; build_id = $Module.build_id }
		Assert-ArtifactDescriptor $Descriptor "$Context loaded module $ExpectedName"
	}
	$SharedBuildId = [string]$Report.execution_provenance.target_receipt.build_id
	Assert-True ($Report.execution_provenance.module_manifest.build_id -ceq $SharedBuildId -and $LoadedModules[0].build_id -ceq $SharedBuildId -and $LoadedModules[1].build_id -ceq $SharedBuildId) "$Context receipt, manifest, and loaded modules must share one non-blank build_id."
	Assert-True (@($ReportContract.allowed_registry_sources) -ccontains $Report.execution_provenance.registry_source) "$Context execution_provenance.registry_source is unsupported."
	Assert-True ($Report.execution_provenance.policy_sha256 -ceq $Report.policy_sha256) "$Context embedded policy hash does not match policy_sha256."
	Assert-True ($Report.execution_provenance.intake_sha256 -ceq $Report.intake_sha256) "$Context embedded intake hash does not match intake_sha256."
	Assert-True ($Report.engine_identity -ceq "$($Report.execution_provenance.engine_tag)@$($Report.execution_provenance.engine_revision)") "$Context engine_identity does not bind the exact engine tag and revision."
	Assert-True (Test-NonBlankJsonString $Report.audience -and @('all','shared','server_only','client_only') -ccontains $Report.audience) "$Context audience is unsupported."
	Assert-True (Test-NonBlankJsonString $Report.result -and @($ReportContract.allowed_results) -ccontains $Report.result) "$Context result is unsupported."
	$Started = ConvertFrom-JsonUtcTimestamp $Report.started_utc "$Context started_utc"
	$Finished = ConvertFrom-JsonUtcTimestamp $Report.finished_utc "$Context finished_utc"
	Assert-True ($Finished -ge $Started) "$Context finished_utc precedes started_utc."

	Assert-True (Test-JsonObject $Report.counts) "$Context counts must be a JSON object."
	Assert-ClosedProperties $Report.counts @($ReportContract.counts_required_fields) "$Context counts"
	foreach ($Field in @($ReportContract.counts_required_fields)) {
		Assert-True (Test-JsonInteger $Report.counts.$Field) "$Context counts.$Field must be a JSON integer."
		Assert-True ($Report.counts.$Field -ge 0) "$Context counts.$Field must not be negative."
	}
	Assert-True (Test-JsonArray $Report.assets) "$Context assets must be a JSON array."
	Assert-True (Test-JsonArray $Report.findings) "$Context findings must be a JSON array."
	$Assets = @($Report.assets)
	$Findings = @($Report.findings)
	Assert-True ($Assets.Count -gt 0) "$Context contains no governed assets."
	Assert-True ($Report.counts.assets -eq $Assets.Count) "$Context asset count is inconsistent."
	Assert-True ($Report.counts.findings -eq $Findings.Count) "$Context finding count is inconsistent."

	$StableIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$AssetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$FamilyStatuses = [System.Collections.Generic.List[string]]::new()
	$FamilyRecords = [System.Collections.Generic.List[object]]::new()
	foreach ($Asset in $Assets) {
		Assert-True (Test-JsonObject $Asset) "$Context asset must be a JSON object."
		Assert-ClosedProperties $Asset @($ReportContract.asset_required_fields) "$Context asset"
		Assert-True (Test-NonBlankJsonString $Asset.asset_path -and $Asset.asset_path -cmatch '^/Game(?:/[^\s.]+)+$') "$Context asset_path '$($Asset.asset_path)' is malformed."
		Assert-True ($AssetPaths.Add($Asset.asset_path)) "$Context contains duplicate asset_path '$($Asset.asset_path)'."
		Assert-True (Test-NonBlankJsonString $Asset.stable_id -and $Asset.stable_id -cmatch '^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+$') "$Context stable_id '$($Asset.stable_id)' is malformed."
		Assert-True ($StableIds.Add($Asset.stable_id)) "$Context contains duplicate stable_id '$($Asset.stable_id)'."
		Assert-True (Test-JsonInteger $Asset.content_version) "$Context asset '$($Asset.asset_path)' content_version must be a JSON integer."
		Assert-True ($Asset.content_version -gt 0) "$Context asset '$($Asset.asset_path)' has a non-positive content_version."
		Assert-True (Test-NonBlankJsonString $Asset.audience -and $ExpectedAudience -ccontains $Asset.audience) "$Context asset '$($Asset.asset_path)' has an unsupported audience."
		Assert-True (Test-NonBlankJsonString $Asset.lifecycle_state -and $ExpectedLifecycle -ccontains $Asset.lifecycle_state) "$Context asset '$($Asset.asset_path)' has an unsupported lifecycle_state."

		Assert-True (Test-JsonObject $Asset.provenance) "$Context provenance must be a JSON object."
		Assert-ClosedProperties $Asset.provenance @($ReportContract.provenance_required_fields) "$Context provenance"
		foreach ($Field in @($ReportContract.provenance_required_fields)) {
			Assert-True ($Asset.provenance.$Field -is [string]) "$Context provenance field '$Field' must be a string."
			Assert-True (-not [string]::IsNullOrWhiteSpace($Asset.provenance.$Field)) "$Context provenance field '$Field' is empty."
		}
		Assert-True ($Asset.provenance.content_sha256 -cmatch '^[0-9a-f]{64}$') "$Context content_sha256 must be an exact lowercase SHA-256 string."
		$ExpectedApproval = if ($Asset.lifecycle_state -ceq 'production_approved') { 'production_approved' } elseif ($Asset.lifecycle_state -ceq 'runtime_candidate') { 'runtime_candidate_approved' } else { $null }
		if ($null -ne $ExpectedApproval) {
			Assert-True ($Asset.provenance.approval_state -ceq $ExpectedApproval) "$Context lifecycle '$($Asset.lifecycle_state)' lacks matching approval evidence."
		}
		Assert-True (Test-JsonObject $Asset.lifecycle_evidence) "$Context lifecycle_evidence must be a JSON object."
		Assert-ClosedProperties $Asset.lifecycle_evidence @($ReportContract.lifecycle_evidence_required_fields) "$Context lifecycle_evidence"
		Assert-ClosedProperties $Asset.lifecycle_evidence.content_identity @('stable_id','content_version','content_sha256') "$Context lifecycle content identity"
		Assert-True ($Asset.lifecycle_evidence.content_identity.stable_id -ceq $Asset.stable_id -and [int]$Asset.lifecycle_evidence.content_identity.content_version -eq [int]$Asset.content_version -and $Asset.lifecycle_evidence.content_identity.content_sha256 -ceq $Asset.provenance.content_sha256) "$Context lifecycle evidence must bind the exact content identity."
		if ($Asset.lifecycle_state -ceq 'concept_reference') {
			Assert-True (@($Asset.lifecycle_evidence.temporary_prototype).Count -eq 0 -and @($Asset.lifecycle_evidence.runtime_candidate).Count -eq 0 -and @($Asset.lifecycle_evidence.production_approval).Count -eq 0) "$Context concept reference cannot carry promotion evidence."
		}
		elseif ($Asset.lifecycle_state -ceq 'temporary_prototype') {
			$Temporary = @($Asset.lifecycle_evidence.temporary_prototype)
			Assert-True ($Temporary.Count -eq 1 -and @($Asset.lifecycle_evidence.runtime_candidate).Count -eq 0 -and @($Asset.lifecycle_evidence.production_approval).Count -eq 0) "$Context temporary prototype must have only temporary lifecycle evidence."
			Assert-ClosedProperties $Temporary[0] @('owner','approval_record','recovery_trigger','may_be_runtime_candidate') "$Context temporary lifecycle evidence"
			Assert-True ($Temporary[0].may_be_runtime_candidate -eq $false) "$Context temporary prototype cannot be promotion-capable."
		}
		else {
			$Candidate = @($Asset.lifecycle_evidence.runtime_candidate)
			Assert-True (@($Asset.lifecycle_evidence.temporary_prototype).Count -eq 0 -and $Candidate.Count -eq 1) "$Context promoted lifecycle must contain exact runtime-candidate evidence."
			Assert-ClosedProperties $Candidate[0] @('review_revision','reviewer','approval_record','stable_id','content_version','content_sha256') "$Context runtime-candidate evidence"
			Assert-True ($Candidate[0].review_revision -cmatch '^[0-9a-f]{40}$' -and $Candidate[0].stable_id -ceq $Asset.stable_id -and [int]$Candidate[0].content_version -eq [int]$Asset.content_version -and $Candidate[0].content_sha256 -ceq $Asset.provenance.content_sha256) "$Context runtime-candidate evidence must bind exact revision and content identity."
		}

		Assert-True (Test-JsonArray $Asset.family_results) "$Context asset '$($Asset.asset_path)' family_results must be a JSON array."
		$FamilyResults = @($Asset.family_results)
		Assert-True ($FamilyResults.Count -eq $ExpectedFamilies.Count) "$Context asset '$($Asset.asset_path)' must report every policy family exactly once."
		foreach ($FamilyId in $ExpectedFamilies) {
			$FamilyResult = @($FamilyResults | Where-Object { $_.policy_id -ceq $FamilyId })
			Assert-True ($FamilyResult.Count -eq 1) "$Context asset '$($Asset.asset_path)' family '$FamilyId' must occur exactly once."
			$FamilyPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq $FamilyId })[0]
			Assert-True (Test-JsonObject $FamilyResult[0]) "$Context family result '$FamilyId' must be a JSON object."
			Assert-ClosedProperties $FamilyResult[0] @($ReportContract.family_result_required_fields) "$Context family result '$FamilyId'"
			foreach ($Field in @('policy_id','applicability','deterministic_status','promotion_status','evidence')) {
				Assert-True (Test-NonBlankJsonString $FamilyResult[0].$Field) "$Context family '$FamilyId' field '$Field' must be a non-blank string."
			}
			Assert-True (@('applicable','not_applicable') -ccontains $FamilyResult[0].applicability) "$Context family '$FamilyId' has invalid applicability."
			Assert-True (@($ReportContract.allowed_deterministic_statuses) -ccontains $FamilyResult[0].deterministic_status) "$Context family '$FamilyId' has invalid deterministic_status."
			Assert-True (@($ReportContract.allowed_promotion_statuses) -ccontains $FamilyResult[0].promotion_status) "$Context family '$FamilyId' has invalid promotion_status."
			Assert-True (Test-JsonArray $FamilyResult[0].check_results) "$Context family '$FamilyId' check_results must be an array."
			$CheckResults = @($FamilyResult[0].check_results)
			$ExpectedChecks = @($FamilyPolicy.checks | ForEach-Object { [string]$_ })
			Assert-True ($CheckResults.Count -eq $ExpectedChecks.Count) "$Context family '$FamilyId' must report every policy check exactly once."
			foreach ($CheckId in $ExpectedChecks) {
				$CheckResult = @($CheckResults | Where-Object { $_.check_id -ceq $CheckId })
				Assert-True ($CheckResult.Count -eq 1) "$Context family '$FamilyId' check '$CheckId' must occur exactly once."
				Assert-ClosedProperties $CheckResult[0] @($ReportContract.check_result_required_fields) "$Context family '$FamilyId' check '$CheckId'"
				foreach ($Field in @($ReportContract.check_result_required_fields)) {
					Assert-True (Test-NonBlankJsonString $CheckResult[0].$Field) "$Context family '$FamilyId' check '$CheckId' field '$Field' must be non-blank."
				}
				Assert-True (@('applicable','not_applicable') -ccontains $CheckResult[0].applicability) "$Context family '$FamilyId' check '$CheckId' has invalid applicability."
				Assert-True (@($ReportContract.allowed_deterministic_statuses) -ccontains $CheckResult[0].deterministic_status) "$Context family '$FamilyId' check '$CheckId' has invalid deterministic_status."
				Assert-True (@($ReportContract.allowed_promotion_statuses) -ccontains $CheckResult[0].promotion_status) "$Context family '$FamilyId' check '$CheckId' has invalid promotion_status."
				if ($CheckResult[0].applicability -ceq 'not_applicable') {
					Assert-True ($CheckResult[0].deterministic_status -ceq 'not_applicable' -and $CheckResult[0].promotion_status -ceq 'not_applicable') "$Context non-applicable check '$FamilyId.$CheckId' must use both not_applicable statuses."
				}
				else {
					Assert-True ($CheckResult[0].deterministic_status -cne 'not_applicable' -and $CheckResult[0].promotion_status -cne 'not_applicable') "$Context applicable check '$FamilyId.$CheckId' cannot use not_applicable statuses."
				}
				if ($CheckResult[0].deterministic_status -ceq 'evidence_unavailable') {
					Assert-True ($CheckResult[0].promotion_status -ceq 'non_promotion') "$Context unavailable check '$FamilyId.$CheckId' must block promotion."
				}
				if ($CheckResult[0].deterministic_status -ceq 'failed') {
					Assert-True ($CheckResult[0].promotion_status -ceq 'non_promotion') "$Context failed check '$FamilyId.$CheckId' must block promotion."
				}
			}
			$ApplicableChecks = @($CheckResults | Where-Object { $_.applicability -ceq 'applicable' })
			$FailedChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'failed' })
			$UnavailableChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'evidence_unavailable' })
			$BlockedChecks = @($ApplicableChecks | Where-Object { $_.promotion_status -ceq 'non_promotion' })
			$ExpectedApplicability = if ($ApplicableChecks.Count -gt 0) { 'applicable' } else { 'not_applicable' }
			$ExpectedDeterministic = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0) { 'failed' } elseif ($UnavailableChecks.Count -gt 0) { 'evidence_unavailable' } else { 'passed' }
			$ExpectedPromotion = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0 -or $UnavailableChecks.Count -gt 0 -or $BlockedChecks.Count -gt 0 -or $Asset.lifecycle_state -ceq 'temporary_prototype') { 'non_promotion' } else { 'eligible' }
			Assert-True ($FamilyResult[0].applicability -ceq $ExpectedApplicability) "$Context family '$FamilyId' applicability does not aggregate check results."
			Assert-True ($FamilyResult[0].deterministic_status -ceq $ExpectedDeterministic) "$Context family '$FamilyId' deterministic_status does not aggregate failed > evidence_unavailable > passed."
			Assert-True ($FamilyResult[0].promotion_status -ceq $ExpectedPromotion) "$Context family '$FamilyId' promotion_status does not aggregate non_promotion > eligible."
			if ($Asset.lifecycle_state -cin @('runtime_candidate','production_approved') -and $FamilyId -ceq 'reference_boundary') {
				Assert-True ($FamilyResult[0].applicability -ceq 'applicable') "$Context runtime lifecycle requires applicable reference_boundary evidence."
			}
			if ($FamilyResult[0].applicability -ceq 'not_applicable') {
				Assert-True ($FamilyResult[0].evidence -ceq (Get-CanonicalNotApplicableEvidence $FamilyId)) "$Context family '$FamilyId' not_applicable status requires exact canonical evidence."
			}
			$AggregateStatus = if ($FamilyResult[0].deterministic_status -ceq 'failed') { 'failed' } elseif ($FamilyResult[0].promotion_status -ceq 'non_promotion') { 'non_promotion' } else { 'passed' }
			$FamilyStatuses.Add($AggregateStatus)
			$FamilyRecords.Add([pscustomobject]@{ AssetPath = $Asset.asset_path; PolicyId = $FamilyId; Deterministic = $FamilyResult[0].deterministic_status; Promotion = $FamilyResult[0].promotion_status })
		}
	}

	foreach ($Finding in $Findings) {
		Assert-True (Test-JsonObject $Finding) "$Context finding must be a JSON object."
		Assert-ClosedProperties $Finding @($ReportContract.finding_required_fields) "$Context finding"
		foreach ($Field in @($ReportContract.finding_required_fields)) {
			Assert-True (Test-NonBlankJsonString $Finding.$Field) "$Context finding field '$Field' must be a non-blank string."
		}
		Assert-True ($ExpectedFamilies -ccontains $Finding.policy_id) "$Context finding has an unknown policy family."
		Assert-True (@($ReportContract.allowed_severities) -ccontains $Finding.severity) "$Context finding severity is unsupported."
		$PolicyFamily = @($Policy.policy_families | Where-Object { $_.id -ceq $Finding.policy_id })[0]
		$ExpectedCode = if ($Finding.severity -ceq 'error') { [string]$PolicyFamily.failure_code } else { [string]$PolicyFamily.failure_code -replace '\.failed$', '.non_promotion' }
		Assert-True ($Finding.code -ceq $ExpectedCode) "$Context finding code '$($Finding.code)' does not match policy family '$($Finding.policy_id)' stable code '$ExpectedCode'."
		$MatchingFamily = @($FamilyRecords | Where-Object { $_.AssetPath -ceq $Finding.asset_path -and $_.PolicyId -ceq $Finding.policy_id })
		Assert-True ($MatchingFamily.Count -eq 1) "$Context finding '$($Finding.policy_id)' does not identify one reported asset family."
		if ($Finding.severity -ceq 'error') {
			Assert-True ($MatchingFamily[0].Deterministic -ceq 'failed') "$Context error finding '$($Finding.policy_id)' requires deterministic_status failed."
		}
		else {
			Assert-True ($MatchingFamily[0].Deterministic -cne 'failed' -and $MatchingFamily[0].Promotion -ceq 'non_promotion') "$Context non-promotion finding '$($Finding.policy_id)' requires a non-failed family with promotion_status non_promotion."
		}
	}
	foreach ($FamilyRecord in @($FamilyRecords | Where-Object { $_.Deterministic -ceq 'failed' -or $_.Promotion -ceq 'non_promotion' })) {
		$ExpectedSeverity = if ($FamilyRecord.Deterministic -ceq 'failed') { 'error' } else { 'non_promotion' }
		$MatchingFindings = @($Findings | Where-Object { $_.asset_path -ceq $FamilyRecord.AssetPath -and $_.policy_id -ceq $FamilyRecord.PolicyId -and $_.severity -ceq $ExpectedSeverity })
		Assert-True ($MatchingFindings.Count -eq 1) "$Context blocking family '$($FamilyRecord.PolicyId)' must have exactly one precedence-correlated finding."
	}

	$Errors = @($Findings | Where-Object { $_.severity -ceq 'error' }).Count
	$NonPromotion = @($Findings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
	Assert-True ($Report.counts.errors -eq $Errors) "$Context error count is inconsistent."
	Assert-True ($Report.counts.non_promotion -eq $NonPromotion) "$Context non-promotion count is inconsistent."
	if ($Report.result -ceq 'passed') {
		Assert-True ($Errors -eq 0 -and $NonPromotion -eq 0 -and ($FamilyStatuses -notcontains 'failed') -and ($FamilyStatuses -notcontains 'non_promotion')) "$Context reports passed despite blocking family results."
	}
	elseif ($Report.result -ceq 'failed') {
		Assert-True ($Errors -gt 0 -and ($FamilyStatuses -contains 'failed')) "$Context reports failed without an error family result and diagnostic."
	}
	else {
		Assert-True ($Errors -eq 0 -and $NonPromotion -gt 0 -and ($FamilyStatuses -contains 'non_promotion')) "$Context non-promotion result is inconsistent."
	}
}

function Assert-ReportRejected([object] $Report, [string] $ExpectedMessage, [string] $Context) {
	$Failure = $null
	try { Assert-ReportContract $Report $Context } catch { $Failure = $_.Exception.Message }
	Assert-True (-not [string]::IsNullOrWhiteSpace($Failure)) "$Context must fail report-contract validation."
	Assert-True ($Failure -match $ExpectedMessage) "$Context failed with an unexpected diagnostic: $Failure"
}

function New-ContentFixtureInput {
	$FamilyInputs = [ordered]@{}
	foreach ($Family in $Policy.policy_families) {
		$Checks = [ordered]@{}
		foreach ($Check in $Family.checks) {
			$Checks[[string]$Check] = [ordered]@{
				observations = @("fixture:$($Family.id):${Check}:observed")
				violations = @()
			}
		}
		$FamilyInputs[[string]$Family.id] = [ordered]@{
			checks = $Checks
		}
	}
	return [ordered]@{
		asset_path = '/Game/Fixtures/DA_GovernedFixture'
		stable_id = 'content.fixture.governed'
		content_version = 1
		audience = 'shared'
		lifecycle_state = 'runtime_candidate'
		provenance = [ordered]@{
			author_or_provider = 'fixture-author'
			source_record = 'fixture://source-record'
			source_version = 'fixture-v1'
			license_or_permission_evidence = 'fixture-rights-record'
			modifications = 'none'
			generation_metadata_when_applicable = 'not_applicable'
			content_sha256 = ('1' * 64)
			reviewer = 'fixture-reviewer'
			approval_state = 'runtime_candidate_approved'
		}
		lifecycle_evidence = [ordered]@{
			content_identity = [ordered]@{ stable_id = 'content.fixture.governed'; content_version = 1; content_sha256 = ('1' * 64) }
			temporary_prototype = @()
			runtime_candidate = @([ordered]@{ review_revision = ('a' * 40); reviewer = 'fixture-reviewer'; approval_record = 'fixture://approval-record'; stable_id = 'content.fixture.governed'; content_version = 1; content_sha256 = ('1' * 64) })
			production_approval = @()
		}
		family_inputs = $FamilyInputs
	}
}

$PromotionBlockingChecks = @{
	collision = @('presentation_equivalence')
	rendering_suitability = @('hlod','nanite_suitability','streaming')
	texture = @('streaming')
	material = @('shader_complexity_evidence')
	skeletal_animation = @('morph_policy','influences','animation_complexity')
	map_world = @('data_layers','pcg_authority')
	navigation = @('streaming_boundaries','runtime_rebuild_policy')
	reference_boundary = @()
}

function Invoke-ContentFixtureValidation([object] $FixtureInput) {
	Assert-ClosedProperties $FixtureInput @('asset_path','stable_id','content_version','audience','lifecycle_state','provenance','lifecycle_evidence','family_inputs') 'Content fixture input'
	Assert-True (Test-JsonObject $FixtureInput.family_inputs) 'Content fixture family_inputs must be an object.'
	Assert-ClosedProperties $FixtureInput.family_inputs $ExpectedFamilies 'Content fixture family_inputs'
	$FamilyResults = [System.Collections.Generic.List[object]]::new()
	$Findings = [System.Collections.Generic.List[object]]::new()
	foreach ($Family in $Policy.policy_families) {
		$FamilyId = [string]$Family.id
		$FamilyInput = (Get-JsonProperty $FixtureInput.family_inputs $FamilyId).Value
		Assert-True (Test-JsonObject $FamilyInput) "Content fixture family '$FamilyId' must be an object."
		Assert-ClosedProperties $FamilyInput @('checks') "Content fixture family '$FamilyId'"
		Assert-True ($Family.applicability_required -eq $true) "Content fixture family '$FamilyId' must use the committed policy applicability rule."
		Assert-True (Test-JsonObject $FamilyInput.checks) "Content fixture family '$FamilyId' checks must be an object."
		$ExpectedChecks = @($Family.checks | ForEach-Object { [string]$_ })
		Assert-ClosedProperties $FamilyInput.checks $ExpectedChecks "Content fixture family '$FamilyId' checks"
		$CheckResults = [System.Collections.Generic.List[object]]::new()
		$FailedChecks = [System.Collections.Generic.List[string]]::new()
		$BlockedChecks = [System.Collections.Generic.List[string]]::new()
		$ObservedCheckCount = 0
		foreach ($Check in $ExpectedChecks) {
			$CheckValue = (Get-JsonProperty $FamilyInput.checks $Check).Value
			$Applicable = $null -ne $CheckValue
			$Passed = $false
			if ($Applicable) {
				Assert-True (Test-JsonObject $CheckValue) "Content fixture family '$FamilyId' check '$Check' must contain raw observation facts or null."
				Assert-ClosedProperties $CheckValue @('observations','violations') "Content fixture family '$FamilyId' check '$Check' raw facts"
				$Observations = @($CheckValue.observations)
				$Violations = @($CheckValue.violations)
				Assert-True ($Observations.Count -gt 0) "Content fixture family '$FamilyId' check '$Check' needs at least one observed fact."
				foreach ($Fact in @($Observations + $Violations)) { Assert-True (Test-NonBlankJsonString $Fact) "Content fixture family '$FamilyId' check '$Check' facts must be non-blank strings." }
				$ObservedCheckCount++
				$Passed = $Violations.Count -eq 0
				if (-not $Passed) { $FailedChecks.Add($Check) }
			}
			$PromotionBlocked = $Applicable -and ((-not $Passed) -or ($PromotionBlockingChecks[$FamilyId] -ccontains $Check) -or $FixtureInput.lifecycle_state -ceq 'temporary_prototype')
			if ($PromotionBlocked) { $BlockedChecks.Add($Check) }
			$CheckResults.Add([ordered]@{
				check_id = $Check
				applicability = if ($Applicable) { 'applicable' } else { 'not_applicable' }
				deterministic_status = if (-not $Applicable) { 'not_applicable' } elseif ($Passed) { 'passed' } else { 'failed' }
				promotion_status = if (-not $Applicable) { 'not_applicable' } elseif ($PromotionBlocked) { 'non_promotion' } else { 'eligible' }
				evidence = if ($Applicable) { "fixture:${FamilyId}:${Check}:observations=$($Observations.Count);violations=$($Violations.Count)" } else { "fixture:${FamilyId}:${Check}:not_applicable" }
			})
		}
		$Applicability = if ($ObservedCheckCount -eq 0) { 'not_applicable' } else { 'applicable' }
		if ($FixtureInput.lifecycle_state -cin @('runtime_candidate','production_approved') -and $FamilyId -ceq 'reference_boundary') {
			Assert-True ($Applicability -ceq 'applicable') "Content fixture runtime lifecycle requires complete reference_boundary raw observations."
		}
		$DeterministicStatus = if ($Applicability -ceq 'not_applicable') {
			'not_applicable'
		}
		elseif ($FailedChecks.Count -gt 0) {
			'failed'
		}
		else {
			'passed'
		}
		$PromotionStatus = if ($Applicability -ceq 'not_applicable') { 'not_applicable' } elseif ($FailedChecks.Count -gt 0 -or $BlockedChecks.Count -gt 0) { 'non_promotion' } else { 'eligible' }
		$Evidence = if ($DeterministicStatus -ceq 'not_applicable') {
			Get-CanonicalNotApplicableEvidence $FamilyId
		}
		elseif ($DeterministicStatus -ceq 'failed') {
			"fixture:${FamilyId}:failed=$($FailedChecks -join ',')"
		}
		elseif ($PromotionStatus -ceq 'non_promotion') {
			"policy:${FamilyId}:non_promotion:unresolved_budgets=$($UnresolvedBudgetIds -join ',')"
		}
		else {
			"fixture:${FamilyId}:validated=$($ExpectedChecks -join ',')"
		}
		$FamilyResults.Add([ordered]@{
			policy_id = $FamilyId
			applicability = $Applicability
			deterministic_status = $DeterministicStatus
			promotion_status = $PromotionStatus
			evidence = $Evidence
			check_results = @($CheckResults)
		})
		if ($DeterministicStatus -ceq 'failed') {
			$Findings.Add([ordered]@{
				policy_id = $FamilyId
				code = [string]$Family.failure_code
				asset_path = [string]$FixtureInput.asset_path
				severity = 'error'
				reason = "Deterministic $FamilyId checks failed: $($FailedChecks -join ', ')."
				remediation = "Correct the failed $FamilyId inputs and rerun validation."
				evidence_field = "family_inputs.$FamilyId.checks.$($FailedChecks -join ',')"
			})
		}
		elseif ($PromotionStatus -ceq 'non_promotion') {
			$Findings.Add([ordered]@{
				policy_id = $FamilyId
				code = ([string]$Family.failure_code -replace '\.failed$', '.non_promotion')
				asset_path = [string]$FixtureInput.asset_path
				severity = 'non_promotion'
				reason = "Quantitative thresholds remain $($Policy.thresholds.unresolved_value) under the committed policy."
				remediation = "Resolve the governed budgets with their owners and revisit triggers before promotion."
				evidence_field = 'thresholds.unresolved_budgets'
			})
		}
	}
	$ErrorCount = @($Findings | Where-Object { $_.severity -ceq 'error' }).Count
	$NonPromotionCount = @($Findings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
	return [ordered]@{
		schema_id = 'aetheln.content-validation-report'
		schema_version = 2
		revision = ('a' * 40)
		engine_identity = "5.8.1-release@$('b' * 40)"
		policy_sha256 = ('0' * 64)
		intake_sha256 = ('2' * 64)
		execution_provenance = [ordered]@{
			repository_clean = $true
			engine_revision = ('b' * 40)
			engine_tag = '5.8.1-release'
			engine_binary_sha256 = ('3' * 64)
			build_version_sha256 = ('4' * 64)
			target = 'AethelnOnlineEditor'
			platform = 'Win64'
			configuration = 'Development'
			editor_build_command_sha256 = ('9' * 64)
			editor_build_log_sha256 = ('a' * 64)
			compiler_version = 'fixture compiler 1.0'
			compiler_sha256 = ('5' * 64)
			resource_compiler_version = 'fixture resource compiler 1.0'
			resource_compiler_sha256 = ('6' * 64)
			target_receipt = [ordered]@{ path = 'Binaries/Win64/AethelnOnlineEditor.target'; size_bytes = 101; sha256 = ('b' * 64); build_id = 'fixture-build-id' }
			module_manifest = [ordered]@{ path = 'Binaries/Win64/UnrealEditor.modules'; size_bytes = 102; sha256 = ('c' * 64); build_id = 'fixture-build-id' }
			loaded_project_modules = @(
				[ordered]@{ name = 'GameCore'; path = 'Binaries/Win64/UnrealEditor-GameCore.dll'; size_bytes = 103; sha256 = ('d' * 64); build_id = 'fixture-build-id' },
				[ordered]@{ name = 'GameTests'; path = 'Binaries/Win64/UnrealEditor-GameTests.dll'; size_bytes = 104; sha256 = ('e' * 64); build_id = 'fixture-build-id' }
			)
			project_sha256 = ('7' * 64)
			policy_sha256 = ('0' * 64)
			intake_sha256 = ('2' * 64)
			invocation_sha256 = ('8' * 64)
			registry_source = 'test_snapshot'
		}
		audience = 'all'
		started_utc = '2026-09-05T00:00:00Z'
		finished_utc = '2026-09-05T00:00:01Z'
		command = 'portable deterministic fixture validator; no editor scanner executed'
		counts = [ordered]@{ assets = 1; findings = $Findings.Count; errors = $ErrorCount; non_promotion = $NonPromotionCount }
		assets = @([ordered]@{
			asset_path = $FixtureInput.asset_path
			stable_id = $FixtureInput.stable_id
			content_version = $FixtureInput.content_version
			audience = $FixtureInput.audience
			lifecycle_state = $FixtureInput.lifecycle_state
			provenance = $FixtureInput.provenance
			lifecycle_evidence = $FixtureInput.lifecycle_evidence
			family_results = @($FamilyResults)
		})
		findings = @($Findings)
		result = if ($ErrorCount -gt 0) { 'failed' } elseif ($NonPromotionCount -gt 0) { 'non_promotion' } else { 'passed' }
	}
}

$AllApplicableInput = New-ContentFixtureInput
$AllApplicablePolicyOutcome = Invoke-ContentFixtureValidation $AllApplicableInput
$AllApplicableRoundTrip = ($AllApplicablePolicyOutcome | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
Assert-ReportContract $AllApplicableRoundTrip 'All-applicable policy-outcome fixture'
$AllApplicableNonPromotion = @($AllApplicableRoundTrip.findings | Where-Object { $_.severity -ceq 'non_promotion' })
Assert-True ($AllApplicableRoundTrip.result -ceq 'non_promotion') 'Applicable families under the current TBD quantitative policy cannot emit an overall passed result.'
Assert-True ($AllApplicableNonPromotion.Count -eq 7 -and $AllApplicableRoundTrip.counts.non_promotion -eq 7 -and $AllApplicableRoundTrip.counts.errors -eq 0) 'Every applicable family with an unresolved quantitative budget must emit one non-promotion finding; reference_boundary remains independently eligible.'
Write-Output 'PASS: all-applicable raw inputs under current TBD policy emit non-promotion evidence'

$PassingInput = Copy-JsonObject $AllApplicableInput
$PassingInput.lifecycle_state = 'concept_reference'
$PassingInput.provenance.approval_state = 'concept_reference_reviewed'
$PassingInput.lifecycle_evidence.runtime_candidate = @()
foreach ($Family in $Policy.policy_families) {
	foreach ($Check in $Family.checks) { $PassingInput.family_inputs.$($Family.id).checks.$Check = $null }
}
$PassingFixture = Invoke-ContentFixtureValidation $PassingInput
$PassingJson = $PassingFixture | ConvertTo-Json -Depth 20
$PassingRoundTrip = $PassingJson | ConvertFrom-Json
Assert-ReportContract $PassingRoundTrip 'Passing fixture'
Assert-True ($PassingRoundTrip.result -ceq 'passed' -and @($PassingRoundTrip.findings).Count -eq 0) 'Representative passing fixture must emit passed machine-readable evidence.'
Write-Output 'PASS: genuinely non-applicable families emit a schema-complete passing report'

$FailingReports = @{}
foreach ($FamilyId in $ExpectedFamilies) {
	$FailingInput = Copy-JsonObject $AllApplicableInput
	$PolicyFamily = @($Policy.policy_families | Where-Object { $_.id -ceq $FamilyId })[0]
	$FailedCheck = [string]$PolicyFamily.checks[0]
	$FailingInput.family_inputs.$FamilyId.checks.$FailedCheck.violations = @("fixture:${FamilyId}:${FailedCheck}:violation")
	$FailingFixture = Invoke-ContentFixtureValidation $FailingInput
	$FailingRoundTrip = ($FailingFixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
	Assert-ReportContract $FailingRoundTrip "Failing $FamilyId fixture"
	Assert-True ($FailingRoundTrip.result -ceq 'failed') "Failing $FamilyId fixture must report failure."
	$FamilyFailure = @($FailingRoundTrip.findings | Where-Object { $_.policy_id -ceq $FamilyId -and $_.severity -ceq 'error' })
	Assert-True ($FamilyFailure.Count -eq 1 -and $FamilyFailure[0].evidence_field -match [regex]::Escape($FailedCheck)) "Failing $FamilyId fixture must emit one error diagnostic correlated to its invalid input."
	$ExpectedNonPromotionCount = if (@($PromotionBlockingChecks[$FamilyId]).Count -gt 0) { 6 } else { 7 }
	Assert-True ($FailingRoundTrip.counts.errors -eq 1 -and $FailingRoundTrip.counts.non_promotion -eq $ExpectedNonPromotionCount -and @($FailingRoundTrip.findings).Count -eq ($ExpectedNonPromotionCount + 1)) "Failing $FamilyId fixture must preserve non-promotion findings for every other blocked family while failed takes precedence for this family."
	$FailingReports[$FamilyId] = $FailingRoundTrip
	Write-Output "PASS: invalid $FamilyId input '$FailedCheck' emits correlated machine-readable diagnostics"
}

foreach ($ReferenceCheck in @('stable_id_unique','redirectors','broken_references','compatible_content_version','audience_reachability','hard_reference_exceptions')) {
	$ReferenceInput = Copy-JsonObject $AllApplicableInput
	$ReferenceInput.family_inputs.reference_boundary.checks.$ReferenceCheck.violations = @("fixture:reference_boundary:${ReferenceCheck}:violation")
	$ReferenceReport = Invoke-ContentFixtureValidation $ReferenceInput
	Assert-ReportContract $ReferenceReport "Invalid reference-boundary $ReferenceCheck fixture"
	$ReferenceFinding = @($ReferenceReport.findings | Where-Object { $_.policy_id -ceq 'reference_boundary' -and $_.severity -ceq 'error' })
	Assert-True ($ReferenceReport.result -ceq 'failed' -and $ReferenceFinding.Count -eq 1 -and $ReferenceFinding[0].evidence_field -match [regex]::Escape($ReferenceCheck)) "Invalid reference-boundary observation '$ReferenceCheck' must fail with correlated evidence."
}
Write-Output 'PASS: stable ID, redirector, broken dependency, exact version, soft audience, and hard audience violations fail independently'

$CorrectedReferenceFailure = Copy-JsonObject $FailingReports.reference_boundary
$CorrectedReferenceFamily = @($CorrectedReferenceFailure.assets[0].family_results | Where-Object { $_.policy_id -ceq 'reference_boundary' })[0]
$CorrectedFailedCheck = @($CorrectedReferenceFamily.check_results | Where-Object { $_.deterministic_status -ceq 'failed' })[0]
Assert-True ($CorrectedFailedCheck.promotion_status -ceq 'non_promotion') 'Failed check must block promotion even without a lifecycle or unresolved-budget blocker.'
Assert-True ($CorrectedReferenceFamily.promotion_status -ceq 'non_promotion') 'Family containing a failed check must block promotion even without a lifecycle or unresolved-budget blocker.'

$ForgedFailedEligible = Copy-JsonObject $CorrectedReferenceFailure
$ForgedReferenceFamily = @($ForgedFailedEligible.assets[0].family_results | Where-Object { $_.policy_id -ceq 'reference_boundary' })[0]
$ForgedReferenceFamily.promotion_status = 'eligible'
@($ForgedReferenceFamily.check_results | Where-Object { $_.deterministic_status -ceq 'failed' })[0].promotion_status = 'eligible'
Assert-ReportRejected $ForgedFailedEligible 'failed check.*must block promotion' 'Forged-failed-check-eligible fixture'

$ForgedFailedFamilyEligible = Copy-JsonObject $CorrectedReferenceFailure
@($ForgedFailedFamilyEligible.assets[0].family_results | Where-Object { $_.policy_id -ceq 'reference_boundary' })[0].promotion_status = 'eligible'
Assert-ReportRejected $ForgedFailedFamilyEligible 'promotion_status does not aggregate' 'Forged-failed-family-eligible fixture'

$ApplicableNotApplicable = Copy-JsonObject $AllApplicablePolicyOutcome
$ApplicableNotApplicable.assets[0].family_results[0].deterministic_status = 'not_applicable'
Assert-ReportRejected $ApplicableNotApplicable 'deterministic_status does not aggregate' 'Applicable-family-not-applicable fixture'

$UnavailableEvidence = Copy-JsonObject $AllApplicablePolicyOutcome
$UnavailableFamily = @($UnavailableEvidence.assets[0].family_results | Where-Object { $_.policy_id -ceq 'collision' })[0]
$UnavailableFamily.deterministic_status = 'evidence_unavailable'
$UnavailableFamily.check_results[0].deterministic_status = 'evidence_unavailable'
$UnavailableFamily.check_results[0].promotion_status = 'non_promotion'
$UnavailableFamily.check_results[0].evidence = 'fixture:collision:profile;evidence_unavailable:profile_name'
Assert-ReportContract $UnavailableEvidence 'Applicable-evidence-unavailable fixture'
Assert-True ($UnavailableEvidence.result -ceq 'non_promotion') 'Applicable unavailable evidence must remain distinct from failure, not_applicable, and TBD while blocking promotion.'

$UnavailableEligible = Copy-JsonObject $UnavailableEvidence
$UnavailableEligible.assets[0].family_results[0].check_results[0].promotion_status = 'eligible'
Assert-ReportRejected $UnavailableEligible 'unavailable check.*must block promotion' 'Unavailable-evidence-eligible fixture'

$AuthorSuppliedApplicability = Copy-JsonObject $AllApplicableInput
Add-Member -InputObject $AuthorSuppliedApplicability.family_inputs.material -MemberType NoteProperty -Name 'applicability' -Value 'not_applicable' -Force
$AuthorApplicabilityFailure = $null
try { Invoke-ContentFixtureValidation $AuthorSuppliedApplicability | Out-Null } catch { $AuthorApplicabilityFailure = $_.Exception.Message }
Assert-True ($AuthorApplicabilityFailure -match "unsupported field 'applicability'") 'Raw fixture input must not accept an author-supplied family applicability verdict.'
$AuthorSuppliedVerdict = Copy-JsonObject $AllApplicableInput
Add-Member -InputObject $AuthorSuppliedVerdict.family_inputs.material -MemberType NoteProperty -Name 'deterministic_status' -Value 'passed' -Force
$AuthorVerdictFailure = $null
try { Invoke-ContentFixtureValidation $AuthorSuppliedVerdict | Out-Null } catch { $AuthorVerdictFailure = $_.Exception.Message }
Assert-True ($AuthorVerdictFailure -match "unsupported field 'deterministic_status'") 'Raw fixture input must not accept an author-supplied deterministic verdict.'

$PartialObservations = Copy-JsonObject $AllApplicableInput
$PartialObservations.family_inputs.material.checks.material_instance_policy = $null
$PartialObservationReport = Invoke-ContentFixtureValidation $PartialObservations
Assert-ReportContract $PartialObservationReport 'Per-check-not-applicable fixture'
$PartialMaterial = @($PartialObservationReport.assets[0].family_results | Where-Object { $_.policy_id -ceq 'material' })[0]
Assert-True ($PartialMaterial.applicability -ceq 'applicable' -and @($PartialMaterial.check_results | Where-Object { $_.check_id -ceq 'material_instance_policy' })[0].deterministic_status -ceq 'not_applicable') 'Per-check applicability must not erase other observed material checks.'

$RuntimeWithoutReferenceEvidence = Copy-JsonObject $PassingInput
$RuntimeWithoutReferenceEvidence.lifecycle_state = 'runtime_candidate'
$RuntimeWithoutReferenceEvidence.provenance.approval_state = 'runtime_candidate_approved'
$RuntimeReferenceFailure = $null
try { Invoke-ContentFixtureValidation $RuntimeWithoutReferenceEvidence | Out-Null } catch { $RuntimeReferenceFailure = $_.Exception.Message }
Assert-True ($RuntimeReferenceFailure -match 'runtime lifecycle requires complete reference_boundary') 'A runtime lifecycle cannot mark every policy family not applicable.'

$ValidNotApplicableInput = Copy-JsonObject $AllApplicableInput
$MaterialPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq 'material' })[0]
foreach ($Check in $MaterialPolicy.checks) { $ValidNotApplicableInput.family_inputs.material.checks.$Check = $null }
$ValidNotApplicable = Invoke-ContentFixtureValidation $ValidNotApplicableInput
Assert-ReportContract $ValidNotApplicable 'Valid-not-applicable fixture'
$ValidNotApplicableMaterial = @($ValidNotApplicable.assets[0].family_results | Where-Object { $_.policy_id -ceq 'material' })[0]
Assert-True ($ValidNotApplicableMaterial.deterministic_status -ceq 'not_applicable' -and $ValidNotApplicableMaterial.promotion_status -ceq 'not_applicable' -and $ValidNotApplicable.result -ceq 'non_promotion') 'A genuinely non-applicable family must emit both not_applicable statuses without erasing other policy-mandated non-promotion outcomes.'

$ArbitraryNotApplicableEvidence = Copy-JsonObject $ValidNotApplicable
$ArbitraryMaterial = @($ArbitraryNotApplicableEvidence.assets[0].family_results | Where-Object { $_.policy_id -ceq 'material' })[0]
$ArbitraryMaterial.evidence = 'author supplied not-applicable evidence'
Assert-ReportRejected $ArbitraryNotApplicableEvidence 'not_applicable.*canonical evidence' 'Arbitrary-not-applicable-evidence fixture'

$NonApplicablePassed = Copy-JsonObject $ValidNotApplicable
$NonApplicablePassedMaterial = @($NonApplicablePassed.assets[0].family_results | Where-Object { $_.policy_id -ceq 'material' })[0]
$NonApplicablePassedMaterial.deterministic_status = 'passed'
Assert-ReportRejected $NonApplicablePassed 'deterministic_status does not aggregate' 'Non-applicable-family-passed fixture'

$StringSchemaVersion = Copy-JsonObject $PassingFixture
$StringSchemaVersion.schema_version = '2'
Assert-ReportRejected $StringSchemaVersion 'schema_version.*JSON integer' 'String-schema-version fixture'

$FractionalContentVersion = Copy-JsonObject $PassingFixture
$FractionalContentVersion.assets[0].content_version = 1.5
Assert-ReportRejected $FractionalContentVersion 'content_version.*JSON integer' 'Fractional-content-version fixture'

$NumericReviewer = Copy-JsonObject $PassingFixture
$NumericReviewer.assets[0].provenance.reviewer = 42
Assert-ReportRejected $NumericReviewer 'reviewer.*string' 'Numeric-reviewer fixture'

foreach ($InvalidHash in @(('A' * 64), ('a' * 63), ('g' * 64))) {
	$InvalidContentHash = Copy-JsonObject $PassingFixture
	$InvalidContentHash.assets[0].provenance.content_sha256 = $InvalidHash
	Assert-ReportRejected $InvalidContentHash 'content_sha256.*lowercase SHA-256' 'Invalid-content-hash fixture'
}

$DuplicateAssetPath = Copy-JsonObject $PassingFixture
$SecondAssetAtSamePath = Copy-JsonObject $DuplicateAssetPath.assets[0]
$SecondAssetAtSamePath.stable_id = 'content.fixture.other'
$DuplicateAssetPath.assets = @($DuplicateAssetPath.assets[0], $SecondAssetAtSamePath)
$DuplicateAssetPath.counts.assets = 2
Assert-ReportRejected $DuplicateAssetPath 'duplicate asset_path' 'Duplicate-asset-path fixture'

$MissingStableIdReport = Copy-JsonObject $PassingFixture
$MissingStableIdReport.assets[0].stable_id = ''
Assert-ReportRejected $MissingStableIdReport 'stable_id.*malformed' 'Missing-report-stable-id fixture'

$DuplicateStableIdReport = Copy-JsonObject $PassingFixture
$SecondAssetWithDuplicateId = Copy-JsonObject $DuplicateStableIdReport.assets[0]
$SecondAssetWithDuplicateId.asset_path = '/Game/Fixtures/DA_OtherFixture'
$DuplicateStableIdReport.assets = @($DuplicateStableIdReport.assets[0], $SecondAssetWithDuplicateId)
$DuplicateStableIdReport.counts.assets = 2
Assert-ReportRejected $DuplicateStableIdReport 'duplicate stable_id' 'Duplicate-report-stable-id fixture'

$NonUtcTimestamp = Copy-JsonObject $PassingFixture
$NonUtcTimestamp.started_utc = '2026-09-05T02:00:00+02:00'
Assert-ReportRejected $NonUtcTimestamp 'started_utc.*UTC' 'Non-UTC-timestamp fixture'

$MalformedRevision = Copy-JsonObject $PassingFixture
$MalformedRevision.revision = 'fixture-revision'
Assert-ReportRejected $MalformedRevision 'revision.*exact lowercase Git commit' 'Malformed-revision fixture'

$DirtyExecution = Copy-JsonObject $PassingFixture
$DirtyExecution.execution_provenance.repository_clean = $false
Assert-ReportRejected $DirtyExecution 'repository_clean must be true' 'Dirty-execution fixture'

$MismatchedIntakeHash = Copy-JsonObject $PassingFixture
$MismatchedIntakeHash.execution_provenance.intake_sha256 = ('9' * 64)
Assert-ReportRejected $MismatchedIntakeHash 'embedded intake hash' 'Mismatched-intake-hash fixture'

$UnsupportedRegistrySource = Copy-JsonObject $PassingFixture
$UnsupportedRegistrySource.execution_provenance.registry_source = 'author_supplied'
Assert-ReportRejected $UnsupportedRegistrySource 'registry_source is unsupported' 'Unsupported-registry-source fixture'

$UnknownExecutionField = Copy-JsonObject $PassingFixture
Add-Member -InputObject $UnknownExecutionField.execution_provenance -MemberType NoteProperty -Name 'unbound_note' -Value 'ignored'
Assert-ReportRejected $UnknownExecutionField 'unsupported field.*unbound_note' 'Unknown-execution-field fixture'

$MismatchedBuildId = Copy-JsonObject $PassingFixture
$MismatchedBuildId.execution_provenance.loaded_project_modules[1].build_id = 'other-build-id'
Assert-ReportRejected $MismatchedBuildId 'share one non-blank build_id' 'Mismatched-module-build-id fixture'

$ReorderedModules = Copy-JsonObject $PassingFixture
$ReorderedModules.execution_provenance.loaded_project_modules = @($ReorderedModules.execution_provenance.loaded_project_modules[1], $ReorderedModules.execution_provenance.loaded_project_modules[0])
Assert-ReportRejected $ReorderedModules 'loaded module 0 must be GameCore' 'Reordered-loaded-modules fixture'

$AbsoluteReceiptPath = Copy-JsonObject $PassingFixture
$AbsoluteReceiptPath.execution_provenance.target_receipt.path = 'D:/build/AethelnOnlineEditor.target'
Assert-ReportRejected $AbsoluteReceiptPath 'path must be canonical repository-relative' 'Absolute-receipt-path fixture'

$EmptyCompilerVersion = Copy-JsonObject $PassingFixture
$EmptyCompilerVersion.execution_provenance.compiler_version = ''
Assert-ReportRejected $EmptyCompilerVersion 'compiler_version.*non-blank' 'Empty-compiler-version fixture'

$PromotableTemporary = Copy-JsonObject $PassingFixture
$PromotableTemporary.assets[0].lifecycle_state = 'temporary_prototype'
$PromotableTemporary.assets[0].provenance.approval_state = 'temporary_prototype_only'
$PromotableTemporary.assets[0].lifecycle_evidence.runtime_candidate = @()
$PromotableTemporary.assets[0].lifecycle_evidence.temporary_prototype = @([ordered]@{ owner = 'fixture-owner'; approval_record = 'fixture://temporary'; recovery_trigger = 'fixture recovery'; may_be_runtime_candidate = $true })
Assert-ReportRejected $PromotableTemporary 'temporary prototype cannot be promotion-capable' 'Promotable-temporary fixture'

$WrongFailureCode = Copy-JsonObject $FailingReports.collision
$WrongFailureCode.findings[0].code = 'content.texture.failed'
Assert-ReportRejected $WrongFailureCode 'code.*collision' 'Wrong-family-code fixture'

$CrossFamilyFinding = Copy-JsonObject $FailingReports.collision
$CrossFamilyFinding.findings[0].policy_id = 'texture'
$CrossFamilyFinding.findings[0].code = 'content.texture.failed'
Assert-ReportRejected $CrossFamilyFinding "error finding 'texture'.*deterministic_status failed" 'Cross-family-finding fixture'
Write-Output 'PASS: family applicability, scalar formats, asset identity, and diagnostic correlation fail closed'

$MissingRights = Copy-JsonObject $PassingFixture
$MissingRights.assets[0].provenance.license_or_permission_evidence = ''
$MissingRightsFailure = $null
try { Assert-ReportContract $MissingRights 'Missing-rights fixture' } catch { $MissingRightsFailure = $_.Exception.Message }
Assert-True ($MissingRightsFailure -match 'license_or_permission_evidence.*empty') 'Missing usage-rights evidence must fail closed.'

$UnapprovedProduction = Copy-JsonObject $PassingFixture
$UnapprovedProduction.assets[0].lifecycle_state = 'production_approved'
$UnapprovedProductionFailure = $null
try { Assert-ReportContract $UnapprovedProduction 'Unapproved-production fixture' } catch { $UnapprovedProductionFailure = $_.Exception.Message }
Assert-True ($UnapprovedProductionFailure -match 'production_approved.*approval evidence') 'Production lifecycle without matching approval evidence must fail closed.'
Write-Output 'PASS: missing rights and production approval evidence fail closed'

foreach ($Heading in @('Lifecycle gates','Closed runtime registry','Asset-class intake matrix','Reference and cook boundaries','Rename, move, and recovery','Validation family contract','Evidence and deferred gates')) {
	Assert-True ($Documentation -match "(?m)^## $([regex]::Escape($Heading))$") "Contributor contract section '$Heading' is missing."
}
foreach ($Phrase in @('Git LFS','reimport','Data Layers','PCG','output preserves `non_promotion`','live Asset Registry','real client and dedicated-server cook evidence remains deferred')) {
	Assert-True ($DocumentationNormalized -match [regex]::Escape($Phrase)) "Contributor contract does not state '$Phrase'."
}
Write-Output 'PASS: contributor contract covers class ownership, reimport, world content, recovery, and deferred gates'

# No live producer binds navigation packages to cook evidence yet, so the live
# scanner must never emit the facts that would let navigation audience pass.
foreach ($AudienceFact in @('navigation_audience_evidence_recorded','client_audience_valid','server_audience_valid')) {
	$EmitPattern = '(?:\{\s*|\.Add\(\s*|\.Emplace\(\s*)TEXT\("' + [regex]::Escape($AudienceFact) + '"\)'
	Assert-True ($ScannerSource -notmatch $EmitPattern) "The live scanner must not emit '$AudienceFact' until governed navigation cook evidence exists."
	Assert-True ($ScannerSource -match ('RequiredBool\(TEXT\("' + [regex]::Escape($AudienceFact) + '"\)\)')) "The navigation evaluator must still require '$AudienceFact'."
}
Assert-True ($ScannerSource -match 'navigation_audience_evidence=unavailable') 'The live scanner must record navigation audience evidence as unavailable.'
Write-Output 'PASS: the live scanner never emits navigation audience evidence, so navigation stays non-promotion'

Write-Output 'All content validation policy and report-contract tests passed.'
