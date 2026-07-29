$ErrorActionPreference = 'Stop'

$script:DeliveryAllowedExternalExtensions = @('.json', '.md', '.png', '.ps1', '.svg')
$script:DeliveryUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

if ($null -eq ('AethelnDeliveryVolumeNative' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AethelnDeliveryVolumeNative
{
	[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	public static extern bool GetVolumePathName(
		string fileName,
		StringBuilder volumePathName,
		int bufferLength
	);
}
'@
}

function Get-DeliveryVolumeRoot {
	param([Parameter(Mandatory)][string]$Path)
	if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
		throw '[platform_unsupported] External ingest v1 requires Windows.'
	}
	$Builder = [Text.StringBuilder]::new(1024)
	if (-not [AethelnDeliveryVolumeNative]::GetVolumePathName(
		[IO.Path]::GetFullPath($Path), $Builder, $Builder.Capacity
	)) {
		$Code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
		throw "[volume_lookup_failed] Cannot resolve volume (Win32 $Code)."
	}
	return $Builder.ToString().TrimEnd('\', '/')
}

function Get-DeliverySha256Bytes {
	param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).
			Replace('-', '').ToLowerInvariant()
	}
	finally { $Hasher.Dispose() }
}

function Get-DeliverySha256File {
	param([Parameter(Mandatory)][string]$Path)
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DeliveryRepositoryHeadCommit {
	param([Parameter(Mandatory)][string]$RepositoryRoot)
	$ResolvedRepository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $ResolvedRepository
	$StartInfo.Arguments = 'rev-parse --verify HEAD^{commit}'
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
	$StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
	$StartInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
	$Process = [Diagnostics.Process]::new()
	try {
		$Process.StartInfo = $StartInfo
		if (-not $Process.Start()) {
			throw '[source_commit_unavailable] Could not start Git.'
		}
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		$Output = $OutputTask.GetAwaiter().GetResult().Trim()
		$ErrorText = $ErrorTask.GetAwaiter().GetResult()
		if ($Process.ExitCode -ne 0 -or
			$Output -cnotmatch '^[0-9a-f]{40,64}$') {
			throw (
				'[source_commit_unavailable] Repository HEAD is not a commit: ' +
				$ErrorText.Trim()
			)
		}
		return $Output
	}
	finally {
		$Process.Dispose()
	}
}

function Test-DeliveryPathWithin {
	param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
	$FullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
	$FullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	return $FullPath.Equals($FullRoot, [StringComparison]::OrdinalIgnoreCase) -or
		$FullPath.StartsWith(
			$FullRoot + [IO.Path]::DirectorySeparatorChar,
			[StringComparison]::OrdinalIgnoreCase
		)
}

function Assert-DeliveryNoReparsePath {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$StopRoot,
		[switch]$AllowMissingLeaf
	)
	$FullPath = [IO.Path]::GetFullPath($Path)
	$FullRoot = [IO.Path]::GetFullPath($StopRoot).TrimEnd('\', '/')
	if (-not (Test-DeliveryPathWithin -Path $FullPath -Root $StopRoot)) {
		throw "[path_escape] '$FullPath' is outside '$FullRoot'."
	}
	$Current = $FullPath
	if (-not (Test-Path -LiteralPath $Current)) {
		if (-not $AllowMissingLeaf) { throw "[path_missing] '$Current' does not exist." }
		$Current = [IO.Path]::GetDirectoryName($Current)
	}
	while (-not [string]::IsNullOrWhiteSpace($Current)) {
		if (Test-Path -LiteralPath $Current) {
			$Item = Get-Item -LiteralPath $Current -Force
			if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				throw "[reparse_point] '$($Item.FullName)' is a reparse point."
			}
		}
		$Trimmed = [IO.Path]::GetFullPath($Current).TrimEnd('\', '/')
		if ($Trimmed.Equals($FullRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
		$Parent = [IO.Path]::GetDirectoryName($Trimmed)
		if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $Current) {
			throw "[path_escape] Could not reach '$FullRoot' from '$FullPath'."
		}
		$Current = $Parent
	}
}

function Assert-DeliveryExactProperties {
	param(
		[Parameter(Mandatory)][object]$Value,
		[Parameter(Mandatory)][string[]]$Expected,
		[Parameter(Mandatory)][string]$Name
	)
	if ($Value -isnot [pscustomobject]) { throw "[schema_invalid] $Name must be an object." }
	$Actual = @($Value.PSObject.Properties.Name)
	if ($Actual.Count -ne $Expected.Count) {
		throw "[schema_invalid] $Name has unexpected properties."
	}
	foreach ($Property in $Expected) {
		if ($Actual -cnotcontains $Property) {
			throw "[schema_invalid] $Name is missing '$Property'."
		}
	}
}

function Assert-DeliveryStrictJson {
	param([Parameter(Mandatory)][byte[]]$Bytes)
	if ($Bytes.Length -gt 1048576) {
		throw '[schema_invalid] JSON exceeds the 1 MiB contract ceiling.'
	}
	Add-Type -AssemblyName System.Runtime.Serialization
	$Stream = [IO.MemoryStream]::new($Bytes, $false)
	$Reader = $null
	try {
		$Reader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
			$Stream, [Xml.XmlDictionaryReaderQuotas]::Max
		)
		$Document = [Xml.XmlDocument]::new()
		$Document.Load($Reader)
		function Test-Node([Xml.XmlElement]$Node, [int]$Depth = 0) {
			if ($Depth -gt 16) {
				throw '[schema_invalid] JSON nesting exceeds the contract ceiling.'
			}
			if ($Node.GetAttribute('type') -ceq 'object') {
				$Names = [Collections.Generic.HashSet[string]]::new(
					[StringComparer]::Ordinal
				)
				foreach ($Child in $Node.ChildNodes) {
					if ($Child.NodeType -ne [Xml.XmlNodeType]::Element -or
						-not $Names.Add($Child.LocalName)) {
						throw '[schema_invalid] JSON contains duplicate object keys.'
					}
					Test-Node ([Xml.XmlElement]$Child) ($Depth + 1)
				}
			}
			elseif ($Node.GetAttribute('type') -ceq 'array') {
				foreach ($Child in $Node.ChildNodes) {
					if ($Child.NodeType -eq [Xml.XmlNodeType]::Element) {
						Test-Node ([Xml.XmlElement]$Child) ($Depth + 1)
					}
				}
			}
		}
		Test-Node $Document.DocumentElement
	}
	catch {
		if ($_.Exception.Message.StartsWith(
			'[schema_invalid]', [StringComparison]::Ordinal
		)) {
			throw
		}
		throw '[schema_invalid] JSON is malformed.'
	}
	finally {
		if ($null -ne $Reader) { $Reader.Dispose() }
		$Stream.Dispose()
	}
}

function Read-DeliveryJsonFile {
	param([Parameter(Mandatory)][string]$Path)
	$Resolved = (Resolve-Path -LiteralPath $Path).Path
	$Bytes = [IO.File]::ReadAllBytes($Resolved)
	Assert-DeliveryStrictJson -Bytes $Bytes
	try { $Text = $script:DeliveryUtf8.GetString($Bytes) }
	catch { throw '[schema_invalid] JSON is not valid UTF-8.' }
	if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xfeff) {
		throw '[schema_invalid] UTF-8 BOM is not accepted.'
	}
	try { $Value = $Text | ConvertFrom-Json }
	catch { throw '[schema_invalid] JSON is malformed.' }
	return [pscustomobject]@{
		Path = $Resolved
		Bytes = $Bytes
		Sha256 = Get-DeliverySha256Bytes -Bytes $Bytes
		Value = $Value
	}
}

