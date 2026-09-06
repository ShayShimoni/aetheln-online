[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $RepositoryRoot,
	[switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This helper is for an exclusively owned trusted compile checkout. Checkout
# switches tracked source first. Retention is only a filesystem policy: it does
# not attest cache identity, producing revision, or successful compilation.
$Root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]'\/')
if (-not [IO.Path]::IsPathRooted($RepositoryRoot) -or $Root -eq [IO.Path]::GetPathRoot($Root).TrimEnd([char[]]'\/')) {
	throw 'compile_workspace_root_invalid'
}
$Prefix = $Root + [IO.Path]::DirectorySeparatorChar
$Comparison = [StringComparison]::OrdinalIgnoreCase

function Assert-PlainPath([string] $Path) {
	$Current = [IO.Path]::GetFullPath($Path)
	if ($Current -ne $Root -and -not $Current.StartsWith($Prefix, $Comparison)) { throw 'compile_workspace_path_escape' }
	while ($Current) {
		$Item = Get-Item -LiteralPath $Current -Force -ErrorAction Stop
		if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'compile_workspace_reparse_point' }
		$Parent = [IO.Path]::GetDirectoryName($Current)
		if ($Parent -eq $Current) { break }
		$Current = $Parent
	}
}

function Assert-RelativePath([string] $Relative) {
	if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[\\:\x00-\x1f]' -or $Relative.StartsWith('/')) { throw 'compile_workspace_path_invalid' }
	foreach ($Part in $Relative.Split('/')) {
		if (-not $Part -or $Part -eq '.' -or $Part -eq '..' -or $Part -match '[. ]$' -or $Part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'compile_workspace_path_invalid' }
		# Inspect names only. Never open secret-bearing paths or their children.
		if ($Part -match '^(?i:\.env(?:\..*)?|\.ssh|\.aws|\.azure|\.gnupg|secrets?|credentials?(?:\..*)?|id_rsa|id_ed25519)$' -or $Part -match '(?i)\.(pem|key|pfx|p12)$') {
			throw 'compile_workspace_sensitive_path'
		}
	}
}

function Test-Retained([string] $Relative) {
	return $Relative.StartsWith('Binaries/', $Comparison) -or $Relative.StartsWith('Intermediate/Build/', $Comparison)
}
function Test-RetainedDirectory([string] $Relative) {
	return $Relative -ieq 'Binaries' -or $Relative -ieq 'Intermediate/Build' -or (Test-Retained $Relative)
}

function Invoke-GitInventory([string] $Arguments) {
	# Native PowerShell pipelines split lines; ReadToEnd preserves Git's raw NUL
	# boundaries and UTF-8 paths, including spaces and literal wildcard characters.
	$Start = New-Object Diagnostics.ProcessStartInfo
	$Start.FileName = 'git'
	$Start.Arguments = $Arguments
	$Start.WorkingDirectory = $Root
	$Start.UseShellExecute = $false
	$Start.CreateNoWindow = $true
	$Start.RedirectStandardOutput = $true
	$Start.RedirectStandardError = $true
	$Start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false, $true)
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = $Start
	try {
		if (-not $Process.Start()) { throw 'compile_workspace_git_failed' }
		$ErrorRead = $Process.StandardError.ReadToEndAsync()
		$Output = $Process.StandardOutput.ReadToEnd()
		$Process.WaitForExit()
		$null = $ErrorRead.GetAwaiter().GetResult()
		if ($Process.ExitCode -ne 0) { throw 'compile_workspace_git_failed' }
		return $Output
	} finally { $Process.Dispose() }
}

Assert-PlainPath $Root
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'compile_workspace_root_invalid' }

