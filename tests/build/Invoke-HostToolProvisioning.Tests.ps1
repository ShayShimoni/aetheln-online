$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Policy = Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.Policy.ps1'
. $Policy
$Entry = Join-Path $PSScriptRoot '../../scripts/build/Invoke-HostToolProvisioning.ps1'
. (Join-Path $PSScriptRoot '../../scripts/ci/EngineRunnerHostLease.ps1')

function Assert-HostFixture([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}
function Assert-HostFailure([scriptblock] $Action, [string] $Reason) {
	$Caught = $null
	try { & $Action } catch { $Caught = $_.Exception.Message }
	Assert-HostFixture ($Caught -ceq $Reason) "Expected '$Reason'; observed '$Caught'."
}
function Remove-HostFixtureRoot([string] $Root, [string] $Parent) {
	$ResolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
	$ResolvedRoot = [IO.Path]::GetFullPath($Root)
	if (-not $ResolvedRoot.StartsWith($ResolvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'fixture_cleanup_path_invalid' }
	if (Test-Path -LiteralPath $ResolvedRoot -PathType Container) { Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force }
}

$Pin = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$Envelope = New-HostToolAttemptEnvelope -StartTicks 1000L -Frequency 10L
Assert-HostFixture ($Envelope.usefulDeadlineTicks -eq 199000L -and $Envelope.cleanupDeadlineTicks -eq 205000L -and $Envelope.publicationDeadlineTicks -eq 217000L) 'The 330/340/360 minute envelope drifted.'
Assert-HostFailure { New-HostToolAttemptEnvelope -StartTicks ([long]::MaxValue) -Frequency ([long]::MaxValue) } 'monotonic_clock_unavailable'
Assert-HostFailure { New-HostToolEvidenceDirectory -Path $PSScriptRoot } 'evidence_directory_exists_or_invalid'
$FixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$FixtureTempRoot = Join-Path $FixtureParent ('AethelnHostToolsFixture-' + [guid]::NewGuid().ToString('N'))
try {
$null = New-Item -ItemType Directory -Path $FixtureTempRoot -ErrorAction Stop
$EntryFailure = $null
try {
	. $Entry -EngineRoot 'D:\unused' -EvidenceRoot 'F:\unused' -HostLeasePath 'D:\unused.lease' -CompilerPath 'C:\unused\cl.exe' -ResourceCompilerPath 'C:\unused\rc.exe'
} catch { $EntryFailure = $_.Exception.Message }
Assert-HostFixture ($EntryFailure -ceq 'execute_required') 'Definition-only child-path fixture unexpectedly executed the provisioner.'
$ExpectedPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
$ChildPowerShell = Resolve-HostToolChildPowerShellPath
Assert-HostFixture ($ChildPowerShell -ceq $ExpectedPowerShell -and (Test-Path -LiteralPath $ChildPowerShell -PathType Leaf)) 'The child shell must be the existing absolute Windows PowerShell executable.'
if (-not (Test-Path -LiteralPath (Join-Path $PSHOME 'powershell.exe') -PathType Leaf)) {
	Assert-HostFixture ($ChildPowerShell -cne (Join-Path $PSHOME 'powershell.exe')) 'A pwsh host must not select a nonexistent child in PSHOME.'
}
Assert-HostFailure { Resolve-HostToolChildPowerShellPath -SystemDirectory (Join-Path $FixtureTempRoot 'MissingSystemDirectory') } 'child_powershell_unavailable'
$SuccessCleanup = Join-Path $FixtureTempRoot 'success-cleanup'
$null = New-Item -ItemType Directory -Path $SuccessCleanup -ErrorAction Stop
Remove-HostFixtureRoot -Root $SuccessCleanup -Parent $FixtureTempRoot
Assert-HostFixture (-not (Test-Path -LiteralPath $SuccessCleanup)) 'Successful fixture cleanup failed.'
$FailureCleanup = Join-Path $FixtureTempRoot 'failure-cleanup'
$CaughtCleanupFailure = $null
try {
	$null = New-Item -ItemType Directory -Path $FailureCleanup -ErrorAction Stop
	throw 'expected_fixture_failure'
} catch { $CaughtCleanupFailure = $_.Exception.Message }
finally { Remove-HostFixtureRoot -Root $FailureCleanup -Parent $FixtureTempRoot }
Assert-HostFixture ($CaughtCleanupFailure -ceq 'expected_fixture_failure' -and -not (Test-Path -LiteralPath $FailureCleanup)) 'Failed fixture cleanup failed.'
$CreateOnlyFixture = Join-Path $FixtureTempRoot ('AethelnHostTools-' + [guid]::NewGuid().ToString('N'))
Assert-HostFixture ((New-HostToolEvidenceDirectory -Path $CreateOnlyFixture) -eq $CreateOnlyFixture -and
	(Test-Path -LiteralPath $CreateOnlyFixture -PathType Container)) 'Create-only evidence directory failed.'
Assert-HostFailure { New-HostToolEvidenceDirectory -Path $CreateOnlyFixture } 'evidence_directory_exists_or_invalid'
Assert-HostFailure { & $Entry -EngineRoot 'D:\unused' -EvidenceRoot 'F:\unused' -HostLeasePath 'D:\unused.lease' -CompilerPath 'C:\unused\cl.exe' -ResourceCompilerPath 'C:\unused\rc.exe' } 'execute_required'
Assert-HostFailure { & $Entry -Execute -WhatIf -EngineRoot 'D:\unused' -EvidenceRoot 'F:\unused' -HostLeasePath 'D:\unused.lease' -CompilerPath 'C:\unused\cl.exe' -ResourceCompilerPath 'C:\unused\rc.exe' } 'execute_declined'
Assert-HostFixture ((Assert-HostToolGitState -Head $Pin -Status '' -Expected $Pin) -eq $Pin) 'Canonical clean engine must pass.'
Assert-HostFailure { Assert-HostToolGitState -Head ('a' * 40) -Status '' -Expected $Pin } 'engine_revision_mismatch'
Assert-HostFailure { Assert-HostToolGitState -Head $Pin -Status '?? Engine/Binaries/rogue.exe' -Expected $Pin } 'engine_dirty'

# A real disposable index proves both flags can hide modified build inputs from
# porcelain status. The production guard must reject the flags and raw bytes.
$HiddenEngine = Join-Path $FixtureTempRoot ('AethelnHiddenHostTools-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $HiddenEngine 'Engine/Build/BatchFiles') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $HiddenEngine 'Engine/Source/Programs/UnrealBuildTool') -Force
$HiddenBatch = Join-Path $HiddenEngine 'Engine/Build/BatchFiles/Build.bat'
$HiddenUbt = Join-Path $HiddenEngine 'Engine/Source/Programs/UnrealBuildTool/Program.cs'
Set-Content -LiteralPath $HiddenBatch -Value '@echo off' -Encoding Ascii
Set-Content -LiteralPath $HiddenUbt -Value 'class Program {}' -Encoding Ascii
& git -C $HiddenEngine init -q
if ($LASTEXITCODE -ne 0) { throw 'fixture_git_init_failed' }
& git -C $HiddenEngine add -- Engine
if ($LASTEXITCODE -ne 0) { throw 'fixture_git_add_failed' }
& git -C $HiddenEngine -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
if ($LASTEXITCODE -ne 0) { throw 'fixture_git_commit_failed' }
Assert-HostFixture (Assert-HostToolEngineInputIdentity -EngineRoot $HiddenEngine) 'Clean tracked engine inputs must pass.'
Set-Content -LiteralPath $HiddenBatch -Value '@echo altered' -Encoding Ascii
& git -C $HiddenEngine update-index --assume-unchanged -- Engine/Build/BatchFiles/Build.bat
if ($LASTEXITCODE -ne 0) { throw 'fixture_assume_unchanged_failed' }
Assert-HostFixture (@(& git -C $HiddenEngine status --porcelain=v1).Count -eq 0) 'Assume-unchanged fixture should hide the altered batch file.'
Assert-HostFailure { Assert-HostToolEngineInputIdentity -EngineRoot $HiddenEngine } 'engine_index_flags_present'
& git -C $HiddenEngine update-index --no-assume-unchanged -- Engine/Build/BatchFiles/Build.bat
if ($LASTEXITCODE -ne 0) { throw 'fixture_assume_clear_failed' }
Assert-HostFailure { Assert-HostToolEngineInputIdentity -EngineRoot $HiddenEngine } 'engine_input_identity_mismatch'
& git -C $HiddenEngine checkout-index --force -- Engine/Build/BatchFiles/Build.bat
if ($LASTEXITCODE -ne 0) { throw 'fixture_batch_restore_failed' }
Set-Content -LiteralPath $HiddenUbt -Value 'class AlteredProgram {}' -Encoding Ascii
& git -C $HiddenEngine update-index --skip-worktree -- Engine/Source/Programs/UnrealBuildTool/Program.cs
if ($LASTEXITCODE -ne 0) { throw 'fixture_skip_worktree_failed' }
Assert-HostFixture (@(& git -C $HiddenEngine status --porcelain=v1).Count -eq 0) 'Skip-worktree fixture should hide the altered UBT source.'
Assert-HostFailure { Assert-HostToolEngineInputIdentity -EngineRoot $HiddenEngine } 'engine_index_flags_present'

# Controller status can likewise hide a modified script. Exercise the real
# index flags and worktree bytes without changing the project checkout.
$HiddenController = Join-Path $FixtureTempRoot ('AethelnHiddenController-' + [guid]::NewGuid().ToString('N'))
try {
	$null = New-Item -ItemType Directory -Path (Join-Path $HiddenController 'scripts/build') -Force
	$null = New-Item -ItemType Directory -Path (Join-Path $HiddenController 'tests/build') -Force
	$ControllerScript = Join-Path $HiddenController 'scripts/build/Invoke-HostToolProvisioning.ps1'
	$ControllerTest = Join-Path $HiddenController 'tests/build/Invoke-HostToolProvisioning.Tests.ps1'
	Set-Content -LiteralPath $ControllerScript -Value 'Write-Output original' -Encoding Ascii
	Set-Content -LiteralPath $ControllerTest -Value 'Write-Output original-test' -Encoding Ascii
	& git -C $HiddenController init -q
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_git_init_failed' }
	& git -C $HiddenController add -- scripts tests
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_git_add_failed' }
	& git -C $HiddenController -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_git_commit_failed' }
	Assert-HostFixture (Assert-HostToolControllerInputIdentity -ControllerRoot $HiddenController) 'Clean tracked controller inputs must pass.'
	Set-Content -LiteralPath $ControllerScript -Value 'Write-Output altered' -Encoding Ascii
	& git -C $HiddenController update-index --assume-unchanged -- scripts/build/Invoke-HostToolProvisioning.ps1
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_assume_unchanged_failed' }
	Assert-HostFixture (@(& git -C $HiddenController status --porcelain=v1).Count -eq 0) 'Assume-unchanged fixture should hide the altered controller script.'
	Assert-HostFailure { Assert-HostToolControllerInputIdentity -ControllerRoot $HiddenController } 'controller_index_flags_present'
	& git -C $HiddenController update-index --no-assume-unchanged -- scripts/build/Invoke-HostToolProvisioning.ps1
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_assume_clear_failed' }
	Assert-HostFailure { Assert-HostToolControllerInputIdentity -ControllerRoot $HiddenController } 'controller_input_identity_mismatch'
	Set-Content -LiteralPath $ControllerScript -Value 'Write-Output original' -Encoding Ascii
	Set-Content -LiteralPath $ControllerTest -Value 'Write-Output altered-test' -Encoding Ascii
	& git -C $HiddenController update-index --skip-worktree -- tests/build/Invoke-HostToolProvisioning.Tests.ps1
	if ($LASTEXITCODE -ne 0) { throw 'controller_fixture_skip_worktree_failed' }
	Assert-HostFixture (@(& git -C $HiddenController status --porcelain=v1).Count -eq 0) 'Skip-worktree fixture should hide the altered controller test.'
	Assert-HostFailure { Assert-HostToolControllerInputIdentity -ControllerRoot $HiddenController } 'controller_index_flags_present'
} finally {
	Remove-HostFixtureRoot -Root $HiddenController -Parent $FixtureTempRoot
}

# Simulate a source mutation after a child exits but before final acceptance.
# Porcelain stays clean, so the final raw check must still reject it.
$FinalEngine = Join-Path $FixtureTempRoot ('AethelnFinalEngine-' + [guid]::NewGuid().ToString('N'))
try {
	$FinalBatch = Join-Path $FinalEngine 'Engine/Build/BatchFiles/Build.bat'
	$null = New-Item -ItemType Directory -Path (Split-Path -Parent $FinalBatch) -Force
	Set-Content -LiteralPath $FinalBatch -Value '@echo off' -Encoding Ascii
	& git -C $FinalEngine init -q
	if ($LASTEXITCODE -ne 0) { throw 'final_engine_fixture_init_failed' }
	& git -C $FinalEngine add -- Engine
	if ($LASTEXITCODE -ne 0) { throw 'final_engine_fixture_add_failed' }
	& git -C $FinalEngine -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
	if ($LASTEXITCODE -ne 0) { throw 'final_engine_fixture_commit_failed' }
	Assert-HostFixture (Assert-HostToolEngineInputIdentity -EngineRoot $FinalEngine) 'Unchanged final engine inputs must pass.'
	Set-Content -LiteralPath $FinalBatch -Value '@echo altered-after-child' -Encoding Ascii
	& git -C $FinalEngine update-index --assume-unchanged -- Engine/Build/BatchFiles/Build.bat
	if ($LASTEXITCODE -ne 0) { throw 'final_engine_fixture_assume_failed' }
	Assert-HostFixture (@(& git -C $FinalEngine status --porcelain=v1).Count -eq 0) 'Post-child engine mutation should be hidden from porcelain.'
	Assert-HostFailure { Assert-HostToolEngineInputIdentity -EngineRoot $FinalEngine } 'engine_index_flags_present'
	& git -C $FinalEngine update-index --no-assume-unchanged -- Engine/Build/BatchFiles/Build.bat
	if ($LASTEXITCODE -ne 0) { throw 'final_engine_fixture_assume_clear_failed' }
	Assert-HostFailure { Assert-HostToolEngineInputIdentity -EngineRoot $FinalEngine } 'engine_input_identity_mismatch'
} finally {
	Remove-HostFixtureRoot -Root $FinalEngine -Parent $FixtureTempRoot
}

$GitdepsEngine = Join-Path $FixtureTempRoot ('AethelnGitdepsHostTools-' + [guid]::NewGuid().ToString('N'))
$GitdepsWin64 = Join-Path $GitdepsEngine 'Engine/Binaries/Win64'
$GitdepsBuild = Join-Path $GitdepsEngine 'Engine/Build'
foreach ($Path in @($GitdepsWin64, $GitdepsBuild)) { $null = New-Item -ItemType Directory -Path $Path -Force }
$GitdepsSupport = Join-Path $GitdepsWin64 'Support.exe'
Set-Content -LiteralPath $GitdepsSupport -Value 'setup payload fixture' -Encoding Ascii
$GitdepsSha1 = (Get-FileHash -LiteralPath $GitdepsSupport -Algorithm SHA1).Hash.ToLowerInvariant()
$GitdepsManifest = Join-Path $GitdepsBuild 'Commit.gitdeps.xml'
Set-Content -LiteralPath $GitdepsManifest -Value ('<DependencyManifest><Files><File Name="Engine/Binaries/Win64/Support.exe" Hash="' + $GitdepsSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
$GitdepsTracked = @('Engine/Build/Commit.gitdeps.xml')
Assert-HostFixture (Assert-HostToolGitDependencyManifestIdentity -ExpectedBlob ('a' * 40) -ActualBlob ('a' * 40)) 'Pinned manifest blob identity must pass.'
Assert-HostFailure { Assert-HostToolGitDependencyManifestIdentity -ExpectedBlob ('a' * 40) -ActualBlob ('b' * 40) } 'gitdeps_manifest_identity_mismatch'
$GitdepsProof = Assert-HostToolFreshOutputState -EngineRoot $GitdepsEngine -TrackedPaths $GitdepsTracked
Assert-HostFixture ($GitdepsProof.fresh -and $GitdepsProof.manifestFilesVerified -eq 1) 'Exact SHA1-verified Setup payload should pass.'
Set-Content -LiteralPath $GitdepsSupport -Value 'changed setup payload' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $GitdepsEngine -TrackedPaths $GitdepsTracked } 'gitdeps_hash_mismatch'
Set-Content -LiteralPath $GitdepsSupport -Value 'setup payload fixture' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $GitdepsWin64 'UnrealEditor.exe') -Value 'unlisted output' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $GitdepsEngine -TrackedPaths $GitdepsTracked } 'prior_host_outputs_present'
Set-Content -LiteralPath $GitdepsManifest -Value ('<DependencyManifest><Files><File Name="Engine/Binaries/Win64/Support.exe" Hash="' + $GitdepsSha1 + '" /><File Name="Engine/Binaries/Win64/support.exe" Hash="' + $GitdepsSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $GitdepsEngine -TrackedPaths $GitdepsTracked } 'gitdeps_manifest_invalid'
$PluginGitdepsEngine = Join-Path $FixtureTempRoot ('AethelnPluginGitdeps-' + [guid]::NewGuid().ToString('N'))
$PluginGitdepsBuild = Join-Path $PluginGitdepsEngine 'Engine/Plugins/Fixture/Build'
$PluginGitdepsOutput = Join-Path $PluginGitdepsEngine 'Engine/Plugins/Fixture/Binaries/Win64'
foreach ($Path in @($PluginGitdepsBuild, $PluginGitdepsOutput)) { $null = New-Item -ItemType Directory -Path $Path -Force }
$PluginSupport = Join-Path $PluginGitdepsOutput 'Support.dll'
Set-Content -LiteralPath $PluginSupport -Value 'plugin setup fixture' -Encoding Ascii
$PluginSha1 = (Get-FileHash -LiteralPath $PluginSupport -Algorithm SHA1).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $PluginGitdepsEngine 'Engine/Plugins/Fixture/Fixture.uplugin') -Value '{}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $PluginGitdepsBuild 'Commit.gitdeps.xml') -Value ('<DependencyManifest><Files><File Name="Binaries/Win64/Support.dll" Hash="' + $PluginSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
$PluginGitdepsProof = Assert-HostToolFreshOutputState -EngineRoot $PluginGitdepsEngine -TrackedPaths @('Engine/Plugins/Fixture/Build/Commit.gitdeps.xml', 'Engine/Plugins/Fixture/Fixture.uplugin')
Assert-HostFixture ($PluginGitdepsProof.manifestFilesVerified -eq 1) 'Tracked plugin manifest payload should pass.'

# The pinned engine's GitDependencies manifest hydrates this one Programs/bin
# executable before any host-tool build. It is not a stale generated product.
$ProgramGitdepsEngine = Join-Path $FixtureTempRoot ('AethelnProgramGitdeps-' + [guid]::NewGuid().ToString('N'))
$ProgramRelative = 'Engine/Source/Programs/UnrealGameSync/PostBadgeStatus/bin/Release/PostBadgeStatus.exe'
$ProgramOutput = Join-Path $ProgramGitdepsEngine $ProgramRelative
$ProgramBuild = Join-Path $ProgramGitdepsEngine 'Engine/Build'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $ProgramOutput) -Force
$null = New-Item -ItemType Directory -Path $ProgramBuild -Force
Set-Content -LiteralPath $ProgramOutput -Value 'pinned program dependency' -Encoding Ascii
$ProgramSha1 = (Get-FileHash -LiteralPath $ProgramOutput -Algorithm SHA1).Hash.ToLowerInvariant()
$ProgramManifest = Join-Path $ProgramBuild 'Commit.gitdeps.xml'
Set-Content -LiteralPath $ProgramManifest -Value ('<DependencyManifest><Files><File Name="' + $ProgramRelative + '" Hash="' + $ProgramSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
$ProgramTracked = @('Engine/Build/Commit.gitdeps.xml')
$ProgramProof = Assert-HostToolFreshOutputState -EngineRoot $ProgramGitdepsEngine -TrackedPaths $ProgramTracked
Assert-HostFixture ($ProgramProof.manifestFilesVerified -eq 1) 'Exact SHA1-verified pinned Programs/bin dependency should pass.'
Set-Content -LiteralPath $ProgramOutput -Value 'changed program dependency' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $ProgramGitdepsEngine -TrackedPaths $ProgramTracked } 'gitdeps_hash_mismatch'
Set-Content -LiteralPath $ProgramOutput -Value 'pinned program dependency' -Encoding Ascii
Set-Content -LiteralPath $ProgramManifest -Value ('<DependencyManifest><Files><File Name="' + $ProgramRelative.Replace('PostBadgeStatus.exe', 'postbadgestatus.exe') + '" Hash="' + $ProgramSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $ProgramGitdepsEngine -TrackedPaths $ProgramTracked } 'prior_host_outputs_present'
Set-Content -LiteralPath $ProgramManifest -Value '<DependencyManifest><Files /></DependencyManifest>' -Encoding UTF8
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $ProgramGitdepsEngine -TrackedPaths $ProgramTracked } 'prior_host_outputs_present'
$OtherProgram = Join-Path (Split-Path -Parent $ProgramOutput) 'Other.exe'
Set-Content -LiteralPath $OtherProgram -Value 'another dependency' -Encoding Ascii
$OtherProgramSha1 = (Get-FileHash -LiteralPath $OtherProgram -Algorithm SHA1).Hash.ToLowerInvariant()
Set-Content -LiteralPath $ProgramManifest -Value ('<DependencyManifest><Files><File Name="' + $ProgramRelative + '" Hash="' + $ProgramSha1 + '" /><File Name="' + $ProgramRelative.Replace('PostBadgeStatus.exe', 'Other.exe') + '" Hash="' + $OtherProgramSha1 + '" /></Files></DependencyManifest>') -Encoding UTF8
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $ProgramGitdepsEngine -TrackedPaths $ProgramTracked } 'prior_host_outputs_present'

