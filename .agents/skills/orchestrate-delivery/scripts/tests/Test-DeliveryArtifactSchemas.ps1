[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ExternalSchemaPath = Join-Path (
	$SkillRoot
) 'references\external-file-ingest-schema.json'
$CompositeSchemaPath = Join-Path (
	$SkillRoot
) 'references\delivery-composite-candidate-schema.json'
$Results = [Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [bool]$Passed) {
	$Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
}

function Get-SchemaPropertyNames([object]$Value) {
	return @($Value.PSObject.Properties.Name)
}

function Resolve-LocalSchemaReference([object]$Root, [string]$Reference) {
	if ($Reference -cnotmatch '^#/\$defs/([A-Za-z0-9_]+)$') {
		throw "Unsupported schema reference '$Reference'."
	}
	$Name = $Matches[1]
	if (@($Root.'$defs'.PSObject.Properties.Name) -cnotcontains $Name) {
		throw "Missing schema definition '$Name'."
	}
	return $Root.'$defs'.$Name
}

function Test-JsonSchemaInstance {
	param(
		[Parameter(Mandatory)][object]$Schema,
		[AllowNull()][object]$Instance,
		[Parameter(Mandatory)][object]$Root
	)
	if (@(Get-SchemaPropertyNames $Schema) -ccontains '$ref') {
		return Test-JsonSchemaInstance `
			-Schema (Resolve-LocalSchemaReference $Root ([string]$Schema.'$ref')) `
			-Instance $Instance -Root $Root
	}
	if (@(Get-SchemaPropertyNames $Schema) -ccontains 'oneOf') {
		$Matches = @($Schema.oneOf | Where-Object {
			Test-JsonSchemaInstance -Schema $_ -Instance $Instance -Root $Root
		})
		if ($Matches.Count -ne 1) { return $false }
	}
	if (@(Get-SchemaPropertyNames $Schema) -ccontains 'const' -and
		-not [object]::Equals($Instance, $Schema.const)) {
		return $false
	}
	if (@(Get-SchemaPropertyNames $Schema) -ccontains 'type') {
		switch ([string]$Schema.type) {
			'object' {
				if ($Instance -isnot [pscustomobject]) { return $false }
				$Actual = @(Get-SchemaPropertyNames $Instance)
				foreach ($Name in @($Schema.required)) {
					if ($Actual -cnotcontains [string]$Name) { return $false }
				}
				if ($Schema.additionalProperties -eq $false) {
					$Allowed = @(Get-SchemaPropertyNames $Schema.properties)
					if (@($Actual | Where-Object {
						$Allowed -cnotcontains $_
					}).Count) {
						return $false
					}
				}
				foreach ($Property in $Schema.properties.PSObject.Properties) {
					if ($Actual -ccontains $Property.Name -and
						-not (Test-JsonSchemaInstance -Schema $Property.Value `
							-Instance $Instance.($Property.Name) -Root $Root)) {
						return $false
					}
				}
			}
			'array' {
				if ($Instance -isnot [Array]) { return $false }
				$Values = @($Instance)
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'minItems' -and
					$Values.Count -lt [int]$Schema.minItems) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'maxItems' -and
					$Values.Count -gt [int]$Schema.maxItems) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'uniqueItems' -and
					$Schema.uniqueItems -eq $true) {
					$Unique = [Collections.Generic.HashSet[string]]::new(
						[StringComparer]::Ordinal
					)
					foreach ($Value in $Values) {
						$Identity = $Value | ConvertTo-Json -Depth 20 -Compress
						if (-not $Unique.Add($Identity)) { return $false }
					}
				}
				foreach ($Value in $Values) {
					if (-not (Test-JsonSchemaInstance -Schema $Schema.items `
							-Instance $Value -Root $Root)) {
						return $false
					}
				}
			}
			'string' {
				if ($Instance -isnot [string]) { return $false }
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'minLength' -and
					$Instance.Length -lt [int]$Schema.minLength) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'maxLength' -and
					$Instance.Length -gt [int]$Schema.maxLength) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'pattern' -and
					$Instance -cnotmatch [string]$Schema.pattern) {
					return $false
				}
			}
			'integer' {
				if ($Instance -isnot [byte] -and $Instance -isnot [sbyte] -and
					$Instance -isnot [int16] -and $Instance -isnot [uint16] -and
					$Instance -isnot [int32] -and $Instance -isnot [uint32] -and
					$Instance -isnot [int64] -and $Instance -isnot [uint64] -and
					$Instance -isnot [decimal] -and $Instance -isnot [double] -and
					$Instance -isnot [single]) {
					return $false
				}
				$Numeric = [decimal]$Instance
				if ([decimal]::Truncate($Numeric) -ne $Numeric) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'minimum' -and
					$Numeric -lt [decimal]$Schema.minimum) {
					return $false
				}
				if (@(Get-SchemaPropertyNames $Schema) -ccontains 'maximum' -and
					$Numeric -gt [decimal]$Schema.maximum) {
					return $false
				}
			}
			default { throw "Unsupported schema type '$($Schema.type)'." }
		}
	}
	return $true
}

