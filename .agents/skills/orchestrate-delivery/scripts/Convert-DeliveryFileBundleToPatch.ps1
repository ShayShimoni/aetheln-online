[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[object]$Bundle,

	[Parameter(Mandatory)]
	[string]$WorkspaceRoot,

	[Parameter(Mandatory)]
	[string[]]$AllowedPaths,

	[Parameter(Mandatory)]
	[string[]]$DeclaredPaths,

	[Parameter(Mandatory)]
	[hashtable]$SnapshotFiles,

	[Parameter(Mandatory)]
	[string]$PatchPath
)

$ErrorActionPreference = 'Stop'
$MaximumFileCount = 128
$MaximumDecodedBytes = 16MB
$ExpectedBundleProperties = @('format', 'files')
$ExpectedFileProperties = @(
	'path',
	'operation',
	'base_sha256',
	'encoding',
	'content'
)
$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
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

function Assert-ClosedObject {
	param(
		[Parameter(Mandatory)]
		[object]$Value,

		[Parameter(Mandatory)]
		[string[]]$ExpectedProperties,

		[Parameter(Mandatory)]
		[string]$Description
	)

	if ($Value -isnot [System.Management.Automation.PSCustomObject]) {
		throw "[bundle_invalid] $Description must be a JSON object."
	}

	$ActualProperties = [string[]]@($Value.PSObject.Properties.Name)
	if ($ActualProperties.Count -ne $ExpectedProperties.Count) {
		throw "[bundle_invalid] $Description must contain only the required properties."
	}

	foreach ($PropertyName in $ExpectedProperties) {
		if ($ActualProperties -cnotcontains $PropertyName) {
			throw "[bundle_invalid] $Description is missing exact property '$PropertyName'."
		}
	}
}

