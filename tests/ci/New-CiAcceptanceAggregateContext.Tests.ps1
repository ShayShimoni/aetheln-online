$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ScriptPath = Join-Path $RepositoryRoot 'scripts\ci\New-CiAcceptanceAggregateContext.ps1'
. $ScriptPath

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	try { & $Action; throw "Expected rejection '$Reason'." }
	catch {
		if ($_.Exception.Message -ceq "Expected rejection '$Reason'." -or $_.Exception.Message -cnotmatch ('^' + [regex]::Escape($Reason) + '(?::|$)')) { throw }
	}
}

$script:ContextUtf8 = New-Object Text.UTF8Encoding($false)
$script:CheckIds = @('portable','visual-package','native-client-server-compile','unreal-editor-automation','content-reference-validation','controller-contract','controller-operational-proof','clean-package-provenance-smoke')
$script:Nonce = '6' * 64
$RepositoryTemplate = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\ci-acceptance-requirements.json') -Raw | ConvertFrom-Json
$RepositoryCheckIds = @($RepositoryTemplate.jobs | ForEach-Object { $_.checks } | ForEach-Object { $_ })
Assert-True ($RepositoryCheckIds.Count -eq 8 -and $RepositoryCheckIds -cnotcontains 'delivery-harness' -and (@($script:CheckIds | Where-Object { $RepositoryCheckIds -cnotcontains $_ }).Count -eq 0)) 'Live requirements template must cover exactly the eight supported selector IDs without the retired harness.'

function Write-FixtureJson([string] $Path, $Value) {
	[IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 16 -Compress) + "`n"), $script:ContextUtf8)
}

function New-SelectorFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory selector fixture without changing external state.')]
	param([string[]] $Selected = @('portable','native-client-server-compile','visual-package'))
	$SelectedSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Id in $Selected) { [void] $SelectedSet.Add($Id) }
	return [pscustomobject][ordered]@{
		schemaVersion='aetheln.ci-selection/v1'
		attemptAnchor=[pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v1';runId='9001';runAttempt=2;nonce=$script:Nonce}
		policy=[pscustomobject][ordered]@{version='shadow-v1';digest=('1'*64);checkIds=@($script:CheckIds)}
		source=[pscustomobject][ordered]@{kind='pull_request';callerKind=$null;baseRevision=('a'*40);headRevision=('b'*40);workflowRevision=('c'*40);revision=$null}
		execution=[pscustomobject][ordered]@{mode='accepted-base';controllerRevision=('a'*40);controllerBlobOid=('d'*40);controllerSha256=('e'*64);checkoutAllowed=$false;complete=$true;reason='classified'}
		classification=[pscustomobject][ordered]@{changedPaths=@('Source/Foo.cpp');entries=@();uncertainties=@()}
		selection=[pscustomobject][ordered]@{shadow=$true;authoritative=$false;obligations=@($script:CheckIds | ForEach-Object {[pscustomobject][ordered]@{id=$_;selected=$SelectedSet.Contains($_);reasons=@(if($SelectedSet.Contains($_)){'fixture'})}})}
		legacyAuthority=[pscustomobject][ordered]@{authoritative=$true;engineRequired=$true;reason='legacy_authority'}
		comparison=[pscustomobject][ordered]@{status='match';differences=@()}
	}
}

function Get-UnavailableSelectorFixture {
	$Report = New-SelectorFixture -Selected $script:CheckIds
	$Report.policy.digest = '0' * 64
	$Report.execution = [pscustomobject][ordered]@{mode='accepted_controller_unavailable';controllerRevision=('a'*40);controllerBlobOid=$null;controllerSha256=$null;checkoutAllowed=$false;complete=$true;reason='accepted_controller_unavailable'}
	$Report.classification = [pscustomobject][ordered]@{changedPaths=@();entries=@();uncertainties=@('accepted_controller_unavailable')}
	$Report.selection.obligations = @($script:CheckIds | ForEach-Object { [pscustomobject][ordered]@{id=$_;selected=$true;reasons=@('accepted_controller_unavailable')} })
	$Report.legacyAuthority = [pscustomobject][ordered]@{authoritative=$true;engineRequired=$null;reason='not_observed'}
	$Report.comparison = [pscustomobject][ordered]@{status='unavailable';differences=@('accepted_controller_unavailable')}
	return $Report
}

