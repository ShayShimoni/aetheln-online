Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PinnedPreparationYamlPath {
	param([string] $Path, [switch] $Directory)
	if (-not [IO.Path]::IsPathRooted($Path)) { throw 'preparation_yaml_path_invalid' }
	$Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
	if ($null -eq $Item -or $Item.PSIsContainer -ne [bool] $Directory) { throw 'preparation_yaml_path_invalid' }
	$Current = $Item
	while ($null -ne $Current) {
		if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'preparation_yaml_path_invalid' }
		$Current = if ($Current -is [IO.FileInfo]) { $Current.Directory } else { $Current.Parent }
	}
}

function Read-PinnedPreparationYamlBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the exact verified assembly byte stream without loading it.')]
	param([Parameter(Mandatory)][string] $PackagePath)
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$Archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
	try {
		$Entries = @($Archive.Entries | Where-Object { $_.FullName -ceq 'lib/net47/YamlDotNet.dll' })
		if ($Entries.Count -ne 1 -or $Entries[0].Length -ne 288256) { throw 'preparation_yaml_assembly_invalid' }
		$AssemblyStream = $Entries[0].Open()
		try {
			$Bytes = [byte[]]::new(288256)
			$Offset = 0
			while ($Offset -lt $Bytes.Length) {
				$Read = $AssemblyStream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
				if ($Read -eq 0) { throw 'preparation_yaml_assembly_invalid' }
				$Offset += $Read
			}
			if ($AssemblyStream.ReadByte() -ne -1) { throw 'preparation_yaml_assembly_invalid' }
		} finally { $AssemblyStream.Dispose() }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Hash = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		if ($Hash -cne 'd35c770d92632bd94bba4203db05eee5ebce6e6ea6d92e7ebe8997a942b5321c') { throw 'preparation_yaml_assembly_invalid' }
		return ,$Bytes
	} finally { $Archive.Dispose() }
}

function Get-PinnedPreparationYaml {
	[CmdletBinding()]
	param([string] $PackagePath, [string] $CacheRoot = [IO.Path]::GetTempPath())
	# Acquisition is confined to unprivileged portable tests. Admission's existing
	# Initialize-PreparationYaml remains offline and independently checks the DLL.
	Assert-PinnedPreparationYamlPath -Path $CacheRoot -Directory
	$Cache = Join-Path $CacheRoot ('AethelnPinnedYaml-' + [guid]::NewGuid().ToString('N'))
	[void] (New-Item -ItemType Directory -Path $Cache)
	if (-not $PackagePath) {
		$PackagePath = Join-Path $Cache 'powershell-yaml.0.4.12.nupkg'
		Add-Type -AssemblyName System.Net.Http
		$Client = [Net.Http.HttpClient]::new()
		try {
			$Client.Timeout = [TimeSpan]::FromSeconds(60)
			$Client.MaxResponseContentBufferSize = 327106
			$PackageBytes = $Client.GetByteArrayAsync('https://www.powershellgallery.com/api/v2/package/powershell-yaml/0.4.12').GetAwaiter().GetResult()
		} finally { $Client.Dispose() }
		$Output = [IO.File]::Open($PackagePath, [IO.FileMode]::CreateNew)
		try { $Output.Write($PackageBytes, 0, $PackageBytes.Length) } finally { $Output.Dispose() }
	}
	Assert-PinnedPreparationYamlPath -Path $PackagePath
	$PackageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
	if ((Get-Item -LiteralPath $PackagePath).Length -ne 327106 -or
		$PackageHash -cne 'd4602bc7a4a093766520422d53ca8b09acde162286fae11e2ee6c8edfea07810') { throw 'preparation_yaml_package_invalid' }
	$AssemblyBytes = Read-PinnedPreparationYamlBytes -PackagePath $PackagePath
	$AssemblyPath = Join-Path $Cache 'YamlDotNet.dll'
	$Output = [IO.File]::Open($AssemblyPath, [IO.FileMode]::CreateNew)
	try { $Output.Write($AssemblyBytes, 0, $AssemblyBytes.Length) } finally { $Output.Dispose() }
	Assert-PinnedPreparationYamlPath -Path $AssemblyPath
	$AssemblyHash = (Get-FileHash -LiteralPath $AssemblyPath -Algorithm SHA256).Hash.ToLowerInvariant()
	if ((Get-Item -LiteralPath $AssemblyPath).Length -ne 288256 -or
		$AssemblyHash -cne 'd35c770d92632bd94bba4203db05eee5ebce6e6ea6d92e7ebe8997a942b5321c') { throw 'preparation_yaml_assembly_invalid' }
	return [pscustomobject]@{ PackagePath = [IO.Path]::GetFullPath($PackagePath); PackageSha256 = $PackageHash; AssemblyPath = $AssemblyPath; AssemblySha256 = $AssemblyHash }
}