# A clean Git tree does not prove ignored build products share this source pin.
$FreshEngine = Join-Path $FixtureTempRoot ('AethelnFreshHostTools-' + [guid]::NewGuid().ToString('N'))
$FreshPlugin = Join-Path $FreshEngine 'Engine/Plugins/Fixture'
$FreshEditor = Join-Path $FreshEngine 'Engine/Binaries/Win64'
$FreshIntermediate = Join-Path $FreshEngine 'Engine/Intermediate/Build/Win64'
foreach ($Path in @($FreshPlugin, $FreshEditor, $FreshIntermediate)) { $null = New-Item -ItemType Directory -Path $Path -Force }
$FreshProof = Assert-HostToolFreshOutputState -EngineRoot $FreshEngine
Assert-HostFixture ($FreshProof.fresh -and $FreshProof.outputRootsChecked -ge 2) 'Empty engine outputs should pass.'
Set-Content -LiteralPath (Join-Path $FreshEditor 'TrackedSupport.exe') -Value 'source fixture' -Encoding Ascii
$FreshProof = Assert-HostToolFreshOutputState -EngineRoot $FreshEngine -TrackedPaths @('Engine/Binaries/Win64/TrackedSupport.exe')
Assert-HostFixture ($FreshProof.fresh -and $FreshProof.trackedPaths -eq 1) 'Tracked source-support binary should remain eligible.'
Set-Content -LiteralPath (Join-Path $FreshEditor 'UnrealEditor-Fixture.dll') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $FreshEngine -TrackedPaths @('Engine/Binaries/Win64/TrackedSupport.exe') } 'prior_host_outputs_present'
$PluginEngine = Join-Path $FixtureTempRoot ('AethelnPluginHostTools-' + [guid]::NewGuid().ToString('N'))
$PluginOutput = Join-Path $PluginEngine 'Engine/Plugins/Fixture/Binaries/Win64'
$null = New-Item -ItemType Directory -Path $PluginOutput -Force
Set-Content -LiteralPath (Join-Path $PluginOutput 'UnrealEditor-Fixture.dll') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $PluginEngine } 'prior_host_outputs_present'
$IntermediateEngine = Join-Path $FixtureTempRoot ('AethelnIntermediateHostTools-' + [guid]::NewGuid().ToString('N'))
$IntermediateOutput = Join-Path $IntermediateEngine 'Engine/Intermediate/Build/Win64'
$null = New-Item -ItemType Directory -Path $IntermediateOutput -Force
Set-Content -LiteralPath (Join-Path $IntermediateOutput 'Module-Fixture.obj') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $IntermediateEngine } 'prior_host_outputs_present'
$UbtEngine = Join-Path $FixtureTempRoot ('AethelnUbtHostTools-' + [guid]::NewGuid().ToString('N'))
$UbtOutput = Join-Path $UbtEngine 'Engine/Binaries/DotNET/UnrealBuildTool'
$null = New-Item -ItemType Directory -Path $UbtOutput -Force
Set-Content -LiteralPath (Join-Path $UbtOutput 'UnrealBuildTool.dll') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $UbtEngine } 'prior_host_outputs_present'
$UbtDepsEngine = Join-Path $FixtureTempRoot ('AethelnUbtDeps-' + [guid]::NewGuid().ToString('N'))
$UbtDeps = Join-Path $UbtDepsEngine 'Engine/Intermediate/Build'
$null = New-Item -ItemType Directory -Path $UbtDeps -Force
Set-Content -LiteralPath (Join-Path $UbtDeps 'UnrealBuildTool.dep.csv') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $UbtDepsEngine } 'prior_host_outputs_present'
$BuildRulesEngine = Join-Path $FixtureTempRoot ('AethelnBuildRules-' + [guid]::NewGuid().ToString('N'))
try {
	$BuildRulesOutput = Join-Path $BuildRulesEngine 'Engine/Intermediate/Build/BuildRules'
	$null = New-Item -ItemType Directory -Path $BuildRulesOutput -Force
	Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $BuildRulesEngine } 'prior_host_outputs_present'
	Set-Content -LiteralPath (Join-Path $BuildRulesOutput 'UE5Rules.dll') -Value 'stale rules assembly' -Encoding Ascii
	Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $BuildRulesEngine } 'prior_host_outputs_present'
} finally {
	Remove-HostFixtureRoot -Root $BuildRulesEngine -Parent $FixtureTempRoot
}
$UbtObjEngine = Join-Path $FixtureTempRoot ('AethelnUbtObj-' + [guid]::NewGuid().ToString('N'))
$UbtObj = Join-Path $UbtObjEngine 'Engine/Source/Programs/UnrealBuildTool/obj'
$null = New-Item -ItemType Directory -Path $UbtObj -Force
Set-Content -LiteralPath (Join-Path $UbtObj 'project.assets.json') -Value 'fixture' -Encoding Ascii
Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $UbtObjEngine } 'prior_host_outputs_present'
foreach ($Relative in @(
	'Engine/Source/Programs/Tool/Bin/Stale.dll',
	'Engine/Source/Programs/Tool/OBJ/Stale.obj',
	'Engine/Plugins/Fixture/binaries/Win64/Stale.dll',
	'Engine/Plugins/Fixture/Intermediate/build/Win64/Stale.obj',
	'Engine/Plugins/Fixture/intermediate/Build/Win64/Stale.obj')) {
	$CaseEngine = Join-Path $FixtureTempRoot ('AethelnCaseOutput-' + [guid]::NewGuid().ToString('N'))
	$CaseOutput = Join-Path $CaseEngine $Relative
	$null = New-Item -ItemType Directory -Path (Split-Path -Parent $CaseOutput) -Force
	Set-Content -LiteralPath $CaseOutput -Value 'stale generated output' -Encoding Ascii
	Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $CaseEngine } 'prior_host_outputs_present'
}