function New-RequirementsTemplateFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory requirements-template fixture without changing external state.')]
	param()
	return [pscustomobject][ordered]@{
		schemaVersion='aetheln.ci-acceptance-requirements-template/v1'
		jobs=@(
			[pscustomobject][ordered]@{key='native';jobName='native-receipt-shadow';checks=@('clean-package-provenance-smoke','controller-operational-proof','native-client-server-compile')},
			[pscustomobject][ordered]@{key='portable';jobName='portable-receipt-shadow';checks=@('content-reference-validation','controller-contract','portable')},
			[pscustomobject][ordered]@{key='unreal';jobName='unreal-receipt-shadow';checks=@('unreal-editor-automation')},
			[pscustomobject][ordered]@{key='visual';jobName='visual-receipt-shadow';checks=@('visual-package')}
		)
	}
}
# The fixture is the live template, so every aggregate case below exercises the real producer job map.
Assert-True (((New-RequirementsTemplateFixture) | ConvertTo-Json -Depth 8 -Compress) -ceq ($RepositoryTemplate | ConvertTo-Json -Depth 8 -Compress)) 'The requirements-template fixture must match the live template exactly.'

function Get-ActionItemsJson {
	return (@(
		[pscustomobject][ordered]@{uses='actions/checkout';revision=('2'*40)},
		[pscustomobject][ordered]@{uses='actions/download-artifact';revision=('3'*40)},
		[pscustomobject][ordered]@{uses='actions/upload-artifact';revision=('4'*40)}
	) | ConvertTo-Json -Depth 4 -Compress)
}

function Get-SelectorBindingJson {
	return ([pscustomobject][ordered]@{jobName='ci-selection-shadow';artifactId='1001';artifactName=('ci-selection-shadow-9001-2-'+$script:Nonce);digest=('sha256:'+('7'*64))} | ConvertTo-Json -Compress)
}

function Get-ProducerBindingsJson {
	return (@(
		[pscustomobject][ordered]@{key='native';jobName='native-receipt-shadow';artifactId='2001';artifactName=('ci-receipt-native-9001-2-'+$script:Nonce);digest=('sha256:'+('8'*64))},
		[pscustomobject][ordered]@{key='portable';jobName='portable-receipt-shadow';artifactId='2002';artifactName=('ci-receipt-portable-9001-2-'+$script:Nonce);digest=('sha256:'+('9'*64))},
		[pscustomobject][ordered]@{key='visual';jobName='visual-receipt-shadow';artifactId='2003';artifactName=('ci-receipt-visual-9001-2-'+$script:Nonce);digest=('sha256:'+('a'*64))}
	) | ConvertTo-Json -Depth 4 -Compress)
}

function New-InvocationFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only a uniquely named disposable test fixture under the process temporary directory.')]
	param()
	$Root = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-aggregate-context-' + [guid]::NewGuid().ToString('N'))
	[void] (New-Item -ItemType Directory -Path $Root)
	$SelectorPath = Join-Path $Root 'selector.json'
	$WorkflowPath = Join-Path $Root 'workflow.yml'
	$TemplatePath = Join-Path $Root 'requirements-template.json'
	Write-FixtureJson $SelectorPath (New-SelectorFixture)
	[IO.File]::WriteAllText($WorkflowPath, "name: fixture`n", $script:ContextUtf8)
	Write-FixtureJson $TemplatePath (New-RequirementsTemplateFixture)
	return [pscustomobject]@{
		Root=$Root;SelectorPath=$SelectorPath;WorkflowPath=$WorkflowPath;TemplatePath=$TemplatePath
		IdentityPath=(Join-Path $Root 'identity.json');AggregatePath=(Join-Path $Root 'aggregate.json');RequirementsPath=(Join-Path $Root 'requirements.json')
	}
}