function ConvertTo-DeliverySealedJsonBytes {
	param([Parameter(Mandatory)][object]$Value)
	$Bytes = $script:DeliveryUtf8.GetBytes(
		($Value | ConvertTo-Json -Depth 20 -Compress)
	)
	Assert-DeliveryStrictJson -Bytes $Bytes
	return ,$Bytes
}

function Write-DeliverySealedJson {
	param(
		[Parameter(Mandatory)][object]$Value,
		[Parameter(Mandatory)][string]$Path,
		[switch]$Atomic
	)
	$FullPath = [IO.Path]::GetFullPath($Path)
	if (Test-Path -LiteralPath $FullPath) { throw "[target_exists] '$FullPath' exists." }
	$Parent = [IO.Path]::GetDirectoryName($FullPath)
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
		throw "[path_missing] Parent '$Parent' does not exist."
	}
	$Bytes = ConvertTo-DeliverySealedJsonBytes -Value $Value
	$WritePath = if ($Atomic) {
		Join-Path $Parent ('.delivery-seal-' + [guid]::NewGuid().ToString('N') + '.tmp')
	}
	else { $FullPath }
	$Stream = [IO.FileStream]::new(
		$WritePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
		[IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough
	)
	try {
		$Stream.Write($Bytes, 0, $Bytes.Length)
		$Stream.Flush($true)
	}
	finally { $Stream.Dispose() }
	if ($Atomic) { [IO.File]::Move($WritePath, $FullPath) }
	$Item = Get-Item -LiteralPath $FullPath -Force
	$Item.IsReadOnly = $true
	return [pscustomobject]@{
		Path = $FullPath
		Sha256 = Get-DeliverySha256File -Path $FullPath
		Bytes = $Bytes
	}
}

