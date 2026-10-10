<#
.SYNOPSIS
Writes verified, file-level provenance for packaged Aetheln artifacts.
.PARAMETER BuildNumber
Optional release build number: a positive integer of at most ten digits
without a leading zero. When present, the committed ProjectVersion is read
case-sensitively from Config/DefaultGame.ini of the verified clean HEAD,
validated as SemVer without build metadata, and recorded with the number in a
release block. Without it the document is unchanged and ProjectVersion is not
read.
.EXAMPLE
./scripts/build/Write-BuildProvenance.ps1 -OutputPath D:/Builds/run/build-provenance.json -ProjectPath ./AethelnOnline.uproject -EngineRoot D:/UnrealEngine/UE-5.8.1-source-issue81-clean -LinuxToolchainRoot C:/UnrealToolchains/v26_clang-20.1.8-rockylinux8 -SourceRevision e5798da01cc8dddb70c0a586843ddd2294dbfef3 -BuildConfiguration Development -ClientArchivePath D:/Builds/run/WindowsClient -ServerArchivePath D:/Builds/run/LinuxServer -CompilerPath 'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe' -ResourceCompilerPath 'C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/rc.exe' -UatArgumentsJson '{"client":["BuildCookRun"],"server":["BuildCookRun"],"dependencyRegistryDump":["-run=DumpAssetRegistry","-DependencyDetails"],"cookedInventoryDump":["-run=DumpAssetRegistry","-PackageName"]}' -CookedRegistryReceiptsJson (Get-Content -Raw D:/Builds/run/cooked-registry-receipts.json)

CookedRegistryReceiptsJson carries the packaging producer's client and server
Saved/Cooked AssetRegistry.bin receipts, captured immediately after each cook.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [string] $OutputPath,
	[Parameter(Mandatory)] [string] $ProjectPath,
	[Parameter(Mandatory)] [string] $EngineRoot,
	[Parameter(Mandatory)] [string] $LinuxToolchainRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[Parameter(Mandatory)] [ValidateSet('Development', 'Shipping', 'Test')] [string] $BuildConfiguration,
	[Parameter(Mandatory)] [string] $ClientArchivePath,
	[Parameter(Mandatory)] [string] $ServerArchivePath,
	[Parameter(Mandatory)] [string] $CompilerPath,
	[Parameter(Mandatory)] [string] $ResourceCompilerPath,
	[Parameter(Mandatory)] [string] $UatArgumentsJson,
	[Parameter(Mandatory)] [string] $CookedRegistryReceiptsJson,
	[string] $PackageRecipeJson,
	[string] $BuildNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Resolve-RequiredPath([string] $Name, [string] $Path, [string] $PathType) {
	if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) { throw "$Name '$Path' does not exist or is not a $($PathType.ToLowerInvariant())." }
	(Resolve-Path -LiteralPath $Path).Path
}
function Invoke-IdentityCommand([string] $File, [string[]] $Arguments) {
	try { $Value = (& $File @Arguments 2>&1 | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $Value) { return $Value } } catch { Write-Verbose "Identity command probe failed, so that provenance field stays unavailable: $($_.Exception.Message)" }
	return $null
}
function Get-OptionalProperty($Object, [string] $Name) {
	$Property = $Object.PSObject.Properties[$Name]
	if ($null -eq $Property) { return @() }
	return @($Property.Value)
}
. (Join-Path $PSScriptRoot 'ProjectVersion.ps1')
. (Join-Path $PSScriptRoot 'PackagingRecipeProof.ps1')

