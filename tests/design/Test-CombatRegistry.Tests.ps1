[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Validator = Join-Path $Root 'scripts/design/Test-CombatRegistry.ps1'
$SchemaPath = Join-Path $Root 'design/combat-registry/schema.json'
$RegistryPath = Join-Path $Root 'design/combat-registry/registry.json'
$FixturePath = Join-Path ([IO.Path]::GetTempPath()) ("AethelnCombatRegistry-{0}.json" -f [guid]::NewGuid().ToString('N'))
$SchemaFixturePath = Join-Path ([IO.Path]::GetTempPath()) ("AethelnCombatSchema-{0}.json" -f [guid]::NewGuid().ToString('N'))
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("AethelnCombatKinds-{0}" -f [guid]::NewGuid().ToString('N'))
. $Validator -SkipMain

function Copy-Fixture {
	return (Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-CompositionFixture {
	$Fixture = Copy-Fixture
	foreach ($Budget in $Fixture.budgets) { $Budget.maxPerRoot = 4 }
	$FixtureEvidence = @([pscustomobject]@{source='docs/game-design-bible.md';revision=('b' * 40);ownerIssue=106})
	$Fixture.definitions += [pscustomobject]@{id='fixture.ability.root';kind='ability';definitionVersion=1;maturity='Implementation Ready';displayName='Fixture root';summary='Synthetic root for composition coverage.';source='docs/game-design-bible.md';sourceAnchor='#shared-combat-grammar';ownerIssue=106;references=@();emits=@();writes=@();evidence=$FixtureEvidence;work=[pscustomobject]@{listeners=0;procs=0;targets=0;constructs=0}}
	foreach ($Suffix in @('one','two')) {
		$Fixture.definitions += [pscustomobject]@{id="fixture.thread.$Suffix";kind='thread';definitionVersion=1;maturity='Implementation Ready';displayName="Fixture Thread $Suffix";summary='Synthetic listener for composition coverage.';source='docs/game-design-bible.md';sourceAnchor='#shared-combat-grammar';ownerIssue=106;references=@([pscustomobject]@{id='fixture.ability.root';minVersion=1;maxVersion=1});emits=@();writes=@();evidence=$FixtureEvidence;work=[pscustomobject]@{listeners=2;procs=1;targets=1;constructs=1}}
	}
	$Fixture.definitions += [pscustomobject]@{id='fixture.manifest.two_listeners';kind='manifest';definitionVersion=1;maturity='Implementation Ready';displayName='Fixture manifest';summary='Synthetic root with two attached listeners.';source='docs/game-design-bible.md';sourceAnchor='#shared-combat-grammar';ownerIssue=106;references=@([pscustomobject]@{id='fixture.ability.root';minVersion=1;maxVersion=1},[pscustomobject]@{id='fixture.thread.one';minVersion=1;maxVersion=1},[pscustomobject]@{id='fixture.thread.two';minVersion=1;maxVersion=1});emits=@();writes=@();evidence=$FixtureEvidence;work=[pscustomobject]@{listeners=0;procs=0;targets=0;constructs=0};composition=[pscustomobject]@{activationId='fixture.ability.root';memberIds=@('fixture.thread.one','fixture.thread.two')}}
	return $Fixture
}

function Invoke-Fixture {
	param($Fixture, [string] $UseSchemaPath = $SchemaPath)
	[IO.File]::WriteAllText($FixturePath, ($Fixture | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
	return Test-CombatRegistry -RegistryPath $FixturePath -SchemaPath $UseSchemaPath
}

function Assert-Valid {
	param([string] $Name, $Fixture, [string] $UseSchemaPath = $SchemaPath)
	$Result = Invoke-Fixture -Fixture $Fixture -UseSchemaPath $UseSchemaPath
	if (-not $Result.passed) { throw "Expected valid ${Name}: $($Result.errors -join '; ')" }
	Write-Output "PASS: $Name"
}

function Assert-Invalid {
	param([string] $Name, $Fixture, [string] $Reason, [string] $UseSchemaPath = $SchemaPath)
	$Result = Invoke-Fixture -Fixture $Fixture -UseSchemaPath $UseSchemaPath
	if ($Result.passed -or -not (@($Result.errors) -match $Reason)) { throw "Expected $Name to fail with '$Reason'; actual: $($Result.errors -join '; ')" }
	Write-Output "PASS: rejected $Name"
}

function Assert-InvalidRawJson {
	param([string] $Name, [string] $RawJson, [string] $DocumentName, [string] $Reason)
	$Path = if ($DocumentName -eq 'schema') { $SchemaFixturePath } else { $FixturePath }
	[IO.File]::WriteAllText($Path, $RawJson, (New-Object System.Text.UTF8Encoding($false)))
	$RegistryToTest = if ($DocumentName -eq 'schema') { $RegistryPath } else { $FixturePath }
	$SchemaToTest = if ($DocumentName -eq 'schema') { $SchemaFixturePath } else { $SchemaPath }
	$Result = Test-CombatRegistry -RegistryPath $RegistryToTest -SchemaPath $SchemaToTest
	if ($Result.passed -or -not (@($Result.errors) -match $Reason)) { throw "Expected $Name to fail with '$Reason'; actual: $($Result.errors -join '; ')" }
	Write-Output "PASS: rejected $Name"
}

try {
	Assert-Valid -Name 'canonical seed corpus' -Fixture (Copy-Fixture)
	$Schema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
	$AllKinds = Copy-Fixture
	foreach ($Kind in $Schema.kinds) {
		$KindReferences = @()
		if ($Kind -in @('specialization','weapon','peak')) { $KindReferences = @([pscustomobject]@{id='order.oathscar';minVersion=1;maxVersion=1}) }
		elseif ($Kind -in @('form','thread')) { $KindReferences = @([pscustomobject]@{id='order.oathscar.ability.gate_step';minVersion=1;maxVersion=1}) }
		elseif ($Kind -eq 'keystone') { $KindReferences = @([pscustomobject]@{id='combat.resource.guard';minVersion=1;maxVersion=1}) }
		$AllKinds.definitions += [pscustomobject]@{
			id = "fixture.kind.$($Kind.ToLowerInvariant())"; kind = $Kind; definitionVersion = 1
			maturity = 'Canonical Intent'; displayName = "Fixture $Kind"; summary = 'Synthetic kind coverage.'; source = 'docs/game-design-bible.md'; sourceAnchor = '#shared-combat-grammar'
			ownerIssue = 106; references = $KindReferences; emits = @(); writes = @()
		}
	}
	$FixtureSchemaDirectory = Join-Path $FixtureRoot 'design/combat-registry'
	$FixtureDocsDirectory = Join-Path $FixtureRoot 'docs'
	New-Item -ItemType Directory -Path $FixtureSchemaDirectory -Force | Out-Null
	New-Item -ItemType Directory -Path $FixtureDocsDirectory -Force | Out-Null
	$KindsSchemaPath = Join-Path $FixtureSchemaDirectory 'schema.json'
	Copy-Item -LiteralPath $SchemaPath -Destination $KindsSchemaPath
	Copy-Item -LiteralPath (Join-Path $Root 'docs/characters-and-factions.md') -Destination (Join-Path $FixtureDocsDirectory 'characters-and-factions.md')
	$GameBible = Get-Content -LiteralPath (Join-Path $Root 'docs/game-design-bible.md') -Raw -Encoding UTF8
	$SyntheticIds = @($AllKinds.definitions | Where-Object { $_.id -like 'fixture.kind.*' } | ForEach-Object { $_.id }) + @('fixture.ability.root','fixture.thread.one','fixture.thread.two','fixture.manifest.two_listeners')
	$KindsBlock = "### Shared Combat Grammar`n" + ($SyntheticIds -join "`n")
	$GameBible = $GameBible.Replace('### Shared Combat Grammar', $KindsBlock)
	[IO.File]::WriteAllText((Join-Path $FixtureDocsDirectory 'game-design-bible.md'), $GameBible, (New-Object System.Text.UTF8Encoding($false)))
	Assert-Valid -Name 'every supported definition kind' -Fixture $AllKinds -UseSchemaPath $KindsSchemaPath

	$Maturities = Copy-Fixture
	foreach ($Budget in $Maturities.budgets) { $Budget.maxPerRoot = 16 }
	$Evidence = @([pscustomobject]@{source='docs/game-design-bible.md';revision=('a' * 40);ownerIssue=106})
	$Maturities.definitions[6].maturity = 'Evidence Validated'; $Maturities.definitions[6] | Add-Member -NotePropertyName evidence -NotePropertyValue $Evidence
	$Maturities.definitions[3].maturity = 'Implementation Ready'; $Maturities.definitions[3] | Add-Member -NotePropertyName evidence -NotePropertyValue $Evidence; $Maturities.definitions[3] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=0;procs=0;targets=0;constructs=0})
	$Maturities.definitions[7].maturity = 'Superseded'; $Maturities.definitions[7] | Add-Member -NotePropertyName supersededBy -NotePropertyValue 'combat.damage.wrought'
	Assert-Valid -Name 'all five design maturities' -Fixture $Maturities

	$Fixture = Copy-Fixture; $Fixture.definitions += $Fixture.definitions[0]
	Assert-Invalid -Name 'duplicate IDs' -Fixture $Fixture -Reason 'duplicate stable ID'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].id = 'Bad.ID'
	Assert-Invalid -Name 'unstable ID syntax' -Fixture $Fixture -Reason 'invalid stable ID'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].displayName = "Health`nUnsafe"
	Assert-Invalid -Name 'multiline display name' -Fixture $Fixture -Reason 'displayName must be bounded single-line plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].displayName = 'Health | injected column'
	Assert-Invalid -Name 'Markdown table injection in display name' -Fixture $Fixture -Reason 'displayName must be bounded single-line plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].displayName = '<script>unsafe</script>'
	Assert-Invalid -Name 'HTML injection in display name' -Fixture $Fixture -Reason 'displayName must be bounded single-line plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].displayName = ('x' * 121)
	Assert-Invalid -Name 'oversized display name' -Fixture $Fixture -Reason 'displayName must be bounded single-line plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].summary = "Line one`nLine two"
	Assert-Invalid -Name 'multiline summary' -Fixture $Fixture -Reason 'summary must be bounded plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].summary = ('a' * 241)
	Assert-Invalid -Name 'oversized summary' -Fixture $Fixture -Reason 'summary must be bounded plain text'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].sourceAnchor = '#missing-heading'
	Assert-Invalid -Name 'missing source anchor' -Fixture $Fixture -Reason 'canonical source anchor is missing'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].sourceAnchor = '#combat'
	Assert-Invalid -Name 'real but broader false provenance anchor' -Fixture $Fixture -Reason 'canonical source section does not contain stable ID'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].sourceAnchor = '#world-structure'
	Assert-Invalid -Name 'real unrelated false provenance anchor' -Fixture $Fixture -Reason 'canonical source section does not contain stable ID'
	$Fixture = Copy-Fixture; $Fixture.definitions[8].sourceAnchor = '#canonical-intent'
	Assert-Invalid -Name 'longer child IDs cannot prove parent Order ID' -Fixture $Fixture -Reason 'canonical source section does not contain stable ID'
	$TempGameBiblePath = Join-Path $FixtureDocsDirectory 'game-design-bible.md'
	$TempGameBible = Get-Content -LiteralPath $TempGameBiblePath -Raw -Encoding UTF8
	$TempGameBible = $TempGameBible.Replace('## World Structure', "## World Structure`n~~~`ncombat.resource.health`n~~~")
	[IO.File]::WriteAllText($TempGameBiblePath, $TempGameBible, (New-Object System.Text.UTF8Encoding($false)))
	$Fixture = Copy-Fixture; $Fixture.definitions[0].sourceAnchor = '#world-structure'
	Assert-Invalid -Name 'ID hidden in fenced example is not canonical provenance' -Fixture $Fixture -Reason 'canonical source section does not contain stable ID' -UseSchemaPath $KindsSchemaPath
	$TempGameBible = (Get-Content -LiteralPath $TempGameBiblePath -Raw -Encoding UTF8).Replace('## Design Pillars', "## Design Pillars`n<!-- combat.resource.health -->")
	[IO.File]::WriteAllText($TempGameBiblePath, $TempGameBible, (New-Object System.Text.UTF8Encoding($false)))
	$Fixture = Copy-Fixture; $Fixture.definitions[0].sourceAnchor = '#design-pillars'
	Assert-Invalid -Name 'ID hidden in HTML comment is not canonical provenance' -Fixture $Fixture -Reason 'canonical source section does not contain stable ID' -UseSchemaPath $KindsSchemaPath
	$Fixture = Copy-Fixture; $Fixture.definitions[0].kind = 'unknown'
	Assert-Invalid -Name 'unknown kind' -Fixture $Fixture -Reason 'unknown definition kind'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].maturity = 'Accepted'
	Assert-Invalid -Name 'ADR status used as design maturity' -Fixture $Fixture -Reason 'unknown design maturity'
	$Fixture = Copy-Fixture; $Fixture.definitions[8].maturity = 'Prototype Candidate'
	Assert-Invalid -Name 'unapproved prototype promotion' -Fixture $Fixture -Reason 'outside the approved prototype subset'
	$Fixture = Copy-Fixture; $Fixture.definitions[0].maturity = 'Canonical Intent'
	Assert-Invalid -Name 'approved prototype demotion' -Fixture $Fixture -Reason 'approved Prototype Candidate combat.resource.health is missing or demoted'
	$Fixture = Copy-Fixture; $Fixture.definitions = @($Fixture.definitions | Where-Object { $_.id -ne 'combat.resource.health' })
	Assert-Invalid -Name 'approved prototype record omitted' -Fixture $Fixture -Reason 'approved Prototype Candidate combat.resource.health is missing or demoted'
	$ExpandedSchema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
	$ExpandedSchema.prototypeCandidateIds += 'order.oathscar'
	[IO.File]::WriteAllText($SchemaFixturePath, ($ExpandedSchema | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
	$Fixture = Copy-Fixture; $Fixture.definitions[8].maturity = 'Prototype Candidate'
	Assert-Invalid -Name 'schema-expanded prototype promotion' -Fixture $Fixture -Reason 'prototype allowlist differs from the approved nine IDs' -UseSchemaPath $SchemaFixturePath
	$ExpandedSchema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
	$ExpandedSchema.referenceKindPolicy = 'all-of'
	[IO.File]::WriteAllText($SchemaFixturePath, ($ExpandedSchema | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
	Assert-Invalid -Name 'schema changes any-of to all-of' -Fixture (Copy-Fixture) -Reason 'unsupported reference or execution policy' -UseSchemaPath $SchemaFixturePath
	$ExpandedSchema.referenceKindPolicy = 'any-of'; $ExpandedSchema.executionPolicy = 'record-permissive'
	[IO.File]::WriteAllText($SchemaFixturePath, ($ExpandedSchema | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
	Assert-Invalid -Name 'schema bypasses manifest-only execution' -Fixture (Copy-Fixture) -Reason 'unsupported reference or execution policy' -UseSchemaPath $SchemaFixturePath
	$RawSchema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8
	Assert-InvalidRawJson -Name 'case-colliding schema property' -RawJson ($RawSchema.Replace('"schemaVersion": 1,', '"schemaVersion": 1, "SchemaVersion": 1,')) -DocumentName 'schema' -Reason 'duplicate JSON object property'
	Assert-InvalidRawJson -Name 'escaped duplicate schema property' -RawJson ($RawSchema.Replace('"schemaVersion": 1,', '"schemaVersion": 1, "schema\u0056ersion": 1,')) -DocumentName 'schema' -Reason 'duplicate JSON object property'
	$RawRegistry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8
	Assert-InvalidRawJson -Name 'nested case-colliding registry property' -RawJson ($RawRegistry.Replace('"ownerIssue": 19, "references"', '"ownerIssue": 19, "OwnerIssue": 19, "references"')) -DocumentName 'registry' -Reason 'duplicate JSON object property'
	$Fixture = Copy-Fixture; $Fixture.definitions[5].maturity = 'Evidence Validated'
	Assert-Invalid -Name 'promotion without evidence' -Fixture $Fixture -Reason 'promoted maturity requires declared evidence'
	$Fixture = Copy-Fixture; $Fixture.definitions[5].maturity = 'Evidence Validated'; $Fixture.definitions[5] | Add-Member -NotePropertyName evidence -NotePropertyValue @([pscustomobject]@{source='docs/game-design-bible.md';revision='not-a-revision';ownerIssue=106})
	Assert-Invalid -Name 'malformed promotion evidence' -Fixture $Fixture -Reason 'malformed evidence declaration'
	$Fixture = Copy-Fixture; $Fixture.definitions[9].references[0].id = 'missing.definition'
	Assert-Invalid -Name 'missing reference' -Fixture $Fixture -Reason 'missing reference'
	$Fixture = Copy-Fixture; $Fixture.definitions[9].references = @([pscustomobject]@{unexpected='shape'})
	Assert-Invalid -Name 'malformed reference edge' -Fixture $Fixture -Reason 'missing id'
	$Fixture = Copy-Fixture; $Fixture.definitions[9].references[0].minVersion = 2
	Assert-Invalid -Name 'incompatible definition version' -Fixture $Fixture -Reason 'incompatible version'
	$Fixture = Copy-Fixture; $Fixture.definitions[9].references = @()
	Assert-Invalid -Name 'specialization without Order reference' -Fixture $Fixture -Reason 'missing required kind reference'
	$Fixture = Copy-Fixture; $Fixture.definitions[21].references = @()
	Assert-Invalid -Name 'Form without ability reference' -Fixture $Fixture -Reason 'missing required kind reference'
	$Fixture = Copy-Fixture; $Fixture.definitions[28].references[0].id = 'combat.damage.wrought'
	Assert-Invalid -Name 'Keystone without any accepted reference kind' -Fixture $Fixture -Reason 'missing required kind reference'
	Assert-Valid -Name 'Keystone any-of accepts one resource reference' -Fixture $AllKinds -UseSchemaPath $KindsSchemaPath
	$Fixture = Copy-Fixture; $Fixture.definitions[8].references += [pscustomobject]@{id='order.oathscar.spec.ironwake';minVersion=1;maxVersion=1}
	Assert-Invalid -Name 'reference cycle' -Fixture $Fixture -Reason 'cycle:'
	$Fixture = Copy-Fixture; $Fixture.definitions[8].writes += [pscustomobject]@{slot='combat.resource.health';owner='server.other'}
	Assert-Invalid -Name 'conflicting exclusive writer' -Fixture $Fixture -Reason 'conflicting exclusive writer'
	$Fixture = Copy-Fixture; $Fixture.definitions[8].writes += [pscustomobject]@{slot='combat.resource.missing';owner='server.gamecombat'}
	Assert-Invalid -Name 'writer slot without definition' -Fixture $Fixture -Reason 'writer slot combat.resource.missing: missing definition'
	$Fixture = Copy-Fixture; $Fixture.definitions[8].writes += [pscustomobject]@{slot='combat.damage.wrought';owner='server.gamecombat'}
	Assert-Invalid -Name 'writer slot wrong kind' -Fixture $Fixture -Reason 'incompatible definition kind'
	$Fixture = Copy-Fixture; $Fixture.budgets = @($Fixture.budgets | Where-Object { $_.kind -ne 'targets' })
	Assert-Invalid -Name 'missing root budget' -Fixture $Fixture -Reason 'missing targets'
	$Fixture = Copy-Fixture; $Fixture.budgets[0].maxPerRoot = 0
	Assert-Invalid -Name 'zero root budget' -Fixture $Fixture -Reason 'limit must be a finite positive integer'
	$Fixture = Copy-Fixture; $Fixture.definitions[3].maturity = 'Implementation Ready'; $Fixture.definitions[3] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=0;procs=0;targets=0;constructs=0}); $Fixture.definitions[3] | Add-Member -NotePropertyName evidence -NotePropertyValue $Evidence
	Assert-Invalid -Name 'ready with unresolved root budgets' -Fixture $Fixture -Reason 'requires finite root budgets'
	foreach ($Kind in @('listeners','procs','targets','constructs')) {
		$Fixture = Copy-Fixture
		$Fixture.definitions[8] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=0;procs=0;targets=0;constructs=0})
		$Fixture.definitions[8].work.$Kind = 1
		Assert-Invalid -Name "unresolved active $Kind" -Fixture $Fixture -Reason "active $Kind work has unresolved root budget"
	}
	$Fixture = Copy-Fixture
	foreach ($Budget in $Fixture.budgets) { $Budget.maxPerRoot = 1 }
	$Fixture.definitions[8] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=2;procs=0;targets=0;constructs=0})
	Assert-Invalid -Name 'finite listener overflow' -Fixture $Fixture -Reason 'aggregate listeners work exceeds root budget'
	$Fixture = Copy-Fixture
	foreach ($Budget in $Fixture.budgets) { $Budget.maxPerRoot = 2 }
	$Fixture.definitions[9] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=1;procs=1;targets=0;constructs=0})
	$Fixture.definitions[9].emits += 'order.oathscar.ability.gate_step'
	$Fixture.definitions[18] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=2;procs=0;targets=0;constructs=0})
	Assert-Invalid -Name 'aggregate descendant fan-out' -Fixture $Fixture -Reason 'aggregate listeners work exceeds root budget'
	$Fixture = Copy-Fixture
	foreach ($Budget in $Fixture.budgets) { $Budget.maxPerRoot = 4 }
	$Fixture.definitions[9] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=1;procs=1;targets=0;constructs=0})
	$Fixture.definitions[9].emits += 'order.oathscar.ability.gate_step'
	$Fixture.definitions[18] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=0;procs=0;targets=1;constructs=0})
	Assert-Valid -Name 'finite acyclic proc work' -Fixture $Fixture
	$Fixture.definitions[18].emits += 'order.oathscar.spec.ironwake'
	$Fixture.definitions[18].work.listeners = 1; $Fixture.definitions[18].work.procs = 1
	Assert-Invalid -Name 'proc cycle' -Fixture $Fixture -Reason 'cycle:'
	$Fixture = Copy-Fixture
	foreach ($Budget in $Fixture.budgets) { $Budget.maxPerRoot = [long]::MaxValue }
	$Fixture.definitions[9] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=1;procs=1;targets=[long]::MaxValue;constructs=0})
	$Fixture.definitions[9].emits += 'order.oathscar.ability.gate_step'
	$Fixture.definitions[18] | Add-Member -NotePropertyName work -NotePropertyValue ([pscustomobject]@{listeners=0;procs=0;targets=[long]::MaxValue;constructs=0})
	Assert-Invalid -Name 'wide integer aggregate overflow' -Fixture $Fixture -Reason 'aggregate targets work exceeds root budget'
	$CompositionFixture = Get-CompositionFixture
	Assert-Valid -Name 'two-listener composition within aggregate limits' -Fixture $CompositionFixture -UseSchemaPath $KindsSchemaPath
	foreach ($Kind in @('listeners','procs','targets','constructs','depth')) {
		$Fixture = Get-CompositionFixture
		($Fixture.budgets | Where-Object { $_.kind -eq $Kind }).maxPerRoot = if ($Kind -eq 'listeners') { 3 } else { 1 }
		Assert-Invalid -Name "combined two-listener $Kind overflow" -Fixture $Fixture -Reason "composition fixture.manifest.two_listeners: aggregate $Kind work exceeds root budget" -UseSchemaPath $KindsSchemaPath
	}
	$Fixture = Get-CompositionFixture
	$Fixture.definitions = @($Fixture.definitions | Where-Object { $_.id -ne 'fixture.manifest.two_listeners' })
	Assert-Invalid -Name 'ready listeners without an executable manifest' -Fixture $Fixture -Reason 'ready executable definition has no ready manifest composition' -UseSchemaPath $KindsSchemaPath
	$Fixture = Get-CompositionFixture
	$Fixture.definitions[-1].composition.memberIds = @('fixture.thread.one')
	Assert-Invalid -Name 'manifest omits one declared listener' -Fixture $Fixture -Reason 'composition and versioned references must name exactly the same participants' -UseSchemaPath $KindsSchemaPath
	$Fixture = Get-CompositionFixture
	[void]$Fixture.definitions[-1].PSObject.Properties.Remove('composition')
	Assert-Invalid -Name 'ready manifest without a composition' -Fixture $Fixture -Reason 'ready manifest requires composition' -UseSchemaPath $KindsSchemaPath
	$Fixture = Get-CompositionFixture
	$Fixture.definitions[-1].composition.memberIds = @('fixture.thread.one','fixture.thread.one')
	Assert-Invalid -Name 'duplicate composition listener' -Fixture $Fixture -Reason 'duplicate composition member' -UseSchemaPath $KindsSchemaPath
	$Fixture = Get-CompositionFixture
	$Fixture.definitions[-4] | Add-Member -NotePropertyName composition -NotePropertyValue ([pscustomobject]@{activationId='fixture.ability.root';memberIds=@()})
	Assert-Invalid -Name 'nonmanifest composition declaration' -Fixture $Fixture -Reason 'only a manifest may declare a composition' -UseSchemaPath $KindsSchemaPath
	$Fixture = Get-CompositionFixture
	$Fixture.definitions[-1].emits += 'combat.resource.health'
	$Fixture.definitions[-1].work.listeners = 1; $Fixture.definitions[-1].work.procs = 1
	Assert-Invalid -Name 'manifest-emitted work cannot bypass aggregate bounds' -Fixture $Fixture -Reason 'manifest emits are unsupported by composition aggregation' -UseSchemaPath $KindsSchemaPath
	$Fixture = Copy-Fixture
	$Fixture.definitions[8].maturity = 'Superseded'; $Fixture.definitions[8] | Add-Member -NotePropertyName supersededBy -NotePropertyValue 'missing.replacement'
	Assert-Invalid -Name 'missing superseding definition' -Fixture $Fixture -Reason 'invalid replacement reference'
	$Fixture = Copy-Fixture
	$Fixture.definitions[12].maturity = 'Superseded'; $Fixture.definitions[12] | Add-Member -NotePropertyName supersededBy -NotePropertyValue 'order.oathscar.weapon.greatsword'
	Assert-Invalid -Name 'active reference to superseded definition' -Fixture $Fixture -Reason 'references superseded definition'
	$Fixture = Copy-Fixture; $Fixture.schemaVersion = 2
	Assert-Invalid -Name 'incompatible registry version' -Fixture $Fixture -Reason 'incompatible schema identity or version'
	$Fixture = Copy-Fixture; $Fixture.schemaVersion = '1'
	Assert-Invalid -Name 'string registry version' -Fixture $Fixture -Reason 'incompatible schema identity or version'
	$Fixture = Copy-Fixture; $Fixture.definitions[0] | Add-Member -NotePropertyName accidental -NotePropertyValue 'drift'
	Assert-Invalid -Name 'unknown definition property' -Fixture $Fixture -Reason 'unexpected accidental'
}
finally {
	if (Test-Path -LiteralPath $FixturePath) { Remove-Item -LiteralPath $FixturePath -Force }
	if (Test-Path -LiteralPath $SchemaFixturePath) { Remove-Item -LiteralPath $SchemaFixturePath -Force }
	if (Test-Path -LiteralPath $FixtureRoot) {
		$ResolvedFixtureRoot = (Resolve-Path -LiteralPath $FixtureRoot).Path
		$ResolvedTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
		if (-not $ResolvedFixtureRoot.StartsWith($ResolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup target escaped the temporary directory.' }
		Remove-Item -LiteralPath $ResolvedFixtureRoot -Recurse -Force
	}
}
