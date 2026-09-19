[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Input.ps1')
$SourceModule = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Source.ps1'
if (-not (Test-Path -LiteralPath $SourceModule)) { throw 'Source binding implementation missing' }
. $SourceModule
function Assert-SourceTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-SourceFailure {
	param([scriptblock] $Action, [string] $Code)
	$Failure = ''
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.GetBaseException().Message }
	Assert-SourceTest -Condition ($Failure -ceq $Code) -Message "Expected $Code; got $Failure"
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnSource-' + [guid]::NewGuid().ToString('N'))
$SourceRoot = Join-Path $FixtureRoot 'source'
$CommonRoot = Join-Path $SourceRoot '.git'
$CacheRoot = Join-Path $FixtureRoot 'cache'
$EmptyCommon = Join-Path $SourceRoot '.git-empty'
$null = New-Item -ItemType Directory -Path $CommonRoot, $EmptyCommon, $CacheRoot, (Join-Path $CommonRoot 'lfs'), (Join-Path $CommonRoot 'relative-cache')
$Revision = 'b' * 40
$Attempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision $Revision -AttemptId ('source-' + [guid]::NewGuid().ToString('N'))
$Request = [pscustomobject]@{ sourceRoot = $SourceRoot; repository = 'owner/repository'; targetRevision = $Revision; lfsStorageRoot = $CacheRoot }
function Test-SourceCase {
	function Invoke-InitialPreparationSourceGit {
		param($Root, $Arguments, $Attempt, $OnProgress)
		Assert-SourceTest -Condition ($Root -ceq $SourceRoot -and $Attempt.targetRevision -ceq $Revision) -Message 'Source Git identity changed'
		& $OnProgress | Out-Null
		[void] $State.calls.Add($Arguments)
		$Value = ''; $Exit = 0
		switch -Exact ($Arguments) {
			'rev-parse --show-toplevel' { $Value = $SourceRoot; if ($State.mode -ceq 'wrong_top') { $Value = $FixtureRoot } }
			('rev-parse --verify ' + $Revision + '^{commit}') { $Value = $Revision; if ($State.mode -ceq 'missing_commit') { $Exit = 128 } }
			'rev-parse --path-format=absolute --git-common-dir' { $Value = $(if ($State.mode -ceq 'missing_default') { $EmptyCommon } else { $CommonRoot }) }
			'config --path --get lfs.storage' {
				$Value = $State.pathValue
				if ($State.mode -in @('default', 'missing_default')) { $Exit = 1 }
				if ($State.mode -ceq 'config_failure') { $Exit = 128 }
			}
			'config --get lfs.storage' { $Value = $State.rawValue; if ($State.mode -in @('default', 'missing_default')) { $Exit = 1 } }
			default { throw ('Unapproved source query: ' + $Arguments) }
		}
		return [pscustomobject]@{ ExitCode = $Exit; Output = $(if ($Exit -eq 0) { $Value + "`n" } else { '' }) }
	}
	foreach ($Mode in @('absolute', 'default', 'relative', 'mismatch', 'missing_cache', 'missing_default', 'wrong_top', 'missing_commit', 'config_failure', 'multiline', 'expansion', 'request_mismatch', 'boolean_context', 'array_context', 'array_root')) {
		$State = @{ mode = $Mode; calls = (New-Object Collections.ArrayList); pathValue = $CacheRoot; rawValue = $CacheRoot; progress = 0 }
		$CaseRequest = $Request | Select-Object *
		$ExpectedCache = $CacheRoot
		if ($Mode -ceq 'default') { $ExpectedCache = Join-Path $CommonRoot 'lfs'; $State.pathValue = ''; $State.rawValue = '' }
		if ($Mode -ceq 'missing_default') { $ExpectedCache = Join-Path $EmptyCommon 'lfs'; $State.pathValue = ''; $State.rawValue = '' }
		if ($Mode -ceq 'relative') { $ExpectedCache = Join-Path $CommonRoot 'relative-cache'; $State.pathValue = 'relative-cache'; $State.rawValue = 'relative-cache' }
		if ($Mode -ceq 'mismatch') { $State.pathValue = $FixtureRoot; $State.rawValue = $FixtureRoot }
		if ($Mode -ceq 'missing_cache') { $ExpectedCache = Join-Path $FixtureRoot 'absent'; $State.pathValue = $ExpectedCache; $State.rawValue = $ExpectedCache }
		if ($Mode -ceq 'multiline') { $State.pathValue = $CacheRoot + "`nother" }
		if ($Mode -ceq 'expansion') { $State.rawValue = '~/cache' }
		$CaseRequest.lfsStorageRoot = $ExpectedCache
		if ($Mode -ceq 'request_mismatch') { $CaseRequest.repository = 'other/repository' }
		if ($Mode -ceq 'array_root') { $CaseRequest.sourceRoot = @($SourceRoot) }
		if ($Mode -ceq 'boolean_context') { $CaseRequest = $true }
		if ($Mode -ceq 'array_context') { $CaseRequest = @($CaseRequest) }
		$Parameters = @{ ReviewedRequest = $CaseRequest; SourceRoot = $SourceRoot; Repository = 'owner/repository'; TargetRevision = $Revision; LfsStorageRoot = $ExpectedCache; Attempt = $Attempt; OnProgress = { $State.progress++; Write-Output 'discard me' } }
		if ($Mode -in @('absolute', 'default', 'relative')) {
			$Bound = Test-InitialPreparationSourceBinding @Parameters
			Assert-SourceTest -Condition ($Bound -is [bool] -and $Bound -and $State.progress -gt 0 -and $State.calls.Count -eq 5) -Message 'Valid source/cache binding failed'
		} else {
			$Reason = @{ mismatch = 'source_cache_mismatch'; missing_cache = 'source_cache_invalid'; missing_default = 'source_cache_invalid'; wrong_top = 'source_repository_invalid'; missing_commit = 'source_commit_unavailable'; config_failure = 'source_cache_query_failed'; multiline = 'source_cache_invalid'; expansion = 'source_cache_expansion_unsupported'; request_mismatch = 'source_review_context_mismatch'; boolean_context = 'source_review_context_mismatch'; array_context = 'source_review_context_mismatch'; array_root = 'source_review_context_mismatch' }[$Mode]
			Assert-SourceFailure -Action { Test-InitialPreparationSourceBinding @Parameters } -Code $Reason
			if ($Mode -in @('request_mismatch', 'boolean_context', 'array_context', 'array_root')) { Assert-SourceTest -Condition ($State.calls.Count -eq 0) -Message 'Invalid review context queried source' }
		}
	}
}
Test-SourceCase

# Real read-only queries against a new fixture repository and linked worktree.
# Only fixture-local named lfs.storage changes occur; never alter global config.
function Invoke-SourceFixtureGit {
	param([string] $Root, [string[]] $Arguments)
	$Value = & git -C $Root @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) { throw ('Fixture Git failed: ' + $Value) }
	return $Value
}
$NativeSource = Join-Path $FixtureRoot 'native'
$null = New-Item -ItemType Directory -Path $NativeSource
$null = Invoke-SourceFixtureGit -Root $NativeSource -Arguments @('init', '--quiet')
$null = Invoke-SourceFixtureGit -Root $NativeSource -Arguments @('-c', 'user.name=Source Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '--quiet', '-m', 'fixture')
$NativeRevision = [string](Invoke-SourceFixtureGit -Root $NativeSource -Arguments @('rev-parse', 'HEAD'))
$NativeAttempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision $NativeRevision -AttemptId ('native-source-' + [guid]::NewGuid().ToString('N'))
$NativeCommon = Join-Path $NativeSource '.git'
$NativeCache = Join-Path $NativeCommon 'relative-cache'
$null = New-Item -ItemType Directory -Path $NativeCache
$null = Invoke-SourceFixtureGit -Root $NativeSource -Arguments @('config', 'lfs.storage', 'relative-cache')
$NativeRequest = [pscustomobject]@{ sourceRoot = $NativeSource; repository = 'owner/repository'; targetRevision = $NativeRevision; lfsStorageRoot = $NativeCache }
$NativeBound = Test-InitialPreparationSourceBinding -ReviewedRequest $NativeRequest -SourceRoot $NativeSource -Repository owner/repository -TargetRevision $NativeRevision -LfsStorageRoot $NativeCache -Attempt $NativeAttempt -OnProgress {}
Assert-SourceTest -Condition ($NativeBound -is [bool] -and $NativeBound) -Message 'Real relative cache failed'
$LinkedSource = Join-Path $FixtureRoot 'native-linked'
$null = Invoke-SourceFixtureGit -Root $NativeSource -Arguments @('worktree', 'add', '--quiet', '--detach', $LinkedSource, $NativeRevision)
$NativeRequest.sourceRoot = $LinkedSource
$LinkedBound = Test-InitialPreparationSourceBinding -ReviewedRequest $NativeRequest -SourceRoot $LinkedSource -Repository owner/repository -TargetRevision $NativeRevision -LfsStorageRoot $NativeCache -Attempt $NativeAttempt -OnProgress {}
Assert-SourceTest -Condition ($LinkedBound -is [bool] -and $LinkedBound) -Message 'Linked worktree common-directory cache failed'
Write-Output "PASS: source/cache binding fixtures; retained $FixtureRoot"