function Assert-SchemaKeywordCoverage([object]$Schema) {
	$Known = @(
		'$schema','$comment','$defs','$ref','oneOf','type','additionalProperties',
		'required','properties','const','pattern','minLength','maxLength','minimum',
		'maximum','minItems','maxItems','uniqueItems','items'
	)
	foreach ($Property in $Schema.PSObject.Properties) {
		if ($Known -cnotcontains $Property.Name) {
			throw "Schema uses untested keyword '$($Property.Name)'."
		}
		if ($Property.Name -in @('$defs', 'properties')) {
			foreach ($Child in $Property.Value.PSObject.Properties) {
				Assert-SchemaKeywordCoverage $Child.Value
			}
		}
		elseif ($Property.Name -eq 'oneOf') {
			foreach ($Child in @($Property.Value)) {
				Assert-SchemaKeywordCoverage $Child
			}
		}
		elseif ($Property.Name -eq 'items') {
			Assert-SchemaKeywordCoverage $Property.Value
		}
	}
}

$ExternalSchema = Get-Content -Raw -LiteralPath $ExternalSchemaPath |
	ConvertFrom-Json
$CompositeSchema = Get-Content -Raw -LiteralPath $CompositeSchemaPath |
	ConvertFrom-Json
Assert-SchemaKeywordCoverage $ExternalSchema
Assert-SchemaKeywordCoverage $CompositeSchema

