[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$GovernedValidator = Join-Path $RepositoryRoot 'scripts/build/Validate-ContentCookEvidence.ps1'
$GovernedPolicyPath = Join-Path $RepositoryRoot 'Config/ContentValidation/asset-intake-policy.json'
$Validator = $GovernedValidator
$PolicyPath = $GovernedPolicyPath
$RuntimeIntakePath = $null
$BuildProvenancePath = $null
$ActiveReportPath = $null
$FixtureRevision = ('a' * 40)
$FixtureEngineRevision = ('b' * 40)
$FixtureEngineBinarySha256 = ('c' * 64)
$FixtureBuildVersionSha256 = ('d' * 64)
$FixtureCompilerSha256 = ('e' * 64)
$FixtureResourceCompilerSha256 = ('f' * 64)
$FixtureLinuxCompilerSha256 = ('1' * 64)
$FixtureProjectSha256 = ('2' * 64)
$FixtureEditorBuildCommandSha256 = ('3' * 64)
$FixtureEditorBuildLogSha256 = ('4' * 64)
$FixtureReportCompilerVersion = '14.44.35228'
$FixtureBuildCompilerVersion = '14.44.35207'
$FixtureResourceCompilerVersion = '10.0.26100.0'
$FixtureBuildId = 'fixture-editor-build-id'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnContentCookTests-{0}" -f [guid]::NewGuid().ToString('N'))
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

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-Inventory([string] $Directory, [string[]] $Packages, [string] $Kind) {
	New-Item -ItemType Directory -Path $Directory -Force | Out-Null
	if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = if ((Split-Path -Leaf $Directory) -match '(?i)server') { 'server' } else { 'client' } }
	$Lines = [System.Collections.Generic.List[string]]::new()
	$Lines.Add('--- Begin CachedAssetsByPackageName ---')
	foreach ($Package in ($Packages | Sort-Object -Unique)) {
		$Lines.Add("`t$Package : 1 item(s)")
		$Lines.Add("`t`t$Package.$([IO.Path]::GetFileName($Package))")
	}
	$Lines.Add("--- End CachedAssetsByPackageName : $($Packages.Count) entries ---")
	Set-Content -LiteralPath (Join-Path $Directory 'Page_00000.txt') -Value $Lines -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $Directory 'AssetRegistry.bin') -Value "$Kind staged registry fixture" -Encoding UTF8
	Write-InventoryManifest $Directory $Packages.Count $Kind
}

