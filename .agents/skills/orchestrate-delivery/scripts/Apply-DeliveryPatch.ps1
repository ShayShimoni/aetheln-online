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
$ValidationScript = Join-Path $PSScriptRoot 'Validate-DeliveryPatch.ps1'
$ReparseCheckScript = Join-Path $PSScriptRoot 'Assert-DeliveryPathNoReparse.ps1'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Test-DeliveryByteArrayEqual {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Left,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Right
	)

	if ($Left.Length -ne $Right.Length) {
		return $false
	}

	for ($Index = 0; $Index -lt $Left.Length; $Index++) {
		if ($Left[$Index] -ne $Right[$Index]) {
			return $false
		}
	}

	return $true
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
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
	$StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
	$StartInfo.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'
	$StartInfo.Arguments = $Arguments

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
		if ($Process.ExitCode -ne 0) {
			throw (
				"[patch_application_failed] Isolated Git failed: $StandardError"
			)
		}
		return $StandardOutput
	}
	finally {
		$Process.Dispose()
	}
}

$PatchHashBeforeValidation = (
	Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$Validation = & $ValidationScript `
	-PatchPath $PatchPath `
	-WorkspaceRoot $WorkspaceRoot `
	-AllowedPaths $AllowedPaths
$PatchHashBeforeMaterialization = (
	Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256
).Hash.ToLowerInvariant()

if ($PatchHashBeforeValidation -cne $PatchHashBeforeMaterialization) {
	throw '[patch_tampered] Candidate patch changed after validation.'
}

$PatchText = [System.IO.File]::ReadAllText($PatchPath, $Utf8NoBom)
if ($PatchText -cmatch '(?m)^(?:deleted file mode|rename |copy )' -or
	$PatchText -cmatch '(?m)^\+\+\+ /dev/null\s*$') {
	throw (
		'[patch_path_unsupported] Governed application supports only create and ' +
		'replace operations.'
	)
}

$ProposedPaths = [string[]]@($Validation.ProposedPaths)
if ($ProposedPaths.Count -eq 0) {
	throw '[patch_empty] Candidate patch has no proposed paths.'
}
$UniquePaths = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
foreach ($RelativePath in $ProposedPaths) {
	if (-not $UniquePaths.Add($RelativePath)) {
		throw "[patch_path_unsafe] Candidate patch path '$RelativePath' is duplicated."
	}
}

$Baselines = [ordered]@{}
foreach ($RelativePath in $ProposedPaths) {
	$DestinationPath = [System.IO.Path]::GetFullPath(
		(Join-Path $WorkspaceRoot $RelativePath)
	)
	& $ReparseCheckScript -Path $DestinationPath -Root $WorkspaceRoot
	$Exists = Test-Path -LiteralPath $DestinationPath -PathType Leaf
	$Bytes = if ($Exists) {
		[System.IO.File]::ReadAllBytes($DestinationPath)
	}
	else {
		[byte[]]@()
	}
	$Baselines[$RelativePath] = [pscustomobject]@{
		DestinationPath = $DestinationPath
		Exists = $Exists
		Bytes = $Bytes
	}
}

$SystemTempRoot = [System.IO.Path]::GetFullPath(
	[System.IO.Path]::GetTempPath()
).TrimEnd('\', '/')
$MaterializationRoot = Join-Path $SystemTempRoot (
	'aetheln-delivery-apply-' + [guid]::NewGuid().ToString('N')
)
$StagedWrites = [System.Collections.Generic.List[object]]::new()
$CommittedWrites = [System.Collections.Generic.List[object]]::new()

try {
	New-Item -ItemType Directory -Path $MaterializationRoot | Out-Null
	$null = Invoke-IsolatedGit `
		-WorkingDirectory $MaterializationRoot `
		-Arguments 'init --quiet'

	$AttributeLines = foreach ($RelativePath in $ProposedPaths) {
		(
			(ConvertTo-DeliveryAttributePattern -RelativePath $RelativePath) +
			' -text -crlf !eol -filter -ident -working-tree-encoding'
		)
	}
	$AttributePath = Join-Path $MaterializationRoot '.git\info\attributes'
	[System.IO.File]::WriteAllText(
		$AttributePath,
		(($AttributeLines -join "`n") + "`n"),
		$Utf8NoBom
	)

	foreach ($RelativePath in $ProposedPaths) {
		$Baseline = $Baselines[$RelativePath]
		if (-not $Baseline.Exists) {
			continue
		}

		$MaterializedPath = Join-Path $MaterializationRoot $RelativePath
		$MaterializedParent = [System.IO.Path]::GetDirectoryName($MaterializedPath)
		if (-not (Test-Path -LiteralPath $MaterializedParent)) {
			New-Item -ItemType Directory -Path $MaterializedParent | Out-Null
		}
		[System.IO.File]::WriteAllBytes($MaterializedPath, $Baseline.Bytes)
	}

	$null = Invoke-IsolatedGit `
		-WorkingDirectory $MaterializationRoot `
		-Arguments (
			'-c core.autocrlf=false apply --binary -- "' +
			$PatchPath.Replace('"', '\"') + '"'
		)

	$PatchHashAfterMaterialization = (
		Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256
	).Hash.ToLowerInvariant()
	if ($PatchHashBeforeMaterialization -cne $PatchHashAfterMaterialization) {
		throw '[patch_tampered] Candidate patch changed during materialization.'
	}

	foreach ($RelativePath in $ProposedPaths) {
		$MaterializedPath = Join-Path $MaterializationRoot $RelativePath
		& $ReparseCheckScript -Path $MaterializedPath -Root $MaterializationRoot
		if (-not (Test-Path -LiteralPath $MaterializedPath -PathType Leaf)) {
			throw (
				"[patch_path_unsupported] Candidate result '$RelativePath' is not a file."
			)
		}

		$Baseline = $Baselines[$RelativePath]
		$DestinationPath = $Baseline.DestinationPath
		& $ReparseCheckScript -Path $DestinationPath -Root $WorkspaceRoot
		$StillExists = Test-Path -LiteralPath $DestinationPath -PathType Leaf
		if ($StillExists -ne $Baseline.Exists) {
			throw (
				"[patch_stale] Destination '$RelativePath' changed before application."
			)
		}
		if ($StillExists) {
			$CurrentBytes = [System.IO.File]::ReadAllBytes($DestinationPath)
			if (-not (Test-DeliveryByteArrayEqual `
					-Left $CurrentBytes `
					-Right $Baseline.Bytes)) {
				throw (
					"[patch_stale] Destination '$RelativePath' changed before application."
				)
			}
		}

		$DestinationParent = [System.IO.Path]::GetDirectoryName($DestinationPath)
		if (-not (Test-Path -LiteralPath $DestinationParent)) {
			New-Item -ItemType Directory -Path $DestinationParent | Out-Null
		}
		& $ReparseCheckScript -Path $DestinationParent -Root $WorkspaceRoot

		$ResultBytes = [System.IO.File]::ReadAllBytes($MaterializedPath)
		$StagedPath = Join-Path $DestinationParent (
			'.delivery-stage-' + [guid]::NewGuid().ToString('N') + '.tmp'
		)
		[System.IO.File]::WriteAllBytes($StagedPath, $ResultBytes)
		if (-not (Test-DeliveryByteArrayEqual `
				-Left ([System.IO.File]::ReadAllBytes($StagedPath)) `
				-Right $ResultBytes)) {
			throw "[patch_application_failed] Could not stage exact bytes for '$RelativePath'."
		}

		$StagedWrites.Add([pscustomobject]@{
			RelativePath = $RelativePath
			DestinationPath = $DestinationPath
			StagedPath = $StagedPath
			BackupPath = $StagedPath + '.backup'
			Existed = $Baseline.Exists
			ResultBytes = $ResultBytes
		})
	}

	foreach ($Write in $StagedWrites) {
		& $ReparseCheckScript -Path $Write.DestinationPath -Root $WorkspaceRoot
		if ($Write.Existed) {
			[System.IO.File]::Replace(
				$Write.StagedPath,
				$Write.DestinationPath,
				$Write.BackupPath,
				$true
			)
		}
		else {
			[System.IO.File]::Move($Write.StagedPath, $Write.DestinationPath)
		}
		$CommittedWrites.Add($Write)
	}

	foreach ($Write in $CommittedWrites) {
		& $ReparseCheckScript -Path $Write.DestinationPath -Root $WorkspaceRoot
		$AppliedBytes = [System.IO.File]::ReadAllBytes($Write.DestinationPath)
		if (-not (Test-DeliveryByteArrayEqual `
				-Left $AppliedBytes `
				-Right $Write.ResultBytes)) {
			throw (
				"[patch_application_failed] Applied bytes for '$($Write.RelativePath)' " +
				'do not match the validated result.'
			)
		}
	}
}
catch {
	for ($Index = $CommittedWrites.Count - 1; $Index -ge 0; $Index--) {
		$Write = $CommittedWrites[$Index]
		try {
			if ($Write.Existed -and (Test-Path -LiteralPath $Write.BackupPath)) {
				[System.IO.File]::Replace(
					$Write.BackupPath,
					$Write.DestinationPath,
					$null,
					$true
				)
			}
			elseif (-not $Write.Existed -and
				(Test-Path -LiteralPath $Write.DestinationPath)) {
				[System.IO.File]::Delete($Write.DestinationPath)
			}
		}
		catch {
			throw (
				'[patch_rollback_failed] Application failed and exact rollback also ' +
				"failed for '$($Write.RelativePath)'."
			)
		}
	}
	throw
}
finally {
	foreach ($Write in $StagedWrites) {
		foreach ($TemporaryPath in @($Write.StagedPath, $Write.BackupPath)) {
			if (Test-Path -LiteralPath $TemporaryPath) {
				[System.IO.File]::Delete($TemporaryPath)
			}
		}
	}
	$ResolvedMaterializationRoot = [System.IO.Path]::GetFullPath(
		$MaterializationRoot
	).TrimEnd('\', '/')
	if ((Test-Path -LiteralPath $ResolvedMaterializationRoot) -and
		$ResolvedMaterializationRoot.StartsWith(
			$SystemTempRoot + [System.IO.Path]::DirectorySeparatorChar,
			[System.StringComparison]::OrdinalIgnoreCase
		)) {
		[System.IO.Directory]::Delete($ResolvedMaterializationRoot, $true)
	}
}

[pscustomobject]@{
	PatchHash = $PatchHashBeforeMaterialization
	ProposedPaths = $ProposedPaths
}