function Assert-DeliverySafeRelativePath {
	param(
		[Parameter(Mandatory)][string]$Path,
		[ValidateRange(1, 32767)][int]$MaxLength = 512
	)
	if ([string]::IsNullOrWhiteSpace($Path) -or
		$Path.Length -gt $MaxLength -or
		[IO.Path]::IsPathRooted($Path) -or $Path.Contains('\') -or
		$Path.StartsWith('/') -or $Path.EndsWith('/') -or $Path.Contains('//')) {
		throw "[path_unsafe] '$Path' is not a normalized relative path."
	}
	foreach ($Segment in @($Path.Split('/'))) {
		if ($Segment -in @('.', '..') -or $Segment.EndsWith('.') -or
			$Segment.EndsWith(' ') -or $Segment.IndexOfAny([char[]]'<>:"\|?*') -ge 0 -or
			@($Segment.ToCharArray() | Where-Object { [int]$_ -lt 32 }).Count -gt 0) {
			throw "[path_unsafe] '$Path' contains an unsafe segment."
		}
		$Base = $Segment.Split('.')[0]
		if ($Base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
			throw "[path_unsafe] '$Path' contains a reserved device name."
		}
	}
	return $Path.Normalize([Text.NormalizationForm]::FormC)
}

function Assert-DeliveryExternalRelativePath {
	param([Parameter(Mandatory)][string]$Path)
	$Normalized = Assert-DeliverySafeRelativePath -Path $Path -MaxLength 240
	$Extension = [IO.Path]::GetExtension($Path)
	if ($script:DeliveryAllowedExternalExtensions -cnotcontains $Extension) {
		throw "[extension_unsafe] '$Path' has unsupported extension '$Extension'."
	}
	return $Normalized
}

function Get-DeliveryOrdinalSortedStrings {
	param([Parameter(Mandatory)][string[]]$Value)
	$Copy = [string[]]@($Value)
	[Array]::Sort($Copy, [StringComparer]::Ordinal)
	return $Copy
}

function ConvertTo-DeliveryNonnegativeInt64 {
	param([Parameter(Mandatory)][object]$Value)
	if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and
		$Value -isnot [int16] -and $Value -isnot [uint16] -and
		$Value -isnot [int32] -and $Value -isnot [uint32] -and
		$Value -isnot [int64] -and $Value -isnot [uint64] -and
		$Value -isnot [decimal] -and $Value -isnot [double] -and
		$Value -isnot [single]) {
		throw '[integer_invalid] Value is not a JSON number.'
	}
	try { $Numeric = [decimal]$Value }
	catch { throw '[integer_invalid] Value is outside the decimal range.' }
	if ([decimal]::Truncate($Numeric) -ne $Numeric -or
		$Numeric -lt 0 -or $Numeric -gt [long]::MaxValue) {
		throw '[integer_invalid] Value is outside the nonnegative Int64 range.'
	}
	return [long]$Numeric
}

