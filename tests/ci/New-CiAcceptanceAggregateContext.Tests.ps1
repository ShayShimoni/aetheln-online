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
$script:CheckIds = @('portable','visual-package','delivery-harness','native-client-server-compile','unreal-editor-automation','content-reference-validation','controller-contract','controller-operational-proof','clean-package-provenance-smoke')
$script:Nonce = '6' * 64

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

function New-RequirementsTemplateFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory requirements-template fixture without changing external state.')]
	param()
	return [pscustomobject][ordered]@{
		schemaVersion='aetheln.ci-acceptance-requirements-template/v1'
		jobs=@(
			[pscustomobject][ordered]@{key='native';jobName='native-receipt-shadow';checks=@('clean-package-provenance-smoke','native-client-server-compile')},
			[pscustomobject][ordered]@{key='portable';jobName='portable-receipt-shadow';checks=@('content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','portable','unreal-editor-automation')},
			[pscustomobject][ordered]@{key='visual';jobName='visual-receipt-shadow';checks=@('visual-package')}
		)
	}
}

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
	param($Fixture,[ValidateSet('Identity','Aggregate')][string]$Mode='Aggregate',[string]$ActionItemsJson=(Get-ActionItemsJson),[string]$SelectorBindingJson=(Get-SelectorBindingJson),[string]$ProducerBindingsJson=(Get-ProducerBindingsJson))
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
	Assert-True ((@($Identity.PSObject.Properties.Name)-join ',') -ceq 'schemaVersion,repository,event,source,workflow,controller,policy,actions,run,attemptAnchor') 'Publisher identity context must have the exact closed ordered schema.'
	Assert-True ((@($Aggregate.PSObject.Properties.Name)-join ',') -ceq 'schemaVersion,repository,event,source,workflow,actions,controller,policy,run,attemptAnchor,selectorBinding,producerBindings') 'Aggregate context must have the exact direct-binding schema.'
	foreach ($Name in @('schemaVersion','repository','event','source','workflow','controller','policy','actions','run','attemptAnchor')) {
		Assert-True (($Identity.$Name|ConvertTo-Json -Depth 8 -Compress) -ceq ($Aggregate.$Name|ConvertTo-Json -Depth 8 -Compress)) "Identity field '$Name' must be semantically identical in both outputs."
	}
	Assert-True ($Identity.workflow.sha256 -ceq (Get-FileHash -LiteralPath $Fixture.WorkflowPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Workflow digest must bind exact workflow bytes.'
	Assert-True ($Identity.controller.blobOid -ceq ('d'*40) -and $Identity.policy.digest -ceq ('1'*64) -and $Identity.attemptAnchor.nonce -ceq $script:Nonce) 'Controller, policy, and attempt anchor must come from the selector report.'
	Assert-True ($Requirements.schemaVersion -ceq 'aetheln.ci-acceptance-requirements/v1' -and @($Requirements.jobs).Count -eq 3) 'Runtime requirements must use the aggregate schema.'
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
	@{name='selector-missing-lf';reason='json_canonical_bytes_invalid';mutate={param($f)$raw=[IO.File]::ReadAllText($f.SelectorPath,$script:ContextUtf8);[IO.File]::WriteAllText($f.SelectorPath,$raw.Substring(0,$raw.Length-1),$script:ContextUtf8)}},
	@{name='selector-extra-lf';reason='json_canonical_bytes_invalid';mutate={param($f)[IO.File]::AppendAllText($f.SelectorPath,"`n",$script:ContextUtf8)}},
	@{name='selector-duplicate-json';reason='json_duplicate_property';mutate={param($f)$raw=[IO.File]::ReadAllText($f.SelectorPath,$script:ContextUtf8);$raw=$raw -replace '^\{','{"schemaVersion":"evil",';[IO.File]::WriteAllText($f.SelectorPath,$raw,$script:ContextUtf8)}},
	@{name='incomplete-coverage';reason='requirements_check_coverage_incomplete';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x.jobs[1].checks=@($x.jobs[1].checks|Where-Object{$_ -cne 'portable'});Write-FixtureJson $f.TemplatePath $x}},
	@{name='unsorted-template';reason='requirements_not_sorted';mutate={param($f)$x=Get-Content -Raw $f.TemplatePath|ConvertFrom-Json;$x.jobs=@($x.jobs[1],$x.jobs[0],$x.jobs[2]);Write-FixtureJson $f.TemplatePath $x}},
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
