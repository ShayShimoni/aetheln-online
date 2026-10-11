[CmdletBinding()]
param([string] $PackagePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SuiteSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiSuite.ps1') -Raw
$ExpectedRegistration = "name = 'runner-scheduling-policy-tests'; tier = 'required'; script = 'tests/ci/Invoke-RunnerSchedulingAndPreparationTests.ps1'"
if (-not $SuiteSource.Contains($ExpectedRegistration)) { throw 'The existing required scheduling identity must run the composite preparation fixture.' }
. (Join-Path $PSScriptRoot 'PinnedPreparationYaml.ps1')
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnPinnedYamlTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

function Assert-Condition {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
	param([scriptblock] $Action, [string] $Reason)
	$Actual = ''
	try { & $Action | Out-Null } catch { $Actual = $_.Exception.Message }
	Assert-Condition -Condition ($Actual -ceq $Reason) -Message "Expected '$Reason'; received '$Actual'."
}

function New-YamlFixtureArchive {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only uniquely named test archives beneath the owned fixture root.')]
	param([string] $Name, [string[]] $EntryNames, [byte[]] $Bytes)
	$Path = Join-Path $FixtureRoot ($Name + '.zip')
	$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
	$Archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create)
	try {
		foreach ($EntryName in $EntryNames) {
			$EntryStream = $Archive.CreateEntry($EntryName).Open()
			try { $EntryStream.Write($Bytes, 0, $Bytes.Length) } finally { $EntryStream.Dispose() }
		}
	} finally { $Archive.Dispose(); $Stream.Dispose() }
	return $Path
}

$Verified = Get-PinnedPreparationYaml -PackagePath $PackagePath -CacheRoot $FixtureRoot
Assert-Condition -Condition ($Verified.AssemblySha256 -ceq 'd35c770d92632bd94bba4203db05eee5ebce6e6ea6d92e7ebe8997a942b5321c') -Message 'The official net47 DLL must match the accepted admission pin.'
Assert-Condition -Condition ($Verified.PackageSha256 -ceq 'd4602bc7a4a093766520422d53ca8b09acde162286fae11e2ee6c8edfea07810') -Message 'The immutable official archive digest must match.'
Assert-Condition -Condition ((Get-Item -LiteralPath $Verified.AssemblyPath).Length -eq 288256) -Message 'The pinned DLL length must match.'
Assert-Condition -Condition ([IO.Path]::GetFileName($Verified.AssemblyPath) -ceq 'YamlDotNet.dll') -Message 'The extraction must retain the closed DLL filename.'
Write-Output 'PASS: the official pinned archive produces the exact net47 admission assembly'

$BadPackage = Join-Path $FixtureRoot 'bad-package.nupkg'
[IO.File]::WriteAllBytes($BadPackage, [byte[]]::new(327106))
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath $BadPackage -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_package_invalid'
$ShortPackage = Join-Path $FixtureRoot 'short-package.nupkg'
[IO.File]::WriteAllBytes($ShortPackage, [byte[]]@(1, 2, 3))
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath $ShortPackage -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_package_invalid'
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath 'relative.nupkg' -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_path_invalid'
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath (Join-Path $FixtureRoot 'absent.nupkg') -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_path_invalid'
Write-Output 'PASS: wrong archive digest, length, relative path, and missing package fail before extraction'

$DllBytes = [IO.File]::ReadAllBytes($Verified.AssemblyPath)
$WrongEntry = New-YamlFixtureArchive -Name 'wrong-entry' -EntryNames @('lib/netstandard2.1/YamlDotNet.dll') -Bytes $DllBytes
$CaseVariant = New-YamlFixtureArchive -Name 'case-variant-entry' -EntryNames @('lib/net47/yamldotnet.dll') -Bytes $DllBytes
$Traversal = New-YamlFixtureArchive -Name 'traversal-entry' -EntryNames @('lib/net47/../net47/YamlDotNet.dll') -Bytes $DllBytes
$Duplicate = New-YamlFixtureArchive -Name 'duplicate-entry' -EntryNames @('lib/net47/YamlDotNet.dll', 'lib/net47/YamlDotNet.dll') -Bytes $DllBytes
$ShortDll = New-YamlFixtureArchive -Name 'short-dll' -EntryNames @('lib/net47/YamlDotNet.dll') -Bytes ([byte[]]@(1, 2, 3))
$WrongDll = New-YamlFixtureArchive -Name 'wrong-dll' -EntryNames @('lib/net47/YamlDotNet.dll') -Bytes ([byte[]]::new(288256))
foreach ($InvalidArchive in @($WrongEntry, $CaseVariant, $Traversal, $Duplicate, $ShortDll, $WrongDll)) {
	Assert-Rejected -Action { Read-PinnedPreparationYamlBytes -PackagePath $InvalidArchive } -Reason 'preparation_yaml_assembly_invalid'
}
Write-Output 'PASS: only one exact net47 entry with the pinned DLL length and digest is accepted'