function Get-DeliveryInventoryHash {
	param([Parameter(Mandatory)][object[]]$Files)
	$ByPath = @{}
	foreach ($File in $Files) { $ByPath[[string]$File.path] = $File }
	$Builder = [Text.StringBuilder]::new()
	foreach ($Path in (Get-DeliveryOrdinalSortedStrings -Value ([string[]]@($ByPath.Keys)))) {
		$File = $ByPath[$Path]
		[void]$Builder.Append($Path).Append([char]0).
			Append(([long]$File.size).ToString([Globalization.CultureInfo]::InvariantCulture)).
			Append([char]0).Append([string]$File.sha256).Append("`n")
	}
	return Get-DeliverySha256Bytes -Bytes $script:DeliveryUtf8.GetBytes($Builder.ToString())
}

function Assert-DeliveryDefaultStreamOnly {
	param([Parameter(Mandatory)][string]$Path)
	try { $Streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop) }
	catch { throw "[stream_check_failed] Cannot enumerate streams for '$Path'." }
	$Named = @($Streams | Where-Object {
		$Name = [string]$_.Stream
		$Name -notin @(':$DATA', '::$DATA')
	})
	if ($Named.Count -gt 0) { throw "[alternate_stream] '$Path' has named data streams." }
}

function Assert-DeliveryRegularFileAttributes {
	param([Parameter(Mandatory)][IO.FileInfo]$File)
	$Allowed = [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::Normal
	$Unexpected = [int]$File.Attributes -band (-bnot [int]$Allowed)
	if ($Unexpected -ne 0) {
		throw "[file_attributes_unsafe] '$($File.FullName)' has unsafe attributes."
	}
}

function Assert-DeliveryInventoryRecords {
	param([Parameter(Mandatory)][object[]]$Files)
	if ($Files.Count -lt 1 -or $Files.Count -gt 128) {
		throw '[inventory_count] Inventory must contain 1 through 128 files.'
	}
	$Collision = [Collections.Generic.HashSet[string]]::new(
		[StringComparer]::OrdinalIgnoreCase
	)
	$Map = @{}
	foreach ($File in $Files) {
		Assert-DeliveryExactProperties $File @('path', 'size', 'sha256') 'inventory file'
		$Path = Assert-DeliveryExternalRelativePath -Path ([string]$File.path)
		try { $Size = ConvertTo-DeliveryNonnegativeInt64 -Value $File.size }
		catch { throw '[inventory_invalid] Inventory record is invalid.' }
		if (-not $Collision.Add($Path) -or
			[string]$File.sha256 -cnotmatch '^[0-9a-f]{64}$') {
			throw '[inventory_invalid] Inventory record is invalid.'
		}
		$Map[$Path] = [pscustomobject][ordered]@{
			path = $Path
			size = $Size
			sha256 = [string]$File.sha256
		}
	}
	return @((Get-DeliveryOrdinalSortedStrings -Value ([string[]]@($Map.Keys))) |
		ForEach-Object { $Map[$_] })
}

function Get-DeliveryExternalInventory {
	param([Parameter(Mandatory)][string]$Root)
	$ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path
	Assert-DeliveryNoReparsePath -Path $ResolvedRoot -StopRoot ([IO.Path]::GetPathRoot($ResolvedRoot))
	Assert-DeliveryDefaultStreamOnly -Path $ResolvedRoot
	foreach ($Entry in @(Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -Force)) {
		if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "[reparse_point] '$($Entry.FullName)' is a reparse point."
		}
		Assert-DeliveryDefaultStreamOnly -Path $Entry.FullName
		if ($Entry.PSIsContainer) { continue }
		if (($Entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
			throw "[file_type_unsafe] '$($Entry.FullName)' is not a regular file."
		}
	}
	$Records = [Collections.Generic.List[object]]::new()
	$Collision = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	foreach ($File in @(Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -Force -File)) {
		$Relative = $File.FullName.Substring($ResolvedRoot.TrimEnd('\').Length + 1).Replace('\', '/')
		$Normalized = Assert-DeliveryExternalRelativePath -Path $Relative
		if (-not $Collision.Add($Normalized)) {
			throw "[path_collision] '$Relative' collides by case or Unicode normalization."
		}
		Assert-DeliveryRegularFileAttributes -File $File
		$Records.Add([pscustomobject][ordered]@{
			path = $Normalized
			size = [long]$File.Length
			sha256 = Get-DeliverySha256File -Path $File.FullName
		})
	}
	if ($Records.Count -lt 1 -or $Records.Count -gt 128) {
		throw '[inventory_count] External inventory must contain 1 through 128 files.'
	}
	$Map = @{}
	foreach ($Record in $Records) { $Map[$Record.path] = $Record }
	$SortedRecords = @((Get-DeliveryOrdinalSortedStrings -Value ([string[]]@($Map.Keys))) |
		ForEach-Object { $Map[$_] })
	$ExpectedDirectories = [Collections.Generic.HashSet[string]]::new(
		[StringComparer]::OrdinalIgnoreCase
	)
	foreach ($Record in $SortedRecords) {
		$Segments = @(([string]$Record.path).Split('/'))
		for ($Index = 1; $Index -lt $Segments.Count; $Index++) {
			$null = $ExpectedDirectories.Add(($Segments[0..($Index - 1)] -join '/'))
		}
	}
	$ActualDirectories = [Collections.Generic.HashSet[string]]::new(
		[StringComparer]::OrdinalIgnoreCase
	)
	foreach ($Directory in @(Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -Force -Directory)) {
		$Relative = $Directory.FullName.Substring(
			$ResolvedRoot.TrimEnd('\').Length + 1
		).Replace('\', '/')
		$NormalizedPlaceholder = Assert-DeliveryExternalRelativePath `
			-Path ($Relative + '/placeholder.md')
		$NormalizedDirectory = $NormalizedPlaceholder.Substring(
			0, $NormalizedPlaceholder.Length - '/placeholder.md'.Length
		)
		if (-not $ActualDirectories.Add($NormalizedDirectory)) {
			throw '[path_collision] Directory paths collide by case or Unicode normalization.'
		}
	}
	if ($ActualDirectories.Count -ne $ExpectedDirectories.Count) {
		throw '[directory_inventory_mismatch] External directory inventory differs.'
	}
	foreach ($Directory in $ExpectedDirectories) {
		if (-not $ActualDirectories.Contains($Directory)) {
			throw "[directory_inventory_mismatch] Missing directory '$Directory'."
		}
	}
	return $SortedRecords
}

function Assert-DeliveryInventoryEqual {
	param(
		[Parameter(Mandatory)][object[]]$Expected,
		[Parameter(Mandatory)][object[]]$Actual
	)
	if ($Expected.Count -ne $Actual.Count) { throw '[inventory_mismatch] File count differs.' }
	$ActualMap = @{}
	foreach ($File in $Actual) { $ActualMap[[string]$File.path] = $File }
	foreach ($File in $Expected) {
		if (-not $ActualMap.ContainsKey([string]$File.path)) {
			throw "[inventory_mismatch] Missing '$($File.path)'."
		}
		$Other = $ActualMap[[string]$File.path]
		if ([long]$Other.size -ne [long]$File.size -or
			[string]$Other.sha256 -cne [string]$File.sha256) {
			throw "[inventory_mismatch] Bytes differ for '$($File.path)'."
		}
	}
}

function Read-DeliveryExternalManifest {
	param([Parameter(Mandatory)][string]$Path)
	$Read = Read-DeliveryJsonFile -Path $Path
	$Manifest = $Read.Value
	Assert-DeliveryExactProperties $Manifest @('format', 'target_root', 'files') 'manifest'
	if ($Manifest.format -cne 'delivery_external_file_bundle_v1' -or
		$Manifest.target_root -cne 'visuals' -or
		$Manifest.files -isnot [Array] -or
		@($Manifest.files).Count -lt 1 -or @($Manifest.files).Count -gt 128) {
		throw '[schema_invalid] External manifest contract is invalid.'
	}
	$Records = [Collections.Generic.List[object]]::new()
	$Collision = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	foreach ($File in @($Manifest.files)) {
		Assert-DeliveryExactProperties $File @('path', 'operation', 'size', 'sha256') 'file'
		$PathValue = Assert-DeliveryExternalRelativePath -Path ([string]$File.path)
		if (-not $Collision.Add($PathValue)) { throw '[path_collision] Manifest paths collide.' }
		try { $Size = ConvertTo-DeliveryNonnegativeInt64 -Value $File.size }
		catch { throw '[schema_invalid] External manifest file record is invalid.' }
		if ($File.operation -cne 'create' -or
			[string]$File.sha256 -cnotmatch '^[0-9a-f]{64}$') {
			throw '[schema_invalid] External manifest file record is invalid.'
		}
		$Records.Add([pscustomobject][ordered]@{
			path = $PathValue
			size = $Size
			sha256 = [string]$File.sha256
		})
	}
	$Map = @{}; foreach ($Record in $Records) { $Map[$Record.path] = $Record }
	$SortedRecords = @((Get-DeliveryOrdinalSortedStrings -Value ([string[]]@($Map.Keys))) |
		ForEach-Object { $Map[$_] })
	$Read | Add-Member -NotePropertyName Records -NotePropertyValue $SortedRecords
	return $Read
}

function New-DeliveryIngestEvidenceValue {
	param(
		[Parameter(Mandatory)][string]$SourceCommit,
		[Parameter(Mandatory)][string]$DestinationRoot,
		[Parameter(Mandatory)][string]$ExternalManifestSha256,
		[Parameter(Mandatory)][string]$JournalSha256,
		[Parameter(Mandatory)][object[]]$Files
	)
	$Changed = @($Files | ForEach-Object { 'visuals/' + [string]$_.path })
	return [ordered]@{
		format = 'delivery_external_file_ingest_evidence_v1'
		disposition = 'accepted'
		source_commit = $SourceCommit
		target_root = 'visuals'
		destination_root = [IO.Path]::GetFullPath($DestinationRoot)
		external_manifest_sha256 = $ExternalManifestSha256
		prepared_journal_sha256 = $JournalSha256
		final_inventory_sha256 = Get-DeliveryInventoryHash -Files $Files
		changed_paths = @(Get-DeliveryOrdinalSortedStrings -Value ([string[]]$Changed))
		files = @($Files)
	}
}

function Test-DeliveryAcceptedIngestEvidence {
	param(
		[Parameter(Mandatory)][string]$EvidenceManifestPath,
		[Parameter(Mandatory)][string]$ExpectedEvidenceManifestSha256,
		[Parameter(Mandatory)][string]$ExternalManifestPath,
		[Parameter(Mandatory)][string]$ExpectedExternalManifestSha256,
		[Parameter(Mandatory)][string]$PreparedJournalPath,
		[Parameter(Mandatory)][string]$ExpectedPreparedJournalSha256,
		[Parameter(Mandatory)][string]$ExpectedSourceCommit,
		[Parameter(Mandatory)][string]$RepositoryRoot
	)
	$EvidenceFullPath = [IO.Path]::GetFullPath($EvidenceManifestPath)
	if (Test-DeliveryPathWithin -Path $EvidenceFullPath -Root $RepositoryRoot) {
		throw '[evidence_invalid] Ingest evidence must remain outside repository.'
	}
	Assert-DeliveryNoReparsePath -Path $EvidenceFullPath `
		-StopRoot ([IO.Path]::GetPathRoot($EvidenceFullPath))
	$Item = Get-Item -LiteralPath $EvidenceManifestPath -Force
	if (-not $Item.IsReadOnly) { throw '[evidence_unsealed] Ingest evidence is not read-only.' }
	$Read = Read-DeliveryJsonFile -Path $EvidenceManifestPath
	if ($Read.Sha256 -cne $ExpectedEvidenceManifestSha256) {
		throw '[evidence_tampered] Ingest evidence hash differs.'
	}

	$JournalFullPath = [IO.Path]::GetFullPath($PreparedJournalPath)
	if (Test-DeliveryPathWithin -Path $JournalFullPath -Root $RepositoryRoot) {
		throw '[journal_invalid] Prepared journal must remain outside repository.'
	}
	Assert-DeliveryNoReparsePath -Path $JournalFullPath `
		-StopRoot ([IO.Path]::GetPathRoot($JournalFullPath))
	$JournalItem = Get-Item -LiteralPath $PreparedJournalPath -Force
	if (-not $JournalItem.IsReadOnly) {
		throw '[journal_unsealed] Prepared journal is not read-only.'
	}
	$JournalRead = Read-DeliveryJsonFile -Path $PreparedJournalPath
	if ($JournalRead.Sha256 -cne $ExpectedPreparedJournalSha256) {
		throw '[journal_tampered] Prepared journal hash differs.'
	}
	$Journal = $JournalRead.Value
	Assert-DeliveryExactProperties $Journal @(
		'format','state','source_commit','repository_root','source_root','staging_root',
		'staged_payload_root','target_root','destination_root','external_manifest_sha256',
		'expected_inventory_sha256','files'
	) 'prepared journal'
	if ($Journal.format -cne 'delivery_external_file_ingest_journal_v1' -or
		$Journal.state -cne 'prepared' -or
		$Journal.source_commit -cne $ExpectedSourceCommit -or
		$Journal.target_root -cne 'visuals' -or
		[string]$Journal.external_manifest_sha256 -cne
			$ExpectedExternalManifestSha256 -or
		[string]$Journal.expected_inventory_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$Journal.files -isnot [Array]) {
		throw '[journal_invalid] Prepared journal contract differs.'
	}
	$Repository = [IO.Path]::GetFullPath($RepositoryRoot)
	if (-not ([IO.Path]::GetFullPath([string]$Journal.repository_root)).Equals(
		$Repository, [StringComparison]::OrdinalIgnoreCase)) {
		throw '[journal_invalid] Prepared journal repository differs.'
	}
	$SourceRoot = [IO.Path]::GetFullPath([string]$Journal.source_root)
	$StagingRoot = [IO.Path]::GetFullPath([string]$Journal.staging_root)
	$StagedPayloadRoot = [IO.Path]::GetFullPath(
		[string]$Journal.staged_payload_root
	)
	$ExpectedDestination = [IO.Path]::GetFullPath(
		(Join-Path $Repository 'visuals')
	)
	if (-not [IO.Path]::GetFileName($SourceRoot.TrimEnd('\', '/')).Equals(
			'visuals', [StringComparison]::OrdinalIgnoreCase) -or
		(Test-DeliveryPathWithin -Path $SourceRoot -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $Repository -Root $SourceRoot) -or
		(Test-DeliveryPathWithin -Path $StagingRoot -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $StagingRoot -Root $SourceRoot) -or
		(Test-DeliveryPathWithin -Path $SourceRoot -Root $StagingRoot) -or
		-not (Test-DeliveryPathWithin -Path $StagedPayloadRoot -Root $StagingRoot) -or
		-not ([IO.Path]::GetFullPath([string]$Journal.destination_root).Equals(
			$ExpectedDestination, [StringComparison]::OrdinalIgnoreCase)) -or
		-not (Get-DeliveryVolumeRoot $Repository).Equals(
			(Get-DeliveryVolumeRoot $StagingRoot),
			[StringComparison]::OrdinalIgnoreCase)) {
		throw '[journal_invalid] Prepared journal path topology differs.'
	}
	if ((Test-DeliveryPathWithin -Path $JournalFullPath -Root $SourceRoot) -or
		(Test-DeliveryPathWithin -Path $JournalFullPath -Root $StagingRoot) -or
		(Test-DeliveryPathWithin -Path $EvidenceFullPath -Root $SourceRoot) -or
		(Test-DeliveryPathWithin -Path $EvidenceFullPath -Root $StagingRoot)) {
		throw '[journal_invalid] Prepared journal location differs.'
	}

	$ExternalFullPath = [IO.Path]::GetFullPath($ExternalManifestPath)
	if ((Test-DeliveryPathWithin -Path $ExternalFullPath -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $ExternalFullPath -Root $SourceRoot) -or
		(Test-DeliveryPathWithin -Path $ExternalFullPath -Root $StagingRoot)) {
		throw '[manifest_invalid] External manifest location differs.'
	}
	Assert-DeliveryNoReparsePath -Path $ExternalFullPath `
		-StopRoot ([IO.Path]::GetPathRoot($ExternalFullPath))
	$ExternalItem = Get-Item -LiteralPath $ExternalManifestPath -Force
	if (-not $ExternalItem.IsReadOnly) {
		throw '[manifest_unsealed] External manifest is not read-only.'
	}
	$ExternalRead = Read-DeliveryExternalManifest -Path $ExternalManifestPath
	if ($ExternalRead.Sha256 -cne $ExpectedExternalManifestSha256) {
		throw '[manifest_tampered] External manifest hash differs.'
	}
	$JournalFiles = Assert-DeliveryInventoryRecords -Files @($Journal.files)
	Assert-DeliveryInventoryEqual -Expected $ExternalRead.Records -Actual $JournalFiles
	if ((Get-DeliveryInventoryHash -Files $JournalFiles) -cne
		[string]$Journal.expected_inventory_sha256) {
		throw '[journal_invalid] Prepared journal inventory hash differs.'
	}

	$Value = $Read.Value
	Assert-DeliveryExactProperties $Value @(
		'format','disposition','source_commit','target_root','destination_root',
		'external_manifest_sha256','prepared_journal_sha256','final_inventory_sha256',
		'changed_paths','files'
	) 'ingest evidence'
	if ($Value.format -cne 'delivery_external_file_ingest_evidence_v1' -or
		$Value.disposition -cne 'accepted' -or
		$Value.source_commit -cne $ExpectedSourceCommit -or
		$Value.target_root -cne 'visuals' -or
		[string]$Value.external_manifest_sha256 -cne
			$ExpectedExternalManifestSha256 -or
		[string]$Value.prepared_journal_sha256 -cne
			$ExpectedPreparedJournalSha256 -or
		[string]$Value.final_inventory_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$Value.changed_paths -isnot [Array] -or $Value.files -isnot [Array]) {
		throw '[evidence_invalid] Ingest evidence contract differs.'
	}
	if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $RepositoryRoot) -cne
		$ExpectedSourceCommit) {
		throw '[evidence_invalid] Repository HEAD differs from ingest evidence.'
	}
	if (-not ([IO.Path]::GetFullPath([string]$Value.destination_root)).Equals(
		$ExpectedDestination, [StringComparison]::OrdinalIgnoreCase)) {
		throw '[evidence_invalid] Ingest evidence destination differs.'
	}
	$Files = @($Value.files)
	$Files = Assert-DeliveryInventoryRecords -Files $Files
	Assert-DeliveryInventoryEqual -Expected $ExternalRead.Records -Actual $Files
	Assert-DeliveryInventoryEqual -Expected $JournalFiles -Actual $Files
	$ExpectedChanged = @(Get-DeliveryOrdinalSortedStrings -Value ([string[]]@(
		$Files | ForEach-Object { 'visuals/' + $_.path }
	)))
	$ActualChanged = @($Value.changed_paths)
	if ($ActualChanged.Count -ne $ExpectedChanged.Count) {
		throw '[evidence_invalid] Ingest evidence changed paths differ.'
	}
	for ($Index = 0; $Index -lt $ExpectedChanged.Count; $Index++) {
		if ([string]$ActualChanged[$Index] -cne $ExpectedChanged[$Index]) {
			throw '[evidence_invalid] Ingest evidence changed paths differ.'
		}
	}
	$Actual = Get-DeliveryExternalInventory -Root $ExpectedDestination
	Assert-DeliveryInventoryEqual -Expected $Files -Actual $Actual
	if ((Get-DeliveryInventoryHash -Files $Actual) -cne [string]$Value.final_inventory_sha256) {
		throw '[evidence_invalid] Destination inventory hash differs.'
	}
	return $Read
}

function Invoke-DeliveryIngestFault {
	param([scriptblock]$FaultInjector, [string]$Checkpoint, [object]$Context)
	if ($null -ne $FaultInjector) { & $FaultInjector $Checkpoint $Context }
}
