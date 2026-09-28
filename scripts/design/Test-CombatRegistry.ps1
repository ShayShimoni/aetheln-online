[CmdletBinding()]
param(
	[string] $RegistryPath,
	[string] $SchemaPath,
	[switch] $SkipMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RegistryPath) { $RegistryPath = Join-Path $PSScriptRoot '..\..\design\combat-registry\registry.json' }
if (-not $SchemaPath) { $SchemaPath = Join-Path $PSScriptRoot '..\..\design\combat-registry\schema.json' }

function Test-RegistryObject {
	param($Value, [string[]] $Required, [string[]] $Optional, [System.Collections.Generic.List[string]] $Errors, [string] $At)
	if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
		$Errors.Add("${At}: expected an object")
		return $false
	}
	$Names = @($Value.PSObject.Properties.Name)
	$Valid = $true
	foreach ($Name in $Required) {
		if ($Names -cnotcontains $Name) { $Errors.Add("${At}: missing $Name"); $Valid = $false }
	}
	foreach ($Name in $Names) {
		if ($Required -cnotcontains $Name -and $Optional -cnotcontains $Name) { $Errors.Add("${At}: unexpected $Name"); $Valid = $false }
	}
	return $Valid
}

function Test-RegistryPositiveInteger {
	param($Value)
	return (($Value -is [int] -or $Value -is [long]) -and $Value -gt 0)
}

function Test-RegistryNonnegativeInteger {
	param($Value)
	return (($Value -is [int] -or $Value -is [long]) -and $Value -ge 0)
}

function Test-RegistryArray {
	param($Value, [System.Collections.Generic.List[string]] $Errors, [string] $At)
	if ($Value -isnot [array]) {
		$Errors.Add("${At}: expected an array")
		return $false
	}
	return $true
}

function Test-RegistryExactValues {
	param($Actual, [string[]] $Expected)
	if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { return $false }
	foreach ($Value in $Expected) {
		if ($Actual -cnotcontains $Value) { return $false }
	}
	return $true
}

function Get-RegistrySourceSectionMap {
	param([string] $Path)
	$Lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
	$VisibleLines = New-Object 'System.Collections.Generic.List[string]'
	$FenceCharacter = $null
	$FenceLength = 0
	foreach ($Line in $Lines) {
		if ($Line -match '^ {0,3}(\x60{3,}|~{3,})(.*)$') {
			$Marker = $Matches[1]
			if ($null -eq $FenceCharacter) {
				$FenceCharacter = $Marker[0]
				$FenceLength = $Marker.Length
			}
			elseif ($Marker[0] -eq $FenceCharacter -and $Marker.Length -ge $FenceLength -and $Matches[2] -match '^\s*$') {
				$FenceCharacter = $null
				$FenceLength = 0
			}
			continue
		}
		if ($null -eq $FenceCharacter) { $VisibleLines.Add($Line) }
	}
	$Lines = @($VisibleLines.ToArray())
	$Sections = @{}
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -cnotmatch '^(#{1,6})\s+(.+)$') { continue }
		$Anchor = '#' + ((($Matches[2] -replace '[^a-zA-Z0-9\s-]', '') -replace '\s+', '-').ToLowerInvariant())
		$End = $Index + 1
		while ($End -lt $Lines.Count) {
			if ($Lines[$End] -match '^#{1,6}\s+') { break }
			$End++
		}
		if (-not $Sections.ContainsKey($Anchor)) { $Sections[$Anchor] = @() }
		$Body = if ($End -gt ($Index + 1)) { $Lines[($Index + 1)..($End - 1)] -join "`n" } else { '' }
		$Sections[$Anchor] += $Body
	}
	return $Sections
}

