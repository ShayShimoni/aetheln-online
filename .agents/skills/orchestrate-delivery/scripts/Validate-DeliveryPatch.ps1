[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$PatchPath,

	[Parameter(Mandatory)]
	[string]$WorkspaceRoot,

	[Parameter(Mandatory)]
	[string[]]$AllowedPaths
)

$ErrorActionPreference = 'Stop'
$PatchPath = (Resolve-Path -LiteralPath $PatchPath).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

function Assert-AllowedPathsSafe {
	param(
		[Parameter(Mandatory)]
		[string[]]$Paths
	)

	foreach ($AllowedPath in $Paths) {
		$Allowed = $AllowedPath.Replace('\', '/').TrimEnd('/')
		if ([string]::IsNullOrWhiteSpace($Allowed) -or
			[System.IO.Path]::IsPathRooted($AllowedPath) -or
			$Allowed.StartsWith('/') -or
			(@($Allowed -split '/') -contains '..')) {
			throw "Allowed path '$AllowedPath' is unsafe."
		}

		$ScopeSegments = @($Allowed -split '/')
		foreach ($Segment in $ScopeSegments) {
			if (($Segment.Contains('*') -and $Segment -notin @('*', '**')) -or
				$Segment.IndexOfAny([char[]]'?[]') -ge 0) {
				throw "Allowed path '$AllowedPath' contains an unsupported wildcard."
			}
		}
	}
}

function Test-RelativePathAllowed {
	param(
		[Parameter(Mandatory)]
		[string]$RelativePath,

		[Parameter(Mandatory)]
		[string[]]$AllowedPaths
	)

	$Normalized = $RelativePath.Replace('\', '/')
	$PathSegments = @($Normalized -split '/')
	foreach ($AllowedPath in $AllowedPaths) {
		$Allowed = $AllowedPath.Replace('\', '/').TrimEnd('/')
		$ScopeSegments = @($Allowed -split '/')
		$HasWildcard = @($ScopeSegments | Where-Object { $_ -in @('*', '**') }).Count -gt 0
		if (-not $HasWildcard) {
			if ($Normalized.Equals($Allowed, [System.StringComparison]::OrdinalIgnoreCase) -or
				$Normalized.StartsWith(
					$Allowed + '/',
					[System.StringComparison]::OrdinalIgnoreCase
				)) {
				return $true
			}
			continue
		}

		$Memo = @{}
		function Test-SegmentMatch {
			param([int]$PathIndex, [int]$ScopeIndex)

			$Key = "$PathIndex,$ScopeIndex"
			if ($Memo.ContainsKey($Key)) {
				return $Memo[$Key]
			}

			$Result = $false
			if ($ScopeIndex -eq $ScopeSegments.Count) {
				$Result = $PathIndex -eq $PathSegments.Count
			}
			elseif ($ScopeSegments[$ScopeIndex] -eq '**') {
				$Result = (Test-SegmentMatch $PathIndex ($ScopeIndex + 1)) -or
					($PathIndex -lt $PathSegments.Count -and
						(Test-SegmentMatch ($PathIndex + 1) $ScopeIndex))
			}
			elseif ($PathIndex -lt $PathSegments.Count -and
				($ScopeSegments[$ScopeIndex] -eq '*' -or
					$PathSegments[$PathIndex].Equals(
						$ScopeSegments[$ScopeIndex],
						[System.StringComparison]::OrdinalIgnoreCase
					))) {
				$Result = Test-SegmentMatch ($PathIndex + 1) ($ScopeIndex + 1)
			}

			$Memo[$Key] = $Result
			return $Result
		}

		if (Test-SegmentMatch 0 0) {
			return $true
		}
	}

	return $false
}

function Invoke-GitNumstatRaw {
	param(
		[Parameter(Mandatory)]
		[string]$RepositoryRoot,

		[Parameter(Mandatory)]
		[string]$CandidatePatchPath
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = 'git'
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.Arguments = 'apply --recount --numstat -z -- "' +
		$CandidatePatchPath.Replace('"', '\"') + '"'
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		[void]$Process.Start()
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		if ($Process.ExitCode -ne 0) {
			throw "Candidate artifact is not a valid Git patch: $StandardError"
		}

		return ,$Output.ToArray()
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}
}

Assert-AllowedPathsSafe -Paths $AllowedPaths

foreach ($PatchLine in [System.IO.File]::ReadLines($PatchPath)) {
	if ($PatchLine -cmatch '^(?:rename|copy) (?:from|to) ') {
		throw (
			'Candidate patch uses rename or copy metadata. Use delete and add patches instead.'
		)
	}
}

try {
	$NumstatBytes = Invoke-GitNumstatRaw `
		-RepositoryRoot $WorkspaceRoot `
		-CandidatePatchPath $PatchPath
	$NumstatText = [System.Text.UTF8Encoding]::new($false, $true).GetString(
		$NumstatBytes
	)
}
catch {
	throw "Could not parse candidate patch paths: $($_.Exception.Message)"
}

$ProposedPaths = @()
$NumstatRecords = $NumstatText.Split([char]0)
for ($RecordIndex = 0; $RecordIndex -lt $NumstatRecords.Count - 1; $RecordIndex++) {
	$Columns = $NumstatRecords[$RecordIndex] -split "`t", 3
	if ($Columns.Count -ne 3) {
		throw "Could not parse candidate patch path record."
	}

	$RecordPaths = @($Columns[2])
	if ([string]::IsNullOrEmpty($Columns[2])) {
		if ($RecordIndex + 2 -ge $NumstatRecords.Count) {
			throw 'Could not parse candidate rename or copy endpoints.'
		}

		$RecordPaths = @(
			$NumstatRecords[++$RecordIndex],
			$NumstatRecords[++$RecordIndex]
		)
	}

	foreach ($ProposedPath in $RecordPaths) {
		if ([string]::IsNullOrEmpty($ProposedPath) -or
			[System.IO.Path]::IsPathRooted($ProposedPath) -or
			($ProposedPath -split '[\\/]') -contains '..' -or
			$ProposedPath.IndexOfAny([char[]]'*?[]') -ge 0) {
			throw "Candidate patch path '$ProposedPath' is unsafe."
		}

		if (-not (Test-RelativePathAllowed `
				-RelativePath $ProposedPath `
				-AllowedPaths $AllowedPaths)) {
			throw "Candidate patch path '$ProposedPath' is outside allowed paths."
		}

		$ProposedPaths += $ProposedPath
	}
}

$PreviousErrorActionPreference = $ErrorActionPreference
try {
	$ErrorActionPreference = 'Continue'
	$PatchCheck = @(& git -C $WorkspaceRoot apply --recount --check -- $PatchPath 2>&1)
	$PatchCheckExitCode = $LASTEXITCODE
}
finally {
	$ErrorActionPreference = $PreviousErrorActionPreference
}
if ($PatchCheckExitCode -ne 0) {
	throw "Candidate patch does not apply cleanly: $($PatchCheck -join ' ')"
}

[pscustomobject]@{
	ProposedPaths = [string[]]$ProposedPaths
}
