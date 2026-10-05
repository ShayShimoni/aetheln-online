[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Write-BuildProvenance.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnProvenanceTests-{0}" -f [guid]::NewGuid().ToString('N'))
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

try {
	$RealRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
	$OriginalPath = $env:PATH
	$GitBin = Join-Path $FixtureRoot 'GitBin'
	New-Item -ItemType Directory -Path $GitBin -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $GitBin 'git.bat') -Value "@echo off`r`nif `"%3`"==`"rev-parse`" echo $RealRevision`r`nexit /b 0" -Encoding Ascii
	$env:PATH = "$GitBin;$OriginalPath"
	$EngineRoot = Join-Path $FixtureRoot 'UE'
	$ToolchainRoot = Join-Path $FixtureRoot 'v26_clang-20.1.8-rockylinux8'
	$Client = Join-Path $FixtureRoot 'Client'
	$Server = Join-Path $FixtureRoot 'Server'
	New-Item -ItemType Directory -Path (Join-Path $EngineRoot 'Engine/Build'), $ToolchainRoot, $Client, $Server -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $EngineRoot 'Engine/Build/Build.version') -Value '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"Changelist":123,"CompatibleChangelist":120,"BranchName":"++UE5+Release-5.8"}' -Encoding UTF8
	$ToolchainX64Bin = Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin'
	$ToolchainDecoyBin = Join-Path $ToolchainRoot 'aarch64-unknown-linux-gnueabi/bin'
	New-Item -ItemType Directory -Path $ToolchainX64Bin, $ToolchainDecoyBin -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $ToolchainX64Bin 'clang.bat') -Value '@echo clang version 20.1.8' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $ToolchainDecoyBin 'clang.bat') -Value '@echo clang version 20.1.8' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $Client 'AethelnOnlineClient.exe') -Value client
	Set-Content -LiteralPath (Join-Path $Server 'AethelnOnlineServer') -Value server
	$Compiler = Join-Path $FixtureRoot 'VS/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
	$DecoyCompiler = Join-Path $FixtureRoot 'VS/MSVC/14.50.99999/bin/Hostx64/x64/cl.exe'
	$ResourceCompiler = Join-Path $FixtureRoot 'Windows Kits/10/bin/10.0.26100.0/x64/rc.exe'
	$DecoyResourceCompiler = Join-Path $FixtureRoot 'Windows Kits/10/bin/10.0.30000.0/x64/rc.exe'
	foreach ($Tool in @($Compiler, $DecoyCompiler, $ResourceCompiler, $DecoyResourceCompiler)) { New-Item -ItemType Directory -Path (Split-Path -Parent $Tool) -Force | Out-Null; Set-Content -LiteralPath $Tool -Value $Tool -Encoding Ascii }
	$Revision = $RealRevision
	$UatArguments = [ordered]@{ client = @('BuildCookRun', '-platform=Win64'); server = @('BuildCookRun', '-serverplatform=Linux'); dependencyRegistryDump = @('-run=DumpAssetRegistry', '-DependencyDetails'); cookedInventoryDump = @('-run=DumpAssetRegistry', '-PackageName') } | ConvertTo-Json -Compress
	$OutputPath = Join-Path $FixtureRoot 'provenance/build.json'
	function New-RegistryReceipts {
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the client and server registry receipt pair.')]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory fixture value and changes no external state.')]
		param([string] $ReceiptRevision = $Revision)
		[ordered]@{
			client = [ordered]@{ relativePath = 'Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin'; sizeBytes = 17; sha256 = ('a' * 64); target = 'AethelnOnlineClient'; platform = 'Win64'; cookPlatform = 'WindowsClient'; sourceRevision = $ReceiptRevision }
			server = [ordered]@{ relativePath = 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin'; sizeBytes = 23; sha256 = ('b' * 64); target = 'AethelnOnlineServer'; platform = 'Linux'; cookPlatform = 'LinuxServer'; sourceRevision = $ReceiptRevision }
		}
	}
	$CookedRegistryReceipts = New-RegistryReceipts | ConvertTo-Json -Compress

	& $Script -OutputPath $OutputPath -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -SourceRevision $Revision -BuildConfiguration Development -ClientArchivePath $Client -ServerArchivePath $Server -CompilerPath $Compiler -ResourceCompilerPath $ResourceCompiler -UatArgumentsJson $UatArguments -CookedRegistryReceiptsJson $CookedRegistryReceipts
	$Provenance = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
	Assert-True ($Provenance.schemaVersion -eq 2) 'Schema version should identify complete provenance.'
	Assert-True ($Provenance.source.revision -eq $Revision) 'Verified repository HEAD should be recorded.'
	Assert-True ($Provenance.source.clean -eq $true) 'Verified clean source state should be recorded.'
	Assert-True (($Provenance.source.statusCommand -join ' ') -match 'status --porcelain=v1 --untracked-files=all') 'Exact clean-worktree command should be recorded.'
	Assert-True ($Provenance.tools.unreal.build.branchName -eq '++UE5+Release-5.8') 'Exact Unreal build identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.identity -eq 'v26_clang-20.1.8-rockylinux8') 'Versioned cross-toolchain root identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.compilerBanner -match '20\.1\.8') 'Cross-toolchain compiler identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.compilerPath.Replace('\', '/') -like '*/x86_64-unknown-linux-gnu/bin/clang.bat') 'Cross-toolchain compiler path must resolve under the x86_64 architecture directory.'
	Assert-True ($Provenance.tools.compiler.path -eq $Compiler) 'Pinned compiler must win when multiple installations exist.'
	Assert-True ($Provenance.tools.compiler.version -eq '14.44.35207') 'Exactly one pinned MSVC version should be recorded.'
	Assert-True ($Provenance.tools.windowsSdk.resourceCompilerPath -eq $ResourceCompiler) 'Pinned SDK tool must win when multiple SDKs exist.'
	Assert-True ($Provenance.tools.windowsSdk.version -eq '10.0.26100.0') 'Exactly one pinned Windows SDK version should be recorded.'
	Assert-True ($Provenance.source.plugins.Count -eq 4) 'Project plugin descriptors and state should be recorded.'
	$AndroidFileServer = @($Provenance.source.plugins | Where-Object { $_.name -eq 'AndroidFileServer' })
	Assert-True ($AndroidFileServer.Count -eq 1 -and $AndroidFileServer[0].enabled -eq $false) 'Disabled plugins should remain explicit in provenance.'
	Assert-True ($Provenance.build.uatInvocations.server.arguments[1] -eq '-serverplatform=Linux') 'Exact UAT argument order should be recorded.'
	Assert-True ($Provenance.artifacts.inventory.Count -eq 2) 'Complete artifact file inventory should be recorded.'
	Assert-True ($Provenance.artifacts.inventory[0].sha256.Length -eq 64) 'Artifact SHA256 should be recorded.'
	Assert-True ($Provenance.artifacts.inventory[0].sizeBytes -gt 0) 'Artifact byte size should be recorded.'
	Assert-True ($Provenance.host.PSObject.Properties.Name -contains 'buildIdentity') 'Host/build identity should be recorded.'
	Assert-True (-not ($Provenance.PSObject.Properties.Name -contains 'environment')) 'Process environment must not be captured.'
	Write-Output 'PASS: provenance records verified revisions, exact tools/arguments/plugins/host, and hashed inventory'

	foreach ($Kind in @('client', 'server')) {
		$Expected = (New-RegistryReceipts).$Kind
		$Recorded = $Provenance.build.cookedRegistries.$Kind
		foreach ($Field in $Expected.Keys) { Assert-True ($Recorded.$Field -ceq $Expected[$Field]) "Provenance must record the producer $Kind registry receipt $Field." }
	}
	Write-Output 'PASS: provenance records the producer-owned client and server cooked-registry receipts'

	$Failure = $null
	try { & $Script -OutputPath (Join-Path $FixtureRoot 'bad.json') -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -SourceRevision ('0' * 40) -BuildConfiguration Development -ClientArchivePath $Client -ServerArchivePath $Server -CompilerPath $Compiler -ResourceCompilerPath $ResourceCompiler -UatArgumentsJson $UatArguments -CookedRegistryReceiptsJson $CookedRegistryReceipts } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match repository HEAD') 'A requested revision not matching actual HEAD must fail.'
	Write-Output 'PASS: provenance refuses an unproven source revision'

	$CrossTarget = New-RegistryReceipts; $CrossTarget.client.cookPlatform = 'LinuxServer'
	$BadDigest = New-RegistryReceipts; $BadDigest.server.sha256 = ('B' * 64)
	$MissingServer = New-RegistryReceipts; $MissingServer.Remove('server')
	$ExtraField = New-RegistryReceipts; $ExtraField.client.stale = $true
	foreach ($ReceiptCase in @(
		@{ name = 'cross-target'; receipts = $CrossTarget; pattern = 'client cooked-registry receipt cookPlatform' },
		@{ name = 'cross-revision'; receipts = (New-RegistryReceipts ('1' * 40)); pattern = 'client cooked-registry receipt sourceRevision' },
		@{ name = 'bad-digest'; receipts = $BadDigest; pattern = 'server cooked-registry receipt sha256' },
		@{ name = 'missing-server'; receipts = $MissingServer; pattern = 'exactly client and server' },
		@{ name = 'extra-field'; receipts = $ExtraField; pattern = 'client cooked-registry receipt fields' }
	)) {
		$Failure = $null
		try { & $Script -OutputPath (Join-Path $FixtureRoot "bad-$($ReceiptCase.name).json") -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -SourceRevision $Revision -BuildConfiguration Development -ClientArchivePath $Client -ServerArchivePath $Server -CompilerPath $Compiler -ResourceCompilerPath $ResourceCompiler -UatArgumentsJson $UatArguments -CookedRegistryReceiptsJson ($ReceiptCase.receipts | ConvertTo-Json -Compress) } catch { $Failure = $_.Exception.Message }
		Assert-True ($null -ne $Failure -and $Failure -match $ReceiptCase.pattern) "A $($ReceiptCase.name) cooked-registry receipt must fail closed; observed '$Failure'."
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot "bad-$($ReceiptCase.name).json"))) "A $($ReceiptCase.name) cooked-registry receipt must not write provenance."
	}
	Write-Output 'PASS: missing, extra, malformed, cross-target, and cross-revision registry receipts fail closed'

	# Issue #226: without -BuildNumber the document keeps today's exact shape.
	Assert-True ((@($Provenance.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,createdUtc,host,source,build,tools,artifacts') 'Without -BuildNumber the provenance top-level shape must stay exactly as before.'
	Assert-True ((@($Provenance.host.PSObject.Properties.Name) -join ',') -ceq 'machineName,os,osArchitecture,processArchitecture,powershell,buildIdentity') 'Without -BuildNumber the host identity shape must stay exactly as before.'
	Assert-True ($Provenance.host.buildIdentity -ceq "AethelnOnline@$Revision/Development") 'host.buildIdentity must keep its exact format; the network-authority spike compares it byte for byte.'
	Write-Output 'PASS: provenance without -BuildNumber keeps its exact top-level and host shape'

	$BaseArguments = @{ EngineRoot = $EngineRoot; LinuxToolchainRoot = $ToolchainRoot; SourceRevision = $Revision; BuildConfiguration = 'Development'; ClientArchivePath = $Client; ServerArchivePath = $Server; CompilerPath = $Compiler; ResourceCompilerPath = $ResourceCompiler; UatArgumentsJson = $UatArguments; CookedRegistryReceiptsJson = $CookedRegistryReceipts }
	$SectionHeader = '[/Script/EngineSettings.GeneralProjectSettings]'
	function Initialize-VersionedProject([string] $Name, [string[]] $IniLines, [string] $LineEnding = "`n") {
		$Root = Join-Path $FixtureRoot ('project-' + $Name)
		New-Item -ItemType Directory -Path (Join-Path $Root 'Config') -Force | Out-Null
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -Destination $Root
		if ($null -ne $IniLines) { [IO.File]::WriteAllText((Join-Path $Root 'Config/DefaultGame.ini'), (($IniLines -join $LineEnding) + $LineEnding), (New-Object Text.UTF8Encoding($false))) }
		return Join-Path $Root 'AethelnOnline.uproject'
	}
	function Invoke-Provenance([string] $Name, [string] $Project, [hashtable] $Extra = @{}) {
		$Output = Join-Path $FixtureRoot ('case-' + $Name + '/build.json')
		$Arguments = $BaseArguments + $Extra + @{ OutputPath = $Output; ProjectPath = $Project }
		$Failure = $null
		try { [void] (& $Script @Arguments) } catch { $Failure = $_.Exception.Message }
		return @{ Path = $Output; Failure = $Failure; Written = (Test-Path -LiteralPath $Output) }
	}

	$ValidProject = Initialize-VersionedProject 'valid' @($SectionHeader, 'ProjectName=AethelnOnline', 'ProjectVersion=1.0.0-alpha.1')
	$Plain = Invoke-Provenance 'plain' $ValidProject
	$Released = Invoke-Provenance 'released' $ValidProject -Extra @{ BuildNumber = '7' }
	Assert-True ($null -eq $Plain.Failure -and $null -eq $Released.Failure -and $Plain.Written -and $Released.Written) "Provenance must be written with and without -BuildNumber. Failures: '$($Plain.Failure)' '$($Released.Failure)'"
	$PlainDocument = Get-Content -LiteralPath $Plain.Path -Raw | ConvertFrom-Json
	$ReleasedDocument = Get-Content -LiteralPath $Released.Path -Raw | ConvertFrom-Json
	Assert-True (-not ($PlainDocument.PSObject.Properties.Name -contains 'release')) 'A project that declares ProjectVersion must still get no release block without -BuildNumber.'
	Assert-True ((@($ReleasedDocument.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,createdUtc,host,source,build,tools,artifacts,release') 'The release block must be appended after the existing properties.'
	Assert-True ((@($ReleasedDocument.release.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,projectVersion,buildNumber,buildVersion') 'The release block must carry exactly its four fields in order.'
	Assert-True ($ReleasedDocument.release.schemaVersion -eq 1 -and $ReleasedDocument.release.projectVersion -ceq '1.0.0-alpha.1' -and $ReleasedDocument.release.buildNumber -eq 7 -and $ReleasedDocument.release.buildVersion -ceq '1.0.0-alpha.1+7') 'The release block must record the committed ProjectVersion, the build number, and their joined build version.'
	Assert-True ((Get-Content -LiteralPath $Released.Path -Raw) -match '"buildNumber":\s+7\b') 'The build number must be a JSON number, not a string.'
	Assert-True ($ReleasedDocument.host.buildIdentity -ceq "AethelnOnline@$Revision/Development") 'host.buildIdentity must not change when a release block is added.'
	# The release block and the cooked-registry receipts coexist in one document,
	# and a tampered receipt still refuses when a build number is given.
	Assert-True ((@($ReleasedDocument.build.cookedRegistries.PSObject.Properties.Name) -join ',') -ceq 'client,server' -and $ReleasedDocument.build.cookedRegistries.client.sha256 -ceq (New-RegistryReceipts).client.sha256) 'A release document must keep both cooked-registry receipts.'
	$TamperedArguments = $BaseArguments.Clone()
	$TamperedArguments.CookedRegistryReceiptsJson = $BadDigest | ConvertTo-Json -Compress
	$TamperedOutput = Join-Path $FixtureRoot 'case-tampered-release/build.json'
	$TamperedFailure = $null
	try { [void] (& $Script @TamperedArguments -BuildNumber '7' -OutputPath $TamperedOutput -ProjectPath $ValidProject) } catch { $TamperedFailure = $_.Exception.Message }
	Assert-True ($TamperedFailure -match 'server cooked-registry receipt sha256' -and -not (Test-Path -LiteralPath $TamperedOutput)) "A tampered receipt must refuse with -BuildNumber too; observed '$TamperedFailure'."
	# The release block is purely additive: removing it must leave the document
	# identical to the one written without -BuildNumber, apart from the clock.
	$PlainDocument.createdUtc = 'normalized'
	$ReleasedDocument.createdUtc = 'normalized'
	$ReleasedDocument.PSObject.Properties.Remove('release')
	Assert-True (($ReleasedDocument | ConvertTo-Json -Depth 12) -ceq ($PlainDocument | ConvertTo-Json -Depth 12)) '-BuildNumber must add the release block and change nothing else in the document.'
	$MaxNumber = Invoke-Provenance 'max-number' $ValidProject -Extra @{ BuildNumber = '9999999999' }
	Assert-True ($null -eq $MaxNumber.Failure -and (Get-Content -LiteralPath $MaxNumber.Path -Raw | ConvertFrom-Json).release.buildNumber -eq 9999999999) 'The largest accepted build number must be written as a number without overflow.'
	Write-Output 'PASS: -BuildNumber adds exactly one release block and changes nothing else'

	foreach ($ValidVersion in @('1.0.0', '0.0.0-test.226', '10.20.30-rc.1', '1.0.0-alpha-1.x-y', '1.0.0-0')) {
		$Project = Initialize-VersionedProject 'valid-version' @($SectionHeader, "ProjectVersion=$ValidVersion")
		$Result = Invoke-Provenance 'valid-version' $Project -Extra @{ BuildNumber = '3' }
		Assert-True ($null -eq $Result.Failure -and (Get-Content -LiteralPath $Result.Path -Raw | ConvertFrom-Json).release.buildVersion -ceq "$ValidVersion+3") "ProjectVersion '$ValidVersion' must be accepted. Failure: $($Result.Failure)"
		Remove-Item -LiteralPath (Split-Path -Parent $Result.Path) -Recurse -Force
	}
	$CrlfProject = Initialize-VersionedProject 'crlf' @('; leading comment', $SectionHeader, 'ProjectName=AethelnOnline', 'ProjectVersion=2.1.0', '', '[/Script/GameplayAbilities.AbilitySystemGlobals]', '+GameplayCueNotifyPaths=/Game') -LineEnding "`r`n"
	$Result = Invoke-Provenance 'crlf' $CrlfProject -Extra @{ BuildNumber = '3' }
	Assert-True ($null -eq $Result.Failure -and (Get-Content -LiteralPath $Result.Path -Raw | ConvertFrom-Json).release.buildVersion -ceq '2.1.0+3') "A CRLF ini with other sections must be read. Failure: $($Result.Failure)"
	# The engine trims trailing whitespace before it recognizes a section header.
	$TrailingHeaderProject = Initialize-VersionedProject 'trailing-header' @(($SectionHeader + " `t"), 'ProjectVersion=2.1.0')
	$Result = Invoke-Provenance 'trailing-header' $TrailingHeaderProject -Extra @{ BuildNumber = '3' }
	Assert-True ($null -eq $Result.Failure -and (Get-Content -LiteralPath $Result.Path -Raw | ConvertFrom-Json).release.buildVersion -ceq '2.1.0+3') "A target section header with trailing whitespace must be read as the engine reads it. Failure: $($Result.Failure)"
	Write-Output 'PASS: ProjectVersion is read from the exact section for SemVer values with or without CRLF'

	$MissingCases = @(
		@{ Name = 'no-line'; Lines = @($SectionHeader, 'ProjectName=AethelnOnline') },
		@{ Name = 'no-file'; Lines = $null }
	)
	foreach ($Case in $MissingCases) {
		$Result = Invoke-Provenance ('missing-' + $Case.Name) (Initialize-VersionedProject ('missing-' + $Case.Name) $Case.Lines) -Extra @{ BuildNumber = '7' }
		Assert-True ($Result.Failure -match '^project_version_missing' -and -not $Result.Written) "A missing ProjectVersion ($($Case.Name)) must fail closed as project_version_missing. Failure: $($Result.Failure)"
	}
	$InvalidCases = @(
		@{ Name = 'tilde-set'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0', '~ProjectVersion=9.9.9') },
		@{ Name = 'tilde-add'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0', '~+ProjectVersion=9.9.9') },
		@{ Name = 'lone-cr'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0', "ProjectName=AethelnOnline`rProjectVersion=9.9.9") },
		@{ Name = 'commented-header'; Lines = @($SectionHeader, '[/Script/Other] // note', 'ProjectVersion=1.0.0') },
		@{ Name = 'build-metadata'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0+3') },
		@{ Name = 'prerelease-and-metadata'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1+7') },
		@{ Name = 'v-prefix'; Lines = @($SectionHeader, 'ProjectVersion=v1.0.0') },
		@{ Name = 'two-parts'; Lines = @($SectionHeader, 'ProjectVersion=1.0') },
		@{ Name = 'four-parts'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0.0') },
		@{ Name = 'leading-zero'; Lines = @($SectionHeader, 'ProjectVersion=01.0.0') },
		@{ Name = 'empty-prerelease'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-') },
		@{ Name = 'numeric-prerelease-leading-zero'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-01') },
		@{ Name = 'empty-prerelease-identifier'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha..1') },
		@{ Name = 'underscore'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha_1') },
		@{ Name = 'trailing-space'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0 ') },
		@{ Name = 'leading-space'; Lines = @($SectionHeader, 'ProjectVersion= 1.0.0') },
		@{ Name = 'quoted'; Lines = @($SectionHeader, 'ProjectVersion="1.0.0"') },
		@{ Name = 'empty-value'; Lines = @($SectionHeader, 'ProjectVersion=') },
		@{ Name = 'duplicate-line'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0', 'ProjectVersion=1.0.1') },
		@{ Name = 'only-in-other-section'; Lines = @($SectionHeader, 'ProjectName=AethelnOnline', '[/Script/GameplayAbilities.AbilitySystemGlobals]', 'ProjectVersion=1.0.0') },
		@{ Name = 'lowercase-key'; Lines = @($SectionHeader, 'projectversion=1.0.0') },
		@{ Name = 'lowercase-section'; Lines = @('[/script/enginesettings.generalprojectsettings]', 'ProjectVersion=1.0.0') },
		@{ Name = 'array-operator'; Lines = @($SectionHeader, '+ProjectVersion=1.0.0') },
		@{ Name = 'duplicate-case-variant'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0', 'PROJECTVERSION=2.0.0') },
		# Engine-parser parity: these files assign the value to another section or
		# join it into another line, so the build would not use it.
		@{ Name = 'other-section-trailing-space-header'; Lines = @($SectionHeader, '[/Script/Other] ', 'ProjectVersion=1.0.0') },
		@{ Name = 'other-section-inner-bracket-header'; Lines = @($SectionHeader, '[/Script/Other]x]', 'ProjectVersion=1.0.0') },
		@{ Name = 'line-continuation'; Lines = @($SectionHeader, 'ProjectName=AethelnOnline\', 'ProjectVersion=1.0.0') },
		@{ Name = 'bracket-block'; Lines = @($SectionHeader, 'ProjectName={', 'ProjectVersion=1.0.0', '}') }
	)
	foreach ($Case in $InvalidCases) {
		$Project = Initialize-VersionedProject ('invalid-' + $Case.Name) $Case.Lines
		$Result = Invoke-Provenance ('invalid-' + $Case.Name) $Project -Extra @{ BuildNumber = '7' }
		Assert-True ($Result.Failure -match '^project_version_invalid' -and -not $Result.Written) "ProjectVersion case '$($Case.Name)' must fail closed as project_version_invalid. Failure: $($Result.Failure)"
		$Inert = Invoke-Provenance ('inert-' + $Case.Name) $Project
		Assert-True ($null -eq $Inert.Failure -and -not ((Get-Content -LiteralPath $Inert.Path -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'release')) "ProjectVersion case '$($Case.Name)' must be ignored entirely when -BuildNumber is absent. Failure: $($Inert.Failure)"
	}
	Write-Output 'PASS: a missing or malformed ProjectVersion fails closed only when -BuildNumber is present'
	foreach ($OverrideCase in @(
		@{ Name = 'linux-braced'; Line = 'Project{Version}=9.9.9' },
		@{ Name = 'linux-tilde'; Line = '~ProjectVersion=9.9.9' },
		@{ Name = 'linux-reset'; Line = '^ProjectVersion=' }
	)) {
		$Name = $OverrideCase.Name
		$OverrideLine = $OverrideCase.Line
		$Project = Initialize-VersionedProject $Name @($SectionHeader, 'ProjectVersion=1.0.0')
		$LinuxConfig = Join-Path (Split-Path -Parent $Project) 'Config/Linux'
		New-Item -ItemType Directory -Path $LinuxConfig -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $LinuxConfig 'LinuxGame.ini'), "$SectionHeader`n$OverrideLine`n")
		$Result = Invoke-Provenance $Name $Project -Extra @{ BuildNumber = '7' }
		Assert-True ($Result.Failure -match '^project_version_override' -and -not $Result.Written) "Platform override '$Name' must fail before release provenance is written. Failure: $($Result.Failure)"
		$Inert = Invoke-Provenance ($Name + '-inert') $Project
		Assert-True ($null -eq $Inert.Failure) 'Platform version scanning must remain inert without BuildNumber.'
	}

	$ArabicIndicThree = [string][char] 0x0663
	foreach ($BadNumber in @('0', '01', 'abc', '12345678901', '', '-1', '+7', '7.0', ' 7', '7 ', "7`n", $ArabicIndicThree)) {
		$Result = Invoke-Provenance 'bad-number' $ValidProject -Extra @{ BuildNumber = $BadNumber }
		Assert-True ($Result.Failure -match '^build_number_invalid' -and -not $Result.Written) "Build number '$BadNumber' must fail closed as build_number_invalid. Failure: $($Result.Failure)"
	}
	Write-Output 'PASS: build numbers must be positive integers of at most ten ASCII digits'
}
finally {
	if ($null -ne $OriginalPath) { $env:PATH = $OriginalPath }
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