# The operator entry acquires the shared lease before source/tool/output probes
# and holds it through the target sequence; a competing writer's output must be
# rejected when preflight runs inside that lease window.
$EntryText = Get-Content -LiteralPath $Entry -Raw
$AcquireAt = $EntryText.IndexOf('$Lease = Enter-EngineRunnerHostLease', [StringComparison]::Ordinal)
$EngineProbeAt = $EntryText.IndexOf('$EngineGit = Get-HostToolGitState', [StringComparison]::Ordinal)
$InputProbeAt = $EntryText.IndexOf('$null = Assert-HostToolEngineInputIdentity', $EngineProbeAt, [StringComparison]::Ordinal)
$FreshProbeAt = $EntryText.IndexOf('$FreshOutputProof = Assert-HostToolFreshOutputState', [StringComparison]::Ordinal)
$BuildAt = $EntryText.IndexOf('$Sequence = Invoke-HostToolProvisioningSequence', [StringComparison]::Ordinal)
$ReceiptProbeAt = $EntryText.IndexOf('$ReceiptClosureProof = Assert-HostToolReceiptSet', [StringComparison]::Ordinal)
$ReleaseAt = $EntryText.IndexOf('Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true', [StringComparison]::Ordinal)
Assert-HostFixture ($AcquireAt -ge 0 -and $AcquireAt -lt $EngineProbeAt -and $EngineProbeAt -lt $InputProbeAt -and $InputProbeAt -lt $FreshProbeAt -and
	$FreshProbeAt -lt $BuildAt -and $BuildAt -lt $ReceiptProbeAt -and $ReceiptProbeAt -lt $ReleaseAt) 'Host lease must enclose fresh preflight, build, and target-receipt verification.'