# The byte reader is a separate unit boundary. The acquisition path must still
# verify the whole package first, even when another archive embeds genuine DLL bytes.
$OtherContainer = New-YamlFixtureArchive -Name 'other-container' -EntryNames @('lib/net47/YamlDotNet.dll') -Bytes $DllBytes
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath $OtherContainer -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_package_invalid'
$PackageDirectoryLink = Join-Path $FixtureRoot 'package-directory-link'
[void] (New-Item -ItemType Junction -Path $PackageDirectoryLink -Target (Split-Path -Parent $Verified.PackagePath))
$PackageLink = Join-Path $PackageDirectoryLink ([IO.Path]::GetFileName($Verified.PackagePath))
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath $PackageLink -CacheRoot $FixtureRoot } -Reason 'preparation_yaml_path_invalid'
$CacheLink = Join-Path $FixtureRoot 'cache-link'
[void] (New-Item -ItemType Junction -Path $CacheLink -Target $FixtureRoot)
Assert-Rejected -Action { Get-PinnedPreparationYaml -PackagePath $Verified.PackagePath -CacheRoot $CacheLink } -Reason 'preparation_yaml_path_invalid'
Write-Output 'PASS: a genuine DLL in an unpinned container and reparse-point package/cache paths fail closed'

# Issue #299: a transient download failure on a hosted runner is retried a bounded number of times,
# and the downloaded bytes still pass the same package pin.
$script:DownloadAttempts = 0
$GoodBytes = [IO.File]::ReadAllBytes($Verified.PackagePath)
$FlakyThenGood = { $script:DownloadAttempts++; if ($script:DownloadAttempts -lt 3) { throw 'transient network error' }; return ,$GoodBytes }
$Retried = Get-PinnedPreparationYaml -CacheRoot $FixtureRoot -Download $FlakyThenGood -RetryDelaySeconds 0
Assert-Condition -Condition ($script:DownloadAttempts -eq 3 -and $Retried.PackageSha256 -ceq $Verified.PackageSha256) -Message 'Two transient download failures must be retried and the third attempt must succeed.'
$script:DownloadAttempts = 0
$AlwaysFails = { $script:DownloadAttempts++; throw 'transient network error' }
Assert-Rejected -Action { Get-PinnedPreparationYaml -CacheRoot $FixtureRoot -Download $AlwaysFails -RetryDelaySeconds 0 } -Reason 'preparation_yaml_download_failed'
Assert-Condition -Condition ($script:DownloadAttempts -eq 3) -Message 'The download must stop after three attempts.'
$script:DownloadAttempts = 0
$WrongBytes = { $script:DownloadAttempts++; return ,([byte[]]::new(327106)) }
Assert-Rejected -Action { Get-PinnedPreparationYaml -CacheRoot $FixtureRoot -Download $WrongBytes -RetryDelaySeconds 0 } -Reason 'preparation_yaml_package_invalid'
Assert-Condition -Condition ($script:DownloadAttempts -eq 1) -Message 'A completed download with the wrong bytes is an integrity failure and must not be retried.'
Write-Output 'PASS: a transient download failure is retried three times at most; wrong bytes are never retried'

$WrapperSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-RunnerSchedulingAndPreparationTests.ps1') -Raw
foreach ($RequiredFixture in @('Test-RunnerSchedulingPolicy.Tests.ps1', 'PinnedPreparationYaml.Tests.ps1', 'InitialPreparation.GitHub.Tests.ps1')) {
	Assert-Condition -Condition ($WrapperSource.Contains($RequiredFixture)) -Message "The composite must run '$RequiredFixture'."
}
Assert-Condition -Condition ($WrapperSource -match '-NoProfile -File') -Message 'The existing preparation fixture must run with its documented File invocation.'
Assert-Condition -Condition ($WrapperSource -match 'CreateNoWindow\s*=\s*\$true') -Message 'Composite child processes must launch hidden.'
Assert-Condition -Condition ($WrapperSource -match 'RedirectStandardOutput\s*=\s*\$true' -and $WrapperSource -match 'RedirectStandardError\s*=\s*\$true') -Message 'Hidden composite children must explicitly capture both output streams.'
Assert-Condition -Condition ($WrapperSource -match 'exit \$ExitCode') -Message 'Composite child failure must reach the required check.'
Write-Output 'PASS: the unchanged required check identity covers all composite fixtures and forwards child failure'
Write-Output "Pinned YAML fixtures retained at '$FixtureRoot'."