function Test-RegistryJsonKeyUniqueness {
	param([string] $RawJson, [string] $DocumentName, [System.Collections.Generic.List[string]] $Errors)
	$Frames = New-Object 'System.Collections.Generic.List[object]'
	foreach ($Match in [regex]::Matches($RawJson, '"(?:\\.|[^"\\])*"|[{}\[\],:]')) {
		$Token = $Match.Value
		switch ($Token) {
			'{' { $Frames.Add([pscustomobject]@{ kind = 'object'; keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase); expectKey = $true }); continue }
			'[' { $Frames.Add([pscustomobject]@{ kind = 'array' }); continue }
			'}' { if ($Frames.Count -gt 0) { $Frames.RemoveAt($Frames.Count - 1) }; continue }
			']' { if ($Frames.Count -gt 0) { $Frames.RemoveAt($Frames.Count - 1) }; continue }
			',' { if ($Frames.Count -gt 0 -and $Frames[$Frames.Count - 1].kind -eq 'object') { $Frames[$Frames.Count - 1].expectKey = $true }; continue }
		}
		if ($Token[0] -eq '"' -and $Frames.Count -gt 0) {
			$Frame = $Frames[$Frames.Count - 1]
			if ($Frame.kind -eq 'object' -and $Frame.expectKey) {
				$Key = ConvertFrom-Json -InputObject $Token -ErrorAction Stop
				if (-not $Frame.keys.Add($Key)) { $Errors.Add("${DocumentName}: duplicate JSON object property '$Key'") }
				$Frame.expectKey = $false
			}
		}
	}
}

function Test-RegistryCycle {
	param([string] $Id, [hashtable] $ById, [hashtable] $Colors, [System.Collections.Generic.List[string]] $Errors, [string[]] $Trail)
	if ($Colors[$Id] -eq 1) {
		$Errors.Add("cycle: $((@($Trail) + $Id) -join ' -> ')")
		return
	}
	if ($Colors[$Id] -eq 2) { return }
	$Colors[$Id] = 1
	$Record = $ById[$Id]
	foreach ($Edge in @($Record.references) + @($Record.emits)) {
		$Target = if ($Edge -is [string]) { $Edge } elseif ($null -ne $Edge -and $null -ne $Edge.PSObject.Properties['id']) { $Edge.id } else { $null }
		if ($Target -is [string] -and $ById.ContainsKey($Target)) {
			Test-RegistryCycle -Id $Target -ById $ById -Colors $Colors -Errors $Errors -Trail (@($Trail) + $Id)
		}
	}
	$Colors[$Id] = 2
}

function Get-RegistryRootWork {
	param([string] $Id, [hashtable] $ById, [hashtable] $Cache)
	if ($Cache.ContainsKey($Id)) { return $Cache[$Id] }
	$Record = $ById[$Id]
	$Total = @{ depth = [decimal]1; listeners = [decimal]0; procs = [decimal]0; targets = [decimal]0; constructs = [decimal]0 }
	if ($null -ne $Record.PSObject.Properties['work']) {
		foreach ($Kind in @('listeners', 'procs', 'targets', 'constructs')) { $Total[$Kind] = [decimal]$Record.work.$Kind }
	}
	foreach ($Target in @($Record.emits)) {
		$Child = Get-RegistryRootWork -Id $Target -ById $ById -Cache $Cache
		$Total.depth = [Math]::Max($Total.depth, ([decimal]1 + $Child.depth))
		foreach ($Kind in @('listeners', 'procs', 'targets', 'constructs')) { $Total[$Kind] += $Child[$Kind] }
	}
	$Cache[$Id] = $Total
	return $Total
}

