# Reviewed request binding, not endpoint/filter/hook certification. The caller
# supplies the frozen, operator-reviewed request; no true/false approval flag
# can replace its exact source/repository/revision/cache identity.
# Git LFS 3.5.1 resolves relative storage against the common Git storage dir:
# https://github.com/git-lfs/git-lfs/blob/v3.5.1/fs/fs.go#L186-L208
# https://github.com/git-lfs/git-lfs/blob/v3.5.1/fs/fs.go#L276-L291
function Invoke-InitialPreparationSourceGit {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Arguments,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][scriptblock] $OnProgress)
	if ($Arguments -cnotin @('rev-parse --show-toplevel', 'rev-parse --path-format=absolute --git-common-dir', 'config --path --get lfs.storage', 'config --get lfs.storage') -and
		$Arguments -cnotmatch '^rev-parse --verify [0-9a-f]{40}\^\{commit\}$') { throw 'source_git_query_invalid' }
	Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
	Initialize-PreparationGitHubTransport
	if (-not ('Aetheln.PreparationSourceGitTask' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Threading.Tasks;
namespace Aetheln {
 public static class PreparationSourceGitTask {
  public static Task<object> Start(Type transport,string exe,string arguments,int milliseconds) {
   return Task.Factory.StartNew<object>(() => transport.GetMethod("Run").Invoke(null,new object[]{exe,arguments,null,milliseconds}));
  }
 }
}
'@
	}
	$Remaining = [int][Math]::Min(15000, [Math]::Floor(($Attempt.stopUsefulWorkTicks - (Get-InitialPreparationTick)) * 1000.0 / $Attempt.monotonicFrequency))
	if ($Remaining -lt 1) { throw 'useful_work_deadline' }
	$Git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	$Command = '--no-replace-objects --no-optional-locks -C "' + $Root + '" ' + $Arguments
	$Task = [Aetheln.PreparationSourceGitTask]::Start([Aetheln.PreparationGitHubTransport], $Git, $Command, $Remaining)
	try {
		while (-not $Task.Wait(100)) { Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress }
		$Result = $Task.Result
		if ($Result.Output -isnot [string] -or $Result.Output.Length -gt 4096 -or
			($Result.ExitCode -isnot [int] -and $Result.ExitCode -isnot [long])) { throw 'source_git_result_invalid' }
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		return $Result
	} finally {
		# The existing bounded transport terminates its native child. The outer
		# operation Job remains the hard interruption/descendant owner.
		if (-not $Task.IsCompleted) {
			try { if (-not $Task.Wait(18000)) { throw 'source_git_cleanup_unproven' } }
			catch { if (-not $Task.IsCompleted) { throw 'source_git_cleanup_unproven' } }
		}
	}
}

function ConvertTo-InitialPreparationSourcePath {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path)
	if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 4096 -or $Path -match '["\x00-\x1f\x7f<>|?*]' -or $Path.Substring(2).Contains(':')) { throw 'source_path_invalid' }
	$Full = [IO.Path]::GetFullPath($Path)
	if ($Full.Length -gt 3) { $Full = $Full.TrimEnd('\', '/') }
	Assert-InitialPreparationPlainPath -Path $Full -Reason 'source_path_invalid'
	return $Full
}

function Get-InitialPreparationSourceLine {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][string] $FailureCode)
	if (($Result.ExitCode -isnot [int] -and $Result.ExitCode -isnot [long]) -or $Result.ExitCode -ne 0 -or
		$Result.Output -isnot [string] -or $Result.Output.Length -gt 4096 -or $Result.Output -cnotmatch '\A([^\r\n\x00]+)\r?\n\z') { throw $FailureCode }
	return $Matches[1]
}