$ControllerProbe = '$null = Assert-HostToolControllerInputIdentity -ControllerRoot $ResolvedController'
$PerTargetControllerAt = $EntryText.IndexOf($ControllerProbe, [StringComparison]::Ordinal)
$ControllerPreflightAt = $EntryText.IndexOf($ControllerProbe, $AcquireAt, [StringComparison]::Ordinal)
$ControllerCompletionAt = $EntryText.IndexOf($ControllerProbe, $ReceiptProbeAt, [StringComparison]::Ordinal)
$ControllerGitAt = $EntryText.IndexOf('$ControllerGit = Get-HostToolGitState', [StringComparison]::Ordinal)
$ProcessStartAt = $EntryText.IndexOf('$Process = $Job.Start', [StringComparison]::Ordinal)
Assert-HostFixture ($PerTargetControllerAt -ge 0 -and $PerTargetControllerAt -lt $ProcessStartAt -and
	$AcquireAt -lt $ControllerGitAt -and $ControllerGitAt -lt $ControllerPreflightAt -and $ControllerPreflightAt -lt $EngineProbeAt -and
	$ReceiptProbeAt -lt $ControllerCompletionAt -and $ControllerCompletionAt -lt $ReleaseAt) 'Tracked controller identity must be checked under the lease before every build and at completion.'
