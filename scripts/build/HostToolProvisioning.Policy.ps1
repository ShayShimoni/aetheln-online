# Definition-only policy shared by the explicit operator entry point and fixtures.
. (Join-Path $PSScriptRoot '../ci/RoutineCompileResources.ps1')

$script:HostToolEnginePin = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$script:HostToolTargets = @('UnrealPak', 'ShaderCompileWorker', 'UnrealEditor')
$script:HostToolProducts = @{
	UnrealEditor = @('Engine/Binaries/Win64/UnrealEditor.exe', 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe', 'Engine/Binaries/Win64/UnrealEditor.target')
	UnrealPak = @('Engine/Binaries/Win64/UnrealPak.exe', 'Engine/Binaries/Win64/UnrealPak.target')
	ShaderCompileWorker = @('Engine/Binaries/Win64/ShaderCompileWorker.exe', 'Engine/Binaries/Win64/ShaderCompileWorker.target')
}
$script:HostToolReceiptTypes = @{ UnrealEditor = 'Editor'; UnrealPak = 'Program'; ShaderCompileWorker = 'Program' }
$script:HostToolIncludedProductTypes = @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package')
$script:HostToolExcludedProductTypes = @('SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary')

function New-HostToolAttemptEnvelope {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns immutable deadline values only; it changes no external state.')]
	[CmdletBinding()]
	param([Parameter(Mandatory)][long] $StartTicks, [Parameter(Mandatory)][long] $Frequency)
	if ($StartTicks -lt 0 -or $Frequency -lt 1) { throw 'monotonic_clock_unavailable' }
	try {
		# Match the accepted #167 supervisor scale: 330 useful, 340 cleanup,
		# and 360 total minutes. The values are ceilings, not runtime estimates.
		$Useful = [long] ([decimal] $StartTicks + [decimal] 19800 * [decimal] $Frequency)
		$Cleanup = [long] ([decimal] $StartTicks + [decimal] 20400 * [decimal] $Frequency)
		$Publication = [long] ([decimal] $StartTicks + [decimal] 21600 * [decimal] $Frequency)
	} catch { throw 'monotonic_clock_unavailable' }
	return [pscustomobject]@{ startTicks = $StartTicks; frequency = $Frequency;
		usefulDeadlineTicks = $Useful; cleanupDeadlineTicks = $Cleanup; publicationDeadlineTicks = $Publication }
}

function New-HostToolEvidenceDirectory {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path)
	if ($Path -cnotmatch '^[A-Za-z]:[\\/]' -or (Test-Path -LiteralPath $Path) -or
		-not (Test-Path -LiteralPath (Split-Path -Parent $Path) -PathType Container)) { throw 'evidence_directory_exists_or_invalid' }
	Assert-InitialPreparationPlainPath -Path $Path -Reason 'evidence_directory_exists_or_invalid'
	Initialize-InitialPreparationJob
	if (-not ('HostToolProvisioningDirectory' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HostToolProvisioningDirectory {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectory(string path,IntPtr attributes);
 public static bool CreateNew(string path) { return CreateDirectory(path,IntPtr.Zero); }
}
'@
	}
	$Pins = @(Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $Path))
	try {
		if (-not [HostToolProvisioningDirectory]::CreateNew($Path)) { throw 'evidence_directory_exists_or_invalid' }
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'evidence_directory_exists_or_invalid'
	} finally { foreach ($Pin in $Pins) { $Pin.Dispose() } }
	return $Path
}

