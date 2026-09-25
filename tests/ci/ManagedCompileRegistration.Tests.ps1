param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$Module = Join-Path $RepositoryRoot 'scripts/ci/ManagedCompileRegistration.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) { throw 'managed_registration_module_missing' }
. $Module
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnRegistration-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$Target = Join-Path $FixtureRoot 'target'
$Common = Join-Path $Target '.git'
$null = New-Item -ItemType Directory -Path $Common
$Record = [ordered]@{ schemaVersion = 1; registrationId = ('a' * 32); repository = 'Fixture/project'; targetRoot = $Target; gitCommonDirectory = $Common; preparationReceiptSha256 = ('b' * 64) }
function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function New-RegistrationFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test-only new uniquely named fixture files, preserved after execution.')]
	[CmdletBinding()]
	[OutputType([hashtable])]
	param([string] $Text)
	$Path = Join-Path $FixtureRoot ([guid]::NewGuid().ToString('N') + '.json')
	[IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
	return @{ Path = $Path; ExpectedSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant(); Repository = 'Fixture/project'; TargetRoot = $Target }
}
function Assert-Rejected([hashtable] $Arguments) {
	$Failure = ''
	try { $Unexpected = Get-ManagedCompileRegistration @Arguments; Close-ManagedCompileRegistration -Registration $Unexpected } catch { $Failure = $_.Exception.Message }
	Assert-True -Condition ($Failure -ceq 'managed_registration_invalid') -Message "closed rejection, got $Failure"
}
$Good = New-RegistrationFixture -Text ($Record | ConvertTo-Json -Compress)
$Registration = Get-ManagedCompileRegistration @Good
try {
	Assert-True -Condition ($Registration.record.registrationId -ceq $Record.registrationId) -Message 'identity retained'
	Assert-True -Condition ($Registration.proof.sha256 -ceq $Good.ExpectedSha256) -Message 'digest bound'
	$Denied = $false
	try { $Writer = [IO.File]::Open($Good.Path, 'Open', 'Write', 'ReadWrite'); $Writer.Dispose() } catch { $Denied = $true }
	Assert-True -Condition $Denied -Message 'retained file handle denies writes'
} finally { Close-ManagedCompileRegistration -Registration $Registration }
Close-ManagedCompileRegistration -Registration $Registration
$Writer = [IO.File]::Open($Good.Path, 'Open', 'Write', 'ReadWrite'); $Writer.Dispose()
$Wrong = $Good.Clone(); $Wrong.ExpectedSha256 = '0' * 64; Assert-Rejected -Arguments $Wrong
$Json = $Record | ConvertTo-Json -Compress
foreach ($BadJson in @(
	$Json.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":1,"SchemaVersion":1'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":1,"\u0073chemaVersion":1'),
	$Json.Replace('"schemaVersion":1', '"SchemaVersion":1'),
	$Json.Replace('"schemaVersion":1', '"\u0073chemaVersion":1'),
	$Json.Replace('"schemaVersion":1,', ''),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":"1"'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":1.0'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":true'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":null'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":[]'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":{}'),
	$Json.Replace('"schemaVersion":1', '"schemaVersion":1,"extra":"x"'),
	('[' + $Json + ']'), ($Json + 'garbage'), ($Json + ','),
	((' ' * 8193) + $Json), ([string][char]0xfeff + $Json)
)) { Assert-Rejected -Arguments (New-RegistrationFixture -Text $BadJson) }
foreach ($Field in @('registrationId', 'repository', 'targetRoot', 'gitCommonDirectory', 'preparationReceiptSha256')) {
	foreach ($Value in @($null, 1, $true, @(), @{})) {
		$BadRecord = [ordered]@{}
		foreach ($Key in $Record.Keys) { $BadRecord[$Key] = $Record[$Key] }
		$BadRecord[$Field] = $Value
		Assert-Rejected -Arguments (New-RegistrationFixture -Text ($BadRecord | ConvertTo-Json -Compress))
	}
}
foreach ($BadHash in @(('B' * 64), ('b' * 63), ('g' * 64), (('b' * 64) + "`n"))) {
	$Wrong = $Good.Clone(); $Wrong.ExpectedSha256 = $BadHash; Assert-Rejected -Arguments $Wrong
}
foreach ($Field in @('registrationId', 'preparationReceiptSha256')) {
	foreach ($BadValue in @('invalid', ('A' * 64), ($Record[$Field] + "`n"))) {
		$BadRecord = [ordered]@{}
		foreach ($Key in $Record.Keys) { $BadRecord[$Key] = $Record[$Key] }
		$BadRecord[$Field] = $BadValue
		Assert-Rejected -Arguments (New-RegistrationFixture -Text ($BadRecord | ConvertTo-Json -Compress))
	}
}
foreach ($BadPath in @('C:\', '\\localhost\share\registration.json', 'relative.json', 'C:relative.json', ($Good.Path + ':alternate'),
	(Join-Path $FixtureRoot '.env'), (Join-Path $FixtureRoot '.env.local'), (Join-Path $FixtureRoot '.ssh\registration.json'),
	(Join-Path $FixtureRoot 'credentials.json'), (Join-Path $FixtureRoot 'secret.key'), (Join-Path $FixtureRoot 'CON.json'),
	(Join-Path $FixtureRoot '..\registration.json'), (Join-Path $FixtureRoot 'space.\registration.json'))) {
	$Wrong = $Good.Clone(); $Wrong.Path = $BadPath; Assert-Rejected -Arguments $Wrong
}
$Wrong = $Good.Clone(); $Wrong.Repository = 'Other/project'; Assert-Rejected -Arguments $Wrong
$Wrong = $Good.Clone(); $Wrong.Repository = 'Fixture/..'; Assert-Rejected -Arguments $Wrong
$Wrong = $Good.Clone(); $Wrong.TargetRoot = $FixtureRoot; Assert-Rejected -Arguments $Wrong
foreach ($Field in @('targetRoot', 'gitCommonDirectory')) {
	$BadRecord = [ordered]@{}
	foreach ($Key in $Record.Keys) { $BadRecord[$Key] = $Record[$Key] }
	$BadRecord[$Field] = 'C:\'
	Assert-Rejected -Arguments (New-RegistrationFixture -Text ($BadRecord | ConvertTo-Json -Compress))
}
$External = Join-Path $FixtureRoot 'shared-git'
$null = New-Item -ItemType Directory -Path $External
$Record.gitCommonDirectory = $External
$ExternalArgs = New-RegistrationFixture -Text ($Record | ConvertTo-Json -Compress)
$ExternalRegistration = Get-ManagedCompileRegistration @ExternalArgs
Close-ManagedCompileRegistration -Registration $ExternalRegistration
# A failed digest releases every acquired handle. Opening for exclusive access
# does not modify any bytes and proves no retained registration handle remains.
$Exclusive = [IO.File]::Open($Good.Path, 'Open', 'ReadWrite', 'None'); $Exclusive.Dispose()
$MalformedPath = Join-Path $FixtureRoot 'malformed-utf8.json'
[IO.File]::WriteAllBytes($MalformedPath, [byte[]]@(123, 34, 192, 175, 34, 58, 49, 125))
$Wrong = $Good.Clone(); $Wrong.Path = $MalformedPath; $Wrong.ExpectedSha256 = (Get-FileHash -LiteralPath $MalformedPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Rejected -Arguments $Wrong
# Junction fixtures contain no secrets and are retained; only metadata is read.
$Link = Join-Path $FixtureRoot 'linked-parent'
$null = New-Item -ItemType Junction -Path $Link -Target $FixtureRoot
$Wrong = $Good.Clone(); $Wrong.Path = Join-Path $Link ([IO.Path]::GetFileName($Good.Path)); Assert-Rejected -Arguments $Wrong
$Wrong = $Good.Clone(); $Wrong.TargetRoot = Join-Path $Link 'target'; Assert-Rejected -Arguments $Wrong
foreach ($Field in @('targetRoot', 'gitCommonDirectory')) {
	$BadRecord = [ordered]@{}
	foreach ($Key in $Record.Keys) { $BadRecord[$Key] = $Record[$Key] }
	$BadRecord[$Field] = Join-Path $Link 'target'
	$Wrong = New-RegistrationFixture -Text ($BadRecord | ConvertTo-Json -Compress)
	if ($Field -ceq 'targetRoot') { $Wrong.TargetRoot = $BadRecord.targetRoot }
	Assert-Rejected -Arguments $Wrong
}
Write-Output "PASS managed registration schema, identity, path and retained-handle fixtures; retained at $FixtureRoot"