$PerTargetInputAt = $EntryText.IndexOf('$null = Assert-HostToolEngineInputIdentity', [StringComparison]::Ordinal)
Assert-HostFixture ($PerTargetInputAt -ge 0 -and $PerTargetInputAt -lt $ProcessStartAt -and
	$ProcessStartAt -lt $InputProbeAt) 'Engine inputs must be checked before each native target launch.'
$PostChildInputAt = $EntryText.IndexOf('$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine', $ProcessStartAt, [StringComparison]::Ordinal)
$ResultReadAt = $EntryText.IndexOf('$ResultPath = Join-Path $TargetEvidence', [StringComparison]::Ordinal)
$ProductAfterAt = $EntryText.IndexOf('$After = Get-HostToolProductState', [StringComparison]::Ordinal)
$FinalInputAt = $EntryText.IndexOf('$null = Assert-HostToolEngineInputIdentity -EngineRoot $ResolvedEngine', $ReceiptProbeAt, [StringComparison]::Ordinal)
$EngineAfterAt = $EntryText.IndexOf('$EngineAfter = Get-HostToolGitState', [StringComparison]::Ordinal)
Assert-HostFixture ($ProcessStartAt -lt $ResultReadAt -and $ResultReadAt -lt $PostChildInputAt -and $PostChildInputAt -lt $ProductAfterAt -and $ProductAfterAt -lt $InputProbeAt -and
	$ReceiptProbeAt -lt $EngineAfterAt -and $EngineAfterAt -lt $FinalInputAt -and $FinalInputAt -lt $ReleaseAt) 'Raw engine identity must be rechecked after each child and before final success.'