$File = [pscustomobject][ordered]@{
	path = 'asset.md'; operation = 'create'; size = 1; sha256 = 'a' * 64
}
$InventoryFile = [pscustomobject][ordered]@{
	path = 'asset.md'; size = 1; sha256 = 'a' * 64
}
$ValidExternal = @(
	[pscustomobject][ordered]@{
		format = 'delivery_external_file_bundle_v1'
		target_root = 'visuals'
		files = @($File)
	},
	[pscustomobject][ordered]@{
		format = 'delivery_external_file_ingest_journal_v1'
		state = 'prepared'
		source_commit = 'a' * 40
		repository_root = 'D:\repo'
		source_root = 'C:\source\visuals'
		staging_root = 'D:\stage\ingest'
		staged_payload_root = 'D:\stage\ingest\payload'
		target_root = 'visuals'
		destination_root = 'D:\repo\visuals'
		external_manifest_sha256 = 'b' * 64
		expected_inventory_sha256 = 'c' * 64
		files = @($InventoryFile)
	},
	[pscustomobject][ordered]@{
		format = 'delivery_external_file_ingest_evidence_v1'
		disposition = 'accepted'
		source_commit = 'a' * 40
		target_root = 'visuals'
		destination_root = 'D:\repo\visuals'
		external_manifest_sha256 = 'b' * 64
		prepared_journal_sha256 = 'c' * 64
		final_inventory_sha256 = 'd' * 64
		changed_paths = @('visuals/asset.md')
		files = @($InventoryFile)
	}
)
Add-Result 'External root schema selects all three valid contracts' (
	@($ValidExternal | Where-Object {
		-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
			-Instance $_ -Root $ExternalSchema)
	}).Count -eq 0
)
Add-Result 'External root schema rejects an empty object' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance ([pscustomobject]@{}) -Root $ExternalSchema)
)
$WrongFormat = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$WrongFormat.format = 'wrong'
Add-Result 'External root schema rejects a wrong format' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $WrongFormat -Root $ExternalSchema)
)
$ExtraField = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$ExtraField | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
Add-Result 'External root schema rejects extra fields' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $ExtraField -Root $ExternalSchema)
)
$UnsafeExternalPath = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$UnsafeExternalPath.files[0].path = '../escape.md'
Add-Result 'External root schema rejects unsafe paths' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $UnsafeExternalPath -Root $ExternalSchema)
)
$LongExternalPath = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$LongExternalPath.files[0].path = ('a' * 238) + '.md'
Add-Result 'External root schema rejects overlong paths' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $LongExternalPath -Root $ExternalSchema)
)
$OversizedInteger = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$OversizedInteger.files[0].size = [decimal]9223372036854775808
Add-Result 'External root schema rejects sizes above signed 64-bit range' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $OversizedInteger -Root $ExternalSchema)
)
$FractionalInteger = $ValidExternal[0] | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$FractionalInteger.files[0].size = [decimal]1.5
Add-Result 'External root schema rejects fractional sizes' (
	-not (Test-JsonSchemaInstance -Schema $ExternalSchema `
		-Instance $FractionalInteger -Root $ExternalSchema)
)

$ValidComposite = [pscustomobject][ordered]@{
	format = 'delivery_composite_candidate_v1'
	source_commit = 'a' * 40
	external_ingest_evidence_sha256 = 'b' * 64
	text_patch_evidence_sha256 = 'c' * 64
	final_inventory_sha256 = 'd' * 64
	changed_paths = @('visuals/asset.md')
}
Add-Result 'Composite schema accepts its valid closed contract' (
	Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance $ValidComposite -Root $CompositeSchema
)
Add-Result 'Composite schema rejects an empty object' (
	-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance ([pscustomobject]@{}) -Root $CompositeSchema)
)
$WrongCompositeFormat = $ValidComposite | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$WrongCompositeFormat.format = 'wrong'
Add-Result 'Composite schema rejects a wrong format' (
	-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance $WrongCompositeFormat -Root $CompositeSchema)
)
$BadComposite = $ValidComposite | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$BadComposite | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
Add-Result 'Composite schema rejects extra fields' (
	-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance $BadComposite -Root $CompositeSchema)
)
$UnsafeComposite = $ValidComposite | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$UnsafeComposite.changed_paths = @('/rooted.md')
Add-Result 'Composite schema rejects rooted paths' (
	-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance $UnsafeComposite -Root $CompositeSchema)
)
foreach ($UnsafePath in @('CON.md', 'docs/bad?name.md', 'docs/trailing.')) {
	$UnsafeComposite = $ValidComposite | ConvertTo-Json -Depth 8 -Compress |
		ConvertFrom-Json
	$UnsafeComposite.changed_paths = @($UnsafePath)
	Add-Result "Composite schema rejects unsafe path $UnsafePath" (
		-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
			-Instance $UnsafeComposite -Root $CompositeSchema)
	)
}
$DuplicateComposite = $ValidComposite | ConvertTo-Json -Depth 8 -Compress |
	ConvertFrom-Json
$DuplicateComposite.changed_paths = @('docs/a.md', 'docs/a.md')
Add-Result 'Composite schema rejects exact duplicate paths' (
	-not (Test-JsonSchemaInstance -Schema $CompositeSchema `
		-Instance $DuplicateComposite -Root $CompositeSchema)
)

$Failed = @($Results | Where-Object { -not $_.Passed })
$Results | Format-Table -AutoSize
if ($Failed.Count -gt 0) { throw "$($Failed.Count) artifact schema tests failed." }
"All $($Results.Count) artifact schema tests passed."