function Invoke-Fixture {
	param($Fixture,[ValidateSet('Identity','Aggregate','Gap')][string]$Mode='Aggregate',[string]$ActionItemsJson=(Get-ActionItemsJson),[string]$SelectorBindingJson=(Get-SelectorBindingJson),[string]$ProducerBindingsJson=(Get-ProducerBindingsJson))
	$Arguments = @{
		Mode=$Mode;SelectorReportPath=$Fixture.SelectorPath;WorkflowPath=$Fixture.WorkflowPath
		Repository='ShayShimoni/aetheln-online';Actor='owner';TriggeringActor='owner'
		BaseRevision=('a'*40);HeadRevision=('b'*40);TestedRevision=('c'*40);WorkflowId='9876543';RunId='9001';RunAttempt=2
		ActionItemsJson=$ActionItemsJson;IdentityContextOutputPath=$Fixture.IdentityPath
	}
	if ($Mode -ceq 'Aggregate') {
		$Arguments.RequirementsTemplatePath=$Fixture.TemplatePath;$Arguments.SelectorBindingJson=$SelectorBindingJson;$Arguments.ProducerBindingsJson=$ProducerBindingsJson
		$Arguments.AggregateContextOutputPath=$Fixture.AggregatePath;$Arguments.RuntimeRequirementsOutputPath=$Fixture.RequirementsPath
	}
	if ($Mode -ceq 'Gap') { return Invoke-CiAcceptanceAggregateContextMain @Arguments }
	Invoke-CiAcceptanceAggregateContextMain @Arguments | Out-Null
}

