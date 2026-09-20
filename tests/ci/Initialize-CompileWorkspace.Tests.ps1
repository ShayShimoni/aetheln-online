param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$Helper = Join-Path $RepositoryRoot 'scripts/ci/Initialize-CompileWorkspace.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnCompileWorkspace-' + [guid]::NewGuid().ToString('N'))

function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Write-Fixture([string] $Root, [string] $Relative, [string] $Value = 'fixture') {
	$Path = Join-Path $Root $Relative
	New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
	[IO.File]::WriteAllText($Path, $Value)
	return $Path
}
function Invoke-FixtureGit([string] $Root, [string[]] $Arguments) {
	& git -C $Root @Arguments | Out-Null
	if ($LASTEXITCODE -ne 0) { throw 'Fixture git command failed.' }
}
function New-Fixture {
	[CmdletBinding(SupportsShouldProcess)]
	param([string] $Name)
	$Root = Join-Path $FixtureRoot $Name
	# Git and [IO.File] writes ignore $WhatIfPreference, so one guard covers every mutation
	# below. A previewed fixture returns nothing rather than a root that was never built.
	if (-not $PSCmdlet.ShouldProcess($Root, 'Create compile-workspace Git fixture')) { return }
	New-Item -ItemType Directory -Path $Root -Force | Out-Null
	Invoke-FixtureGit $Root @('init', '-q')
	Write-Fixture -Root $Root -Relative '.gitignore' -Value "Binaries/`nIntermediate/`nSaved/`nTestResults/`n" | Out-Null
	Write-Fixture -Root $Root -Relative 'Source/tracked.cpp' -Value 'tracked-original' | Out-Null
	Invoke-FixtureGit $Root @('add', '.')
	Invoke-FixtureGit $Root @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'fixture baseline')
	return $Root
}
function Assert-Rejected([string] $Root, [string] $Reason, [switch] $CheckOnly) {
	$Failure = $null
	try { & $Helper -RepositoryRoot $Root -CheckOnly:$CheckOnly | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -and $Failure -match $Reason) "Expected $Reason rejection; got '$Failure'."
}

Assert-True (Test-Path -LiteralPath $Helper -PathType Leaf) 'Compile workspace helper must exist.'
$WhatIfRoot = New-Fixture 'whatif-preview' -WhatIf
Assert-True ($null -eq $WhatIfRoot) 'WhatIf must not return a fixture root that was never built.'
Assert-True (-not (Test-Path -LiteralPath $FixtureRoot)) 'WhatIf must not create directories, files, or a Git repository.'
$Root = New-Fixture 'exact retention with spaces'
$Retained = @(
	(Write-Fixture -Root $Root -Relative 'Binaries/Win64/client.dll' -Value 'binary-bytes'),
	(Write-Fixture -Root $Root -Relative 'Intermediate/Build/Win64/client.obj' -Value 'object-bytes')
)
$Snapshots = @($Retained | ForEach-Object {
	[IO.File]::SetLastWriteTimeUtc($_, [datetime]'2024-01-02T03:04:05Z')
	@{ Path = $_; Hash = (Get-FileHash -LiteralPath $_).Hash; Ticks = [IO.File]::GetLastWriteTimeUtc($_).Ticks }
})
$Debris = @('Source/untracked.cpp', 'Intermediate/Source/stale.cpp', 'Saved/old.log', 'TestResults/old.json', 'Other/Binaries/nested.dll', 'Other/Intermediate/Build/nested.obj', 'ordinary [bracket] debris.txt', ('unicode-' + [char]0x00E9 + '.txt'))
foreach ($Relative in $Debris) { Write-Fixture $Root $Relative | Out-Null }
[IO.File]::WriteAllText((Join-Path $Root 'Source/tracked.cpp'), 'tracked-local-change')
# This config belongs solely to the newly created credential-free fixture.
$ConfigHash = (Get-FileHash -LiteralPath (Join-Path $Root '.git/config')).Hash
$Preview = & $Helper -RepositoryRoot $Root -CheckOnly
Assert-True ($Preview.removedFileCount -eq 0 -and $Preview.cleanupFileCount -eq $Debris.Count) 'CheckOnly reports the exact plan without mutation.'
foreach ($Relative in $Debris) { Assert-True (Test-Path -LiteralPath (Join-Path $Root $Relative)) 'CheckOnly preserves debris.' }
$Result = & $Helper -RepositoryRoot $Root
Assert-True ($Result.removedFileCount -eq $Debris.Count) 'Every nonretained untracked file is removed.'
foreach ($Relative in $Debris) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $Root $Relative))) "Removed $Relative." }
Assert-True ([IO.File]::ReadAllText((Join-Path $Root 'Source/tracked.cpp')) -eq 'tracked-local-change') 'Tracked edits remain untouched.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $Root '.git/config')).Hash -eq $ConfigHash) 'Git configuration remains unchanged.'
foreach ($Snapshot in $Snapshots) {
	Assert-True ((Get-FileHash -LiteralPath $Snapshot.Path).Hash -eq $Snapshot.Hash) 'Retained output bytes are unchanged.'
	Assert-True ([IO.File]::GetLastWriteTimeUtc($Snapshot.Path).Ticks -eq $Snapshot.Ticks) 'Retained output timestamps are unchanged.'
}
Invoke-FixtureGit $Root @('add', 'Source/tracked.cpp')
Invoke-FixtureGit $Root @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'second fixture commit')
Write-Fixture $Root 'Source/second-stale.cpp' | Out-Null
& $Helper -RepositoryRoot $Root | Out-Null
foreach ($Snapshot in $Snapshots) {
	Assert-True ([IO.File]::GetLastWriteTimeUtc($Snapshot.Path).Ticks -eq $Snapshot.Ticks) 'A new commit does not invalidate filesystem retention.'
	Assert-True ((Get-FileHash -LiteralPath $Snapshot.Path).Hash -eq $Snapshot.Hash) 'Retained bytes survive a second preparation.'
}
Assert-True (-not (Test-Path -LiteralPath (Join-Path $Root 'Source/second-stale.cpp'))) 'Repeated preparation removes new source debris.'

