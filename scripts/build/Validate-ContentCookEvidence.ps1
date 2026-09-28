<#
.SYNOPSIS
Validates client and dedicated-server cooked package inventories against governed content audiences.

.DESCRIPTION
Consumes an exact-revision content-validation report plus immutable client and
Linux-server registry captures. It snapshots every input, validates the closed
registry provenance and package inventories, and fails on malformed evidence,
input drift, missing required packages, or audience-boundary leaks. It never
runs a cook.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string] $ContentValidationReportPath,
	[Parameter(Mandatory)]
	[string] $ClientCookedInventoryDirectory,
	[Parameter(Mandatory)]
	[string] $ServerCookedInventoryDirectory,
	[string] $OutputPath,
	[string] $PolicyPath,
	[string] $RuntimeIntakePath,
	[string] $BuildProvenancePath,
	[switch] $AllowTestEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$GovernedPolicyPath = Join-Path $RepositoryRoot 'Config\ContentValidation\asset-intake-policy.json'
$GovernedRuntimeIntakePath = Join-Path $RepositoryRoot 'Config\ContentValidation\runtime-asset-intake.json'
if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = $GovernedPolicyPath }
if ([string]::IsNullOrWhiteSpace($RuntimeIntakePath)) { $RuntimeIntakePath = $GovernedRuntimeIntakePath }
if (-not $AllowTestEvidence) {
	if ([IO.Path]::GetFullPath($PolicyPath) -cne [IO.Path]::GetFullPath($GovernedPolicyPath)) { throw 'PolicyPath override is test-only and requires AllowTestEvidence.' }
	if ([IO.Path]::GetFullPath($RuntimeIntakePath) -cne [IO.Path]::GetFullPath($GovernedRuntimeIntakePath)) { throw 'RuntimeIntakePath override is test-only and requires AllowTestEvidence.' }
}
if ([string]::IsNullOrWhiteSpace($BuildProvenancePath)) {
	$BuildProvenancePath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ClientCookedInventoryDirectory))) 'build-provenance.json'
}

function Test-JsonObject([object] $Value) {
	return ($null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject])
}

function Test-JsonArray([object] $Value) {
	return ($null -ne $Value -and -not (Test-JsonObject $Value) -and -not ($Value -is [string]) -and $Value -is [System.Collections.IEnumerable])
}

function Test-JsonInteger([object] $Value) {
	return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
}

function Test-NonBlankJsonString([object] $Value) {
	return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Get-CanonicalNotApplicableEvidence([string] $FamilyId) {
	return "policy:${FamilyId}:not_applicable:no_observed_checks"
}

function ConvertFrom-RequiredUtcTimestamp([object] $Value, [string] $Context) {
	if (-not (Test-NonBlankJsonString $Value)) { throw "$Context must be a non-blank string." }
	if ([string]$Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') { throw "$Context must be a UTC timestamp ending in Z." }
	$Parsed = [DateTimeOffset]::MinValue
	$Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
	if (-not [DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Parsed)) { throw "$Context is malformed." }
	return $Parsed
}

function Assert-ClosedProperties([object] $Value, [string[]] $Allowed, [string] $Context, [switch] $CaseSensitive) {
	if (-not (Test-JsonObject $Value)) { throw "$Context must be a JSON object; validation fails closed." }
	$Names = @($Value.PSObject.Properties.Name)
	foreach ($Name in $Names) {
		$Unsupported = if ($CaseSensitive) { $Allowed -cnotcontains $Name } else { $Allowed -notcontains $Name }
		if ($Unsupported) { throw "$Context contains unsupported field '$Name'; validation fails closed." }
	}
	foreach ($Name in $Allowed) {
		$Missing = if ($CaseSensitive) { $Names -cnotcontains $Name } else { $Names -notcontains $Name }
		if ($Missing) { throw "$Context is missing required field '$Name'; validation fails closed." }
	}
}

function Read-RequiredJson([string] $Path, [string] $Context) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing at '$Path'; validation fails closed." }
	try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
	catch { throw "$Context '$Path' is not valid JSON: $($_.Exception.Message)" }
}

function Get-LowerSha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-StableFileSnapshot([string] $Context, [string] $Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing at '$Path'; validation fails closed." }
	$ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
	$Before = Get-Item -LiteralPath $ResolvedPath
	$Stream = [IO.File]::Open($ResolvedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
		finally { $Hasher.Dispose() }
		$SizeBytes = $Stream.Length
	}
	finally { $Stream.Dispose() }
	$After = Get-Item -LiteralPath $ResolvedPath
	if ($Before.Length -ne $After.Length -or $Before.LastWriteTimeUtc.Ticks -ne $After.LastWriteTimeUtc.Ticks -or $SizeBytes -ne $After.Length) {
		throw "$Context changed while it was being read; validation fails closed."
	}
	if ($SizeBytes -le 0) { throw "$Context must have a positive byte size; validation fails closed." }
	return [pscustomobject]@{
		Path = $ResolvedPath
		SizeBytes = [long]$SizeBytes
		Sha256 = $Sha256
		LastWriteTimeUtcTicks = [long]$After.LastWriteTimeUtc.Ticks
	}
}

function Assert-FileUnchanged([object] $Expected, [string] $Context) {
	$Actual = Read-StableFileSnapshot $Context $Expected.Path
	if ($Actual.SizeBytes -ne $Expected.SizeBytes -or $Actual.Sha256 -cne $Expected.Sha256 -or $Actual.LastWriteTimeUtcTicks -ne $Expected.LastWriteTimeUtcTicks) {
		throw "$Context changed during validation; validation fails closed."
	}
}

function Copy-StableFile([object] $ExpectedSource, [string] $DestinationPath, [string] $Context) {
	Assert-FileUnchanged $ExpectedSource $Context
	if (Test-Path -LiteralPath $DestinationPath) { throw "$Context snapshot path '$DestinationPath' already exists; validation fails closed." }
	$SourceStream = [IO.File]::Open($ExpectedSource.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$DestinationStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try { $SourceStream.CopyTo($DestinationStream) }
		finally { $DestinationStream.Dispose() }
	}
	finally { $SourceStream.Dispose() }
	Assert-FileUnchanged $ExpectedSource $Context
	$Staged = Read-StableFileSnapshot "$Context immutable snapshot" $DestinationPath
	if ($Staged.SizeBytes -ne $ExpectedSource.SizeBytes -or $Staged.Sha256 -cne $ExpectedSource.Sha256) {
		throw "$Context immutable snapshot does not match its source bytes."
	}
	return $Staged
}

function Get-InventorySourceFiles([string] $Directory, [string] $TargetName) {
	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
		throw "$TargetName cooked inventory directory is missing at '$Directory'; validation fails closed."
	}
	$ResolvedDirectory = (Resolve-Path -LiteralPath $Directory).Path
	$Directories = @(Get-ChildItem -LiteralPath $ResolvedDirectory -Directory -Force)
	if ($Directories.Count -gt 0) { throw "$TargetName cooked inventory contains unsupported subdirectories; validation fails closed." }
	$Files = @(Get-ChildItem -LiteralPath $ResolvedDirectory -File -Force | Sort-Object Name)
	foreach ($File in $Files) {
		if ($File.Name -cne 'AssetRegistry.bin' -and $File.Name -cne 'inventory-manifest.json' -and $File.Name -cnotmatch '^Page_\d{5}\.txt$') {
			throw "$TargetName cooked inventory contains unsupported file '$($File.Name)'; validation fails closed."
		}
	}
	foreach ($RequiredName in @('AssetRegistry.bin','inventory-manifest.json')) {
		if (@($Files | Where-Object { $_.Name -ceq $RequiredName }).Count -ne 1) { throw "$TargetName staged cooked registry evidence is missing required file '$RequiredName'; validation fails closed." }
	}
	if (@($Files | Where-Object { $_.Name -cmatch '^Page_\d{5}\.txt$' }).Count -eq 0) { throw "$TargetName cooked inventory contains no Page_*.txt files; validation fails closed." }
	return [pscustomobject]@{ Directory=$ResolvedDirectory; Files=$Files }
}

function New-InventorySnapshot([string] $Directory, [string] $TargetName, [string] $Destination) {
	$Source = Get-InventorySourceFiles $Directory $TargetName
	New-Item -ItemType Directory -Path $Destination | Out-Null
	$Identities = [System.Collections.Generic.List[object]]::new()
	foreach ($File in $Source.Files) {
		$Identity = Read-StableFileSnapshot "$TargetName cooked inventory '$($File.Name)'" $File.FullName
		[void](Copy-StableFile $Identity (Join-Path $Destination $File.Name) "$TargetName cooked inventory '$($File.Name)'")
		$Identities.Add($Identity)
	}
	$After = Get-InventorySourceFiles $Source.Directory $TargetName
	$BeforeNames = @($Source.Files.Name)
	$AfterNames = @($After.Files.Name)
	if (($BeforeNames -join "`0") -cne ($AfterNames -join "`0")) { throw "$TargetName cooked inventory file set changed while it was snapshotted; validation fails closed." }
	return [pscustomobject]@{ SourceDirectory=$Source.Directory; Directory=$Destination; SourceFiles=@($Identities); FileNames=$BeforeNames }
}

function Assert-InventorySnapshotUnchanged([object] $Snapshot, [string] $TargetName) {
	$Current = Get-InventorySourceFiles $Snapshot.SourceDirectory $TargetName
	if ((@($Current.Files.Name) -join "`0") -cne (@($Snapshot.FileNames) -join "`0")) { throw "$TargetName cooked inventory file set changed during validation; validation fails closed." }
	foreach ($Identity in $Snapshot.SourceFiles) { Assert-FileUnchanged $Identity "$TargetName cooked inventory '$([IO.Path]::GetFileName($Identity.Path))'" }
}