Assert-HostFixture ($EntryText.Contains('-AdmitTarget {') -and -not $EntryText.Contains('-ReadCapacity {')) 'Operator entry must use receipt-accounted routine target admission.'
$RaceEngine = Join-Path $FixtureTempRoot ('AethelnHostRace-' + [guid]::NewGuid().ToString('N'))
$RaceOutput = Join-Path $RaceEngine 'Engine/Binaries/Win64'
$null = New-Item -ItemType Directory -Path $RaceOutput -Force
$RaceLease = Enter-EngineRunnerHostLease -LeasePath (Join-Path $RaceEngine 'host.lease') -OwnerId 'host-race-fixture' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
try {
	Set-Content -LiteralPath (Join-Path $RaceOutput 'UnrealEditor.exe') -Value 'competing fixture' -Encoding Ascii
	Assert-HostFailure { Assert-HostToolFreshOutputState -EngineRoot $RaceEngine } 'prior_host_outputs_present'
} finally { Exit-EngineRunnerHostLease -Lease $RaceLease -CleanupVerified $true }

$Command = Get-HostToolBuildCommand -Target 'UnrealEditor' -ActionLimit 2 -BuildBatch 'D:\Engine\Engine\Build\BatchFiles\Build.bat'
Assert-HostFixture ($Command.arguments -contains '-MaxParallelActions=2') 'Action limit missing.'
Assert-HostFixture ($Command.arguments -contains '-CompilerVersion=14.44.35207') 'Compiler pin missing.'
Assert-HostFixture ($Command.arguments -contains '-WindowsSDKVersion=10.0.26100.0') 'SDK pin missing.'
Assert-HostFixture (-not (($Command.arguments -join ' ') -match '(?i)(^|\s)-clean(\s|$)|RunUAT|Rebuild')) 'Provisioner must not clean or use UAT/rebuild.'
Assert-HostFailure { Get-HostToolBuildCommand -Target 'UnrealEditor' -ActionLimit 5 -BuildBatch 'D:\Engine\Engine\Build\BatchFiles\Build.bat' } 'action_limit_invalid'

$Observed = Get-HostToolBuildProof -Lines @(
	'Using Visual Studio 2022 14.44.35228 toolchain (C:\VS\VC\Tools\MSVC\14.44.35207) and Windows 10.0.26100.0 SDK (C:\Kits\10).',
	'Using Parallel executor to run 12 action(s)', '[1/12] Compile Module.Core.cpp') -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10'