$Collision = New-Fixture 'retained-file-collision'
Write-Fixture $Collision 'Intermediate/Build' | Out-Null
Assert-Rejected $Collision 'retained_root_collision'
$TrackedCollision = New-Fixture 'tracked-output-collision'
Write-Fixture $TrackedCollision 'Binaries/tracked.dll' | Out-Null
Invoke-FixtureGit $TrackedCollision @('add', '-f', 'Binaries/tracked.dll')
Assert-Rejected $TrackedCollision 'tracked_retention_collision'
$TypeCollision = New-Fixture 'tracked-file-directory-collision'
Move-Item -LiteralPath (Join-Path $TypeCollision 'Source/tracked.cpp') -Destination (Join-Path $TypeCollision 'tracked-original-copy')
Write-Fixture $TypeCollision 'Source/tracked.cpp/debris.txt' | Out-Null
Assert-Rejected $TypeCollision 'tracked_type_collision'
Assert-True (Test-Path -LiteralPath (Join-Path $TypeCollision 'Source/tracked.cpp/debris.txt')) 'Tracked type collision rejects before deletion.'
$CaseCollision = New-Fixture 'index-case-collision'
$Blob = (& git -C $CaseCollision rev-parse 'HEAD:Source/tracked.cpp').Trim()
Invoke-FixtureGit $CaseCollision @('update-index', '--add', '--cacheinfo', "100644,$Blob,Case.cpp")
Invoke-FixtureGit $CaseCollision @('update-index', '--add', '--cacheinfo', "100644,$Blob,case.cpp")
Assert-Rejected $CaseCollision 'case_collision'

$Sensitive = New-Fixture 'sensitive-path'
# An empty directory name exercises rejection without creating or reading secrets.
New-Item -ItemType Directory -Path (Join-Path $Sensitive '.ssh') | Out-Null
$SafeDebris = Write-Fixture $Sensitive 'safe-debris.txt'
Assert-Rejected $Sensitive 'sensitive_path' -CheckOnly
Assert-Rejected $Sensitive 'sensitive_path'
Assert-True (Test-Path -LiteralPath $SafeDebris) 'Preflight rejection happens before cleanup.'

$Linked = New-Fixture 'reparse-point'
$Outside = Join-Path $FixtureRoot 'outside'
$Sentinel = Write-Fixture -Root $Outside -Relative 'sentinel.txt' -Value 'outside-original'
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
	New-Item -ItemType Junction -Path (Join-Path $Linked 'Saved') -Target $Outside | Out-Null
} else {
	New-Item -ItemType SymbolicLink -Path (Join-Path $Linked 'Saved') -Target $Outside | Out-Null
}
$SafeDebris = Write-Fixture $Linked 'safe-debris.txt'
Assert-Rejected $Linked 'reparse_point' -CheckOnly
Assert-Rejected $Linked 'reparse_point'
Assert-True ([IO.File]::ReadAllText($Sentinel) -eq 'outside-original') 'Outside sentinel survives reparse rejection.'
Assert-True (Test-Path -LiteralPath $SafeDebris) 'Reparse rejection precedes all cleanup.'
$LinkedRetained = New-Fixture 'retained-reparse-point'
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
	New-Item -ItemType Junction -Path (Join-Path $LinkedRetained 'Binaries') -Target $Outside | Out-Null
} else {
	New-Item -ItemType SymbolicLink -Path (Join-Path $LinkedRetained 'Binaries') -Target $Outside | Out-Null
}
Assert-Rejected $LinkedRetained 'reparse_point'
Assert-True ([IO.File]::ReadAllText($Sentinel) -eq 'outside-original') 'Retained-root reparse does not access outside contents.'
$Nested = New-Fixture 'nested-repository'
New-Item -ItemType Directory -Path (Join-Path $Nested 'Other/.git') -Force | Out-Null
Assert-Rejected $Nested 'nested_repository'
Assert-Rejected (Join-Path $Root 'Source') 'repository_root_mismatch'

Write-Output "Compile workspace fixture checks passed. Fixtures retained at $FixtureRoot"