function Test-PathInsideDirectory([string] $Path, [string] $Directory) {
	$ResolvedPath = [IO.Path]::GetFullPath($Path)
	$ResolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	return [string]::Equals($ResolvedPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $ResolvedDirectory, [StringComparison]::OrdinalIgnoreCase) -or
		$ResolvedPath.StartsWith(($ResolvedDirectory + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OutputPathHasNoReparsePoint([string] $Path) {
	# Lexical containment cannot see junctions or symbolic links, so every
	# existing component of the output path must be a plain file or directory.
	for ($Current = $Path; -not [string]::IsNullOrEmpty($Current); $Current = [IO.Path]::GetDirectoryName($Current)) {
		if (-not (Test-Path -LiteralPath $Current)) { continue }
		if (([IO.File]::GetAttributes($Current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "OutputPath '$Path' traverses reparse point '$Current'; validation fails closed."
		}
	}
}

function Open-OutputAncestorHolds([string] $Directory) {
	# Directory handles with list access and no delete sharing make every
	# ancestor unrenameable until release. An empty held directory can still be
	# converted to a mount point in place, so publication additionally proves the
	# pending file's location through its own handle (see PublishInHeldDirectory).
	if (-not ('AethelnOutputPublicationNative' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class AethelnOutputPublicationNative {
	[StructLayout(LayoutKind.Sequential)]
	public struct FileInformation {
		public uint FileAttributes;
		public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
		public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
		public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
		public uint VolumeSerialNumber;
		public uint FileSizeHigh;
		public uint FileSizeLow;
		public uint NumberOfLinks;
		public uint FileIndexHigh;
		public uint FileIndexLow;
	}
	[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
	[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
	[DllImport("kernel32.dll", SetLastError = true)]
	static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
	[StructLayout(LayoutKind.Sequential)]
	struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
	[DllImport("ntdll.dll")]
	static extern int NtSetInformationFile(SafeFileHandle handle, out IoStatusBlock status, IntPtr information, uint length, int informationClass);

	static string FinalPath(SafeFileHandle handle) {
		StringBuilder path = new StringBuilder(32768);
		uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
		if (length == 0 || length >= path.Capacity) { throw new IOException("final path is unavailable (Win32 error " + Marshal.GetLastWin32Error() + ")"); }
		return path.ToString();
	}

	static void RequirePlainDirectory(SafeFileHandle handle) {
		FileInformation information;
		if (!GetFileInformationByHandle(handle, out information)) { throw new IOException("held output parent identity is unavailable (Win32 error " + Marshal.GetLastWin32Error() + ")"); }
		if ((information.FileAttributes & 0x400) != 0 || (information.FileAttributes & 0x10) == 0) { throw new IOException("held output parent is no longer a plain directory"); }
	}

	static void RequireLocation(SafeFileHandle handle, string parentFinalPath, string name) {
		string expected = parentFinalPath.TrimEnd('\\') + "\\" + name;
		string actual = FinalPath(handle);
		if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) { throw new IOException("evidence handle resolves to '" + actual + "' instead of '" + expected + "'"); }
	}

	// FileRenameInformation with the held parent as RootDirectory and a bare
	// name renames the open file object relative to that directory object; no
	// path is resolved through any ancestor or the process current directory.
	static void RenameInPlace(SafeFileHandle handle, SafeFileHandle root, string name) {
		int rootOffset = IntPtr.Size;
		int lengthOffset = rootOffset + IntPtr.Size;
		int nameOffset = lengthOffset + 4;
		byte[] nameBytes = Encoding.Unicode.GetBytes(name);
		int size = nameOffset + nameBytes.Length + 2;
		IntPtr buffer = Marshal.AllocHGlobal(size);
		try {
			for (int index = 0; index < size; index++) { Marshal.WriteByte(buffer, index, 0); }
			Marshal.WriteByte(buffer, 0, 1);
			Marshal.WriteIntPtr(buffer, rootOffset, root.DangerousGetHandle());
			Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
			Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
			IoStatusBlock status;
			int result = NtSetInformationFile(handle, out status, buffer, (uint)size, 10);
			if (result != 0) { throw new IOException("rename by handle failed (NTSTATUS 0x" + result.ToString("X8") + ")"); }
		}
		finally { Marshal.FreeHGlobal(buffer); }
	}

	static void DeleteByHandle(SafeFileHandle handle) {
		IntPtr buffer = Marshal.AllocHGlobal(4);
		try { Marshal.WriteInt32(buffer, 1); SetFileInformationByHandle(handle, 4, buffer, 4); }
		finally { Marshal.FreeHGlobal(buffer); }
	}

	static byte[] Sha256(byte[] bytes) { using (SHA256 hasher = SHA256.Create()) { return hasher.ComputeHash(bytes); } }

	// Creates the pending file by handle inside the held parent, proves its
	// location through that handle, and renames that exact file object into
	// place. A non-empty directory cannot become a mount point, and any failure
	// deletes only the file object this call created.
	public static void PublishInHeldDirectory(SafeFileHandle parent, string parentPath, string pendingName, string outputName, byte[] bytes) {
		RequirePlainDirectory(parent);
		string parentFinalPath = FinalPath(parent);
		// GENERIC_READ|GENERIC_WRITE|DELETE, share read only, CREATE_NEW, normal attributes.
		SafeFileHandle pending = CreateFileW(Path.Combine(parentPath, pendingName), 0xC0010000, 0x1, IntPtr.Zero, 1, 0x80, IntPtr.Zero);
		if (pending.IsInvalid) { throw new IOException("pending evidence could not be created (Win32 error " + Marshal.GetLastWin32Error() + ")"); }
		using (FileStream stream = new FileStream(pending, FileAccess.ReadWrite)) {
			try {
				RequireLocation(stream.SafeFileHandle, parentFinalPath, pendingName);
				stream.Write(bytes, 0, bytes.Length);
				stream.Flush(true);
				RequirePlainDirectory(parent);
				RequireLocation(stream.SafeFileHandle, parentFinalPath, pendingName);
				RenameInPlace(stream.SafeFileHandle, parent, outputName);
				RequireLocation(stream.SafeFileHandle, parentFinalPath, outputName);
				stream.Position = 0;
				byte[] published;
				using (SHA256 hasher = SHA256.Create()) { published = hasher.ComputeHash(stream); }
				if (Convert.ToBase64String(published) != Convert.ToBase64String(Sha256(bytes))) { throw new IOException("published evidence bytes differ from the validated evidence"); }
			}
			catch {
				DeleteByHandle(stream.SafeFileHandle);
				throw;
			}
		}
	}
}
'@
	}
	$Components = [System.Collections.Generic.List[string]]::new()
	for ($Current = [IO.Path]::GetFullPath($Directory); -not [string]::IsNullOrEmpty([IO.Path]::GetDirectoryName($Current)); $Current = [IO.Path]::GetDirectoryName($Current)) { $Components.Insert(0, $Current) }
	if ($Components.Count -eq 0) { $Components.Add([IO.Path]::GetFullPath($Directory)) }
	$Holds = [System.Collections.Generic.List[Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
	try {
		foreach ($Component in $Components) {
			# FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES, share read|write only, backup semantics, open the reparse point itself.
			$Handle = [AethelnOutputPublicationNative]::CreateFileW($Component, 0x81, 0x3, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
			if ($Handle.IsInvalid) { throw "OutputPath ancestor '$Component' could not be held for publication (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())); validation fails closed." }
			$Holds.Add($Handle)
			$Information = New-Object AethelnOutputPublicationNative+FileInformation
			if (-not [AethelnOutputPublicationNative]::GetFileInformationByHandle($Handle, [ref] $Information)) { throw "OutputPath ancestor '$Component' identity could not be read; validation fails closed." }
			if (($Information.FileAttributes -band 0x400) -ne 0) { throw "OutputPath traverses reparse point '$Component'; validation fails closed." }
			if (($Information.FileAttributes -band 0x10) -eq 0) { throw "OutputPath ancestor '$Component' is not a directory; validation fails closed." }
		}
	}
	catch {
		foreach ($Hold in $Holds) { $Hold.Dispose() }
		throw
	}
	return ,$Holds
}

function Open-InputLocks([object[]] $Identities) {
	# Read handles without write/delete sharing make the input bytes unwritable
	# through any alias (hardlink, junction, or later swap) until release.
	$Locks = [System.Collections.Generic.List[IO.FileStream]]::new()
	try {
		foreach ($Identity in $Identities) { $Locks.Add([IO.File]::Open($Identity.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)) }
	}
	catch {
		foreach ($Lock in $Locks) { $Lock.Dispose() }
		throw
	}
	return ,$Locks
}

function Get-StringSha256([string] $Value) {
	$Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
}

function Assert-LowerSha256([object] $Value, [string] $Context) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context must be a lowercase SHA-256 digest." }
}

function Assert-ArtifactDescriptor([object] $Descriptor, [string[]] $RequiredFields, [string] $Context) {
	Assert-ClosedProperties $Descriptor $RequiredFields $Context
	if (-not (Test-NonBlankJsonString $Descriptor.path) -or
		([string]$Descriptor.path).Contains(':') -or
		([string]$Descriptor.path).StartsWith('/') -or
		([string]$Descriptor.path).Contains('\') -or
		[string]$Descriptor.path -match '(?:^|/)\.\.(?:/|$)') {
		throw "$Context.path must use canonical repository-relative forward-slash form."
	}
	if (-not (Test-JsonInteger $Descriptor.size_bytes) -or $Descriptor.size_bytes -le 0) { throw "$Context.size_bytes must be a positive JSON integer." }
	Assert-LowerSha256 $Descriptor.sha256 "$Context.sha256"
	if (-not (Test-NonBlankJsonString $Descriptor.build_id)) { throw "$Context.build_id must be a non-blank string." }
}

function Assert-Boolean([object] $Value, [string] $Context) {
	if ($Value -isnot [bool]) { throw "$Context must be a JSON boolean." }
}

function Assert-Equal([object] $Actual, [object] $Expected, [string] $Context) {
	if ($Actual -is [string] -and $Expected -is [string]) {
		if ([string]$Actual -cne [string]$Expected) { throw "$Context mismatch: expected '$Expected' but found '$Actual'." }
		return
	}
	if ($Actual -ne $Expected) { throw "$Context mismatch: expected '$Expected' but found '$Actual'." }
}

function Assert-LifecycleContentIdentity([object] $Identity, [object] $IntakeAsset, [string] $Context) {
	if ($Identity.stable_id -isnot [string] -or $Identity.stable_id -cnotmatch '^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+$') { throw "$Context.stable_id is malformed." }
	if (-not (Test-JsonInteger $Identity.content_version) -or $Identity.content_version -lt 1) { throw "$Context.content_version must be a positive JSON integer." }
	Assert-LowerSha256 $Identity.content_sha256 "$Context.content_sha256"
	foreach ($Field in @('stable_id','content_version','content_sha256')) { Assert-Equal $Identity.$Field $IntakeAsset.$Field "$Context.$Field" }
}

function Assert-LifecycleEvidence([object] $Evidence, [object] $IntakeAsset, [string] $SourceApproval, [string] $Context) {
	if (@('temporary_prototype','runtime_candidate','production_approved') -cnotcontains $IntakeAsset.lifecycle_state) { throw "$Context has unsupported runtime lifecycle_state '$($IntakeAsset.lifecycle_state)'." }
	Assert-ClosedProperties $Evidence @('content_identity','temporary_prototype','runtime_candidate','production_approval') $Context -CaseSensitive
	Assert-ClosedProperties $Evidence.content_identity @('stable_id','content_version','content_sha256') "$Context.content_identity" -CaseSensitive
	Assert-LifecycleContentIdentity $Evidence.content_identity $IntakeAsset "$Context.content_identity"
	foreach ($Field in @('temporary_prototype','runtime_candidate','production_approval')) {
		if (-not (Test-JsonArray $Evidence.$Field)) { throw "$Context.$Field must be a JSON array." }
		if (@($Evidence.$Field).Count -gt 1) { throw "$Context.$Field must contain at most one evidence record." }
	}
	$Temporary = @($Evidence.temporary_prototype)
	$Candidate = @($Evidence.runtime_candidate)
	$Production = @($Evidence.production_approval)
	if ($IntakeAsset.lifecycle_state -ceq 'temporary_prototype') {
		if ($Temporary.Count -ne 1 -or $Candidate.Count -ne 0 -or $Production.Count -ne 0 -or $SourceApproval -cne 'temporary_prototype_only') { throw "$Context has invalid temporary-only evidence or source approval." }
		Assert-ClosedProperties $Temporary[0] @('owner','approval_record','recovery_trigger','may_be_runtime_candidate') "$Context.temporary_prototype[0]" -CaseSensitive
		foreach ($Field in @('owner','approval_record','recovery_trigger')) {
			if (-not (Test-NonBlankJsonString $Temporary[0].$Field)) { throw "$Context.temporary_prototype[0].$Field must be a non-blank string." }
		}
		Assert-Boolean $Temporary[0].may_be_runtime_candidate "$Context.temporary_prototype[0].may_be_runtime_candidate"
		if ($Temporary[0].may_be_runtime_candidate) { throw "$Context temporary evidence cannot be promotion-capable." }
		return
	}
	if ($Temporary.Count -ne 0 -or $Candidate.Count -ne 1) { throw "$Context requires runtime-candidate evidence and no temporary evidence." }
	Assert-ClosedProperties $Candidate[0] @('review_revision','reviewer','approval_record','stable_id','content_version','content_sha256') "$Context.runtime_candidate[0]" -CaseSensitive
	Assert-LifecycleContentIdentity $Candidate[0] $IntakeAsset "$Context.runtime_candidate[0]"
	foreach ($Field in @('reviewer','approval_record')) {
		if (-not (Test-NonBlankJsonString $Candidate[0].$Field)) { throw "$Context.runtime_candidate[0].$Field must be a non-blank string." }
	}
	if ($Candidate[0].review_revision -isnot [string] -or $Candidate[0].review_revision -cnotmatch '^[0-9a-f]{40}$') { throw "$Context.runtime_candidate[0].review_revision must be a lowercase Git revision." }
	if ($IntakeAsset.lifecycle_state -ceq 'runtime_candidate') {
		if ($Production.Count -ne 0 -or $SourceApproval -cne 'runtime_candidate_approved') { throw "$Context runtime-candidate evidence conflicts with source approval." }
		return
	}
	if ($Production.Count -ne 1 -or $SourceApproval -cne 'production_approved') { throw "$Context production evidence is missing or conflicts with source approval." }
	Assert-ClosedProperties $Production[0] @('candidate_review_revision','candidate_approval_record','production_revision','reviewer','approval_record','stable_id','content_version','content_sha256') "$Context.production_approval[0]" -CaseSensitive
	Assert-LifecycleContentIdentity $Production[0] $IntakeAsset "$Context.production_approval[0]"
	foreach ($Field in @('candidate_review_revision','candidate_approval_record','reviewer','approval_record')) {
		if (-not (Test-NonBlankJsonString $Production[0].$Field)) { throw "$Context.production_approval[0].$Field must be a non-blank string." }
	}
	if ($Production[0].production_revision -isnot [string] -or $Production[0].production_revision -cnotmatch '^[0-9a-f]{40}$') { throw "$Context.production_approval[0].production_revision must be a lowercase Git revision." }
	Assert-Equal $Production[0].candidate_review_revision $Candidate[0].review_revision "$Context.production_approval[0].candidate_review_revision"
	Assert-Equal $Production[0].candidate_approval_record $Candidate[0].approval_record "$Context.production_approval[0].candidate_approval_record"
}

function Read-CookedInventory([string] $Directory, [string] $TargetName) {
	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
		throw "$TargetName cooked inventory directory is missing at '$Directory'; validation fails closed."
	}
	$Pages = @(Get-ChildItem -LiteralPath $Directory -File -Filter 'Page_*.txt' | Sort-Object Name)
	if ($Pages.Count -eq 0) { throw "$TargetName cooked inventory '$Directory' contains no Page_*.txt files; validation fails closed." }
	for ($PageIndex = 0; $PageIndex -lt $Pages.Count; $PageIndex++) {
		$ExpectedPageName = 'Page_{0:D5}.txt' -f $PageIndex
		if ($Pages[$PageIndex].Name -cne $ExpectedPageName) {
			throw "$TargetName cooked inventory '$Directory' has a non-contiguous page sequence: expected '$ExpectedPageName' but found '$($Pages[$PageIndex].Name)'."
		}
	}
	$PageEvidence = @(
		foreach ($Page in $Pages) {
			[ordered]@{
				name = $Page.Name
				sha256 = (Get-FileHash -LiteralPath $Page.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
			}
		}
	)
	$Lines = @($Pages | ForEach-Object { Get-Content -LiteralPath $_.FullName })
	$BeginMarkers = @($Lines | Select-String '^--- Begin Cached(?:Assets|Packages)ByPackageName ---$')
	$EndMarkers = @($Lines | Select-String '^--- End Cached(?:Assets|Packages)ByPackageName : (?<EntryCount>\d+) entries ---$')
	if ($BeginMarkers.Count -ne 1 -or $EndMarkers.Count -ne 1) {
		throw "$TargetName cooked inventory '$Directory' must contain exactly one complete CachedAssetsByPackageName section; found $($BeginMarkers.Count) begin and $($EndMarkers.Count) end markers."
	}
	$Begin = $BeginMarkers[0]
	$End = $EndMarkers[0]
	if ($End.LineNumber -le $Begin.LineNumber) { throw "$TargetName cooked inventory '$Directory' has its inventory end marker before its begin marker." }
	for ($Index = 0; $Index -lt ($Begin.LineNumber - 1); $Index++) {
		if (-not [string]::IsNullOrWhiteSpace($Lines[$Index])) { throw "$TargetName cooked inventory '$Directory' has nonblank data before the inventory begin marker at line $($Index + 1)." }
	}
	for ($Index = $End.LineNumber; $Index -lt $Lines.Count; $Index++) {
		if (-not [string]::IsNullOrWhiteSpace($Lines[$Index])) { throw "$TargetName cooked inventory '$Directory' has nonblank data after the inventory end marker at line $($Index + 1)." }
	}
	$DeclaredEntryCount = [long]$End.Matches[0].Groups['EntryCount'].Value
	$Packages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$Index = $Begin.LineNumber
	while ($Index -lt ($End.LineNumber - 1)) {
		$HeaderLine = $Lines[$Index]
		if ($HeaderLine -match '^\t\t/') {
			throw "$TargetName cooked inventory '$Directory' has an item detail without an associated package header at line $($Index + 1): '$HeaderLine'."
		}
		if ($HeaderLine -cnotmatch '^\t(?<Package>/[^\t ]+) : (?<ItemCount>\d+) item\(s\)$') {
			throw "$TargetName cooked inventory '$Directory' has malformed package data at line $($Index + 1): '$HeaderLine'."
		}
		$PackagePath = [string]$Matches['Package']
		[long] $DeclaredItemCount = 0
		if (-not [long]::TryParse([string]$Matches['ItemCount'], [ref]$DeclaredItemCount) -or $DeclaredItemCount -le 0) {
			throw "$TargetName cooked inventory '$Directory' package '$PackagePath' must declare a positive item count."
		}
		if ($Packages.Contains($PackagePath)) {
			throw "$TargetName cooked inventory '$Directory' contains duplicate package header '$PackagePath'."
		}

		[long] $ValidatedItemCount = 0
		while ($ValidatedItemCount -lt $DeclaredItemCount) {
			$DetailIndex = $Index + 1 + $ValidatedItemCount
			if ($DetailIndex -ge ($End.LineNumber - 1) -or $Lines[$DetailIndex] -cnotmatch '^\t\t/[^\s]+$') {
				throw "$TargetName cooked inventory '$Directory' package '$PackagePath' declares $DeclaredItemCount item(s) but has only $ValidatedItemCount associated item row(s)."
			}
			$ExpectedDetailPrefix = "`t`t${PackagePath}."
			if (-not $Lines[$DetailIndex].StartsWith($ExpectedDetailPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
				throw "$TargetName cooked inventory '$Directory' item detail '$($Lines[$DetailIndex].Trim())' does not belong to package '$PackagePath'."
			}
			$ValidatedItemCount++
		}

		[void]$Packages.Add($PackagePath)
		$Index += 1 + $DeclaredItemCount
	}
	if ($Packages.Count -eq 0) { throw "$TargetName cooked inventory '$Directory' contains no packages; validation fails closed." }
	if ($Packages.Count -ne $DeclaredEntryCount) {
		throw "$TargetName cooked inventory '$Directory' declares $DeclaredEntryCount entries but parsed $($Packages.Count) unique package keys; validation fails closed."
	}
	return [pscustomobject]@{ Packages = $Packages; Pages = $PageEvidence; Directory = (Resolve-Path -LiteralPath $Directory).Path }
}

function Read-InventoryManifest([object] $Inventory, [string] $TargetName, [hashtable] $Expected) {
	$ManifestPath = Join-Path $Inventory.Directory 'inventory-manifest.json'
	$Manifest = Read-RequiredJson $ManifestPath "$TargetName cooked inventory manifest"
	$Fields = @(
		'schema_id','schema_version','capture_mode','source_revision','repository_clean','engine_revision','engine_tag',
		'engine_binary_sha256','build_version_sha256','target','platform','configuration','toolchain_identity','toolchain_sha256',
		'project_sha256','policy_sha256','intake_sha256','content_validation_report_sha256','build_provenance_sha256',
		'cooked_registry','cook_command_sha256','capture_command_sha256','started_utc','finished_utc','package_count','pages'
	)
	Assert-ClosedProperties $Manifest $Fields "$TargetName cooked inventory manifest"
	Assert-Equal $Manifest.schema_id 'aetheln.cooked-inventory-manifest' "$TargetName manifest schema_id"
	if (-not (Test-JsonInteger $Manifest.schema_version) -or $Manifest.schema_version -ne 2) { throw "$TargetName manifest schema_version must be JSON integer 2." }
	$AllowedMode = if ($AllowTestEvidence) { @('live_cooked_registry','test_fixture') } else { @('live_cooked_registry') }
	if ($Manifest.capture_mode -isnot [string] -or $AllowedMode -cnotcontains $Manifest.capture_mode) { throw "$TargetName manifest capture_mode '$($Manifest.capture_mode)' is not admissible." }
	Assert-Boolean $Manifest.repository_clean "$TargetName manifest repository_clean"
	if (-not $Manifest.repository_clean) { throw "$TargetName manifest must bind a clean repository." }
	foreach ($Field in @('engine_binary_sha256','build_version_sha256','toolchain_sha256','project_sha256','policy_sha256','intake_sha256','content_validation_report_sha256','build_provenance_sha256','cook_command_sha256','capture_command_sha256')) {
		Assert-LowerSha256 $Manifest.$Field "$TargetName manifest $Field"
	}
	$RegistryFields = @('source_path','staged_path','size_bytes','sha256','target','platform','cook_platform','build_provenance_sha256','source_revision')
	Assert-ClosedProperties $Manifest.cooked_registry $RegistryFields "$TargetName manifest cooked_registry"
	if (-not (Test-NonBlankJsonString $Manifest.cooked_registry.source_path)) { throw "$TargetName manifest cooked_registry.source_path must be a non-blank string." }
	Assert-Equal $Manifest.cooked_registry.staged_path 'AssetRegistry.bin' "$TargetName manifest cooked_registry.staged_path"
	if (-not (Test-JsonInteger $Manifest.cooked_registry.size_bytes) -or $Manifest.cooked_registry.size_bytes -lt 1) { throw "$TargetName manifest cooked_registry.size_bytes must be a positive JSON integer." }
	foreach ($Field in @('sha256','build_provenance_sha256')) { Assert-LowerSha256 $Manifest.cooked_registry.$Field "$TargetName manifest cooked_registry.$Field" }
	$ExpectedCookPlatform = if ($TargetName -ceq 'Client') { 'WindowsClient' } else { 'LinuxServer' }
	$ExpectedSourcePath = if ($TargetName -ceq 'Client') { 'Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin' } else { 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin' }
	if (-not $AllowTestEvidence) { Assert-Equal $Manifest.cooked_registry.source_path $ExpectedSourcePath "$TargetName manifest cooked_registry.source_path" }
	Assert-Equal $Manifest.cooked_registry.target $Expected.target "$TargetName manifest cooked_registry.target"
	Assert-Equal $Manifest.cooked_registry.platform $Expected.platform "$TargetName manifest cooked_registry.platform"
	Assert-Equal $Manifest.cooked_registry.cook_platform $ExpectedCookPlatform "$TargetName manifest cooked_registry.cook_platform"
	Assert-Equal $Manifest.cooked_registry.build_provenance_sha256 $Expected.build_provenance_sha256 "$TargetName manifest cooked_registry.build_provenance_sha256"
	Assert-Equal $Manifest.cooked_registry.source_revision $Expected.source_revision "$TargetName manifest cooked_registry.source_revision"
	$StagedRegistryPath = [IO.Path]::GetFullPath((Join-Path $Inventory.Directory ([string]$Manifest.cooked_registry.staged_path)))
	$ExpectedStagedRegistryPath = [IO.Path]::GetFullPath((Join-Path $Inventory.Directory 'AssetRegistry.bin'))
	if (-not [string]::Equals($StagedRegistryPath, $ExpectedStagedRegistryPath, [StringComparison]::OrdinalIgnoreCase)) { throw "$TargetName manifest cooked_registry.staged_path escapes its inventory directory." }
	$StagedRegistry = Read-StableFileSnapshot "$TargetName staged cooked registry" $StagedRegistryPath
	Assert-Equal ([long]$Manifest.cooked_registry.size_bytes) ([long]$StagedRegistry.SizeBytes) "$TargetName manifest cooked_registry.size_bytes"
	Assert-Equal $Manifest.cooked_registry.sha256 $StagedRegistry.Sha256 "$TargetName manifest cooked_registry.sha256"
	$ProducerReceipt = $ProducerRegistryReceipts[$TargetName.ToLowerInvariant()]
	if ([long]$Manifest.cooked_registry.size_bytes -ne [long]$ProducerReceipt.sizeBytes -or [string]$Manifest.cooked_registry.sha256 -cne [string]$ProducerReceipt.sha256) {
		throw "$TargetName manifest cooked_registry bytes do not match the producer registry receipt recorded at cook time; validation fails closed."
	}
	$Started = ConvertFrom-RequiredUtcTimestamp $Manifest.started_utc "$TargetName manifest started_utc"
	$Finished = ConvertFrom-RequiredUtcTimestamp $Manifest.finished_utc "$TargetName manifest finished_utc"
	if ($Finished -lt $Started) { throw "$TargetName manifest finished_utc precedes started_utc." }
	if (-not (Test-JsonInteger $Manifest.package_count) -or $Manifest.package_count -lt 1) { throw "$TargetName manifest package_count must be a positive JSON integer." }
	Assert-Equal ([long]$Manifest.package_count) ([long]$Inventory.Packages.Count) "$TargetName manifest package_count"
	if (-not (Test-JsonArray $Manifest.pages)) { throw "$TargetName manifest pages must be a JSON array." }
	$ManifestPages = @($Manifest.pages)
	if ($ManifestPages.Count -ne @($Inventory.Pages).Count) { throw "$TargetName manifest page count does not match the captured inventory." }
	for ($Index = 0; $Index -lt $ManifestPages.Count; $Index++) {
		Assert-ClosedProperties $ManifestPages[$Index] @('name','sha256') "$TargetName manifest page[$Index]"
		Assert-LowerSha256 $ManifestPages[$Index].sha256 "$TargetName manifest page[$Index].sha256"
		Assert-Equal $ManifestPages[$Index].name $Inventory.Pages[$Index].name "$TargetName manifest page[$Index].name"
		Assert-Equal $ManifestPages[$Index].sha256 $Inventory.Pages[$Index].sha256 "$TargetName manifest page '$($Inventory.Pages[$Index].name)' digest"
	}
	foreach ($Name in $Expected.Keys) { Assert-Equal $Manifest.$Name $Expected[$Name] "$TargetName manifest $Name" }
	return [pscustomobject]@{ Value=$Manifest; Path=$ManifestPath; Sha256=(Get-LowerSha256 $ManifestPath) }
}

$SourceContentValidationReportPath = [IO.Path]::GetFullPath($ContentValidationReportPath)
$SourcePolicyPath = [IO.Path]::GetFullPath($PolicyPath)
$SourceRuntimeIntakePath = [IO.Path]::GetFullPath($RuntimeIntakePath)
$SourceBuildProvenancePath = [IO.Path]::GetFullPath($BuildProvenancePath)
$SourceClientCookedInventoryDirectory = [IO.Path]::GetFullPath($ClientCookedInventoryDirectory)
$SourceServerCookedInventoryDirectory = [IO.Path]::GetFullPath($ServerCookedInventoryDirectory)
$ResolvedOutput = $null
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
	$ResolvedOutput = [IO.Path]::GetFullPath($OutputPath)
	if (Test-Path -LiteralPath $ResolvedOutput -PathType Container) { throw "OutputPath '$ResolvedOutput' must identify a file, not a directory." }
	foreach ($InputPath in @($SourceContentValidationReportPath,$SourcePolicyPath,$SourceRuntimeIntakePath,$SourceBuildProvenancePath)) {
		if ([string]::Equals($ResolvedOutput, $InputPath, [StringComparison]::OrdinalIgnoreCase)) { throw "OutputPath '$ResolvedOutput' must not overwrite input evidence." }
	}
	if ((Test-PathInsideDirectory $ResolvedOutput $SourceClientCookedInventoryDirectory) -or (Test-PathInsideDirectory $ResolvedOutput $SourceServerCookedInventoryDirectory)) {
		throw "OutputPath '$ResolvedOutput' must not overwrite or alter a cooked-inventory input evidence directory."
	}
	Assert-OutputPathHasNoReparsePoint $ResolvedOutput
}

$InputSnapshotRoot = Join-Path ([IO.Path]::GetTempPath()) ("AethelnContentCookInput-{0}" -f [guid]::NewGuid().ToString('N'))
$OutputAncestorHolds = @()
New-Item -ItemType Directory -Path $InputSnapshotRoot | Out-Null
try {
$ContentReportSource = Read-StableFileSnapshot 'Content validation report' $SourceContentValidationReportPath
$PolicySource = Read-StableFileSnapshot 'Governed asset intake policy' $SourcePolicyPath
$IntakeSource = Read-StableFileSnapshot 'Governed runtime asset intake registry' $SourceRuntimeIntakePath
$BuildProvenanceSource = Read-StableFileSnapshot 'Build provenance' $SourceBuildProvenancePath
$SnapshotReportPath = Join-Path $InputSnapshotRoot 'content-validation-report.json'
$SnapshotPolicyPath = Join-Path $InputSnapshotRoot 'asset-intake-policy.json'
$SnapshotIntakePath = Join-Path $InputSnapshotRoot 'runtime-asset-intake.json'
$SnapshotBuildProvenancePath = Join-Path $InputSnapshotRoot 'build-provenance.json'
[void](Copy-StableFile $ContentReportSource $SnapshotReportPath 'Content validation report')
[void](Copy-StableFile $PolicySource $SnapshotPolicyPath 'Governed asset intake policy')
[void](Copy-StableFile $IntakeSource $SnapshotIntakePath 'Governed runtime asset intake registry')
[void](Copy-StableFile $BuildProvenanceSource $SnapshotBuildProvenancePath 'Build provenance')
$ClientInventorySnapshot = New-InventorySnapshot $SourceClientCookedInventoryDirectory 'Client' (Join-Path $InputSnapshotRoot 'client')
$ServerInventorySnapshot = New-InventorySnapshot $SourceServerCookedInventoryDirectory 'Server' (Join-Path $InputSnapshotRoot 'server')

function Assert-AllValidationInputsUnchanged {
	foreach ($Check in @(
		@{ Identity=$ContentReportSource; Context='Content validation report' },
		@{ Identity=$PolicySource; Context='Governed asset intake policy' },
		@{ Identity=$IntakeSource; Context='Governed runtime asset intake registry' },
		@{ Identity=$BuildProvenanceSource; Context='Build provenance' }
	)) { Assert-FileUnchanged $Check.Identity $Check.Context }
	Assert-InventorySnapshotUnchanged $ClientInventorySnapshot 'Client'
	Assert-InventorySnapshotUnchanged $ServerInventorySnapshot 'Server'
}

$Report = Read-RequiredJson $SnapshotReportPath 'Content validation report'
$Policy = Read-RequiredJson $SnapshotPolicyPath 'Governed asset intake policy'
$Intake = Read-RequiredJson $SnapshotIntakePath 'Governed runtime asset intake registry'
$BuildProvenance = Read-RequiredJson $SnapshotBuildProvenancePath 'Build provenance'
$ExpectedPolicySha256 = $PolicySource.Sha256
$ExpectedIntakeSha256 = $IntakeSource.Sha256
$ContentReportSha256 = $ContentReportSource.Sha256
$BuildProvenanceSha256 = $BuildProvenanceSource.Sha256
$ClientCookedInventoryDirectory = $ClientInventorySnapshot.Directory
$ServerCookedInventoryDirectory = $ServerInventorySnapshot.Directory
$UnresolvedQuantitativeBudgets = @($Policy.thresholds.unresolved_budgets | Where-Object { $_.value -ceq $Policy.thresholds.unresolved_value })
$HasUnresolvedQuantitativeThresholds = $UnresolvedQuantitativeBudgets.Count -gt 0

$IntakeFields = @('schema_id','schema_version','policy_schema_id','policy_schema_version','content_root','package_root','expected_asset_count','source_groups','assets')
Assert-ClosedProperties $Intake $IntakeFields 'Runtime asset intake registry'
Assert-Equal $Intake.schema_id 'aetheln.runtime-asset-intake' 'Runtime asset intake schema_id'
if (-not (Test-JsonInteger $Intake.schema_version) -or $Intake.schema_version -ne 1) { throw 'Runtime asset intake schema_version must be JSON integer 1.' }
Assert-Equal $Intake.policy_schema_id $Policy.schema_id 'Runtime asset intake policy_schema_id'
Assert-Equal $Intake.policy_schema_version $Policy.schema_version 'Runtime asset intake policy_schema_version'
Assert-Equal $Intake.content_root 'Content/' 'Runtime asset intake content_root'
Assert-Equal $Intake.package_root '/Game' 'Runtime asset intake package_root'
if (-not (Test-JsonArray $Intake.source_groups) -or @($Intake.source_groups).Count -eq 0) { throw 'Runtime asset intake source_groups must be a non-empty JSON array.' }
if (-not (Test-JsonArray $Intake.assets) -or @($Intake.assets).Count -eq 0) { throw 'Runtime asset intake assets must be a non-empty JSON array.' }
if (-not (Test-JsonInteger $Intake.expected_asset_count) -or $Intake.expected_asset_count -ne @($Intake.assets).Count) { throw 'Runtime asset intake expected_asset_count does not match its assets array.' }

$SourceGroupFields = @('id','author_or_provider','source_record','source_version','license_or_permission_evidence','modifications','generation_metadata_when_applicable','reviewer','approval_state','naming_owner','import_settings_record','reimport_settings_record')
$SourceGroupsById = @{}
foreach ($SourceGroup in @($Intake.source_groups)) {
	Assert-ClosedProperties $SourceGroup $SourceGroupFields 'Runtime asset intake source group'
	foreach ($Field in $SourceGroupFields) { if (-not (Test-NonBlankJsonString $SourceGroup.$Field)) { throw "Runtime asset intake source group field '$Field' must be a non-blank string." } }
	if ($SourceGroupsById.ContainsKey([string]$SourceGroup.id)) { throw "Runtime asset intake contains duplicate source group '$($SourceGroup.id)'." }
	$SourceGroupsById[[string]$SourceGroup.id] = $SourceGroup
}
$IntakeAssetFields = @('asset_path','repository_path','stable_id','content_version','audience','lifecycle_state','source_group_id','content_sha256','lifecycle_evidence')
$IntakeAssetsByPath = @{}
$IntakeStableIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($IntakeAsset in @($Intake.assets)) {
	Assert-ClosedProperties $IntakeAsset $IntakeAssetFields 'Runtime asset intake asset'
	if (@($IntakeAsset.PSObject.Properties.Name) -cnotcontains 'lifecycle_evidence') { throw "Runtime asset intake asset requires exact field 'lifecycle_evidence'." }
	if ($IntakeAsset.asset_path -isnot [string] -or $IntakeAsset.asset_path -cnotmatch '^/Game(?:/[^\s.]+)+$') { throw "Runtime asset intake asset_path '$($IntakeAsset.asset_path)' is malformed." }
	if ($IntakeAssetsByPath.ContainsKey(([string]$IntakeAsset.asset_path).ToLowerInvariant())) { throw "Runtime asset intake contains duplicate asset_path '$($IntakeAsset.asset_path)'." }
	if (-not $IntakeStableIds.Add([string]$IntakeAsset.stable_id)) { throw "Runtime asset intake contains duplicate stable_id '$($IntakeAsset.stable_id)'." }
	if (-not $SourceGroupsById.ContainsKey([string]$IntakeAsset.source_group_id)) { throw "Runtime asset intake asset '$($IntakeAsset.asset_path)' names unknown source_group_id '$($IntakeAsset.source_group_id)'." }
	Assert-LowerSha256 $IntakeAsset.content_sha256 "Runtime asset intake asset '$($IntakeAsset.asset_path)' content_sha256"
	if (-not (Test-JsonInteger $IntakeAsset.content_version) -or $IntakeAsset.content_version -lt 1) { throw "Runtime asset intake asset '$($IntakeAsset.asset_path)' content_version must be a positive JSON integer." }
	if (@($Policy.lifecycle_states) -cnotcontains $IntakeAsset.lifecycle_state) { throw "Runtime asset intake asset '$($IntakeAsset.asset_path)' has unsupported lifecycle_state '$($IntakeAsset.lifecycle_state)'." }
	if (@($Policy.audiences) -cnotcontains $IntakeAsset.audience) { throw "Runtime asset intake asset '$($IntakeAsset.asset_path)' has unsupported audience '$($IntakeAsset.audience)'." }
	Assert-LifecycleEvidence $IntakeAsset.lifecycle_evidence $IntakeAsset ([string]$SourceGroupsById[[string]$IntakeAsset.source_group_id].approval_state) "Runtime asset intake asset '$($IntakeAsset.asset_path)' lifecycle_evidence"
	$IntakeAssetsByPath[([string]$IntakeAsset.asset_path).ToLowerInvariant()] = $IntakeAsset
}

if ([int]$BuildProvenance.schemaVersion -ne 2) { throw 'Build provenance must use schemaVersion 2.' }
Assert-Boolean $BuildProvenance.source.clean 'Build provenance source.clean'
if (-not $BuildProvenance.source.clean) { throw 'Build provenance must bind a clean source tree.' }
Assert-Equal $BuildProvenance.build.clientTarget 'AethelnOnlineClient' 'Build provenance clientTarget'
Assert-Equal $BuildProvenance.build.clientPlatform 'Win64' 'Build provenance clientPlatform'
Assert-Equal $BuildProvenance.build.serverTarget 'AethelnOnlineServer' 'Build provenance serverTarget'
Assert-Equal $BuildProvenance.build.serverPlatform 'Linux' 'Build provenance serverPlatform'
foreach ($Field in @('sha256')) { Assert-LowerSha256 $BuildProvenance.tools.compiler.$Field "Build provenance compiler.$Field" }
Assert-LowerSha256 $BuildProvenance.tools.linuxCrossToolchain.compilerSha256 'Build provenance linuxCrossToolchain.compilerSha256'

$ReportFields = @($Policy.report.required_fields)
Assert-ClosedProperties $Report $ReportFields 'Content validation report'
if (-not (Test-NonBlankJsonString $Report.schema_id)) { throw 'Content validation report schema_id must be a non-blank string.' }
if (-not (Test-JsonInteger $Report.schema_version)) { throw 'Content validation report schema_version must be a JSON integer.' }
if ($Report.schema_id -cne $Policy.report.schema_id -or $Report.schema_version -ne $Policy.report.schema_version) {
	throw "Content validation report must use $($Policy.report.schema_id) schema version $($Policy.report.schema_version)."
}
$ReportContractVersion = [int]$Policy.report.schema_version
if (-not (Test-NonBlankJsonString $Report.result)) { throw 'Content validation report result must be a non-blank string.' }
if (@($Policy.report.allowed_results) -cnotcontains $Report.result) { throw "Content validation report result '$($Report.result)' is unsupported." }
foreach ($Field in @('revision', 'engine_identity', 'command')) {
	if ($Report.$Field -isnot [string]) { throw "Content validation report $Field must be a string." }
	if ([string]::IsNullOrWhiteSpace($Report.$Field)) { throw "Content validation report $Field is empty." }
}
if ($Report.audience -isnot [string]) { throw 'Content validation report audience must be a string.' }
if ($Report.audience -cne 'all') { throw "Content validation report audience must be 'all' for cross-target cook evidence." }
if ($Report.policy_sha256 -isnot [string] -or $Report.policy_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Content validation report policy_sha256 is malformed.' }
if ($Report.policy_sha256 -cne $ExpectedPolicySha256) { throw 'Content validation report policy_sha256 does not match the current governed policy.' }
Assert-LowerSha256 $Report.intake_sha256 'Content validation report intake_sha256'
if ($Report.intake_sha256 -cne $ExpectedIntakeSha256) { throw 'Content validation report intake_sha256 does not match the current governed runtime intake registry.' }
$ExecutionFields = @($Policy.report.execution_provenance_required_fields)
Assert-ClosedProperties $Report.execution_provenance $ExecutionFields 'Content validation report execution_provenance'
foreach ($Field in @('engine_revision','engine_tag','engine_binary_sha256','build_version_sha256','target','platform','configuration','compiler_sha256','resource_compiler_sha256','project_sha256','policy_sha256','intake_sha256','invocation_sha256','registry_source')) {
	if (-not (Test-NonBlankJsonString $Report.execution_provenance.$Field)) { throw "Content validation report execution_provenance.$Field must be a non-blank string." }
}
if ($ReportContractVersion -ge 2) {
	foreach ($Field in @('editor_build_command_sha256','editor_build_log_sha256','compiler_version','resource_compiler_version')) {
		if (-not (Test-NonBlankJsonString $Report.execution_provenance.$Field)) { throw "Content validation report execution_provenance.$Field must be a non-blank string." }
	}
}
Assert-Boolean $Report.execution_provenance.repository_clean 'Content validation report execution_provenance.repository_clean'
if (-not $Report.execution_provenance.repository_clean) { throw 'Content validation report execution_provenance must bind a clean repository.' }
$ExecutionHashFields = @('engine_binary_sha256','build_version_sha256','compiler_sha256','resource_compiler_sha256','project_sha256','policy_sha256','intake_sha256','invocation_sha256')
if ($ReportContractVersion -ge 2) { $ExecutionHashFields += @('editor_build_command_sha256','editor_build_log_sha256') }
foreach ($Field in $ExecutionHashFields) {
	Assert-LowerSha256 $Report.execution_provenance.$Field "Content validation report execution_provenance.$Field"
}
if ($ReportContractVersion -ge 2) {
	$ArtifactFields = @($Policy.report.artifact_descriptor_required_fields)
	Assert-ArtifactDescriptor $Report.execution_provenance.target_receipt $ArtifactFields 'Content validation report execution_provenance.target_receipt'
	Assert-ArtifactDescriptor $Report.execution_provenance.module_manifest $ArtifactFields 'Content validation report execution_provenance.module_manifest'
	Assert-Equal $Report.execution_provenance.target_receipt.path 'Binaries/Win64/AethelnOnlineEditor.target' 'Content validation target_receipt.path'
	Assert-Equal $Report.execution_provenance.module_manifest.path 'Binaries/Win64/UnrealEditor.modules' 'Content validation module_manifest.path'
	if (-not (Test-JsonArray $Report.execution_provenance.loaded_project_modules)) { throw 'Content validation report execution_provenance.loaded_project_modules must be a JSON array.' }
	$LoadedProjectModules = @($Report.execution_provenance.loaded_project_modules)
	$ExpectedModuleNames = @($Policy.report.loaded_project_module_names)
	if ($ExpectedModuleNames.Count -ne 2 -or $ExpectedModuleNames[0] -cne 'GameCore' -or $ExpectedModuleNames[1] -cne 'GameTests') {
		throw 'Content validation policy must require exactly GameCore then GameTests as loaded project modules.'
	}
	if ($LoadedProjectModules.Count -ne $ExpectedModuleNames.Count) { throw 'Content validation report must bind exactly GameCore then GameTests in loaded_project_modules.' }
	for ($ModuleIndex = 0; $ModuleIndex -lt $ExpectedModuleNames.Count; $ModuleIndex++) {
		$Module = $LoadedProjectModules[$ModuleIndex]
		$ModuleName = [string]$ExpectedModuleNames[$ModuleIndex]
		Assert-ClosedProperties $Module @($Policy.report.loaded_project_module_required_fields) "Content validation loaded project module $ModuleIndex"
		Assert-Equal $Module.name $ModuleName "Content validation loaded project module $ModuleIndex name"
		$ModuleDescriptor = [pscustomobject][ordered]@{ path=$Module.path; size_bytes=$Module.size_bytes; sha256=$Module.sha256; build_id=$Module.build_id }
		Assert-ArtifactDescriptor $ModuleDescriptor $ArtifactFields "Content validation loaded project module $ModuleName"
		Assert-Equal $Module.path "Binaries/Win64/UnrealEditor-$ModuleName.dll" "Content validation loaded project module $ModuleName path"
	}
	$SharedBuildId = [string]$Report.execution_provenance.target_receipt.build_id
	if ($Report.execution_provenance.module_manifest.build_id -cne $SharedBuildId -or
		$LoadedProjectModules[0].build_id -cne $SharedBuildId -or
		$LoadedProjectModules[1].build_id -cne $SharedBuildId) {
		throw 'Content validation target receipt, module manifest, GameCore, and GameTests must share one non-blank build_id.'
	}
}
Assert-Equal $Report.execution_provenance.policy_sha256 $ExpectedPolicySha256 'Content validation execution policy_sha256'
Assert-Equal $Report.execution_provenance.intake_sha256 $ExpectedIntakeSha256 'Content validation execution intake_sha256'
Assert-Equal $Report.execution_provenance.target 'AethelnOnlineEditor' 'Content validation execution target'
Assert-Equal $Report.execution_provenance.platform 'Win64' 'Content validation execution platform'
Assert-Equal $Report.execution_provenance.configuration 'Development' 'Content validation execution configuration'
if ($Report.revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Content validation report revision must be an exact lowercase Git commit.' }
if ($Report.execution_provenance.engine_revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Content validation execution engine_revision must be an exact lowercase Git commit.' }
Assert-Equal $Report.execution_provenance.engine_tag '5.8.1-release' 'Content validation execution engine_tag'
Assert-Equal $Report.engine_identity ("$($Report.execution_provenance.engine_tag)@$($Report.execution_provenance.engine_revision)") 'Content validation engine_identity'
if ($Report.execution_provenance.registry_source -cne 'live_asset_registry' -and -not ($AllowTestEvidence -and $Report.execution_provenance.registry_source -ceq 'test_snapshot')) { throw "Content validation registry_source '$($Report.execution_provenance.registry_source)' is not admissible for cook evidence." }
Assert-Equal $BuildProvenance.source.revision $Report.revision 'Build/content-validation source revision'
# Producer receipts are recorded right after each target's own cook; manifests
# must match them so a self-consistent manifest cannot vouch for other bytes.
if (@($BuildProvenance.build.PSObject.Properties.Name) -cnotcontains 'cookedRegistries') { throw 'Build provenance build.cookedRegistries producer registry receipts are missing; validation fails closed.' }
Assert-ClosedProperties $BuildProvenance.build.cookedRegistries @('client','server') 'Build provenance build.cookedRegistries' -CaseSensitive
$ProducerRegistryReceipts = @{}
foreach ($Kind in @('client','server')) {
	$Receipt = $BuildProvenance.build.cookedRegistries.$Kind
	$Context = "$Kind producer registry receipt"
	Assert-ClosedProperties $Receipt @('relativePath','sizeBytes','sha256','target','platform','cookPlatform','sourceRevision') $Context -CaseSensitive
	$ExpectedCookPlatform = if ($Kind -ceq 'client') { 'WindowsClient' } else { 'LinuxServer' }
	Assert-Equal $Receipt.cookPlatform $ExpectedCookPlatform "$Context cookPlatform"
	Assert-Equal $Receipt.target $(if ($Kind -ceq 'client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }) "$Context target"
	Assert-Equal $Receipt.platform $(if ($Kind -ceq 'client') { 'Win64' } else { 'Linux' }) "$Context platform"
	Assert-Equal $Receipt.relativePath "Saved/Cooked/$ExpectedCookPlatform/AethelnOnline/AssetRegistry.bin" "$Context relativePath"
	if ($Receipt.sourceRevision -isnot [string] -or -not $Receipt.sourceRevision.Equals([string]$BuildProvenance.source.revision, [StringComparison]::OrdinalIgnoreCase)) { throw "$Context sourceRevision '$($Receipt.sourceRevision)' does not match build revision '$($BuildProvenance.source.revision)'." }
	Assert-LowerSha256 $Receipt.sha256 "$Context sha256"
	if (-not (Test-JsonInteger $Receipt.sizeBytes) -or $Receipt.sizeBytes -lt 1) { throw "$Context sizeBytes must be a positive JSON integer." }
	$ProducerRegistryReceipts[$Kind] = $Receipt
}
Assert-Equal $BuildProvenance.source.projectSha256 $Report.execution_provenance.project_sha256 'Build/content-validation project_sha256'
Assert-Equal $BuildProvenance.build.configuration $Report.execution_provenance.configuration 'Build/content-validation configuration'
Assert-Equal $BuildProvenance.tools.unreal.repositoryRevision $Report.execution_provenance.engine_revision 'Build/content-validation engine_revision'
Assert-Equal $BuildProvenance.tools.unreal.buildVersionSha256 $Report.execution_provenance.build_version_sha256 'Build/content-validation build_version_sha256'
Assert-Equal $BuildProvenance.tools.compiler.sha256 $Report.execution_provenance.compiler_sha256 'Build/content-validation compiler_sha256'
Assert-Equal $BuildProvenance.tools.windowsSdk.resourceCompilerSha256 $Report.execution_provenance.resource_compiler_sha256 'Build/content-validation resource_compiler_sha256'
$StartedAt = ConvertFrom-RequiredUtcTimestamp $Report.started_utc 'Content validation report started_utc'
$FinishedAt = ConvertFrom-RequiredUtcTimestamp $Report.finished_utc 'Content validation report finished_utc'
if ($FinishedAt -lt $StartedAt) { throw 'Content validation report finished_utc precedes started_utc.' }

Assert-ClosedProperties $Report.counts @($Policy.report.counts_required_fields) 'Content validation report counts'
foreach ($Field in @($Policy.report.counts_required_fields)) {
	if (-not (Test-JsonInteger $Report.counts.$Field)) { throw "Content validation report counts.$Field must be a JSON integer." }
	if ($Report.counts.$Field -lt 0) { throw "Content validation report counts.$Field must not be negative." }
}
if (-not (Test-JsonArray $Report.findings)) { throw 'Content validation report findings must be a JSON array.' }
$ReportFindings = @($Report.findings)
if ($Report.counts.findings -ne $ReportFindings.Count) { throw 'Content validation report finding count does not match its findings array.' }

if (-not (Test-JsonArray $Report.assets)) { throw 'Content validation report assets must be a JSON array.' }
$Assets = @($Report.assets)
if ($Assets.Count -eq 0) { throw 'Content validation report contains no governed assets; validation fails closed.' }
if ($Report.counts.assets -ne $Assets.Count) { throw 'Content validation report asset count does not match its assets array.' }
$KnownAudiences = @('shared','server_only','client_only')
$StableIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$AssetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ExpectedFamilies = @($Policy.policy_families.id)
$FamilyStatuses = [System.Collections.Generic.List[string]]::new()
$FamilyRecords = [System.Collections.Generic.List[object]]::new()
foreach ($Asset in $Assets) {
	Assert-ClosedProperties $Asset @($Policy.report.asset_required_fields) 'Content validation asset'
	if (@($Asset.PSObject.Properties.Name) -cnotcontains 'lifecycle_evidence') { throw "Content validation asset requires exact field 'lifecycle_evidence'." }
	if ($Asset.asset_path -isnot [string] -or $Asset.asset_path -cnotmatch '^/Game(?:/[^\s.]+)+$') { throw "Content validation asset_path '$($Asset.asset_path)' is malformed." }
	if (-not $AssetPaths.Add($Asset.asset_path)) { throw "Content validation report contains duplicate asset_path '$($Asset.asset_path)'." }
	if ($Asset.stable_id -isnot [string] -or $Asset.stable_id -cnotmatch '^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+$') { throw "Content validation asset '$($Asset.asset_path)' has a malformed stable_id '$($Asset.stable_id)'." }
	if (-not $StableIds.Add($Asset.stable_id)) { throw "Content validation report contains duplicate stable_id '$($Asset.stable_id)'." }
	if (-not (Test-JsonInteger $Asset.content_version)) { throw "Content validation asset '$($Asset.asset_path)' content_version must be a JSON integer." }
	if ($Asset.content_version -lt 1) { throw "Content validation asset '$($Asset.asset_path)' has a non-positive content_version." }
	if ($Asset.audience -isnot [string] -or $KnownAudiences -cnotcontains $Asset.audience) { throw "Content validation asset '$($Asset.asset_path)' has unsupported audience '$($Asset.audience)'." }
	if ($Asset.lifecycle_state -isnot [string] -or @($Policy.lifecycle_states) -cnotcontains $Asset.lifecycle_state) { throw "Content validation asset '$($Asset.asset_path)' has unsupported lifecycle_state '$($Asset.lifecycle_state)'." }
	$IntakeKey = ([string]$Asset.asset_path).ToLowerInvariant()
	if (-not $IntakeAssetsByPath.ContainsKey($IntakeKey)) { throw "Content validation asset '$($Asset.asset_path)' is absent from the runtime intake registry." }
	$IntakeAsset = $IntakeAssetsByPath[$IntakeKey]
	foreach ($Field in @('stable_id','content_version','audience','lifecycle_state')) { Assert-Equal $Asset.$Field $IntakeAsset.$Field "Content validation asset '$($Asset.asset_path)' $Field" }

	Assert-ClosedProperties $Asset.provenance @($Policy.report.provenance_required_fields) "Content validation asset '$($Asset.asset_path)' provenance"
	foreach ($Field in @($Policy.report.provenance_required_fields)) {
		if ($Asset.provenance.$Field -isnot [string]) { throw "Content validation asset '$($Asset.asset_path)' provenance field '$Field' must be a string." }
		if ([string]::IsNullOrWhiteSpace($Asset.provenance.$Field)) { throw "Content validation asset '$($Asset.asset_path)' provenance field '$Field' is empty." }
	}
	if ($Asset.provenance.content_sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Content validation asset '$($Asset.asset_path)' content_sha256 is malformed." }
	Assert-Equal $Asset.provenance.content_sha256 $IntakeAsset.content_sha256 "Content validation asset '$($Asset.asset_path)' content_sha256"
	$SourceGroup = $SourceGroupsById[[string]$IntakeAsset.source_group_id]
	foreach ($Field in @('author_or_provider','source_record','source_version','license_or_permission_evidence','modifications','generation_metadata_when_applicable','reviewer','approval_state')) {
		Assert-Equal $Asset.provenance.$Field $SourceGroup.$Field "Content validation asset '$($Asset.asset_path)' provenance.$Field"
	}
	Assert-ClosedProperties $Asset.lifecycle_evidence @($Policy.report.lifecycle_evidence_required_fields) "Content validation asset '$($Asset.asset_path)' lifecycle_evidence"
	Assert-LifecycleEvidence $Asset.lifecycle_evidence $IntakeAsset ([string]$SourceGroup.approval_state) "Content validation asset '$($Asset.asset_path)' lifecycle_evidence"
	if (($Asset.lifecycle_evidence | ConvertTo-Json -Compress -Depth 12) -cne ($IntakeAsset.lifecycle_evidence | ConvertTo-Json -Compress -Depth 12)) { throw "Content validation asset '$($Asset.asset_path)' lifecycle_evidence does not match the intake registry." }

	if (-not (Test-JsonArray $Asset.family_results)) { throw "Content validation asset '$($Asset.asset_path)' family_results must be a JSON array." }
	$FamilyResults = @($Asset.family_results)
	if ($FamilyResults.Count -ne $ExpectedFamilies.Count) { throw "Content validation asset '$($Asset.asset_path)' must report every policy family exactly once." }
	foreach ($FamilyId in $ExpectedFamilies) {
		$FamilyResult = @($FamilyResults | Where-Object { $_.policy_id -ceq $FamilyId })
		if ($FamilyResult.Count -ne 1) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' must occur exactly once." }
		$FamilyPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq $FamilyId })[0]
		Assert-ClosedProperties $FamilyResult[0] @($Policy.report.family_result_required_fields) "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId'"
		if ($ReportContractVersion -ge 2) {
			foreach ($Field in @('policy_id','applicability','deterministic_status','promotion_status','evidence')) {
				if (-not (Test-NonBlankJsonString $FamilyResult[0].$Field)) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' field '$Field' must be a non-blank string." }
			}
			if (@('applicable','not_applicable') -cnotcontains $FamilyResult[0].applicability) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has unsupported applicability." }
			if (@($Policy.report.allowed_deterministic_statuses) -cnotcontains $FamilyResult[0].deterministic_status) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has unsupported deterministic_status '$($FamilyResult[0].deterministic_status)'." }
			if (@($Policy.report.allowed_promotion_statuses) -cnotcontains $FamilyResult[0].promotion_status) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has unsupported promotion_status '$($FamilyResult[0].promotion_status)'." }
			if (-not (Test-JsonArray $FamilyResult[0].check_results)) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check_results must be a JSON array." }
			$CheckResults = @($FamilyResult[0].check_results)
			$ExpectedChecks = @($FamilyPolicy.checks | ForEach-Object { [string]$_ })
			if ($CheckResults.Count -ne $ExpectedChecks.Count) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' must report every policy check exactly once." }
			foreach ($CheckId in $ExpectedChecks) {
				$CheckResult = @($CheckResults | Where-Object { $_.check_id -ceq $CheckId })
				if ($CheckResult.Count -ne 1) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId' must occur exactly once." }
				Assert-ClosedProperties $CheckResult[0] @($Policy.report.check_result_required_fields) "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId'"
				foreach ($Field in @($Policy.report.check_result_required_fields)) {
					if (-not (Test-NonBlankJsonString $CheckResult[0].$Field)) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId' field '$Field' must be a non-blank string." }
				}
				if (@('applicable','not_applicable') -cnotcontains $CheckResult[0].applicability) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId' has unsupported applicability." }
				if (@($Policy.report.allowed_deterministic_statuses) -cnotcontains $CheckResult[0].deterministic_status) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId' has unsupported deterministic_status." }
				if (@($Policy.report.allowed_promotion_statuses) -cnotcontains $CheckResult[0].promotion_status) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' check '$CheckId' has unsupported promotion_status." }
				if ($CheckResult[0].applicability -ceq 'not_applicable') {
					if ($CheckResult[0].deterministic_status -cne 'not_applicable' -or $CheckResult[0].promotion_status -cne 'not_applicable') { throw "Content validation asset '$($Asset.asset_path)' non-applicable check '$FamilyId.$CheckId' must use both not_applicable statuses." }
				}
				elseif ($CheckResult[0].deterministic_status -ceq 'not_applicable' -or $CheckResult[0].promotion_status -ceq 'not_applicable') {
					throw "Content validation asset '$($Asset.asset_path)' applicable check '$FamilyId.$CheckId' cannot use not_applicable statuses."
				}
				if ($CheckResult[0].deterministic_status -ceq 'evidence_unavailable' -and $CheckResult[0].promotion_status -cne 'non_promotion') {
					throw "Content validation asset '$($Asset.asset_path)' applicable check '$FamilyId.$CheckId' with unavailable evidence must be non_promotion."
				}
				if ($CheckResult[0].deterministic_status -ceq 'failed' -and $CheckResult[0].promotion_status -cne 'non_promotion') {
					throw "Content validation asset '$($Asset.asset_path)' failed check '$FamilyId.$CheckId' must be non_promotion."
				}
			}
			$ApplicableChecks = @($CheckResults | Where-Object { $_.applicability -ceq 'applicable' })
			$FailedChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'failed' })
			$UnavailableChecks = @($ApplicableChecks | Where-Object { $_.deterministic_status -ceq 'evidence_unavailable' })
			$BlockedChecks = @($ApplicableChecks | Where-Object { $_.promotion_status -ceq 'non_promotion' })
			$ExpectedApplicability = if ($ApplicableChecks.Count -gt 0) { 'applicable' } else { 'not_applicable' }
			$ExpectedDeterministic = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0) { 'failed' } elseif ($UnavailableChecks.Count -gt 0) { 'evidence_unavailable' } else { 'passed' }
			$ExpectedPromotion = if ($ApplicableChecks.Count -eq 0) { 'not_applicable' } elseif ($FailedChecks.Count -gt 0 -or $UnavailableChecks.Count -gt 0 -or $BlockedChecks.Count -gt 0 -or $Asset.lifecycle_state -ceq 'temporary_prototype') { 'non_promotion' } else { 'eligible' }
			if ($FamilyResult[0].applicability -cne $ExpectedApplicability) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' applicability does not aggregate check results." }
			if ($FamilyResult[0].deterministic_status -cne $ExpectedDeterministic) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' deterministic_status does not aggregate failed over evidence_unavailable over passed." }
			if ($FamilyResult[0].promotion_status -cne $ExpectedPromotion) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' promotion_status does not aggregate non_promotion before eligible." }
			if ($FamilyResult[0].applicability -ceq 'not_applicable' -and $FamilyResult[0].evidence -cne (Get-CanonicalNotApplicableEvidence $FamilyId)) {
				throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' not_applicable status requires exact canonical evidence."
			}
			$AggregateStatus = if ($FamilyResult[0].deterministic_status -ceq 'failed') { 'failed' } elseif ($FamilyResult[0].promotion_status -ceq 'non_promotion') { 'non_promotion' } else { 'passed' }
			if ($FamilyId -ceq 'reference_boundary' -and $FamilyResult[0].applicability -cne 'applicable') { throw "Content validation asset '$($Asset.asset_path)' cooked package requires applicable reference_boundary evidence." }
			$FamilyStatuses.Add($AggregateStatus)
			$FamilyRecords.Add([pscustomobject]@{ AssetPath=[string]$Asset.asset_path; PolicyId=$FamilyId; Status=$AggregateStatus })
		}
		else {
			foreach ($Field in @($Policy.report.family_result_required_fields)) {
				if (-not (Test-NonBlankJsonString $FamilyResult[0].$Field)) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' field '$Field' must be a non-blank string." }
			}
			if (@('applicable','not_applicable') -cnotcontains $FamilyResult[0].applicability) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has unsupported applicability." }
			if (@($Policy.report.allowed_family_statuses) -cnotcontains $FamilyResult[0].status) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has unsupported status '$($FamilyResult[0].status)'." }
			if ($FamilyId -ceq 'reference_boundary' -and $FamilyResult[0].applicability -cne 'applicable') { throw "Content validation asset '$($Asset.asset_path)' cooked package requires applicable reference_boundary evidence." }
			$ExpectedStatus = if ($FamilyResult[0].applicability -ceq 'not_applicable') { 'not_applicable' } elseif ($HasUnresolvedQuantitativeThresholds -and $FamilyPolicy.unresolved_quantitative_result -ceq 'non_promotion') { 'non_promotion' } else { 'passed' }
			$AllowsDeterministicFailure = $FamilyResult[0].applicability -ceq 'applicable' -and $FamilyResult[0].status -ceq 'failed'
			if (-not $AllowsDeterministicFailure -and $FamilyResult[0].status -cne $ExpectedStatus) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' has blocking status '$($FamilyResult[0].status)'; expected '$ExpectedStatus'." }
			if ($ExpectedStatus -ceq 'not_applicable' -and $FamilyResult[0].evidence -cne (Get-CanonicalNotApplicableEvidence $FamilyId)) { throw "Content validation asset '$($Asset.asset_path)' policy family '$FamilyId' not_applicable status requires exact canonical evidence." }
			$FamilyStatuses.Add([string]$FamilyResult[0].status)
			$FamilyRecords.Add([pscustomobject]@{ AssetPath=[string]$Asset.asset_path; PolicyId=$FamilyId; Status=[string]$FamilyResult[0].status })
		}
	}
}
if ($Assets.Count -ne @($Intake.assets).Count) { throw 'Content validation report must contain exactly every runtime intake registry asset.' }

foreach ($Finding in $ReportFindings) {
	Assert-ClosedProperties $Finding @($Policy.report.finding_required_fields) 'Content validation finding'
	foreach ($Field in @($Policy.report.finding_required_fields)) {
		if (-not (Test-NonBlankJsonString $Finding.$Field)) { throw "Content validation finding field '$Field' must be a non-blank string." }
	}
	if ($ExpectedFamilies -cnotcontains $Finding.policy_id) { throw "Content validation finding has unknown policy family '$($Finding.policy_id)'." }
	if (@($Policy.report.allowed_severities) -cnotcontains $Finding.severity) { throw "Content validation finding severity '$($Finding.severity)' is unsupported." }
	$FindingPolicy = @($Policy.policy_families | Where-Object { $_.id -ceq $Finding.policy_id })[0]
	$ExpectedCode = if ($Finding.severity -ceq 'error') { [string]$FindingPolicy.failure_code } else { [string]$FindingPolicy.failure_code -replace '\.failed$', '.non_promotion' }
	if ($Finding.code -cne $ExpectedCode) { throw "Content validation finding code '$($Finding.code)' does not match policy family '$($Finding.policy_id)' stable code '$ExpectedCode'." }
	$MatchingFamily = @($FamilyRecords | Where-Object { $_.AssetPath -ceq $Finding.asset_path -and $_.PolicyId -ceq $Finding.policy_id })
	if ($MatchingFamily.Count -ne 1) { throw "Content validation finding '$($Finding.policy_id)' does not identify one reported asset family." }
	$ExpectedFindingStatus = if ($Finding.severity -ceq 'error') { 'failed' } else { 'non_promotion' }
	if ($MatchingFamily[0].Status -cne $ExpectedFindingStatus) { throw "Content validation finding '$($Finding.policy_id)' expects family status '$ExpectedFindingStatus' but found '$($MatchingFamily[0].Status)'." }
}
foreach ($FamilyRecord in @($FamilyRecords | Where-Object { $_.Status -cin @('failed', 'non_promotion') })) {
	$ExpectedSeverity = if ($FamilyRecord.Status -ceq 'failed') { 'error' } else { 'non_promotion' }
	$MatchingFindings = @($ReportFindings | Where-Object { $_.asset_path -ceq $FamilyRecord.AssetPath -and $_.policy_id -ceq $FamilyRecord.PolicyId -and $_.severity -ceq $ExpectedSeverity })
	if ($MatchingFindings.Count -ne 1) { throw "Content validation asset '$($FamilyRecord.AssetPath)' policy family '$($FamilyRecord.PolicyId)' status '$($FamilyRecord.Status)' must have exactly one correlated finding." }
}

$ReportErrorCount = @($ReportFindings | Where-Object { $_.severity -ceq 'error' }).Count
$ReportNonPromotionCount = @($ReportFindings | Where-Object { $_.severity -ceq 'non_promotion' }).Count
if ($Report.counts.errors -ne $ReportErrorCount) { throw 'Content validation report error count is inconsistent.' }
if ($Report.counts.non_promotion -ne $ReportNonPromotionCount) { throw 'Content validation report non-promotion count is inconsistent.' }
if ($Report.result -ceq 'passed') {
	if ($ReportErrorCount -ne 0 -or $ReportNonPromotionCount -ne 0 -or $FamilyStatuses -contains 'failed' -or $FamilyStatuses -contains 'non_promotion') {
		throw 'Content validation report result passed is inconsistent with its family statuses and findings.'
	}
}
elseif ($Report.result -ceq 'failed') {
	if ($ReportErrorCount -eq 0 -or $FamilyStatuses -notcontains 'failed') { throw 'Content validation report result failed is inconsistent without a correlated deterministic error.' }
}
else {
	if ($ReportErrorCount -ne 0 -or $ReportNonPromotionCount -eq 0 -or $FamilyStatuses -notcontains 'non_promotion') {
		throw 'Content validation report result non_promotion is inconsistent with its family statuses and findings.'
	}
}
if ($Report.result -ceq 'failed') { throw 'Content validation report contains deterministic validation errors and cannot be used for cook-boundary evidence.' }

$ClientInventory = Read-CookedInventory $ClientCookedInventoryDirectory 'Client'
$ServerInventory = Read-CookedInventory $ServerCookedInventoryDirectory 'Server'
$CommonManifest = @{
	capture_mode = if ($Report.execution_provenance.registry_source -ceq 'test_snapshot') { 'test_fixture' } else { 'live_cooked_registry' }
	source_revision = [string]$Report.revision
	repository_clean = $true
	engine_revision = [string]$Report.execution_provenance.engine_revision
	engine_tag = [string]$Report.execution_provenance.engine_tag
	engine_binary_sha256 = [string]$Report.execution_provenance.engine_binary_sha256
	build_version_sha256 = [string]$Report.execution_provenance.build_version_sha256
	configuration = [string]$Report.execution_provenance.configuration
	project_sha256 = [string]$Report.execution_provenance.project_sha256
	policy_sha256 = $ExpectedPolicySha256
	intake_sha256 = $ExpectedIntakeSha256
	content_validation_report_sha256 = $ContentReportSha256
	build_provenance_sha256 = $BuildProvenanceSha256
}
$ClientExpectedManifest = @{} + $CommonManifest
$ClientExpectedManifest.target = [string]$BuildProvenance.build.clientTarget
$ClientExpectedManifest.platform = [string]$BuildProvenance.build.clientPlatform
$ClientExpectedManifest.toolchain_identity = [string]$BuildProvenance.tools.compiler.version
$ClientExpectedManifest.toolchain_sha256 = [string]$BuildProvenance.tools.compiler.sha256
$ClientExpectedManifest.cook_command_sha256 = Get-StringSha256 (@($BuildProvenance.build.uatInvocations.client.arguments) -join "`0")
$ServerExpectedManifest = @{} + $CommonManifest
$ServerExpectedManifest.target = [string]$BuildProvenance.build.serverTarget
$ServerExpectedManifest.platform = [string]$BuildProvenance.build.serverPlatform
$ServerExpectedManifest.toolchain_identity = [string]$BuildProvenance.tools.linuxCrossToolchain.identity
$ServerExpectedManifest.toolchain_sha256 = [string]$BuildProvenance.tools.linuxCrossToolchain.compilerSha256
$ServerExpectedManifest.cook_command_sha256 = Get-StringSha256 (@($BuildProvenance.build.uatInvocations.server.arguments) -join "`0")
$ClientManifest = Read-InventoryManifest $ClientInventory 'Client' $ClientExpectedManifest
$ServerManifest = Read-InventoryManifest $ServerInventory 'Server' $ServerExpectedManifest
$ClientPackages = $ClientInventory.Packages
$ServerPackages = $ServerInventory.Packages
$Findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding([object] $Asset, [string] $Reason, [string] $Remediation) {
	$Findings.Add([ordered]@{
		policy_id = 'reference_boundary'
		code = 'content.reference_boundary.failed'
		asset_path = [string]$Asset.asset_path
		severity = 'error'
		reason = $Reason
		remediation = $Remediation
		evidence_field = 'audience'
	})
}

function Add-UnregisteredFinding([string] $Path, [string] $TargetName) {
	$Findings.Add([ordered]@{
		policy_id = 'reference_boundary'
		code = 'content.reference_boundary.failed'
		asset_path = $Path
		severity = 'error'
		reason = "$TargetName cooked package '$Path' is absent from the closed runtime intake registry"
		remediation = 'Register the exact committed /Game package with provenance, lifecycle, audience, and content hash before using it in a cook.'
		evidence_field = 'runtime_asset_intake'
	})
}

foreach ($Package in @($ClientPackages | Sort-Object)) {
	if ($Package.StartsWith('/Game/', [StringComparison]::OrdinalIgnoreCase) -and -not $IntakeAssetsByPath.ContainsKey($Package.ToLowerInvariant())) { Add-UnregisteredFinding $Package 'Client' }
}
foreach ($Package in @($ServerPackages | Sort-Object)) {
	if ($Package.StartsWith('/Game/', [StringComparison]::OrdinalIgnoreCase) -and -not $IntakeAssetsByPath.ContainsKey($Package.ToLowerInvariant())) { Add-UnregisteredFinding $Package 'Server' }
}

foreach ($Asset in $Assets) {
	$Path = [string]$Asset.asset_path
	switch ([string]$Asset.audience) {
		'shared' {
			if (-not $ClientPackages.Contains($Path)) { Add-Finding $Asset "shared asset '$Path' is missing from the client cooked inventory" 'Include the shared package in the exact-revision client cook.' }
			if (-not $ServerPackages.Contains($Path)) { Add-Finding $Asset "shared asset '$Path' is missing from the server cooked inventory" 'Include the shared package in the exact-revision dedicated-server cook.' }
		}
		'server_only' {
			if (-not $ServerPackages.Contains($Path)) { Add-Finding $Asset "server_only asset '$Path' is missing from the server cooked inventory" 'Include the server-only package in the exact-revision dedicated-server cook.' }
			if ($ClientPackages.Contains($Path)) { Add-Finding $Asset "server_only asset '$Path' leaked into the client cooked inventory" 'Remove the server-only package from client cook reachability.' }
		}
		'client_only' {
			if (-not $ClientPackages.Contains($Path)) { Add-Finding $Asset "client_only asset '$Path' is missing from the client cooked inventory" 'Include the client-only package in the exact-revision client cook.' }
			if ($ServerPackages.Contains($Path)) { Add-Finding $Asset "client_only asset '$Path' leaked into the server cooked inventory" 'Remove the client-only package from dedicated-server cook reachability.' }
		}
	}
}

Assert-AllValidationInputsUnchanged
$StartedUtc = [DateTime]::UtcNow
$Result = if ($Findings.Count -gt 0) { 'failed' } elseif ($Report.result -ceq 'non_promotion') { 'non_promotion' } else { 'passed' }
$Evidence = [ordered]@{
	schema_id = 'aetheln.content-cook-evidence'
	schema_version = 3
	revision = [string]$Report.revision
	policy_sha256 = [string]$Report.policy_sha256
	intake_sha256 = [string]$Report.intake_sha256
	started_utc = $StartedUtc.ToString('o')
	finished_utc = [DateTime]::UtcNow.ToString('o')
	inputs = [ordered]@{
		content_validation_report = [ordered]@{ sha256 = $ContentReportSha256; result = [string]$Report.result }
		build_provenance = [ordered]@{ sha256 = $BuildProvenanceSha256; revision = [string]$BuildProvenance.source.revision }
		client_inventory = [ordered]@{ manifest_sha256 = $ClientManifest.Sha256; capture_mode = [string]$ClientManifest.Value.capture_mode; cooked_registry = $ClientManifest.Value.cooked_registry; pages = @($ClientInventory.Pages) }
		server_inventory = [ordered]@{ manifest_sha256 = $ServerManifest.Sha256; capture_mode = [string]$ServerManifest.Value.capture_mode; cooked_registry = $ServerManifest.Value.cooked_registry; pages = @($ServerInventory.Pages) }
	}
	counts = [ordered]@{
		assets = $Assets.Count
		client_packages = $ClientPackages.Count
		server_packages = $ServerPackages.Count
		findings = $Findings.Count
	}
	findings = @($Findings)
	result = $Result
}

if ($null -ne $ResolvedOutput) {
	$OutputDirectory = Split-Path -Parent $ResolvedOutput
	if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
	$OutputAncestorHolds = Open-OutputAncestorHolds $OutputDirectory
	$EvidenceBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((($Evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine))
}

$InputLocks = Open-InputLocks (@($ContentReportSource, $PolicySource, $IntakeSource, $BuildProvenanceSource) + @($ClientInventorySnapshot.SourceFiles) + @($ServerInventorySnapshot.SourceFiles))
try {
	Assert-AllValidationInputsUnchanged
	if ($null -ne $ResolvedOutput) {
		$PublicationTarget = $ResolvedOutput
		# A write-open of any hardlink alias of a locked input fails, so this
		# path-based probe rejects aliases without writing any bytes. The
		# publication itself then works through handles: it replaces the output
		# entry inside the held parent and never deletes a separate path.
		try {
			if (Test-Path -LiteralPath $PublicationTarget -PathType Leaf) {
				([IO.File]::Open($PublicationTarget, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)).Dispose()
			}
		}
		catch [IO.IOException], [UnauthorizedAccessException] {
			throw "OutputPath '$PublicationTarget' could not be published because it aliases protected input evidence or is otherwise locked; validation fails closed. $($_.Exception.Message)"
		}
		$PendingOutputName = ".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($ResolvedOutput)), [guid]::NewGuid().ToString('N')
		try { [AethelnOutputPublicationNative]::PublishInHeldDirectory($OutputAncestorHolds[$OutputAncestorHolds.Count - 1], $OutputDirectory, $PendingOutputName, [IO.Path]::GetFileName($ResolvedOutput), $EvidenceBytes) }
		catch {
			$Reason = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
			throw "OutputPath '$PublicationTarget' could not be published inside its held parent: $Reason; validation fails closed."
		}
	}
	Assert-AllValidationInputsUnchanged
}
finally {
	foreach ($Lock in $InputLocks) { $Lock.Dispose() }
}

if ($Findings.Count -gt 0) {
	$Messages = @($Findings | ForEach-Object { $_.reason })
	throw ("Content cook evidence validation failed:" + [Environment]::NewLine + ' - ' + ($Messages -join ([Environment]::NewLine + ' - ')))
}

Write-Output "Validated $($Assets.Count) governed assets across $($ClientPackages.Count) client and $($ServerPackages.Count) server cooked packages."
Write-Output 'Content cook evidence validation passed.'
}
finally {
	foreach ($Hold in $OutputAncestorHolds) { $Hold.Dispose() }
	if (Test-Path -LiteralPath $InputSnapshotRoot) { Remove-Item -LiteralPath $InputSnapshotRoot -Recurse -Force }
}
