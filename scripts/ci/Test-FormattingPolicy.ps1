[CmdletBinding()]
param(
	[string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
	$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-GitRaw {
	param([Parameter(Mandatory)][string[]] $Arguments)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& git -C $RepositoryRoot @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	return @{ Output = $Output; ExitCode = $ExitCode }
}

function Invoke-Git {
	param([Parameter(Mandatory)][string[]] $Arguments)

	$Result = Invoke-GitRaw -Arguments $Arguments
	if ($Result.ExitCode -ne 0) {
		throw "git $($Arguments -join ' ') failed: $($Result.Output -join [Environment]::NewLine)"
	}
	return $Result.Output
}

$Violations = @()

# 1. Tracked text files must be stored with LF endings in the index.
foreach ($Line in (Invoke-Git -Arguments @('ls-files', '--eol'))) {
	if ($Line -match '^i/(crlf|mixed)\s.*\t(.+)$') {
		$Violations += "$($Matches[2]): index line endings are i/$($Matches[1]); repository-authored text must be stored as LF."
	}
}

# 2. No tracked text file may contain merge-conflict markers. The '=' separator
#    must be exactly seven characters so setext underlines never match.
$ConflictPattern = '^(<{7} |>{7} )|^={7}$'
$ConflictResult = Invoke-GitRaw -Arguments @('grep', '-I', '-n', '-E', $ConflictPattern, '--', '.')
if ($ConflictResult.ExitCode -eq 0) {
	foreach ($Line in $ConflictResult.Output) {
		$Violations += "${Line}: merge-conflict marker found."
	}
}
elseif ($ConflictResult.ExitCode -ne 1) {
	throw "git grep for conflict markers failed: $($ConflictResult.Output -join [Environment]::NewLine)"
}

# 3. C++ sources under Source/ use tab indentation, never leading spaces.
$SourceFiles = @(Invoke-Git -Arguments @('ls-files', '--', 'Source')) | Where-Object { $_ -match '\.(h|hpp|c|cpp)$' }
foreach ($RelativePath in $SourceFiles) {
	$FullPath = Join-Path $RepositoryRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $FullPath)) {
		continue
	}
	$Lines = @(Get-Content -LiteralPath $FullPath -Encoding UTF8)
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match '^ {4,}[^ ]') {
			$Violations += "${RelativePath}:$($Index + 1): line is indented with spaces; C++ under Source/ uses tab indentation."
		}
	}
}

# 4. Public project files never reference the private AethelnArt plugin (TA-019).
#    Text and hydrated binary assets are scanned. LFS pointer files carry no
#    asset content, so they are counted and reported instead of silently
#    passing. This script is under scripts/ci/, so editing this rule also
#    selects the trusted compile (TA-018).
# ponytail: whole-file ReadAllBytes + Latin-1 string per file; stream in chunks if a single asset nears the 2 GiB array limit.
#    Paths come from NUL-separated git output read as UTF-8, so non-ASCII and
#    quoted paths survive Windows PowerShell's console decoding.
$GitInfo = New-Object System.Diagnostics.ProcessStartInfo 'git', ('-C "{0}" ls-files -z -- Content Config Source Plugins AethelnOnline.uproject' -f $RepositoryRoot)
$GitInfo.UseShellExecute = $false
$GitInfo.RedirectStandardOutput = $true
$GitInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
$GitProcess = [System.Diagnostics.Process]::Start($GitInfo)
$TrackedArtScope = $GitProcess.StandardOutput.ReadToEnd()
$GitProcess.WaitForExit()
if ($GitProcess.ExitCode -ne 0) {
	throw "git ls-files -z for the private art boundary failed with exit code $($GitProcess.ExitCode)."
}
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$ScannedCount = 0
$PointerCount = 0
foreach ($RelativePath in @($TrackedArtScope.Split([char]0) | Where-Object { $_ })) {
	$FullPath = Join-Path $RepositoryRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
		$Violations += "${RelativePath}: tracked file is missing from the work tree; the private art boundary cannot scan it."
		continue
	}
	$Text = $Latin1.GetString([System.IO.File]::ReadAllBytes($FullPath))
	if ($Text.Length -le 1024 -and $Text -cmatch '\Aversion https://git-lfs\.github\.com/spec/v1\n(?:.*\n)*?oid sha256:[0-9a-f]{64}\nsize [0-9]+\n') {
		$PointerCount++
		continue
	}
	$ScannedCount++
	if ($Text -match '(?i)\bAethelnArt\b') {
		$Violations += "${RelativePath}: references the private AethelnArt plugin; public files must not depend on private art."
	}
}
Write-Output "Private art boundary: scanned $ScannedCount tracked files; $PointerCount LFS pointer files not scanned (asset content absent)."

if ($Violations.Count -gt 0) {
	throw "Formatting policy violations:`n$($Violations -join "`n")"
}

Write-Output 'Formatting policy checks passed.'