function Test-InitialPreparationSourceBinding {
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)] $ReviewedRequest,
		[Parameter(Mandatory)][string] $SourceRoot, [Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string] $TargetRevision, [Parameter(Mandatory)][string] $LfsStorageRoot,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][scriptblock] $OnProgress)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	# Full request schema/hash validation belongs to the caller. These exact
	# bindings must still hold at the materializer's trust callback boundary.
	try {
		if ($ReviewedRequest -isnot [pscustomobject]) { throw 'invalid' }
		foreach ($Field in @('sourceRoot', 'repository', 'targetRevision', 'lfsStorageRoot')) {
			if ($ReviewedRequest.$Field -isnot [string]) { throw 'invalid' }
		}
		if ($Repository -cne $Attempt.repository -or $TargetRevision -cne $Attempt.targetRevision -or
			$ReviewedRequest.repository -cne $Repository -or $ReviewedRequest.targetRevision -cne $TargetRevision) { throw 'invalid' }
		$Source = ConvertTo-InitialPreparationSourcePath -Path $SourceRoot
		$ExpectedSource = ConvertTo-InitialPreparationSourcePath -Path $ReviewedRequest.sourceRoot
		$Cache = ConvertTo-InitialPreparationSourcePath -Path $LfsStorageRoot
		$ExpectedCache = ConvertTo-InitialPreparationSourcePath -Path $ReviewedRequest.lfsStorageRoot
		if (-not [string]::Equals($Source, $ExpectedSource, [StringComparison]::OrdinalIgnoreCase) -or
			-not [string]::Equals($Cache, $ExpectedCache, [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid' }
	} catch { throw 'source_review_context_mismatch' }
	$Pins = New-Object Collections.ArrayList
	try {
		try { foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Source)) { [void] $Pins.Add($Pin) } } catch { throw 'source_repository_invalid' }
		$GitArgs = @{ Root = $Source; Attempt = $Attempt; OnProgress = $OnProgress }
		$Top = Get-InitialPreparationSourceLine -Result (Invoke-InitialPreparationSourceGit @GitArgs -Arguments 'rev-parse --show-toplevel') -FailureCode 'source_repository_invalid'
		try { $Top = ConvertTo-InitialPreparationSourcePath -Path $Top } catch { throw 'source_repository_invalid' }
		if (-not [string]::Equals($Top, $Source, [StringComparison]::OrdinalIgnoreCase)) { throw 'source_repository_invalid' }
		$Commit = Get-InitialPreparationSourceLine -Result (Invoke-InitialPreparationSourceGit @GitArgs -Arguments ('rev-parse --verify ' + $TargetRevision + '^{commit}')) -FailureCode 'source_commit_unavailable'
		if ($Commit -cne $TargetRevision) { throw 'source_commit_unavailable' }
		$Common = Get-InitialPreparationSourceLine -Result (Invoke-InitialPreparationSourceGit @GitArgs -Arguments 'rev-parse --path-format=absolute --git-common-dir') -FailureCode 'source_repository_invalid'
		try {
			$Common = ConvertTo-InitialPreparationSourcePath -Path $Common
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Common)) { [void] $Pins.Add($Pin) }
		} catch { throw 'source_repository_invalid' }
		# Read ONLY this named non-secret key. The raw comparison prevents --path
		# tilde/prefix expansion from attesting a different path than git-lfs3.5.1,
		# whose config/config.go passes the raw value to fs.New.
		$Configured = Invoke-InitialPreparationSourceGit @GitArgs -Arguments 'config --path --get lfs.storage'
		$Raw = Invoke-InitialPreparationSourceGit @GitArgs -Arguments 'config --get lfs.storage'
		foreach ($Query in @($Configured, $Raw)) {
			if (($Query.ExitCode -isnot [int] -and $Query.ExitCode -isnot [long]) -or $Query.ExitCode -notin @(0, 1) -or
				$Query.Output -isnot [string] -or $Query.Output.Length -gt 4096) { throw 'source_cache_query_failed' }
		}
		if ($Configured.ExitCode -ne $Raw.ExitCode) { throw 'source_cache_query_failed' }
		if ($Configured.ExitCode -eq 1) {
			if ($Configured.Output.Length -ne 0 -or $Raw.Output.Length -ne 0) { throw 'source_cache_query_failed' }
			$Storage = Join-Path $Common 'lfs'
		} else {
			$Storage = Get-InitialPreparationSourceLine -Result $Configured -FailureCode 'source_cache_invalid'
			$RawStorage = Get-InitialPreparationSourceLine -Result $Raw -FailureCode 'source_cache_invalid'
			if ($RawStorage -cne $Storage) { throw 'source_cache_expansion_unsupported' }
			if ($Storage -notmatch '^[A-Za-z]:[\\/]') {
				if ([IO.Path]::IsPathRooted($Storage) -or $Storage.Contains(':') -or $Storage -match '["\x00-\x1f\x7f<>|?*]') { throw 'source_cache_invalid' }
				$Storage = Join-Path $Common $Storage
			}
		}
		try { $Storage = ConvertTo-InitialPreparationSourcePath -Path $Storage } catch { throw 'source_cache_invalid' }
		if (-not [string]::Equals($Storage, $Cache, [StringComparison]::OrdinalIgnoreCase)) { throw 'source_cache_mismatch' }
		try { foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Storage)) { [void] $Pins.Add($Pin) } } catch { throw 'source_cache_invalid' }
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		return $true
	} finally { foreach ($Pin in $Pins) { $Pin.Dispose() } }
}