function Write-InventoryManifest([string] $Directory, [int] $PackageCount, [string] $Kind) {
	if ([string]::IsNullOrWhiteSpace($ActiveReportPath)) { throw 'ActiveReportPath is required for inventory fixtures.' }
	$ReportValue = Get-Content -LiteralPath $ActiveReportPath -Raw | ConvertFrom-Json
	$BuildValue = Get-Content -LiteralPath $BuildProvenancePath -Raw | ConvertFrom-Json
	if ([string]::IsNullOrWhiteSpace($Kind)) { $Kind = if ((Split-Path -Leaf $Directory) -match '(?i)server') { 'server' } else { 'client' } }
	$Target = if ($Kind -ceq 'server') { [string]$BuildValue.build.serverTarget } else { [string]$BuildValue.build.clientTarget }
	$Platform = if ($Kind -ceq 'server') { [string]$BuildValue.build.serverPlatform } else { [string]$BuildValue.build.clientPlatform }
	$ToolchainIdentity = if ($Kind -ceq 'server') { [string]$BuildValue.tools.linuxCrossToolchain.identity } else { [string]$BuildValue.tools.compiler.version }
	$ToolchainSha = if ($Kind -ceq 'server') { [string]$BuildValue.tools.linuxCrossToolchain.compilerSha256 } else { [string]$BuildValue.tools.compiler.sha256 }
	$CookPlatform = if ($Kind -ceq 'server') { 'LinuxServer' } else { 'WindowsClient' }
	$CookArguments = if ($Kind -ceq 'server') { @($BuildValue.build.uatInvocations.server.arguments) } else { @($BuildValue.build.uatInvocations.client.arguments) }
	$CookBytes = [Text.Encoding]::UTF8.GetBytes((@($CookArguments) -join "`0"))
	$CookHasher = [Security.Cryptography.SHA256]::Create()
	try { $CookCommandSha256 = ([BitConverter]::ToString($CookHasher.ComputeHash($CookBytes))).Replace('-', '').ToLowerInvariant() }
	finally { $CookHasher.Dispose() }
	$Pages = @(Get-ChildItem -LiteralPath $Directory -File -Filter 'Page_*.txt' | Sort-Object Name | ForEach-Object {
		[ordered]@{ name=$_.Name; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
	})
	$RegistryPath = Join-Path $Directory 'AssetRegistry.bin'
	$BuildProvenanceSha256 = (Get-FileHash -LiteralPath $BuildProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
	$Manifest = [ordered]@{
		schema_id='aetheln.cooked-inventory-manifest'; schema_version=2; capture_mode='test_fixture'; source_revision=[string]$ReportValue.revision; repository_clean=$true
		engine_revision=[string]$ReportValue.execution_provenance.engine_revision; engine_tag=[string]$ReportValue.execution_provenance.engine_tag
		engine_binary_sha256=[string]$ReportValue.execution_provenance.engine_binary_sha256; build_version_sha256=[string]$ReportValue.execution_provenance.build_version_sha256
		target=$Target; platform=$Platform; configuration=[string]$BuildValue.build.configuration; toolchain_identity=$ToolchainIdentity; toolchain_sha256=$ToolchainSha
		project_sha256=[string]$ReportValue.execution_provenance.project_sha256; policy_sha256=[string]$ReportValue.policy_sha256; intake_sha256=[string]$ReportValue.intake_sha256
		content_validation_report_sha256=(Get-FileHash -LiteralPath $ActiveReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
		build_provenance_sha256=$BuildProvenanceSha256
		cooked_registry=[ordered]@{
			source_path="test-fixture/$Kind/AssetRegistry.bin"; staged_path='AssetRegistry.bin'; size_bytes=(Get-Item -LiteralPath $RegistryPath).Length
			sha256=(Get-FileHash -LiteralPath $RegistryPath -Algorithm SHA256).Hash.ToLowerInvariant(); target=$Target; platform=$Platform; cook_platform=$CookPlatform
			build_provenance_sha256=$BuildProvenanceSha256; source_revision=[string]$BuildValue.source.revision
		}
		cook_command_sha256=$CookCommandSha256; capture_command_sha256=('5' * 64)
		started_utc='2026-08-29T00:00:02Z'; finished_utc='2026-08-29T00:00:03Z'; package_count=$PackageCount; pages=$Pages
	}
	[IO.File]::WriteAllText((Join-Path $Directory 'inventory-manifest.json'), (($Manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Split-InventoryIntoTwoPages([string] $Directory) {
	$FirstPagePath = Join-Path $Directory 'Page_00000.txt'
	$Lines = @(Get-Content -LiteralPath $FirstPagePath)
	Assert-True ($Lines.Count -ge 6) 'The paged inventory fixture requires at least two packages.'
	Set-Content -LiteralPath $FirstPagePath -Value @($Lines[0..2]) -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $Directory 'Page_00001.txt') -Value @($Lines[3..($Lines.Count - 1)]) -Encoding UTF8
	$EndMarker = @($Lines | Select-String '^--- End Cached(?:Assets|Packages)ByPackageName : (?<EntryCount>\d+) entries ---$')
	$EntryCount = [int]$EndMarker[0].Matches[0].Groups['EntryCount'].Value
	Write-InventoryManifest $Directory $EntryCount
}

function New-FixtureExecutionProvenance([string] $EffectivePolicyPath) {
	$Policy = Get-Content -LiteralPath $EffectivePolicyPath -Raw | ConvertFrom-Json
	$PolicySha256 = (Get-FileHash -LiteralPath $EffectivePolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$IntakeSha256 = (Get-FileHash -LiteralPath $RuntimeIntakePath -Algorithm SHA256).Hash.ToLowerInvariant()
	if ([int]$Policy.report.schema_version -ge 2) {
		return [ordered]@{
			repository_clean=$true; engine_revision=$FixtureEngineRevision; engine_tag='5.8.1-release'; engine_binary_sha256=$FixtureEngineBinarySha256
			build_version_sha256=$FixtureBuildVersionSha256; target='AethelnOnlineEditor'; platform='Win64'; configuration='Development'
			editor_build_command_sha256=$FixtureEditorBuildCommandSha256; editor_build_log_sha256=$FixtureEditorBuildLogSha256
			compiler_version=$FixtureReportCompilerVersion; compiler_sha256=$FixtureCompilerSha256
			resource_compiler_version=$FixtureResourceCompilerVersion; resource_compiler_sha256=$FixtureResourceCompilerSha256
			target_receipt=[ordered]@{ path='Binaries/Win64/AethelnOnlineEditor.target'; size_bytes=101; sha256=('7' * 64); build_id=$FixtureBuildId }
			module_manifest=[ordered]@{ path='Binaries/Win64/UnrealEditor.modules'; size_bytes=102; sha256=('8' * 64); build_id=$FixtureBuildId }
			loaded_project_modules=@(
				[ordered]@{ name='GameCore'; path='Binaries/Win64/UnrealEditor-GameCore.dll'; size_bytes=103; sha256=('9' * 64); build_id=$FixtureBuildId },
				[ordered]@{ name='GameTests'; path='Binaries/Win64/UnrealEditor-GameTests.dll'; size_bytes=104; sha256=('a' * 64); build_id=$FixtureBuildId }
			)
			project_sha256=$FixtureProjectSha256; policy_sha256=$PolicySha256; intake_sha256=$IntakeSha256
			invocation_sha256=('6' * 64); registry_source='test_snapshot'
		}
	}
	return [ordered]@{
		repository_clean=$true; engine_revision=$FixtureEngineRevision; engine_tag='5.8.1-release'; engine_binary_sha256=$FixtureEngineBinarySha256
		build_version_sha256=$FixtureBuildVersionSha256; target='AethelnOnlineEditor'; platform='Win64'; configuration='Development'
		compiler_sha256=$FixtureCompilerSha256; resource_compiler_sha256=$FixtureResourceCompilerSha256; project_sha256=$FixtureProjectSha256
		policy_sha256=$PolicySha256; intake_sha256=$IntakeSha256; invocation_sha256=('6' * 64); registry_source='test_snapshot'
	}
}

function Write-Report([string] $Path, [object[]] $Assets, [string] $Result = 'passed', [string] $EffectivePolicyPath = $PolicyPath) {
	$Policy = Get-Content -LiteralPath $EffectivePolicyPath -Raw | ConvertFrom-Json
	$Findings = @()
	[ordered]@{
		schema_id = 'aetheln.content-validation-report'
		schema_version = [int]$Policy.report.schema_version
		revision = $FixtureRevision
		engine_identity = "5.8.1-release@$FixtureEngineRevision"
		policy_sha256 = (Get-FileHash -LiteralPath $EffectivePolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
		intake_sha256 = (Get-FileHash -LiteralPath $RuntimeIntakePath -Algorithm SHA256).Hash.ToLowerInvariant()
		execution_provenance = New-FixtureExecutionProvenance $EffectivePolicyPath
		audience = 'all'
		started_utc = '2026-08-29T00:00:00Z'
		finished_utc = '2026-08-29T00:00:01Z'
		command = 'fixture'
		counts = @{ assets = $Assets.Count; findings = $Findings.Count; errors = 0; non_promotion = 0 }
		assets = @($Assets)
		findings = $Findings
		result = $Result
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-FixtureLifecycle([string] $StableId, [string] $State = 'runtime_candidate') {
	$Evidence = [ordered]@{
		content_identity = [ordered]@{ stable_id=$StableId; content_version=1; content_sha256=('1' * 64) }
		temporary_prototype = @()
		runtime_candidate = @()
		production_approval = @()
	}
	if ($State -ceq 'temporary_prototype') {
		$Evidence.temporary_prototype = @([ordered]@{ owner='Fixture owner'; approval_record='Fixture temporary approval'; recovery_trigger='Replace after fixture'; may_be_runtime_candidate=$false })
	} else {
		$Evidence.runtime_candidate = @([ordered]@{ review_revision=$FixtureRevision; reviewer='fixture-reviewer'; approval_record='Fixture runtime approval'; stable_id=$StableId; content_version=1; content_sha256=('1' * 64) })
		if ($State -ceq 'production_approved') {
			$Evidence.production_approval = @([ordered]@{ candidate_review_revision=$FixtureRevision; candidate_approval_record='Fixture runtime approval'; production_revision=('9' * 40); reviewer='fixture-production-reviewer'; approval_record='Fixture production approval'; stable_id=$StableId; content_version=1; content_sha256=('1' * 64) })
		}
	}
	return $Evidence
}

function Set-FixtureLifecycleWrapperCasing([object] $Record) {
	$Lifecycle = $Record.lifecycle_evidence
	if ($Record -is [Collections.IDictionary]) {
		$Record.Remove('lifecycle_evidence')
		$Record['Lifecycle_evidence'] = $Lifecycle
	} else {
		$Record.PSObject.Properties.Remove('lifecycle_evidence')
		$Record | Add-Member -NotePropertyName Lifecycle_evidence -NotePropertyValue $Lifecycle
	}
}

function New-GovernedAsset([string] $AssetPath, [string] $StableId, [string] $Audience, [string] $EffectivePolicyPath = $PolicyPath) {
	$Policy = Get-Content -LiteralPath $EffectivePolicyPath -Raw | ConvertFrom-Json
	return [ordered]@{
		asset_path = $AssetPath
		stable_id = $StableId
		content_version = 1
		audience = $Audience
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
		lifecycle_evidence = New-FixtureLifecycle $StableId
		family_results = @(
			foreach ($Family in $Policy.policy_families) {
				if ([int]$Policy.report.schema_version -ge 2) {
					[ordered]@{
						policy_id=[string]$Family.id; applicability='applicable'; deterministic_status='passed'; promotion_status='eligible'; evidence="fixture:$($Family.id):accepted"
						check_results=@($Family.checks | ForEach-Object { [ordered]@{ check_id=[string]$_; applicability='applicable'; deterministic_status='passed'; promotion_status='eligible'; evidence="fixture:$($Family.id):$($_):accepted" } })
					}
				}
				else { [ordered]@{ policy_id=[string]$Family.id; applicability='applicable'; status='passed'; evidence="fixture:$($Family.id):accepted" } }
			}
		)
	}
}

function New-PolicyOutcomeAsset([string] $AssetPath, [string] $StableId, [string] $Audience, [string] $EffectivePolicyPath) {
	$Policy = Get-Content -LiteralPath $EffectivePolicyPath -Raw | ConvertFrom-Json
	$Asset = New-GovernedAsset $AssetPath $StableId $Audience $EffectivePolicyPath
	$HasUnresolvedThresholds = @($Policy.thresholds.unresolved_budgets | Where-Object { $_.value -ceq $Policy.thresholds.unresolved_value }).Count -gt 0
	foreach ($FamilyResult in $Asset.family_results) {
		$FamilyPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq $FamilyResult.policy_id })[0]
		if ($HasUnresolvedThresholds -and $FamilyPolicy.unresolved_quantitative_result -ceq 'non_promotion') {
			if ([int]$Policy.report.schema_version -ge 2) {
				foreach ($CheckResult in $FamilyResult.check_results) {
					if (@($PromotionBlockingChecks[[string]$FamilyResult.policy_id]) -ccontains [string]$CheckResult.check_id) { $CheckResult.promotion_status = 'non_promotion' }
				}
				if (@($FamilyResult.check_results | Where-Object { $_.promotion_status -ceq 'non_promotion' }).Count -gt 0) {
					$FamilyResult.promotion_status = 'non_promotion'
					$FamilyResult.evidence = "policy:$($FamilyResult.policy_id):non_promotion:unresolved_budgets"
				}
			}
			else {
				$FamilyResult.status = 'non_promotion'
				$FamilyResult.evidence = "policy:$($FamilyResult.policy_id):non_promotion:unresolved_budgets"
			}
		}
	}
	return $Asset
}

function Write-PolicyOutcomeReport([string] $Path, [object[]] $Assets, [string] $EffectivePolicyPath) {
	$Policy = Get-Content -LiteralPath $EffectivePolicyPath -Raw | ConvertFrom-Json
	$Findings = [System.Collections.Generic.List[object]]::new()
	foreach ($Asset in $Assets) {
		foreach ($FamilyResult in $Asset.family_results) {
			$FamilyStatus = if ([int]$Policy.report.schema_version -ge 2) {
				if ($FamilyResult.deterministic_status -ceq 'failed') { 'failed' } elseif ($FamilyResult.promotion_status -ceq 'non_promotion') { 'non_promotion' } else { 'passed' }
			}
			else { [string]$FamilyResult.status }
			if ($FamilyStatus -cin @('failed', 'non_promotion')) {
				$FamilyPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq $FamilyResult.policy_id })[0]
				$Severity = if ($FamilyStatus -ceq 'failed') { 'error' } else { 'non_promotion' }
				$Code = if ($Severity -ceq 'error') { [string]$FamilyPolicy.failure_code } else { [string]$FamilyPolicy.failure_code -replace '\.failed$', '.non_promotion' }
				$Findings.Add([ordered]@{
					policy_id = [string]$FamilyResult.policy_id
					code = $Code
					asset_path = [string]$Asset.asset_path
					severity = $Severity
					reason = "fixture policy outcome for $($FamilyResult.policy_id)"
					remediation = "resolve the governed $($FamilyResult.policy_id) gate"
					evidence_field = "family_results.$($FamilyResult.policy_id)"
				})
			}
		}
	}
	$ErrorCount = @($Findings | Where-Object { $_.severity -ceq 'error' }).Count
	$NonPromotionCount = @($Findings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
	$Result = if ($ErrorCount -gt 0) { 'failed' } elseif ($NonPromotionCount -gt 0) { 'non_promotion' } else { 'passed' }
	[ordered]@{
		schema_id = 'aetheln.content-validation-report'
		schema_version = [int]$Policy.report.schema_version
		revision = $FixtureRevision
		engine_identity = "5.8.1-release@$FixtureEngineRevision"
		policy_sha256 = (Get-FileHash -LiteralPath $EffectivePolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
		intake_sha256 = (Get-FileHash -LiteralPath $RuntimeIntakePath -Algorithm SHA256).Hash.ToLowerInvariant()
		execution_provenance = New-FixtureExecutionProvenance $EffectivePolicyPath
		audience = 'all'
		started_utc = '2026-08-29T00:00:00Z'
		finished_utc = '2026-08-29T00:00:01Z'
		command = 'fixture'
		counts = @{ assets = $Assets.Count; findings = $Findings.Count; errors = $ErrorCount; non_promotion = $NonPromotionCount }
		assets = @($Assets)
		findings = @($Findings)
		result = $Result
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-ExpectedFailure([hashtable] $Arguments, [string] $Pattern, [string] $ValidatorPath = $Validator) {
	if (-not $Arguments.ContainsKey('PolicyPath')) { $Arguments.PolicyPath = $PolicyPath }
	if (-not $Arguments.ContainsKey('RuntimeIntakePath')) { $Arguments.RuntimeIntakePath = $RuntimeIntakePath }
	if (-not $Arguments.ContainsKey('BuildProvenancePath')) { $Arguments.BuildProvenancePath = $BuildProvenancePath }
	if (-not $Arguments.ContainsKey('AllowTestEvidence')) { $Arguments.AllowTestEvidence = $true }
	$Failure = $null
	try { & $ValidatorPath @Arguments | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True ($null -ne $Failure) "Expected validation to fail with '$Pattern'."
	Assert-True ($Failure -match $Pattern) "Failure '$Failure' did not match '$Pattern'."
}

function Invoke-TestValidator([string] $ReportPath, [string] $ClientDirectory, [string] $ServerDirectory, [string] $EvidencePath, [string] $EffectivePolicyPath = $PolicyPath) {
	$Arguments = @{ ContentValidationReportPath=$ReportPath; ClientCookedInventoryDirectory=$ClientDirectory; ServerCookedInventoryDirectory=$ServerDirectory; PolicyPath=$EffectivePolicyPath; RuntimeIntakePath=$RuntimeIntakePath; BuildProvenancePath=$BuildProvenancePath; AllowTestEvidence=$true }
	if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) { $Arguments.OutputPath = $EvidencePath }
	& $Validator @Arguments | Out-Null
}

function Invoke-LifecycleFixture([string] $Name, [string] $State, [scriptblock] $Mutation, [string] $FailurePattern) {
	$CaseRoot = Join-Path $FixtureRoot ("lifecycle-$Name")
	New-Item -ItemType Directory -Path $CaseRoot | Out-Null
	$CaseIntake = Get-Content -LiteralPath $RuntimeIntakePath -Raw | ConvertFrom-Json
	$RuntimeIntakePath = Join-Path $CaseRoot 'intake.json'
	$CasePolicyPath = if ($State -ceq 'temporary_prototype') { $GovernedPolicyPath } else { $PolicyPath }
	$ApprovalState = switch ($State) {
		'temporary_prototype' { 'temporary_prototype_only' }
		'runtime_candidate' { 'runtime_candidate_approved' }
		'production_approved' { 'production_approved' }
	}
	$CaseIntake.source_groups[0].approval_state = $ApprovalState
	$CaseAssets = @(
		foreach ($IntakeRecord in $CaseIntake.assets) {
			$IntakeRecord.lifecycle_state = $State
			$IntakeRecord.lifecycle_evidence = New-FixtureLifecycle $IntakeRecord.stable_id $State
			$Record = if ($State -ceq 'temporary_prototype') {
				New-PolicyOutcomeAsset $IntakeRecord.asset_path $IntakeRecord.stable_id $IntakeRecord.audience $CasePolicyPath
			} else { New-GovernedAsset $IntakeRecord.asset_path $IntakeRecord.stable_id $IntakeRecord.audience $CasePolicyPath }
			$Record.lifecycle_state = $State
			$Record.provenance.approval_state = $ApprovalState
			$Record.lifecycle_evidence = New-FixtureLifecycle $IntakeRecord.stable_id $State
			if ($State -ceq 'temporary_prototype') {
				foreach ($FamilyResult in $Record.family_results) {
					$FamilyResult.promotion_status = 'non_promotion'
					foreach ($CheckResult in $FamilyResult.check_results) { $CheckResult.promotion_status = 'non_promotion' }
				}
			}
			$Record
		}
	)
	if ($null -ne $Mutation) { & $Mutation $CaseIntake $CaseAssets }
	$CaseIntake | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $RuntimeIntakePath -Encoding UTF8
	$ActiveReportPath = Join-Path $CaseRoot 'report.json'
	if ($State -ceq 'temporary_prototype') { Write-PolicyOutcomeReport $ActiveReportPath $CaseAssets $CasePolicyPath }
	else { Write-Report $ActiveReportPath $CaseAssets 'passed' $CasePolicyPath }
	$CaseClient = Join-Path $CaseRoot 'client'
	$CaseServer = Join-Path $CaseRoot 'server'
	Write-Inventory $CaseClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	Write-Inventory $CaseServer @('/Game/Shared/DA_Objective', '/Game/Server/DA_ServerRules') 'server'
	$CaseOutput = Join-Path $CaseRoot 'evidence.json'
	if ([string]::IsNullOrWhiteSpace($FailurePattern)) {
		Invoke-TestValidator $ActiveReportPath $CaseClient $CaseServer $CaseOutput $CasePolicyPath
		$ExpectedResult = if ($State -ceq 'temporary_prototype') { 'non_promotion' } else { 'passed' }
		$Actual = Get-Content -LiteralPath $CaseOutput -Raw | ConvertFrom-Json
		Assert-True ($Actual.result -ceq $ExpectedResult) "Lifecycle '$State' must retain result '$ExpectedResult'."
	} else {
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$ActiveReportPath; ClientCookedInventoryDirectory=$CaseClient; ServerCookedInventoryDirectory=$CaseServer; OutputPath=$CaseOutput; PolicyPath=$CasePolicyPath } $FailurePattern
		Assert-True (-not (Test-Path -LiteralPath $CaseOutput)) "Invalid lifecycle '$Name' must not publish cook evidence."
	}
	Write-Output "PASS: lifecycle $Name"
}

try {
	Assert-True (Test-Path -LiteralPath $GovernedValidator -PathType Leaf) 'The content cook-evidence validator must exist.'
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$ResolvedRepositoryRoot = Join-Path $FixtureRoot 'resolved-policy-repository'
	$ResolvedScriptDirectory = Join-Path $ResolvedRepositoryRoot 'scripts/build'
	$ResolvedPolicyDirectory = Join-Path $ResolvedRepositoryRoot 'Config/ContentValidation'
	New-Item -ItemType Directory -Path $ResolvedScriptDirectory -Force | Out-Null
	New-Item -ItemType Directory -Path $ResolvedPolicyDirectory -Force | Out-Null
	$Validator = Join-Path $ResolvedScriptDirectory 'Validate-ContentCookEvidence.ps1'
	$PolicyPath = Join-Path $ResolvedPolicyDirectory 'asset-intake-policy.json'
	$RuntimeIntakePath = Join-Path $ResolvedPolicyDirectory 'runtime-asset-intake.json'
	$BuildProvenancePath = Join-Path $FixtureRoot 'build-provenance.json'
	Copy-Item -LiteralPath $GovernedValidator -Destination $Validator
	$IntegratedPolicy = Get-Content -LiteralPath $GovernedPolicyPath -Raw | ConvertFrom-Json
	$IntegratedPolicy.schema_version = 2
	$IntegratedPolicy.report.schema_version = 2
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName execution_provenance_required_fields -NotePropertyValue @('repository_clean','engine_revision','engine_tag','engine_binary_sha256','build_version_sha256','target','platform','configuration','editor_build_command_sha256','editor_build_log_sha256','compiler_version','compiler_sha256','resource_compiler_version','resource_compiler_sha256','target_receipt','module_manifest','loaded_project_modules','project_sha256','policy_sha256','intake_sha256','invocation_sha256','registry_source')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName family_result_required_fields -NotePropertyValue @('policy_id','applicability','deterministic_status','promotion_status','evidence','check_results')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName check_result_required_fields -NotePropertyValue @('check_id','applicability','deterministic_status','promotion_status','evidence')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName artifact_descriptor_required_fields -NotePropertyValue @('path','size_bytes','sha256','build_id')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName loaded_project_module_required_fields -NotePropertyValue @('name','path','size_bytes','sha256','build_id')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName loaded_project_module_names -NotePropertyValue @('GameCore','GameTests')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName allowed_deterministic_statuses -NotePropertyValue @('passed','failed','evidence_unavailable','not_applicable')
	$IntegratedPolicy.report | Add-Member -Force -NotePropertyName allowed_promotion_statuses -NotePropertyValue @('eligible','non_promotion','not_applicable')
	$IntegratedPolicy.report.PSObject.Properties.Remove('allowed_family_statuses')
	$GovernedPolicyPath = Join-Path $ResolvedPolicyDirectory 'governed-asset-intake-policy.json'
	[IO.File]::WriteAllText($GovernedPolicyPath, (($IntegratedPolicy | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
	$ResolvedPolicy = Get-Content -LiteralPath $GovernedPolicyPath -Raw | ConvertFrom-Json
	foreach ($Budget in $ResolvedPolicy.thresholds.unresolved_budgets) { $Budget.value = 'fixture-resolved' }
	[System.IO.File]::WriteAllText($PolicyPath, (($ResolvedPolicy | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
	$SourceGroup = [ordered]@{
		id='fixture-source'; author_or_provider='fixture-author'; source_record='fixture://source-record'; source_version='fixture-v1'
		license_or_permission_evidence='fixture-rights-record'; modifications='none'; generation_metadata_when_applicable='not_applicable'
		reviewer='fixture-reviewer'; approval_state='runtime_candidate_approved'; naming_owner='Fixture'; import_settings_record='fixture import'; reimport_settings_record='fixture reimport'
	}
	$IntakeAssets = @(
		[ordered]@{ asset_path='/Game/Shared/DA_Objective'; repository_path='Content/Shared/DA_Objective.uasset'; stable_id='content.objective'; content_version=1; audience='shared'; lifecycle_state='runtime_candidate'; source_group_id='fixture-source'; content_sha256=('1'*64); lifecycle_evidence=(New-FixtureLifecycle 'content.objective') }
		[ordered]@{ asset_path='/Game/Server/DA_ServerRules'; repository_path='Content/Server/DA_ServerRules.uasset'; stable_id='content.server_rules'; content_version=1; audience='server_only'; lifecycle_state='runtime_candidate'; source_group_id='fixture-source'; content_sha256=('1'*64); lifecycle_evidence=(New-FixtureLifecycle 'content.server_rules') }
		[ordered]@{ asset_path='/Game/UI/WBP_HUD'; repository_path='Content/UI/WBP_HUD.uasset'; stable_id='content.hud'; content_version=1; audience='client_only'; lifecycle_state='runtime_candidate'; source_group_id='fixture-source'; content_sha256=('1'*64); lifecycle_evidence=(New-FixtureLifecycle 'content.hud') }
	)
	$RuntimeIntake = [ordered]@{ schema_id='aetheln.runtime-asset-intake'; schema_version=1; policy_schema_id=[string]$IntegratedPolicy.schema_id; policy_schema_version=[int]$IntegratedPolicy.schema_version; content_root='Content/'; package_root='/Game'; expected_asset_count=$IntakeAssets.Count; source_groups=@($SourceGroup); assets=$IntakeAssets }
	[IO.File]::WriteAllText($RuntimeIntakePath, (($RuntimeIntake | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
	$BuildProvenance = [ordered]@{
		schemaVersion=2; source=[ordered]@{ revision=$FixtureRevision; clean=$true; projectSha256=$FixtureProjectSha256 }
		build=[ordered]@{ configuration='Development'; clientTarget='AethelnOnlineClient'; clientPlatform='Win64'; serverTarget='AethelnOnlineServer'; serverPlatform='Linux'; uatInvocations=[ordered]@{client=[ordered]@{arguments=@('BuildCookRun','-platform=Win64')};server=[ordered]@{arguments=@('BuildCookRun','-serverplatform=Linux')}} }
		tools=[ordered]@{ unreal=[ordered]@{repositoryRevision=$FixtureEngineRevision;buildVersionSha256=$FixtureBuildVersionSha256}; compiler=[ordered]@{version=$FixtureBuildCompilerVersion;sha256=$FixtureCompilerSha256}; windowsSdk=[ordered]@{version=$FixtureResourceCompilerVersion;resourceCompilerSha256=$FixtureResourceCompilerSha256}; linuxCrossToolchain=[ordered]@{identity='v26_clang-20.1.8-rockylinux8';compilerSha256=$FixtureLinuxCompilerSha256} }
	}
	# Producer receipts bind the exact bytes Write-Inventory stages for each kind.
	$ReceiptProbe = Join-Path $FixtureRoot 'receipt-probe.bin'
	$BuildProvenance.build.cookedRegistries = [ordered]@{}
	foreach ($Kind in @('client', 'server')) {
		Set-Content -LiteralPath $ReceiptProbe -Value "$Kind staged registry fixture" -Encoding UTF8
		$CookPlatform = if ($Kind -ceq 'server') { 'LinuxServer' } else { 'WindowsClient' }
		$BuildProvenance.build.cookedRegistries[$Kind] = [ordered]@{
			relativePath="Saved/Cooked/$CookPlatform/AethelnOnline/AssetRegistry.bin"; sizeBytes=(Get-Item -LiteralPath $ReceiptProbe).Length
			sha256=(Get-FileHash -LiteralPath $ReceiptProbe -Algorithm SHA256).Hash.ToLowerInvariant()
			target=$(if ($Kind -ceq 'server') { 'AethelnOnlineServer' } else { 'AethelnOnlineClient' }); platform=$(if ($Kind -ceq 'server') { 'Linux' } else { 'Win64' }); cookPlatform=$CookPlatform; sourceRevision=$FixtureRevision
		}
	}
	Remove-Item -LiteralPath $ReceiptProbe -Force
	[IO.File]::WriteAllText($BuildProvenancePath, (($BuildProvenance | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
	Write-Output 'PASS: cook-boundary behavior uses an isolated resolved-budget fixture policy'
	$Report = Join-Path $FixtureRoot 'content-report.json'
	$Client = Join-Path $FixtureRoot 'client'
	$Server = Join-Path $FixtureRoot 'server'
	$Output = Join-Path $FixtureRoot 'cook-evidence.json'
	$Assets = @(
		New-GovernedAsset '/Game/Shared/DA_Objective' 'content.objective' 'shared'
		New-GovernedAsset '/Game/Server/DA_ServerRules' 'content.server_rules' 'server_only'
		New-GovernedAsset '/Game/UI/WBP_HUD' 'content.hud' 'client_only'
	)
	Write-Report $Report $Assets
	$ActiveReportPath = $Report
	Write-Inventory $Client @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	Write-Inventory $Server @('/Game/Shared/DA_Objective', '/Game/Server/DA_ServerRules') 'server'

	$UnavailableReport = Join-Path $FixtureRoot 'unavailable-content-report.json'
	$UnavailableOutput = Join-Path $FixtureRoot 'unavailable-cook-evidence.json'
	$UnavailableAssets = @((Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json).assets)
	$UnavailableFamily = $UnavailableAssets[0].family_results[0]
	$UnavailableFamily.check_results[0].deterministic_status = 'evidence_unavailable'
	$UnavailableFamily.check_results[0].promotion_status = 'non_promotion'
	$UnavailableFamily.deterministic_status = 'evidence_unavailable'
	$UnavailableFamily.promotion_status = 'non_promotion'
	Write-PolicyOutcomeReport $UnavailableReport $UnavailableAssets $PolicyPath
	$ActiveReportPath = $UnavailableReport
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2
	Invoke-TestValidator $UnavailableReport $Client $Server $UnavailableOutput
	$UnavailableEvidence = Get-Content -LiteralPath $UnavailableOutput -Raw | ConvertFrom-Json
	Assert-True ($UnavailableEvidence.result -ceq 'non_promotion' -and $UnavailableEvidence.inputs.content_validation_report.result -ceq 'non_promotion') 'Unavailable check evidence must permit cook comparison while preserving non-promotion.'
	Assert-True ($UnavailableEvidence.inputs.content_validation_report.sha256 -ceq (Get-FileHash -LiteralPath $UnavailableReport -Algorithm SHA256).Hash.ToLowerInvariant()) 'Unavailable evidence must retain the exact source report hash.'
	Write-Output 'PASS: evidence_unavailable aggregates before passed and retains non-promotion through cook comparison'

	# The live scanner cannot bind navigation observations to governed navigation
	# packages or exact cook evidence, so navigation audience stays unavailable.
	$NavigationReport = Join-Path $FixtureRoot 'navigation-unavailable-content-report.json'
	$NavigationOutput = Join-Path $FixtureRoot 'navigation-unavailable-cook-evidence.json'
	$NavigationAssets = @((Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json).assets)
	$NavigationFamily = @($NavigationAssets[0].family_results | Where-Object { $_.policy_id -ceq 'navigation' })[0]
	$NavigationCheck = @($NavigationFamily.check_results | Where-Object { $_.check_id -ceq 'navigation_data_audience' })[0]
	Assert-True ($null -ne $NavigationCheck -and $NavigationCheck.applicability -ceq 'applicable') 'The navigation audience fixture must start from an applicable check.'
	$NavigationCheck.deterministic_status = 'evidence_unavailable'
	$NavigationCheck.promotion_status = 'non_promotion'
	$NavigationFamily.deterministic_status = 'evidence_unavailable'
	$NavigationFamily.promotion_status = 'non_promotion'
	Write-PolicyOutcomeReport $NavigationReport $NavigationAssets $PolicyPath
	$ActiveReportPath = $NavigationReport
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2
	Invoke-TestValidator $NavigationReport $Client $Server $NavigationOutput
	$NavigationEvidence = Get-Content -LiteralPath $NavigationOutput -Raw | ConvertFrom-Json
	Assert-True ($NavigationEvidence.result -ceq 'non_promotion' -and $NavigationEvidence.inputs.content_validation_report.result -ceq 'non_promotion') 'Unavailable navigation audience evidence must keep cook evidence non-promotion.'
	$ForgedNavigation = Get-Content -LiteralPath $NavigationReport -Raw | ConvertFrom-Json
	@(@($ForgedNavigation.assets[0].family_results | Where-Object { $_.policy_id -ceq 'navigation' })[0].check_results | Where-Object { $_.check_id -ceq 'navigation_data_audience' })[0].promotion_status = 'eligible'
	$ForgedNavigationReport = Join-Path $FixtureRoot 'navigation-unavailable-eligible-report.json'
	$ForgedNavigation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ForgedNavigationReport -Encoding UTF8
	$ActiveReportPath = $ForgedNavigationReport
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ForgedNavigationReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'navigation\.navigation_data_audience.*unavailable evidence must be non_promotion'
	Write-Output 'PASS: unavailable navigation audience evidence stays non-promotion and cannot be forged eligible'

	$UnavailableCases = @(
		@{ Name='unavailable-eligible-check'; Pattern='check.*unavailable evidence must be non_promotion'; Mutate={ param($Value) $Value.assets[0].family_results[0].check_results[0].promotion_status = 'eligible' } }
		@{ Name='unavailable-hidden-as-passed-eligible'; Pattern='check.*unavailable evidence must be non_promotion'; Mutate={ param($Value) $Family = $Value.assets[0].family_results[0]; $Family.check_results[0].promotion_status = 'eligible'; $Family.deterministic_status = 'passed'; $Family.promotion_status = 'eligible'; $Value.findings = @(); $Value.counts.findings = 0; $Value.counts.non_promotion = 0; $Value.result = 'passed' } }
		@{ Name='unavailable-eligible-family'; Pattern='promotion_status does not aggregate'; Mutate={ param($Value) $Value.assets[0].family_results[0].promotion_status = 'eligible' } }
		@{ Name='unavailable-misaggregated-passed'; Pattern='deterministic_status does not aggregate'; Mutate={ param($Value) $Value.assets[0].family_results[0].deterministic_status = 'passed' } }
		@{ Name='unavailable-misaggregated-failed'; Pattern='deterministic_status does not aggregate'; Mutate={ param($Value) $Value.assets[0].family_results[0].deterministic_status = 'failed' } }
		@{ Name='unavailable-report-passed'; Pattern='result passed is inconsistent'; Mutate={ param($Value) $Value.result = 'passed' } }
		@{ Name='unavailable-report-failed'; Pattern='result failed.*without a correlated deterministic error'; Mutate={ param($Value) $Value.result = 'failed' } }
		@{ Name='unavailable-missing-finding'; Pattern='status.*non_promotion.*exactly one correlated finding'; Mutate={ param($Value) $Value.findings = @(); $Value.counts.findings = 0; $Value.counts.non_promotion = 0 } }
		@{ Name='unavailable-wrong-count'; Pattern='non-promotion count is inconsistent'; Mutate={ param($Value) $Value.counts.non_promotion = 0 } }
		@{ Name='failed-eligible-check'; Pattern='failed check.*must be non_promotion'; Mutate={ param($Value) $Family = $Value.assets[0].family_results[0]; $Family.check_results[0].deterministic_status = 'failed'; $Family.check_results[0].promotion_status = 'eligible'; $Family.deterministic_status = 'failed' } }
	)
	foreach ($Case in $UnavailableCases) {
		$CaseReport = Join-Path $FixtureRoot ($Case.Name + '.json')
		$CaseOutput = Join-Path $FixtureRoot ($Case.Name + '-output.json')
		$CaseValue = Get-Content -LiteralPath $UnavailableReport -Raw | ConvertFrom-Json
		& $Case.Mutate $CaseValue
		$CaseValue | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $CaseReport -Encoding UTF8
		$ActiveReportPath = $CaseReport
		Write-InventoryManifest $Client 2
		Write-InventoryManifest $Server 2
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$CaseReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$CaseOutput } $Case.Pattern
		Assert-True (-not (Test-Path -LiteralPath $CaseOutput)) "Invalid unavailable-evidence case '$($Case.Name)' must not publish cook evidence."
		Write-Output "PASS: $($Case.Name) fails closed before cook evidence publication"
	}
	$FailedUnavailableFamily = $UnavailableAssets[0].family_results[0]
	Assert-True (@($FailedUnavailableFamily.check_results).Count -gt 1) 'Failure precedence requires distinct failed and unavailable checks.'
	$FailedUnavailableFamily.check_results[1].deterministic_status = 'failed'
	$FailedUnavailableFamily.check_results[1].promotion_status = 'non_promotion'
	$FailedUnavailableFamily.deterministic_status = 'failed'
	$FailedUnavailableReport = Join-Path $FixtureRoot 'failed-and-unavailable-report.json'
	Write-PolicyOutcomeReport $FailedUnavailableReport $UnavailableAssets $PolicyPath
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$FailedUnavailableReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'contains deterministic validation errors'
	$FailedUnavailableFamily.deterministic_status = 'evidence_unavailable'
	Write-PolicyOutcomeReport $FailedUnavailableReport $UnavailableAssets $PolicyPath
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$FailedUnavailableReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'deterministic_status does not aggregate'
	Write-Output 'PASS: failed checks take precedence over unavailable and passed checks'
	$ActiveReportPath = $Report
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2

	$GovernedReport = Join-Path $FixtureRoot 'governed-content-report.json'
	$GovernedOutput = Join-Path $FixtureRoot 'governed-cook-evidence.json'
	$GovernedAssets = @(
		New-PolicyOutcomeAsset '/Game/Shared/DA_Objective' 'content.objective' 'shared' $GovernedPolicyPath
		New-PolicyOutcomeAsset '/Game/Server/DA_ServerRules' 'content.server_rules' 'server_only' $GovernedPolicyPath
		New-PolicyOutcomeAsset '/Game/UI/WBP_HUD' 'content.hud' 'client_only' $GovernedPolicyPath
	)
	Write-PolicyOutcomeReport $GovernedReport $GovernedAssets $GovernedPolicyPath
	$ActiveReportPath = $GovernedReport
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2
	Invoke-TestValidator $GovernedReport $Client $Server $GovernedOutput $GovernedPolicyPath
	$GovernedEvidence = Get-Content -LiteralPath $GovernedOutput -Raw | ConvertFrom-Json
	Assert-True ($GovernedEvidence.result -ceq 'non_promotion') 'Successful cook-boundary comparison must preserve the governed report non-promotion result.'
	Assert-True ($GovernedEvidence.inputs.content_validation_report.result -ceq 'non_promotion') 'Cook evidence must record the governed source report result.'
	Assert-True ([int]$GovernedEvidence.counts.assets -eq 3 -and [int]$GovernedEvidence.counts.findings -eq 0) 'Governed non-promotion evidence must still report the successful deterministic comparison counts.'
	Write-Output 'PASS: governed all-TBD policy permits deterministic cook comparison without promotion'
	$ActiveReportPath = $Report
	Write-InventoryManifest $Client 2
	Write-InventoryManifest $Server 2

	$WrongFindingCodeReport = Join-Path $FixtureRoot 'wrong-finding-code-report.json'
	$WrongFindingCode = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$WrongFindingCode.findings[0].code = 'content.texture.non_promotion'
	$WrongFindingCode | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WrongFindingCodeReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$WrongFindingCodeReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'finding code.*does not match policy family' $Validator

	$OrphanFindingReport = Join-Path $FixtureRoot 'orphan-finding-report.json'
	$OrphanFinding = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$OrphanFinding.findings[0].asset_path = '/Game/Other/DA_NotReported'
	$OrphanFinding | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OrphanFindingReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$OrphanFindingReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'does not identify one reported asset family' $Validator

	$MissingFindingReport = Join-Path $FixtureRoot 'missing-correlated-finding-report.json'
	$MissingFinding = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$MissingFinding.findings = @($MissingFinding.findings | Select-Object -Skip 1)
	$MissingFinding.counts.findings = @($MissingFinding.findings).Count
	$MissingFinding.counts.non_promotion = @($MissingFinding.findings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
	$MissingFinding | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $MissingFindingReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$MissingFindingReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'status.*non_promotion.*exactly one correlated finding' $Validator

	$DuplicateFindingReport = Join-Path $FixtureRoot 'duplicate-correlated-finding-report.json'
	$DuplicateFinding = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$DuplicateFinding.findings = @($DuplicateFinding.findings) + @($DuplicateFinding.findings[0])
	$DuplicateFinding.counts.findings = @($DuplicateFinding.findings).Count
	$DuplicateFinding.counts.non_promotion = @($DuplicateFinding.findings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
	$DuplicateFinding | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DuplicateFindingReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$DuplicateFindingReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'status.*non_promotion.*exactly one correlated finding' $Validator

	$FindingCountMismatchReport = Join-Path $FixtureRoot 'finding-count-mismatch-report.json'
	$FindingCountMismatch = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$FindingCountMismatch.counts.findings++
	$FindingCountMismatch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $FindingCountMismatchReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$FindingCountMismatchReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'finding count.*does not match' $Validator

	$DeterministicErrorReport = Join-Path $FixtureRoot 'deterministic-error-report.json'
	$DeterministicError = Get-Content -LiteralPath $GovernedReport -Raw | ConvertFrom-Json
	$DeterministicError.assets[0].family_results[0].deterministic_status = 'failed'
	$DeterministicError.assets[0].family_results[0].check_results[0].deterministic_status = 'failed'
	$DeterministicError.assets[0].family_results[0].check_results[0].promotion_status = 'non_promotion'
	$DeterministicError.findings[0].severity = 'error'
	$DeterministicError.findings[0].code = 'content.collision.failed'
	$DeterministicError.counts.errors = 1
	$DeterministicError.counts.non_promotion--
	$DeterministicError.result = 'failed'
	$DeterministicError | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DeterministicErrorReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$DeterministicErrorReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'contains deterministic validation errors' $Validator
	Write-Output 'PASS: governed findings, correlations, counts, and deterministic errors fail closed'

	Invoke-TestValidator $Report $Client $Server $Output
	$Evidence = Get-Content -LiteralPath $Output -Raw | ConvertFrom-Json
	Assert-True ($Evidence.schema_id -eq 'aetheln.content-cook-evidence' -and [int]$Evidence.schema_version -eq 3) 'Cook evidence must be versioned.'
	Assert-True ($Evidence.revision -eq $FixtureRevision -and $Evidence.result -eq 'passed') 'Passing evidence must retain the source revision.'
	Assert-True ([int]$Evidence.counts.assets -eq 3 -and [int]$Evidence.counts.findings -eq 0) 'Passing evidence must report exact counts.'
	Assert-True ([string]$Evidence.inputs.content_validation_report.sha256 -match '^[0-9a-f]{64}$') 'Cook evidence must bind the source report hash.'
	Assert-True (@($Evidence.inputs.client_inventory.pages).Count -eq 1 -and [string]$Evidence.inputs.client_inventory.pages[0].sha256 -match '^[0-9a-f]{64}$') 'Cook evidence must bind client inventory page hashes.'
	Assert-True (@($Evidence.inputs.server_inventory.pages).Count -eq 1 -and [string]$Evidence.inputs.server_inventory.pages[0].sha256 -match '^[0-9a-f]{64}$') 'Cook evidence must bind server inventory page hashes.'
	Assert-True ([string]$Evidence.intake_sha256 -ceq (Get-FileHash -LiteralPath $RuntimeIntakePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Cook evidence must bind the closed runtime intake registry.'
	Assert-True ([string]$Evidence.inputs.build_provenance.sha256 -ceq (Get-FileHash -LiteralPath $BuildProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Cook evidence must bind exact build provenance bytes.'
	Assert-True ([string]$Evidence.inputs.client_inventory.manifest_sha256 -match '^[0-9a-f]{64}$' -and [string]$Evidence.inputs.server_inventory.manifest_sha256 -match '^[0-9a-f]{64}$') 'Cook evidence must bind both target manifests.'
	Assert-True ([string]$Evidence.inputs.client_inventory.cooked_registry.sha256 -ceq (Get-FileHash -LiteralPath (Join-Path $Client 'AssetRegistry.bin') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Cook evidence must bind the exact staged client registry bytes.'
	Assert-True ([string]$Evidence.inputs.server_inventory.cooked_registry.sha256 -ceq (Get-FileHash -LiteralPath (Join-Path $Server 'AssetRegistry.bin') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Cook evidence must bind the exact staged server registry bytes.'
	Assert-True ($Evidence.inputs.client_inventory.cooked_registry.target -ceq 'AethelnOnlineClient' -and $Evidence.inputs.client_inventory.cooked_registry.platform -ceq 'Win64' -and $Evidence.inputs.client_inventory.cooked_registry.cook_platform -ceq 'WindowsClient') 'Cook evidence must retain client target, platform, and cook-platform provenance.'
	Assert-True ($Evidence.inputs.server_inventory.cooked_registry.target -ceq 'AethelnOnlineServer' -and $Evidence.inputs.server_inventory.cooked_registry.platform -ceq 'Linux' -and $Evidence.inputs.server_inventory.cooked_registry.cook_platform -ceq 'LinuxServer') 'Cook evidence must retain server target, platform, and cook-platform provenance.'
	Write-Output 'PASS: shared, server-only, and client-only packages are separated'

	$ReportV2 = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$ExpectedExecutionFields = @('repository_clean','engine_revision','engine_tag','engine_binary_sha256','build_version_sha256','target','platform','configuration','editor_build_command_sha256','editor_build_log_sha256','compiler_version','compiler_sha256','resource_compiler_version','resource_compiler_sha256','target_receipt','module_manifest','loaded_project_modules','project_sha256','policy_sha256','intake_sha256','invocation_sha256','registry_source')
	Assert-True ([int]$ReportV2.schema_version -eq 2 -and (($ReportV2.execution_provenance.PSObject.Properties.Name -join ',') -ceq ($ExpectedExecutionFields -join ','))) 'The cook comparator fixture must exercise the exact ordered report-v2 execution provenance contract.'
	Assert-True (($ReportV2.execution_provenance.target_receipt.PSObject.Properties.Name -join ',') -ceq 'path,size_bytes,sha256,build_id' -and ($ReportV2.execution_provenance.module_manifest.PSObject.Properties.Name -join ',') -ceq 'path,size_bytes,sha256,build_id') 'Receipt and manifest provenance must use closed artifact descriptors.'
	Assert-True (@($ReportV2.execution_provenance.loaded_project_modules).Count -eq 2 -and $ReportV2.execution_provenance.loaded_project_modules[0].name -ceq 'GameCore' -and $ReportV2.execution_provenance.loaded_project_modules[1].name -ceq 'GameTests') 'Loaded module provenance must be exactly GameCore then GameTests.'
	Assert-True ($ReportV2.execution_provenance.target_receipt.build_id -ceq $ReportV2.execution_provenance.module_manifest.build_id -and $ReportV2.execution_provenance.target_receipt.build_id -ceq $ReportV2.execution_provenance.loaded_project_modules[0].build_id -and $ReportV2.execution_provenance.target_receipt.build_id -ceq $ReportV2.execution_provenance.loaded_project_modules[1].build_id) 'All Editor artifacts must share one build ID.'

	$ReceiptExtraReport = Join-Path $FixtureRoot 'receipt-extra-report.json'
	$ReceiptExtra = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$ReceiptExtra.execution_provenance.target_receipt | Add-Member -NotePropertyName ungoverned -NotePropertyValue $true
	$ReceiptExtra | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReceiptExtraReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ReceiptExtraReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'target_receipt contains unsupported field' $Validator
	$WrongModuleOrderReport = Join-Path $FixtureRoot 'wrong-module-order-report.json'
	$WrongModuleOrder = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$WrongModuleOrder.execution_provenance.loaded_project_modules = @($WrongModuleOrder.execution_provenance.loaded_project_modules[1], $WrongModuleOrder.execution_provenance.loaded_project_modules[0])
	$WrongModuleOrder | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $WrongModuleOrderReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$WrongModuleOrderReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'loaded project module 0 name mismatch' $Validator
	$WrongBuildIdReport = Join-Path $FixtureRoot 'wrong-editor-build-id-report.json'
	$WrongBuildId = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$WrongBuildId.execution_provenance.loaded_project_modules[1].build_id = 'different-build-id'
	$WrongBuildId | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $WrongBuildIdReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$WrongBuildIdReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'must share one non-blank build_id' $Validator
	$WrongEditorHashReport = Join-Path $FixtureRoot 'wrong-editor-build-hash-report.json'
	$WrongEditorHash = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$WrongEditorHash.execution_provenance.editor_build_log_sha256 = ('A' * 64)
	$WrongEditorHash | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $WrongEditorHashReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$WrongEditorHashReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'editor_build_log_sha256.*lowercase SHA-256' $Validator
	$MissingCompilerVersionReport = Join-Path $FixtureRoot 'missing-compiler-version-report.json'
	$MissingCompilerVersion = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$MissingCompilerVersion.execution_provenance.compiler_version = ''
	$MissingCompilerVersion | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $MissingCompilerVersionReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$MissingCompilerVersionReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'compiler_version.*non-blank string' $Validator
	Write-Output 'PASS: full report-v2 Editor build, receipt, manifest, and module provenance fails closed on drift'

	$UnregisteredClient = Join-Path $FixtureRoot 'unregistered-client'
	Write-Inventory $UnregisteredClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD', '/Game/Unregistered/DA_Unexpected') 'client'
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$UnregisteredClient; ServerCookedInventoryDirectory=$Server } 'Unregistered.*absent from the closed runtime intake registry'
	Write-Output 'PASS: every cooked /Game package requires a closed intake record'

	$EnginePackageClient = Join-Path $FixtureRoot 'engine-package-client'
	Write-Inventory $EnginePackageClient @('/Engine/EngineMaterials/DefaultMaterial', '/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	Invoke-TestValidator $Report $EnginePackageClient $Server $null
	Write-Output 'PASS: engine packages remain outside the /Game intake boundary'

	$MissingRegistryAssetReport = Join-Path $FixtureRoot 'missing-registry-asset-report.json'
	Write-Report $MissingRegistryAssetReport @($Assets[0], $Assets[1])
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$MissingRegistryAssetReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'exactly every runtime intake registry asset'
	$MismatchedRegistryAssetReport = Join-Path $FixtureRoot 'mismatched-registry-asset-report.json'
	Write-Report $MismatchedRegistryAssetReport $Assets
	$MismatchedRegistryAsset = Get-Content -LiteralPath $MismatchedRegistryAssetReport -Raw | ConvertFrom-Json
	$MismatchedRegistryAsset.assets[0].provenance.content_sha256 = ('7' * 64)
	$MismatchedRegistryAsset | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $MismatchedRegistryAssetReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$MismatchedRegistryAssetReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'content_sha256 mismatch'
	$MismatchedLifecycleReport = Join-Path $FixtureRoot 'mismatched-lifecycle-report.json'
	Write-Report $MismatchedLifecycleReport $Assets
	$MismatchedLifecycle = Get-Content -LiteralPath $MismatchedLifecycleReport -Raw | ConvertFrom-Json
	$MismatchedLifecycle.assets[0].lifecycle_evidence.runtime_candidate[0].reviewer = 'Different reviewer'
	$MismatchedLifecycle | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $MismatchedLifecycleReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$MismatchedLifecycleReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'lifecycle_evidence.*does not match the intake'
	Write-Output 'PASS: report completeness, content hashes, and lifecycle evidence bind exactly to intake'
	foreach ($State in @('temporary_prototype','runtime_candidate','production_approved')) { Invoke-LifecycleFixture $State $State $null '' }
	$LifecycleCases = @(
		@{ name='legacy-intake'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].PSObject.Properties.Remove('lifecycle_evidence'); $IntakeValue.assets[0] | Add-Member -NotePropertyName temporary_owner -NotePropertyValue 'legacy' }; pattern='Runtime asset intake asset.*unsupported field.*temporary_owner' },
		@{ name='legacy-report'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $ReportAssets[0].lifecycle_evidence = [ordered]@{ owner='legacy'; approval_record='legacy'; recovery_trigger='legacy'; may_be_runtime_candidate=$true } }; pattern='lifecycle_evidence.*unsupported field.*owner' },
		@{ name='missing-field'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.Remove('production_approval') }; pattern='lifecycle_evidence.*missing required field.*production_approval' },
		@{ name='extra-nested-field'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.content_identity.extra = 'unexpected' }; pattern='content_identity.*unsupported field.*extra' },
		@{ name='scalar-array'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate = $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0] }; pattern='runtime_candidate must be a JSON array' },
		@{ name='duplicate-candidate'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate += $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0] }; pattern='runtime_candidate.*at most one' },
		@{ name='wrong-identity'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.content_identity.stable_id = 'content.other' }; pattern='content_identity.stable_id mismatch' },
		@{ name='wrong-hash'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0].content_sha256 = ('2' * 64) }; pattern='runtime_candidate.*content_sha256 mismatch' },
		@{ name='wrong-version'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0].content_version = 2 }; pattern='runtime_candidate.*content_version mismatch' },
		@{ name='string-version'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.content_identity.content_version = '1' }; pattern='content_identity.content_version.*positive JSON integer' },
		@{ name='blank-reviewer'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0].reviewer = ' ' }; pattern='runtime_candidate.*reviewer.*non-blank string' },
		@{ name='bad-review-revision'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate[0].review_revision = ('A' * 40) }; pattern='runtime_candidate.*review_revision.*lowercase.*revision' },
		@{ name='missing-candidate'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.runtime_candidate = @() }; pattern='requires runtime-candidate evidence' },
		@{ name='temporary-source-for-candidate'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.source_groups[0].approval_state = 'temporary_prototype_only' }; pattern='runtime-candidate evidence conflicts with source approval' },
		@{ name='temporary-promotion'; state='temporary_prototype'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.temporary_prototype[0].may_be_runtime_candidate = $true }; pattern='temporary evidence cannot be promotion-capable' },
		@{ name='temporary-string-boolean'; state='temporary_prototype'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.temporary_prototype[0].may_be_runtime_candidate = 'false' }; pattern='may_be_runtime_candidate must be a JSON boolean' },
		@{ name='production-candidate-revision'; state='production_approved'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.production_approval[0].candidate_review_revision = ('8' * 40) }; pattern='production_approval.*candidate_review_revision mismatch' },
		@{ name='production-candidate-approval'; state='production_approved'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.production_approval[0].candidate_approval_record = 'other approval' }; pattern='production_approval.*candidate_approval_record mismatch' },
		@{ name='report-identity'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $ReportAssets[0].lifecycle_evidence.content_identity.stable_id = 'content.other' }; pattern='content_identity.stable_id mismatch' },
		@{ name='report-approval'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $ReportAssets[0].lifecycle_evidence.runtime_candidate[0].approval_record = 'other approval' }; pattern='lifecycle_evidence.*does not match the intake' },
		@{ name='concept-with-production-evidence'; state='production_approved'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_state = 'concept_reference'; $ReportAssets[0].lifecycle_state = 'concept_reference' }; pattern='lifecycle_evidence.*unsupported runtime lifecycle_state.*concept_reference' },
		@{ name='matching-miscased-identity'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) $IntakeValue.assets[0].lifecycle_evidence.content_identity = [ordered]@{ Stable_id='content.objective'; content_version=1; content_sha256=('1' * 64) }; $ReportAssets[0].lifecycle_evidence.content_identity = [ordered]@{ Stable_id='content.objective'; content_version=1; content_sha256=('1' * 64) } }; pattern='content_identity.*unsupported field.*Stable_id' },
		@{ name='intake-wrapper-casing'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) Set-FixtureLifecycleWrapperCasing $IntakeValue.assets[0] }; pattern='Runtime asset intake asset.*requires exact field.*lifecycle_evidence' },
		@{ name='report-wrapper-casing'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) Set-FixtureLifecycleWrapperCasing $ReportAssets[0] }; pattern='Content validation asset.*requires exact field.*lifecycle_evidence' },
		@{ name='matching-wrapper-casing'; state='runtime_candidate'; mutation={ param($IntakeValue, $ReportAssets) Set-FixtureLifecycleWrapperCasing $IntakeValue.assets[0]; Set-FixtureLifecycleWrapperCasing $ReportAssets[0] }; pattern='Runtime asset intake asset.*requires exact field.*lifecycle_evidence' }
	)
	$LifecycleFailures = [Collections.Generic.List[string]]::new()
	foreach ($Case in $LifecycleCases) {
		try { Invoke-LifecycleFixture $Case.name $Case.state $Case.mutation $Case.pattern }
		catch { $LifecycleFailures.Add("$($Case.name): $($_.Exception.Message)") }
	}
	Assert-True ($LifecycleFailures.Count -eq 0) ("Lifecycle regression failures:`n" + ($LifecycleFailures -join "`n"))

	$TamperedPageManifestClient = Join-Path $FixtureRoot 'tampered-page-manifest-client'
	Write-Inventory $TamperedPageManifestClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$TamperedPageManifestPath = Join-Path $TamperedPageManifestClient 'inventory-manifest.json'
	$TamperedPageManifest = Get-Content -LiteralPath $TamperedPageManifestPath -Raw | ConvertFrom-Json
	$TamperedPageManifest.pages[0].sha256 = ('8' * 64)
	$TamperedPageManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $TamperedPageManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$TamperedPageManifestClient; ServerCookedInventoryDirectory=$Server } 'page.*digest mismatch'

	$WrongTargetClient = Join-Path $FixtureRoot 'wrong-target-client'
	Write-Inventory $WrongTargetClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$WrongTargetManifestPath = Join-Path $WrongTargetClient 'inventory-manifest.json'
	$WrongTargetManifest = Get-Content -LiteralPath $WrongTargetManifestPath -Raw | ConvertFrom-Json
	$WrongTargetManifest.target = 'AethelnOnlineServer'
	$WrongTargetManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WrongTargetManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$WrongTargetClient; ServerCookedInventoryDirectory=$Server } 'Client manifest target mismatch'

	$WrongCookPlatformClient = Join-Path $FixtureRoot 'wrong-cook-platform-client'
	Write-Inventory $WrongCookPlatformClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$WrongCookPlatformManifestPath = Join-Path $WrongCookPlatformClient 'inventory-manifest.json'
	$WrongCookPlatformManifest = Get-Content -LiteralPath $WrongCookPlatformManifestPath -Raw | ConvertFrom-Json
	$WrongCookPlatformManifest.cooked_registry.cook_platform = 'LinuxServer'
	$WrongCookPlatformManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WrongCookPlatformManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$WrongCookPlatformClient; ServerCookedInventoryDirectory=$Server } 'Client manifest cooked_registry\.cook_platform mismatch'

	$WrongRegistryBuildClient = Join-Path $FixtureRoot 'wrong-registry-build-client'
	Write-Inventory $WrongRegistryBuildClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$WrongRegistryBuildManifestPath = Join-Path $WrongRegistryBuildClient 'inventory-manifest.json'
	$WrongRegistryBuildManifest = Get-Content -LiteralPath $WrongRegistryBuildManifestPath -Raw | ConvertFrom-Json
	$WrongRegistryBuildManifest.cooked_registry.build_provenance_sha256 = ('9' * 64)
	$WrongRegistryBuildManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WrongRegistryBuildManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$WrongRegistryBuildClient; ServerCookedInventoryDirectory=$Server } 'Client manifest cooked_registry\.build_provenance_sha256 mismatch'

	$TamperedStagedRegistryClient = Join-Path $FixtureRoot 'tampered-staged-registry-client'
	Write-Inventory $TamperedStagedRegistryClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	Add-Content -LiteralPath (Join-Path $TamperedStagedRegistryClient 'AssetRegistry.bin') -Value 'tampered bytes' -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$TamperedStagedRegistryClient; ServerCookedInventoryDirectory=$Server } 'Client manifest cooked_registry\.(?:size_bytes|sha256) mismatch'

	$ZeroRegistrySizeClient = Join-Path $FixtureRoot 'zero-registry-size-client'
	Write-Inventory $ZeroRegistrySizeClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$ZeroRegistrySizeManifestPath = Join-Path $ZeroRegistrySizeClient 'inventory-manifest.json'
	$ZeroRegistrySizeManifest = Get-Content -LiteralPath $ZeroRegistrySizeManifestPath -Raw | ConvertFrom-Json
	$ZeroRegistrySizeManifest.cooked_registry.size_bytes = 0
	$ZeroRegistrySizeManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ZeroRegistrySizeManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$ZeroRegistrySizeClient; ServerCookedInventoryDirectory=$Server } 'cooked_registry\.size_bytes must be a positive JSON integer'

	$MissingStagedRegistryClient = Join-Path $FixtureRoot 'missing-staged-registry-client'
	Write-Inventory $MissingStagedRegistryClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	Remove-Item -LiteralPath (Join-Path $MissingStagedRegistryClient 'AssetRegistry.bin') -Force
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$MissingStagedRegistryClient; ServerCookedInventoryDirectory=$Server } 'staged cooked registry.*missing'

	$ExtraFieldClient = Join-Path $FixtureRoot 'extra-field-client'
	Write-Inventory $ExtraFieldClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD') 'client'
	$ExtraFieldManifestPath = Join-Path $ExtraFieldClient 'inventory-manifest.json'
	$ExtraFieldManifest = Get-Content -LiteralPath $ExtraFieldManifestPath -Raw | ConvertFrom-Json
	$ExtraFieldManifest | Add-Member -NotePropertyName ungoverned -NotePropertyValue $true
	$ExtraFieldManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ExtraFieldManifestPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$ExtraFieldClient; ServerCookedInventoryDirectory=$Server } 'unsupported field.*ungoverned'
	Write-Output 'PASS: page, staged-registry, target, cook-platform, build, and closed manifest provenance fail closed'

	$DirtyBuildPath = Join-Path $FixtureRoot 'dirty-build-provenance.json'
	$DirtyBuild = Get-Content -LiteralPath $BuildProvenancePath -Raw | ConvertFrom-Json
	$DirtyBuild.source.clean = $false
	$DirtyBuild | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DirtyBuildPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; BuildProvenancePath=$DirtyBuildPath } 'clean source tree'
	$WrongRevisionBuildPath = Join-Path $FixtureRoot 'wrong-revision-build-provenance.json'
	$WrongRevisionBuild = Get-Content -LiteralPath $BuildProvenancePath -Raw | ConvertFrom-Json
	$WrongRevisionBuild.source.revision = ('9' * 40)
	$WrongRevisionBuild | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $WrongRevisionBuildPath -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; BuildProvenancePath=$WrongRevisionBuildPath } 'source revision mismatch'
	Write-Output 'PASS: dirty or cross-revision build provenance cannot back cook evidence'

	foreach ($ReceiptCase in @(
		@{ name='missing'; mutate={ param($Build) $Build.build.PSObject.Properties.Remove('cookedRegistries') }; pattern='cookedRegistries' },
		@{ name='cross-target'; mutate={ param($Build) $Build.build.cookedRegistries.client.cookPlatform = 'LinuxServer' }; pattern='client producer registry receipt cookPlatform' },
		@{ name='cross-revision'; mutate={ param($Build) $Build.build.cookedRegistries.client.sourceRevision = ('9' * 40) }; pattern='client producer registry receipt sourceRevision' },
		@{ name='extra-field'; mutate={ param($Build) $Build.build.cookedRegistries.client | Add-Member -NotePropertyName stale -NotePropertyValue $true }; pattern="client producer registry receipt contains unsupported field 'stale'" }
	)) {
		$ReceiptBuildPath = Join-Path $FixtureRoot "receipt-$($ReceiptCase.name)-build-provenance.json"
		$ReceiptBuild = Get-Content -LiteralPath $BuildProvenancePath -Raw | ConvertFrom-Json
		& $ReceiptCase.mutate $ReceiptBuild
		$ReceiptBuild | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReceiptBuildPath -Encoding UTF8
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; BuildProvenancePath=$ReceiptBuildPath } ([string]$ReceiptCase.pattern)
	}
	$SubstitutedClient = Join-Path $FixtureRoot 'substituted-registry-client'
	Copy-Item -LiteralPath $Client -Destination $SubstitutedClient -Recurse
	Set-Content -LiteralPath (Join-Path $SubstitutedClient 'AssetRegistry.bin') -Value 'stale or substituted client registry' -Encoding UTF8
	$PreviousActiveReportPath = $ActiveReportPath
	$ActiveReportPath = $Report
	try { Write-InventoryManifest $SubstitutedClient ([int](Get-Content -LiteralPath (Join-Path $Client 'inventory-manifest.json') -Raw | ConvertFrom-Json).package_count) 'client' }
	finally { $ActiveReportPath = $PreviousActiveReportPath }
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$SubstitutedClient; ServerCookedInventoryDirectory=$Server } 'Client manifest cooked_registry.*producer registry receipt'
	Write-Output 'PASS: missing, cross-target, cross-revision, and self-consistent substituted registry receipts fail closed'

	$ProductionModeFailure = $null
	try {
		& $Validator -ContentValidationReportPath $Report -ClientCookedInventoryDirectory $Client -ServerCookedInventoryDirectory $Server -PolicyPath $PolicyPath -RuntimeIntakePath $RuntimeIntakePath -BuildProvenancePath $BuildProvenancePath | Out-Null
	}
	catch { $ProductionModeFailure = $_.Exception.Message }
	Assert-True ($ProductionModeFailure -match 'registry_source.*not admissible') 'Test-snapshot content reports must be rejected without the explicit test-evidence gate.'
	Write-Output 'PASS: test evidence cannot be mistaken for live cook evidence'

	$PagedClient = Join-Path $FixtureRoot 'paged-client'
	$PagedOutput = Join-Path $FixtureRoot 'paged-evidence.json'
	Write-Inventory $PagedClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	Split-InventoryIntoTwoPages $PagedClient
	Invoke-TestValidator $Report $PagedClient $Server $PagedOutput
	$PagedEvidence = Get-Content -LiteralPath $PagedOutput -Raw | ConvertFrom-Json
	Assert-True (@($PagedEvidence.inputs.client_inventory.pages).Count -eq 2) 'A valid contiguous multi-page inventory must retain both page hashes.'
	Assert-True ($PagedEvidence.inputs.client_inventory.pages[0].name -ceq 'Page_00000.txt' -and $PagedEvidence.inputs.client_inventory.pages[1].name -ceq 'Page_00001.txt') 'A valid contiguous multi-page inventory must retain its ordered page names.'
	Write-Output 'PASS: contiguous zero-based multi-page inventory is accepted'

	$MultiItemClient = Join-Path $FixtureRoot 'multi-item-client'
	Write-Inventory $MultiItemClient @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$MultiItemPage = Join-Path $MultiItemClient 'Page_00000.txt'
	$MultiItemLines = [System.Collections.Generic.List[string]]::new()
	$OriginalMultiItemLines = @(Get-Content -LiteralPath $MultiItemPage)
	$MultiItemLines.Add($OriginalMultiItemLines[0])
	$MultiItemLines.Add("`t/Game/Shared/DA_Objective : 2 item(s)")
	$MultiItemLines.Add($OriginalMultiItemLines[2])
	$MultiItemLines.Add("`t`t/Game/Shared/DA_Objective.Secondary")
	foreach ($Line in $OriginalMultiItemLines[3..($OriginalMultiItemLines.Count - 1)]) { $MultiItemLines.Add($Line) }
	Set-Content -LiteralPath $MultiItemPage -Value $MultiItemLines -Encoding UTF8
	Write-InventoryManifest $MultiItemClient 2
	Invoke-TestValidator $Report $MultiItemClient $Server $null
	Write-Output 'PASS: multiple package records with exact positive item details are accepted'

	$ZeroItemHeader = Join-Path $FixtureRoot 'zero-item-header'
	Write-Inventory $ZeroItemHeader @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$ZeroItemPage = Join-Path $ZeroItemHeader 'Page_00000.txt'
	$ZeroItemLines = @(Get-Content -LiteralPath $ZeroItemPage)
	$ZeroItemLines[1] = "`t/Game/Shared/DA_Objective : 0 item(s)"
	Set-Content -LiteralPath $ZeroItemPage -Value $ZeroItemLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$ZeroItemHeader; ServerCookedInventoryDirectory=$Server } 'positive item count'
	Write-Output 'PASS: zero-item package headers fail closed'

	$DuplicatePackageHeader = Join-Path $FixtureRoot 'duplicate-package-header'
	Write-Inventory $DuplicatePackageHeader @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$DuplicatePackagePage = Join-Path $DuplicatePackageHeader 'Page_00000.txt'
	$OriginalDuplicateLines = @(Get-Content -LiteralPath $DuplicatePackagePage)
	$DuplicatePackageLines = @(
		$OriginalDuplicateLines[0..2]
		"`t/Game/Shared/DA_Objective : 1 item(s)"
		"`t`t/Game/Shared/DA_Objective.Duplicate"
		$OriginalDuplicateLines[3..($OriginalDuplicateLines.Count - 1)]
	)
	Set-Content -LiteralPath $DuplicatePackagePage -Value $DuplicatePackageLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$DuplicatePackageHeader; ServerCookedInventoryDirectory=$Server } 'duplicate package header.*DA_Objective'
	Write-Output 'PASS: duplicate package headers fail closed'

	$MissingItemDetails = Join-Path $FixtureRoot 'missing-item-details'
	Write-Inventory $MissingItemDetails @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$MissingItemPage = Join-Path $MissingItemDetails 'Page_00000.txt'
	$MissingItemLines = @(Get-Content -LiteralPath $MissingItemPage)
	$MissingItemLines[1] = "`t/Game/Shared/DA_Objective : 999 item(s)"
	Set-Content -LiteralPath $MissingItemPage -Value $MissingItemLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$MissingItemDetails; ServerCookedInventoryDirectory=$Server } 'declares 999 item.*only 1 associated item row'
	Write-Output 'PASS: missing package item-detail rows fail closed'

	$ExtraItemDetails = Join-Path $FixtureRoot 'extra-item-details'
	Write-Inventory $ExtraItemDetails @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$ExtraItemPage = Join-Path $ExtraItemDetails 'Page_00000.txt'
	$OriginalExtraLines = @(Get-Content -LiteralPath $ExtraItemPage)
	$ExtraLines = @(
		$OriginalExtraLines[0..2]
		"`t`t/Game/Shared/DA_Objective.Unclaimed"
		$OriginalExtraLines[3..($OriginalExtraLines.Count - 1)]
	)
	Set-Content -LiteralPath $ExtraItemPage -Value $ExtraLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$ExtraItemDetails; ServerCookedInventoryDirectory=$Server } 'item detail.*without an associated package header'
	Write-Output 'PASS: extra package item-detail rows fail closed'

	$WrongPackageDetail = Join-Path $FixtureRoot 'wrong-package-detail'
	Write-Inventory $WrongPackageDetail @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$WrongPackagePage = Join-Path $WrongPackageDetail 'Page_00000.txt'
	$WrongPackageLines = @(Get-Content -LiteralPath $WrongPackagePage)
	$WrongPackageLines[2] = "`t`t/Game/UI/WBP_HUD.ImpersonatedObjective"
	Set-Content -LiteralPath $WrongPackagePage -Value $WrongPackageLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$WrongPackageDetail; ServerCookedInventoryDirectory=$Server } 'item detail.*does not belong to package.*DA_Objective'
	Write-Output 'PASS: package headers cannot claim another package item as detail evidence'

	$DuplicateSection = Join-Path $FixtureRoot 'duplicate-section'
	Write-Inventory $DuplicateSection @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$DuplicateSectionPage = Join-Path $DuplicateSection 'Page_00000.txt'
	$DuplicateSectionLines = @(Get-Content -LiteralPath $DuplicateSectionPage)
	Add-Content -LiteralPath $DuplicateSectionPage -Value $DuplicateSectionLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$DuplicateSection; ServerCookedInventoryDirectory=$Server } 'exactly one.*section'
	Write-Output 'PASS: duplicate inventory section fails closed'

	$TrailingStalePage = Join-Path $FixtureRoot 'trailing-stale-page'
	Write-Inventory $TrailingStalePage @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	Set-Content -LiteralPath (Join-Path $TrailingStalePage 'Page_00001.txt') -Value 'stale inventory data' -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$TrailingStalePage; ServerCookedInventoryDirectory=$Server } 'nonblank data after.*end'
	Write-Output 'PASS: trailing stale inventory page fails closed'

	$MissingMiddlePage = Join-Path $FixtureRoot 'missing-middle-page'
	Write-Inventory $MissingMiddlePage @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	Split-InventoryIntoTwoPages $MissingMiddlePage
	Move-Item -LiteralPath (Join-Path $MissingMiddlePage 'Page_00001.txt') -Destination (Join-Path $MissingMiddlePage 'Page_00002.txt')
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$MissingMiddlePage; ServerCookedInventoryDirectory=$Server } 'page sequence.*Page_00001\.txt.*Page_00002\.txt'
	Write-Output 'PASS: missing middle inventory page fails closed'

	$DeclaredCountMismatch = Join-Path $FixtureRoot 'declared-count-mismatch'
	Write-Inventory $DeclaredCountMismatch @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD')
	$MismatchPage = Join-Path $DeclaredCountMismatch 'Page_00000.txt'
	$MismatchLines = @(Get-Content -LiteralPath $MismatchPage)
	$MismatchLines[$MismatchLines.Count - 1] = '--- End CachedAssetsByPackageName : 3 entries ---'
	Set-Content -LiteralPath $MismatchPage -Value $MismatchLines -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$DeclaredCountMismatch; ServerCookedInventoryDirectory=$Server } 'declares 3 entries.*parsed 2 unique package'
	Write-Output 'PASS: declared entry count mismatch fails closed'

	$MissingShared = Join-Path $FixtureRoot 'missing-shared-server'
	Write-Inventory $MissingShared @('/Game/Server/DA_ServerRules')
	$MissingSharedOutput = Join-Path $FixtureRoot 'missing-shared-evidence.json'
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$MissingShared; OutputPath=$MissingSharedOutput } 'shared.*DA_Objective.*server'
	$MissingSharedEvidence = Get-Content -LiteralPath $MissingSharedOutput -Raw | ConvertFrom-Json
	Assert-True ($MissingSharedEvidence.result -eq 'failed' -and @($MissingSharedEvidence.findings).Count -eq 1) 'A cook boundary failure must still emit machine-readable evidence.'
	Assert-True ($MissingSharedEvidence.findings[0].code -eq 'content.reference_boundary.failed' -and $MissingSharedEvidence.findings[0].severity -eq 'error') 'A cook boundary failure must use the stable reference-boundary diagnostic.'
	Write-Output 'PASS: failing cook boundary emits actionable machine-readable evidence'

	$ClientLeak = Join-Path $FixtureRoot 'client-leak-server'
	Write-Inventory $ClientLeak @('/Game/Shared/DA_Objective', '/Game/Server/DA_ServerRules', '/Game/UI/WBP_HUD')
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$ClientLeak } 'client_only.*WBP_HUD.*server'

	$ServerLeak = Join-Path $FixtureRoot 'server-leak-client'
	Write-Inventory $ServerLeak @('/Game/Shared/DA_Objective', '/Game/UI/WBP_HUD', '/Game/Server/DA_ServerRules') 'client'
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$ServerLeak; ServerCookedInventoryDirectory=$Server } 'server_only.*DA_ServerRules.*client'

	$FailedReport = Join-Path $FixtureRoot 'failed-report.json'
	Write-Report $FailedReport $Assets 'failed'
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$FailedReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'result failed.*without a correlated deterministic error'

	$DuplicateReport = Join-Path $FixtureRoot 'duplicate-report.json'
	Write-Report $DuplicateReport @($Assets[0], (New-GovernedAsset '/Game/Other/DA_Other' 'content.objective' 'shared'))
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$DuplicateReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'duplicate stable_id'

	$DuplicateAssetPathReport = Join-Path $FixtureRoot 'duplicate-asset-path-report.json'
	Write-Report $DuplicateAssetPathReport @($Assets[0], (New-GovernedAsset '/Game/Shared/DA_Objective' 'content.other_objective' 'shared'))
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$DuplicateAssetPathReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'duplicate asset_path'

	$IncompleteReport = Join-Path $FixtureRoot 'incomplete-report.json'
	Write-Report $IncompleteReport @(@{ asset_path='/Game/Shared/DA_Objective'; stable_id='content.objective'; content_version=1; audience='shared' })
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$IncompleteReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'missing required field.*lifecycle_state'

	$WrongPolicyReport = Join-Path $FixtureRoot 'wrong-policy-report.json'
	Write-Report $WrongPolicyReport $Assets
	$WrongPolicy = Get-Content -LiteralPath $WrongPolicyReport -Raw | ConvertFrom-Json
	$WrongPolicy.policy_sha256 = ('f' * 64)
	$WrongPolicy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WrongPolicyReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$WrongPolicyReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'policy_sha256.*current governed policy'

	$StringVersionReport = Join-Path $FixtureRoot 'string-version-report.json'
	Write-Report $StringVersionReport $Assets
	$StringVersion = Get-Content -LiteralPath $StringVersionReport -Raw | ConvertFrom-Json
	$StringVersion.schema_version = '2'
	$StringVersion | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StringVersionReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$StringVersionReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'schema_version.*JSON integer'

	$FractionalVersionReport = Join-Path $FixtureRoot 'fractional-version-report.json'
	Write-Report $FractionalVersionReport $Assets
	$FractionalVersion = Get-Content -LiteralPath $FractionalVersionReport -Raw | ConvertFrom-Json
	$FractionalVersion.assets[0].content_version = 1.5
	$FractionalVersion | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $FractionalVersionReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$FractionalVersionReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'content_version.*JSON integer'

	$NumericReviewerReport = Join-Path $FixtureRoot 'numeric-reviewer-report.json'
	Write-Report $NumericReviewerReport $Assets
	$NumericReviewer = Get-Content -LiteralPath $NumericReviewerReport -Raw | ConvertFrom-Json
	$NumericReviewer.assets[0].provenance.reviewer = 42
	$NumericReviewer | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $NumericReviewerReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$NumericReviewerReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'reviewer.*string'

	foreach ($InvalidHash in @(('A' * 64), ('a' * 63), ('g' * 64))) {
		$InvalidHashReport = Join-Path $FixtureRoot ("invalid-hash-{0}.json" -f [guid]::NewGuid().ToString('N'))
		Write-Report $InvalidHashReport $Assets
		$InvalidHashValue = Get-Content -LiteralPath $InvalidHashReport -Raw | ConvertFrom-Json
		$InvalidHashValue.assets[0].provenance.content_sha256 = $InvalidHash
		$InvalidHashValue | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InvalidHashReport -Encoding UTF8
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$InvalidHashReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'content_sha256.*malformed'
	}
	Write-Output 'PASS: uppercase, short, and non-hex content hashes fail closed'

	$ArbitraryNotApplicableReport = Join-Path $FixtureRoot 'arbitrary-not-applicable-report.json'
	Write-Report $ArbitraryNotApplicableReport $Assets
	$ArbitraryNotApplicable = Get-Content -LiteralPath $ArbitraryNotApplicableReport -Raw | ConvertFrom-Json
	$ArbitraryNotApplicable.assets[0].family_results[0].applicability = 'not_applicable'
	$ArbitraryNotApplicable.assets[0].family_results[0].deterministic_status = 'not_applicable'
	$ArbitraryNotApplicable.assets[0].family_results[0].promotion_status = 'not_applicable'
	$ArbitraryNotApplicable.assets[0].family_results[0].evidence = 'author says this does not apply'
	foreach ($CheckResult in $ArbitraryNotApplicable.assets[0].family_results[0].check_results) {
		$CheckResult.applicability = 'not_applicable'; $CheckResult.deterministic_status = 'not_applicable'; $CheckResult.promotion_status = 'not_applicable'
	}
	$ArbitraryNotApplicable | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ArbitraryNotApplicableReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ArbitraryNotApplicableReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'not_applicable.*canonical evidence'

	$ForgedPassingReport = Join-Path $FixtureRoot 'forged-passing-report.json'
	Copy-Item -LiteralPath $GovernedReport -Destination $ForgedPassingReport
	$ForgedPassing = Get-Content -LiteralPath $ForgedPassingReport -Raw | ConvertFrom-Json
	foreach ($AssetRecord in $ForgedPassing.assets) {
		foreach ($FamilyResult in $AssetRecord.family_results) {
			$FamilyResult.applicability = 'applicable'
			$FamilyResult.deterministic_status = 'passed'
			$FamilyResult.promotion_status = 'eligible'
			$FamilyResult.evidence = 'author supplied pass'
		}
	}
	$ForgedPassing | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ForgedPassingReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ForgedPassingReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'promotion_status does not aggregate' $Validator

	$ForgedNonPromotionReport = Join-Path $FixtureRoot 'forged-non-promotion-as-passed-report.json'
	Copy-Item -LiteralPath $GovernedReport -Destination $ForgedNonPromotionReport
	$ForgedNonPromotion = Get-Content -LiteralPath $ForgedNonPromotionReport -Raw | ConvertFrom-Json
	$ForgedNonPromotion.result = 'passed'
	$ForgedNonPromotion | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ForgedNonPromotionReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ForgedNonPromotionReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'result passed.*inconsistent' $Validator

	$ForgedNotApplicableReport = Join-Path $FixtureRoot 'forged-runtime-not-applicable-report.json'
	Write-Report $ForgedNotApplicableReport $Assets 'passed' $GovernedPolicyPath
	$ForgedNotApplicable = Get-Content -LiteralPath $ForgedNotApplicableReport -Raw | ConvertFrom-Json
	foreach ($AssetRecord in $ForgedNotApplicable.assets) {
		foreach ($FamilyResult in $AssetRecord.family_results) {
			$FamilyResult.applicability = 'not_applicable'
			$FamilyResult.deterministic_status = 'not_applicable'
			$FamilyResult.promotion_status = 'not_applicable'
			$FamilyResult.evidence = "policy:$($FamilyResult.policy_id):not_applicable:no_observed_checks"
			foreach ($CheckResult in $FamilyResult.check_results) {
				$CheckResult.applicability = 'not_applicable'; $CheckResult.deterministic_status = 'not_applicable'; $CheckResult.promotion_status = 'not_applicable'
			}
		}
	}
	$ForgedNotApplicable | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ForgedNotApplicableReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$ForgedNotApplicableReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; PolicyPath=$GovernedPolicyPath } 'cooked package requires applicable reference_boundary' $Validator
	Write-Output 'PASS: arbitrary applicability evidence and forged policy outcomes fail closed'

	$NonUtcReport = Join-Path $FixtureRoot 'non-utc-report.json'
	Write-Report $NonUtcReport $Assets
	$NonUtc = Get-Content -LiteralPath $NonUtcReport -Raw | ConvertFrom-Json
	$NonUtc.started_utc = '2026-08-29T02:00:00+02:00'
	$NonUtc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $NonUtcReport -Encoding UTF8
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$NonUtcReport; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server } 'started_utc.*UTC'
	Write-Output 'PASS: report scalar types and UTC timestamp formats fail closed'

	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=(Join-Path $FixtureRoot 'missing'); ServerCookedInventoryDirectory=$Server } 'inventory directory is missing'

	$OriginalReportBytes = [IO.File]::ReadAllBytes($Report)
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$Report } 'OutputPath.*must not overwrite.*input evidence'
	Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Report)) -ceq [Convert]::ToBase64String($OriginalReportBytes)) 'Rejected same-path output must leave the input report unchanged.'
	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$Client } 'OutputPath.*must identify a file|must not overwrite or alter a cooked-inventory'
	Write-Output 'PASS: validator refuses same-path input/output mutation'

	Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath='\\localhost\aetheln-no-such-share\cook-evidence.json' } 'OutputPath.*network or device path.*local volume'
	Write-Output 'PASS: network output paths are rejected before any filesystem access'

	$ReportDirectory = Split-Path -Parent $Report
	$ReportLeaf = Split-Path -Leaf $Report
	$ClientManifestPath = Join-Path $Client 'inventory-manifest.json'
	$OriginalClientManifestBytes = [IO.File]::ReadAllBytes($ClientManifestPath)
	$JunctionOutputParent = Join-Path $FixtureRoot 'alias-junction-output'
	New-Item -ItemType Junction -Path $JunctionOutputParent -Target $ReportDirectory | Out-Null
	try {
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=(Join-Path $JunctionOutputParent $ReportLeaf) } 'OutputPath.*reparse point'
	}
	finally { [IO.Directory]::Delete($JunctionOutputParent) }
	Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Report)) -ceq [Convert]::ToBase64String($OriginalReportBytes)) 'A junction-aliased output must leave the input report bytes unchanged.'
	$HardLinkOutput = Join-Path $FixtureRoot 'alias-hardlink-report.json'
	New-Item -ItemType HardLink -Path $HardLinkOutput -Target $Report | Out-Null
	try {
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$HardLinkOutput } 'OutputPath.*protected input evidence'
	}
	finally { if (Test-Path -LiteralPath $HardLinkOutput) { Remove-Item -LiteralPath $HardLinkOutput -Force } }
	Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Report)) -ceq [Convert]::ToBase64String($OriginalReportBytes)) 'A hardlink-aliased output must leave the input report bytes unchanged.'
	$ManifestHardLinkOutput = Join-Path $FixtureRoot 'alias-hardlink-manifest.json'
	New-Item -ItemType HardLink -Path $ManifestHardLinkOutput -Target $ClientManifestPath | Out-Null
	try {
		Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$ManifestHardLinkOutput } 'OutputPath.*protected input evidence'
	}
	finally { if (Test-Path -LiteralPath $ManifestHardLinkOutput) { Remove-Item -LiteralPath $ManifestHardLinkOutput -Force } }
	Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ClientManifestPath)) -ceq [Convert]::ToBase64String($OriginalClientManifestBytes)) 'A hardlink-aliased output must leave cooked-inventory input bytes unchanged.'
	Write-Output 'PASS: junction and hardlink output aliases are rejected with input bytes preserved'

	$SwapMarker = '$StartedUtc = [DateTime]::UtcNow'
	$SwapCases = @(
		@{ name='hardlink'; output=(Join-Path $FixtureRoot 'swap-hardlink-evidence.json'); mutation="New-Item -ItemType HardLink -Path `$ResolvedOutput -Target `$SourceContentValidationReportPath | Out-Null"; pattern='OutputPath.*protected input evidence' },
		@{ name='junction'; output=(Join-Path (Join-Path $FixtureRoot 'swap-junction-output') $ReportLeaf); mutation="[IO.Directory]::Delete((Split-Path -Parent `$ResolvedOutput)); New-Item -ItemType Junction -Path (Split-Path -Parent `$ResolvedOutput) -Target (Split-Path -Parent `$SourceContentValidationReportPath) | Out-Null"; pattern='OutputPath.*reparse point' }
	)
	foreach ($SwapCase in $SwapCases) {
		$SwapValidator = Join-Path $FixtureRoot ("Validate-ContentCookEvidence-{0}-swap.ps1" -f $SwapCase.name)
		$ValidatorSource = [IO.File]::ReadAllText($Validator)
		Assert-True ($ValidatorSource.IndexOf($SwapMarker, [StringComparison]::Ordinal) -ge 0) 'The deterministic post-preflight swap marker must exist after output preflight.'
		[IO.File]::WriteAllText($SwapValidator, $ValidatorSource.Replace($SwapMarker, ([string]$SwapCase.mutation + "`n" + $SwapMarker)), [Text.UTF8Encoding]::new($false))
		$SwapParent = Split-Path -Parent ([string]$SwapCase.output)
		if (-not (Test-Path -LiteralPath $SwapParent)) { New-Item -ItemType Directory -Path $SwapParent | Out-Null }
		try {
			Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=[string]$SwapCase.output } ([string]$SwapCase.pattern) $SwapValidator
			Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Report)) -ceq [Convert]::ToBase64String($OriginalReportBytes)) "A post-preflight $($SwapCase.name) output swap must leave the input report bytes unchanged."
			Assert-True (@(Get-ChildItem -LiteralPath $ReportDirectory -Force -Filter '*.tmp').Count -eq 0) "A post-preflight $($SwapCase.name) output swap must not leave pending evidence beside the input report."
		}
		finally {
			if ([string]$SwapCase.name -ceq 'junction') { if (Test-Path -LiteralPath $SwapParent) { [IO.Directory]::Delete($SwapParent) } }
			elseif (Test-Path -LiteralPath ([string]$SwapCase.output)) { Remove-Item -LiteralPath ([string]$SwapCase.output) -Force }
		}
	}
	Write-Output 'PASS: post-preflight hardlink and junction output swaps are rejected with input bytes preserved'

	# After the final publication check, an attacker may try to swap the output
	# parent or the output name for a junction into an unrelated victim directory.
	$PublicationMarker = '$PublicationTarget = $ResolvedOutput'
	$VictimRoot = Join-Path $FixtureRoot 'publication-victim'
	$VictimLeaf = 'victim-evidence.json'
	$VictimPath = Join-Path $VictimRoot $VictimLeaf
	New-Item -ItemType Directory -Path $VictimRoot | Out-Null
	[IO.File]::WriteAllText($VictimPath, 'unrelated victim bytes', [Text.UTF8Encoding]::new($false))
	$OriginalVictimBytes = [IO.File]::ReadAllBytes($VictimPath)
	$SwapMarkerPath = Join-Path $FixtureRoot 'publication-swap-result.txt'
	$HoldMarker = '$OutputAncestorHolds = Open-OutputAncestorHolds $OutputDirectory'
	# Converts an empty directory into a mount point in place, without renaming
	# it, using only FILE_WRITE_ATTRIBUTES, which directory hold sharing admits.
	$MountPointHelper = Join-Path $FixtureRoot 'Set-FixtureMountPoint.ps1'
	[IO.File]::WriteAllText($MountPointHelper, @'
param([string] $Directory, [string] $Target, [string] $ResultPath)
if (-not ('AethelnFixtureMountPoint' -as [type])) {
	Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AethelnFixtureMountPoint {
	[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
}
"@
}
$Substitute = [Text.Encoding]::Unicode.GetBytes('\??\' + $Target.TrimEnd('\') + '\')
$Print = [Text.Encoding]::Unicode.GetBytes($Target)
$DataLength = 8 + $Substitute.Length + 2 + $Print.Length + 2
$Buffer = New-Object byte[] (8 + $DataLength)
[BitConverter]::GetBytes([uint32] 2684354563).CopyTo($Buffer, 0)
[BitConverter]::GetBytes([uint16] $DataLength).CopyTo($Buffer, 4)
[BitConverter]::GetBytes([uint16] 0).CopyTo($Buffer, 8)
[BitConverter]::GetBytes([uint16] $Substitute.Length).CopyTo($Buffer, 10)
[BitConverter]::GetBytes([uint16] ($Substitute.Length + 2)).CopyTo($Buffer, 12)
[BitConverter]::GetBytes([uint16] $Print.Length).CopyTo($Buffer, 14)
$Substitute.CopyTo($Buffer, 16)
$Print.CopyTo($Buffer, 16 + $Substitute.Length + 2)
$Handle = [AethelnFixtureMountPoint]::CreateFileW($Directory, 0x100, 0x7, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
$Returned = 0
$Converted = (-not $Handle.IsInvalid) -and [AethelnFixtureMountPoint]::DeviceIoControl($Handle, 0x900A4, $Buffer, $Buffer.Length, [IntPtr]::Zero, 0, [ref] $Returned, [IntPtr]::Zero)
$ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
$Handle.Dispose()
[IO.File]::WriteAllText($ResultPath, $(if ($Converted) { 'swapped' } else { "blocked:$ErrorCode" }))
'@, [Text.UTF8Encoding]::new($false))
	$AfterCheckCases = @(
		@{ name='in-place-mount-point'; expected='swapped'; precreate=$false; marker=$HoldMarker; after=$true; mutation=@'
& '__MOUNT_HELPER__' -Directory (Split-Path -Parent $ResolvedOutput) -Target '__VICTIM_ROOT__' -ResultPath '__SWAP_MARKER__'
'@ },
		@{ name='parent'; expected='blocked'; mutation=@'
try { Rename-Item -LiteralPath (Split-Path -Parent $ResolvedOutput) -NewName 'after-check-parent-displaced' -ErrorAction Stop; New-Item -ItemType Junction -Path (Split-Path -Parent $ResolvedOutput) -Target '__VICTIM_ROOT__' | Out-Null; [IO.File]::WriteAllText('__SWAP_MARKER__', 'swapped') } catch { [IO.File]::WriteAllText('__SWAP_MARKER__', 'blocked') }
'@ },
		@{ name='name'; expected='swapped'; mutation=@'
try { if (Test-Path -LiteralPath $ResolvedOutput) { Remove-Item -LiteralPath $ResolvedOutput -Force -ErrorAction Stop }; New-Item -ItemType Junction -Path $ResolvedOutput -Target '__VICTIM_ROOT__' | Out-Null; [IO.File]::WriteAllText('__SWAP_MARKER__', 'swapped') } catch { [IO.File]::WriteAllText('__SWAP_MARKER__', 'blocked') }
'@ }
	)
	foreach ($AfterCheckCase in $AfterCheckCases) {
		$AfterCheckParent = Join-Path $FixtureRoot "after-check-$($AfterCheckCase.name)"
		$AfterCheckOutput = Join-Path $AfterCheckParent $VictimLeaf
		if ($AfterCheckCase.ContainsKey('precreate') -and -not $AfterCheckCase.precreate) {
			Assert-True (-not (Test-Path -LiteralPath $AfterCheckParent)) 'The in-place mount-point case must let the validator create an empty parent.'
		}
		else {
			New-Item -ItemType Directory -Path $AfterCheckParent | Out-Null
			[IO.File]::WriteAllText($AfterCheckOutput, 'previous evidence', [Text.UTF8Encoding]::new($false))
		}
		$AfterCheckValidator = Join-Path $FixtureRoot ("Validate-ContentCookEvidence-after-check-{0}.ps1" -f $AfterCheckCase.name)
		$ValidatorSource = [IO.File]::ReadAllText($Validator)
		$CaseMarker = if ($AfterCheckCase.ContainsKey('marker')) { [string]$AfterCheckCase.marker } else { $PublicationMarker }
		Assert-True ($ValidatorSource.IndexOf($CaseMarker, [StringComparison]::Ordinal) -ge 0) "The deterministic after-check marker '$CaseMarker' must exist in the validator."
		$Mutation = ([string]$AfterCheckCase.mutation).Replace('__VICTIM_ROOT__', $VictimRoot).Replace('__SWAP_MARKER__', $SwapMarkerPath).Replace('__MOUNT_HELPER__', $MountPointHelper)
		$Instrumented = if ($AfterCheckCase.ContainsKey('after') -and $AfterCheckCase.after) { $ValidatorSource.Replace($CaseMarker, ($CaseMarker + "`n" + $Mutation)) } else { $ValidatorSource.Replace($CaseMarker, ($Mutation + "`n" + $CaseMarker)) }
		[IO.File]::WriteAllText($AfterCheckValidator, $Instrumented, [Text.UTF8Encoding]::new($false))
		if (Test-Path -LiteralPath $SwapMarkerPath) { Remove-Item -LiteralPath $SwapMarkerPath -Force }
		$AfterCheckFailure = $null
		try {
			try { & $AfterCheckValidator -ContentValidationReportPath $Report -ClientCookedInventoryDirectory $Client -ServerCookedInventoryDirectory $Server -OutputPath $AfterCheckOutput -PolicyPath $PolicyPath -RuntimeIntakePath $RuntimeIntakePath -BuildProvenancePath $BuildProvenancePath -AllowTestEvidence | Out-Null }
			catch { $AfterCheckFailure = $_.Exception.Message }
			Assert-True (Test-Path -LiteralPath $SwapMarkerPath) "The after-check $($AfterCheckCase.name) swap must have been attempted."
			Assert-True (Test-Path -LiteralPath $VictimPath -PathType Leaf) "An after-check $($AfterCheckCase.name) swap must not delete the unrelated victim file."
			Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($VictimPath)) -ceq [Convert]::ToBase64String($OriginalVictimBytes)) "An after-check $($AfterCheckCase.name) swap must leave the unrelated victim bytes unchanged."
			Assert-True (@(Get-ChildItem -LiteralPath $VictimRoot -Force).Count -eq 1) "An after-check $($AfterCheckCase.name) swap must not leave publication debris in the victim directory."
			$SwapResult = [IO.File]::ReadAllText($SwapMarkerPath)
			Assert-True ($SwapResult -ceq [string]$AfterCheckCase.expected) "The after-check $($AfterCheckCase.name) swap must be $($AfterCheckCase.expected); observed '$SwapResult'."
			if ($SwapResult -ceq 'blocked') {
				Assert-True ($null -eq $AfterCheckFailure) "A blocked $($AfterCheckCase.name) swap must still publish into the verified parent; observed '$AfterCheckFailure'."
				Assert-True ((Get-Content -LiteralPath $AfterCheckOutput -Raw | ConvertFrom-Json).result -ceq 'passed') "A blocked $($AfterCheckCase.name) swap must publish the exact evidence."
			}
			else {
				Assert-True ($null -ne $AfterCheckFailure -and $AfterCheckFailure -match 'OutputPath') "A completed $($AfterCheckCase.name) swap must fail publication closed; observed '$AfterCheckFailure'."
			}
		}
		finally {
			foreach ($Candidate in @((Split-Path -Parent $AfterCheckOutput), $AfterCheckOutput)) {
				if ((Test-Path -LiteralPath $Candidate) -and (([IO.File]::GetAttributes($Candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { [IO.Directory]::Delete($Candidate) }
			}
			$Displaced = Join-Path $FixtureRoot 'after-check-parent-displaced'
			if (Test-Path -LiteralPath $Displaced) { Rename-Item -LiteralPath $Displaced -NewName (Split-Path -Leaf $AfterCheckParent) }
		}
	}
	Write-Output 'PASS: after-check parent, name, and in-place mount-point swaps never delete or alter an unrelated victim'

	# Publication fault fixtures run instrumented copies whose native type is
	# renamed, so each compiles its own injected behavior in this process.
	$FaultCases = @(
		@{ name='converted-before-create'; mount=$true; debris=$false; pattern='could not be created inside the held parent'; edits=@(
			@{ pattern='RequirePlainDirectory\(parent\);\r?\n(\s*)string parentFinalPath'; replacement='$1string parentFinalPath' }) },
		@{ name='stream-open-failure'; mount=$false; debris=$false; pattern='injected FileStream failure'; edits=@(
			@{ pattern=[regex]::Escape('stream = new FileStream(pending, FileAccess.ReadWrite);'); replacement='if (bytes != null) { throw new IOException("injected FileStream failure"); }' }) },
		@{ name='disposition-failure'; mount=$false; debris=$true; pattern='injected FileStream failure; pending evidence .* could not be removed'; edits=@(
			@{ pattern=[regex]::Escape('stream = new FileStream(pending, FileAccess.ReadWrite);'); replacement='if (bytes != null) { throw new IOException("injected FileStream failure"); }' },
			@{ pattern=[regex]::Escape('if (SetFileInformationByHandle(handle, 4, buffer, 4)) { return null; }'); replacement='if (handle == null && SetFileInformationByHandle(handle, 4, buffer, 4)) { return null; }' }) }
	)
	$FaultIndex = 0
	foreach ($FaultCase in $FaultCases) {
		$FaultIndex++
		$FaultParent = Join-Path $FixtureRoot "publication-fault-$($FaultCase.name)"
		$FaultOutput = Join-Path $FaultParent $VictimLeaf
		$FaultSource = [IO.File]::ReadAllText($Validator).Replace('AethelnOutputPublicationNative', "AethelnOutputPublicationNativeFault$FaultIndex")
		foreach ($Edit in $FaultCase.edits) {
			$Edited = [regex]::Replace($FaultSource, [string]$Edit.pattern, [string]$Edit.replacement)
			Assert-True ($Edited -cne $FaultSource) "Fault fixture '$($FaultCase.name)' must change the validator at '$($Edit.pattern)'."
			$FaultSource = $Edited
		}
		if ($FaultCase.mount) {
			$Mutation = "& '$MountPointHelper' -Directory (Split-Path -Parent `$ResolvedOutput) -Target '$VictimRoot' -ResultPath '$SwapMarkerPath'"
			$FaultSource = $FaultSource.Replace($HoldMarker, ($HoldMarker + "`n" + $Mutation))
		}
		$FaultValidator = Join-Path $FixtureRoot ("Validate-ContentCookEvidence-fault-{0}.ps1" -f $FaultCase.name)
		[IO.File]::WriteAllText($FaultValidator, $FaultSource, [Text.UTF8Encoding]::new($false))
		if (Test-Path -LiteralPath $SwapMarkerPath) { Remove-Item -LiteralPath $SwapMarkerPath -Force }
		$FaultFailure = $null
		try {
			try { & $FaultValidator -ContentValidationReportPath $Report -ClientCookedInventoryDirectory $Client -ServerCookedInventoryDirectory $Server -OutputPath $FaultOutput -PolicyPath $PolicyPath -RuntimeIntakePath $RuntimeIntakePath -BuildProvenancePath $BuildProvenancePath -AllowTestEvidence | Out-Null }
			catch { $FaultFailure = $_.Exception.Message }
			Assert-True ($null -ne $FaultFailure -and $FaultFailure -match [string]$FaultCase.pattern) "Publication fault '$($FaultCase.name)' must fail closed with '$($FaultCase.pattern)'; observed '$FaultFailure'."
			if ($FaultCase.mount) { Assert-True ([IO.File]::ReadAllText($SwapMarkerPath) -ceq 'swapped') 'The converted-before-create fixture must convert the empty held parent in place.' }
			Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($VictimPath)) -ceq [Convert]::ToBase64String($OriginalVictimBytes)) "Publication fault '$($FaultCase.name)' must leave the victim bytes unchanged."
			Assert-True (@(Get-ChildItem -LiteralPath $VictimRoot -Force).Count -eq 1) "Publication fault '$($FaultCase.name)' must not create anything in the victim directory."
			$Leftovers = if ($FaultCase.mount) { @() } else { @(Get-ChildItem -LiteralPath $FaultParent -Force) }
			Assert-True (@($Leftovers | Where-Object { $_.Name -ceq $VictimLeaf }).Count -eq 0) "Publication fault '$($FaultCase.name)' must not publish evidence."
			if ($FaultCase.debris) {
				Assert-True (@($Leftovers | Where-Object { $_.Name -like '*.tmp' }).Count -eq 1) 'A failed disposition must leave exactly one reported pending file inside the held parent.'
				Assert-True ($FaultFailure -match [regex]::Escape($Leftovers[0].Name)) 'A failed disposition must name the leftover pending file.'
			}
			else { Assert-True (@($Leftovers | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) "Publication fault '$($FaultCase.name)' must delete its own pending file." }
		}
		finally {
			# Cleanup must never replace a failing assertion (for example a leaked pending handle).
			try {
				if ((Test-Path -LiteralPath $FaultParent) -and (([IO.File]::GetAttributes($FaultParent) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { [IO.Directory]::Delete($FaultParent) }
				elseif (Test-Path -LiteralPath $FaultParent) { Remove-Item -LiteralPath $FaultParent -Recurse -Force }
			}
			catch { Write-Warning "Publication fault '$($FaultCase.name)' cleanup failed: $($_.Exception.Message)" }
		}
	}
	Write-Output 'PASS: in-place conversion before create, stream-open failure, and cleanup failure all fail closed without touching a victim'

	$DriftMarker = '$StartedUtc = [DateTime]::UtcNow'
	$DriftCases = @(
		@{ name='report'; target=$Report; mutation="Add-Content -LiteralPath `$SourceContentValidationReportPath -Value 'same-path report drift' -Encoding UTF8"; pattern='Content validation report changed during validation' },
		@{ name='build-provenance'; target=$BuildProvenancePath; mutation="Add-Content -LiteralPath `$SourceBuildProvenancePath -Value 'same-path build drift' -Encoding UTF8"; pattern='Build provenance changed during validation' },
		@{ name='client-registry'; target=(Join-Path $Client 'AssetRegistry.bin'); mutation="Add-Content -LiteralPath (Join-Path `$SourceClientCookedInventoryDirectory 'AssetRegistry.bin') -Value 'same-path registry drift' -Encoding UTF8"; pattern='Client cooked inventory.*AssetRegistry\.bin.*changed during validation' }
	)
	foreach ($DriftCase in $DriftCases) {
		$OriginalBytes = [IO.File]::ReadAllBytes([string]$DriftCase.target)
		$DriftValidator = Join-Path $FixtureRoot ("Validate-ContentCookEvidence-{0}-drift.ps1" -f $DriftCase.name)
		$ValidatorSource = [IO.File]::ReadAllText($Validator)
		Assert-True ($ValidatorSource.IndexOf($DriftMarker, [StringComparison]::Ordinal) -ge 0) 'The deterministic input-drift fixture marker must exist exactly before evidence construction.'
		$InstrumentedSource = $ValidatorSource.Replace($DriftMarker, ([string]$DriftCase.mutation + "`n" + $DriftMarker))
		[IO.File]::WriteAllText($DriftValidator, $InstrumentedSource, [Text.UTF8Encoding]::new($false))
		$DriftOutput = Join-Path $FixtureRoot ("{0}-drift-evidence.json" -f $DriftCase.name)
		try {
			Invoke-ExpectedFailure @{ ContentValidationReportPath=$Report; ClientCookedInventoryDirectory=$Client; ServerCookedInventoryDirectory=$Server; OutputPath=$DriftOutput } ([string]$DriftCase.pattern) $DriftValidator
			Assert-True (-not (Test-Path -LiteralPath $DriftOutput)) "Observed $($DriftCase.name) drift must fail before publishing evidence."
		}
		finally { [IO.File]::WriteAllBytes([string]$DriftCase.target, $OriginalBytes) }
	}
	Write-Output 'PASS: report, build-provenance, and staged-registry same-path drift fails before evidence publication'
	Write-Output 'All content cook-evidence tests passed.'
}
finally {
	# A leaked handle must surface as its assertion, not as a fixture-cleanup error.
	try { if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force } }
	catch { Write-Warning "Fixture cleanup failed: $($_.Exception.Message)" }
}