function Assert-AllowedPathsSafe {
	param(
		[Parameter(Mandatory)]
		[string[]]$Paths
	)

	foreach ($AllowedPath in $Paths) {
		if ($AllowedPath -isnot [string]) {
			throw '[bundle_path_unsafe] Allowed paths must be strings.'
		}

		$Allowed = $AllowedPath.Replace('\', '/').TrimEnd('/')
		if ([string]::IsNullOrWhiteSpace($Allowed) -or
			[System.IO.Path]::IsPathRooted($AllowedPath) -or
			$Allowed.StartsWith('/') -or
			(@($Allowed -split '/') -contains '..')) {
			throw "[bundle_path_unsafe] Allowed path '$AllowedPath' is unsafe."
		}

		$ScopeSegments = @($Allowed -split '/')
		foreach ($Segment in $ScopeSegments) {
			if ([string]::IsNullOrEmpty($Segment) -or
				$Segment -eq '.' -or
				($Segment.Contains('*') -and $Segment -notin @('*', '**')) -or
				$Segment.IndexOfAny([char[]]'?[]') -ge 0) {
				throw "[bundle_path_unsafe] Allowed path '$AllowedPath' contains an unsupported segment."
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
		$HasWildcard = @(
			$ScopeSegments | Where-Object { $_ -in @('*', '**') }
		).Count -gt 0
		if (-not $HasWildcard) {
			if ($Normalized.Equals(
					$Allowed,
					[System.StringComparison]::OrdinalIgnoreCase
				) -or $Normalized.StartsWith(
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

function ConvertTo-SafeRelativePath {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Description
	)

	$Normalized = $Path.Replace('\', '/')
	if ([string]::IsNullOrWhiteSpace($Normalized) -or
		[System.IO.Path]::IsPathRooted($Path) -or
		$Normalized.StartsWith('/') -or
		$Normalized.EndsWith('/')) {
		throw "[bundle_path_unsafe] $Description '$Path' is not a safe relative file path."
	}

	$Segments = @($Normalized -split '/')
	foreach ($Segment in $Segments) {
		if ([string]::IsNullOrEmpty($Segment) -or
			$Segment -in @('.', '..') -or
			-not $Segment.Equals(
				$Segment.Trim(),
				[System.StringComparison]::Ordinal
			) -or
			$Segment.IndexOfAny([char[]]'*?[]') -ge 0 -or
			$Segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
			throw "[bundle_path_unsafe] $Description '$Path' contains an unsafe path segment."
		}

		foreach ($Character in $Segment.ToCharArray()) {
			if ([char]::IsControl($Character)) {
				throw "[bundle_path_unsafe] $Description '$Path' contains a control character."
			}
		}
	}

	return $Normalized
}

function Assert-NoReparsePointWithinWorkspace {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Root
	)

	$CurrentPath = [System.IO.Path]::GetFullPath($Path)
	$NormalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	while (-not (Test-Path -LiteralPath $CurrentPath)) {
		if ($CurrentPath.TrimEnd('\', '/').Equals(
				$NormalizedRoot,
				[System.StringComparison]::OrdinalIgnoreCase
			)) {
			break
		}

		$ParentPath = Split-Path -Parent $CurrentPath
		if ([string]::IsNullOrWhiteSpace($ParentPath) -or
			$ParentPath.Equals(
				$CurrentPath,
				[System.StringComparison]::OrdinalIgnoreCase
			)) {
			throw "[bundle_path_unsafe] Path '$Path' could not be resolved within the workspace."
		}
		$CurrentPath = $ParentPath
	}

	$Current = Get-Item -LiteralPath $CurrentPath -Force
	while ($null -ne $Current) {
		if (($Current.Attributes -band
				[System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "[bundle_path_unsafe] Path '$Path' traverses reparse point '$($Current.FullName)'."
		}

		if ($Current.FullName.TrimEnd('\', '/').Equals(
				$NormalizedRoot,
				[System.StringComparison]::OrdinalIgnoreCase
			)) {
			return
		}
		$Current = if ($Current -is [System.IO.FileInfo]) {
			$Current.Directory
		}
		else {
			$Current.Parent
		}
	}

	throw "[bundle_path_unsafe] Path '$Path' is not rooted in the workspace."
}

function Assert-NoReparsePoint {
	param(
		[Parameter(Mandatory)]
		[string]$Path
	)

	$Current = Get-Item -LiteralPath $Path -Force
	while ($null -ne $Current) {
		if (($Current.Attributes -band
				[System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "[bundle_path_unsafe] Path '$Path' traverses reparse point '$($Current.FullName)'."
		}
		$Current = $Current.Parent
	}
}

function ConvertFrom-StrictContent {
	param(
		[Parameter(Mandatory)]
		[string]$Encoding,

		[Parameter(Mandatory)]
		[string]$Content,

		[Parameter(Mandatory)]
		[string]$Path
	)

	try {
		if ($Encoding -ceq 'utf8') {
			[byte[]]$Bytes = $StrictUtf8.GetBytes($Content)
			if ($Bytes.Length -ge 3 -and
				$Bytes[0] -eq 0xEF -and
				$Bytes[1] -eq 0xBB -and
				$Bytes[2] -eq 0xBF) {
				throw 'UTF-8 byte-order marks are not allowed.'
			}
			return ,$Bytes
		}

		if ($Encoding -ceq 'base64') {
			if ($Content -cnotmatch (
					'^(?:[A-Za-z0-9+/]{4})*' +
					'(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'
				)) {
				throw 'Base64 must use canonical alphabet and padding without whitespace.'
			}
			return ,([System.Convert]::FromBase64String($Content))
		}
	}
	catch {
		throw "[bundle_invalid] Bundle content for '$Path' is not valid $Encoding content."
	}

	throw "[bundle_invalid] Bundle file '$Path' uses unsupported encoding '$Encoding'."
}

function Get-StreamSha256 {
	param(
		[Parameter(Mandatory)]
		[System.IO.Stream]$Stream
	)

	$Stream.Position = 0
	$Sha256 = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Hash = $Sha256.ComputeHash($Stream)
	}
	finally {
		$Sha256.Dispose()
		$Stream.Position = 0
	}

	return ([System.BitConverter]::ToString($Hash)).Replace('-', '').ToLowerInvariant()
}

function Invoke-GitBytes {
	param(
		[Parameter(Mandatory)]
		[string]$RepositoryRoot,

		[Parameter(Mandatory)]
		[string]$Arguments,

		[System.IO.Stream]$InputStream
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.RedirectStandardInput = $null -ne $InputStream

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}

		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		if ($null -ne $InputStream) {
			$InputStream.Position = 0
			$InputStream.CopyTo($Process.StandardInput.BaseStream)
			$Process.StandardInput.Close()
		}
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
		$Result = $Output.ToArray()
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}

	if ($ExitCode -ne 0) {
		throw "Git command '$Arguments' failed: $StandardError"
	}

	return ,$Result
}

function Invoke-GitText {
	param(
		[Parameter(Mandatory)]
		[string]$RepositoryRoot,

		[Parameter(Mandatory)]
		[string]$Arguments,

		[System.IO.Stream]$InputStream
	)

	$Bytes = Invoke-GitBytes `
		-RepositoryRoot $RepositoryRoot `
		-Arguments $Arguments `
		-InputStream $InputStream
	return $StrictUtf8.GetString($Bytes)
}

function Get-GitObjectId {
	param(
		[Parameter(Mandatory)]
		[string]$RepositoryRoot,

		[Parameter(Mandatory)]
		[System.IO.Stream]$ContentStream
	)

	$ObjectId = (
		Invoke-GitText `
			-RepositoryRoot $RepositoryRoot `
			-Arguments 'hash-object -w --stdin' `
			-InputStream $ContentStream
	).Trim()
	if ($ObjectId -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
		throw 'Git returned an invalid object identifier.'
	}

	return $ObjectId
}

function Set-GitIndexEntries {
	param(
		[Parameter(Mandatory)]
		[string]$RepositoryRoot,

		[Parameter(Mandatory)]
		[object[]]$Entries
	)

	$IndexInformation = [System.IO.MemoryStream]::new()
	try {
		foreach ($Entry in $Entries) {
			$Record = "100644 $($Entry.ObjectId)`t$($Entry.Path)" + [char]0
			$RecordBytes = $StrictUtf8.GetBytes($Record)
			$IndexInformation.Write($RecordBytes, 0, $RecordBytes.Length)
		}
		$IndexInformation.Position = 0
		$null = Invoke-GitBytes `
			-RepositoryRoot $RepositoryRoot `
			-Arguments 'update-index -z --index-info' `
			-InputStream $IndexInformation
	}
	finally {
		$IndexInformation.Dispose()
	}
}

$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$WorkspaceItem = Get-Item -LiteralPath $WorkspaceRoot -Force
if (-not $WorkspaceItem.PSIsContainer -or
	($WorkspaceItem.Attributes -band
		[System.IO.FileAttributes]::ReparsePoint) -ne 0) {
	throw "[bundle_path_unsafe] Workspace root '$WorkspaceRoot' must be a regular directory."
}

$PatchParentInput = Split-Path -Parent ([System.IO.Path]::GetFullPath($PatchPath))
if ([string]::IsNullOrWhiteSpace($PatchParentInput) -or
	-not (Test-Path -LiteralPath $PatchParentInput -PathType Container)) {
	throw "[bundle_path_unsafe] Patch parent directory '$PatchParentInput' does not exist."
}
$PatchParent = (Resolve-Path -LiteralPath $PatchParentInput).Path
Assert-NoReparsePoint -Path $PatchParent
$PatchPath = [System.IO.Path]::GetFullPath(
	(Join-Path $PatchParent (Split-Path -Leaf $PatchPath))
)
if (Test-PathWithin -Path $PatchPath -Root $WorkspaceRoot) {
	throw "[bundle_path_unsafe] Patch path '$PatchPath' must be outside the workspace."
}
if (Test-Path -LiteralPath $PatchPath) {
	throw "[bundle_path_unsafe] Patch path '$PatchPath' already exists."
}

Assert-AllowedPathsSafe -Paths $AllowedPaths
Assert-ClosedObject `
	-Value $Bundle `
	-ExpectedProperties $ExpectedBundleProperties `
	-Description 'Bundle'
if ($Bundle.format -isnot [string] -or
	[string]$Bundle.format -cne 'delivery_file_bundle_v1') {
	throw "[bundle_invalid] Bundle format must be 'delivery_file_bundle_v1'."
}
if ($Bundle.files -isnot [System.Array]) {
	throw '[bundle_invalid] Bundle files must be a JSON array.'
}

$Files = [object[]]@($Bundle.files)
if ($Files.Count -lt 1 -or $Files.Count -gt $MaximumFileCount) {
	throw "[bundle_invalid] Bundle must contain between 1 and $MaximumFileCount files."
}

$Records = @()
$ProposedPaths = @()
$SeenPaths = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::OrdinalIgnoreCase
)
$TotalDecodedBytes = [long]0
for ($FileIndex = 0; $FileIndex -lt $Files.Count; $FileIndex++) {
	$File = $Files[$FileIndex]
	Assert-ClosedObject `
		-Value $File `
		-ExpectedProperties $ExpectedFileProperties `
		-Description "Bundle file at index $FileIndex"

	if ($File.path -isnot [string]) {
		throw "[bundle_path_unsafe] Bundle file at index $FileIndex path must be a string."
	}
	$RelativePath = ConvertTo-SafeRelativePath `
		-Path ([string]$File.path) `
		-Description 'Bundle file path'
	if (& $SensitivePathScript -RelativePath $RelativePath) {
		throw (
			"[bundle_path_sensitive] Bundle file path '$RelativePath' is " +
			'sensitive.'
		)
	}
	if (-not $SeenPaths.Add($RelativePath)) {
		throw "[bundle_path_unsafe] Bundle file path '$RelativePath' is duplicated."
	}
	if (-not (Test-RelativePathAllowed `
			-RelativePath $RelativePath `
			-AllowedPaths $AllowedPaths)) {
		throw "[bundle_out_of_scope] Bundle file path '$RelativePath' is outside allowed paths."
	}

	if ($File.operation -isnot [string] -or
		[string]$File.operation -cnotin @('create', 'replace')) {
		throw "[bundle_invalid] Bundle file '$RelativePath' uses an unsupported operation."
	}
	$Operation = [string]$File.operation
	if ($File.encoding -isnot [string] -or
		[string]$File.encoding -cnotin @('utf8', 'base64')) {
		throw "[bundle_invalid] Bundle file '$RelativePath' uses an unsupported encoding."
	}
	if ($File.content -isnot [string]) {
		throw "[bundle_invalid] Bundle file '$RelativePath' content must be a string."
	}

	if ($Operation -ceq 'create') {
		if ($null -ne $File.base_sha256) {
			throw "[bundle_invalid] Create file '$RelativePath' must use null base_sha256."
		}
		if ($SnapshotFiles.ContainsKey($RelativePath)) {
			throw "[bundle_stale] Create file '$RelativePath' existed in the source snapshot."
		}
	}
	else {
		if ($File.base_sha256 -isnot [string] -or
			[string]$File.base_sha256 -notmatch '^[0-9a-f]{64}$') {
			throw "[bundle_invalid] Replace file '$RelativePath' requires a SHA-256 base hash."
		}
		if (-not $SnapshotFiles.ContainsKey($RelativePath)) {
			throw "[bundle_stale] Replace file '$RelativePath' was not present in the source snapshot."
		}
		$SnapshotFingerprint = [string]$SnapshotFiles[$RelativePath]
		$SnapshotFingerprintMatch = [regex]::Match(
			$SnapshotFingerprint,
			'^([0-9a-f]{64})\|attributes=-?[0-9]+$'
		)
		if (-not $SnapshotFingerprintMatch.Success) {
			throw "[bundle_invalid] Source snapshot entry for '$RelativePath' is invalid."
		}
		if (-not $SnapshotFingerprintMatch.Groups[1].Value.Equals(
				[string]$File.base_sha256,
				[System.StringComparison]::Ordinal
			)) {
			throw "[bundle_stale] Replace file '$RelativePath' does not match the source snapshot."
		}
	}

	$FullPath = [System.IO.Path]::GetFullPath(
		(Join-Path $WorkspaceRoot $RelativePath)
	)
	if (-not (Test-PathWithin -Path $FullPath -Root $WorkspaceRoot) -or
		$FullPath.TrimEnd('\', '/').Equals(
			$WorkspaceRoot.TrimEnd('\', '/'),
			[System.StringComparison]::OrdinalIgnoreCase
		)) {
		throw "[bundle_path_unsafe] Bundle file path '$RelativePath' escapes the workspace."
	}
	Assert-NoReparsePointWithinWorkspace `
		-Path $FullPath `
		-Root $WorkspaceRoot

	[byte[]]$ContentBytes = ConvertFrom-StrictContent `
		-Encoding ([string]$File.encoding) `
		-Content ([string]$File.content) `
		-Path $RelativePath
	$TotalDecodedBytes += $ContentBytes.LongLength
	if ($TotalDecodedBytes -gt $MaximumDecodedBytes) {
		throw "[bundle_invalid] Bundle decoded content exceeds $MaximumDecodedBytes bytes."
	}

	if ($Operation -ceq 'create') {
		if (Test-Path -LiteralPath $FullPath) {
			throw "[bundle_stale] Create file '$RelativePath' already exists."
		}
	}
	else {
		$CandidateStream = [System.IO.MemoryStream]::new($ContentBytes, $false)
		try {
			$CandidateSha256 = Get-StreamSha256 -Stream $CandidateStream
		}
		finally {
			$CandidateStream.Dispose()
		}
		if ($CandidateSha256.Equals(
				[string]$File.base_sha256,
				[System.StringComparison]::Ordinal
			)) {
			throw "[bundle_empty] Replace file '$RelativePath' does not change content."
		}
		if (-not [System.IO.File]::Exists($FullPath)) {
			throw "[bundle_stale] Replace file '$RelativePath' must be an existing regular file."
		}
		$SourceItem = Get-Item -LiteralPath $FullPath -Force
		if ($SourceItem.PSIsContainer -or
			($SourceItem.Attributes -band
				[System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "[bundle_path_unsafe] Replace file '$RelativePath' must be an existing regular non-reparse file."
		}
	}

	$Records += [pscustomobject]@{
		Path = $RelativePath
		FullPath = $FullPath
		Operation = $Operation
		BaseSha256 = $File.base_sha256
		Encoding = [string]$File.encoding
		Bytes = $ContentBytes
		SourceStream = $null
	}
	$ProposedPaths += $RelativePath
}

$DeclaredNormalized = @()
$SeenDeclaredPaths = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::OrdinalIgnoreCase
)
foreach ($DeclaredPath in $DeclaredPaths) {
	if ($DeclaredPath -isnot [string]) {
		throw '[bundle_path_unsafe] Declared changed paths must be strings.'
	}
	$NormalizedDeclaredPath = ConvertTo-SafeRelativePath `
		-Path $DeclaredPath `
		-Description 'Declared changed path'
	if (-not $SeenDeclaredPaths.Add($NormalizedDeclaredPath)) {
		throw "[bundle_path_unsafe] Declared changed path '$NormalizedDeclaredPath' is duplicated."
	}
	$DeclaredNormalized += $NormalizedDeclaredPath
}

if ($DeclaredNormalized.Count -ne $ProposedPaths.Count) {
	throw '[bundle_invalid] Declared changed paths must exactly match bundle file paths.'
}
foreach ($ProposedPath in $ProposedPaths) {
	if (-not $SeenDeclaredPaths.Contains($ProposedPath)) {
		throw '[bundle_invalid] Declared changed paths must exactly match bundle file paths.'
	}
}

$TemporaryRoot = [System.IO.Path]::GetFullPath(
	(Join-Path ([System.IO.Path]::GetTempPath()) (
		'aetheln-delivery-bundle-' + [guid]::NewGuid().ToString('N')
	))
)
if (Test-PathWithin -Path $TemporaryRoot -Root $WorkspaceRoot) {
	throw "[bundle_path_unsafe] System temporary path '$TemporaryRoot' must be outside the workspace."
}

$TemporaryRootCreated = $false
try {
	foreach ($Record in $Records) {
		if ($Record.Operation -cne 'replace') {
			continue
		}

		Assert-NoReparsePointWithinWorkspace `
			-Path $Record.FullPath `
			-Root $WorkspaceRoot
		$Record.SourceStream = [System.IO.FileStream]::new(
			$Record.FullPath,
			[System.IO.FileMode]::Open,
			[System.IO.FileAccess]::Read,
			[System.IO.FileShare]::Read
		)
		$ActualBaseSha256 = Get-StreamSha256 -Stream $Record.SourceStream
		if (-not $ActualBaseSha256.Equals(
				[string]$Record.BaseSha256,
				[System.StringComparison]::OrdinalIgnoreCase
			)) {
			throw "[bundle_stale] Replace file '$($Record.Path)' base_sha256 is stale."
		}
	}

	[void][System.IO.Directory]::CreateDirectory($TemporaryRoot)
	$TemporaryRootCreated = $true
	Assert-NoReparsePoint -Path $TemporaryRoot
	$null = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments 'init --quiet --template= -- .'
	$null = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments 'config core.autocrlf false'
	$null = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments 'config core.safecrlf false'
	$BinaryAttributeLines = @(
		$Records |
			Where-Object { $_.Encoding -ceq 'base64' } |
			ForEach-Object {
				$EscapedAttributePath = $_.Path.Replace('\', '\\').Replace('"', '\"')
				"`"$EscapedAttributePath`" binary"
			}
	)
	if ($BinaryAttributeLines.Count -gt 0) {
		$AttributesPath = Join-Path $TemporaryRoot '.git\info\attributes'
		[void][System.IO.Directory]::CreateDirectory(
			(Split-Path -Parent $AttributesPath)
		)
		[System.IO.File]::WriteAllLines(
			$AttributesPath,
			[string[]]$BinaryAttributeLines,
			[System.Text.UTF8Encoding]::new($false)
		)
	}
	$null = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments 'read-tree --empty'

	$BaselineEntries = @()
	foreach ($Record in $Records) {
		if ($Record.Operation -cne 'replace') {
			continue
		}
		$ObjectId = Get-GitObjectId `
			-RepositoryRoot $TemporaryRoot `
			-ContentStream $Record.SourceStream
		$BaselineEntries += [pscustomobject]@{
			Path = $Record.Path
			ObjectId = $ObjectId
		}
	}
	if ($BaselineEntries.Count -gt 0) {
		Set-GitIndexEntries `
			-RepositoryRoot $TemporaryRoot `
			-Entries $BaselineEntries
	}

	$BaselineTree = (
		Invoke-GitText `
			-RepositoryRoot $TemporaryRoot `
			-Arguments 'write-tree'
	).Trim()
	if ($BaselineTree -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
		throw 'Git returned an invalid baseline tree identifier.'
	}

	$null = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments 'read-tree --empty'
	$CandidateEntries = @()
	foreach ($Record in $Records) {
		$CandidateStream = [System.IO.MemoryStream]::new(
			[byte[]]$Record.Bytes,
			$false
		)
		try {
			$ObjectId = Get-GitObjectId `
				-RepositoryRoot $TemporaryRoot `
				-ContentStream $CandidateStream
		}
		finally {
			$CandidateStream.Dispose()
		}
		$CandidateEntries += [pscustomobject]@{
			Path = $Record.Path
			ObjectId = $ObjectId
		}
	}
	Set-GitIndexEntries `
		-RepositoryRoot $TemporaryRoot `
		-Entries $CandidateEntries

	$PatchBytes = Invoke-GitBytes `
		-RepositoryRoot $TemporaryRoot `
		-Arguments (
			'diff --cached --binary --full-index --no-ext-diff ' +
			"$BaselineTree --"
		)
	if ($PatchBytes.Length -eq 0) {
		throw '[bundle_empty] Bundle produced an empty patch.'
	}

	$PatchStream = [System.IO.FileStream]::new(
		$PatchPath,
		[System.IO.FileMode]::CreateNew,
		[System.IO.FileAccess]::Write,
		[System.IO.FileShare]::None
	)
	try {
		$PatchStream.Write($PatchBytes, 0, $PatchBytes.Length)
		$PatchStream.Flush($true)
	}
	finally {
		$PatchStream.Dispose()
	}
}
finally {
	foreach ($Record in $Records) {
		if ($null -ne $Record.SourceStream) {
			$Record.SourceStream.Dispose()
			$Record.SourceStream = $null
		}
	}

	if ($TemporaryRootCreated -and
		[System.IO.Directory]::Exists($TemporaryRoot)) {
		$ResolvedTemporaryRoot = (Resolve-Path -LiteralPath $TemporaryRoot).Path
		$ResolvedSystemTempRoot = [System.IO.Path]::GetFullPath(
			[System.IO.Path]::GetTempPath()
		).TrimEnd('\', '/')
		$TemporaryRootName = Split-Path -Leaf $ResolvedTemporaryRoot

		if (-not (Test-PathWithin `
				-Path $ResolvedTemporaryRoot `
				-Root $ResolvedSystemTempRoot) -or
			-not $TemporaryRootName.Equals(
				(Split-Path -Leaf $TemporaryRoot),
				[System.StringComparison]::Ordinal
			) -or
			$TemporaryRootName -cnotmatch
				'^aetheln-delivery-bundle-[0-9a-f]{32}$') {
			throw (
				"Refusing to remove unsafe bundle temporary directory " +
				"'$ResolvedTemporaryRoot'."
			)
		}

		Assert-NoReparsePoint -Path $ResolvedTemporaryRoot
		Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
	}
}

[pscustomobject]@{
	Format = 'delivery_file_bundle_v1'
	FileCount = $Records.Count
	ProposedPaths = [string[]]$ProposedPaths
}
