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
$SensitivePathScript = Join-Path $PSScriptRoot 'Test-DeliverySensitivePath.ps1'
$ReparseCheckScript = Join-Path $PSScriptRoot 'Assert-DeliveryPathNoReparse.ps1'

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
	$StartInfo.Arguments = '-c core.autocrlf=false apply --numstat -z -- "' +
		$CandidatePatchPath.Replace('"', '\"') + '"'
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'

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
			throw (
				'[patch_malformed] Candidate artifact is not a valid Git patch: ' +
				$StandardError
			)
		}

		return ,$Output.ToArray()
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}
}

function ConvertTo-DeliveryAttributePattern {
	param(
		[Parameter(Mandatory)]
		[string]$RelativePath
	)

	$Escaped = $RelativePath.Replace('\', '\\').Replace('"', '\"')
	$Escaped = $Escaped.Replace("`t", '\t').Replace("`n", '\n').Replace("`r", '\r')
	return '"' + $Escaped + '"'
}

function Invoke-IsolatedGit {
	param(
		[Parameter(Mandatory)]
		[string]$WorkingDirectory,

		[Parameter(Mandatory)]
		[string]$Arguments
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $WorkingDirectory
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
	$StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
	$StartInfo.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) {
			throw 'Could not start isolated Git.'
		}
		$StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
		$StandardErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		$StandardOutput = $StandardOutputTask.GetAwaiter().GetResult()
		$StandardError = $StandardErrorTask.GetAwaiter().GetResult()
		return [pscustomobject]@{
			ExitCode = $Process.ExitCode
			StandardOutput = $StandardOutput
			StandardError = $StandardError
		}
	}
	finally {
		$Process.Dispose()
	}
}

Assert-AllowedPathsSafe -Paths $AllowedPaths

foreach ($PatchLine in [System.IO.File]::ReadLines($PatchPath)) {
	if ($PatchLine -cmatch '^(?:rename|copy) (?:from|to) ') {
		throw (
			'[patch_path_unsupported] Candidate patch uses rename or copy metadata. ' +
			'Use delete and add patches instead.'
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
			throw "[patch_path_unsafe] Candidate patch path '$ProposedPath' is unsafe."
		}

		if (& $SensitivePathScript -RelativePath $ProposedPath) {
			throw (
				"[patch_path_sensitive] Candidate patch path '$ProposedPath' is " +
				'sensitive.'
			)
		}

		if (-not (Test-RelativePathAllowed `
				-RelativePath $ProposedPath `
				-AllowedPaths $AllowedPaths)) {
			throw (
				"[patch_out_of_scope] Candidate patch path '$ProposedPath' is " +
				'outside allowed paths.'
			)
		}

		$ProposedPaths += $ProposedPath
	}
}

$UniquePaths = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
foreach ($ProposedPath in $ProposedPaths) {
	if (-not $UniquePaths.Add($ProposedPath)) {
		throw "[patch_path_unsafe] Candidate patch path '$ProposedPath' is duplicated."
	}
}

$SystemTempRoot = [System.IO.Path]::GetFullPath(
	[System.IO.Path]::GetTempPath()
).TrimEnd('\', '/')
$ValidationRoot = Join-Path $SystemTempRoot (
	'aetheln-delivery-check-' + [guid]::NewGuid().ToString('N')
)
try {
	New-Item -ItemType Directory -Path $ValidationRoot | Out-Null
	$GitInit = Invoke-IsolatedGit `
		-WorkingDirectory $ValidationRoot `
		-Arguments 'init --quiet'
	if ($GitInit.ExitCode -ne 0) {
		throw (
			'[patch_nonapplying] Could not initialize isolated validation: ' +
			$GitInit.StandardError
		)
	}

	$AttributeLines = foreach ($ProposedPath in $ProposedPaths) {
		(
			(ConvertTo-DeliveryAttributePattern -RelativePath $ProposedPath) +
			' -text -crlf !eol -filter -ident -working-tree-encoding'
		)
	}
	$AttributePath = Join-Path $ValidationRoot '.git\info\attributes'
	[System.IO.File]::WriteAllText(
		$AttributePath,
		(($AttributeLines -join "`n") + "`n"),
		[System.Text.UTF8Encoding]::new($false)
	)

	foreach ($ProposedPath in $ProposedPaths) {
		$SourcePath = [System.IO.Path]::GetFullPath(
			(Join-Path $WorkspaceRoot $ProposedPath)
		)
		& $ReparseCheckScript -Path $SourcePath -Root $WorkspaceRoot
		if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
			continue
		}

		$ValidationPath = Join-Path $ValidationRoot $ProposedPath
		$ValidationParent = [System.IO.Path]::GetDirectoryName($ValidationPath)
		if (-not (Test-Path -LiteralPath $ValidationParent)) {
			New-Item -ItemType Directory -Path $ValidationParent | Out-Null
		}
		[System.IO.File]::WriteAllBytes(
			$ValidationPath,
			[System.IO.File]::ReadAllBytes($SourcePath)
		)
	}

	$PatchCheck = Invoke-IsolatedGit `
		-WorkingDirectory $ValidationRoot `
		-Arguments (
			'-c core.autocrlf=false apply --binary --check -- "' +
			$PatchPath.Replace('"', '\"') + '"'
		)
	if ($PatchCheck.ExitCode -ne 0) {
		throw (
			'[patch_nonapplying] Candidate patch does not apply cleanly: ' +
			$PatchCheck.StandardError
		)
	}
}
finally {
	$ResolvedValidationRoot = [System.IO.Path]::GetFullPath(
		$ValidationRoot
	).TrimEnd('\', '/')
	if ((Test-Path -LiteralPath $ResolvedValidationRoot) -and
		$ResolvedValidationRoot.StartsWith(
			$SystemTempRoot + [System.IO.Path]::DirectorySeparatorChar,
			[System.StringComparison]::OrdinalIgnoreCase
		)) {
		[System.IO.Directory]::Delete($ResolvedValidationRoot, $true)
	}
}

[pscustomobject]@{
	ProposedPaths = [string[]]$ProposedPaths
}