# Preflight the entire checkout before asking Git to enumerate it. Never descend
# through a reparse point, nested repository, or sensitive directory, even inside
# a retained output root. .git is preserved and its content is never enumerated.
$Files = New-Object 'Collections.Generic.List[object]'
$Directories = New-Object 'Collections.Generic.List[object]'
$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$Pending = New-Object 'Collections.Generic.Queue[string]'
$Pending.Enqueue($Root)
while ($Pending.Count -gt 0) {
	$Directory = $Pending.Dequeue()
	Assert-PlainPath $Directory
	foreach ($Item in (Get-ChildItem -LiteralPath $Directory -Force)) {
		$Relative = $Item.FullName.Substring($Prefix.Length).Replace('\', '/')
		if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'compile_workspace_reparse_point' }
		if ($Relative -ieq '.git') { continue }
		Assert-RelativePath $Relative
		if ($Item.Name -ieq '.git') { throw 'compile_workspace_nested_repository' }
		if (-not $Seen.Add($Relative)) { throw 'compile_workspace_case_collision' }
		if ($Item.PSIsContainer) {
			$Directories.Add(@{ Path = $Item.FullName; Relative = $Relative })
			$Pending.Enqueue($Item.FullName)
		} else {
			if ($Relative -ieq 'Binaries' -or $Relative -ieq 'Intermediate' -or $Relative -ieq 'Intermediate/Build') { throw 'compile_workspace_retained_root_collision' }
			$Files.Add(@{ Path = $Item.FullName; Relative = $Relative })
		}
	}
}
$ActualRoot = (Invoke-GitInventory 'rev-parse --show-toplevel').TrimEnd([char[]]"`r`n")
if (-not [IO.Path]::GetFullPath($ActualRoot).TrimEnd([char[]]'\/').Equals($Root, $Comparison)) { throw 'compile_workspace_repository_root_mismatch' }

$Tracked = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$TrackedDirectories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($Entry in (Invoke-GitInventory 'ls-files --stage -z').Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
	if ($Entry -notmatch '^([0-9]{6}) [0-9a-f]+ ([0-3])\t(.+)$') { throw 'compile_workspace_git_inventory_invalid' }
	$Mode = $Matches[1]
	$Stage = $Matches[2]
	$Relative = $Matches[3]
	Assert-RelativePath $Relative
	if ($Mode -ne '100644' -and $Mode -ne '100755') { throw 'compile_workspace_tracked_type_unsupported' }
	if ($Stage -ne '0') { throw 'compile_workspace_index_unmerged' }
	if (-not $Tracked.Add($Relative)) { throw 'compile_workspace_case_collision' }
	if ((Test-Retained $Relative) -or $Relative -ieq 'Binaries' -or $Relative -ieq 'Intermediate/Build') { throw 'compile_workspace_tracked_retention_collision' }
	$Parent = $Relative
	while ($Parent.Contains('/')) {
		$Parent = $Parent.Substring(0, $Parent.LastIndexOf('/'))
		$null = $TrackedDirectories.Add($Parent)
	}
}
$Untracked = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
# No --exclude-standard: ignored paths such as Intermediate/Source must be cleaned.
foreach ($Relative in (Invoke-GitInventory 'ls-files --others -z').Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
	Assert-RelativePath $Relative
	if (-not $Untracked.Add($Relative) -or $Tracked.Contains($Relative)) { throw 'compile_workspace_inventory_collision' }
}
$Cleanup = New-Object 'Collections.Generic.List[object]'
$RetainedCount = 0
foreach ($Directory in $Directories) {
	if ($Tracked.Contains($Directory.Relative)) { throw 'compile_workspace_tracked_type_collision' }
}
foreach ($File in $Files) {
	if ($TrackedDirectories.Contains($File.Relative)) { throw 'compile_workspace_tracked_type_collision' }
	if ($Tracked.Contains($File.Relative)) { continue }
	if (-not $Untracked.Contains($File.Relative)) { throw 'compile_workspace_unclassified_file' }
	if (Test-Retained $File.Relative) { $RetainedCount++; continue }
	$Cleanup.Add($File)
}

$Removed = 0
if (-not $CheckOnly) {
	foreach ($File in $Cleanup) {
		Assert-PlainPath $File.Path
		if (Test-Path -LiteralPath $File.Path -PathType Container) { throw 'compile_workspace_type_changed' }
		Remove-Item -LiteralPath $File.Path -Force -ErrorAction Stop
		$Removed++
	}
	foreach ($Directory in ($Directories | Sort-Object { $_.Path.Length } -Descending)) {
		if ((Test-RetainedDirectory $Directory.Relative) -or $TrackedDirectories.Contains($Directory.Relative)) { continue }
		Assert-PlainPath $Directory.Path
		if (@(Get-ChildItem -LiteralPath $Directory.Path -Force).Count -eq 0) {
			# Deliberately nonrecursive: a concurrent/new child is never adopted.
			[IO.Directory]::Delete($Directory.Path, $false)
		}
	}
}
[pscustomobject]@{
	repositoryRoot = $Root
	checkOnly = [bool]$CheckOnly
	retainedRoots = @('Binaries/', 'Intermediate/Build/')
	retainedFileCount = $RetainedCount
	cleanupFileCount = $Cleanup.Count
	removedFileCount = $Removed
}