Assert-HostFixture ($Observed.actionCount -eq 12 -and $Observed.progressCount -eq 1) 'Positive action proof failed.'
Assert-HostFailure { Get-HostToolBuildProof -Lines @('Target is up to date') -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10' } 'tool_selection_unproven'
Assert-HostFailure { Get-HostToolBuildProof -Lines @('Using Visual Studio 2022 14.44.35228 toolchain (C:\VS\VC\Tools\MSVC\14.44.35207) and Windows 10.0.26100.0 SDK (C:\Kits\10).', 'Using Parallel executor to run 0 action(s)') -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10' } 'actions_unproven'
Assert-HostFailure { Get-HostToolBuildProof -Lines @('Using Parallel executor to run 12 action(s)', '[1/12] Compile') -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10' } 'tool_selection_unproven'
Assert-HostFailure { Get-HostToolBuildProof -Lines @('Using Visual Studio 2022 14.44.35228 toolchain (C:\Other) and Windows 10.0.26100.0 SDK (C:\Kits\10).', 'Using Parallel executor to run 1 action(s)', '[1/1] Compile') -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10' } 'tool_selection_mismatch'

$BeforeProducts = [ordered]@{
	'Engine/Binaries/Win64/UnrealPak.exe' = $null
	'Engine/Binaries/Win64/UnrealPak.target' = $null
}
$AfterProducts = [ordered]@{
	'Engine/Binaries/Win64/UnrealPak.exe' = [pscustomobject]@{ sizeBytes = 12L; sha256 = ('b' * 64) }
	'Engine/Binaries/Win64/UnrealPak.target' = [pscustomobject]@{ sizeBytes = 12L; sha256 = ('c' * 64) }
}
Assert-HostFixture (Assert-HostToolProductChange -Target UnrealPak -Before $BeforeProducts -After $AfterProducts) 'Missing-to-present product transition should pass.'
Assert-HostFailure { Assert-HostToolProductChange -Target UnrealPak -Before $AfterProducts -After $AfterProducts } 'products_unchanged'
$AfterProducts['Engine/Binaries/Win64/UnrealPak.target'] = $null
Assert-HostFailure { Assert-HostToolProductChange -Target UnrealPak -Before $BeforeProducts -After $AfterProducts } 'products_unproven'
$AfterProducts['Engine/Binaries/Win64/UnrealPak.target'] = [pscustomobject]@{ sizeBytes = 12L; sha256 = ('c' * 64) }
$ReceiptOnlyBefore = [ordered]@{
	'Engine/Binaries/Win64/UnrealPak.exe' = $AfterProducts['Engine/Binaries/Win64/UnrealPak.exe']
	'Engine/Binaries/Win64/UnrealPak.target' = $null
}
Assert-HostFailure { Assert-HostToolProductChange -Target UnrealPak -Before $ReceiptOnlyBefore -After $AfterProducts } 'products_unchanged'

$ReceiptEngine = Join-Path $FixtureTempRoot ('AethelnReceiptHostTools-' + [guid]::NewGuid().ToString('N'))
$ReceiptWin64 = Join-Path $ReceiptEngine 'Engine/Binaries/Win64'
$null = New-Item -ItemType Directory -Path $ReceiptWin64 -Force
foreach ($Name in @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe', 'UnrealPak.exe', 'ShaderCompileWorker.exe')) {
	Set-Content -LiteralPath (Join-Path $ReceiptWin64 $Name) -Value 'fixture product' -Encoding Ascii
}
function Set-HostReceiptFixture([string] $Target, [string] $TargetType, [string[]] $Products, [object[]] $ExtraProducts = @()) {
	$BuildProducts = @($Products | ForEach-Object { [ordered]@{ Path = ('$(EngineDir)/Binaries/Win64/' + $_); Type = 'Executable' } }) + @($ExtraProducts)
	[ordered]@{ TargetName = $Target; Platform = 'Win64'; Configuration = 'Development'; TargetType = $TargetType;
		BuildProducts = $BuildProducts } | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath (Join-Path $ReceiptWin64 ($Target + '.target')) -Encoding UTF8
}
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')
Set-HostReceiptFixture -Target UnrealPak -TargetType Program -Products @('UnrealPak.exe')
Set-HostReceiptFixture -Target ShaderCompileWorker -TargetType Program -Products @('ShaderCompileWorker.exe')
$ReceiptProof = Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine
Assert-HostFixture ($ReceiptProof.productCount -eq 7 -and $ReceiptProof.totalBytes -gt 0) 'Semantically valid target receipts should pass.'
$SharedDirectory = Join-Path $ReceiptWin64 'D3D12/x64'
$null = New-Item -ItemType Directory -Path $SharedDirectory -Force
Set-Content -LiteralPath (Join-Path $SharedDirectory 'D3D12Core.dll') -Value 'shared runtime product' -Encoding Ascii
$SharedProduct = [ordered]@{ Path = '$(EngineDir)/Binaries/Win64/D3D12/x64/D3D12Core.dll'; Type = 'DynamicLibrary' }
Set-HostReceiptFixture -Target ShaderCompileWorker -TargetType Program -Products @('ShaderCompileWorker.exe') -ExtraProducts @($SharedProduct)
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe') -ExtraProducts @($SharedProduct)
$ReceiptProof = Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine
$ExpectedReceiptBytes = [long] 0
foreach ($Name in @('UnrealPak.target', 'ShaderCompileWorker.target', 'UnrealEditor.target', 'UnrealPak.exe',
	'ShaderCompileWorker.exe', 'UnrealEditor.exe', 'UnrealEditor-Cmd.exe', 'D3D12/x64/D3D12Core.dll')) {
	$ExpectedReceiptBytes += [long] (Get-Item -LiteralPath (Join-Path $ReceiptWin64 $Name)).Length
}
Assert-HostFixture ($ReceiptProof.productCount -eq 8 -and $ReceiptProof.totalBytes -eq $ExpectedReceiptBytes) 'Shared identical target products should be counted once.'
Set-HostReceiptFixture -Target ShaderCompileWorker -TargetType Program -Products @('ShaderCompileWorker.exe') -ExtraProducts @($SharedProduct, $SharedProduct)
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_product_duplicate'
Set-HostReceiptFixture -Target ShaderCompileWorker -TargetType Program -Products @('ShaderCompileWorker.exe') -ExtraProducts @($SharedProduct)
$ConflictingType = [ordered]@{ Path = $SharedProduct.Path; Type = 'RequiredResource' }
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe') -ExtraProducts @($ConflictingType)
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_product_duplicate'
$ConflictingCase = [ordered]@{ Path = '$(EngineDir)/Binaries/Win64/D3D12/x64/d3d12core.dll'; Type = 'DynamicLibrary' }
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe') -ExtraProducts @($ConflictingCase)
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_product_duplicate'
Set-HostReceiptFixture -Target ShaderCompileWorker -TargetType Program -Products @('ShaderCompileWorker.exe')
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')
$EditorTargetPath = Join-Path $ReceiptWin64 'UnrealEditor.target'
Set-Content -LiteralPath $EditorTargetPath -Value '{invalid' -Encoding Ascii
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_receipt_invalid'
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')
$EditorBody = Get-Content -LiteralPath $EditorTargetPath -Raw
Set-Content -LiteralPath $EditorTargetPath -Value ($EditorBody.Replace('"Development"', '"Shipping"')) -Encoding UTF8
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_receipt_invalid'
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')
Set-Content -LiteralPath $EditorTargetPath -Value ($EditorBody.Replace('"BuildProducts":', '"WrongProducts":')) -Encoding UTF8
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_receipt_invalid'
Set-HostReceiptFixture -Target UnrealEditor -TargetType Editor -Products @('UnrealEditor.exe', 'UnrealEditor-Cmd.exe')
Set-HostReceiptFixture -Target UnrealPak -TargetType Program -Products @('UnrealPak.exe', 'UnrealPak-Missing.dll')
Assert-HostFailure { Assert-HostToolReceiptSet -EngineRoot $ReceiptEngine } 'target_product_missing'
Set-HostReceiptFixture -Target UnrealPak -TargetType Program -Products @('UnrealPak.exe')

# Exercise the real child capture using a harmless fixture Build.bat. This is
# not the pinned engine and never starts UnrealBuildTool or an engine build.
$FakeEngine = Join-Path $FixtureTempRoot ('AethelnHostBuild-' + [guid]::NewGuid().ToString('N'))
$FakeBatchDir = Join-Path $FakeEngine 'Engine/Build/BatchFiles'
$FakeDotnetDir = Join-Path $FakeEngine 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
$FakeEvidence = Join-Path $FakeEngine 'fixture-evidence'
foreach ($Path in @($FakeBatchDir, $FakeDotnetDir, $FakeEvidence)) { $null = New-Item -ItemType Directory -Path $Path }
Set-Content -LiteralPath (Join-Path $FakeDotnetDir 'dotnet.exe') -Value 'fixture only' -Encoding Ascii
$FakeBatch = @'
@echo off
echo Using Visual Studio 2022 14.44.35228 toolchain (C:\VS\VC\Tools\MSVC\14.44.35207) and Windows 10.0.26100.0 SDK (C:\Kits\10).
echo Using Parallel executor to run 1 action(s)
echo [1/1] FakeCompile
exit /b 0
'@
Set-Content -LiteralPath (Join-Path $FakeBatchDir 'Build.bat') -Value $FakeBatch -Encoding Ascii
$Child = Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.BuildInvocation.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Child -Target UnrealPak -ActionLimit 1 -EngineRoot $FakeEngine -EvidenceRoot $FakeEvidence
Assert-HostFixture ($LASTEXITCODE -eq 0) 'Fixture Build.bat capture failed.'
$ChildResult = Get-Content -LiteralPath (Join-Path $FakeEvidence 'native-result.json') -Raw | ConvertFrom-Json
Assert-HostFixture ($ChildResult.nativeExitCode -eq 0 -and $null -eq $ChildResult.infrastructureFailure) 'Child result missing.'
$ChildProof = Get-HostToolBuildProof -Lines @(Get-Content -LiteralPath (Join-Path $FakeEvidence 'build.log')) -ToolDirectory 'C:\VS\VC\Tools\MSVC\14.44.35207' -SdkDirectory 'C:\Kits\10'
Assert-HostFixture ($ChildProof.actionCount -eq 1) 'Captured fixture build proof missing.'

$States = @('UnrealPak', 'ShaderCompileWorker', 'UnrealEditor')
$Now = 0L
$Calls = New-Object Collections.ArrayList
$Capacity = [pscustomobject]@{ physicalCores = 4; availablePhysicalRamGiB = 24.0; commitHeadroomGiB = 24.0; volumes = @([pscustomobject]@{ availableBytes = 50GB; knownAllocationBytes = 0L; recoveryFloorBytes = 20GB }) }
$Sequence = Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { $Now } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild {
	param($Target, $Limit)
	[void] $Calls.Add($Target)
	return [pscustomobject]@{ target = $Target; nativeExitCode = 0; actionCount = 1; progressCount = 1; selectionVerified = $true; productsVerified = $true; cleanupVerified = $true; command = @('Build.bat', $Target); logSha256 = ('a' * 64) }
}
Assert-HostFixture ($Sequence.Count -eq 3 -and $Calls.Count -eq 3 -and @($Sequence | Where-Object { $_.actionLimit -ne 4 }).Count -eq 0) 'Success sequence failed.'
$AdmissionState = [pscustomobject]@{ commit = [long] 24GB; ordinal = 0 }
$AdmissionNow = 0L
$AdmissionMonitor = New-RoutineCompileResourceMonitor -Roots @{ evidence = $PSScriptRoot } -ResolveVolume {
	param($Root) [pscustomobject]@{ mount = 'F:\'; volumeId = 'admission-fixture' }
} -ReadDisk {
	param($Volume) [pscustomobject]@{ volumeId = 'admission-fixture'; availableBytes = 50GB }
} -ReadMemory {
	[pscustomobject]@{ availableRamBytes = 24GB; commitHeadroomBytes = [long] $AdmissionState.commit }
} -ReadPhysicalCores { 4 } -ReadMilliseconds { [long] $AdmissionNow }
$Admitted = Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -AdmitTarget {
	$AdmissionState.commit = @([long] 24GB, [long] 9GB, [long] 12GB)[$AdmissionState.ordinal]
	$AdmissionState.ordinal++
	Get-RoutineCompileActionLimit -Monitor $AdmissionMonitor
} -InvokeBuild {
	param($Target, $Limit)
	[pscustomobject]@{ target = $Target; nativeExitCode = 0; actionCount = 1; progressCount = 1; selectionVerified = $true;
		productsVerified = $true; cleanupVerified = $true; command = @('Build.bat', $Target); logSha256 = ('a' * 64) }
}
$AdmissionProof = Get-RoutineCompileResourceProof -Monitor $AdmissionMonitor
Assert-HostFixture ($AdmissionProof.targetAdmissionCount -eq 3 -and $AdmissionProof.minimumActionLimit -eq 1 -and
	$AdmissionProof.maximumActionLimit -eq 4 -and (@($Admitted | ForEach-Object actionLimit) -join ',') -ceq '4,1,2') 'Receipt admission proof must match three bounded target limits.'
$Capacity.commitHeadroomGiB = 9.0
$LowCap = Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { param($Target,$Limit) [pscustomobject]@{ target=$Target; nativeExitCode=0; actionCount=1; progressCount=1; selectionVerified=$true; productsVerified=$true; cleanupVerified=$true; command=@('Build.bat',$Target); logSha256=('a'*64) } }
Assert-HostFixture (@($LowCap | Where-Object { $_.actionLimit -ne 1 }).Count -eq 0) 'Commit headroom did not cap to one action.'
$Capacity.commitHeadroomGiB = 8.0
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { throw 'must_not_start' } } 'resource_admission_refused'
$Capacity.commitHeadroomGiB = 24.0
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 300L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { throw 'must_not_start' } } 'useful_work_deadline'
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { param($Target,$Limit) [pscustomobject]@{ target=$Target; nativeExitCode=0; actionCount=1; progressCount=1; selectionVerified=$true; productsVerified=$true; cleanupVerified=$false; command=@(); logSha256=('a'*64) } } } 'cleanup_unproven'
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { param($Target,$Limit) [pscustomobject]@{ target=$Target; nativeExitCode=0; actionCount=0; progressCount=0; selectionVerified=$true; productsVerified=$true; cleanupVerified=$true; command=@(); logSha256=('a'*64) } } } 'actions_unproven'
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { param($Target,$Limit) [pscustomobject]@{ target=$Target; nativeExitCode=0; actionCount=1; progressCount=1; selectionVerified=$true; productsVerified=$false; cleanupVerified=$true; command=@(); logSha256=('a'*64) } } } 'products_unproven'
Assert-HostFailure { Invoke-HostToolProvisioningSequence -Targets $States -ReadTicks { 0L } -UsefulDeadlineTicks 300 -CleanupDeadlineTicks 360 -ReadCapacity { $Capacity } -InvokeBuild { param($Target,$Limit) [pscustomobject]@{ target=$Target; nativeExitCode=1; actionCount=1; progressCount=1; selectionVerified=$true; productsVerified=$true; cleanupVerified=$true; command=@(); logSha256=('a'*64) } } } 'native_build_failed'

