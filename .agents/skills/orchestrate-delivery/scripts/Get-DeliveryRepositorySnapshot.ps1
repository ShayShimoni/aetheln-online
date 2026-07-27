[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$ReparseCheckScript = Join-Path $PSScriptRoot 'Assert-DeliveryPathNoReparse.ps1'
$PathSplitScript = Join-Path $PSScriptRoot 'Split-DeliveryGitPathList.ps1'
$SensitivePathScript = Join-Path $PSScriptRoot 'Test-DeliverySensitivePath.ps1'

function Test-PathWithin {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Root
	)

	$NormalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
	$NormalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	return $NormalizedPath.Equals(
		$NormalizedRoot,
		[System.StringComparison]::OrdinalIgnoreCase
	) -or $NormalizedPath.StartsWith(
		$NormalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
		[System.StringComparison]::OrdinalIgnoreCase
	)
}

$GitCommand = (Get-Command git -ErrorAction Stop).Source
$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $GitCommand
$StartInfo.WorkingDirectory = $RepositoryRoot
$StartInfo.UseShellExecute = $false
$StartInfo.CreateNoWindow = $true
$StartInfo.RedirectStandardOutput = $true
$StartInfo.RedirectStandardError = $true
$StartInfo.Arguments = (
	'-c core.quotepath=false ls-files --cached --others ' +
	'--exclude-standard -z'
)
$Process = [System.Diagnostics.Process]::new()
$Process.StartInfo = $StartInfo
$OutputBytes = [System.IO.MemoryStream]::new()
try {
	if (-not $Process.Start()) {
		throw 'Could not start Git repository inventory.'
	}
	$Process.StandardOutput.BaseStream.CopyTo($OutputBytes)
	$StandardError = $Process.StandardError.ReadToEnd()
	$Process.WaitForExit()
	$ExitCode = $Process.ExitCode
}
finally {
	$Process.Dispose()
}
if ($ExitCode -ne 0) {
	throw "Could not enumerate repository paths for '$RepositoryRoot': $StandardError"
}
$RawPaths = [System.Text.Encoding]::UTF8.GetString($OutputBytes.ToArray())
$OutputBytes.Dispose()
$Paths = @(& $PathSplitScript -RawPaths $RawPaths)

$Snapshot = @{}
foreach ($RelativePath in @($Paths | Sort-Object -Unique)) {
	$RelativePath = [string]$RelativePath
	$FullPath = [System.IO.Path]::GetFullPath(
		(Join-Path $RepositoryRoot $RelativePath)
	)
	if (-not (Test-PathWithin -Path $FullPath -Root $RepositoryRoot)) {
		continue
	}

	if (Test-Path -LiteralPath $FullPath) {
		& $ReparseCheckScript -Path $FullPath -Root $RepositoryRoot
	}
	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
		continue
	}

	$Item = Get-Item -LiteralPath $FullPath -Force
	$Sensitive = & $SensitivePathScript -RelativePath $RelativePath
	if ($Sensitive) {
		throw (
			'Stage launch refused because the repository contains a tracked ' +
			'or non-ignored sensitive path. Move it outside the repository or ' +
			'ignore it before orchestration.'
		)
	}

	$ContentHash = (
		Get-FileHash -LiteralPath $FullPath -Algorithm SHA256
	).Hash.ToLowerInvariant()
	$AttributeFingerprint = ([int64]$Item.Attributes).ToString()
	$Snapshot[$RelativePath] = "$ContentHash|attributes=$AttributeFingerprint"
}

$Canonical = @(
	$Snapshot.Keys |
		Sort-Object |
		ForEach-Object { "$_=$($Snapshot[$_])" }
) -join "`n"
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Canonical)
$Hasher = [System.Security.Cryptography.SHA256]::Create()
try {
	$SnapshotHash = [System.BitConverter]::ToString(
		$Hasher.ComputeHash($Bytes)
	).Replace('-', '').ToLowerInvariant()
}
finally {
	$Hasher.Dispose()
}

[pscustomobject]@{
	Hash = $SnapshotHash
	Files = $Snapshot
}
