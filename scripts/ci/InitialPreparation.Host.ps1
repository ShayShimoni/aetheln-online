# Compile-host identity only. No engine/tool rebuild, installation or packaging.
# Version selection is enforced by BuildInvocation; physical Windows tool selection
# must additionally match the actual UBT-selected paths before final acceptance.
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot 'InitialPreparation.GitHub.ps1')
. (Join-Path $PSScriptRoot 'InitialPreparation.Input.ps1')

function Get-InitialPreparationHostInventory {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $PublishRoot, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)][scriptblock] $OnProgress)
	$PublishPrefix = [IO.Path]::GetFullPath($PublishRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
	$Pending = New-Object 'Collections.Generic.Queue[string]'
	$Pending.Enqueue($PublishRoot)
	$Paths = New-Object 'Collections.Generic.List[string]'
	$DirectoryCount = 0
	while ($Pending.Count -gt 0) {
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		$Directory = $Pending.Dequeue()
		$DirectoryCount++
		if ($DirectoryCount -gt 128) { throw 'host_inventory_limit' }
		Assert-InitialPreparationPlainPath -Path $Directory -Reason 'host_input_path_invalid'
		foreach ($Item in [IO.Directory]::EnumerateFileSystemEntries($Directory)) {
			if ($Paths.Count + $Pending.Count -ge 2048) { throw 'host_inventory_limit' }
			$Name = [IO.Path]::GetFileName($Item)
			# Inspect names/metadata before opening bytes; never inspect secrets.
			if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $Name -match '(?i)(secret|credential|token|password|private|^\.env)') { throw 'host_input_path_invalid' }
			$Attributes = [IO.File]::GetAttributes($Item)
			if ($Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'host_input_path_invalid' }
			if ($Attributes -band [IO.FileAttributes]::Directory) { $Pending.Enqueue($Item) }
			else {
				$Relative = [IO.Path]::GetFullPath($Item).Substring($PublishPrefix.Length).Replace('\', '/')
				# Exact pinned publish assets: SQLitePCLRaw.lib.e_sqlite3/2.1.11
				# runtimeTargets in UBT.deps.json, and EpicGames.UBA/Library.props.
				# Keep unknown .a/.bin files rejected, including the same basenames
				# at other locations. These assets still enter the retained hash set.
				$KnownNativeAsset = $Relative -cin @('runtimes/browser-wasm/nativeassets/net9.0/e_sqlite3.a', 'runtimes/linux-x64/native/UbaStaticStub.bin')
				if (-not $KnownNativeAsset -and [IO.Path]::GetExtension($Item) -notin @('.dll', '.exe', '.json', '.config', '.dat', '.so', '.dylib', '.pdb', '.xml')) { throw 'host_input_path_invalid' }
				$Paths.Add([IO.Path]::GetFullPath($Item))
			}
		}
	}
	return ,@($Paths | Sort-Object)
}

function Close-InitialPreparationHostProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Proof)
	foreach ($Handle in $Proof.handles) { $Handle.Dispose() }
	$Proof.closed = $true
}

