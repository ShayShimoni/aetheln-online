[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CaptureScript = Join-Path $RepositoryRoot 'scripts/build/Invoke-CookedInventoryCapture.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("AethelnCookCaptureTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-Json([string] $Path, [object] $Value) {
	[IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Invoke-ExpectedFailure([hashtable] $Arguments, [string] $Pattern) {
	$Failure = $null
	try { & $CaptureScript @Arguments | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True ($null -ne $Failure) "Expected capture to fail with '$Pattern'."
	Assert-True ($Failure -match $Pattern) "Failure '$Failure' did not match '$Pattern'."
}

try {
	Assert-True (Test-Path -LiteralPath $CaptureScript -PathType Leaf) 'The cooked inventory capture entry point must exist.'
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$EngineRoot = Join-Path $FixtureRoot 'engine'
	$EngineBuild = Join-Path $EngineRoot 'Engine/Build'
	New-Item -ItemType Directory -Path $EngineBuild -Force | Out-Null
	$BuildVersionPath = Join-Path $EngineBuild 'Build.version'
	Set-Content -LiteralPath $BuildVersionPath -Value '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1}' -Encoding UTF8

	$Project = Join-Path $FixtureRoot 'AethelnOnline.uproject'
	$Policy = Join-Path $FixtureRoot 'asset-intake-policy.json'
	$Intake = Join-Path $FixtureRoot 'runtime-asset-intake.json'
	$Report = Join-Path $FixtureRoot 'content-validation-report.json'
	$BuildProvenance = Join-Path $FixtureRoot 'build-provenance.json'
	$ClientRegistry = Join-Path $FixtureRoot 'Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin'
	$ServerRegistry = Join-Path $FixtureRoot 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin'
	$FakeDump = Join-Path $FixtureRoot 'Fake-DumpAssetRegistry.ps1'
	Set-Content -LiteralPath $Project -Value '{"FileVersion":3}' -Encoding UTF8
	New-Item -ItemType Directory -Path (Split-Path -Parent $ClientRegistry),(Split-Path -Parent $ServerRegistry) -Force | Out-Null
	Set-Content -LiteralPath $ClientRegistry -Value 'client registry fixture' -Encoding UTF8
	Set-Content -LiteralPath $ServerRegistry -Value 'server registry fixture' -Encoding UTF8
	Write-Json $Policy ([ordered]@{ schema_id='aetheln.asset-intake-policy'; schema_version=2; report=[ordered]@{schema_id='aetheln.content-validation-report';schema_version=2} })
	Write-Json $Intake ([ordered]@{ policy_schema_id='aetheln.asset-intake-policy'; policy_schema_version=2 })
	$PolicySha = (Get-FileHash -LiteralPath $Policy -Algorithm SHA256).Hash.ToLowerInvariant()
	$IntakeSha = (Get-FileHash -LiteralPath $Intake -Algorithm SHA256).Hash.ToLowerInvariant()
	$ProjectSha = (Get-FileHash -LiteralPath $Project -Algorithm SHA256).Hash.ToLowerInvariant()
	$BuildVersionSha = (Get-FileHash -LiteralPath $BuildVersionPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$Revision = ('a' * 40)
	$EngineRevision = ('b' * 40)
	$CompilerSha = ('c' * 64)
	$LinuxCompilerSha = ('d' * 64)
	$ResourceCompilerSha = ('e' * 64)
	$InvocationSha = ('1' * 64)
	$FakeDumpBody = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]] $Arguments)
$OutArgument = @($Arguments | Where-Object { $_ -like '-OutDir=*' })
$PathArgument = @($Arguments | Where-Object { $_ -like '-Path=*' })
if ($OutArgument.Count -ne 1 -or $PathArgument.Count -ne 1) { throw 'missing fake dump arguments' }
$OutDir = $OutArgument[0].Substring(8)
$RegistryPath = $PathArgument[0].Substring(6)
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'dump-paths.txt') -Value ([IO.Path]::GetFullPath($RegistryPath)) -Encoding UTF8
$IsClient = $RegistryPath -match '(?i)[\\/]client[\\/]'
if ($IsClient -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'mutate-client-source'))) {
	Add-Content -LiteralPath (Join-Path $PSScriptRoot 'Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin') -Value 'source drift' -Encoding UTF8
	Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'mutate-client-source') -Force
}
if ($IsClient -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'mutate-build-provenance'))) {
	Add-Content -LiteralPath (Join-Path $PSScriptRoot 'build-provenance.json') -Value 'provenance drift' -Encoding UTF8
	Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'mutate-build-provenance') -Force
}
if ($IsClient -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'mutate-staged-registry'))) {
	Add-Content -LiteralPath $RegistryPath -Value 'staged drift' -Encoding UTF8
	Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'mutate-staged-registry') -Force
}
if ($IsClient -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'mutate-dump-command'))) {
	Add-Content -LiteralPath $PSCommandPath -Value '# executable drift' -Encoding UTF8
	Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'mutate-dump-command') -Force
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$Package = '/Game/Maps/StarterMap'
$Lines = @('--- Begin CachedAssetsByPackageName ---', "`t$Package : 1 item(s)", "`t`t$Package.StarterMap", '--- End CachedAssetsByPackageName : 1 entries ---')
Set-Content -LiteralPath (Join-Path $OutDir 'Page_00000.txt') -Value $Lines -Encoding UTF8
'fake dump complete'
'@
	[IO.File]::WriteAllText($FakeDump, $FakeDumpBody, [Text.UTF8Encoding]::new($false))
	$EngineBinarySha = (Get-FileHash -LiteralPath $FakeDump -Algorithm SHA256).Hash.ToLowerInvariant()

	Write-Json $BuildProvenance ([ordered]@{
		schemaVersion=2
		source=[ordered]@{ revision=$Revision; clean=$true; projectSha256=$ProjectSha }
		build=[ordered]@{
			configuration='Development'; clientTarget='AethelnOnlineClient'; clientPlatform='Win64'; serverTarget='AethelnOnlineServer'; serverPlatform='Linux'
			uatInvocations=[ordered]@{ client=[ordered]@{arguments=@('BuildCookRun','-platform=Win64')}; server=[ordered]@{arguments=@('BuildCookRun','-serverplatform=Linux')} }
		}
		tools=[ordered]@{
			unreal=[ordered]@{ repositoryRevision=$EngineRevision; buildVersionSha256=$BuildVersionSha }
			compiler=[ordered]@{ version='14.44.35207'; sha256=$CompilerSha }
			windowsSdk=[ordered]@{ resourceCompilerSha256=$ResourceCompilerSha }
			linuxCrossToolchain=[ordered]@{ identity='v26_clang-20.1.8-rockylinux8'; compilerSha256=$LinuxCompilerSha }
		}
	})
	Write-Json $Report ([ordered]@{
		schema_id='aetheln.content-validation-report'; schema_version=2; revision=$Revision; policy_sha256=$PolicySha; intake_sha256=$IntakeSha
		execution_provenance=[ordered]@{
			engine_revision=$EngineRevision; engine_tag='5.8.1-release'; engine_binary_sha256=$EngineBinarySha; build_version_sha256=$BuildVersionSha
			target='AethelnOnlineEditor'; platform='Win64'; configuration='Development'; compiler_sha256=$CompilerSha; resource_compiler_sha256=$ResourceCompilerSha
			project_sha256=$ProjectSha; policy_sha256=$PolicySha; intake_sha256=$IntakeSha; invocation_sha256=$InvocationSha; registry_source='test_snapshot'; repository_clean=$true
		}
	})

	$Arguments = @{
		ProjectPath=$Project; EngineRoot=$EngineRoot; BuildProvenancePath=$BuildProvenance; ContentValidationReportPath=$Report
		ClientCookedRegistryPath=$ClientRegistry; ServerCookedRegistryPath=$ServerRegistry; OutputRoot=(Join-Path $FixtureRoot 'capture')
		PolicyPath=$Policy; RuntimeIntakePath=$Intake; DumpCommandPath=$FakeDump; AllowTestCommand=$true
	}
	& $CaptureScript @Arguments | Out-Null
	foreach ($Kind in @('client','server')) {
		$ManifestPath = Join-Path $Arguments.OutputRoot "$Kind/inventory-manifest.json"
		Assert-True (Test-Path -LiteralPath $ManifestPath -PathType Leaf) "$Kind manifest must be emitted."
		$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
		Assert-True ($Manifest.schema_id -ceq 'aetheln.cooked-inventory-manifest' -and [int]$Manifest.schema_version -eq 2) "$Kind manifest must be versioned."
		Assert-True ($Manifest.capture_mode -ceq 'test_fixture' -and $Manifest.source_revision -ceq $Revision) "$Kind manifest must expose test evidence and exact revision."
		Assert-True ([int]$Manifest.package_count -eq 1 -and @($Manifest.pages).Count -eq 1) "$Kind manifest must bind its exact package/page count."
		$PagePath = Join-Path (Split-Path -Parent $ManifestPath) $Manifest.pages[0].name
		Assert-True ($Manifest.pages[0].sha256 -ceq (Get-FileHash -LiteralPath $PagePath -Algorithm SHA256).Hash.ToLowerInvariant()) "$Kind page digest must match bytes."
		Assert-True ($Manifest.policy_sha256 -ceq $PolicySha -and $Manifest.intake_sha256 -ceq $IntakeSha) "$Kind manifest must bind policy and intake."
		Assert-True ($Manifest.content_validation_report_sha256 -ceq (Get-FileHash -LiteralPath $Report -Algorithm SHA256).Hash.ToLowerInvariant()) "$Kind manifest must bind the report."
		$ExpectedRegistry = if ($Kind -ceq 'client') { $ClientRegistry } else { $ServerRegistry }
		$ExpectedTarget = if ($Kind -ceq 'client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
		$ExpectedPlatform = if ($Kind -ceq 'client') { 'Win64' } else { 'Linux' }
		$ExpectedCookPlatform = if ($Kind -ceq 'client') { 'WindowsClient' } else { 'LinuxServer' }
		$StagedRegistry = Join-Path (Split-Path -Parent $ManifestPath) 'AssetRegistry.bin'
		Assert-True (Test-Path -LiteralPath $StagedRegistry -PathType Leaf) "$Kind capture must retain its immutable staged registry."
		Assert-True ($Manifest.cooked_registry.source_path -ceq ([IO.Path]::GetFullPath($ExpectedRegistry).Replace('\','/'))) "$Kind manifest must bind the resolved source registry path."
		Assert-True ($Manifest.cooked_registry.staged_path -ceq 'AssetRegistry.bin') "$Kind manifest must bind the manifest-relative staged registry path."
		Assert-True ([long]$Manifest.cooked_registry.size_bytes -gt 0 -and [long]$Manifest.cooked_registry.size_bytes -eq (Get-Item -LiteralPath $StagedRegistry).Length) "$Kind manifest must bind the positive staged byte size."
		Assert-True ($Manifest.cooked_registry.sha256 -ceq (Get-FileHash -LiteralPath $StagedRegistry -Algorithm SHA256).Hash.ToLowerInvariant()) "$Kind manifest must bind the staged registry digest."
		Assert-True ($Manifest.cooked_registry.target -ceq $ExpectedTarget -and $Manifest.cooked_registry.platform -ceq $ExpectedPlatform -and $Manifest.cooked_registry.cook_platform -ceq $ExpectedCookPlatform) "$Kind manifest must bind target, platform, and cook platform."
		Assert-True ($Manifest.cooked_registry.build_provenance_sha256 -ceq (Get-FileHash -LiteralPath $BuildProvenance -Algorithm SHA256).Hash.ToLowerInvariant() -and $Manifest.cooked_registry.source_revision -ceq $Revision) "$Kind registry must bind the exact build provenance digest and revision."
	}
	$DumpPaths = @(Get-Content -LiteralPath (Join-Path $FixtureRoot 'dump-paths.txt'))
	Assert-True ($DumpPaths.Count -eq 2) 'Capture must run exactly one dump per staged registry.'
	Assert-True ($DumpPaths[0] -ceq [IO.Path]::GetFullPath((Join-Path $Arguments.OutputRoot 'client/AssetRegistry.bin'))) 'Client dump must consume the immutable staged registry rather than the mutable source.'
	Assert-True ($DumpPaths[1] -ceq [IO.Path]::GetFullPath((Join-Path $Arguments.OutputRoot 'server/AssetRegistry.bin'))) 'Server dump must consume the immutable staged registry rather than the mutable source.'
	$ClientManifest = Get-Content -LiteralPath (Join-Path $Arguments.OutputRoot 'client/inventory-manifest.json') -Raw | ConvertFrom-Json
	$ServerManifest = Get-Content -LiteralPath (Join-Path $Arguments.OutputRoot 'server/inventory-manifest.json') -Raw | ConvertFrom-Json
	Assert-True ($ClientManifest.target -ceq 'AethelnOnlineClient' -and $ClientManifest.platform -ceq 'Win64' -and $ClientManifest.toolchain_sha256 -ceq $CompilerSha) 'Client manifest must bind the client target and MSVC toolchain.'
	Assert-True ($ServerManifest.target -ceq 'AethelnOnlineServer' -and $ServerManifest.platform -ceq 'Linux' -and $ServerManifest.toolchain_sha256 -ceq $LinuxCompilerSha) 'Server manifest must bind the server target and Linux toolchain.'
	Write-Output 'PASS: guarded capture emits provenance-bound client and server manifests'
	Invoke-ExpectedFailure $Arguments 'not empty.*refusing to mix or overwrite evidence'
	Write-Output 'PASS: capture refuses to mix with or overwrite existing evidence'

	$NoSwitch = @{} + $Arguments
	$NoSwitch.Remove('AllowTestCommand')
	Invoke-ExpectedFailure $NoSwitch 'test-only.*requires AllowTestCommand'
	$NoCommand = @{} + $Arguments
	$NoCommand.Remove('DumpCommandPath')
	Invoke-ExpectedFailure $NoCommand 'AllowTestCommand requires.*DumpCommandPath'
	Write-Output 'PASS: test command injection is explicitly double gated'

	$NonCanonicalRegistry = Join-Path $FixtureRoot 'arbitrary-client-AssetRegistry.bin'
	Set-Content -LiteralPath $NonCanonicalRegistry -Value 'arbitrary registry fixture' -Encoding UTF8
	$NonCanonicalArguments = @{} + $Arguments
	$NonCanonicalArguments.Remove('AllowTestCommand')
	$NonCanonicalArguments.Remove('DumpCommandPath')
	$NonCanonicalArguments.Remove('PolicyPath')
	$NonCanonicalArguments.Remove('RuntimeIntakePath')
	$NonCanonicalArguments.ClientCookedRegistryPath = $NonCanonicalRegistry
	$NonCanonicalArguments.OutputRoot = Join-Path $FixtureRoot 'noncanonical-capture'
	Invoke-ExpectedFailure $NonCanonicalArguments 'ClientCookedRegistryPath.*canonical.*Saved[\\/]Cooked[\\/]WindowsClient[\\/]AethelnOnline[\\/]AssetRegistry\.bin'
	Write-Output 'PASS: live capture accepts only canonical client and server cooked registries'

	$OriginalClientRegistryBytes = [IO.File]::ReadAllBytes($ClientRegistry)
	Set-Content -LiteralPath (Join-Path $FixtureRoot 'mutate-client-source') -Value 'mutate' -Encoding Ascii
	$SourceDriftArguments = @{} + $Arguments
	$SourceDriftArguments.OutputRoot = Join-Path $FixtureRoot 'source-drift-capture'
	Invoke-ExpectedFailure $SourceDriftArguments 'Client cooked registry source changed during capture'
	[IO.File]::WriteAllBytes($ClientRegistry, $OriginalClientRegistryBytes)
	Write-Output 'PASS: mutable source registry drift fails after staged capture'

	Set-Content -LiteralPath (Join-Path $FixtureRoot 'mutate-staged-registry') -Value 'mutate' -Encoding Ascii
	$StagedDriftArguments = @{} + $Arguments
	$StagedDriftArguments.OutputRoot = Join-Path $FixtureRoot 'staged-drift-capture'
	Invoke-ExpectedFailure $StagedDriftArguments 'Client staged cooked registry changed during capture'
	Write-Output 'PASS: staged registry drift fails closed'

	$OriginalBuildProvenanceBytes = [IO.File]::ReadAllBytes($BuildProvenance)
	Set-Content -LiteralPath (Join-Path $FixtureRoot 'mutate-build-provenance') -Value 'mutate' -Encoding Ascii
	$ProvenanceDriftArguments = @{} + $Arguments
	$ProvenanceDriftArguments.OutputRoot = Join-Path $FixtureRoot 'provenance-drift-capture'
	Invoke-ExpectedFailure $ProvenanceDriftArguments 'Build provenance changed during capture'
	[IO.File]::WriteAllBytes($BuildProvenance, $OriginalBuildProvenanceBytes)
	Write-Output 'PASS: build-provenance same-path drift fails after capture'

	$OriginalDumpCommandBytes = [IO.File]::ReadAllBytes($FakeDump)
	Set-Content -LiteralPath (Join-Path $FixtureRoot 'mutate-dump-command') -Value 'mutate' -Encoding Ascii
	$CommandDriftArguments = @{} + $Arguments
	$CommandDriftArguments.OutputRoot = Join-Path $FixtureRoot 'command-drift-capture'
	Invoke-ExpectedFailure $CommandDriftArguments 'Dump command changed during capture'
	[IO.File]::WriteAllBytes($FakeDump, $OriginalDumpCommandBytes)
	Write-Output 'PASS: capture-command same-path drift fails after capture'

	$MismatchReport = Join-Path $FixtureRoot 'mismatch-report.json'
	$Mismatch = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$Mismatch.revision = ('9' * 40)
	Write-Json $MismatchReport $Mismatch
	$MismatchArguments = @{} + $Arguments
	$MismatchArguments.ContentValidationReportPath = $MismatchReport
	$MismatchArguments.OutputRoot = Join-Path $FixtureRoot 'mismatch-capture'
	Invoke-ExpectedFailure $MismatchArguments 'source revisions differ'
	Write-Output 'PASS: source revision mismatch fails before capture'
	$WrongReportSchema = Join-Path $FixtureRoot 'wrong-schema-report.json'
	$WrongSchema = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
	$WrongSchema.schema_version = 1
	Write-Json $WrongReportSchema $WrongSchema
	$WrongSchemaArguments = @{} + $Arguments
	$WrongSchemaArguments.ContentValidationReportPath = $WrongReportSchema
	$WrongSchemaArguments.OutputRoot = Join-Path $FixtureRoot 'wrong-schema-capture'
	Invoke-ExpectedFailure $WrongSchemaArguments 'report schema identity does not match'
	Write-Output 'PASS: capture binds the policy-selected content report schema'

	$BadPolicy = Join-Path $FixtureRoot 'bad-policy.json'
	Write-Json $BadPolicy ([ordered]@{ schema_id='other.policy'; schema_version=2; report=[ordered]@{schema_id='aetheln.content-validation-report';schema_version=2} })
	$BadPolicyArguments = @{} + $Arguments
	$BadPolicyArguments.PolicyPath = $BadPolicy
	$BadPolicyArguments.OutputRoot = Join-Path $FixtureRoot 'bad-policy-capture'
	Invoke-ExpectedFailure $BadPolicyArguments 'policy identity does not match'
	Write-Output 'PASS: policy and intake identity mismatch fails closed'

	Write-Output 'All cooked inventory capture tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
