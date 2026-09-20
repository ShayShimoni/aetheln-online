[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/ManagedCompileWorkspace.ps1')
function Assert-ManagedFixture {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Invoke-ManagedFixtureGit {
	param([string] $Root, [string[]] $Arguments)
	$Lines = & git -C $Root -c core.autocrlf=false @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) { throw 'fixture_git_failed' }
	return ($Lines -join "`n")
}
function Set-ManagedFixtureFile {
	[CmdletBinding(SupportsShouldProcess)]
	param([string] $Root, [string] $Path, [string] $Value)
	$Full = Join-Path $Root $Path
	if (-not $PSCmdlet.ShouldProcess($Full, 'Write disposable fixture input')) { return }
	$null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Full))
	[IO.File]::WriteAllText($Full, $Value, (New-Object Text.UTF8Encoding($false)))
}
function Assert-ManagedRejection {
	param([scriptblock] $Action, [string] $Reason)
	$Failure = ''
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.GetBaseException().Message }
	Assert-ManagedFixture -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; got $Failure"
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnManagedWorkspace-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$EarlyParameters = @{ ControlRoot = (Join-Path $FixtureRoot 'absent-control'); TargetRoot = (Join-Path $FixtureRoot 'absent-target'); Repository = 'owner/repository'; SourceRevision = ('a' * 40); ExpectedGitCommonDirectory = (Join-Path $FixtureRoot 'absent-common'); DeadlineUtc = [DateTime]::UtcNow.AddDays(1); AssertRepositoryTrust = { return $true }; RemainingBudget = { 0 } }
Assert-ManagedRejection -Action { Sync-ManagedCompileWorkspace @EarlyParameters } -Reason 'compile_timeout'
Assert-ManagedFixture -Condition (-not (Test-Path -LiteralPath $EarlyParameters.TargetRoot)) -Message 'Expired monotonic budget must prevent workspace mutation'
foreach ($Value in @($null, '1000', $true, [double]::NaN, [double]::PositiveInfinity, @('one', 'two'))) {
	$EarlyParameters.RemainingBudget = { $Value }.GetNewClosure()
	Assert-ManagedRejection -Action { Sync-ManagedCompileWorkspace @EarlyParameters } -Reason 'compile_clock_invalid'
}
$EarlyParameters.RemainingBudget = { 10000 }
foreach ($Reason in @('compile_timeout', 'resource_pressure', 'disk_floor_reached')) {
	$EarlyParameters.OnProgress = { throw $Reason }.GetNewClosure()
	Assert-ManagedRejection -Action { Sync-ManagedCompileWorkspace @EarlyParameters } -Reason $Reason
}
Write-Output 'PASS monotonic-admission-and-progress-reasons'
foreach ($Case in @('same', 'different', 'same-tree', 'linked', 'autocrlf', 'dirty', 'index', 'collision', 'ignored-collision', 'untracked-input', 'lfs-pointer', 'expired', 'wrong-control', 'trust', 'generated', 'symlink-mode', 'case-collision', 'wrong-common', 'same-root', 'volume-root', 'relative-root', 'reparse-root', 'hydrated-lfs', 'nonselected-lfs-pointer', 'external-descriptor', 'newline-revision', 'monotonic-forward-utc')) {
	$Control = Join-Path $FixtureRoot ($Case + '-control')
	$Target = Join-Path $FixtureRoot ($Case + '-target')
	$null = New-Item -ItemType Directory -Path $Control
	$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('init', '--quiet')
	Set-ManagedFixtureFile -Root $Control -Path 'AethelnOnline.uproject' -Value '{}'
	Set-ManagedFixtureFile -Root $Control -Path '.gitignore' -Value "Binaries/`nIntermediate/`nignored.txt`n"
	Set-ManagedFixtureFile -Root $Control -Path 'Source/input.cpp' -Value "// initial`n"
	$Payload = 'fixture hydrated bytes'
	if ($Case -in @('hydrated-lfs', 'nonselected-lfs-pointer')) {
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Oid = ([BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload)))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		$LfsPath = if ($Case -eq 'hydrated-lfs') { 'Content/data.uasset' } else { 'output/report.pdf' }
		Set-ManagedFixtureFile -Root $Control -Path $LfsPath -Value ("version https://git-lfs.github.com/spec/v1`noid sha256:$Oid`nsize $($Payload.Length)`n")
	}
	$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('add', '.')
	$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'initial')
	$Old = Invoke-ManagedFixtureGit -Root $Control -Arguments @('rev-parse', 'HEAD')
	if ($Case -ceq 'linked') {
		$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('worktree', 'add', '--quiet', '--detach', $Target, $Old)
	} else { $null = Invoke-ManagedFixtureGit -Root $FixtureRoot -Arguments @('clone', '--quiet', '--no-hardlinks', $Control, $Target) }
	if ($Case -eq 'autocrlf') { $null = Invoke-ManagedFixtureGit -Root $Target -Arguments @('config', 'core.autocrlf', 'true') }
	Set-ManagedFixtureFile -Root $Target -Path 'Binaries/sentinel.bin' -Value 'binary sentinel'
	Set-ManagedFixtureFile -Root $Target -Path 'Intermediate/Build/sentinel.obj' -Value 'object sentinel'
	if ($Case -eq 'hydrated-lfs') { Set-ManagedFixtureFile -Root $Target -Path $LfsPath -Value $Payload }
	if ($Case -in @('different', 'linked', 'collision')) { Set-ManagedFixtureFile -Root $Control -Path 'Source/new.cpp' -Value '// new' }
	if ($Case -eq 'autocrlf') { Set-ManagedFixtureFile -Root $Control -Path 'Source/new.cpp' -Value "// new`n" }
	if ($Case -eq 'ignored-collision') { Set-ManagedFixtureFile -Root $Control -Path 'ignored.txt' -Value 'tracked'; $null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('add', '-f', 'ignored.txt') }
	if ($Case -eq 'lfs-pointer') { Set-ManagedFixtureFile -Root $Control -Path 'Content/test.uasset' -Value ("version https://git-lfs.github.com/spec/v1`noid sha256:" + ('a' * 64) + "`nsize 500`n") }
	if ($Case -eq 'generated') { Set-ManagedFixtureFile -Root $Control -Path 'Binaries/tracked.bin' -Value 'bad'; $null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('add', '-f', 'Binaries/tracked.bin') }
	if ($Case -eq 'external-descriptor') { Set-ManagedFixtureFile -Root $Control -Path 'AethelnOnline.uproject' -Value '{"AdditionalRootDirectories":["../outside"]}' }
	$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('add', '.')
	if ($Case -in @('symlink-mode', 'case-collision')) {
		$Blob = Invoke-ManagedFixtureGit -Root $Control -Arguments @('hash-object', 'Source/input.cpp')
		$Mode = if ($Case -eq 'symlink-mode') { '120000' } else { '100644' }
		$Path = if ($Case -eq 'symlink-mode') { 'Source/link' } else { 'Source/INPUT.cpp' }
		$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('update-index', '--add', '--cacheinfo', "$Mode,$Blob,$Path")
	}
	$null = Invoke-ManagedFixtureGit -Root $Control -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '--allow-empty', '-m', 'candidate')
	$Revision = Invoke-ManagedFixtureGit -Root $Control -Arguments @('rev-parse', 'HEAD')
	if ($Case -eq 'same') { $null = Invoke-ManagedFixtureGit -Root $Target -Arguments @('fetch', '--quiet', $Control, $Revision); $null = Invoke-ManagedFixtureGit -Root $Target -Arguments @('checkout', '--quiet', '--detach', $Revision) }
	if ($Case -in @('dirty', 'index')) { Set-ManagedFixtureFile -Root $Target -Path 'Source/input.cpp' -Value '// dirty' }
	if ($Case -eq 'index') { $null = Invoke-ManagedFixtureGit -Root $Target -Arguments @('add', 'Source/input.cpp') }
	if ($Case -eq 'collision') { Set-ManagedFixtureFile -Root $Target -Path 'Source/new.cpp' -Value 'preserve' }
	if ($Case -eq 'ignored-collision') { Set-ManagedFixtureFile -Root $Target -Path 'ignored.txt' -Value 'preserve' }
	if ($Case -eq 'untracked-input') { Set-ManagedFixtureFile -Root $Target -Path 'Source/extra.cpp' -Value 'preserve' }
	$Common = Invoke-ManagedFixtureGit -Root $Target -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
	$SyncParameters = @{ ControlRoot = $Control; TargetRoot = $Target; Repository = 'owner/repository'; SourceRevision = $Revision; ExpectedGitCommonDirectory = $Common; DeadlineUtc = [DateTime]::UtcNow.AddMinutes(2); AssertRepositoryTrust = { return $true } }
	if ($Case -eq 'expired') { $SyncParameters.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1) }
	if ($Case -eq 'monotonic-forward-utc') { $SyncParameters.DeadlineUtc = [DateTime]::UtcNow.AddDays(-1); $SyncParameters.RemainingBudget = { 30000 } }
	if ($Case -eq 'wrong-control') { $SyncParameters.SourceRevision = $Old }
	if ($Case -eq 'trust') { $SyncParameters.Remove('AssertRepositoryTrust') }
	if ($Case -eq 'newline-revision') { $SyncParameters.SourceRevision = $Revision + "`n" }
	if ($Case -eq 'wrong-common') { $SyncParameters.ExpectedGitCommonDirectory = Join-Path $Control '.git' }
	if ($Case -eq 'same-root') { $SyncParameters.TargetRoot = $Control }
	if ($Case -eq 'volume-root') { $SyncParameters.TargetRoot = [IO.Path]::GetPathRoot($Control) }
	if ($Case -eq 'relative-root') { $SyncParameters.TargetRoot = '.' }
	if ($Case -eq 'reparse-root') {
		$Junction = Join-Path $FixtureRoot 'reparse-alias'
		$null = New-Item -ItemType Junction -Path $Junction -Target $Target
		$SyncParameters.TargetRoot = $Junction
	}
	$Expected = switch ($Case) {
		'dirty' { 'managed_workspace_dirty' }; 'index' { 'managed_workspace_index_mismatch' }
		'collision' { 'managed_workspace_collision' }; 'ignored-collision' { 'managed_workspace_collision' }
		'untracked-input' { 'managed_workspace_untracked_input' }; 'lfs-pointer' { 'managed_workspace_lfs_hydration_required' }
		'expired' { 'managed_workspace_deadline' }; 'wrong-control' { 'managed_workspace_revision_mismatch' }
		'trust' { 'managed_workspace_trust_required' }; 'generated' { 'managed_workspace_generated_path' }
		'symlink-mode' { 'managed_workspace_tree_invalid' }; 'case-collision' { 'managed_workspace_path_collision' }
		'wrong-common' { 'managed_workspace_common_directory_mismatch' }; 'same-root' { 'managed_workspace_root_overlap' }
		'volume-root' { 'managed_workspace_root_invalid' }; 'relative-root' { 'managed_workspace_root_invalid' }
		'reparse-root' { 'managed_workspace_reparse_path' }; 'external-descriptor' { 'managed_workspace_external_descriptor_root' }
		'newline-revision' { 'managed_workspace_identity_invalid' }
		default { '' }
	}
	if ($Expected) { Assert-ManagedRejection -Action { Sync-ManagedCompileWorkspace @SyncParameters } -Reason $Expected }
	else {
		$Result = Sync-ManagedCompileWorkspace @SyncParameters
		Assert-ManagedFixture -Condition ($Result.sourceRevision -ceq $Revision -and (Invoke-ManagedFixtureGit -Root $Target -Arguments @('rev-parse', 'HEAD')) -ceq $Revision) -Message 'Exact commit was not synchronized'
		Assert-ManagedFixture -Condition ($Result.changed -eq ($Case -ne 'same')) -Message 'Change classification wrong'
		if ($Case -eq 'autocrlf') {
			$ExpectedBytes = [Text.Encoding]::UTF8.GetBytes("// new`n")
			$ActualBytes = [IO.File]::ReadAllBytes((Join-Path $Target 'Source/new.cpp'))
			Assert-ManagedFixture -Condition ([Linq.Enumerable]::SequenceEqual([byte[]] $ActualBytes, [byte[]] $ExpectedBytes)) -Message 'Managed checkout applied core.autocrlf transformation'
		}
	}
	Assert-ManagedFixture -Condition ([IO.File]::ReadAllText((Join-Path $Target 'Binaries/sentinel.bin')) -ceq 'binary sentinel') -Message 'Binaries changed'
	Assert-ManagedFixture -Condition ([IO.File]::ReadAllText((Join-Path $Target 'Intermediate/Build/sentinel.obj')) -ceq 'object sentinel') -Message 'Intermediates changed'
	Assert-ManagedFixture -Condition ((Invoke-ManagedFixtureGit -Root $Control -Arguments @('rev-parse', 'HEAD')) -ceq $Revision) -Message 'Control HEAD changed'
	if ($Case -eq 'linked') { Assert-ManagedFixture -Condition (Test-Path -LiteralPath (Join-Path $Target '.git') -PathType Leaf) -Message 'Linked worktree overlaid' }
	Write-Output ('PASS ' + $Case)
}
# The Git alias is a disposable, read-only native wait, not a hook replacement.
# Its child has its own two-second bound; production descendant cleanup belongs
# to the enclosing hard-bounded gate and is tested by the parent integration.
$NativeContext = @{ deadline = [DateTime]::UtcNow.AddMilliseconds(300); seconds = 0.3; clock = [Diagnostics.Stopwatch]::StartNew(); progress = $null; git = (Get-Command git -CommandType Application | Select-Object -First 1).Source; pins = @{} }
Assert-ManagedRejection -Action { Invoke-ManagedWorkspaceGit -Root $Control -Arguments '-c "alias.managedwait=!sleep 2" managedwait' -Context $NativeContext } -Reason 'managed_workspace_deadline'
Assert-ManagedFixture -Condition ($NativeContext.clock.Elapsed.TotalSeconds -lt 1.5) -Message 'Native timeout extended deadline'
Write-Output 'PASS native-deadline'
$NativeContext.deadline = [DateTime]::UtcNow.AddSeconds(10); $NativeContext.seconds = 10; $NativeContext.clock.Restart()
Assert-ManagedRejection -Action { Invoke-ManagedWorkspaceGit -Root $Control -Arguments 'not-a-real-command' -Context $NativeContext } -Reason 'managed_workspace_git_failed'
Write-Output 'PASS native-failure-closed'
$MonotonicContext = @{ deadline = [DateTime]::UtcNow.AddDays(-1); seconds = -1; clock = [pscustomobject]@{ Elapsed = [TimeSpan]::Zero }; progress = $null; remainingBudget = { 1000 }; milliseconds = [double]::PositiveInfinity }
Assert-ManagedWorkspaceProgress -Context $MonotonicContext
$MonotonicContext.clock.Elapsed = [TimeSpan]::FromMilliseconds(500)
Assert-ManagedWorkspaceProgress -Context $MonotonicContext
Assert-ManagedFixture -Condition ($MonotonicContext.milliseconds -eq 1000) -Message 'Repeated operations must not replenish the original local bound'
$MonotonicContext.clock.Elapsed = [TimeSpan]::FromMilliseconds(1000)
Assert-ManagedRejection -Action { Assert-ManagedWorkspaceProgress -Context $MonotonicContext } -Reason 'compile_timeout'
Write-Output 'PASS monotonic-operation-budget-never-resets'
$NativeContext.remainingBudget = { 10000 }
foreach ($Reason in @('compile_timeout', 'resource_pressure', 'disk_floor_reached')) {
	$ProgressState = @{ Calls = 0 }
	$NativeContext.progress = { $ProgressState.Calls++; if ($ProgressState.Calls -ge 2) { throw $Reason } }.GetNewClosure()
	$NativeContext.milliseconds = [double]::PositiveInfinity
	$NativeContext.clock.Restart()
	Assert-ManagedRejection -Action { Invoke-ManagedWorkspaceGit -Root $Control -Arguments 'rev-parse HEAD' -Context $NativeContext } -Reason $Reason
}
Write-Output 'PASS native-progress-reasons-preserved'
foreach ($Unsafe in @('Source/../escape', 'Source/CON.cpp', 'Source/aux.txt', 'Source/trailing.', 'Source/a:b', 'Source/.env', 'Config/private.key', '.gitmodules', '.lfsconfig')) {
	$Failure = $null
	try { Test-ManagedWorkspaceRelativePath -Path $Unsafe | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-ManagedFixture -Condition ($null -ne $Failure) -Message 'Unsafe pathname accepted'
}
Write-Output ('Fixtures retained: ' + $FixtureRoot)