function Get-InitialPreparationHostProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $LinuxToolchainRoot,
		[Parameter(Mandatory)][string] $CompilerPath, [Parameter(Mandatory)][string] $ResourceCompilerPath,
		[Parameter(Mandatory)][scriptblock] $OnProgress)
	Assert-InitialPreparationInputLease -Attempt $Attempt -Lease $Lease
	foreach ($Path in @($EngineRoot, $LinuxToolchainRoot, $CompilerPath, $ResourceCompilerPath)) {
		if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 4096 -or $Path.Substring(2).Contains(':') -or $Path -match '["\x00-\x1f]') { throw 'host_tool_path_invalid' }
	}
	$EngineRoot = [IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
	$LinuxToolchainRoot = [IO.Path]::GetFullPath($LinuxToolchainRoot).TrimEnd('\', '/')
	$CompilerPath = [IO.Path]::GetFullPath($CompilerPath)
	$ResourceCompilerPath = [IO.Path]::GetFullPath($ResourceCompilerPath)
	if ($CompilerPath -notmatch '[\\/]VC[\\/]Tools[\\/]MSVC[\\/]14\.44\.35207[\\/]bin[\\/]Hostx64[\\/]x64[\\/]cl\.exe$' -or
		$ResourceCompilerPath -notmatch '[\\/]bin[\\/]10\.0\.26100\.0[\\/]x64[\\/]rc\.exe$' -or
		[IO.Path]::GetFileName($LinuxToolchainRoot) -cne 'v26_clang-20.1.8-rockylinux8') { throw 'host_tool_path_invalid' }
	Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
	$Engine = Get-InitialPreparationCheckoutIdentity -Root $EngineRoot -ExpectedRevision '9ab6767ecaaa724d01371ffaea14317311ae8371'
	if ($Engine.clean -isnot [bool] -or -not $Engine.clean) { throw 'host_engine_identity_invalid' }
	$PublishRoot = Join-Path $EngineRoot 'Engine/Binaries/DotNET/UnrealBuildTool'
	$Proof = [pscustomobject]@{ scope = 'compile_host_file_identity'; attempt = $Attempt; lease = $Lease;
		engineRoot = $EngineRoot; publishRoot = $PublishRoot; inventory = @(); records = (New-Object Collections.ArrayList);
		linuxToolchainRoot = $LinuxToolchainRoot;
		handles = (New-Object Collections.ArrayList); digest = $null; closed = $false;
		invocationSha256 = $null;
		inputsVerified = $true; consumptionVerified = $false; baselineVerified = $false;
		dotnetPath = (Join-Path $EngineRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe');
		compilerPath = $CompilerPath; resourceCompilerPath = $ResourceCompilerPath;
		requiredWindowsArguments = @('-Compiler=VisualStudio2022', '-CompilerVersion=14.44.35207', '-WindowsSDKVersion=10.0.26100.0') }
	try {
		$Proof.inventory = Get-InitialPreparationHostInventory -PublishRoot $PublishRoot -Attempt $Attempt -OnProgress $OnProgress
		foreach ($Name in @('UnrealBuildTool.dll', 'EpicGames.UHT.dll', 'UnrealBuildTool.deps.json', 'UnrealBuildTool.runtimeconfig.json')) {
			if ($Proof.inventory -notcontains (Join-Path $PublishRoot $Name)) { throw 'host_required_input_missing' }
		}
		$InvocationPath = Join-Path $PSScriptRoot 'InitialPreparation.BuildInvocation.ps1'
		$Paths = @($Proof.inventory) + @($InvocationPath, $Proof.dotnetPath, $CompilerPath, (Join-Path (Split-Path -Parent $CompilerPath) 'link.exe'), $ResourceCompilerPath,
			(Join-Path $LinuxToolchainRoot 'ToolchainVersion.txt'), (Join-Path $LinuxToolchainRoot 'x86_64-unknown-linux-gnu/bin/clang++.exe'),
			(Join-Path $LinuxToolchainRoot 'x86_64-unknown-linux-gnu/bin/ld.lld.exe'), (Join-Path $LinuxToolchainRoot 'x86_64-unknown-linux-gnu/usr/include/stdio.h'))
		foreach ($Name in @('Build.bat', 'BuildUBT.bat', 'GetDotnetPath.bat', 'DotnetDepends.bat')) { $Paths += Join-Path $EngineRoot ('Engine/Build/BatchFiles/' + $Name) }
		$PinnedDirectories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		$Total = 0L
		foreach ($Path in @($Paths | Sort-Object)) {
			Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
			Assert-InitialPreparationPlainPath -Path $Path -Reason 'host_input_path_invalid'
			$Directory = Split-Path -Parent $Path
			if ($PinnedDirectories.Add($Directory)) { foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $Proof.handles.Add($Pin) } }
			$Stream = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($Path), [IO.FileAccess]::Read)
			[void] $Proof.handles.Add($Stream)
			if ($Stream.Length -lt 1 -or $Stream.Length -gt 268435456 -or $Stream.Length -gt 1073741824L - $Total) { throw 'host_input_size_limit' }
			$Total += $Stream.Length
			if ($Path -ceq (Join-Path $LinuxToolchainRoot 'ToolchainVersion.txt')) {
				if ($Stream.Length -gt 128) { throw 'host_linux_version_invalid' }
				$VersionBytes = New-Object byte[] ([int] $Stream.Length)
				if ($Stream.Read($VersionBytes, 0, $VersionBytes.Length) -ne $VersionBytes.Length -or
					([Text.Encoding]::UTF8.GetString($VersionBytes)).Trim() -cne 'v26_clang-20.1.8-rockylinux8') { throw 'host_linux_version_invalid' }
				$Stream.Position = 0
			}
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try {
				$Buffer = New-Object byte[] 65536
				while (($Count = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
					[void] $Hasher.TransformBlock($Buffer, 0, $Count, $Buffer, 0)
					Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
				}
				[void] $Hasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
				$Digest = ([BitConverter]::ToString($Hasher.Hash)).Replace('-', '').ToLowerInvariant()
			} finally { $Hasher.Dispose() }
			[void] $Proof.records.Add([pscustomobject]@{ path = $Path; bytes = $Stream.Length; sha256 = $Digest })
			if ($Path -ceq $InvocationPath) { $Proof.invocationSha256 = $Digest }
		}
		$Bytes = [Text.Encoding]::UTF8.GetBytes(($Proof.records | ConvertTo-Json -Depth 3 -Compress))
		if ($Bytes.Length -gt 8388608) { throw 'host_inventory_limit' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Proof.digest = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		$null = Assert-InitialPreparationHostProof -Proof $Proof -OnProgress $OnProgress
		return $Proof
	} catch { Close-InitialPreparationHostProof -Proof $Proof; throw }
}

function Assert-InitialPreparationHostProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Proof, [Parameter(Mandatory)][scriptblock] $OnProgress)
	if ($Proof.closed) { throw 'host_proof_closed' }
	Assert-InitialPreparationInputLease -Attempt $Proof.attempt -Lease $Proof.lease
	$Inventory = Get-InitialPreparationHostInventory -PublishRoot $Proof.publishRoot -Attempt $Proof.attempt -OnProgress $OnProgress
	if ($Inventory.Count -ne $Proof.inventory.Count -or (Compare-Object -ReferenceObject $Proof.inventory -DifferenceObject $Inventory -CaseSensitive)) { throw 'host_input_inventory_changed' }
	# Retained no-write/no-delete handles bind existing bytes; no repeat hashing.
	foreach ($Handle in $Proof.handles) {
		if ($Handle -is [IO.FileStream] -and -not $Handle.CanRead) { throw 'host_proof_closed' }
	}
	return $Proof.digest
}

function Assert-InitialPreparationHostReadiness {
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)] $Proof,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedInvocationSha256,
		[Parameter(Mandatory)][scriptblock] $OnProgress)
	# The lead supplies the independently reviewed, frozen invocation identity.
	# That invocation enforces bundled dotnet and canonical Windows versions.
	# This admits a bounded compile attempt; it is not observed physical Windows
	# tool selection, successful compilation, dependency-scan or baseline proof.
	$null = Assert-InitialPreparationHostProof -Proof $Proof -OnProgress $OnProgress
	if ($Proof.inputsVerified -isnot [bool] -or -not $Proof.inputsVerified -or
		$Proof.invocationSha256 -isnot [string] -or $Proof.invocationSha256 -cne $ExpectedInvocationSha256) { throw 'host_invocation_identity_mismatch' }
	return $true
}