$HasBuildNumber = $PSBoundParameters.ContainsKey('BuildNumber')
if ($HasBuildNumber -and $BuildNumber -cnotmatch '^[1-9][0-9]{0,9}\z') { throw 'build_number_invalid: -BuildNumber must be a positive integer of at most ten digits without a leading zero.' }
$ResolvedProject = Resolve-RequiredPath -Name 'ProjectPath' -Path $ProjectPath -PathType 'Leaf'
$RepositoryRoot = Split-Path -Parent $ResolvedProject
$ResolvedEngine = Resolve-RequiredPath -Name 'EngineRoot' -Path $EngineRoot -PathType 'Container'
$ResolvedToolchain = Resolve-RequiredPath -Name 'LinuxToolchainRoot' -Path $LinuxToolchainRoot -PathType 'Container'
$ResolvedClient = Resolve-RequiredPath -Name 'ClientArchivePath' -Path $ClientArchivePath -PathType 'Container'
$ResolvedServer = Resolve-RequiredPath -Name 'ServerArchivePath' -Path $ServerArchivePath -PathType 'Container'
$ResolvedCompiler = Resolve-RequiredPath -Name 'CompilerPath' -Path $CompilerPath -PathType 'Leaf'
$ResolvedResourceCompiler = Resolve-RequiredPath -Name 'ResourceCompilerPath' -Path $ResourceCompilerPath -PathType 'Leaf'
$ActualRevision = Invoke-IdentityCommand 'git' @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
if (-not $ActualRevision) { throw "Could not determine repository HEAD for '$RepositoryRoot'." }
if ($ActualRevision -ne $SourceRevision) { throw "Requested SourceRevision '$SourceRevision' does not match repository HEAD '$ActualRevision'." }
$StatusCommand = @('git', '-C', $RepositoryRoot, 'status', '--porcelain=v1', '--untracked-files=all')
$SourceStatus = @(& $StatusCommand[0] $StatusCommand[1..($StatusCommand.Count - 1)] 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Could not verify repository cleanliness with '$($StatusCommand -join ' ')': $($SourceStatus -join [Environment]::NewLine)" }
$SourceChanges = @($SourceStatus | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($SourceChanges.Count -gt 0) { throw "Provenance requires a clean repository but found $($SourceChanges.Count) modified or untracked path(s):`n - $($SourceChanges -join "`n - ")" }

$ReleaseBlock = $null
if ($HasBuildNumber) {
	$ProjectVersion = Read-ProjectVersion (Join-Path $RepositoryRoot 'Config/DefaultGame.ini')
	$ReleaseBlock = [ordered]@{ schemaVersion = 1; projectVersion = $ProjectVersion; buildNumber = [long] $BuildNumber; buildVersion = "$ProjectVersion+$BuildNumber" }
}

$BuildVersionPath = Resolve-RequiredPath -Name 'Unreal Build.version' -Path (Join-Path $ResolvedEngine 'Engine/Build/Build.version') -PathType 'Leaf'
try { $BuildVersion = Get-Content -LiteralPath $BuildVersionPath -Raw | ConvertFrom-Json } catch { throw "Unreal identity file '$BuildVersionPath' is not valid JSON: $($_.Exception.Message)" }
$ToolchainRootIdentity = Split-Path -Leaf $ResolvedToolchain
$ToolchainCompilerRoot = Resolve-RequiredPath -Name 'Linux cross-toolchain x86_64-unknown-linux-gnu directory' -Path (Join-Path $ResolvedToolchain 'x86_64-unknown-linux-gnu') -PathType 'Container'
$ToolchainCompiler = Get-ChildItem -LiteralPath $ToolchainCompilerRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('clang++.exe', 'clang.exe', 'clang++.bat', 'clang.bat') } | Sort-Object FullName | Select-Object -First 1
if (-not $ToolchainCompiler) { throw "Linux cross-toolchain identity could not find clang under '$ToolchainCompilerRoot'." }
$ToolchainCompilerBanner = Invoke-IdentityCommand $ToolchainCompiler.FullName @('--version')
if (-not $ToolchainCompilerBanner) { throw "Linux cross-toolchain compiler '$($ToolchainCompiler.FullName)' did not provide a version identity." }
$ToolchainMarker = Get-ChildItem -LiteralPath $ResolvedToolchain -File | Where-Object { $_.Name -match '(?i)(version|toolchain)' } | Sort-Object Name | Select-Object -First 1
$UatInvocations = ConvertFrom-PackageProofJson $UatArgumentsJson
Assert-PackageProofFields $UatInvocations @('client', 'server', 'dependencyRegistryDump', 'cookedInventoryDump')
if ([string]::IsNullOrWhiteSpace($PackageRecipeJson) -and @($UatInvocations.client + $UatInvocations.server | Where-Object { $_ -imatch '^-skipbuild(?:=|$)' }).Count) { Stop-PackageRecipe 'proof_missing' }
$RecordedUatInvocations = [ordered]@{
	client = [ordered]@{ arguments = @($UatInvocations.client) }
	server = [ordered]@{ arguments = @($UatInvocations.server) }
	dependencyRegistryDump = [ordered]@{ arguments = @($UatInvocations.dependencyRegistryDump) }
	cookedInventoryDump = [ordered]@{ arguments = @($UatInvocations.cookedInventoryDump) }
}
# The producer hashes each canonical cooked registry immediately after its own
# cook; consumers compare later registry bytes against these receipts.
try { $CookedRegistryReceipts = $CookedRegistryReceiptsJson | ConvertFrom-Json } catch { throw "CookedRegistryReceiptsJson is invalid JSON: $($_.Exception.Message)" }
if ($null -eq $CookedRegistryReceipts -or (@($CookedRegistryReceipts.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'client,server') { throw 'CookedRegistryReceiptsJson must contain exactly client and server cooked-registry receipts.' }
$RecordedCookedRegistries = [ordered]@{}
foreach ($Expected in @(
	[ordered]@{ kind = 'client'; target = 'AethelnOnlineClient'; platform = 'Win64'; cookPlatform = 'WindowsClient' },
	[ordered]@{ kind = 'server'; target = 'AethelnOnlineServer'; platform = 'Linux'; cookPlatform = 'LinuxServer' }
)) {
	$Receipt = $CookedRegistryReceipts.($Expected.kind)
	$Context = "$($Expected.kind) cooked-registry receipt"
	$ReceiptFields = @('relativePath', 'sizeBytes', 'sha256', 'target', 'platform', 'cookPlatform', 'sourceRevision')
	if ($null -eq $Receipt -or (@($Receipt.PSObject.Properties.Name | Sort-Object) -join ',') -cne (@($ReceiptFields | Sort-Object) -join ',')) { throw "$Context fields must be exactly $($ReceiptFields -join ', ')." }
	foreach ($Field in @('target', 'platform', 'cookPlatform')) {
		if ($Receipt.$Field -cne $Expected[$Field]) { throw "$Context $Field '$($Receipt.$Field)' does not match '$($Expected[$Field])'." }
	}
	$ExpectedRelativePath = "Saved/Cooked/$($Expected.cookPlatform)/AethelnOnline/AssetRegistry.bin"
	if ($Receipt.relativePath -cne $ExpectedRelativePath) { throw "$Context relativePath must be '$ExpectedRelativePath'." }
	if ($Receipt.sha256 -isnot [string] -or $Receipt.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "$Context sha256 must be a lowercase SHA-256 digest." }
	if (-not ($Receipt.sizeBytes -is [int] -or $Receipt.sizeBytes -is [long]) -or $Receipt.sizeBytes -le 0) { throw "$Context sizeBytes must be a positive integer." }
	if ($Receipt.sourceRevision -isnot [string] -or -not $Receipt.sourceRevision.Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw "$Context sourceRevision '$($Receipt.sourceRevision)' does not match '$SourceRevision'." }
	$RecordedCookedRegistries[$Expected.kind] = [ordered]@{ relativePath = $Receipt.relativePath; sizeBytes = [long] $Receipt.sizeBytes; sha256 = $Receipt.sha256; target = $Receipt.target; platform = $Receipt.platform; cookPlatform = $Receipt.cookPlatform; sourceRevision = $Receipt.sourceRevision }
}
$ProjectDescriptor = Get-Content -LiteralPath $ResolvedProject -Raw | ConvertFrom-Json

$EngineRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngine, 'rev-parse', 'HEAD')
if ($ResolvedCompiler -notmatch '[\\/]MSVC[\\/](?<MsvcVersion>[^\\/]+)[\\/].*[\\/]cl\.exe$') { throw "CompilerPath '$ResolvedCompiler' does not identify an MSVC versioned cl.exe path." }
$MsvcVersion = $Matches.MsvcVersion
if ($ResolvedResourceCompiler -notmatch '^(?<SdkRoot>.*[\\/]Windows Kits[\\/]10)[\\/]bin[\\/](?<SdkVersion>[^\\/]+)[\\/].*[\\/]rc\.exe$') { throw "ResourceCompilerPath '$ResolvedResourceCompiler' does not identify a versioned Windows 10 SDK rc.exe path." }
$WindowsSdkRoot = $Matches.SdkRoot
$WindowsSdkVersion = $Matches.SdkVersion
$CompilerIdentity = [ordered]@{ path = $ResolvedCompiler; version = $MsvcVersion; fileVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($ResolvedCompiler)).FileVersion; sha256 = (Get-FileHash -LiteralPath $ResolvedCompiler -Algorithm SHA256).Hash.ToLowerInvariant() }
$WindowsSdk = [ordered]@{ version = $WindowsSdkVersion; root = $WindowsSdkRoot; resourceCompilerPath = $ResolvedResourceCompiler; resourceCompilerFileVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($ResolvedResourceCompiler)).FileVersion; resourceCompilerSha256 = (Get-FileHash -LiteralPath $ResolvedResourceCompiler -Algorithm SHA256).Hash.ToLowerInvariant() }
$HostIdentity = [ordered]@{ machineName = [Environment]::MachineName; os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription; osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString(); powershell = $PSVersionTable.PSVersion.ToString(); buildIdentity = "AethelnOnline@$ActualRevision/$BuildConfiguration" }

$Inventory = foreach ($Archive in @(@{ Kind = 'client'; Root = $ResolvedClient }, @{ Kind = 'server'; Root = $ResolvedServer })) {
	foreach ($File in Get-ChildItem -LiteralPath $Archive.Root -Recurse -File | Sort-Object FullName) {
		$RelativePath = $File.FullName.Substring($Archive.Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
		[ordered]@{ kind = $Archive.Kind; path = $RelativePath; sizeBytes = $File.Length; sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
	}
}

$Document = [ordered]@{
	schemaVersion = 2; createdUtc = [DateTime]::UtcNow.ToString('o'); host = $HostIdentity
	source = [ordered]@{ revision = $ActualRevision; repositoryRoot = $RepositoryRoot; clean = $true; statusCommand = $StatusCommand; project = $ResolvedProject; projectSha256 = (Get-FileHash -LiteralPath $ResolvedProject -Algorithm SHA256).Hash.ToLowerInvariant(); plugins = @($ProjectDescriptor.Plugins | ForEach-Object { [ordered]@{ name = $_.Name; enabled = $_.Enabled; targetAllowList = @(Get-OptionalProperty $_ 'TargetAllowList'); targetDenyList = @(Get-OptionalProperty $_ 'TargetDenyList'); descriptor = $_ } }) }
	build = [ordered]@{ configuration = $BuildConfiguration; clientPlatform = 'Win64'; serverPlatform = 'Linux'; clientTarget = 'AethelnOnlineClient'; serverTarget = 'AethelnOnlineServer'; uatInvocations = $RecordedUatInvocations; cookedRegistries = $RecordedCookedRegistries }
	tools = [ordered]@{ unreal = [ordered]@{ root = $ResolvedEngine; repositoryRevision = $EngineRevision; build = $BuildVersion; buildVersionSha256 = (Get-FileHash -LiteralPath $BuildVersionPath -Algorithm SHA256).Hash.ToLowerInvariant() }; compiler = $CompilerIdentity; windowsSdk = $WindowsSdk; linuxCrossToolchain = [ordered]@{ identity = $ToolchainRootIdentity; root = $ResolvedToolchain; compilerPath = $ToolchainCompiler.FullName; compilerBanner = $ToolchainCompilerBanner; compilerFileVersion = $ToolchainCompiler.VersionInfo.FileVersion; compilerSha256 = (Get-FileHash -LiteralPath $ToolchainCompiler.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); versionMarker = if ($ToolchainMarker) { [ordered]@{ path = $ToolchainMarker.FullName; sha256 = (Get-FileHash -LiteralPath $ToolchainMarker.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } } else { $null } } }
	artifacts = [ordered]@{ clientArchive = $ResolvedClient; serverArchive = $ResolvedServer; inventory = @($Inventory) }
}
if ($null -ne $ReleaseBlock) { $Document['release'] = $ReleaseBlock }
if (-not [string]::IsNullOrWhiteSpace($PackageRecipeJson)) {
	$Document.build['packageRecipe'] = ConvertFrom-PackageProofJson $PackageRecipeJson
	$ParsedDocument = ConvertFrom-PackageProofJson ($Document | ConvertTo-Json -Depth 32 -Compress)
	Assert-PackageRecipeProvenance $ParsedDocument
	foreach ($Kind in @('client', 'server')) { Assert-PackageSourcePins $ParsedDocument.build.packageRecipe.$Kind.sourceIdentity.targetRulePins @(Get-PackageTargetRulePins $RepositoryRoot) $ResolvedEngine $RepositoryRoot }
	Assert-PackageRecipePayloads $ParsedDocument (Split-Path -Parent $ResolvedClient) (Split-Path -Parent $ResolvedServer)
	$Selected = $ParsedDocument.build.packageRecipe
	if ($Selected.client.engineIdentity.selectedTools.compiler.path -cne $ResolvedCompiler -or $Selected.client.engineIdentity.selectedTools.compiler.sha256 -cne $CompilerIdentity.sha256 -or $Selected.client.engineIdentity.selectedTools.resourceCompiler.path -cne $ResolvedResourceCompiler -or $Selected.client.engineIdentity.selectedTools.resourceCompiler.sha256 -cne $WindowsSdk.resourceCompilerSha256 -or $Selected.server.engineIdentity.selectedTools.linuxCompiler.path -cne $ToolchainCompiler.FullName -or $Selected.server.engineIdentity.selectedTools.linuxCompiler.sha256 -cne $Document.tools.linuxCrossToolchain.compilerSha256) { Stop-PackageRecipe 'tool_changed' }
}
$Parent = Split-Path -Parent $OutputPath
if (-not $Parent) { $Parent = (Get-Location).Path }
New-Item -ItemType Directory -Path $Parent -Force | Out-Null
$Document | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "Build provenance written to '$OutputPath'."