$SampleMilliseconds = 0L
$AvailableDisk = 50GB
$LowMemory = 1GB
$ResourceArgs = @{
	Roots = @{ evidence = $PSScriptRoot }
	ResolveVolume = { param($Root) [pscustomobject]@{ mount = 'F:\'; volumeId = 'fixture-volume' } }
	ReadDisk = { param($Volume) [pscustomobject]@{ volumeId = 'fixture-volume'; availableBytes = [long] $AvailableDisk } }
	ReadMemory = { [pscustomobject]@{ availableRamBytes = [long] $LowMemory; commitHeadroomBytes = 24GB } }
	ReadPhysicalCores = { 4 }
	ReadMilliseconds = { [long] $SampleMilliseconds }
}
$PressureMonitor = New-RoutineCompileResourceMonitor @ResourceArgs
$SampleMilliseconds = 5000L
$null = Update-RoutineCompileResources -Monitor $PressureMonitor
$SampleMilliseconds = 10000L
Assert-HostFailure { Update-RoutineCompileResources -Monitor $PressureMonitor } 'resource_pressure'
$LowMemory = 24GB; $SampleMilliseconds = 0L; $AvailableDisk = 20GB
Assert-HostFailure { New-RoutineCompileResourceMonitor @ResourceArgs } 'disk_floor_reached'

} finally {
	if ([IO.Path]::GetFileName($FixtureTempRoot) -cnotmatch '^AethelnHostToolsFixture-[0-9a-f]{32}$') { throw 'fixture_cleanup_path_invalid' }
	Remove-HostFixtureRoot -Root $FixtureTempRoot -Parent $FixtureParent
}
Assert-HostFixture (-not (Test-Path -LiteralPath $FixtureTempRoot)) 'Fixture suite cleanup failed.'
'PASS Invoke-HostToolProvisioning fixtures'