function Test-CombatRegistry {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $RegistryPath, [Parameter(Mandatory)][string] $SchemaPath)
	$Errors = New-Object 'System.Collections.Generic.List[string]'
	try {
		$SchemaRaw = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8
		$RegistryRaw = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8
		Test-RegistryJsonKeyUniqueness -RawJson $SchemaRaw -DocumentName 'schema' -Errors $Errors
		Test-RegistryJsonKeyUniqueness -RawJson $RegistryRaw -DocumentName 'registry' -Errors $Errors
		if ($Errors.Count -gt 0) { return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) } }
		$Schema = ConvertFrom-Json -InputObject $SchemaRaw -ErrorAction Stop
		$Registry = ConvertFrom-Json -InputObject $RegistryRaw -ErrorAction Stop
	}
	catch {
		return [pscustomobject]@{ passed = $false; errors = @("invalid JSON or unreadable registry: $($_.Exception.Message)") }
	}
	if (-not (Test-RegistryObject -Value $Schema -Required @('schemaId','schemaVersion','registryId','supportedRegistryVersion','maturities','kinds','budgetKinds','requiredReferenceKinds','referenceKindPolicy','executionPolicy','prototypeCandidateIds','idPattern','sourcePattern') -Optional @() -Errors $Errors -At 'schema')) {
		return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) }
	}
	if ($Schema.schemaId -cne 'aetheln.combat-design-registry.schema' -or $Schema.schemaVersion -isnot [int] -or $Schema.schemaVersion -ne 1 -or $Schema.registryId -cne 'aetheln.combat-design-registry' -or $Schema.supportedRegistryVersion -isnot [int] -or $Schema.supportedRegistryVersion -ne 1) {
		$Errors.Add('schema: unsupported contract version or identity')
	}
	if ($Schema.referenceKindPolicy -cne 'any-of' -or $Schema.executionPolicy -cne 'manifest-only') { $Errors.Add('schema: unsupported reference or execution policy') }
	foreach ($Field in @('maturities','kinds','budgetKinds','prototypeCandidateIds')) { [void](Test-RegistryArray -Value $Schema.$Field -Errors $Errors -At "schema.$Field") }
	if ($Errors.Count -gt 0) { return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) } }
	# Version 1 is a closed contract: adding values or widening syntax requires a
	# reviewed schema and validator version change, not just editing schema.json.
	if (-not (Test-RegistryExactValues $Schema.kinds @('order','specialization','weapon','ability','peak','form','thread','keystone','heritage','resource','damageFamily','effect','construct','visibility','recovery','preset','manifest')) -or
		-not (Test-RegistryExactValues $Schema.maturities @('Canonical Intent','Prototype Candidate','Evidence Validated','Implementation Ready','Superseded')) -or
		-not (Test-RegistryExactValues $Schema.budgetKinds @('depth','listeners','procs','targets','constructs'))) {
		$Errors.Add('schema: unsupported v1 schema vocabulary')
	}
	if ($Schema.idPattern -cne '^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$' -or $Schema.sourcePattern -cne '^docs/[a-z0-9-]+\.md$') {
		$Errors.Add('schema: unsupported v1 schema pattern')
	}
	$ApprovedPrototypeIds = @(
		'combat.resource.health', 'combat.resource.endurance', 'combat.resource.guard', 'combat.damage.wrought',
		'order.oathscar.weapon.sword_and_shield', 'order.oathscar.ability.sword_shield_basic_chain',
		'order.oathscar.ability.gate_step', 'order.oathscar.ability.sworn_rebuke',
		'order.oathscar.ability.hold_the_line'
	)
	if ($Schema.prototypeCandidateIds.Count -ne $ApprovedPrototypeIds.Count -or @($Schema.prototypeCandidateIds | Sort-Object -Unique).Count -ne $ApprovedPrototypeIds.Count) {
		$Errors.Add('schema: prototype allowlist differs from the approved nine IDs')
	}
	foreach ($Id in $ApprovedPrototypeIds) {
		if ($Schema.prototypeCandidateIds -cnotcontains $Id) { $Errors.Add("schema: approved prototype ID $Id is missing") }
	}
	if (-not (Test-RegistryObject -Value $Schema.requiredReferenceKinds -Required @('specialization','weapon','peak','form','thread','keystone') -Optional @() -Errors $Errors -At 'schema.requiredReferenceKinds')) {
		return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) }
	}
	$ExpectedReferenceKinds = @{
		specialization = @('order'); weapon = @('order'); peak = @('order')
		form = @('ability'); thread = @('ability'); keystone = @('order','resource','ability')
	}
	foreach ($Property in $Schema.requiredReferenceKinds.PSObject.Properties) {
		if (-not (Test-RegistryArray -Value $Property.Value -Errors $Errors -At "schema.requiredReferenceKinds.$($Property.Name)")) { continue }
		if (-not (Test-RegistryExactValues $Property.Value $ExpectedReferenceKinds[$Property.Name])) { $Errors.Add('schema: unsupported v1 schema reference kinds') }
		foreach ($AllowedKind in $Property.Value) {
			if ($Schema.kinds -cnotcontains $AllowedKind) { $Errors.Add("schema.requiredReferenceKinds.$($Property.Name): unknown kind $AllowedKind") }
		}
	}
	if ($Errors.Count -gt 0) { return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) } }
	if (-not (Test-RegistryObject -Value $Registry -Required @('schemaId','schemaVersion','definitions','budgets') -Optional @() -Errors $Errors -At 'registry')) {
		return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) }
	}
	if ($Registry.schemaId -cne $Schema.registryId -or $Registry.schemaVersion -isnot [int] -or $Registry.schemaVersion -ne $Schema.supportedRegistryVersion) { $Errors.Add('registry: incompatible schema identity or version') }
	if (-not (Test-RegistryArray -Value $Registry.definitions -Errors $Errors -At 'registry.definitions') -or -not (Test-RegistryArray -Value $Registry.budgets -Errors $Errors -At 'registry.budgets')) {
		return [pscustomobject]@{ passed = $false; errors = @($Errors.ToArray()) }
	}
	$ById = @{}
	$WriterBySlot = @{}
	$SourceSections = @{}
	$EdgesReady = $true
	foreach ($Record in $Registry.definitions) {
		if (-not (Test-RegistryObject -Value $Record -Required @('id','kind','definitionVersion','maturity','displayName','summary','source','sourceAnchor','ownerIssue','references','emits','writes') -Optional @('work','supersededBy','evidence','composition') -Errors $Errors -At 'definition')) { $EdgesReady = $false; continue }
		$At = "definition $($Record.id)"
		if ($Record.id -isnot [string] -or $Record.id -cnotmatch $Schema.idPattern) { $Errors.Add("${At}: invalid stable ID"); continue }
		if ($ById.ContainsKey($Record.id)) { $Errors.Add("${At}: duplicate stable ID"); continue }
		$ById[$Record.id] = $Record
		if ($Schema.kinds -cnotcontains $Record.kind) { $Errors.Add("${At}: unknown definition kind") }
		if (-not (Test-RegistryPositiveInteger $Record.definitionVersion)) { $Errors.Add("${At}: definitionVersion must be a positive integer") }
		if ($Schema.maturities -cnotcontains $Record.maturity) { $Errors.Add("${At}: unknown design maturity") }
		if ($Record.maturity -ceq 'Prototype Candidate' -and $ApprovedPrototypeIds -cnotcontains $Record.id) { $Errors.Add("${At}: outside the approved prototype subset") }
		if ($Record.displayName -isnot [string] -or [string]::IsNullOrWhiteSpace($Record.displayName) -or $Record.displayName.Length -gt 120 -or $Record.displayName -cmatch '[\x00-\x1f\x7f<>`\[\]|\\]') {
			$Errors.Add("${At}: displayName must be bounded single-line plain text")
		}
		if ($Record.summary -isnot [string] -or $Record.summary.Length -lt 1 -or $Record.summary.Length -gt 240 -or $Record.summary -cmatch '[\x00-\x1f\x7f<>`\[\]]') { $Errors.Add("${At}: summary must be bounded plain text") }
		if ($Record.source -isnot [string] -or $Record.source -cnotmatch $Schema.sourcePattern) { $Errors.Add("${At}: invalid canonical source path") }
		if ($Record.sourceAnchor -isnot [string] -or $Record.sourceAnchor -cnotmatch '^#[a-z][a-z0-9-]*$') { $Errors.Add("${At}: invalid canonical source anchor") }
		elseif ($Record.source -is [string] -and $Record.source -cmatch $Schema.sourcePattern) {
			$SourcePath = Join-Path (Resolve-Path (Join-Path (Split-Path -Parent $SchemaPath) '..\..')).Path $Record.source
			if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { $Errors.Add("${At}: canonical source is missing") }
			else {
				if (-not $SourceSections.ContainsKey($SourcePath)) { $SourceSections[$SourcePath] = Get-RegistrySourceSectionMap -Path $SourcePath }
				$Sections = $SourceSections[$SourcePath]
				if (-not $Sections.ContainsKey($Record.sourceAnchor)) { $Errors.Add("${At}: canonical source anchor is missing") }
				elseif ($Sections[$Record.sourceAnchor].Count -ne 1) { $Errors.Add("${At}: canonical source anchor is ambiguous") }
				elseif (($Sections[$Record.sourceAnchor][0] -replace '(?s)<!--.*?-->', '') -cnotmatch ("(?<![a-z0-9_.]){0}(?![a-z0-9_.])" -f [regex]::Escape($Record.id))) {
					$Errors.Add("${At}: canonical source section does not contain stable ID")
				}
			}
		}
		if (-not (Test-RegistryPositiveInteger $Record.ownerIssue)) { $Errors.Add("${At}: ownerIssue must be a positive integer") }
		foreach ($Field in @('references','emits','writes')) { if (-not (Test-RegistryArray -Value $Record.$Field -Errors $Errors -At "$At.$Field")) { $EdgesReady = $false } }
		if ($Record.maturity -ceq 'Superseded') {
			if ($null -eq $Record.PSObject.Properties['supersededBy']) { $Errors.Add("${At}: supersededBy is required") }
		}
		elseif ($null -ne $Record.PSObject.Properties['supersededBy']) { $Errors.Add("${At}: supersededBy is only valid for Superseded") }
		if ($Record.maturity -cin @('Evidence Validated','Implementation Ready')) {
			if ($null -eq $Record.PSObject.Properties['evidence'] -or -not (Test-RegistryArray -Value $Record.evidence -Errors $Errors -At "$At.evidence") -or $Record.evidence.Count -eq 0) {
				$Errors.Add("${At}: promoted maturity requires declared evidence")
			}
		}
		if ($null -ne $Record.PSObject.Properties['evidence'] -and $Record.evidence -is [array]) {
			foreach ($Evidence in $Record.evidence) {
				if (-not (Test-RegistryObject -Value $Evidence -Required @('source','revision','ownerIssue') -Optional @() -Errors $Errors -At "$At.evidence")) { continue }
				if ($Evidence.source -isnot [string] -or $Evidence.source -cnotmatch '^(docs/[a-z0-9-]+\.md|https://github\.com/ShayShimoni/aetheln-online/(issues|pull)/[1-9][0-9]*([#][a-zA-Z0-9-]+)?)$' -or $Evidence.revision -isnot [string] -or $Evidence.revision -cnotmatch '^[a-f0-9]{40}$' -or -not (Test-RegistryPositiveInteger $Evidence.ownerIssue)) {
					$Errors.Add("${At}: malformed evidence declaration")
				}
			}
		}
		if ($null -ne $Record.PSObject.Properties['work']) {
			if (Test-RegistryObject -Value $Record.work -Required @('listeners','procs','targets','constructs') -Optional @() -Errors $Errors -At "$At.work") {
				foreach ($Kind in @('listeners','procs','targets','constructs')) {
					if (-not (Test-RegistryNonnegativeInteger $Record.work.$Kind)) { $Errors.Add("${At}: work.$Kind must be a nonnegative integer") }
				}
			}
		}
		elseif ($Record.maturity -ceq 'Implementation Ready') { $Errors.Add("${At}: Implementation Ready requires explicit root work") }
		if ($Record.kind -cne 'manifest' -and $null -ne $Record.PSObject.Properties['composition']) { $Errors.Add("${At}: only a manifest may declare a composition") }
		if ($Record.kind -ceq 'manifest' -and $Record.emits -is [array] -and $Record.emits.Count -gt 0) { $Errors.Add("${At}: manifest emits are unsupported by composition aggregation") }
		if ($Record.kind -ceq 'manifest' -and $Record.maturity -ceq 'Implementation Ready' -and $null -eq $Record.PSObject.Properties['composition']) { $Errors.Add("${At}: ready manifest requires composition") }
		if ($Record.emits -is [array] -and $Record.emits.Count -gt 0) {
			if ($null -eq $Record.PSObject.Properties['work'] -or $Record.work.procs -lt $Record.emits.Count -or $Record.work.listeners -lt 1) {
				$Errors.Add("${At}: emitted procs require explicit root work for procs and listeners")
			}
		}
		foreach ($Writer in @($Record.writes)) {
			if (-not (Test-RegistryObject -Value $Writer -Required @('slot','owner') -Optional @() -Errors $Errors -At "$At.write")) { continue }
			if ($Writer.slot -isnot [string] -or $Writer.slot -cnotmatch $Schema.idPattern -or $Writer.owner -isnot [string] -or $Writer.owner -cnotmatch '^server\.[a-z][a-z0-9_]*$') {
				$Errors.Add("${At}: invalid authoritative writer claim")
				continue
			}
			if ($WriterBySlot.ContainsKey($Writer.slot) -and $WriterBySlot[$Writer.slot] -cne $Writer.owner) { $Errors.Add("${At}: conflicting exclusive writer for $($Writer.slot)") }
			else { $WriterBySlot[$Writer.slot] = $Writer.owner }
		}
	}
	foreach ($Id in $ApprovedPrototypeIds) {
		if (-not $ById.ContainsKey($Id) -or $ById[$Id].maturity -cne 'Prototype Candidate') { $Errors.Add("registry: approved Prototype Candidate $Id is missing or demoted") }
	}
	$BudgetByKind = @{}
	foreach ($Budget in $Registry.budgets) {
		if (-not (Test-RegistryObject -Value $Budget -Required @('kind','maxPerRoot','ownerIssue') -Optional @() -Errors $Errors -At 'budget')) { continue }
		if ($Schema.budgetKinds -cnotcontains $Budget.kind) { $Errors.Add("budget: unknown kind $($Budget.kind)"); continue }
		if ($BudgetByKind.ContainsKey($Budget.kind)) { $Errors.Add("budget: duplicate $($Budget.kind)"); continue }
		$BudgetByKind[$Budget.kind] = $Budget
		if (-not (Test-RegistryPositiveInteger $Budget.ownerIssue)) { $Errors.Add("budget $($Budget.kind): ownerIssue must be a positive integer") }
		if ($Budget.maxPerRoot -cne 'TBD' -and -not (Test-RegistryPositiveInteger $Budget.maxPerRoot)) { $Errors.Add("budget $($Budget.kind): limit must be a finite positive integer or TBD") }
	}
	foreach ($Kind in $Schema.budgetKinds) { if (-not $BudgetByKind.ContainsKey($Kind)) { $Errors.Add("budget: missing $Kind") } }
	if ($EdgesReady) {
		$Compositions = @()
		foreach ($Slot in $WriterBySlot.Keys) {
			if (-not $ById.ContainsKey($Slot)) { $Errors.Add("writer slot ${Slot}: missing definition") }
			elseif ($ById[$Slot].kind -cnotin @('resource','effect','construct')) { $Errors.Add("writer slot ${Slot}: incompatible definition kind") }
		}
		foreach ($Record in $ById.Values) {
			$At = "definition $($Record.id)"
			$Targets = @{}
			$ReferencedKinds = @()
			foreach ($Reference in $Record.references) {
				if (-not (Test-RegistryObject -Value $Reference -Required @('id','minVersion','maxVersion') -Optional @() -Errors $Errors -At "$At.reference")) { continue }
				if ($Reference.id -isnot [string] -or -not $ById.ContainsKey($Reference.id)) { $Errors.Add("${At}: missing reference $($Reference.id)"); continue }
				if ($Targets.ContainsKey($Reference.id)) { $Errors.Add("${At}: duplicate reference $($Reference.id)") }
				$Targets[$Reference.id] = $true
				$ReferencedKinds += $ById[$Reference.id].kind
				if (-not (Test-RegistryPositiveInteger $Reference.minVersion) -or -not (Test-RegistryPositiveInteger $Reference.maxVersion) -or $Reference.minVersion -gt $Reference.maxVersion -or $ById[$Reference.id].definitionVersion -lt $Reference.minVersion -or $ById[$Reference.id].definitionVersion -gt $Reference.maxVersion) {
					$Errors.Add("${At}: incompatible version of $($Reference.id)")
				}
				if ($ById[$Reference.id].maturity -ceq 'Superseded') { $Errors.Add("${At}: references superseded definition $($Reference.id)") }
			}
			if ($null -ne $Schema.requiredReferenceKinds.PSObject.Properties[$Record.kind] -and -not (@($Schema.requiredReferenceKinds.($Record.kind) | Where-Object { $ReferencedKinds -ccontains $_ }).Count -gt 0)) {
				$Errors.Add("${At}: missing required kind reference")
			}
			foreach ($Target in $Record.emits) {
				if ($Target -isnot [string] -or -not $ById.ContainsKey($Target)) { $Errors.Add("${At}: missing emitted definition $Target"); continue }
				if ($Targets.ContainsKey($Target)) { $Errors.Add("${At}: duplicate dependency $Target") }
				$Targets[$Target] = $true
				if ($ById[$Target].maturity -ceq 'Superseded') { $Errors.Add("${At}: emits superseded definition $Target") }
			}
			if ($Record.maturity -ceq 'Superseded' -and $null -ne $Record.PSObject.Properties['supersededBy']) {
				$Replacement = $Record.supersededBy
				if ($Replacement -isnot [string] -or -not $ById.ContainsKey($Replacement) -or $Replacement -ceq $Record.id) { $Errors.Add("${At}: invalid replacement reference") }
				elseif ($ById[$Replacement].kind -cne $Record.kind -or $ById[$Replacement].maturity -ceq 'Superseded') { $Errors.Add("${At}: replacement must be an active definition of the same kind") }
			}
			if ($Record.kind -ceq 'manifest' -and $null -ne $Record.PSObject.Properties['composition']) {
				$Composition = $Record.composition
				if (-not (Test-RegistryObject -Value $Composition -Required @('activationId','memberIds') -Optional @() -Errors $Errors -At "$At.composition")) { continue }
				if ($null -eq $Record.PSObject.Properties['work']) { $Errors.Add("${At}: composition requires explicit manifest work"); continue }
				if ($Composition.activationId -isnot [string] -or -not $ById.ContainsKey($Composition.activationId) -or $ById[$Composition.activationId].kind -cne 'ability') {
					$Errors.Add("${At}: composition requires an existing ability activation")
					continue
				}
				if (-not (Test-RegistryArray -Value $Composition.memberIds -Errors $Errors -At "$At.composition.memberIds")) { continue }
				$Members = @{}
				$Members[$Composition.activationId] = $true
				foreach ($MemberId in $Composition.memberIds) {
					if ($MemberId -isnot [string] -or -not $ById.ContainsKey($MemberId)) { $Errors.Add("${At}: composition member is missing"); continue }
					if ($Members.ContainsKey($MemberId)) { $Errors.Add("${At}: duplicate composition member $MemberId"); continue }
					$Members[$MemberId] = $true
					if ($ById[$MemberId].kind -cin @('manifest','preset')) { $Errors.Add("${At}: nested manifest or preset composition is unsupported") }
					if ($ById[$MemberId].kind -ceq 'thread' -and ($null -eq $ById[$MemberId].PSObject.Properties['work'] -or $ById[$MemberId].work.listeners -lt 1)) {
						$Errors.Add("${At}: attached Thread requires a declared listener evaluation")
					}
				}
				$DeclaredReferences = @($Record.references | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['id'] } | ForEach-Object { $_.id })
				if ($DeclaredReferences.Count -ne $Members.Count -or @($DeclaredReferences | Where-Object { -not $Members.ContainsKey($_) }).Count -gt 0) {
					$Errors.Add("${At}: composition and versioned references must name exactly the same participants")
				}
				if ($Record.maturity -ceq 'Implementation Ready') {
					foreach ($MemberId in $Members.Keys) {
						if ($ById[$MemberId].maturity -cne 'Implementation Ready') { $Errors.Add("${At}: ready composition contains a definition without Implementation Ready maturity") }
					}
				}
				$Compositions += $Record
			}
		}
		$Colors = @{}
		foreach ($Id in @($ById.Keys | Sort-Object)) { if ($Colors[$Id] -ne 2) { Test-RegistryCycle -Id $Id -ById $ById -Colors $Colors -Errors $Errors -Trail @() } }
	}
	if ($Errors.Count -eq 0) {
		$Cache = @{}
		foreach ($Record in $ById.Values) {
			if ($Record.maturity -ceq 'Implementation Ready' -and @($BudgetByKind.Values | Where-Object { $_.maxPerRoot -ceq 'TBD' }).Count -gt 0) {
				$Errors.Add("definition $($Record.id): Implementation Ready requires finite root budgets")
			}
			$Work = Get-RegistryRootWork -Id $Record.id -ById $ById -Cache $Cache
			foreach ($Kind in $Schema.budgetKinds) {
				$Limit = $BudgetByKind[$Kind].maxPerRoot
				if ($Limit -ceq 'TBD') {
					if ($Kind -ne 'depth' -and $Work[$Kind] -gt 0) { $Errors.Add("definition $($Record.id): active $Kind work has unresolved root budget") }
					if ($Kind -eq 'depth' -and $Record.emits.Count -gt 0) { $Errors.Add("definition $($Record.id): proc chain has unresolved depth budget") }
				}
				elseif ($Work[$Kind] -gt $Limit) { $Errors.Add("definition $($Record.id): aggregate $Kind work exceeds root budget") }
			}
		}
		$CoveredReadyIds = @{}
		foreach ($Manifest in $Compositions) {
			$RootWork = Get-RegistryRootWork -Id $Manifest.composition.activationId -ById $ById -Cache $Cache
			$Total = @{ depth = $RootWork.depth; listeners = [decimal]0; procs = [decimal]0; targets = [decimal]0; constructs = [decimal]0 }
			foreach ($Kind in @('listeners','procs','targets','constructs')) { $Total[$Kind] = $RootWork[$Kind] + [decimal]$Manifest.work.$Kind }
			foreach ($MemberId in $Manifest.composition.memberIds) {
				$MemberWork = Get-RegistryRootWork -Id $MemberId -ById $ById -Cache $Cache
				$Total.depth = [Math]::Max($Total.depth, ($RootWork.depth + $MemberWork.depth))
				foreach ($Kind in @('listeners','procs','targets','constructs')) { $Total[$Kind] += $MemberWork[$Kind] }
			}
			foreach ($Kind in $Schema.budgetKinds) {
				$Limit = $BudgetByKind[$Kind].maxPerRoot
				if ($Limit -ceq 'TBD') {
					if ($Kind -eq 'depth' -and $Manifest.composition.memberIds.Count -gt 0) { $Errors.Add("composition $($Manifest.id): unresolved depth budget") }
					elseif ($Kind -ne 'depth' -and $Total[$Kind] -gt 0) { $Errors.Add("composition $($Manifest.id): unresolved $Kind budget") }
				}
				elseif ($Total[$Kind] -gt $Limit) { $Errors.Add("composition $($Manifest.id): aggregate $Kind work exceeds root budget") }
			}
			if ($Manifest.maturity -ceq 'Implementation Ready') {
				$CoveredReadyIds[$Manifest.composition.activationId] = $true
				foreach ($MemberId in $Manifest.composition.memberIds) { $CoveredReadyIds[$MemberId] = $true }
			}
		}
		foreach ($Record in $ById.Values) {
			if ($Record.maturity -ceq 'Implementation Ready' -and $Record.kind -cin @('ability','form','thread','keystone','peak','effect','construct','visibility','recovery','preset') -and -not $CoveredReadyIds.ContainsKey($Record.id)) {
				$Errors.Add("definition $($Record.id): ready executable definition has no ready manifest composition")
			}
		}
	}
	return [pscustomobject]@{ passed = ($Errors.Count -eq 0); errors = @($Errors.ToArray()); definitionCount = $ById.Count }
}

if (-not $SkipMain) {
	$Result = Test-CombatRegistry -RegistryPath $RegistryPath -SchemaPath $SchemaPath
	if (-not $Result.passed) {
		$Result.errors | ForEach-Object { Write-Output "FAIL: $_" }
		exit 1
	}
	Write-Output "PASS: combat registry ($($Result.definitionCount) definitions)"
}