$Fixture = New-InvocationFixture
try {
	Invoke-Fixture $Fixture
	$IdentityBytes = [IO.File]::ReadAllBytes($Fixture.IdentityPath)
	$AggregateBytes = [IO.File]::ReadAllBytes($Fixture.AggregatePath)
	$RequirementsBytes = [IO.File]::ReadAllBytes($Fixture.RequirementsPath)
	Assert-True ($IdentityBytes.Length -gt 0 -and $IdentityBytes[0] -ne 0xEF) 'Identity output must be bounded UTF-8 without BOM.'
	Assert-True ($AggregateBytes[-1] -ne 10 -and $RequirementsBytes[-1] -ne 10) 'Outputs must not add trailing line endings.'
	$Identity = $script:ContextUtf8.GetString($IdentityBytes) | ConvertFrom-Json
	$Aggregate = $script:ContextUtf8.GetString($AggregateBytes) | ConvertFrom-Json
	$Requirements = $script:ContextUtf8.GetString($RequirementsBytes) | ConvertFrom-Json
	Assert-True ((@($Identity.PSObject.Properties.Name)-join ',') -ceq 'schemaVersion,repository,event,source,workflow,controller,policy,actions,run,attemptAnchor,selection') 'Publisher identity context must have the exact closed ordered schema.'
	Assert-True ((@($Identity.selection.PSObject.Properties.Name)-join ',') -ceq 'checks' -and $Identity.selection.checks -is [array] -and (@($Identity.selection.checks)-join ',') -ceq 'portable,visual-package,native-client-server-compile') 'Publisher identity selection must carry every selector-selected obligation in selector order.'
	Assert-True ((@($Aggregate.PSObject.Properties.Name)-join ',') -ceq 'schemaVersion,repository,event,source,workflow,actions,controller,policy,run,attemptAnchor,selectorBinding,producerBindings') 'Aggregate context must have the exact direct-binding schema.'
	foreach ($Name in @('schemaVersion','repository','event','source','workflow','controller','policy','actions','run','attemptAnchor')) {
		Assert-True (($Identity.$Name|ConvertTo-Json -Depth 8 -Compress) -ceq ($Aggregate.$Name|ConvertTo-Json -Depth 8 -Compress)) "Identity field '$Name' must be semantically identical in both outputs."
	}
	Assert-True ($Identity.workflow.sha256 -ceq (Get-FileHash -LiteralPath $Fixture.WorkflowPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Workflow digest must bind exact workflow bytes.'
	Assert-True ($Identity.controller.blobOid -ceq ('d'*40) -and $Identity.policy.digest -ceq ('1'*64) -and $Identity.attemptAnchor.nonce -ceq $script:Nonce) 'Controller, policy, and attempt anchor must come from the selector report.'
	Assert-True ($Requirements.schemaVersion -ceq 'aetheln.ci-acceptance-requirements/v1' -and @($Requirements.jobs).Count -eq 4) 'Runtime requirements must use the aggregate schema.'
	foreach ($Job in $Requirements.jobs) { Assert-True ($Job.artifactName -ceq ('ci-receipt-'+$Job.key+'-9001-2-'+$script:Nonce)) 'Runtime artifact names must bind the current nonce.' }
	. (Join-Path $RepositoryRoot 'scripts\ci\Invoke-CiAcceptanceAggregate.ps1')
	Assert-AcceptanceContext -Context $Aggregate
	Assert-AcceptanceRequirements -Requirements $Requirements -Context $Aggregate
	$FirstIdentity = $script:ContextUtf8.GetString($IdentityBytes);$FirstAggregate=$script:ContextUtf8.GetString($AggregateBytes);$FirstRequirements=$script:ContextUtf8.GetString($RequirementsBytes)
	Remove-Item -LiteralPath $Fixture.IdentityPath,$Fixture.AggregatePath,$Fixture.RequirementsPath -Force
	Invoke-Fixture $Fixture
	Assert-True ($FirstIdentity -ceq [IO.File]::ReadAllText($Fixture.IdentityPath,$script:ContextUtf8) -and $FirstAggregate -ceq [IO.File]::ReadAllText($Fixture.AggregatePath,$script:ContextUtf8) -and $FirstRequirements -ceq [IO.File]::ReadAllText($Fixture.RequirementsPath,$script:ContextUtf8)) 'Valid output must be deterministic.'

	Assert-Rejected { Invoke-Fixture $Fixture } 'output_exists'
} finally { Remove-Item -LiteralPath $Fixture.Root -Recurse -Force }

$IdentityFixture = New-InvocationFixture
try {
	Invoke-Fixture -Fixture $IdentityFixture -Mode Identity
	Assert-True ((Test-Path -LiteralPath $IdentityFixture.IdentityPath -PathType Leaf) -and -not (Test-Path -LiteralPath $IdentityFixture.AggregatePath) -and -not (Test-Path -LiteralPath $IdentityFixture.RequirementsPath)) 'Identity mode must emit only the publisher context.'
} finally { Remove-Item -LiteralPath $IdentityFixture.Root -Recurse -Force }

$UnavailableGapFixture = New-InvocationFixture
try {
	Write-FixtureJson $UnavailableGapFixture.SelectorPath (Get-UnavailableSelectorFixture)
	$Gap = Invoke-Fixture -Fixture $UnavailableGapFixture -Mode Gap
	Assert-True ($Gap.mode -ceq 'Gap' -and $Gap.acceptedControllerUnavailable -eq $true -and $Gap.attemptAnchor.nonce -ceq $script:Nonce) 'Unavailable-controller gap validation must bind the current attempt without claiming accepted-base identity.'
	Assert-True ((@($Gap.selectedUnsupported) -join ',') -ceq 'content-reference-validation,clean-package-provenance-smoke') 'The fallback must conservatively select both obligations without live producers.'
	Assert-True (-not (Test-Path -LiteralPath $UnavailableGapFixture.IdentityPath) -and -not (Test-Path -LiteralPath $UnavailableGapFixture.AggregatePath) -and -not (Test-Path -LiteralPath $UnavailableGapFixture.RequirementsPath)) 'Gap mode must publish no identity, aggregate context, or receipt prerequisites.'
	Assert-Rejected { Invoke-Fixture -Fixture $UnavailableGapFixture -Mode Identity } 'selector_execution_invalid'
	Assert-Rejected { Invoke-Fixture -Fixture $UnavailableGapFixture -Mode Aggregate } 'selector_execution_invalid'
} finally { Remove-Item -LiteralPath $UnavailableGapFixture.Root -Recurse -Force }

$WorkflowFallbackFixture = New-InvocationFixture
$PreviousShadowReportPath = [Environment]::GetEnvironmentVariable('AETHELN_SHADOW_REPORT')
try {
	$WorkflowSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml'), $script:ContextUtf8)
	$FallbackWriters = [regex]::Matches($WorkflowSource, '(?m)^\s*\[IO\.File\]::WriteAllText\(\$env:AETHELN_SHADOW_REPORT, .*\)\r?$')
	Assert-True ($FallbackWriters.Count -eq 1) 'The workflow must contain exactly one fallback report writer.'
	$Report = Get-UnavailableSelectorFixture
	$Utf8 = $script:ContextUtf8
	Assert-True ($Utf8.WebName -ceq 'utf-8') 'The workflow fallback fixture must use UTF-8 bytes.'
	$env:AETHELN_SHADOW_REPORT = $WorkflowFallbackFixture.SelectorPath
	& ([scriptblock]::Create($FallbackWriters[0].Value))
	$FallbackBytes = [IO.File]::ReadAllBytes($WorkflowFallbackFixture.SelectorPath)
	Assert-True ($FallbackBytes.Length -gt 2 -and $FallbackBytes[-1] -eq 10 -and $FallbackBytes[-2] -ne 10 -and $FallbackBytes[-2] -ne 13) 'The actual workflow fallback writer must emit exactly one trailing LF.'
	$Gap = Invoke-Fixture -Fixture $WorkflowFallbackFixture -Mode Gap
	Assert-True ($Gap.acceptedControllerUnavailable -eq $true -and @($Gap.selectedUnsupported).Count -eq 2) 'The exact workflow fallback serialization must pass strict gap validation.'
} finally {
	if ($null -eq $PreviousShadowReportPath) { Remove-Item Env:AETHELN_SHADOW_REPORT -ErrorAction SilentlyContinue }
	else { $env:AETHELN_SHADOW_REPORT = $PreviousShadowReportPath }
	Remove-Item -LiteralPath $WorkflowFallbackFixture.Root -Recurse -Force
}

$AcceptedGapFixture = New-InvocationFixture
try {
	Write-FixtureJson $AcceptedGapFixture.SelectorPath (New-SelectorFixture -Selected @('content-reference-validation'))
	$Gap = Invoke-Fixture -Fixture $AcceptedGapFixture -Mode Gap
	Assert-True ($Gap.acceptedControllerUnavailable -eq $false -and (@($Gap.selectedUnsupported) -join ',') -ceq 'content-reference-validation') 'An accepted-base unsupported selection must retain the strict existing identity contract but produce only a gap diagnostic.'
	Assert-True (-not (Test-Path -LiteralPath $AcceptedGapFixture.IdentityPath) -and -not (Test-Path -LiteralPath $AcceptedGapFixture.AggregatePath)) 'Accepted-base gap validation must not create aggregate inputs.'
} finally { Remove-Item -LiteralPath $AcceptedGapFixture.Root -Recurse -Force }

$NoGapFixture = New-InvocationFixture
try { Assert-Rejected { Invoke-Fixture -Fixture $NoGapFixture -Mode Gap } 'gap_selection_empty' }
finally { Remove-Item -LiteralPath $NoGapFixture.Root -Recurse -Force }

$ContractFixture = New-InvocationFixture
try {
	Write-FixtureJson $ContractFixture.SelectorPath (New-SelectorFixture -Selected @('controller-contract','portable'))
	Assert-Rejected { Invoke-Fixture -Fixture $ContractFixture -Mode Gap } 'gap_selection_empty'
	Write-FixtureJson $ContractFixture.SelectorPath (New-SelectorFixture -Selected @('controller-operational-proof'))
	Assert-Rejected { Invoke-Fixture -Fixture $ContractFixture -Mode Gap } 'gap_selection_empty'
	# The selector always co-selects native compile with unreal automation; both now have live producers.
	Write-FixtureJson $ContractFixture.SelectorPath (New-SelectorFixture -Selected @('native-client-server-compile','unreal-editor-automation'))
	Assert-Rejected { Invoke-Fixture -Fixture $ContractFixture -Mode Gap } 'gap_selection_empty'
	$NativeOnlyBinding = ConvertTo-Json -InputObject @((Get-ProducerBindingsJson | ConvertFrom-Json)[0]) -Depth 4 -Compress
	Assert-Rejected { Invoke-Fixture -Fixture $ContractFixture -ProducerBindingsJson $NativeOnlyBinding } 'producer_binding_missing'
	Write-FixtureJson $ContractFixture.SelectorPath (New-SelectorFixture -Selected @('controller-contract','portable'))
	Assert-Rejected { Invoke-Fixture -Fixture $ContractFixture -ProducerBindingsJson '[]' } 'producer_binding_missing'
	Assert-True (-not (Test-Path -LiteralPath $ContractFixture.IdentityPath) -and -not (Test-Path -LiteralPath $ContractFixture.AggregatePath)) 'A missing portable producer binding must publish no aggregate inputs.'
	Invoke-Fixture -Fixture $ContractFixture -Mode Identity
	$ContractIdentity = Get-Content -LiteralPath $ContractFixture.IdentityPath -Raw | ConvertFrom-Json
	Assert-True ((@($ContractIdentity.selection.checks) -join ',') -ceq 'portable,controller-contract') 'Identity selection must expose controller-contract to the portable receipt publisher from selector bytes.'
} finally { Remove-Item -LiteralPath $ContractFixture.Root -Recurse -Force }

foreach ($Case in @(
	@{name='fallback-policy-digest';reason='selector_fallback_invalid';mutate={param($x)$x.policy.digest='1'*64}},
	@{name='fallback-blob';reason='selector_fallback_invalid';mutate={param($x)$x.execution.controllerBlobOid='d'*40}},
	@{name='fallback-reason';reason='selector_fallback_invalid';mutate={param($x)$x.execution.reason='classified'}},
	@{name='fallback-uncertainty';reason='selector_fallback_invalid';mutate={param($x)$x.classification.uncertainties=@('other')}},
	@{name='fallback-changed-path';reason='selector_fallback_invalid';mutate={param($x)$x.classification.changedPaths=@('Source/Foo.cpp')}},
	@{name='fallback-unselected';reason='selector_fallback_invalid';mutate={param($x)$x.selection.obligations[4].selected=$false;$x.selection.obligations[4].reasons=@()}},
	@{name='fallback-selection-reason';reason='selector_fallback_invalid';mutate={param($x)$x.selection.obligations[4].reasons=@('fixture')}},
	@{name='fallback-comparison';reason='selector_fallback_invalid';mutate={param($x)$x.comparison.status='match'}},
	@{name='fallback-legacy';reason='selector_fallback_invalid';mutate={param($x)$x.legacyAuthority.engineRequired=$true}},
	@{name='fallback-controller-revision';reason='selector_fallback_invalid';mutate={param($x)$x.execution.controllerRevision='f'*40}},
	@{name='fallback-attempt-replay';reason='selector_identity_mismatch';mutate={param($x)$x.attemptAnchor.runAttempt=3}},
	@{name='fallback-head-replay';reason='selector_identity_mismatch';mutate={param($x)$x.source.headRevision='f'*40}}
)) {
	$Bad = New-InvocationFixture
	try {
		$Report = Get-UnavailableSelectorFixture
		& $Case.mutate $Report
		Write-FixtureJson $Bad.SelectorPath $Report
		Assert-Rejected { Invoke-Fixture -Fixture $Bad -Mode Gap } $Case.reason
		Assert-True (-not (Test-Path -LiteralPath $Bad.IdentityPath) -and -not (Test-Path -LiteralPath $Bad.AggregatePath)) "Malformed fallback '$($Case.name)' must publish no acceptance inputs."
	} finally { Remove-Item -LiteralPath $Bad.Root -Recurse -Force }
}

$UnrealBindingFixture = New-InvocationFixture
try {
	Write-FixtureJson $UnrealBindingFixture.SelectorPath (New-SelectorFixture -Selected @('native-client-server-compile','unreal-editor-automation'))
	$NativeBinding = (Get-ProducerBindingsJson | ConvertFrom-Json)[0]
	$UnrealBinding = [pscustomobject][ordered]@{key='unreal';jobName='unreal-receipt-shadow';artifactId='2004';artifactName=('ci-receipt-unreal-9001-2-'+$script:Nonce);digest=('sha256:'+('b'*64))}
	Invoke-Fixture -Fixture $UnrealBindingFixture -ProducerBindingsJson (ConvertTo-Json -InputObject @($NativeBinding, $UnrealBinding) -Depth 4 -Compress)
	$UnrealAggregate = Get-Content -LiteralPath $UnrealBindingFixture.AggregatePath -Raw | ConvertFrom-Json
	$UnrealRequirements = Get-Content -LiteralPath $UnrealBindingFixture.RequirementsPath -Raw | ConvertFrom-Json
	Assert-True ((@($UnrealAggregate.producerBindings | ForEach-Object { $_.key }) -join ',') -ceq 'native,unreal' -and (@($UnrealRequirements.jobs | Where-Object { $_.key -ceq 'unreal' } | ForEach-Object { $_.jobName + ':' + (@($_.checks) -join ',') }) -join ';') -ceq 'unreal-receipt-shadow:unreal-editor-automation') 'A native plus unreal selection must bind the dedicated unreal receipt job.'
} finally { Remove-Item -LiteralPath $UnrealBindingFixture.Root -Recurse -Force }

$SingleBindingFixture = New-InvocationFixture
try {
	Write-FixtureJson $SingleBindingFixture.SelectorPath (New-SelectorFixture -Selected @('visual-package'))
	$AllBindings=Get-ProducerBindingsJson|ConvertFrom-Json
	$SingleBindingJson=ConvertTo-Json -InputObject @($AllBindings[2]) -Depth 4 -Compress
	Invoke-Fixture -Fixture $SingleBindingFixture -ProducerBindingsJson $SingleBindingJson
	$SingleAggregate=Get-Content -LiteralPath $SingleBindingFixture.AggregatePath -Raw|ConvertFrom-Json
	Assert-True ($SingleAggregate.producerBindings -is [array] -and $SingleAggregate.producerBindings.Count -eq 1 -and $SingleAggregate.producerBindings[0].key -ceq 'visual') 'A one-producer aggregate must preserve the binding as a JSON array.'
} finally { Remove-Item -LiteralPath $SingleBindingFixture.Root -Recurse -Force }

foreach ($Case in @(
	@{name='selector-replay';reason='selector_identity_mismatch';mutate={param($f)$x=Get-Content -Raw $f.SelectorPath|ConvertFrom-Json;$x.attemptAnchor.runId='9000';Write-FixtureJson $f.SelectorPath $x}},
	@{name='selector-type';reason='selector_identity_invalid';mutate={param($f)$x=Get-Content -Raw $f.SelectorPath|ConvertFrom-Json;$x.attemptAnchor.runAttempt='2';Write-FixtureJson $f.SelectorPath $x}},
	@{name='selector-open';reason='selector_schema_invalid';mutate={param($f)$x=Get-Content -Raw $f.SelectorPath|ConvertFrom-Json;$x|Add-Member extra $true;Write-FixtureJson $f.SelectorPath $x}},
	@{name='retired-selector-id';reason='selector_policy_invalid';mutate={param($f)$x=Get-Content -Raw $f.SelectorPath|ConvertFrom-Json;$x.policy.checkIds=@($x.policy.checkIds[0..1])+@('delivery-harness')+@($x.policy.checkIds[2..7]);Write-FixtureJson $f.SelectorPath $x}},
	@{name='selector-missing-lf';reason='json_canonical_bytes_invalid';mutate={param($f)$raw=[IO.File]::ReadAllText($f.SelectorPath,$script:ContextUtf8);[IO.File]::WriteAllText($f.SelectorPath,$raw.Substring(0,$raw.Length-1),$script:ContextUtf8)}},
	@{name='selector-extra-lf';reason='json_canonical_bytes_invalid';mutate={param($f)[IO.File]::AppendAllText($f.SelectorPath,"`n",$script:ContextUtf8)}},
	@{name='selector-duplicate-json';reason='json_duplicate_property';mutate={param($f)$raw=[IO.File]::ReadAllText($f.SelectorPath,$script:ContextUtf8);$raw=$raw -replace '^\{','{"schemaVersion":"evil",';[IO.File]::WriteAllText($f.SelectorPath,$raw,$script:ContextUtf8)}},
	@{name='incomplete-coverage';reason='requirements_check_coverage_incomplete';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x.jobs[1].checks=@($x.jobs[1].checks|Where-Object{$_ -cne 'portable'});Write-FixtureJson $f.TemplatePath $x}},
	@{name='retired-template-id';reason='requirements_check_invalid';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x.jobs[1].checks=@($x.jobs[1].checks[0..1])+@('delivery-harness')+@($x.jobs[1].checks[2]);Write-FixtureJson $f.TemplatePath $x}},
	@{name='unsorted-template';reason='requirements_not_sorted';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x.jobs=@($x.jobs[1],$x.jobs[0],$x.jobs[2],$x.jobs[3]);Write-FixtureJson $f.TemplatePath $x}},
	@{name='template-open';reason='requirements_schema_invalid';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x|Add-Member extra $true;Write-FixtureJson $f.TemplatePath $x}},
	@{name='workflow-reparse';reason='input_reparse_rejected';mutate={param($f)$targetRoot=Join-Path $f.Root 'actual';$linkRoot=Join-Path $f.Root 'linked';New-Item -ItemType Directory -Path $targetRoot|Out-Null;Move-Item $f.WorkflowPath (Join-Path $targetRoot 'workflow.yml');New-Item -ItemType Junction -Path $linkRoot -Target $targetRoot|Out-Null;$f.WorkflowPath=Join-Path $linkRoot 'workflow.yml'}}
)) {
	$Bad = New-InvocationFixture
	try { & $Case.mutate $Bad; Assert-Rejected { Invoke-Fixture $Bad } $Case.reason }
	finally { Remove-Item -LiteralPath $Bad.Root -Recurse -Force }
}