function Assert-HostToolFreshOutputRoot {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $EngineRoot,
		[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]] $Tracked,
		[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.Dictionary[string,object]] $GitDependencies,
		[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]] $Observed,
		[Parameter(Mandatory)] $ManifestProof, [Parameter(Mandatory)][int] $Count)
	Assert-InitialPreparationPlainPath -Path $Root -Reason 'fresh_output_unproven'
	if (-not (Test-Path -LiteralPath $Root)) { return $Count }
	if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'prior_host_outputs_present' }
	$Stack = New-Object Collections.Stack
	$Stack.Push($Root)
	while ($Stack.Count -gt 0) {
		$Directory = [string] $Stack.Pop()
		foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
			$Count++
			if ($Count -gt 100000) { throw 'fresh_output_unproven' }
			Assert-InitialPreparationPlainPath -Path $Item.FullName -Reason 'fresh_output_unproven'
			if ($Item.PSIsContainer) { $Stack.Push($Item.FullName); continue }
			$Relative = $Item.FullName.Substring($EngineRoot.TrimEnd('\').Length + 1)
			$NormalizedRelative = $Relative.Replace('\', '/')
			if (-not $Observed.Add($NormalizedRelative)) { throw 'fresh_output_case_collision' }
			if ($Tracked.Contains($Relative)) { continue }
			if (-not $GitDependencies.ContainsKey($NormalizedRelative)) { throw 'prior_host_outputs_present' }
			$Expected = $GitDependencies[$NormalizedRelative]
			if ($NormalizedRelative -cne $Expected.path) { throw 'fresh_output_case_collision' }
			$ActualHash = (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
			if ($ActualHash -cne $Expected.sha1) { throw 'gitdeps_hash_mismatch' }
			$ManifestProof.filesVerified++
		}
	}
	return $Count
}

function Get-HostToolGitDependencyAllowlist {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot, [string[]] $TrackedPaths = @())
	$Allowed = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
	$ManifestCount = 0
	$FileCount = 0
	foreach ($Relative in $TrackedPaths) {
		$Prefix = ''
		if ($Relative -cmatch '^[^/]+/Build/[^/]+\.gitdeps\.xml$') { }
		elseif ($Relative -cmatch '^(?<base>[^/]+)/Plugins/(?<plugin>.+)/Build/[^/]+\.gitdeps\.xml$') {
			$PluginRootRelative = $Matches.base + '/Plugins/' + $Matches.plugin
			$PluginRoot = Join-Path $EngineRoot $PluginRootRelative
			Assert-InitialPreparationPlainPath -Path $PluginRoot -Reason 'gitdeps_manifest_invalid'
			if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container) -or
				@(Get-ChildItem -LiteralPath $PluginRoot -File -Filter '*.uplugin' -ErrorAction Stop | Select-Object -First 1).Count -ne 1) { continue }
			$Prefix = $PluginRootRelative + '/'
		} else { continue }
		$ManifestCount++
		if ($ManifestCount -gt 128) { throw 'gitdeps_manifest_invalid' }
		$Path = Join-Path $EngineRoot $Relative
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'gitdeps_manifest_invalid'
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
			(Get-Item -LiteralPath $Path -Force).Length -gt 67108864) { throw 'gitdeps_manifest_invalid' }
		$Settings = New-Object System.Xml.XmlReaderSettings
		$Settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
		$Settings.XmlResolver = $null
		$Settings.MaxCharactersInDocument = 67108864
		$Reader = $null
		try {
			$Reader = [System.Xml.XmlReader]::Create($Path, $Settings)
			while ($Reader.Read()) {
				if ($Reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $Reader.Name -cne 'File') { continue }
				$FileCount++
				if ($FileCount -gt 200000) { throw 'gitdeps_manifest_invalid' }
				$Name = $Prefix + $Reader.GetAttribute('Name')
				$Hash = $Reader.GetAttribute('Hash')
				if ($Name -cnotmatch '^Engine/(Binaries/Win64|Plugins/.+/Binaries/Win64)/' -and
					$Name -cne 'Engine/Source/Programs/UnrealGameSync/PostBadgeStatus/bin/Release/PostBadgeStatus.exe') { continue }
				if ($Name.Length -gt 512 -or $Hash -cnotmatch '^[0-9a-f]{40}$' -or
					$Name.Contains(':') -or @(($Name -split '/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0 -or
					$Allowed.ContainsKey($Name)) { throw 'gitdeps_manifest_invalid' }
				$Allowed.Add($Name, [pscustomobject]@{ path = $Name; sha1 = $Hash })
			}
		} catch { throw 'gitdeps_manifest_invalid' }
		finally { if ($null -ne $Reader) { $Reader.Dispose() } }
	}
	return [pscustomobject]@{ paths = $Allowed; manifestCount = $ManifestCount; fileCount = $FileCount }
}

function Assert-HostToolGitDependencyManifestIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $ExpectedBlob, [Parameter(Mandatory)][string] $ActualBlob)
	if ($ExpectedBlob -cnotmatch '^[0-9a-f]{40}$' -or $ActualBlob -cnotmatch '^[0-9a-f]{40}$' -or
		$ExpectedBlob -cne $ActualBlob) { throw 'gitdeps_manifest_identity_mismatch' }
	return $true
}