foreach ($Case in @(
	@{name='actions-unsorted';reason='actions_not_sorted';json={(@([pscustomobject][ordered]@{uses='z/action';revision=('1'*40)},[pscustomobject][ordered]@{uses='a/action';revision=('2'*40)})|ConvertTo-Json -Compress)}},
	@{name='actions-open';reason='actions_schema_invalid';json={(ConvertTo-Json -InputObject @([pscustomobject][ordered]@{uses='a/action';revision=('1'*40);extra=$true}) -Compress)}},
	@{name='actions-trailing';reason='json_canonical_bytes_invalid';json={(Get-ActionItemsJson)+"`n"}}
)) {
	$Bad=New-InvocationFixture
	try { Assert-Rejected { Invoke-Fixture -Fixture $Bad -ActionItemsJson (& $Case.json) } $Case.reason }
	finally { Remove-Item -LiteralPath $Bad.Root -Recurse -Force }
}

foreach ($Case in @(
	@{name='selector-binding-replay';reason='selector_binding_invalid';selector={([pscustomobject][ordered]@{jobName='ci-selection-shadow';artifactId='1001';artifactName=('ci-selection-shadow-9000-2-'+$script:Nonce);digest=('sha256:'+('7'*64))}|ConvertTo-Json -Compress)};producer={Get-ProducerBindingsJson}},
	@{name='binding-unsorted';reason='producer_bindings_not_sorted';selector={Get-SelectorBindingJson};producer={$x=Get-ProducerBindingsJson|ConvertFrom-Json;@($x[1],$x[0],$x[2])|ConvertTo-Json -Compress}},
	@{name='binding-duplicate';reason='producer_bindings_duplicate';selector={Get-SelectorBindingJson};producer={$x=Get-ProducerBindingsJson|ConvertFrom-Json;$x[1].artifactId=$x[0].artifactId;$x|ConvertTo-Json -Compress}},
	@{name='binding-missing';reason='producer_binding_missing';selector={Get-SelectorBindingJson};producer={$x=Get-ProducerBindingsJson|ConvertFrom-Json;@($x[0],$x[1])|ConvertTo-Json -Compress}},
	@{name='binding-swapped';reason='producer_binding_requirement_mismatch';selector={Get-SelectorBindingJson};producer={$x=Get-ProducerBindingsJson|ConvertFrom-Json;$x[0].jobName='visual-receipt-shadow';$x|ConvertTo-Json -Compress}},
	@{name='binding-digest';reason='producer_binding_invalid';selector={Get-SelectorBindingJson};producer={$x=Get-ProducerBindingsJson|ConvertFrom-Json;$x[0].digest='sha256:'+('A'*64);$x|ConvertTo-Json -Compress}}
)) {
	$Bad=New-InvocationFixture
	try { Assert-Rejected { Invoke-Fixture -Fixture $Bad -SelectorBindingJson (& $Case.selector) -ProducerBindingsJson (& $Case.producer) } $Case.reason }
	finally { Remove-Item -LiteralPath $Bad.Root -Recurse -Force }
}

$Traversal = New-InvocationFixture
try {
	Assert-Rejected { Invoke-CiAcceptanceAggregateContextMain -Mode Identity -SelectorReportPath (Join-Path $Traversal.Root 'sub\..\selector.json') -WorkflowPath $Traversal.WorkflowPath -Repository 'ShayShimoni/aetheln-online' -Actor owner -TriggeringActor owner -BaseRevision ('a'*40) -HeadRevision ('b'*40) -TestedRevision ('c'*40) -WorkflowId 9876543 -RunId 9001 -RunAttempt 2 -ActionItemsJson (Get-ActionItemsJson) -IdentityContextOutputPath $Traversal.IdentityPath } 'path_traversal_rejected'
} finally { Remove-Item -LiteralPath $Traversal.Root -Recurse -Force }

$Oversized = New-InvocationFixture
try {
	[IO.File]::WriteAllBytes($Oversized.WorkflowPath,(New-Object byte[] (1048577)))
	Assert-Rejected { Invoke-Fixture $Oversized } 'input_size_limit'
} finally { Remove-Item -LiteralPath $Oversized.Root -Recurse -Force }

Write-Output 'New-CiAcceptanceAggregateContext tests passed.'