function Assert-HostToolFreshOutputState {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot, [string[]] $TrackedPaths = @())
	$Engine = Join-Path $EngineRoot 'Engine'
	if (-not (Test-Path -LiteralPath $Engine -PathType Container)) { throw 'engine_root_invalid' }
	$Tracked = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Path in $TrackedPaths) {
		if (($Path -cnotmatch '^Engine/(Build|Binaries/Win64|Binaries/DotNET/UnrealBuildTool|Intermediate/Build|Plugins|Source/Programs)/' -and
			$Path -cnotmatch '^[^/]+/(Build/[^/]+\.gitdeps\.xml|Plugins/.+/Build/[^/]+\.gitdeps\.xml)$') -or
			$Path -match '(^|/)\.\.?(/|$)' -or -not $Tracked.Add($Path.Replace('/', '\'))) { throw 'fresh_output_unproven' }
	}
	$GitDependencyProof = Get-HostToolGitDependencyAllowlist -EngineRoot $EngineRoot -TrackedPaths $TrackedPaths
	$Observed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$ManifestProof = [pscustomobject]@{ filesVerified = 0 }
	$OutputRoots = @(
		(Join-Path $Engine 'Binaries/Win64'),
		(Join-Path $Engine 'Intermediate/Build/Win64'),
		(Join-Path $Engine 'Binaries/DotNET/UnrealBuildTool')
	)
	$OutputEntries = 0
	foreach ($Root in $OutputRoots) {
		$OutputEntries = Assert-HostToolFreshOutputRoot -Root $Root -EngineRoot $EngineRoot -Tracked $Tracked -GitDependencies $GitDependencyProof.paths -Observed $Observed -ManifestProof $ManifestProof -Count $OutputEntries
	}
	$IntermediateBuild = Join-Path $Engine 'Intermediate/Build'
	if (Test-Path -LiteralPath $IntermediateBuild -PathType Container) {
		foreach ($Item in @(Get-ChildItem -LiteralPath $IntermediateBuild -Force -ErrorAction Stop)) {
			# UBT loads or creates these rules assemblies outside Win64.
			if ([string]::Equals($Item.Name, 'BuildRules', [StringComparison]::OrdinalIgnoreCase)) { throw 'prior_host_outputs_present' }
			if (-not $Item.Name.StartsWith('UnrealBuildTool', [StringComparison]::OrdinalIgnoreCase)) { continue }
			$OutputEntries++
			if ($OutputEntries -gt 100000) { throw 'fresh_output_unproven' }
			Assert-InitialPreparationPlainPath -Path $Item.FullName -Reason 'fresh_output_unproven'
			$Relative = $Item.FullName.Substring($EngineRoot.TrimEnd('\').Length + 1)
			if ($Item.PSIsContainer -or -not $Tracked.Contains($Relative)) { throw 'prior_host_outputs_present' }
		}
	}
	$Plugins = Join-Path $Engine 'Plugins'
	$Scanned = 0
	if (Test-Path -LiteralPath $Plugins -PathType Container) {
		$Stack = New-Object Collections.Stack
		$Stack.Push($Plugins)
		while ($Stack.Count -gt 0) {
			$Directory = [string] $Stack.Pop()
			Assert-InitialPreparationPlainPath -Path $Directory -Reason 'fresh_output_unproven'
			$Scanned++
			if ($Scanned -gt 100000) { throw 'fresh_output_unproven' }
			if ([IO.Path]::GetFileName($Directory) -ieq 'Binaries') {
				$OutputRoots += Join-Path $Directory 'Win64'
			} elseif ([IO.Path]::GetFileName($Directory) -ieq 'Build' -and
				[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Directory)) -ieq 'Intermediate') {
				$OutputRoots += Join-Path $Directory 'Win64'
			}
			$Children = @(Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction Stop)
			foreach ($Child in $Children) { $Stack.Push($Child.FullName) }
		}
	}
	$Programs = Join-Path $Engine 'Source/Programs'
	if (Test-Path -LiteralPath $Programs -PathType Container) {
		$Stack = New-Object Collections.Stack
		$Stack.Push($Programs)
		while ($Stack.Count -gt 0) {
			$Directory = [string] $Stack.Pop()
			Assert-InitialPreparationPlainPath -Path $Directory -Reason 'fresh_output_unproven'
			$Scanned++
			if ($Scanned -gt 100000) { throw 'fresh_output_unproven' }
			foreach ($Child in @(Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction Stop)) {
				if ($Child.Name -in @('bin', 'obj')) { $OutputRoots += $Child.FullName }
				else { $Stack.Push($Child.FullName) }
			}
		}
	}
	foreach ($Root in $OutputRoots | Select-Object -Skip 3) {
		$OutputEntries = Assert-HostToolFreshOutputRoot -Root $Root -EngineRoot $EngineRoot -Tracked $Tracked -GitDependencies $GitDependencyProof.paths -Observed $Observed -ManifestProof $ManifestProof -Count $OutputEntries
	}
	return [pscustomobject]@{ fresh = $true; scannedPluginDirectories = $Scanned; outputRootsChecked = $OutputRoots.Count;
		trackedPaths = $Tracked.Count; outputEntriesChecked = $OutputEntries; manifestCount = $GitDependencyProof.manifestCount;
		manifestFilesVerified = $ManifestProof.filesVerified }
}

function Assert-HostToolGitState {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Head, [AllowEmptyString()][Parameter(Mandatory)][string] $Status,
		[Parameter(Mandatory)][string] $Expected, [ValidateSet('engine', 'controller')][string] $Kind = 'engine')
	if ($Head -cnotmatch '^[0-9a-f]{40}$' -or $Expected -cnotmatch '^[0-9a-f]{40}$' -or $Head -cne $Expected) {
		throw ($Kind + '_revision_mismatch')
	}
	if ($Status.Length -gt 0) { throw ($Kind + '_dirty') }
	return $Head
}

function Assert-HostToolControllerInputIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $ControllerRoot)
	$Safe = 'safe.directory=' + $ControllerRoot.Replace('\', '/')
	$TreeText = [string]::Join("`n", @(& git -c $Safe -C $ControllerRoot ls-tree -r -z HEAD 2>$null))
	if ($LASTEXITCODE -ne 0 -or $TreeText.Length -eq 0) { throw 'controller_input_identity_unavailable' }
	$IndexText = [string]::Join("`n", @(& git -c $Safe -C $ControllerRoot ls-files -s -z 2>$null))
	if ($LASTEXITCODE -ne 0 -or $IndexText.Length -eq 0) { throw 'controller_input_identity_unavailable' }
	$FlagsText = [string]::Join("`n", @(& git -c $Safe -C $ControllerRoot ls-files -v -z 2>$null))
	if ($LASTEXITCODE -ne 0 -or $FlagsText.Length -eq 0) { throw 'controller_input_identity_unavailable' }
	$TreeRecords = @($TreeText.Split([char] 0) | Where-Object { $_.Length -gt 0 })
	$IndexRecords = @($IndexText.Split([char] 0) | Where-Object { $_.Length -gt 0 })
	$FlagRecords = @($FlagsText.Split([char] 0) | Where-Object { $_.Length -gt 0 })
	if ($TreeRecords.Count -ne $IndexRecords.Count -or $TreeRecords.Count -ne $FlagRecords.Count -or
		$TreeRecords.Count -gt 10000) { throw 'controller_input_identity_mismatch' }
	$RelativePaths = New-Object 'Collections.Generic.List[string]'
	$ExpectedBlobs = New-Object 'Collections.Generic.List[string]'
	for ($Index = 0; $Index -lt $TreeRecords.Count; $Index++) {
		if ($TreeRecords[$Index] -cnotmatch '^(?<mode>100644|100755) blob (?<blob>[0-9a-f]{40})\t(?<path>.+)$') { throw 'controller_input_identity_mismatch' }
		$Mode = $Matches.mode; $Blob = $Matches.blob; $Relative = $Matches.path
		if ($Relative -match '[\r\n\t\\:]' -or $Relative -match '(^|/)\.\.?(/|$)') { throw 'controller_input_identity_mismatch' }
		if ($IndexRecords[$Index] -cnotmatch '^(?<mode>100644|100755) (?<blob>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
			$Matches.mode -cne $Mode -or $Matches.blob -cne $Blob -or $Matches.path -cne $Relative) { throw 'controller_input_identity_mismatch' }
		if ($FlagRecords[$Index] -cnotmatch '^H (.+)$') { throw 'controller_index_flags_present' }
		if ($Matches[1] -cne $Relative) { throw 'controller_input_identity_mismatch' }
		$RelativePaths.Add($Relative)
		$ExpectedBlobs.Add($Blob)
	}
	# Hash the worktree, not cached stat/status data. Repo-relative paths make
	# Git apply the same path-specific clean filters as HEAD; absolute paths can
	# fall back to a broader LFS rule. Write UTF-8 without PowerShell's stdin BOM.
	$GitCommand = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	$Start = New-Object Diagnostics.ProcessStartInfo
	$Start.FileName = $GitCommand
	$Start.Arguments = '-c "' + $Safe + '" -C "' + $ControllerRoot + '" hash-object --stdin-paths'
	$Start.UseShellExecute = $false
	$Start.CreateNoWindow = $true
	$Start.RedirectStandardInput = $true
	$Start.RedirectStandardOutput = $true
	$Start.RedirectStandardError = $true
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = $Start
	$PreviousInputEncoding = [Console]::InputEncoding
	try {
		[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
		try { if (-not $Process.Start()) { throw 'controller_input_identity_mismatch' } }
		finally { [Console]::InputEncoding = $PreviousInputEncoding }
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Utf8 = New-Object Text.UTF8Encoding($false)
		foreach ($Path in $RelativePaths) {
			$Bytes = $Utf8.GetBytes($Path + "`n")
			$Process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
		}
		$Process.StandardInput.Close()
		if (-not $Process.WaitForExit(600000)) { $Process.Kill(); throw 'controller_input_identity_mismatch' }
		$ActualText = $OutputTask.Result
		$null = $ErrorTask.Result
		if ($Process.ExitCode -ne 0) { throw 'controller_input_identity_mismatch' }
	} catch { throw 'controller_input_identity_mismatch' }
	finally { [Console]::InputEncoding = $PreviousInputEncoding; if (-not $Process.HasExited) { try { $Process.Kill() } catch {} }; $Process.Dispose() }
	$ActualBlobs = @($ActualText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
	if ($ActualBlobs.Count -ne $ExpectedBlobs.Count) { throw 'controller_input_identity_mismatch' }
	for ($Index = 0; $Index -lt $ExpectedBlobs.Count; $Index++) {
		if ([string] $ActualBlobs[$Index] -cne $ExpectedBlobs[$Index]) { throw 'controller_input_identity_mismatch' }
	}
	return $true
}

function Assert-HostToolEngineInputIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot)
	$Safe = 'safe.directory=' + $EngineRoot.Replace('\', '/')
	$TreeText = [string]::Join("`n", @(& git -c $Safe -C $EngineRoot ls-tree -r -z HEAD -- Engine 2>$null))
	if ($LASTEXITCODE -ne 0 -or $TreeText.Length -eq 0) { throw 'engine_input_identity_unavailable' }
	$TreeRecords = @($TreeText.Split([char] 0) | Where-Object { $_.Length -gt 0 })
	$IndexText = [string]::Join("`n", @(& git -c $Safe -C $EngineRoot ls-files -v -z -- Engine 2>$null))
	if ($LASTEXITCODE -ne 0 -or $IndexText.Length -eq 0) { throw 'engine_input_identity_unavailable' }
	$IndexRecords = @($IndexText.Split([char] 0) | Where-Object { $_.Length -gt 0 })
	if ($TreeRecords.Count -ne $IndexRecords.Count -or $TreeRecords.Count -gt 250000) { throw 'engine_input_identity_mismatch' }
	$RelativePaths = New-Object 'Collections.Generic.List[string]'
	$ExpectedBlobs = New-Object 'Collections.Generic.List[string]'
	for ($Index = 0; $Index -lt $TreeRecords.Count; $Index++) {
		$TreeRecord = $TreeRecords[$Index]
		if ($TreeRecord -cnotmatch '^100(?:644|755) blob (?<blob>[0-9a-f]{40})\t(?<path>Engine/.+)$') { throw 'engine_input_identity_mismatch' }
		$Relative = $Matches.path
		$Blob = $Matches.blob
		if ($Relative -match '[\r\n\t\\:]' -or $Relative -match '(^|/)\.\.?(/|$)') { throw 'engine_input_identity_mismatch' }
		$IndexRecord = $IndexRecords[$Index]
		if ($IndexRecord -cnotmatch '^H (.+)$') { throw 'engine_index_flags_present' }
		if ($Matches[1] -cne $Relative) { throw 'engine_input_identity_mismatch' }
		$RelativePaths.Add($Relative)
		$ExpectedBlobs.Add($Blob)
	}
	# Repo-relative stdin-paths applies each path's Git clean filter (including
	# Windows text normalization) while hashing actual bytes in one process.
	# Windows PowerShell 5 prepends a BOM to native pipeline stdin, so write
	# UTF-8 without a BOM directly to Git's process stream.
	$GitCommand = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	$Start = New-Object Diagnostics.ProcessStartInfo
	$Start.FileName = $GitCommand
	$Start.Arguments = '-c "' + $Safe + '" -C "' + $EngineRoot + '" hash-object --stdin-paths'
	$Start.UseShellExecute = $false
	$Start.CreateNoWindow = $true
	$Start.RedirectStandardInput = $true
	$Start.RedirectStandardOutput = $true
	$Start.RedirectStandardError = $true
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = $Start
	$PreviousInputEncoding = [Console]::InputEncoding
	try {
		[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
		try { if (-not $Process.Start()) { throw 'engine_input_identity_mismatch' } }
		finally { [Console]::InputEncoding = $PreviousInputEncoding }
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Utf8 = New-Object Text.UTF8Encoding($false)
		foreach ($Path in $RelativePaths) {
			$Bytes = $Utf8.GetBytes($Path + "`n")
			$Process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
		}
		$Process.StandardInput.Close()
		if (-not $Process.WaitForExit(600000)) { $Process.Kill(); throw 'engine_input_identity_mismatch' }
		$ActualText = $OutputTask.Result
		$null = $ErrorTask.Result
		if ($Process.ExitCode -ne 0) { throw 'engine_input_identity_mismatch' }
	} catch { throw 'engine_input_identity_mismatch' }
	finally { [Console]::InputEncoding = $PreviousInputEncoding; if (-not $Process.HasExited) { try { $Process.Kill() } catch {} }; $Process.Dispose() }
	$ActualBlobs = @($ActualText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
	if ($ActualBlobs.Count -ne $ExpectedBlobs.Count) { throw 'engine_input_identity_mismatch' }
	$MismatchIndexes = New-Object 'Collections.Generic.List[int]'
	for ($Index = 0; $Index -lt $ExpectedBlobs.Count; $Index++) {
		if ([string] $ActualBlobs[$Index] -cne $ExpectedBlobs[$Index]) { $MismatchIndexes.Add($Index) }
	}
	if ($MismatchIndexes.Count -eq 0) { return $true }
	# Some pinned engine blobs intentionally contain CRLF. core.autocrlf can
	# normalize their filtered hash even when worktree bytes equal HEAD exactly.
	# Rehash only mismatches without filters; no other difference is accepted.
	$Start.Arguments = '-c "' + $Safe + '" -C "' + $EngineRoot + '" hash-object --no-filters --stdin-paths'
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = $Start
	try {
		[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
		try { if (-not $Process.Start()) { throw 'engine_input_identity_mismatch' } }
		finally { [Console]::InputEncoding = $PreviousInputEncoding }
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		foreach ($Index in $MismatchIndexes) {
			$Bytes = $Utf8.GetBytes($RelativePaths[$Index] + "`n")
			$Process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
		}
		$Process.StandardInput.Close()
		if (-not $Process.WaitForExit(600000)) { $Process.Kill(); throw 'engine_input_identity_mismatch' }
		$RawText = $OutputTask.Result
		$null = $ErrorTask.Result
		if ($Process.ExitCode -ne 0) { throw 'engine_input_identity_mismatch' }
	} catch { throw 'engine_input_identity_mismatch' }
	finally { [Console]::InputEncoding = $PreviousInputEncoding; if (-not $Process.HasExited) { try { $Process.Kill() } catch {} }; $Process.Dispose() }
	$RawBlobs = @($RawText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
	if ($RawBlobs.Count -ne $MismatchIndexes.Count) { throw 'engine_input_identity_mismatch' }
	for ($Mismatch = 0; $Mismatch -lt $MismatchIndexes.Count; $Mismatch++) {
		if ([string] $RawBlobs[$Mismatch] -cne $ExpectedBlobs[$MismatchIndexes[$Mismatch]]) { throw 'engine_input_identity_mismatch' }
	}
	return $true
}

function Get-HostToolBuildCommand {
	[CmdletBinding()]
	param([Parameter(Mandatory)][ValidateSet('UnrealEditor', 'UnrealPak', 'ShaderCompileWorker')][string] $Target,
		[Parameter(Mandatory)][int] $ActionLimit, [Parameter(Mandatory)][string] $BuildBatch)
	if ($ActionLimit -lt 1 -or $ActionLimit -gt 4) { throw 'action_limit_invalid' }
	if ([string]::IsNullOrWhiteSpace($BuildBatch) -or $BuildBatch -match '["\x00-\x1f]') { throw 'build_path_invalid' }
	return [pscustomobject]@{ executable = $BuildBatch; arguments = @(
		$Target, 'Win64', 'Development', '-WaitMutex', '-NoHotReloadFromIDE',
		'-UBA', '-UBADisableRemote', '-NoXGE', '-NoSNDBS', '-NoFASTBuild',
		('-MaxParallelActions=' + $ActionLimit), '-Compiler=VisualStudio2022',
		'-CompilerVersion=14.44.35207', '-WindowsSDKVersion=10.0.26100.0') }
}

function Get-HostToolBuildProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines, [Parameter(Mandatory)][string] $ToolDirectory,
		[Parameter(Mandatory)][string] $SdkDirectory)
	if ($Lines.Count -lt 1 -or $Lines.Count -gt 200000) { throw 'actions_unproven' }
	$Selected = 0; $Plan = $null; $Progress = 0
	foreach ($Line in $Lines) {
		if ($Line.Length -gt 16384) { throw 'build_log_invalid' }
		if ($Line -cmatch '^Using Visual Studio 2022 (?<version>14\.44\.35228) toolchain \((?<tool>[^\r\n]{1,4096})\) and Windows 10\.0\.26100\.0 SDK \((?<sdk>[^\r\n]{1,4096})\)\.$') {
			$Selected++
			if ($Selected -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath($Matches.tool).TrimEnd('\', '/'), [IO.Path]::GetFullPath($ToolDirectory).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -or
				-not [string]::Equals([IO.Path]::GetFullPath($Matches.sdk).TrimEnd('\', '/'), [IO.Path]::GetFullPath($SdkDirectory).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { throw 'tool_selection_mismatch' }
		} elseif ($Line.StartsWith('Using ', [StringComparison]::Ordinal) -and
			($Line.Contains(' toolchain (') -or $Line.Contains(' SDK ('))) { throw 'tool_selection_mismatch' }
		if ($Line -cmatch '^Using [^\r\n]{1,512} executor to run (?<count>[0-9]{1,10}) action\(s\)$') {
			if ($null -ne $Plan) { throw 'actions_unproven' }
			$Parsed = 0
			if (-not [int]::TryParse($Matches.count, [ref] $Parsed) -or $Parsed -lt 1 -or $Parsed -gt 200000) { throw 'actions_unproven' }
			$Plan = $Parsed
		} elseif ($Line.StartsWith('Using ', [StringComparison]::Ordinal) -and $Line.Contains(' executor to run ')) { throw 'actions_unproven' }
		if ($Line -cmatch '^\[(?<ordinal>[0-9]{1,10})/(?<total>[0-9]{1,10})\] ') {
			$Ordinal = 0; $Total = 0
			if (-not [int]::TryParse($Matches.ordinal, [ref] $Ordinal) -or -not [int]::TryParse($Matches.total, [ref] $Total) -or
				$null -eq $Plan -or $Total -ne $Plan -or $Ordinal -lt 1 -or $Ordinal -gt $Plan) { throw 'actions_unproven' }
			$Progress++
		}
	}
	if ($Selected -ne 1) { throw 'tool_selection_unproven' }
	if ($null -eq $Plan -or $Progress -lt 1) { throw 'actions_unproven' }
	return [pscustomobject]@{ actionCount = [int] $Plan; progressCount = [int] $Progress; selectionVerified = $true }
}

function Get-HostToolProductState {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot,
		[Parameter(Mandatory)][ValidateSet('UnrealEditor', 'UnrealPak', 'ShaderCompileWorker')][string] $Target)
	$State = [ordered]@{}
	foreach ($Relative in $script:HostToolProducts[$Target]) {
		$Path = Join-Path $EngineRoot $Relative
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'product_path_invalid'
		if (-not (Test-Path -LiteralPath $Path)) { $State[$Relative] = $null; continue }
		$Item = Get-Item -LiteralPath $Path -ErrorAction Stop
		if ($Item.PSIsContainer -or $Item.Length -lt 1 -or $Item.Length -gt 8GB) { throw 'product_invalid' }
		$State[$Relative] = [pscustomobject]@{ sizeBytes = [long] $Item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
	}
	return $State
}

function Assert-HostToolProductChange {
	[CmdletBinding()]
	param([Parameter(Mandatory)][ValidateSet('UnrealEditor', 'UnrealPak', 'ShaderCompileWorker')][string] $Target,
		[Parameter(Mandatory)][Collections.IDictionary] $Before, [Parameter(Mandatory)][Collections.IDictionary] $After)
	$Changed = $false
	foreach ($Relative in $script:HostToolProducts[$Target]) {
		if (-not $Before.Contains($Relative) -or -not $After.Contains($Relative) -or $null -eq $After[$Relative] -or
			$After[$Relative].sha256 -isnot [string] -or $After[$Relative].sha256 -cnotmatch '^[0-9a-f]{64}$' -or
			($After[$Relative].sizeBytes -isnot [int] -and $After[$Relative].sizeBytes -isnot [long]) -or $After[$Relative].sizeBytes -lt 1) { throw 'products_unproven' }
		if ($Relative.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) -and
			($null -eq $Before[$Relative] -or $Before[$Relative].sha256 -cne $After[$Relative].sha256 -or
			$Before[$Relative].sizeBytes -ne $After[$Relative].sizeBytes)) { $Changed = $true }
	}
	if (-not $Changed) { throw 'products_unchanged' }
	return $true
}

function Assert-HostToolReceiptSet {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot)
	$Seen = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
	$TotalBytes = [long] 0
	foreach ($Target in $script:HostToolTargets) {
		$ReceiptRelative = 'Engine/Binaries/Win64/' + $Target + '.target'
		$ReceiptPath = Join-Path $EngineRoot $ReceiptRelative
		Assert-InitialPreparationPlainPath -Path $ReceiptPath -Reason 'target_receipt_invalid'
		if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'target_receipt_invalid' }
		$ReceiptItem = Get-Item -LiteralPath $ReceiptPath -Force
		if ($ReceiptItem.Length -lt 1 -or $ReceiptItem.Length -gt 16777216) { throw 'target_receipt_invalid' }
		try { $Parsed = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json }
		catch { throw 'target_receipt_invalid' }
		foreach ($Name in @('TargetName', 'Platform', 'Configuration', 'TargetType', 'BuildProducts')) {
			if ($null -eq $Parsed -or $null -eq $Parsed.PSObject.Properties[$Name]) { throw 'target_receipt_invalid' }
		}
		if ($Parsed.TargetName -isnot [string] -or $Parsed.TargetName -cne $Target -or
			$Parsed.Platform -isnot [string] -or $Parsed.Platform -cne 'Win64' -or
			$Parsed.Configuration -isnot [string] -or $Parsed.Configuration -cne 'Development' -or
			$Parsed.TargetType -isnot [string] -or $Parsed.TargetType -cne $script:HostToolReceiptTypes[$Target] -or
			$Parsed.BuildProducts -isnot [array] -or $Parsed.BuildProducts.Count -lt 1 -or
			$Parsed.BuildProducts.Count -gt 8192) { throw 'target_receipt_invalid' }
		$Derived = New-Object Collections.ArrayList
		[void] $Derived.Add([pscustomobject]@{ path = $ReceiptRelative; type = 'TargetReceipt' })
		$TargetProducts = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		foreach ($Product in $Parsed.BuildProducts) {
			if ($null -eq $Product -or $null -eq $Product.PSObject.Properties['Path'] -or
				$null -eq $Product.PSObject.Properties['Type'] -or $Product.Path -isnot [string] -or
				$Product.Type -isnot [string]) { throw 'target_receipt_invalid' }
			if ($script:HostToolExcludedProductTypes -ccontains $Product.Type) { continue }
			if ($script:HostToolIncludedProductTypes -cnotcontains $Product.Type -or
				$Product.Path -cnotmatch '^\$\(EngineDir\)/') { throw 'target_receipt_invalid' }
			$Relative = 'Engine/' + $Product.Path.Substring(13)
			if ($Relative.Contains(':') -or [IO.Path]::IsPathRooted($Relative) -or
				@(($Relative -split '[\\/]') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) { throw 'target_receipt_invalid' }
			[void] $Derived.Add([pscustomobject]@{ path = $Relative; type = $Product.Type })
			if (-not $TargetProducts.Add($Relative.Replace('\', '/'))) { throw 'target_product_duplicate' }
		}
		foreach ($Expected in $script:HostToolProducts[$Target]) {
			if ($Expected.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) -and
				-not $TargetProducts.Contains($Expected)) { throw 'target_receipt_invalid' }
		}
		foreach ($Entry in $Derived) {
			$Relative = [string] $Entry.path
			$Normalized = $Relative.Replace('\', '/')
			$IsNew = -not $Seen.ContainsKey($Normalized)
			if ($IsNew) {
				$Seen.Add($Normalized, [pscustomobject]@{ path = $Normalized; type = [string] $Entry.type })
			} else {
				$Previous = $Seen[$Normalized]
				if ($Previous.path -cne $Normalized -or $Previous.type -cne [string] $Entry.type -or
					$Entry.type -ceq 'TargetReceipt') { throw 'target_product_duplicate' }
			}
			$Path = Join-Path $EngineRoot $Relative
			Assert-InitialPreparationPlainPath -Path $Path -Reason 'target_receipt_invalid'
			if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'target_product_missing' }
			$Size = [long] (Get-Item -LiteralPath $Path -Force).Length
			if ($Size -lt 0 -or $Size -gt 4294967296L) { throw 'target_product_invalid' }
			if ($IsNew) {
				if ($TotalBytes -gt 137438953472L - $Size) { throw 'target_product_invalid' }
				$TotalBytes += $Size
			}
		}
	}
	return [pscustomobject]@{ productCount = $Seen.Count; totalBytes = $TotalBytes; semanticsVerified = $true }
}

function Invoke-HostToolProvisioningSequence {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string[]] $Targets, [Parameter(Mandatory)][scriptblock] $ReadTicks,
		[Parameter(Mandatory)][long] $UsefulDeadlineTicks, [Parameter(Mandatory)][long] $CleanupDeadlineTicks,
		[scriptblock] $ReadCapacity, [scriptblock] $AdmitTarget, [Parameter(Mandatory)][scriptblock] $InvokeBuild)
	if ($Targets.Count -ne 3 -or ($Targets -join ',') -cne ($script:HostToolTargets -join ',') -or
		$UsefulDeadlineTicks -le 0 -or $CleanupDeadlineTicks -le $UsefulDeadlineTicks -or
		(($null -eq $ReadCapacity) -eq ($null -eq $AdmitTarget))) { throw 'provisioning_plan_invalid' }
	$Results = New-Object Collections.ArrayList
	foreach ($Target in $Targets) {
		$Tick = & $ReadTicks
		if ($Tick -isnot [long] -and $Tick -isnot [int]) { throw 'monotonic_clock_unavailable' }
		if ([long] $Tick -ge $UsefulDeadlineTicks) { throw 'useful_work_deadline' }
		$Limit = if ($null -ne $AdmitTarget) { & $AdmitTarget }
		else { Get-InitialPreparationActionLimit -Capacity (& $ReadCapacity) }
		if (($Limit -isnot [int] -and $Limit -isnot [long]) -or $Limit -lt 1 -or $Limit -gt 4) { throw 'action_limit_invalid' }
		$Result = & $InvokeBuild $Target $Limit
		if ($null -eq $Result -or $Result.target -cne $Target -or $Result.cleanupVerified -isnot [bool] -or -not $Result.cleanupVerified) { throw 'cleanup_unproven' }
		if (($Result.nativeExitCode -isnot [int] -and $Result.nativeExitCode -isnot [long]) -or $Result.nativeExitCode -ne 0) { throw 'native_build_failed' }
		if ($Result.selectionVerified -isnot [bool] -or -not $Result.selectionVerified) { throw 'tool_selection_unproven' }
		if (($Result.actionCount -isnot [int] -and $Result.actionCount -isnot [long]) -or $Result.actionCount -lt 1 -or
			($Result.progressCount -isnot [int] -and $Result.progressCount -isnot [long]) -or $Result.progressCount -lt 1) { throw 'actions_unproven' }
		if ($Result.productsVerified -isnot [bool] -or -not $Result.productsVerified) { throw 'products_unproven' }
		if ($Result.logSha256 -isnot [string] -or $Result.logSha256 -cnotmatch '^[0-9a-f]{64}$' -or @($Result.command).Count -lt 2) { throw 'build_evidence_invalid' }
		[void] $Results.Add([pscustomobject]@{ target = $Target; actionLimit = [int] $Limit; nativeExitCode = 0;
			actionCount = [int] $Result.actionCount; progressCount = [int] $Result.progressCount;
			cleanupVerified = $true; productsVerified = $true; command = @($Result.command); logSha256 = $Result.logSha256 })
	}
	$Tick = & $ReadTicks
	if (($Tick -isnot [long] -and $Tick -isnot [int]) -or [long] $Tick -ge $CleanupDeadlineTicks) { throw 'cleanup_deadline' }
	return ,@($Results)
}
