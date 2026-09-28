[CmdletBinding()]
param(
	[ValidateSet('RunSuite', 'LockAssertions', 'AcquireOnly', 'ReportAbandoned', 'FailureRelease', 'HoldUntilKilled')]
	[string]$SuiteLockProbeMode = 'RunSuite',

	[string]$SuiteLockProbeRoot
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SkillRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $SkillRoot '..\..\..')).Path

if (
	$SuiteLockProbeMode -in @('RunSuite', 'LockAssertions') -and
	$PSBoundParameters.ContainsKey('SuiteLockProbeRoot')
) {
	throw '-SuiteLockProbeRoot is valid only for a suite-lock probe mode.'
}

function Get-CanonicalDeliveryLauncherWorktreeRoot {
	param(
		[Parameter(Mandatory)]
		[string]$WorktreeRoot
	)

	$ResolvedRoot = Resolve-Path -LiteralPath $WorktreeRoot -ErrorAction Stop
	if ($ResolvedRoot.Provider.Name -cne 'FileSystem') {
		throw "Delivery launcher worktree root '$WorktreeRoot' is not a file-system path."
	}
	$RootItem = Get-Item -LiteralPath $ResolvedRoot.ProviderPath -Force
	if (-not $RootItem.PSIsContainer) {
		throw "Delivery launcher worktree root '$WorktreeRoot' is not a directory."
	}

	$CanonicalRoot = [System.IO.Path]::GetFullPath($ResolvedRoot.ProviderPath)
	$CanonicalRoot = $CanonicalRoot.Replace(
		[System.IO.Path]::AltDirectorySeparatorChar,
		[System.IO.Path]::DirectorySeparatorChar
	)
	$VolumeRoot = [System.IO.Path]::GetPathRoot($CanonicalRoot)
	if ($CanonicalRoot.Length -gt $VolumeRoot.Length) {
		$CanonicalRoot = $CanonicalRoot.TrimEnd(
			[char[]]@(
				[System.IO.Path]::DirectorySeparatorChar,
				[System.IO.Path]::AltDirectorySeparatorChar
			)
		)
	}
	if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
		$CanonicalRoot = $CanonicalRoot.ToUpperInvariant()
	}

	return $CanonicalRoot
}

if (-not ('AethelnDeliveryLauncherDirectoryIdentity' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class AethelnDeliveryLauncherDirectoryIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] FileId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string path, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle handle, int informationClass, out FileIdInfo information,
        uint bufferSize);

    public static string Get(string path)
    {
        const uint ShareReadWriteDelete = 0x00000007;
        const uint OpenExisting = 3;
        const uint BackupSemantics = 0x02000000;
        const int FileIdInfoClass = 18;
        using (SafeFileHandle handle = CreateFile(
            path, 0, ShareReadWriteDelete, IntPtr.Zero, OpenExisting,
            BackupSemantics, IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not open the worktree directory for suite-lock identity.");
            }
            FileIdInfo information;
            if (!GetFileInformationByHandleEx(handle, FileIdInfoClass,
                out information, (uint)Marshal.SizeOf(typeof(FileIdInfo))))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not read the physical worktree directory identity.");
            }
            return information.VolumeSerialNumber.ToString("X16") + "-" +
                BitConverter.ToString(information.FileId).Replace("-", "");
        }
    }
}
'@
}

function Get-DeliveryLauncherSuiteMutexName {
	param(
		[Parameter(Mandatory)]
		[string]$WorktreeRoot
	)

	$DirectoryIdentity = [AethelnDeliveryLauncherDirectoryIdentity]::Get(
		(Get-CanonicalDeliveryLauncherWorktreeRoot -WorktreeRoot $WorktreeRoot)
	)
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$HashBytes = $Hasher.ComputeHash(
			[System.Text.Encoding]::UTF8.GetBytes($DirectoryIdentity)
		)
	}
	finally {
		$Hasher.Dispose()
	}
	$Suffix = [System.BitConverter]::ToString($HashBytes).Replace('-', '')
	return 'Global\AethelnOnline_DeliveryLauncherSuite_' + $Suffix
}

function New-DeliveryLauncherSuiteMutexSecurity {
	$Security = [System.Security.AccessControl.MutexSecurity]::new()
	$AuthenticatedUsers = [System.Security.Principal.SecurityIdentifier]::new(
		[System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
		$null
	)
	$Rights = [System.Security.AccessControl.MutexRights]::Modify -bor
		[System.Security.AccessControl.MutexRights]::Synchronize
	$Rule = [System.Security.AccessControl.MutexAccessRule]::new(
		$AuthenticatedUsers,
		$Rights,
		[System.Security.AccessControl.AccessControlType]::Allow
	)
	$Security.AddAccessRule($Rule)
	return $Security
}

function Get-DeliveryLauncherSuiteLockDiagnostic {
	param(
		[Parameter(Mandatory)]
		[string]$WorktreeRoot
	)

	return (
		'Test-DeliveryStageLauncher.ps1: another instance owns the delivery ' +
		"launcher suite lock for worktree '$WorktreeRoot'. This suite " +
		'baselines and mutates repository state; run it serialized per worktree.'
	)
}

# Interprocess per-worktree suite lock (#146). This suite baselines live Git
# state and deliberately mutates in-repository fixtures, so two instances in
# the same physical worktree contaminate each other's assertions. The machine-
# global named mutex is outside the repository and is keyed by the directory's
# volume/file ID, not an aliasable path or per-user temp location. Its live OS
# ownership is released on ordinary exit and process termination. The ACL
# grants authenticated Windows users the minimal wait/release rights; failure
# to create or access this single namespace fails closed without fallback.
$RequestedSuiteLockRoot = if ($PSBoundParameters.ContainsKey('SuiteLockProbeRoot')) {
	$SuiteLockProbeRoot
}
else {
	$RepositoryRoot
}
$SuiteLockRoot = Get-CanonicalDeliveryLauncherWorktreeRoot -WorktreeRoot $RequestedSuiteLockRoot
$SuiteLockMutex = $null
$SuiteLockOwned = $false
$SuiteLockAbandoned = $false
try {
	$SuiteLockName = Get-DeliveryLauncherSuiteMutexName -WorktreeRoot $SuiteLockRoot
	$MinimalRights = [System.Security.AccessControl.MutexRights]::Modify -bor
		[System.Security.AccessControl.MutexRights]::Synchronize
	try {
		# An existing cross-user object may deny FullControl while granting
		# precisely the rights required to wait and release.
		$SuiteLockMutex = [System.Threading.Mutex]::OpenExisting(
			$SuiteLockName, $MinimalRights
		)
	}
	catch [System.Threading.WaitHandleCannotBeOpenedException] {
		$CreatedNew = $false
		try {
			$SuiteLockMutex = [System.Threading.Mutex]::new(
				$false,
				$SuiteLockName,
				[ref]$CreatedNew,
				(New-DeliveryLauncherSuiteMutexSecurity)
			)
		}
		catch [System.UnauthorizedAccessException] {
			# Another user may have created the same object in the race after
			# OpenExisting. Retry only the exact global name with minimal rights.
			$SuiteLockMutex = [System.Threading.Mutex]::OpenExisting(
				$SuiteLockName, $MinimalRights
			)
		}
	}
	try {
		$SuiteLockOwned = $SuiteLockMutex.WaitOne(0)
	}
	catch [System.Threading.AbandonedMutexException] {
		# WaitOne grants ownership even when it reports an abandoned owner.
		$SuiteLockOwned = $true
		$SuiteLockAbandoned = $true
	}
}
catch {
	if ($null -ne $SuiteLockMutex) { $SuiteLockMutex.Dispose() }
	[Console]::Error.WriteLine((
		'Test-DeliveryStageLauncher.ps1: cannot establish the machine-global ' +
		"suite lock for worktree '$SuiteLockRoot'; refusing to run."
	))
	exit 1
}
if (-not $SuiteLockOwned) {
	$SuiteLockMutex.Dispose()
	[Console]::Error.WriteLine((
		Get-DeliveryLauncherSuiteLockDiagnostic -WorktreeRoot $SuiteLockRoot
	))
	exit 1
}

$FailureReleaseProbeMessage = 'Intentional suite-lock failure-release probe.'
$FailureReleaseProbeError = $null
try {
	if ($SuiteLockProbeMode -eq 'FailureRelease') {
		throw $FailureReleaseProbeMessage
	}
	if ($SuiteLockProbeMode -eq 'AcquireOnly') {
		return
	}
	if ($SuiteLockProbeMode -eq 'ReportAbandoned') {
		if (-not $SuiteLockAbandoned) {
			throw 'The abandoned-mutex probe did not observe an abandoned owner.'
		}
		[Console]::Out.WriteLine('suite-lock-abandoned')
		return
	}
	if ($SuiteLockProbeMode -eq 'HoldUntilKilled') {
		[Console]::Out.WriteLine('suite-lock-held')
		while ($true) {
			[System.Threading.Thread]::Sleep(1000)
		}
	}
$SourceCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
$ValidateScript = Join-Path $ScriptRoot 'Validate-DeliveryHandoff.ps1'
$LaunchScript = Join-Path $ScriptRoot 'Invoke-DeliveryStage.ps1'
$SnapshotScript = Join-Path $ScriptRoot 'Get-DeliveryRepositorySnapshot.ps1'
$PatchValidationScript = Join-Path $ScriptRoot 'Validate-DeliveryPatch.ps1'
$PatchApplicationScript = Join-Path $ScriptRoot 'Apply-DeliveryPatch.ps1'
$BundleConversionScript = Join-Path (
	$ScriptRoot
) 'Convert-DeliveryFileBundleToPatch.ps1'
$ReparseCheckScript = Join-Path $ScriptRoot 'Assert-DeliveryPathNoReparse.ps1'
$PathSplitScript = Join-Path $ScriptRoot 'Split-DeliveryGitPathList.ps1'
$SensitivePathScript = Join-Path $ScriptRoot 'Test-DeliverySensitivePath.ps1'
$EvidenceProtectionScript = Join-Path $ScriptRoot 'Protect-DeliveryEvidence.ps1'
$EvidenceValidationScript = Join-Path $ScriptRoot 'Test-DeliveryEvidence.ps1'
$EventTelemetryScript = Join-Path $ScriptRoot 'Get-DeliveryEventTelemetry.ps1'
$EfficiencyComparisonScript = Join-Path $ScriptRoot 'Compare-DeliveryEfficiency.ps1'
$SchemaPath = Join-Path $SkillRoot 'references\handoff-schemas.json'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-stage-tests-' + [guid]::NewGuid().ToString('N')
)

New-Item -ItemType Directory -Path $TestRoot | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter(Mandatory)]
		[bool]$Passed,

		[string]$Detail = ''
	)

	$Results.Add([pscustomobject]@{
		Name = $Name
		Passed = $Passed
		Detail = $Detail
	})
}

function Invoke-ExpectedFailure {
	param(
		[Parameter(Mandatory)]
		[scriptblock]$Action,

		[Parameter(Mandatory)]
		[string]$Pattern
	)

	try {
		& $Action
		return $false
	}
	catch {
		return $_.Exception.Message -match $Pattern
	}
}

function Invoke-TestGitText {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
		$Result = [System.Text.Encoding]::UTF8.GetString($Output.ToArray())
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}

	if ($ExitCode -ne 0) {
		throw "Git command '$Arguments' failed: $StandardError"
	}

	return $Result
}

function Invoke-TestGitBytes {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments,

		[hashtable]$Environment = @{},

		[string]$WorkingDirectory = $RepositoryRoot
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $WorkingDirectory
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	foreach ($Name in $Environment.Keys) {
		$StartInfo.EnvironmentVariables[[string]$Name] = [string]$Environment[$Name]
	}

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
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

	return ,([byte[]]$Result)
}

function Get-TestSha256 {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes
	)

	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function New-NeutralEvidenceByteRecord {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('text', 'command_log', 'artifact', 'diff', 'status', 'path_list')]
		[string]$Kind,

		[Parameter(Mandatory)]
		[ValidateSet('control_plane', 'repository', 'launcher', 'stage', 'external')]
		[string]$Provenance,

		[Parameter(Mandatory)]
		[string]$Source,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[ValidateSet('utf8', 'base64')]
		[string]$Encoding
	)

	$Content = if ($Encoding -eq 'base64') {
		[System.Convert]::ToBase64String($Bytes)
	}
	else {
		$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
		$StrictUtf8.GetString($Bytes)
	}

	return [pscustomobject][ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = $Encoding
		source = $Source
		sha256 = Get-TestSha256 -Bytes $Bytes
		content = $Content
	}
}

function Test-TestByteArrayEqual {
	param(
		[AllowEmptyCollection()]
		[byte[]]$Left,

		[AllowEmptyCollection()]
		[byte[]]$Right
	)

	return [System.Linq.Enumerable]::SequenceEqual(
		[byte[]]$Left,
		[byte[]]$Right
	)
}

function New-NeutralEvidenceRecord {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('text', 'command_log', 'artifact', 'diff', 'status', 'path_list')]
		[string]$Kind,

		[Parameter(Mandatory)]
		[ValidateSet('control_plane', 'repository', 'launcher', 'stage', 'external')]
		[string]$Provenance,

		[Parameter(Mandatory)]
		[string]$Source,

		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Text,

		[ValidateSet('utf8', 'base64')]
		[string]$Encoding = 'utf8'
	)

	$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Hash = [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}

	$Content = if ($Encoding -eq 'base64') {
		[System.Convert]::ToBase64String($Bytes)
	} else {
		$Text
	}

	return [pscustomobject][ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = $Encoding
		source = $Source
		sha256 = $Hash
		content = $Content
	}
}

function New-RequiredEvidenceDeclaration {
	param(
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][object]$Record
	)

	return [ordered]@{
		field = $Field
		kind = $Record.kind
		provenance = $Record.provenance
		encoding = $Record.encoding
		source = $Record.source
		sha256 = $Record.sha256
	}
}

function New-FrozenAuthoritativeEvidenceManifest {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('verifier', 'approver')]
		[string]$Stage,

		[Parameter(Mandatory)][object]$Handoff,

		[Parameter(Mandatory)][string]$Name
	)

	[string[]]$FieldNames = if ($Stage -ceq 'verifier') {
		@('candidate_artifact', 'raw_check_output')
	}
	else {
		@('baseline_status', 'baseline_diff', 'final_artifact', 'raw_check_output')
	}
	$Records = [System.Collections.Generic.List[object]]::new()
	foreach ($FieldName in $FieldNames) {
		$FieldValue = if ($Handoff -is [System.Collections.IDictionary]) {
			$Handoff[$FieldName]
		}
		else {
			$Handoff.$FieldName
		}
		$FieldRecords = if ($FieldValue -is [System.Array]) {
			@($FieldValue)
		}
		else {
			@($FieldValue)
		}
		foreach ($Record in $FieldRecords) {
			[void]$Records.Add([pscustomobject][ordered]@{
				field = $FieldName
				kind = $Record.kind
				provenance = $Record.provenance
				encoding = $Record.encoding
				source = $Record.source
				sha256 = $Record.sha256
			})
		}
	}

	$Manifest = [pscustomobject][ordered]@{
		format = 'delivery_authoritative_evidence_manifest_v1'
		stage = $Stage
		records = [object[]]@($Records)
	}
	$Json = $Manifest | ConvertTo-Json -Depth 10 -Compress
	$Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
	$Bytes = $Utf8NoBom.GetBytes($Json)
	$Path = Join-Path $TestRoot "$Name-authoritative-evidence-manifest.json"
	[System.IO.File]::WriteAllBytes($Path, $Bytes)

	return [pscustomobject]@{
		Path = $Path
		Bytes = [byte[]]$Bytes
		Sha256 = Get-TestSha256 -Bytes $Bytes
	}
}

function Invoke-DeliveryLauncherSuiteLockProbe {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('AcquireOnly', 'ReportAbandoned', 'FailureRelease')]
		[string]$Mode,

		[string]$LockRoot,

		[hashtable]$ProcessEnvironment = @{},

		[ValidateRange(1, 60000)]
		[int]$TimeoutMilliseconds = 10000
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
	$StartInfo.Arguments = (
		'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
		$PSCommandPath + '" -SuiteLockProbeMode ' + $Mode
	)
	if ($PSBoundParameters.ContainsKey('LockRoot')) {
		$StartInfo.Arguments += ' -SuiteLockProbeRoot "' + $LockRoot + '"'
	}
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.WorkingDirectory = $RepositoryRoot
	foreach ($Name in $ProcessEnvironment.Keys) {
		$StartInfo.EnvironmentVariables[[string]$Name] =
			[string]$ProcessEnvironment[$Name]
	}

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Started = $false
	$CompletedWithinTimeout = $false
	try {
		$Started = $Process.Start()
		if (-not $Started) {
			throw 'Could not start the delivery launcher suite-lock probe.'
		}

		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$CompletedWithinTimeout = $Process.WaitForExit($TimeoutMilliseconds)
		if (-not $CompletedWithinTimeout) {
			try {
				$Process.Kill()
			}
			catch {
				throw (
					'Delivery launcher suite-lock probe timed out and could not be ' +
					"terminated: $($_.Exception.Message)"
				)
			}
			if (-not $Process.WaitForExit(5000)) {
				throw (
					'Delivery launcher suite-lock probe remained active after its ' +
					'timeout cleanup.'
				)
			}
		}

		$StandardOutput = $OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
	}
	finally {
		if ($Started) {
			try {
				if (-not $Process.HasExited) {
					$Process.Kill()
					[void]$Process.WaitForExit(5000)
				}
			}
			catch {
				# The bounded probe never spawns children. Best-effort cleanup here
				# is a fallback for exceptions in the primary timeout path above.
			}
		}
		$Process.Dispose()
	}

	return [pscustomobject]@{
		CompletedWithinTimeout = $CompletedWithinTimeout
		ExitCode = $ExitCode
		StandardOutput = $StandardOutput
		StandardError = $StandardError
	}
}

function Invoke-DeliveryLauncherForcedOwnerExitProbe {
	param(
		[Parameter(Mandatory)]
		[string]$LockRoot
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
	$StartInfo.Arguments = (
		'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
		$PSCommandPath + '" -SuiteLockProbeMode HoldUntilKilled ' +
		'-SuiteLockProbeRoot "' + $LockRoot + '"'
	)
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Started = $false
	$HolderExited = $false
	$ObserverMutex = $null
	try {
		$Started = $Process.Start()
		if (-not $Started) {
			throw 'Could not start the forced-owner-exit suite-lock probe.'
		}
		$ReadyTask = $Process.StandardOutput.ReadLineAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		if (-not $ReadyTask.Wait(10000) -or $ReadyTask.Result -cne 'suite-lock-held') {
			throw 'Forced-owner-exit probe did not report lock acquisition.'
		}
		$ObserverRights = [System.Security.AccessControl.MutexRights]::Modify -bor
			[System.Security.AccessControl.MutexRights]::Synchronize
		$ObserverMutex = [System.Threading.Mutex]::OpenExisting(
			(Get-DeliveryLauncherSuiteMutexName -WorktreeRoot $LockRoot),
			$ObserverRights
		)
		$BlockedProbe = Invoke-DeliveryLauncherSuiteLockProbe `
			-Mode AcquireOnly -LockRoot $LockRoot -TimeoutMilliseconds 10000
		$Process.Kill()
		$HolderExited = $Process.WaitForExit(5000)
		if (-not $HolderExited) {
			throw 'Forced-owner-exit suite-lock holder remained active after cleanup.'
		}
		$HolderError = $ErrorTask.GetAwaiter().GetResult()
		$ReleasedProbe = Invoke-DeliveryLauncherSuiteLockProbe `
			-Mode ReportAbandoned -LockRoot $LockRoot -TimeoutMilliseconds 10000
		return [pscustomobject]@{
			HolderExited = $HolderExited
			HolderError = $HolderError
			BlockedProbe = $BlockedProbe
			ReleasedProbe = $ReleasedProbe
		}
	}
	finally {
		if ($Started -and -not $Process.HasExited) {
			$Process.Kill()
			[void]$Process.WaitForExit(5000)
		}
		if ($null -ne $ObserverMutex) {
			$ObserverMutex.Dispose()
		}
		$Process.Dispose()
	}
}

$SuiteLockProbeTimeoutMilliseconds = 10000

# While this process holds the suite lock, a bounded non-recursive probe for
# the same worktree must return exactly one stable diagnostic and no stdout.
$ConcurrentSuiteProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
$ExpectedSuiteLockError = (
	Get-DeliveryLauncherSuiteLockDiagnostic -WorktreeRoot $SuiteLockRoot
) + [Environment]::NewLine
Add-Result `
	-Name 'Concurrent suite invocation in the same worktree fails fast on the lock' `
	-Passed (
		$ConcurrentSuiteProbe.CompletedWithinTimeout -and
		$ConcurrentSuiteProbe.ExitCode -eq 1 -and
		$ConcurrentSuiteProbe.StandardOutput -ceq '' -and
		$ConcurrentSuiteProbe.StandardError -ceq $ExpectedSuiteLockError
	) `
	-Detail (
		'completed=' + $ConcurrentSuiteProbe.CompletedWithinTimeout +
		'; exit=' + $ConcurrentSuiteProbe.ExitCode +
		'; stdoutLength=' + $ConcurrentSuiteProbe.StandardOutput.Length +
		'; stderrLength=' + $ConcurrentSuiteProbe.StandardError.Length
	)

$AlternateTempProbeRoot = Join-Path $TestRoot 'alternate-process-temp'
New-Item -ItemType Directory -Path $AlternateTempProbeRoot | Out-Null
$AlternateTempSuiteProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $RepositoryRoot `
	-ProcessEnvironment @{
		TEMP = $AlternateTempProbeRoot
		TMP = $AlternateTempProbeRoot
		LOCALAPPDATA = $AlternateTempProbeRoot
	} `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Same worktree lock identity is independent of user temp and app-data variables' `
	-Passed (
		$AlternateTempSuiteProbe.CompletedWithinTimeout -and
		$AlternateTempSuiteProbe.ExitCode -eq 1 -and
		$AlternateTempSuiteProbe.StandardOutput -ceq '' -and
		$AlternateTempSuiteProbe.StandardError -ceq $ExpectedSuiteLockError
	) `
	-Detail (
		'completed=' + $AlternateTempSuiteProbe.CompletedWithinTimeout +
		'; exit=' + $AlternateTempSuiteProbe.ExitCode +
		'; stdoutLength=' + $AlternateTempSuiteProbe.StandardOutput.Length +
		'; stderrLength=' + $AlternateTempSuiteProbe.StandardError.Length
	)

$EquivalentSuiteLockRoot = $RepositoryRoot.ToUpperInvariant().Replace('\', '/') + '/'
$EquivalentRootSuiteProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $EquivalentSuiteLockRoot `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Equivalent case-separator worktree spelling shares the suite lock' `
	-Passed (
		$EquivalentRootSuiteProbe.CompletedWithinTimeout -and
		$EquivalentRootSuiteProbe.ExitCode -eq 1 -and
		$EquivalentRootSuiteProbe.StandardOutput -ceq '' -and
		$EquivalentRootSuiteProbe.StandardError -ceq $ExpectedSuiteLockError
	) `
	-Detail (
		'completed=' + $EquivalentRootSuiteProbe.CompletedWithinTimeout +
		'; exit=' + $EquivalentRootSuiteProbe.ExitCode +
		'; stdoutLength=' + $EquivalentRootSuiteProbe.StandardOutput.Length +
		'; stderrLength=' + $EquivalentRootSuiteProbe.StandardError.Length
	)

$JunctionSuiteLockRoot = Join-Path $TestRoot 'junction-worktree-alias'
$null = New-Item -ItemType Junction -Path $JunctionSuiteLockRoot `
	-Target $RepositoryRoot -ErrorAction Stop
try {
	$JunctionRootSuiteProbe = Invoke-DeliveryLauncherSuiteLockProbe `
		-Mode AcquireOnly `
		-LockRoot $JunctionSuiteLockRoot `
		-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
}
finally {
	$JunctionItem = Get-Item -LiteralPath $JunctionSuiteLockRoot -Force -ErrorAction Stop
	if (
		$JunctionItem.LinkType -cne 'Junction' -or
		-not ($JunctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
		[IO.Path]::GetFullPath([string]$JunctionItem.Target) -ine
			[IO.Path]::GetFullPath($RepositoryRoot)
	) {
		throw 'Junction suite-lock probe cannot safely remove its temporary alias.'
	}
	[IO.Directory]::Delete($JunctionSuiteLockRoot, $false)
}
Add-Result `
	-Name 'Junction alias of the same physical worktree shares the suite lock' `
	-Passed (
		$JunctionRootSuiteProbe.CompletedWithinTimeout -and
		$JunctionRootSuiteProbe.ExitCode -eq 1 -and
		$JunctionRootSuiteProbe.StandardOutput -ceq '' -and
		$JunctionRootSuiteProbe.StandardError -like `
			'Test-DeliveryStageLauncher.ps1: another instance owns the delivery*' -and
		-not (Test-Path -LiteralPath $JunctionSuiteLockRoot)
	) `
	-Detail (
		'completed=' + $JunctionRootSuiteProbe.CompletedWithinTimeout +
		'; exit=' + $JunctionRootSuiteProbe.ExitCode +
		'; stdoutLength=' + $JunctionRootSuiteProbe.StandardOutput.Length +
		'; stderrLength=' + $JunctionRootSuiteProbe.StandardError.Length
	)

$DistinctLockProbeRoot = Join-Path $TestRoot 'distinct-worktree-lock-probe'
New-Item -ItemType Directory -Path $DistinctLockProbeRoot | Out-Null
& git init --quiet -- $DistinctLockProbeRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw 'Could not initialize distinct temporary Git checkout for suite-lock test.'
}
$DistinctLockProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $DistinctLockProbeRoot `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Distinct worktree lock identity remains independently available' `
	-Passed (
		$DistinctLockProbe.CompletedWithinTimeout -and
		$DistinctLockProbe.ExitCode -eq 0 -and
		$DistinctLockProbe.StandardOutput -ceq '' -and
		$DistinctLockProbe.StandardError -ceq ''
	) `
	-Detail (
		'completed=' + $DistinctLockProbe.CompletedWithinTimeout +
		'; exit=' + $DistinctLockProbe.ExitCode
	)

$DeniedLockProbeRoot = Join-Path $TestRoot 'access-denied-lock-probe'
New-Item -ItemType Directory -Path $DeniedLockProbeRoot | Out-Null
$DeniedMutexName = Get-DeliveryLauncherSuiteMutexName `
	-WorktreeRoot $DeniedLockProbeRoot
$DeniedMutexSecurity = [System.Security.AccessControl.MutexSecurity]::new()
$Everyone = [System.Security.Principal.SecurityIdentifier]::new(
	[System.Security.Principal.WellKnownSidType]::WorldSid,
	$null
)
$DenyRule = [System.Security.AccessControl.MutexAccessRule]::new(
	$Everyone,
	[System.Security.AccessControl.MutexRights]::FullControl,
	[System.Security.AccessControl.AccessControlType]::Deny
)
$DeniedMutexSecurity.AddAccessRule($DenyRule)
$DeniedMutexCreated = $false
$DeniedMutex = [System.Threading.Mutex]::new(
	$false, $DeniedMutexName, [ref]$DeniedMutexCreated, $DeniedMutexSecurity
)
try {
	$DeniedLockProbe = Invoke-DeliveryLauncherSuiteLockProbe `
		-Mode AcquireOnly -LockRoot $DeniedLockProbeRoot `
		-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
}
finally {
	$DeniedMutex.Dispose()
}
Add-Result `
	-Name 'Access-denied global mutex fails closed without alternate namespace' `
	-Passed (
		$DeniedLockProbe.CompletedWithinTimeout -and
		$DeniedLockProbe.ExitCode -eq 1 -and
		$DeniedLockProbe.StandardOutput -ceq '' -and
		$DeniedLockProbe.StandardError -like `
			'Test-DeliveryStageLauncher.ps1: cannot establish the machine-global*'
	) `
	-Detail (
		'completed=' + $DeniedLockProbe.CompletedWithinTimeout +
		'; exit=' + $DeniedLockProbe.ExitCode +
		'; stdoutLength=' + $DeniedLockProbe.StandardOutput.Length +
		'; stderrLength=' + $DeniedLockProbe.StandardError.Length
	)

$LimitedRightsProbeRoot = Join-Path $TestRoot 'limited-rights-lock-probe'
New-Item -ItemType Directory -Path $LimitedRightsProbeRoot | Out-Null
$LimitedRightsMutexName = Get-DeliveryLauncherSuiteMutexName `
	-WorktreeRoot $LimitedRightsProbeRoot
$LimitedRightsSecurity = New-DeliveryLauncherSuiteMutexSecurity
$DeniedAdministrationRights =
	[System.Security.AccessControl.MutexRights]::ReadPermissions -bor
	[System.Security.AccessControl.MutexRights]::ChangePermissions -bor
	[System.Security.AccessControl.MutexRights]::TakeOwnership -bor
	[System.Security.AccessControl.MutexRights]::Delete
$LimitedRightsSecurity.AddAccessRule(
	[System.Security.AccessControl.MutexAccessRule]::new(
		$Everyone,
		$DeniedAdministrationRights,
		[System.Security.AccessControl.AccessControlType]::Deny
	)
)
$LimitedRightsCreated = $false
$LimitedRightsMutex = [System.Threading.Mutex]::new(
	$false, $LimitedRightsMutexName, [ref]$LimitedRightsCreated,
	$LimitedRightsSecurity
)
$LimitedRightsOwned = $false
try {
	$LimitedRightsOwned = $LimitedRightsMutex.WaitOne(0)
	if (-not $LimitedRightsOwned) {
		throw 'Limited-rights mutex fixture could not be acquired.'
	}
	$LimitedRightsProbe = Invoke-DeliveryLauncherSuiteLockProbe `
		-Mode AcquireOnly -LockRoot $LimitedRightsProbeRoot `
		-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
}
finally {
	if ($LimitedRightsOwned) { $LimitedRightsMutex.ReleaseMutex() }
	$LimitedRightsMutex.Dispose()
}
Add-Result `
	-Name 'Limited-rights existing global mutex still rejects a contender as owned' `
	-Passed (
		$LimitedRightsProbe.CompletedWithinTimeout -and
		$LimitedRightsProbe.ExitCode -eq 1 -and
		$LimitedRightsProbe.StandardOutput -ceq '' -and
		$LimitedRightsProbe.StandardError -like `
			'Test-DeliveryStageLauncher.ps1: another instance owns the delivery*'
	) `
	-Detail (
		'completed=' + $LimitedRightsProbe.CompletedWithinTimeout +
		'; exit=' + $LimitedRightsProbe.ExitCode +
		'; stdoutLength=' + $LimitedRightsProbe.StandardOutput.Length +
		'; stderrLength=' + $LimitedRightsProbe.StandardError.Length
	)

$GitOverrideSuiteProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $RepositoryRoot `
	-ProcessEnvironment @{
		GIT_DIR = (Join-Path $DistinctLockProbeRoot '.git')
		GIT_WORK_TREE = $DistinctLockProbeRoot
		GIT_COMMON_DIR = (Join-Path $DistinctLockProbeRoot '.git')
	} `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Inherited Git directory overrides cannot redirect the worktree suite lock' `
	-Passed (
		$GitOverrideSuiteProbe.CompletedWithinTimeout -and
		$GitOverrideSuiteProbe.ExitCode -eq 1 -and
		$GitOverrideSuiteProbe.StandardOutput -ceq '' -and
		$GitOverrideSuiteProbe.StandardError -ceq $ExpectedSuiteLockError
	) `
	-Detail (
		'completed=' + $GitOverrideSuiteProbe.CompletedWithinTimeout +
		'; exit=' + $GitOverrideSuiteProbe.ExitCode +
		'; stdoutLength=' + $GitOverrideSuiteProbe.StandardOutput.Length +
		'; stderrLength=' + $GitOverrideSuiteProbe.StandardError.Length
	)

$StaleLockProbeRoot = Join-Path $TestRoot 'stale-owner-lock-probe'
New-Item -ItemType Directory -Path $StaleLockProbeRoot | Out-Null
$ExitedOwnerProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $StaleLockProbeRoot `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
$StaleLockProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode AcquireOnly `
	-LockRoot $StaleLockProbeRoot `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Exited suite-lock owner does not block later acquisition' `
	-Passed (
		$ExitedOwnerProbe.CompletedWithinTimeout -and
		$ExitedOwnerProbe.ExitCode -eq 0 -and
		$StaleLockProbe.CompletedWithinTimeout -and
		$StaleLockProbe.ExitCode -eq 0 -and
		$StaleLockProbe.StandardOutput -ceq '' -and
		$StaleLockProbe.StandardError -ceq ''
	) `
	-Detail (
		'completed=' + $StaleLockProbe.CompletedWithinTimeout +
		'; exit=' + $StaleLockProbe.ExitCode
	)

$ForcedExitLockRoot = Join-Path $TestRoot 'forced-owner-exit-lock-probe'
New-Item -ItemType Directory -Path $ForcedExitLockRoot | Out-Null
$ForcedOwnerExitProbe = Invoke-DeliveryLauncherForcedOwnerExitProbe `
	-LockRoot $ForcedExitLockRoot
Add-Result `
	-Name 'Forced owner termination transfers abandoned mutex ownership safely' `
	-Passed (
		$ForcedOwnerExitProbe.HolderExited -and
		$ForcedOwnerExitProbe.HolderError -ceq '' -and
		$ForcedOwnerExitProbe.BlockedProbe.CompletedWithinTimeout -and
		$ForcedOwnerExitProbe.BlockedProbe.ExitCode -eq 1 -and
		$ForcedOwnerExitProbe.BlockedProbe.StandardOutput -ceq '' -and
		$ForcedOwnerExitProbe.BlockedProbe.StandardError -like `
			'Test-DeliveryStageLauncher.ps1: another instance owns the delivery*' -and
		$ForcedOwnerExitProbe.ReleasedProbe.CompletedWithinTimeout -and
		$ForcedOwnerExitProbe.ReleasedProbe.ExitCode -eq 0 -and
		$ForcedOwnerExitProbe.ReleasedProbe.StandardOutput -ceq `
			('suite-lock-abandoned' + [Environment]::NewLine) -and
		$ForcedOwnerExitProbe.ReleasedProbe.StandardError -ceq ''
	) `
	-Detail (
		'holderExited=' + $ForcedOwnerExitProbe.HolderExited +
		'; blockedExit=' + $ForcedOwnerExitProbe.BlockedProbe.ExitCode +
		'; reacquireExit=' + $ForcedOwnerExitProbe.ReleasedProbe.ExitCode
	)

$FailureReleaseProbeRoot = Join-Path $TestRoot 'failure-release-lock-probe'
New-Item -ItemType Directory -Path $FailureReleaseProbeRoot | Out-Null
& git init --quiet -- $FailureReleaseProbeRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw 'Could not initialize failure-release temporary Git checkout for suite-lock test.'
}
$FailureReleaseProbe = Invoke-DeliveryLauncherSuiteLockProbe `
	-Mode FailureRelease `
	-LockRoot $FailureReleaseProbeRoot `
	-TimeoutMilliseconds $SuiteLockProbeTimeoutMilliseconds
Add-Result `
	-Name 'Post-acquisition failure releases the suite lock in the same process' `
	-Passed (
		$FailureReleaseProbe.CompletedWithinTimeout -and
		$FailureReleaseProbe.ExitCode -eq 0 -and
		$FailureReleaseProbe.StandardOutput -ceq '' -and
		$FailureReleaseProbe.StandardError -ceq ''
	) `
	-Detail (
		'completed=' + $FailureReleaseProbe.CompletedWithinTimeout +
		'; exit=' + $FailureReleaseProbe.ExitCode
	)

if ($SuiteLockProbeMode -eq 'LockAssertions') {
	$Results | Format-Table -AutoSize
	$Failed = @($Results | Where-Object { -not $_.Passed })
	if ($Failed.Count -gt 0) {
		throw "$($Failed.Count) delivery launcher suite-lock assertion(s) failed."
	}
	return
}

try {
	$AnalystHandoffPath = Join-Path $TestRoot 'analyst.json'
	@{
		schema_version = 1
		stage = 'analyst'
		run_id = 'test-analyst'
		workspace_root = $RepositoryRoot
		source_commit = $SourceCommit
		ticket = 'Issue #123'
		acceptance_criteria = @('Criterion')
		canonical_sources = @('AGENTS.md')
		output_contract = 'Return readiness evidence.'
		board_export = 'board.json'
		repository_tree = 'tree.txt'
		repository_state = 'status.txt'
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AnalystHandoffPath -Encoding UTF8

	$AnalystValidation = & $ValidateScript `
		-HandoffPath $AnalystHandoffPath `
		-SchemaPath $SchemaPath
	Add-Result -Name 'Valid analyst handoff passes' -Passed $true

	$OriginalHandoffBytes = [System.IO.File]::ReadAllBytes($AnalystHandoffPath)
	$ChangedHandoff = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
	$ChangedHandoff.run_id = 'replacement-run'
	$ChangedHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $AnalystHandoffPath `
		-Encoding UTF8
	$OriginalHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$OriginalHash = [System.BitConverter]::ToString(
			$OriginalHasher.ComputeHash($OriginalHandoffBytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$OriginalHasher.Dispose()
	}
	Add-Result `
		-Name 'Validated handoff bytes remain frozen' `
		-Passed (
			$AnalystValidation.RunId -eq 'test-analyst' -and
			$AnalystValidation.HandoffJson -match '"test-analyst"' -and
			$AnalystValidation.HandoffHash -eq $OriginalHash
		)
	[System.IO.File]::WriteAllBytes($AnalystHandoffPath, $OriginalHandoffBytes)

	$DefaultPolicy = $AnalystValidation.ExecutionPolicy
	Add-Result `
		-Name 'Absent execution policy receives normalized defaults' `
		-Passed (
			$DefaultPolicy.AttemptOrdinal -eq 1 -and
			$DefaultPolicy.AttemptClass -eq 'initial' -and
			$DefaultPolicy.CapabilityClass -eq 'standard' -and
			$null -eq $DefaultPolicy.RetryCause -and
			@($DefaultPolicy.Limits.PSObject.Properties.Value |
				Where-Object { $null -ne $_ }).Count -eq 0
		)

	$CompletePolicyPath = Join-Path $TestRoot 'complete-policy.json'
	$CompletePolicyHandoff = Get-Content -Raw -LiteralPath $AnalystHandoffPath |
		ConvertFrom-Json
	$CompletePolicyHandoff.run_id = 'complete-policy'
	$CompletePolicyHandoff | Add-Member -NotePropertyName execution_policy -NotePropertyValue ([pscustomobject]@{
		attempt_ordinal = 2
		attempt_class = 'replacement'
		capability_class = 'elevated'
		retry_cause = 'transient execution failure'
		limits = [pscustomobject]@{
			total_tokens = 100
			elapsed_milliseconds = 200
			concurrent_stages = 3
			execution_retries = 1
			fix_cycles = 2
			provenance = 'user-approved'
			approved_at_utc = '2026-07-27T12:34:56.123Z'
		}
	})
	$CompletePolicyHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $CompletePolicyPath -Encoding UTF8
	$CompletePolicyBytes = [System.IO.File]::ReadAllBytes($CompletePolicyPath)
	$CompletePolicyValidation = & $ValidateScript `
		-HandoffPath $CompletePolicyPath -SchemaPath $SchemaPath
	$CompletePolicyHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$CompletePolicyHash = [System.BitConverter]::ToString(
			$CompletePolicyHasher.ComputeHash($CompletePolicyBytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$CompletePolicyHasher.Dispose()
	}
	Add-Result `
		-Name 'Complete execution policy is normalized without changing handoff evidence' `
		-Passed (
			$CompletePolicyValidation.ExecutionPolicy.AttemptOrdinal -eq 2 -and
			$CompletePolicyValidation.ExecutionPolicy.AttemptClass -eq 'replacement' -and
			$CompletePolicyValidation.ExecutionPolicy.CapabilityClass -eq 'elevated' -and
			$CompletePolicyValidation.ExecutionPolicy.RetryCause -eq 'transient execution failure' -and
			$CompletePolicyValidation.ExecutionPolicy.Limits.TotalTokens -eq 100 -and
			$CompletePolicyValidation.ExecutionPolicy.Limits.ApprovedAtUtc -eq '2026-07-27T12:34:56.123Z' -and
			$CompletePolicyValidation.HandoffJson -eq [System.Text.Encoding]::UTF8.GetString($CompletePolicyBytes) -and
			$CompletePolicyValidation.HandoffHash -eq $CompletePolicyHash -and
			[object]::ReferenceEquals(
				$CompletePolicyValidation.Handoff.execution_policy,
				$CompletePolicyValidation.ExecutionPolicy
			) -eq $false
		)

	$InvalidPolicies = @(
		@('unknown policy property', '{"unexpected":true}', 'not allowed'),
		@('unknown limits property', '{"limits":{"unexpected":true}}', 'not allowed'),
		@('boolean ordinal', '{"attempt_ordinal":true}', 'attempt_ordinal'),
		@('string ordinal', '{"attempt_ordinal":"1"}', 'attempt_ordinal'),
		@('zero ordinal', '{"attempt_ordinal":0}', 'attempt_ordinal'),
		@('fractional ordinal', '{"attempt_ordinal":1.5}', 'attempt_ordinal'),
		@('invalid attempt class', '{"attempt_class":"retry"}', 'attempt_class'),
		@('invalid capability class', '{"capability_class":"premium"}', 'capability_class'),
		@('blank retry cause', '{"retry_cause":" "}', 'retry_cause'),
		@('numeric retry cause', '{"retry_cause":5}', 'retry_cause'),
		@('boolean numeric limit', '{"limits":{"total_tokens":true}}', 'total_tokens'),
		@('string numeric limit', '{"limits":{"total_tokens":"1"}}', 'total_tokens'),
		@('negative numeric limit', '{"limits":{"total_tokens":-1}}', 'total_tokens'),
		@('fractional numeric limit', '{"limits":{"total_tokens":1.5}}', 'total_tokens'),
		@('total tokens without approval', '{"limits":{"total_tokens":1}}', 'require.*provenance.*approved_at_utc'),
		@('elapsed milliseconds without approval', '{"limits":{"elapsed_milliseconds":1}}', 'require.*provenance.*approved_at_utc'),
		@('concurrent stages without approval', '{"limits":{"concurrent_stages":1}}', 'require.*provenance.*approved_at_utc'),
		@('execution retries without approval', '{"limits":{"execution_retries":1}}', 'require.*provenance.*approved_at_utc'),
		@('fix cycles without approval', '{"limits":{"fix_cycles":1}}', 'require.*provenance.*approved_at_utc'),
		@('numeric limit without approval time', '{"limits":{"total_tokens":1,"provenance":"user-approved"}}', 'require.*provenance.*approved_at_utc'),
		@('numeric limit without provenance', '{"limits":{"total_tokens":1,"approved_at_utc":"2026-07-27T12:34:56Z"}}', 'require.*provenance.*approved_at_utc'),
		@('blank provenance', '{"limits":{"provenance":" "}}', 'provenance'),
		@('numeric provenance', '{"limits":{"provenance":5}}', 'provenance'),
		@('offset timestamp', '{"limits":{"approved_at_utc":"2026-07-27T12:34:56+00:00"}}', 'approved_at_utc'),
		@('invalid timestamp', '{"limits":{"approved_at_utc":"2026-02-30T12:34:56Z"}}', 'approved_at_utc'),
		@('numeric timestamp', '{"limits":{"approved_at_utc":5}}', 'approved_at_utc'),
		@('null policy', 'null', 'JSON object'),
		@('array limits', '{"limits":[]}', 'JSON object')
	)
	foreach ($InvalidPolicy in $InvalidPolicies) {
		$InvalidPolicyPath = Join-Path $TestRoot (
			'invalid-policy-' + ($InvalidPolicy[0] -replace ' ', '-') + '.json'
		)
		$InvalidPolicyJson = Get-Content -Raw -LiteralPath $AnalystHandoffPath |
			ConvertFrom-Json
		$InvalidPolicyJson.run_id = 'invalid-policy-' + ($InvalidPolicy[0] -replace ' ', '-')
		$InvalidPolicyValue = $InvalidPolicy[1] | ConvertFrom-Json
		$InvalidPolicyJson | Add-Member `
			-NotePropertyName execution_policy `
			-NotePropertyValue $InvalidPolicyValue
		$InvalidPolicyJson | ConvertTo-Json -Depth 8 | Set-Content `
			-LiteralPath $InvalidPolicyPath -Encoding UTF8
		$InvalidPolicyRejected = Invoke-ExpectedFailure `
			-Pattern $InvalidPolicy[2] `
			-Action {
				& $ValidateScript `
					-HandoffPath $InvalidPolicyPath `
					-SchemaPath $SchemaPath | Out-Null
			}
		Add-Result `
			-Name "Execution policy rejects $($InvalidPolicy[0])" `
			-Passed $InvalidPolicyRejected
	}

	$GateStages = @('verifier', 'reviewer', 'approver', 'adjudicator', 'qa')
	foreach ($GateStage in $GateStages) {
		$GateHandoffPath = Join-Path $TestRoot "economy-$GateStage.json"
		$GateSchema = (Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json).stages.$GateStage
		$GateHandoff = [ordered]@{
			schema_version = 1; stage = $GateStage; run_id = "economy-$GateStage"
			workspace_root = $RepositoryRoot; source_commit = $SourceCommit
			ticket = 'Issue #123'; acceptance_criteria = @('Criterion')
			canonical_sources = @('AGENTS.md'); output_contract = 'Return evidence.'
			execution_policy = @{ capability_class = 'economy' }
		}
		$RequiredEvidenceSources = @()
		foreach ($RequiredName in @($GateSchema.required)) {
			if ($RequiredName -ceq 'required_evidence_sources') {
				continue
			}

			$NeutralField = $GateSchema.neutral_evidence_fields.PSObject.Properties[
				$RequiredName
			]
			if ($null -eq $NeutralField) {
				$GateHandoff[$RequiredName] = 'raw evidence'
				continue
			}

			$NeutralParts = [string]$NeutralField.Value -split ':', 3
			$Cardinality = $NeutralParts[0]
			$Kind = ($NeutralParts[1] -split '\|')[0]
			$Provenance = ($NeutralParts[2] -split '\|')[0]
			$NeutralSource = "economy-$GateStage-$RequiredName"
			$AuthoritativeSources = @(
				@($GateSchema.authoritative_evidence_sources) |
					Where-Object { $_.field -ceq $RequiredName }
			)
			if ($AuthoritativeSources.Count -eq 1) {
				$Kind = $AuthoritativeSources[0].kind
				$Provenance = $AuthoritativeSources[0].provenance
				$NeutralSource = $AuthoritativeSources[0].source
			}
			$NeutralRecord = New-NeutralEvidenceRecord `
				-Kind $Kind `
				-Provenance $Provenance `
				-Source $NeutralSource `
				-Text 'raw evidence'
			if ($Cardinality -eq 'array') {
				$GateHandoff[$RequiredName] = [object[]]@($NeutralRecord)
			} else {
				$GateHandoff[$RequiredName] = $NeutralRecord
			}
			$RequiredEvidenceSources += New-RequiredEvidenceDeclaration `
				-Field $RequiredName `
				-Record $NeutralRecord
		}
		if (@($GateSchema.required) -ccontains 'required_evidence_sources') {
			$GateHandoff['required_evidence_sources'] = `
				[object[]]$RequiredEvidenceSources
		}
		$GateHandoff | ConvertTo-Json -Depth 8 | Set-Content `
			-LiteralPath $GateHandoffPath -Encoding UTF8
		$GateValidationParameters = @{
			HandoffPath = $GateHandoffPath
			SchemaPath = $SchemaPath
		}
		if (@('verifier', 'approver') -ccontains $GateStage) {
			$GateManifest = New-FrozenAuthoritativeEvidenceManifest `
				-Stage $GateStage `
				-Handoff $GateHandoff `
				-Name "economy-$GateStage"
			$GateValidationParameters['AuthoritativeEvidenceManifestBytes'] = `
				$GateManifest.Bytes
			$GateValidationParameters['ExpectedAuthoritativeEvidenceManifestSha256'] = `
				$GateManifest.Sha256
		}
		$EconomyRejected = Invoke-ExpectedFailure -Pattern 'economy.*not allowed' -Action {
			& $ValidateScript @GateValidationParameters | Out-Null
		}
		Add-Result -Name "Economy capability is rejected for $GateStage" -Passed $EconomyRejected
	}

	$AdjudicatorDefaultPath = Join-Path $TestRoot 'adjudicator-default.json'
	@{
		schema_version = 1; stage = 'adjudicator'; run_id = 'adjudicator-default'
		workspace_root = $RepositoryRoot; source_commit = $SourceCommit
		ticket = 'Issue #123'; acceptance_criteria = @('Criterion')
		canonical_sources = @('AGENTS.md'); output_contract = 'Return decision.'
		neutral_question = 'What evidence governs?'
		raw_evidence = @(
			New-NeutralEvidenceRecord -Kind text -Provenance control_plane `
				-Source 'adjudicator-default' -Text 'raw evidence'
		)
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AdjudicatorDefaultPath -Encoding UTF8
	$AdjudicatorDefault = & $ValidateScript `
		-HandoffPath $AdjudicatorDefaultPath -SchemaPath $SchemaPath
	Add-Result `
		-Name 'Adjudicator defaults to elevated capability' `
		-Passed ($AdjudicatorDefault.ExecutionPolicy.CapabilityClass -eq 'elevated')

	$AnalystDryRun = & $LaunchScript -HandoffPath $AnalystHandoffPath -DryRun -PassThru
	Add-Result `
		-Name 'Read-only stage dry run disables external tools' `
		-Passed (
			$AnalystDryRun.SandboxMode -eq 'read-only' -and
			$AnalystDryRun.Arguments -contains '--ignore-user-config' -and
			$AnalystDryRun.Arguments -contains 'apps' -and
			$AnalystDryRun.Arguments -contains 'mcp_servers={}' -and
			@($AnalystDryRun.Arguments | Where-Object {
				$_ -match '^features\.shell_tool='
			}).Count -eq 0 -and
			@($AnalystDryRun.Arguments | Where-Object {
				$_ -match '^mcp_servers\.source_inspection\.'
			}).Count -eq 0 -and
			@($AnalystDryRun.Arguments | Where-Object {
				$_ -ceq (
					'mcp_servers.source_inspection.tools.read_allowed_source_file.' +
					'approval_mode=''approve'''
				)
			}).Count -eq 0
		)
}
catch {
	Add-Result -Name 'Valid analyst handoff passes' -Passed $false -Detail $_.Exception.Message
	Add-Result `
		-Name 'Validated handoff bytes remain frozen' `
		-Passed $false `
		-Detail $_.Exception.Message
	Add-Result `
		-Name 'Read-only stage dry run disables external tools' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$VerifierHandoffPath = Join-Path $TestRoot 'verifier-with-verdict.json'
$VerifierCandidateArtifact = New-NeutralEvidenceRecord -Kind artifact `
	-Provenance launcher -Source 'candidate.patch' -Text 'candidate patch'
$VerifierLinuxBuildLog = New-NeutralEvidenceRecord -Kind command_log `
	-Provenance launcher -Source 'linux-server-build-log' `
	-Text 'Linux server build passed.'
$VerifierCheckOutput = New-NeutralEvidenceRecord -Kind command_log `
	-Provenance launcher -Source 'verifier-check-output' -Text 'check completed'
$VerifierRequiredEvidenceSources = @(
	(New-RequiredEvidenceDeclaration -Field 'candidate_artifact' `
		-Record $VerifierCandidateArtifact),
	(New-RequiredEvidenceDeclaration -Field 'raw_check_output' `
		-Record $VerifierLinuxBuildLog),
	(New-RequiredEvidenceDeclaration -Field 'raw_check_output' `
		-Record $VerifierCheckOutput)
)
@{
	schema_version = 1
	stage = 'verifier'
	run_id = 'test-verifier'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return verification evidence.'
	candidate_artifact = $VerifierCandidateArtifact
	test_environment = 'local'
	commands = @('git diff --check')
	raw_check_output = @(
		$VerifierLinuxBuildLog
		$VerifierCheckOutput
	)
	required_evidence_sources = $VerifierRequiredEvidenceSources
	prior_findings = @('Expected to pass')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $VerifierHandoffPath -Encoding UTF8

$VerifierManifest = New-FrozenAuthoritativeEvidenceManifest `
	-Stage 'verifier' `
	-Handoff (Get-Content -Raw -LiteralPath $VerifierHandoffPath | ConvertFrom-Json) `
	-Name 'test-verifier'
$BlindFailure = Invoke-ExpectedFailure -Pattern 'not allowed|prohibited' -Action {
	& $ValidateScript `
		-HandoffPath $VerifierHandoffPath `
		-SchemaPath $SchemaPath `
		-AuthoritativeEvidenceManifestBytes $VerifierManifest.Bytes `
		-ExpectedAuthoritativeEvidenceManifestSha256 $VerifierManifest.Sha256 |
		Out-Null
}
Add-Result -Name 'Blind verifier rejects prior verdict fields' -Passed $BlindFailure

$VerifierStringBypassPath = Join-Path $TestRoot 'verifier-string-bypass.json'
$VerifierStringBypass = Get-Content -Raw -LiteralPath $VerifierHandoffPath |
	ConvertFrom-Json
$VerifierStringBypass.PSObject.Properties.Remove('prior_findings')
$VerifierStringBypass.run_id = 'test-verifier-string-bypass'
$VerifierStringBypass.candidate_artifact = New-NeutralEvidenceRecord `
	-Kind artifact -Provenance launcher -Source 'candidate.patch' `
	-Text 'candidate.patch with prior_verdict embedded'
$VerifierStringBypass.required_evidence_sources[0] = `
	New-RequiredEvidenceDeclaration -Field 'candidate_artifact' `
		-Record $VerifierStringBypass.candidate_artifact
$VerifierStringBypass | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $VerifierStringBypassPath -Encoding UTF8
$VerifierStringBypassManifest = New-FrozenAuthoritativeEvidenceManifest `
	-Stage 'verifier' `
	-Handoff $VerifierStringBypass `
	-Name 'test-verifier-string-bypass'
& $ValidateScript `
	-HandoffPath $VerifierStringBypassPath `
	-SchemaPath $SchemaPath `
	-AuthoritativeEvidenceManifestBytes $VerifierStringBypassManifest.Bytes `
	-ExpectedAuthoritativeEvidenceManifestSha256 $VerifierStringBypassManifest.Sha256 |
	Out-Null
Add-Result `
	-Name 'Blind verifier treats validated typed content as opaque' `
	-Passed $true

$VerifierNestedBypassPath = Join-Path $TestRoot 'verifier-nested-bypass.json'
$VerifierNestedBypass = Get-Content -Raw -LiteralPath $VerifierHandoffPath |
	ConvertFrom-Json
$VerifierNestedBypass.PSObject.Properties.Remove('prior_findings')
$VerifierNestedBypass.run_id = 'test-verifier-nested-bypass'
$VerifierNestedBypass.candidate_artifact = New-NeutralEvidenceRecord `
	-Kind artifact -Provenance launcher -Source 'candidate.patch' `
	-Text 'candidate patch'
$VerifierNestedBypass.required_evidence_sources[0] = `
	New-RequiredEvidenceDeclaration -Field 'candidate_artifact' `
		-Record $VerifierNestedBypass.candidate_artifact
$NestedEvidenceValue = 'do-not-expose-agent-summary'
$VerifierNestedBypass.candidate_artifact | Add-Member `
	-NotePropertyName agent_summary `
	-NotePropertyValue $NestedEvidenceValue
$VerifierNestedBypass | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $VerifierNestedBypassPath -Encoding UTF8
$VerifierNestedBypassManifest = New-FrozenAuthoritativeEvidenceManifest `
	-Stage 'verifier' `
	-Handoff $VerifierNestedBypass `
	-Name 'test-verifier-nested-bypass'
$BlindNestedBypassError = ''
try {
	& $ValidateScript `
		-HandoffPath $VerifierNestedBypassPath `
		-SchemaPath $SchemaPath `
		-AuthoritativeEvidenceManifestBytes $VerifierNestedBypassManifest.Bytes `
		-ExpectedAuthoritativeEvidenceManifestSha256 $VerifierNestedBypassManifest.Sha256 |
		Out-Null
}
catch {
	$BlindNestedBypassError = $_.Exception.Message
}
Add-Result `
	-Name 'Blind verifier rejects an extra neutral evidence key without exposing its value' `
	-Passed (
		$BlindNestedBypassError -match 'neutral_evidence_keys_invalid' -and
		$BlindNestedBypassError -notmatch [regex]::Escape($NestedEvidenceValue)
	)

$UnsafeRunIdPath = Join-Path $TestRoot 'unsafe-run-id.json'
@{
	schema_version = 1
	stage = 'analyst'
	run_id = '..\AGENTS'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return readiness evidence.'
	board_export = 'board.json'
	repository_tree = 'tree.txt'
	repository_state = 'status.txt'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $UnsafeRunIdPath -Encoding UTF8

$UnsafeRunIdFailure = Invoke-ExpectedFailure -Pattern 'run_id|safe' -Action {
	& $ValidateScript -HandoffPath $UnsafeRunIdPath -SchemaPath $SchemaPath | Out-Null
}
Add-Result -Name 'Unsafe run ID is rejected' -Passed $UnsafeRunIdFailure

$InvalidSourcePath = Join-Path $TestRoot 'invalid-source.json'
$InvalidSource = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
$InvalidSource.run_id = 'test-invalid-source'
$InvalidSource.source_commit = '0000000000000000000000000000000000000000'
$InvalidSource | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InvalidSourcePath -Encoding UTF8
$InvalidSourceFailure = Invoke-ExpectedFailure -Pattern 'source_commit|valid Git' -Action {
	& $LaunchScript -HandoffPath $InvalidSourcePath -DryRun | Out-Null
}
Add-Result -Name 'Unknown source commit is rejected' -Passed $InvalidSourceFailure

$ExternalRootPath = Join-Path $TestRoot 'external-root.json'
$ExternalRoot = Get-Content -Raw -LiteralPath $AnalystHandoffPath | ConvertFrom-Json
$ExternalRoot.run_id = 'test-external-root'
$ExternalRoot.workspace_root = $TestRoot
$ExternalRoot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ExternalRootPath -Encoding UTF8
$ExternalRootFailure = Invoke-ExpectedFailure -Pattern 'configured repository' -Action {
	& $LaunchScript -HandoffPath $ExternalRootPath -DryRun | Out-Null
}
Add-Result -Name 'External workspace root is rejected' -Passed $ExternalRootFailure

$SensitiveRepositoryRoot = Join-Path $TestRoot 'snapshot-sensitive-repository'
New-Item -ItemType Directory -Path $SensitiveRepositoryRoot | Out-Null
& git -C $SensitiveRepositoryRoot init --quiet
$SensitiveFixturePath = Join-Path $SensitiveRepositoryRoot 'snapshot-sensitive-test.pem'
Set-Content -LiteralPath $SensitiveFixturePath -Value 'not-a-secret' -Encoding UTF8
$SensitivePathRejected = Invoke-ExpectedFailure -Pattern 'sensitive path' -Action {
	& $SnapshotScript -RepositoryRoot $SensitiveRepositoryRoot | Out-Null
}
Add-Result -Name 'Sensitive repository path fails closed' -Passed $SensitivePathRejected

$SpecialPathList = "plain.txt`0folder`tname.pem`0line`nname.txt`0"
$ParsedSpecialPaths = @(& $PathSplitScript -RawPaths $SpecialPathList)
Add-Result `
	-Name 'NUL path parser preserves special characters' `
	-Passed (
		$ParsedSpecialPaths.Count -eq 3 -and
		$ParsedSpecialPaths[1] -eq "folder`tname.pem" -and
		$ParsedSpecialPaths[2] -eq "line`nname.txt"
	)
$SnapshotSource = Get-Content -Raw -LiteralPath $SnapshotScript
Add-Result `
	-Name 'Git inventory uses binary-safe output capture' `
	-Passed (
		$SnapshotSource -match 'StandardOutput\.BaseStream\.CopyTo' -and
		$SnapshotSource -notmatch '\& git .+ ls-files'
	)
Add-Result `
	-Name 'Special-character sensitive path is classified' `
	-Passed (& $SensitivePathScript -RelativePath "folder`tname.pem")

$SensitiveCases = @(
	'id_rsa',
	'.npmrc',
	'.netrc',
	'auth.json',
	'kubeconfig',
	'.docker/credentials.json',
	'config/client_secret_game.json',
	'service-account-development.json'
)
$NonSensitiveCases = @(
	'docs/security-and-operations.md',
	'docs/authentication-overview.md',
	'Config/DefaultGame.ini'
)
$SensitiveTablePassed = @(
	$SensitiveCases | Where-Object {
		-not (& $SensitivePathScript -RelativePath $_)
	}
).Count -eq 0 -and @(
	$NonSensitiveCases | Where-Object {
		& $SensitivePathScript -RelativePath $_
	}
).Count -eq 0
Add-Result `
	-Name 'Credential filename table is fail-closed' `
	-Passed $SensitiveTablePassed

$ReparseTarget = Join-Path $TestRoot 'reparse-target'
$ReparseLink = Join-Path $TestRoot 'reparse-link'
New-Item -ItemType Directory -Path $ReparseTarget | Out-Null
Set-Content -LiteralPath (Join-Path $ReparseTarget 'fixture.txt') -Value 'fixture' -Encoding UTF8
$ReparseCreated = $true
try {
	New-Item -ItemType Junction -Path $ReparseLink -Target $ReparseTarget | Out-Null
}
catch {
	$ReparseCreated = $false
}
$ReparseRejected = if ($ReparseCreated) {
	Invoke-ExpectedFailure -Pattern 'reparse point' -Action {
		& $ReparseCheckScript `
			-Path (Join-Path $ReparseLink 'fixture.txt') `
			-Root $TestRoot
	}
}
else {
	$false
}
Add-Result `
	-Name 'Reparse-point ancestor fails closed' `
	-Passed $ReparseRejected `
	-Detail $(if ($ReparseCreated) { '' } else { 'Could not create test junction.' })

$ReparseRepositoryRoot = Join-Path $TestRoot 'snapshot-reparse-repository'
New-Item -ItemType Directory -Path $ReparseRepositoryRoot | Out-Null
& git -C $ReparseRepositoryRoot init --quiet
$RepositoryReparseLink = Join-Path $ReparseRepositoryRoot (
	'snapshot-reparse-' + [guid]::NewGuid().ToString('N')
)
$RepositoryReparseCreated = $true
try {
	New-Item `
		-ItemType Junction `
		-Path $RepositoryReparseLink `
		-Target $ReparseTarget | Out-Null
}
catch {
	$RepositoryReparseCreated = $false
}
$RepositoryReparseRejected = if ($RepositoryReparseCreated) {
	Invoke-ExpectedFailure -Pattern 'reparse point' -Action {
		& $SnapshotScript -RepositoryRoot $ReparseRepositoryRoot | Out-Null
	}
}
else {
	$false
}
Add-Result `
	-Name 'Repository inventory rejects directory reparse entry' `
	-Passed $RepositoryReparseRejected `
	-Detail $(if ($RepositoryReparseCreated) { '' } else { 'Could not create repository test junction.' })

$RepositoryOutputFailure = Invoke-ExpectedFailure -Pattern 'artifact root|outside' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-OutputPath (Join-Path $RepositoryRoot 'AGENTS.md') `
		-DryRun | Out-Null
}
Add-Result -Name 'Repository output path is rejected' -Passed $RepositoryOutputFailure

$RepositoryAuditFailure = Invoke-ExpectedFailure -Pattern 'artifact root|outside' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-AuditPath (Join-Path $RepositoryRoot 'AGENTS.md') `
		-DryRun | Out-Null
}
Add-Result -Name 'Repository audit path is rejected' -Passed $RepositoryAuditFailure

$AliasedArtifactRoot = Join-Path $TestRoot 'aliased-artifacts'
$ArtifactAliasFailure = Invoke-ExpectedFailure -Pattern 'resolve to the same path' -Action {
	& $LaunchScript `
		-HandoffPath $AnalystHandoffPath `
		-OutputPath 'delivery-stage-test-analyst-audit.json' `
		-ArtifactRoot $AliasedArtifactRoot `
		-DryRun | Out-Null
}
Add-Result -Name 'Aliased artifact targets are rejected before launch' -Passed $ArtifactAliasFailure

$ReviewerBaselineStatus = Invoke-TestGitText `
	-Arguments 'status --short --untracked-files=all'
$ReviewerBaselineDiff = Invoke-TestGitText -Arguments 'diff --binary --no-ext-diff'
$ReviewerStatusBytes = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
$ReviewerSnapshotBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$RealIndexPath = (Invoke-TestGitText -Arguments 'rev-parse --git-path index').Trim()
if (-not [System.IO.Path]::IsPathRooted($RealIndexPath)) {
	$RealIndexPath = Join-Path $RepositoryRoot $RealIndexPath
}
$RealIndexHashBefore = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))

$ReviewerGitRoot = Join-Path $TestRoot 'reviewer-git'
$ReviewerIndexPath = Join-Path $ReviewerGitRoot 'index'
$ReviewerObjectPath = Join-Path $ReviewerGitRoot 'objects'
[void][System.IO.Directory]::CreateDirectory($ReviewerObjectPath)
$RealObjectPath = (Invoke-TestGitText -Arguments 'rev-parse --git-path objects').Trim()
if (-not [System.IO.Path]::IsPathRooted($RealObjectPath)) {
	$RealObjectPath = Join-Path $RepositoryRoot $RealObjectPath
}
$ReviewerGitEnvironment = @{
	GIT_INDEX_FILE = $ReviewerIndexPath
	GIT_OBJECT_DIRECTORY = $ReviewerObjectPath
	GIT_ALTERNATE_OBJECT_DIRECTORIES = (Resolve-Path -LiteralPath $RealObjectPath).Path
	GIT_OPTIONAL_LOCKS = '0'
}
$null = Invoke-TestGitBytes `
	-Arguments "read-tree $SourceCommit" `
	-Environment $ReviewerGitEnvironment
$null = Invoke-TestGitBytes `
	-Arguments 'add --all -- .' `
	-Environment $ReviewerGitEnvironment
$ReviewerFinalDiffBytes = Invoke-TestGitBytes `
	-Arguments 'diff --cached --binary --full-index --no-ext-diff' `
	-Environment $ReviewerGitEnvironment

$RealIndexHashAfterFixture = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))
$ReviewerSnapshotAfterFixture = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$ReviewerStatusAfterFixture = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
Add-Result `
	-Name 'Reviewer fixture construction preserves repository state' `
	-Passed (
		$RealIndexHashBefore -eq $RealIndexHashAfterFixture -and
		$ReviewerSnapshotBefore.Hash -eq $ReviewerSnapshotAfterFixture.Hash -and
		(Test-TestByteArrayEqual $ReviewerStatusBytes $ReviewerStatusAfterFixture)
	)

$ReviewerHandoffPath = Join-Path $TestRoot 'reviewer-mapped-baselines.json'
@{
	schema_version = 1
	stage = 'reviewer'
	run_id = 'test-reviewer-mapped-baselines'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return review evidence.'
	baseline_status = New-NeutralEvidenceRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'baseline-status' `
		-Text $ReviewerBaselineStatus
	baseline_diff = New-NeutralEvidenceRecord `
		-Kind diff `
		-Provenance launcher `
		-Source 'baseline-diff' `
		-Text $ReviewerBaselineDiff `
		-Encoding base64
	allowed_paths = @('AGENTS.md')
	non_goals = @('Everything else')
	final_diff = New-NeutralEvidenceByteRecord `
		-Kind diff `
		-Provenance launcher `
		-Source 'final-diff' `
		-Bytes $ReviewerFinalDiffBytes `
		-Encoding base64
	artifact_state = New-NeutralEvidenceByteRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'artifact-state' `
		-Bytes $ReviewerStatusBytes `
		-Encoding base64
	raw_check_output = @(
		New-NeutralEvidenceRecord `
			-Kind command_log `
			-Provenance launcher `
			-Source 'check-output' `
			-Text 'check completed' `
			-Encoding base64
	)
} | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ReviewerHandoffPath -Encoding UTF8

$ReviewerDryRun = $null
$ReviewerDryRunError = ''
try {
	$ReviewerDryRun = & $LaunchScript `
		-HandoffPath $ReviewerHandoffPath `
		-DryRun `
		-PassThru
}
catch {
	$ReviewerDryRunError = $_.Exception.Message
}
$RealIndexHashAfterDryRun = Get-TestSha256 `
	-Bytes ([System.IO.File]::ReadAllBytes($RealIndexPath))
$ReviewerSnapshotAfterDryRun = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$ReviewerStatusAfterDryRun = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
Add-Result `
	-Name 'Mapped reviewer baseline envelopes are decoded before comparison' `
	-Passed (
		$null -ne $ReviewerDryRun -and
		$ReviewerDryRun.Stage -eq 'reviewer' -and
		$ReviewerDryRun.SandboxMode -eq 'read-only'
	) `
	-Detail $ReviewerDryRunError
Add-Result `
	-Name 'Reviewer dry-run attestation preserves repository state' `
	-Passed (
		$RealIndexHashBefore -eq $RealIndexHashAfterDryRun -and
		$ReviewerSnapshotBefore.Hash -eq $ReviewerSnapshotAfterDryRun.Hash -and
		(Test-TestByteArrayEqual $ReviewerStatusBytes $ReviewerStatusAfterDryRun)
	)

$ReviewerUtf8Path = Join-Path $TestRoot 'reviewer-utf8-attestation.json'
$ReviewerUtf8 = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$ReviewerUtf8.run_id = 'test-reviewer-utf8-attestation'
$ReviewerUtf8.final_diff = New-NeutralEvidenceByteRecord `
	-Kind diff `
	-Provenance launcher `
	-Source 'final-diff-utf8' `
	-Bytes $ReviewerFinalDiffBytes `
	-Encoding utf8
$ReviewerUtf8.artifact_state = New-NeutralEvidenceByteRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'artifact-state-utf8' `
	-Bytes $ReviewerStatusBytes `
	-Encoding utf8
$ReviewerUtf8 | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ReviewerUtf8Path -Encoding UTF8
$ReviewerUtf8Error = ''
try {
	$null = & $LaunchScript `
		-HandoffPath $ReviewerUtf8Path `
		-DryRun `
		-PassThru
}
catch {
	$ReviewerUtf8Error = $_.Exception.Message
}
Add-Result `
	-Name 'Reviewer attestation accepts exact valid UTF-8 evidence bytes' `
	-Passed ([string]::IsNullOrEmpty($ReviewerUtf8Error)) `
	-Detail $ReviewerUtf8Error

# Deliberate in-repo fixture (#146): this untracked file must live inside the
# repository under test so it appears in the live `git status` the reviewer
# stage compares against; a temp path would not exercise that detection. Its
# lifetime is the try/finally below only, under the suite lock.
$StaleFixtureRelativePath = 'reviewer-stale-fixture-' +
	[guid]::NewGuid().ToString('N') + '.txt'
$StaleFixturePath = Join-Path $RepositoryRoot $StaleFixtureRelativePath
$StaleReviewerStatusBefore = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
$StaleReviewerSnapshotBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$StaleReviewerFailure = $false
try {
	Set-Content `
		-LiteralPath $StaleFixturePath `
		-Value 'stale reviewer fixture' `
		-Encoding UTF8
	$StaleFixtureStatusBytes = Invoke-TestGitBytes `
		-Arguments 'status --porcelain=v1 -z --untracked-files=all'
	$StaleFixtureBaselineStatus = Invoke-TestGitText `
		-Arguments 'status --short --untracked-files=all'
	$StaleReviewerPath = Join-Path $TestRoot 'reviewer-stale-final-diff.json'
	$StaleReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
		ConvertFrom-Json
	$StaleReviewer.run_id = 'test-reviewer-stale-final-diff'
	$StaleReviewer.allowed_paths = @('AGENTS.md', $StaleFixtureRelativePath)
	$StaleReviewer.baseline_status = New-NeutralEvidenceRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'stale-baseline-status' `
		-Text $StaleFixtureBaselineStatus
	$StaleReviewer.final_diff = New-NeutralEvidenceRecord `
		-Kind diff `
		-Provenance launcher `
		-Source 'stale-final-diff' `
		-Text $ReviewerBaselineDiff `
		-Encoding base64
	$StaleReviewer.artifact_state = New-NeutralEvidenceByteRecord `
		-Kind status `
		-Provenance launcher `
		-Source 'stale-artifact-state' `
		-Bytes $StaleFixtureStatusBytes `
		-Encoding base64
	$StaleReviewer | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $StaleReviewerPath -Encoding UTF8
	$StaleReviewerFailure = Invoke-ExpectedFailure `
		-Pattern 'final_diff does not match' `
		-Action {
		& $LaunchScript -HandoffPath $StaleReviewerPath -DryRun | Out-Null
	}
}
finally {
	Remove-Item -LiteralPath $StaleFixturePath -Force -ErrorAction SilentlyContinue
}
$StaleReviewerStatusAfter = Invoke-TestGitBytes `
	-Arguments 'status --porcelain=v1 -z --untracked-files=all'
$StaleReviewerSnapshotAfter = & $SnapshotScript -RepositoryRoot $RepositoryRoot
Add-Result `
	-Name 'Stale tracked-only reviewer final diff is rejected' `
	-Passed $StaleReviewerFailure
Add-Result `
	-Name 'Stale reviewer fixture restores repository state' `
	-Passed (
		$StaleReviewerSnapshotBefore.Hash -eq $StaleReviewerSnapshotAfter.Hash -and
		(Test-TestByteArrayEqual $StaleReviewerStatusBefore $StaleReviewerStatusAfter)
	)

$FabricatedReviewerPath = Join-Path $TestRoot 'reviewer-fabricated-final-diff.json'
$FabricatedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$FabricatedReviewer.run_id = 'test-reviewer-fabricated-final-diff'
$FabricatedReviewer.final_diff = New-NeutralEvidenceRecord `
	-Kind diff `
	-Provenance launcher `
	-Source 'fabricated-final-diff' `
	-Text "diff --git a/fabricated b/fabricated`n" `
	-Encoding base64
$FabricatedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $FabricatedReviewerPath -Encoding UTF8
$FabricatedReviewerFailure = Invoke-ExpectedFailure `
	-Pattern 'final_diff does not match' `
	-Action {
	& $LaunchScript -HandoffPath $FabricatedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Fabricated reviewer final diff is rejected' `
	-Passed $FabricatedReviewerFailure

$OmittedReviewerPath = Join-Path $TestRoot 'reviewer-omitted-final-diff.json'
$OmittedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$OmittedReviewer.run_id = 'test-reviewer-omitted-final-diff'
$OmittedReviewer.PSObject.Properties.Remove('final_diff')
$OmittedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $OmittedReviewerPath -Encoding UTF8
$OmittedReviewerFailure = Invoke-ExpectedFailure `
	-Pattern 'final_diff|required' `
	-Action {
	& $LaunchScript -HandoffPath $OmittedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Omitted reviewer final diff is rejected' `
	-Passed $OmittedReviewerFailure

$ArtifactMismatchPath = Join-Path $TestRoot 'reviewer-artifact-state-mismatch.json'
$ArtifactMismatch = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$ArtifactMismatch.run_id = 'test-reviewer-artifact-state-mismatch'
$ArtifactMismatch.artifact_state = New-NeutralEvidenceRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'mismatched-artifact-state' `
	-Text 'candidate ready' `
	-Encoding base64
$ArtifactMismatch | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $ArtifactMismatchPath -Encoding UTF8
$ArtifactMismatchFailure = Invoke-ExpectedFailure `
	-Pattern 'artifact_state does not match' `
	-Action {
	& $LaunchScript -HandoffPath $ArtifactMismatchPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Mismatched reviewer artifact state is rejected' `
	-Passed $ArtifactMismatchFailure

$MismatchedReviewerPath = Join-Path $TestRoot 'reviewer-mapped-baseline-mismatch.json'
$MismatchedReviewer = Get-Content -Raw -LiteralPath $ReviewerHandoffPath |
	ConvertFrom-Json
$MismatchedReviewer.run_id = 'test-reviewer-mapped-baseline-mismatch'
$MismatchedReviewer.baseline_status = New-NeutralEvidenceRecord `
	-Kind status `
	-Provenance launcher `
	-Source 'mismatched-baseline-status' `
	-Text ($ReviewerBaselineStatus + 'mismatch')
$MismatchedReviewer | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $MismatchedReviewerPath -Encoding UTF8
$ReviewerBaselineMismatchFailure = Invoke-ExpectedFailure `
	-Pattern 'baseline_status' `
	-Action {
	& $LaunchScript -HandoffPath $MismatchedReviewerPath -DryRun | Out-Null
}
Add-Result `
	-Name 'Rehashed reviewer baseline mismatch is rejected before child launch' `
	-Passed $ReviewerBaselineMismatchFailure

$WorkerBaselineStatus = Invoke-TestGitText `
	-Arguments 'status --short --untracked-files=all'
$WorkerBaselineDiff = Invoke-TestGitText -Arguments 'diff --binary --no-ext-diff'
$WorkerHandoffPath = Join-Path $TestRoot 'worker.json'
@{
	schema_version = 1
	stage = 'worker'
	run_id = 'test-worker'
	workspace_root = $RepositoryRoot
	source_commit = $SourceCommit
	ticket = 'Issue #123'
	acceptance_criteria = @('Criterion')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return a unified diff.'
	work_package = 'Propose an AGENTS.md change.'
	allowed_paths = @('AGENTS.md')
	non_goals = @('Everything else')
	required_checks = @('git diff --check')
	baseline_status = $WorkerBaselineStatus
	baseline_diff = $WorkerBaselineDiff
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $WorkerHandoffPath -Encoding UTF8

function Get-WorkerHandoffWithCurrentBaseline {
	param(
		[Parameter(Mandatory)]
		[object]$Handoff
	)

	$CurrentHandoff = $Handoff.PSObject.Copy()
	$CurrentHandoff.baseline_status = Invoke-TestGitText `
		-Arguments 'status --short --untracked-files=all'
	$CurrentHandoff.baseline_diff = Invoke-TestGitText `
		-Arguments 'diff --binary --no-ext-diff'
	return $CurrentHandoff
}

$SupportedLauncherSourceProtocol = [pscustomobject][ordered]@{
	schema_version = 1
	tool = 'read_allowed_source_file'
	request_arguments = @('path', 'offset_bytes')
	path_source = 'allowed_paths'
	initial_offset_bytes = 0
	next_offset_field = 'end_offset_bytes'
	completion_field = 'eof'
	maximum_page_bytes = 8192
}

function Invoke-SourceProtocolPreflightRejection {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][string]$PrivateMarker
	)

	$Path = Join-Path $TestRoot ($Handoff.run_id + '.json')
	if ([string]$Handoff.stage -ceq 'worker') {
		$Handoff = Get-WorkerHandoffWithCurrentBaseline -Handoff $Handoff
	}
	$Handoff | ConvertTo-Json -Depth 10 | Set-Content `
		-LiteralPath $Path -Encoding UTF8
	$Carrier = @()
	$Failed = try {
		& $LaunchScript -HandoffPath $Path -OutVariable Carrier | Out-Null
		$false
	}
	catch {
		$_.Exception.Message -match 'source_protocol_invalid' -and
		$_.Exception.Message -notmatch [regex]::Escape($PrivateMarker)
	}
	$RetryNeutral = @($Carrier | Where-Object {
		$_.phase -ceq 'preflight' -and
		$_.code -ceq 'source_protocol_invalid' -and
		$_.field -ceq 'source_inspection_protocol' -and
		$_.child_launched -eq $false -and
		$_.attempt_consumed -eq $false
	})
	Add-Result -Name $Name -Passed ($Failed -and $RetryNeutral.Count -eq 1)
}

$RetainedConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$RetainedConflictHandoff.run_id = 'test-worker-retained-source-conflict'
$RetainedConflictHandoff.work_package =
	'Use read_allowed_source_file. Require `limit_bytes: 2048` for each source read. private-retained-preflight'
Invoke-SourceProtocolPreflightRejection `
	-Name 'Retained source-reader requirement is retry-neutrally rejected before launch' `
	-Handoff $RetainedConflictHandoff `
	-PrivateMarker 'private-retained-preflight'

$AdjacentClauseConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$AdjacentClauseConflictHandoff.run_id = 'test-worker-adjacent-clause-source-conflict'
$AdjacentClauseConflictHandoff.work_package =
	'Inspect with read_allowed_source_file. Pass limit_bytes: 4096 on every call.'
$AdjacentClauseConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Adjacent exact source context is retry-neutrally rejected before launch' `
	-Handoff $AdjacentClauseConflictHandoff `
	-PrivateMarker 'private-adjacent-clause-preflight'

$AdjacentSetClauseConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$AdjacentSetClauseConflictHandoff.run_id =
	'test-worker-adjacent-set-clause-source-conflict'
$AdjacentSetClauseConflictHandoff.work_package =
	'Use read_allowed_source_file. Set limit_bytes to 2048 on every call.'
$AdjacentSetClauseConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Adjacent set directive is retry-neutrally rejected before launch' `
	-Handoff $AdjacentSetClauseConflictHandoff `
	-PrivateMarker 'private-adjacent-set-clause-preflight'

$AdjacentPlainMemberConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$AdjacentPlainMemberConflictHandoff.run_id =
	'test-worker-adjacent-plain-member-source-conflict'
$AdjacentPlainMemberConflictHandoff.work_package =
	'Use read_allowed_source_file. Set limit to 2048 on every call.'
$AdjacentPlainMemberConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Adjacent plain member directive is retry-neutrally rejected before launch' `
	-Handoff $AdjacentPlainMemberConflictHandoff `
	-PrivateMarker 'private-adjacent-plain-member-preflight'

$ActiveReplaceSourceConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$ActiveReplaceSourceConflictHandoff.run_id =
	'test-worker-active-replace-source-conflict'
$ActiveReplaceSourceConflictHandoff.work_package =
	'Replace source after calling read_allowed_source_file(path, offset_bytes, limit_bytes).'
$ActiveReplaceSourceConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Leading active replace is retry-neutrally rejected before launch' `
	-Handoff $ActiveReplaceSourceConflictHandoff `
	-PrivateMarker 'private-active-replace-source-preflight'

$UnrelatedLimitRecordHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$UnrelatedLimitRecordHandoff.run_id = 'test-worker-unrelated-limit-record-control'
$UnrelatedLimitRecordHandoff.work_package =
	'Write a configuration record named limit_bytes: 2048; do not call any source tool.'
$UnrelatedLimitRecordHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
$UnrelatedLimitRecordPath = Join-Path $TestRoot 'worker-unrelated-limit-record.json'
$UnrelatedLimitRecordHandoff | ConvertTo-Json -Depth 10 | Set-Content `
	-LiteralPath $UnrelatedLimitRecordPath -Encoding UTF8
try {
	$UnrelatedLimitRecordDryRun = & $LaunchScript `
		-HandoffPath $UnrelatedLimitRecordPath -DryRun -PassThru
	Add-Result `
		-Name 'Unrelated limit record passes launcher preflight' `
		-Passed ($UnrelatedLimitRecordDryRun.Stage -ceq 'worker')
}
catch {
	Add-Result `
		-Name 'Unrelated limit record passes launcher preflight' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$NegativeClauseLauncherCases = @(
	@('No calls with limit_bytes.', 'No-call negative clause'),
	@('Check that calls with limit_bytes are rejected.', 'Check rejection clause'),
	@('Do not pass limit_bytes; use path and offset_bytes.', 'Corrective source clause'),
	@('Verify calls containing limit_bytes are rejected.', 'Verification rejection clause')
)
for ($NegativeClauseIndex = 0;
	$NegativeClauseIndex -lt $NegativeClauseLauncherCases.Count;
	$NegativeClauseIndex++) {
	$NegativeClauseHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$NegativeClauseHandoff.run_id = "test-worker-negative-source-clause-$NegativeClauseIndex"
	$NegativeClauseHandoff.work_package = 'Use read_allowed_source_file.'
	if ($NegativeClauseIndex -eq 0) {
		$NegativeClauseHandoff.non_goals = @(
			$NegativeClauseLauncherCases[$NegativeClauseIndex][0]
		)
	}
	else {
		$NegativeClauseHandoff.required_checks = @(
			$NegativeClauseLauncherCases[$NegativeClauseIndex][0]
		)
	}
	$NegativeClauseHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	$NegativeClausePath = Join-Path $TestRoot ($NegativeClauseHandoff.run_id + '.json')
	$NegativeClauseHandoff | ConvertTo-Json -Depth 10 | Set-Content `
		-LiteralPath $NegativeClausePath -Encoding UTF8
	try {
		$NegativeClauseDryRun = & $LaunchScript `
			-HandoffPath $NegativeClausePath -DryRun -PassThru
		Add-Result `
			-Name "$($NegativeClauseLauncherCases[$NegativeClauseIndex][1]) passes launcher preflight" `
			-Passed ($NegativeClauseDryRun.Stage -ceq 'worker')
	}
	catch {
		Add-Result `
			-Name "$($NegativeClauseLauncherCases[$NegativeClauseIndex][1]) passes launcher preflight" `
			-Passed $false `
			-Detail $_.Exception.Message
	}
}

$NegativeClauseContinuationCases = @(
	'No calls with limit_bytes. Then set limit_bytes to 2048 on every call.',
	'Check that calls with limit_bytes are rejected. Require timeout_seconds on each call.',
	'Use read_allowed_source_file. Do not pass path.',
	'Use read_allowed_source_file. Do not pass offset_bytes.'
)
for ($ContinuationIndex = 0;
	$ContinuationIndex -lt $NegativeClauseContinuationCases.Count;
	$ContinuationIndex++) {
	$ContinuationHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$ContinuationHandoff.run_id =
		"test-worker-negative-source-clause-continuation-$ContinuationIndex"
	$ContinuationHandoff.work_package = 'Use read_allowed_source_file.'
	$ContinuationHandoff.required_checks = @(
		$NegativeClauseContinuationCases[$ContinuationIndex]
	)
	$ContinuationHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Negative source clause continuation $($ContinuationIndex + 1) is retry-neutrally rejected" `
		-Handoff $ContinuationHandoff `
		-PrivateMarker 'private-negative-clause-continuation-preflight'
}

$RetainedEvidenceInvocationHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$RetainedEvidenceInvocationHandoff.run_id = 'test-worker-retained-evidence-invocation-conflict'
$RetainedEvidenceInvocationHandoff.work_package =
	'Reproduce the retained raw evidence by invoking read_allowed_source_file with limit_bytes: 2048.'
$RetainedEvidenceInvocationHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Active retained-evidence invocation is retry-neutrally rejected before launch' `
	-Handoff $RetainedEvidenceInvocationHandoff `
	-PrivateMarker 'private-retained-evidence-preflight'

$ExactToolShapingPreflightCases = @(
	'Do not stop before invoking read_allowed_source_file with limit_bytes: 2048.',
	'No incomplete reads are allowed when calling read_allowed_source_file with timeout_seconds.',
	'Call read_allowed_source_file and cap each request at 2048 bytes.',
	'Use read_allowed_source_file. Cap each page at 2048 bytes.',
	'Use read_allowed_source_file, specifying timeout_seconds: 30 on every request.',
	'Use read_allowed_source_file and specify limit_bytes on each request.',
	'Remove ambiguity by invoking read_allowed_source_file with timeout_seconds: 30.',
	'Previous attempts failed, so invoke read_allowed_source_file with timeout_seconds: 30.'
)
for ($ShapingPreflightIndex = 0;
	$ShapingPreflightIndex -lt $ExactToolShapingPreflightCases.Count;
	$ShapingPreflightIndex++) {
	$ShapingHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
	$ShapingHandoff.run_id = "test-worker-exact-source-shaping-$ShapingPreflightIndex"
	$ShapingHandoff.work_package = $ExactToolShapingPreflightCases[$ShapingPreflightIndex]
	$ShapingHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Exact source shaping case $($ShapingPreflightIndex + 1) is retry-neutrally rejected" `
		-Handoff $ShapingHandoff `
		-PrivateMarker 'private-exact-source-shaping-preflight'
}

$SplitSourceContextPreflightCases = @(
	[pscustomobject]@{
		Value = @(
			'Use read_allowed_source_file.',
			'Pass timeout_seconds on every source request.'
		)
	},
	[pscustomobject]@{
		Value = [ordered]@{
			procedure = 'Use read_allowed_source_file.'
			instructions = 'Pass timeout_seconds on every source request.'
		}
	}
)
for ($SplitPreflightIndex = 0;
	$SplitPreflightIndex -lt $SplitSourceContextPreflightCases.Count;
	$SplitPreflightIndex++) {
	$SplitHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
	$SplitHandoff.run_id = "test-worker-split-source-context-$SplitPreflightIndex"
	$SplitHandoff.work_package =
		$SplitSourceContextPreflightCases[$SplitPreflightIndex].Value
	$SplitHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Split source context case $($SplitPreflightIndex + 1) is retry-neutrally rejected" `
		-Handoff $SplitHandoff `
		-PrivateMarker 'private-split-source-context-preflight'
}

$MemberBeforeToolPreflightVerbs = @('Supply', 'Attach', 'Append', 'Send', 'Provide', 'Assign')
foreach ($MemberBeforeToolVerb in $MemberBeforeToolPreflightVerbs) {
	$MemberBeforeToolHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$MemberBeforeToolHandoff.run_id =
		"test-worker-member-before-tool-$($MemberBeforeToolVerb.ToLowerInvariant())"
	$MemberBeforeToolHandoff.work_package =
		"$MemberBeforeToolVerb timeout_seconds to read_allowed_source_file."
	$MemberBeforeToolHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "$MemberBeforeToolVerb member-before-tool case is retry-neutrally rejected" `
		-Handoff $MemberBeforeToolHandoff `
		-PrivateMarker 'private-member-before-source-tool-preflight'
}

$VerbIndependentPreflightCases = @(
	'Use read_allowed_source_file. Each request must carry path, offset_bytes, and timeout_seconds.',
	'Use read_allowed_source_file. Each request has path, offset_bytes, and timeout_seconds.',
	'Use read_allowed_source_file. Each request is required to carry path, offset_bytes, and timeout_seconds.'
)
for ($VerbIndependentIndex = 0;
	$VerbIndependentIndex -lt $VerbIndependentPreflightCases.Count;
	$VerbIndependentIndex++) {
	$VerbIndependentHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$VerbIndependentHandoff.run_id =
		"test-worker-verb-independent-source-members-$VerbIndependentIndex"
	$VerbIndependentHandoff.work_package =
		$VerbIndependentPreflightCases[$VerbIndependentIndex]
	$VerbIndependentHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Verb-independent source member case $($VerbIndependentIndex + 1) is retry-neutrally rejected" `
		-Handoff $VerbIndependentHandoff `
		-PrivateMarker 'private-verb-independent-source-member-preflight'
}

$ObjectSourceMemberPreflightCases = @(
	[ordered]@{
		procedure = 'Use read_allowed_source_file.'
		request_arguments = @('path', 'offset_bytes', 'timeout_seconds')
	},
	[ordered]@{
		procedure = 'Use read_allowed_source_file.'
		arguments = [ordered]@{
			path = 'AGENTS.md'
			offset_bytes = 0
			timeout_seconds = 30
		}
	}
)
for ($ObjectMemberIndex = 0;
	$ObjectMemberIndex -lt $ObjectSourceMemberPreflightCases.Count;
	$ObjectMemberIndex++) {
	$ObjectMemberHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$ObjectMemberHandoff.run_id = "test-worker-object-source-members-$ObjectMemberIndex"
	$ObjectMemberHandoff.work_package = $ObjectSourceMemberPreflightCases[$ObjectMemberIndex]
	$ObjectMemberHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Object source member case $($ObjectMemberIndex + 1) is retry-neutrally rejected" `
		-Handoff $ObjectMemberHandoff `
		-PrivateMarker 'private-object-source-member-preflight'
}

$CanonicalOnlyMembersHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$CanonicalOnlyMembersHandoff.run_id = 'test-worker-canonical-only-source-members'
$CanonicalOnlyMembersHandoff.work_package =
	'Use read_allowed_source_file. Pass only path and offset_bytes in every source call.'
$CanonicalOnlyMembersHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
$CanonicalOnlyMembersPath = Join-Path $TestRoot 'worker-canonical-only-source-members.json'
$CanonicalOnlyMembersHandoff | ConvertTo-Json -Depth 10 | Set-Content `
	-LiteralPath $CanonicalOnlyMembersPath -Encoding UTF8
try {
	$CanonicalOnlyMembersDryRun = & $LaunchScript `
		-HandoffPath $CanonicalOnlyMembersPath -DryRun -PassThru
	Add-Result `
		-Name 'Canonical only-members source instruction passes launcher preflight' `
		-Passed ($CanonicalOnlyMembersDryRun.Stage -ceq 'worker')
}
catch {
	Add-Result `
		-Name 'Canonical only-members source instruction passes launcher preflight' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$CanonicalPagingInstructionCases = @(
	'Use read_allowed_source_file. Use end_offset_bytes from each response as the next offset.',
	'Use read_allowed_source_file with exactly path and offset_bytes.'
)
for ($CanonicalPagingIndex = 0;
	$CanonicalPagingIndex -lt $CanonicalPagingInstructionCases.Count;
	$CanonicalPagingIndex++) {
	$CanonicalPagingHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$CanonicalPagingHandoff.run_id = "test-worker-canonical-paging-$CanonicalPagingIndex"
	$CanonicalPagingHandoff.work_package =
		$CanonicalPagingInstructionCases[$CanonicalPagingIndex]
	$CanonicalPagingHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	$CanonicalPagingPath = Join-Path $TestRoot ($CanonicalPagingHandoff.run_id + '.json')
	$CanonicalPagingHandoff | ConvertTo-Json -Depth 10 | Set-Content `
		-LiteralPath $CanonicalPagingPath -Encoding UTF8
	try {
		$CanonicalPagingDryRun = & $LaunchScript `
			-HandoffPath $CanonicalPagingPath -DryRun -PassThru
		Add-Result `
			-Name "Canonical paging instruction $($CanonicalPagingIndex + 1) passes launcher preflight" `
			-Passed ($CanonicalPagingDryRun.Stage -ceq 'worker')
	}
	catch {
		Add-Result `
			-Name "Canonical paging instruction $($CanonicalPagingIndex + 1) passes launcher preflight" `
			-Passed $false `
			-Detail $_.Exception.Message
	}
}

$ExactToolConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$ExactToolConflictHandoff.run_id = 'test-worker-exact-source-conflict'
$ExactToolConflictHandoff.work_package =
	'Every read_allowed_source_file call must include timeout_seconds. private-exact-preflight'
Invoke-SourceProtocolPreflightRejection `
	-Name 'Exact source-tool member is retry-neutrally rejected before launch' `
	-Handoff $ExactToolConflictHandoff `
	-PrivateMarker 'private-exact-preflight'

$ExactArgumentListConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$ExactArgumentListConflictHandoff.run_id =
	'test-worker-exact-source-argument-list-conflict'
$ExactArgumentListConflictHandoff.work_package =
	'Use read_allowed_source_file(path, offset_bytes, limit) for every source page. private-exact-argument-list-preflight'
$ExactArgumentListConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Exact source-tool argument list is retry-neutrally rejected before launch' `
	-Handoff $ExactArgumentListConflictHandoff `
	-PrivateMarker 'private-exact-argument-list-preflight'

$CrossFieldConflictHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$CrossFieldConflictHandoff.run_id = 'test-worker-cross-field-source-conflict'
$CrossFieldConflictHandoff.work_package =
	'Use read_allowed_source_file with path and offset_bytes.'
$CrossFieldConflictHandoff.required_checks = @(
	'Every call must include timeout_seconds 30. private-cross-field-preflight'
)
$CrossFieldConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Cross-field exact source context is retry-neutrally rejected before launch' `
	-Handoff $CrossFieldConflictHandoff `
	-PrivateMarker 'private-cross-field-preflight'

$StructuredSourceInstructionHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$StructuredSourceInstructionHandoff.run_id = 'test-worker-structured-source-instruction-conflict'
$StructuredSourceInstructionHandoff.work_package = [ordered]@{
	source_call = [ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{
			path = 'AGENTS.md'
			offset_bytes = 0
		}
	}
	instructions = 'Every call must include timeout_seconds 30.'
}
$StructuredSourceInstructionHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Structured source instruction is retry-neutrally rejected before launch' `
	-Handoff $StructuredSourceInstructionHandoff `
	-PrivateMarker 'private-structured-instruction-preflight'

$InvalidStructuredSourcePreflightCases = @(
	[ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = '0' }
	},
	[ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = -1 }
	},
	[ordered]@{
		tool = 'Read_Allowed_Source_File'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = 0; limit_bytes = 2048 }
	}
)
for ($StructuredPreflightIndex = 0;
	$StructuredPreflightIndex -lt $InvalidStructuredSourcePreflightCases.Count;
	$StructuredPreflightIndex++) {
	$InvalidStructuredHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
		ConvertFrom-Json
	$InvalidStructuredHandoff.run_id =
		"test-worker-invalid-structured-source-$StructuredPreflightIndex"
	$InvalidStructuredHandoff.work_package =
		$InvalidStructuredSourcePreflightCases[$StructuredPreflightIndex]
	$InvalidStructuredHandoff | Add-Member `
		-NotePropertyName source_inspection_protocol `
		-NotePropertyValue $SupportedLauncherSourceProtocol
	Invoke-SourceProtocolPreflightRejection `
		-Name "Invalid structured source call $($StructuredPreflightIndex + 1) is retry-neutrally rejected" `
		-Handoff $InvalidStructuredHandoff `
		-PrivateMarker 'private-invalid-structured-source-preflight'
}

$MalformedSourceProtocolHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$MalformedSourceProtocolHandoff.run_id = 'test-worker-source-protocol-extra'
$MalformedSourceProtocolHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue ([pscustomobject][ordered]@{
		schema_version = 1
		tool = 'read_allowed_source_file'
		request_arguments = @('path', 'offset_bytes')
		path_source = 'allowed_paths'
		initial_offset_bytes = 0
		next_offset_field = 'end_offset_bytes'
		completion_field = 'eof'
		maximum_page_bytes = 8192
		timeout_seconds = 30
	})
Invoke-SourceProtocolPreflightRejection `
	-Name 'Malformed source protocol emits retry-neutral preflight evidence' `
	-Handoff $MalformedSourceProtocolHandoff `
	-PrivateMarker 'private-malformed-protocol'

$DescriptiveSourceHandoffPath = Join-Path $TestRoot 'worker-source-description.json'
$DescriptiveSourceHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$DescriptiveSourceHandoff.run_id = 'test-worker-source-description'
$DescriptiveSourceHandoff.work_package =
	'Descriptive source reader note: keep each response compact.'
$DescriptiveSourceHandoff.required_checks = @(
	'Retry an unrelated API request with timeout_seconds 30.'
)
$DescriptiveSourceHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
$DescriptiveSourceHandoff | ConvertTo-Json -Depth 10 | Set-Content `
	-LiteralPath $DescriptiveSourceHandoffPath -Encoding UTF8
try {
	$DescriptiveDryRun = & $LaunchScript `
		-HandoffPath $DescriptiveSourceHandoffPath -DryRun -PassThru
	Add-Result `
		-Name 'Descriptive source prose does not alter the typed preflight contract' `
		-Passed (
			$DescriptiveDryRun.Stage -ceq 'worker' -and
			$DescriptiveDryRun.SandboxMode -ceq 'read-only'
		)
}
catch {
	Add-Result `
		-Name 'Descriptive source prose does not alter the typed preflight contract' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$MismatchedWorkerPath = Join-Path $TestRoot 'worker-baseline-mismatch.json'
$MismatchedWorker = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
$MismatchedWorker.run_id = 'test-worker-baseline-mismatch'
$MismatchedWorker.baseline_status = ([string]$MismatchedWorker.baseline_status) + 'mismatch'
$MismatchedWorker | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $MismatchedWorkerPath -Encoding UTF8
$BaselineMismatchFailure = Invoke-ExpectedFailure -Pattern 'baseline_status' -Action {
	& $LaunchScript -HandoffPath $MismatchedWorkerPath -DryRun | Out-Null
}
Add-Result -Name 'Baseline mismatch is rejected before child launch' -Passed $BaselineMismatchFailure

$ExternalGateHandoffPath = Join-Path $TestRoot 'worker-external-gate-missing.json'
$ExternalGateHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$ExternalGateHandoff.run_id = 'test-worker-external-gate-missing'
$ExternalGateHandoff | Add-Member `
	-NotePropertyName consumes_external_files -NotePropertyValue $true
$ExternalGateHandoff | Add-Member `
	-NotePropertyName external_ingest_evidence `
	-NotePropertyValue ([pscustomobject][ordered]@{
		evidence_manifest_path = Join-Path $TestRoot 'missing-ingest-evidence.json'
		evidence_manifest_sha256 = '1' * 64
		external_manifest_path = Join-Path $TestRoot 'missing-external-manifest.json'
		external_manifest_sha256 = '2' * 64
		prepared_journal_path = Join-Path $TestRoot 'missing-prepared-journal.json'
		prepared_journal_sha256 = '3' * 64
		source_commit = $SourceCommit
		target_root = 'visuals'
	})
$ExternalGateHandoff | ConvertTo-Json -Depth 10 | Set-Content `
	-LiteralPath $ExternalGateHandoffPath -Encoding UTF8
$MissingExternalEvidenceFailure = Invoke-ExpectedFailure `
	-Pattern 'missing-ingest-evidence|does not exist|cannot find' `
	-Action {
		& $LaunchScript -HandoffPath $ExternalGateHandoffPath -DryRun | Out-Null
	}
Add-Result `
	-Name 'External-consuming worker cannot launch without accepted ingest evidence' `
	-Passed $MissingExternalEvidenceFailure

$LauncherSource = Get-Content -Raw -LiteralPath $LaunchScript
$SnapshotGateIndex = $LauncherSource.IndexOf(
	'$BeforeSnapshot = & $SnapshotScript',
	[System.StringComparison]::Ordinal
)
$LastEvidenceGateIndex = $LauncherSource.LastIndexOf(
	'Test-DeliveryAcceptedIngestEvidence',
	[System.StringComparison]::Ordinal
)
$ChildLaunchIndex = $LauncherSource.IndexOf(
	'$Events = @($Prompt | & $CodexCommand',
	[System.StringComparison]::Ordinal
)
Add-Result `
	-Name 'External evidence is revalidated after snapshot and immediately before child launch' `
	-Passed (
		$SnapshotGateIndex -ge 0 -and
		$LastEvidenceGateIndex -gt $SnapshotGateIndex -and
		$ChildLaunchIndex -gt $LastEvidenceGateIndex
	)

$FixtureBin = Join-Path $TestRoot 'fixture-bin'
New-Item -ItemType Directory -Path $FixtureBin | Out-Null
$FixtureCodexPath = Join-Path $FixtureBin 'codex.exe'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public static class FixtureCodex
{
	public static int Main(string[] args)
	{
		string outputPath = null;
		for (int index = 0; index < args.Length - 1; index++)
		{
			if (args[index] == "--output-last-message")
			{
				outputPath = args[index + 1];
				break;
			}
		}

		string prompt = Console.In.ReadToEnd();
		string normalizedPrompt = prompt.Replace("\r", "").Replace("\n", " ");
		string scenario = Environment.GetEnvironmentVariable("DELIVERY_FIXTURE_SCENARIO");
		if (scenario == "nonzero")
		{
			Console.Error.WriteLine("NONZERO_FIXTURE_STDERR_DIAGNOSTIC");
			return 23;
		}
		if (scenario == "missing-output")
		{
			return 0;
		}
		if (scenario == "malformed-event")
		{
			string malformedOutput = "{\"stage\":\"worker\",\"status\":\"blocked\"," +
				"\"summary\":\"fixture blocked\",\"evidence\":[],\"changed_paths\":[]," +
				"\"findings\":[],\"artifact\":\"\"}";
			File.WriteAllText(outputPath, malformedOutput, new UTF8Encoding(false));
			Console.WriteLine("MALFORMED_EVENT_FIXTURE");
			return 0;
		}
		if (scenario != null && scenario.StartsWith(
			"passed-bundle",
			StringComparison.Ordinal
		))
		{
			string agentsBaseSha256 = Environment.GetEnvironmentVariable(
				"DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256"
			);
			string readmeBaseSha256 = Environment.GetEnvironmentVariable(
				"DELIVERY_FIXTURE_EXPECTED_README_SHA256"
			);
			string expectedAgentsHashEntry =
				"\"AGENTS.md\":\"" + agentsBaseSha256 + "\"";
			string expectedReadmeHashEntry =
				"\"README.md\":\"" + readmeBaseSha256 + "\"";
			int agentsHashIndex = prompt.IndexOf(
				expectedAgentsHashEntry,
				StringComparison.Ordinal
			);
			int readmeHashIndex = prompt.IndexOf(
				expectedReadmeHashEntry,
				StringComparison.Ordinal
			);
			int producerContractIndex = normalizedPrompt.LastIndexOf(
				"Attested existing allowed-path SHA-256 map:",
				StringComparison.Ordinal
			);
			int descriptiveSourceIndex = normalizedPrompt.IndexOf(
				"Descriptive source reader note: keep each response compact.",
				StringComparison.Ordinal
			);
			if (String.IsNullOrWhiteSpace(agentsBaseSha256) ||
				String.IsNullOrWhiteSpace(readmeBaseSha256) ||
				agentsHashIndex < 0 ||
				readmeHashIndex <= agentsHashIndex ||
				producerContractIndex < 0 ||
				descriptiveSourceIndex < 0 ||
				descriptiveSourceIndex >= producerContractIndex ||
				normalizedPrompt.IndexOf(
					"Return the delivery_file_bundle_v1 object directly as your " +
					"structured final output.",
					producerContractIndex,
					StringComparison.Ordinal
				) >= 0 ||
				normalizedPrompt.IndexOf(
					"Return the schema-defined outer stage object as your structured " +
					"final output.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"It must contain stage, status, summary, evidence, changed_paths, " +
					"findings, and artifact.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Put the delivery_file_bundle_v1 object under artifact; do not " +
					"return the bundle directly or omit the outer stage object.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Inspect allowed source files only with the required " +
					"read_allowed_source_file tool.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"This launcher-owned protocol overrides conflicting " +
					"source-reader prose in the frozen handoff.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Every read_allowed_source_file call must contain exactly two " +
					"input arguments: path and offset_bytes.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Start each path at offset_bytes zero, then use the exact prior " +
					"result end_offset_bytes until eof is true.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Never send result-only members as input arguments.",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0 ||
				normalizedPrompt.IndexOf(
					"Do not use commands, scripts, shells, interpreters, " +
					"executables, or temporary files",
					producerContractIndex,
					StringComparison.Ordinal
				) < 0)
			{
				Console.Error.WriteLine("PRODUCER_PROMPT_CONTRACT_MISSING");
				return 24;
			}
			byte[] agentsBaseBytes = File.ReadAllBytes(
				Path.Combine(Environment.CurrentDirectory, "AGENTS.md")
			);
			byte[] agentsSuffix = new UTF8Encoding(false).GetBytes(
				"\n# delivery bundle fixture candidate\n"
			);
			byte[] agentsCandidateBytes = new byte[
				agentsBaseBytes.Length + agentsSuffix.Length
			];
			Buffer.BlockCopy(
				agentsBaseBytes,
				0,
				agentsCandidateBytes,
				0,
				agentsBaseBytes.Length
			);
			Buffer.BlockCopy(
				agentsSuffix,
				0,
				agentsCandidateBytes,
				agentsBaseBytes.Length,
				agentsSuffix.Length
			);
			byte[] readmeBaseBytes = File.ReadAllBytes(
				Path.Combine(Environment.CurrentDirectory, "README.md")
			);
			byte[] readmeSuffix = new UTF8Encoding(false).GetBytes(
				"\n<!-- delivery bundle fixture candidate -->\n"
			);
			byte[] readmeCandidateBytes = new byte[
				readmeBaseBytes.Length + readmeSuffix.Length
			];
			Buffer.BlockCopy(
				readmeBaseBytes,
				0,
				readmeCandidateBytes,
				0,
				readmeBaseBytes.Length
			);
			Buffer.BlockCopy(
				readmeSuffix,
				0,
				readmeCandidateBytes,
				readmeBaseBytes.Length,
				readmeSuffix.Length
			);
			string replacementAgents =
				"{\"path\":\"AGENTS.md\",\"operation\":\"replace\"," +
				"\"base_sha256\":\"" + agentsBaseSha256 +
				"\",\"encoding\":\"utf8\",\"content\":\"" +
				new UTF8Encoding(false, true).GetString(agentsCandidateBytes)
					.Replace("\\", "\\\\").Replace("\"", "\\\"")
					.Replace("\r", "\\r").Replace("\n", "\\n") + "\"}";
			string replacementReadme =
				"{\"path\":\"README.md\",\"operation\":\"replace\"," +
				"\"base_sha256\":\"" + readmeBaseSha256 +
				"\",\"encoding\":\"utf8\",\"content\":\"" +
				new UTF8Encoding(false, true).GetString(readmeCandidateBytes)
					.Replace("\\", "\\\\").Replace("\"", "\\\"")
					.Replace("\r", "\\r").Replace("\n", "\\n") + "\"}";
			string createdFile =
				"{\"path\":\"docs/source-created.md\",\"operation\":\"create\"," +
				"\"base_sha256\":null,\"encoding\":\"utf8\"," +
				"\"content\":\"created fixture\\n\"}";
			string changedPaths;
			string bundleFiles;
			if (scenario == "passed-bundle-create-only")
			{
				changedPaths = "[\"docs/source-created.md\"]";
				bundleFiles = createdFile;
			}
			else if (scenario == "passed-bundle-mixed-create-replace")
			{
				changedPaths = "[\"AGENTS.md\",\"docs/source-created.md\"]";
				bundleFiles = replacementAgents + "," + createdFile;
			}
			else
			{
				changedPaths = "[\"AGENTS.md\",\"README.md\"]";
				bundleFiles = replacementAgents + "," + replacementReadme;
			}
			string bundleOutput = "{\"stage\":\"worker\",\"status\":\"passed\"," +
				"\"summary\":\"fixture passed\",\"evidence\":[]," +
				"\"changed_paths\":" + changedPaths + ",\"findings\":[]," +
				"\"artifact\":{\"format\":\"delivery_file_bundle_v1\"," +
				"\"files\":[" + bundleFiles + "]}}";
			File.WriteAllText(outputPath, bundleOutput, new UTF8Encoding(false));
			Console.Error.WriteLine("IGNORED_FIXTURE_DIAGNOSTIC");
			Console.WriteLine(
				"{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}"
			);
			WriteBundleSourceEvents(
				scenario,
				agentsBaseSha256,
				readmeBaseSha256
			);
			Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{" +
				"\"input_tokens\":100,\"cached_input_tokens\":40," +
				"\"cache_write_input_tokens\":0,\"output_tokens\":20," +
				"\"reasoning_output_tokens\":5}}");
			return 0;
		}
		if (scenario == "issue141-corrected")
		{
			bool shellToolDisabled = false;
			bool inheritedServersCleared = true;
			bool requiredServer = false;
			bool enabledToolsRestricted = false;
			bool readToolApproved = false;
			string commandOverride = null;
			string argsOverride = null;
			for (int index = 0; index < args.Length; index++)
			{
				string argument = args[index];
				if (argument == "features.shell_tool=false") { shellToolDisabled = true; }
				if (argument == "mcp_servers={}") { inheritedServersCleared = false; }
				if (argument == "mcp_servers.source_inspection.required=true")
				{
					requiredServer = true;
				}
				if (argument ==
					"mcp_servers.source_inspection.enabled_tools=['read_allowed_source_file']")
				{
					enabledToolsRestricted = true;
				}
				if (argument ==
					"mcp_servers.source_inspection.tools.read_allowed_source_file." +
					"approval_mode='approve'")
				{
					readToolApproved = true;
				}
				if (argument.StartsWith(
					"mcp_servers.source_inspection.command=",
					StringComparison.Ordinal))
				{
					commandOverride = argument.Substring(
						"mcp_servers.source_inspection.command=".Length
					);
				}
				if (argument.StartsWith(
					"mcp_servers.source_inspection.args=",
					StringComparison.Ordinal))
				{
					argsOverride = argument.Substring(
						"mcp_servers.source_inspection.args=".Length
					);
				}
			}
			if (!shellToolDisabled || !inheritedServersCleared || !requiredServer ||
				!enabledToolsRestricted || !readToolApproved || commandOverride == null ||
				argsOverride == null || commandOverride.Length < 2 ||
				commandOverride[0] != '\'' ||
				commandOverride[commandOverride.Length - 1] != '\'')
			{
				Console.Error.WriteLine("SOURCE_INSPECTION_SURFACE_MISSING");
				return 25;
			}
			string serverCommand = commandOverride.Substring(
				1,
				commandOverride.Length - 2
			);
			List<string> serverArguments = new List<string>();
			int argsCursor = 0;
			while (argsCursor < argsOverride.Length)
			{
				if (argsOverride[argsCursor] == '\'')
				{
					int closeQuote = argsOverride.IndexOf('\'', argsCursor + 1);
					if (closeQuote < 0)
					{
						Console.Error.WriteLine("SOURCE_INSPECTION_ARGS_MALFORMED");
						return 25;
					}
					serverArguments.Add(argsOverride.Substring(
						argsCursor + 1,
						closeQuote - argsCursor - 1
					));
					argsCursor = closeQuote + 1;
				}
				else
				{
					argsCursor++;
				}
			}
			StringBuilder serverArgumentText = new StringBuilder();
			foreach (string serverArgument in serverArguments)
			{
				if (serverArgumentText.Length > 0)
				{
					serverArgumentText.Append(' ');
				}
				serverArgumentText.Append('"').Append(serverArgument);
				int trailingBackslashes = 0;
				while (trailingBackslashes < serverArgument.Length &&
					serverArgument[
						serverArgument.Length - 1 - trailingBackslashes
					] == '\\')
				{
					trailingBackslashes++;
				}
				serverArgumentText.Append('\\', trailingBackslashes).Append('"');
			}
			ProcessStartInfo serverStartInfo = new ProcessStartInfo();
			serverStartInfo.FileName = serverCommand;
			serverStartInfo.Arguments = serverArgumentText.ToString();
			serverStartInfo.UseShellExecute = false;
			serverStartInfo.CreateNoWindow = true;
			serverStartInfo.RedirectStandardInput = true;
			serverStartInfo.RedirectStandardOutput = true;
			serverStartInfo.RedirectStandardError = true;
			using (Process serverProcess = Process.Start(serverStartInfo))
			{
				serverProcess.StandardInput.WriteLine(
					"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," +
					"\"params\":{\"protocolVersion\":\"2025-03-26\"," +
					"\"capabilities\":{},\"clientInfo\":{\"name\":\"fixture-codex\"," +
					"\"version\":\"1.0.0\"}}}"
				);
				serverProcess.StandardInput.Flush();
				string initializeResponse = serverProcess.StandardOutput.ReadLine();
				serverProcess.StandardInput.WriteLine(
					"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
				);
				serverProcess.StandardInput.WriteLine(
					"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"," +
					"\"params\":{}}"
				);
				serverProcess.StandardInput.Flush();
				string listResponse = serverProcess.StandardOutput.ReadLine();
				long expectedOffsetBytes = 0;
				long expectedFileSizeBytes = -1;
				string toolEncoding = null;
				string toolBaseSha256 = null;
				StringBuilder escapedToolContent = new StringBuilder();
				MemoryStream reconstructedSource = new MemoryStream();
				List<string> observedSourceEvents = new List<string>();
				int requestId = 3;
				bool reachedEof = false;
				while (!reachedEof)
				{
					string callId = "source-call-" + requestId;
					string requestArguments =
						"{\"path\":\"AGENTS.md\",\"offset_bytes\":" +
						expectedOffsetBytes + "}";
					observedSourceEvents.Add(
						"{\"type\":\"item.started\",\"item\":{\"id\":\"" + callId +
						"\",\"type\":\"mcp_tool_call\",\"server\":" +
						"\"source_inspection\",\"tool\":\"read_allowed_source_file\"," +
						"\"arguments\":" + requestArguments +
						",\"status\":\"in_progress\"}}"
					);
					serverProcess.StandardInput.WriteLine(
						"{\"jsonrpc\":\"2.0\",\"id\":" + requestId +
						",\"method\":\"tools/call\",\"params\":{\"name\":" +
						"\"read_allowed_source_file\",\"arguments\":{\"path\":" +
						"\"AGENTS.md\",\"offset_bytes\":" + expectedOffsetBytes + "}}}"
					);
					serverProcess.StandardInput.Flush();
					string callResponse = serverProcess.StandardOutput.ReadLine();
					if (callResponse == null || callResponse.IndexOf(
							"\"isError\":false",
							StringComparison.Ordinal
						) < 0)
					{
						Console.Error.WriteLine("SOURCE_INSPECTION_PROTOCOL_FAILED");
						return 26;
					}
					int structuredIndex = callResponse.IndexOf(
						"\"structuredContent\":",
						StringComparison.Ordinal
					);
					int structuredStart = structuredIndex +
						"\"structuredContent\":".Length;
					int structuredEnd = callResponse.IndexOf(
						",\"isError\":",
						structuredStart,
						StringComparison.Ordinal
					);
					string canonicalText = DecodeJsonString(ExtractEscapedJsonValue(
						callResponse, "\"text\":\"", 0
					));
					if (structuredIndex < 0 || structuredEnd < structuredStart ||
						canonicalText == null || canonicalText != callResponse.Substring(
							structuredStart,
							structuredEnd - structuredStart
						))
					{
						Console.Error.WriteLine("SOURCE_INSPECTION_PROTOCOL_FAILED");
						return 26;
					}
					string pagePath = ExtractEscapedJsonValue(
						callResponse, "\"path\":\"", structuredIndex
					);
					string pageEncoding = ExtractEscapedJsonValue(
						callResponse, "\"encoding\":\"", structuredIndex
					);
					string pageContent = ExtractEscapedJsonValue(
						callResponse, "\"content\":\"", structuredIndex
					);
					string pageBaseSha256 = ExtractEscapedJsonValue(
						callResponse, "\"base_sha256\":\"", structuredIndex
					);
					long pageOffsetBytes = ExtractJsonInt64(
						callResponse, "\"offset_bytes\":", structuredIndex
					);
					long pageContentBytes = ExtractJsonInt64(
						callResponse, "\"content_bytes\":", structuredIndex
					);
					long pageEndOffsetBytes = ExtractJsonInt64(
						callResponse, "\"end_offset_bytes\":", structuredIndex
					);
					long pageFileSizeBytes = ExtractJsonInt64(
						callResponse, "\"file_size_bytes\":", structuredIndex
					);
					bool? pageEof = ExtractJsonBoolean(
						callResponse, "\"eof\":", structuredIndex
					);
					string decodedPageContent = DecodeJsonString(pageContent);
					byte[] pageBytes = null;
					try
					{
						if (pageEncoding == "utf8" && decodedPageContent != null)
						{
							pageBytes = new UTF8Encoding(false, true).GetBytes(
								decodedPageContent
							);
						}
					}
					catch (EncoderFallbackException)
					{
						pageBytes = null;
					}
					if (expectedFileSizeBytes < 0)
					{
						expectedFileSizeBytes = pageFileSizeBytes;
						toolEncoding = pageEncoding;
						toolBaseSha256 = pageBaseSha256;
					}
					if (pagePath != "AGENTS.md" || pageEncoding != toolEncoding ||
						pageEncoding != "utf8" || pageContent == null ||
						pageBaseSha256 != toolBaseSha256 ||
						toolBaseSha256 == null || toolBaseSha256.Length != 64 ||
						pageFileSizeBytes != expectedFileSizeBytes ||
						pageOffsetBytes != expectedOffsetBytes ||
						pageContentBytes < 0 || pageContentBytes > 8192 ||
						pageBytes == null || pageBytes.LongLength != pageContentBytes ||
						pageEndOffsetBytes != pageOffsetBytes + pageContentBytes ||
						pageEndOffsetBytes > pageFileSizeBytes || pageEof == null ||
						pageEof.Value != (pageEndOffsetBytes == pageFileSizeBytes) ||
						(!pageEof.Value && pageContentBytes == 0))
					{
						Console.Error.WriteLine("SOURCE_INSPECTION_RESULT_INVALID");
						return 27;
					}
					observedSourceEvents.Add(
						"{\"type\":\"item.completed\",\"item\":{\"id\":\"" + callId +
						"\",\"type\":\"mcp_tool_call\",\"server\":" +
						"\"source_inspection\",\"tool\":\"read_allowed_source_file\"," +
						"\"arguments\":" + requestArguments + ",\"result\":{" +
						"\"content\":[{\"type\":\"text\",\"text\":\"" +
						canonicalText.Replace("\\", "\\\\").Replace("\"", "\\\"") +
						"\"}],\"structured_content\":" + canonicalText +
						",\"isError\":false},\"error\":null,\"status\":\"completed\"}}"
					);
					escapedToolContent.Append(pageContent);
					reconstructedSource.Write(pageBytes, 0, pageBytes.Length);
					expectedOffsetBytes = pageEndOffsetBytes;
					reachedEof = pageEof.Value;
					requestId++;
				}
				serverProcess.StandardInput.Close();
				serverProcess.WaitForExit(30000);
				if (initializeResponse == null || listResponse == null ||
					listResponse.IndexOf(
						"\"read_allowed_source_file\"",
						StringComparison.Ordinal
					) < 0 ||
					listResponse.IndexOf(
						"\"required\":[\"path\",\"offset_bytes\"]",
						StringComparison.Ordinal
					) < 0)
				{
					Console.Error.WriteLine("SOURCE_INSPECTION_PROTOCOL_FAILED");
					return 26;
				}
				byte[] reconstructedBytes = reconstructedSource.ToArray();
				reconstructedSource.Dispose();
				if (reconstructedBytes.LongLength != expectedFileSizeBytes ||
					expectedOffsetBytes != expectedFileSizeBytes ||
					ComputeSha256(reconstructedBytes) != toolBaseSha256)
				{
					Console.Error.WriteLine("SOURCE_INSPECTION_RESULT_INVALID");
					return 27;
				}
				string correctedOutput = "{\"stage\":\"worker\",\"status\":\"passed\"," +
					"\"summary\":\"fixture passed\",\"evidence\":[]," +
					"\"changed_paths\":[\"AGENTS.md\"],\"findings\":[]," +
					"\"artifact\":{\"format\":\"delivery_file_bundle_v1\"," +
					"\"files\":[{\"path\":\"AGENTS.md\",\"operation\":\"replace\"," +
					"\"base_sha256\":\"" + toolBaseSha256 +
					"\",\"encoding\":\"utf8\",\"content\":\"" +
					escapedToolContent.ToString() +
					"\n# delivery source inspection fixture candidate\n\"}]}}";
				File.WriteAllText(outputPath, correctedOutput, new UTF8Encoding(false));
				foreach (string observedSourceEvent in observedSourceEvents)
				{
					Console.WriteLine(observedSourceEvent);
				}
			}
			Console.WriteLine(
				"{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}"
			);
			Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{" +
				"\"input_tokens\":100,\"cached_input_tokens\":40," +
				"\"cache_write_input_tokens\":0,\"output_tokens\":20," +
				"\"reasoning_output_tokens\":5}}");
			return 0;
		}

		string artifact = "";
		if (scenario == "passed-nonapplying-patch")
		{
			artifact = "diff --git a/AGENTS.md b/AGENTS.md\n" +
				"--- a/AGENTS.md\n" +
				"+++ b/AGENTS.md\n" +
				"@@ -1 +1 @@\n" +
				"-this line cannot exist in the attested snapshot\n" +
				"+replacement line\n";
		}
		string escapedArtifact = artifact.Replace("\\", "\\\\").Replace("\"", "\\\"")
			.Replace("\r", "\\r").Replace("\n", "\\n");
		string status = scenario == "blocked" ? "blocked" :
			(scenario == "failed" || scenario == "issue45-initial") ? "failed" :
			"passed";
		string summary = scenario == "issue45-initial"
			? "sandbox-rejected-baseline"
			: "fixture " + status;
		string output = "{\"stage\":\"worker\",\"status\":\"" + status +
			"\",\"summary\":\"" + summary +
			"\",\"evidence\":[],\"changed_paths\":[],\"findings\":[],\"artifact\":\"" +
			escapedArtifact + "\"}";
		File.WriteAllText(outputPath, output, new UTF8Encoding(false));
		Console.Error.WriteLine("IGNORED_FIXTURE_DIAGNOSTIC");
		Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}");
		Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{" +
			"\"input_tokens\":100,\"cached_input_tokens\":40," +
			"\"cache_write_input_tokens\":0,\"output_tokens\":20," +
			"\"reasoning_output_tokens\":5}}");
		return 0;
	}
	private static void WriteCompletedSourceFile(
		string path,
		string baseSha256,
		byte[] bytes,
		string callPrefix
	)
	{
		int offset = 0;
		int pageIndex = 0;
		do
		{
			int contentBytes = Math.Min(8192, bytes.Length - offset);
			byte[] pageBytes = new byte[contentBytes];
			Buffer.BlockCopy(bytes, offset, pageBytes, 0, contentBytes);
			int endOffset = offset + contentBytes;
			bool eof = endOffset == bytes.Length;
			string arguments = "{\"path\":\"" + path +
				"\",\"offset_bytes\":" + offset + "}";
			string page = "{\"path\":\"" + path +
				"\",\"encoding\":\"base64\",\"content\":\"" +
				Convert.ToBase64String(pageBytes) + "\",\"base_sha256\":\"" +
				baseSha256 + "\",\"offset_bytes\":" + offset +
				",\"content_bytes\":" + contentBytes +
				",\"end_offset_bytes\":" + endOffset +
				",\"file_size_bytes\":" + bytes.Length +
				",\"eof\":" + (eof ? "true" : "false") + "}";
			string callId = callPrefix + "-" + pageIndex;
			Console.WriteLine("{\"type\":\"item.started\",\"item\":{" +
				"\"id\":\"" + callId + "\",\"type\":\"mcp_tool_call\"," +
				"\"server\":\"source_inspection\"," +
				"\"tool\":\"read_allowed_source_file\",\"arguments\":" +
				arguments + ",\"status\":\"in_progress\"}}");
			Console.WriteLine("{\"type\":\"item.completed\",\"item\":{" +
				"\"id\":\"" + callId + "\",\"type\":\"mcp_tool_call\"," +
				"\"server\":\"source_inspection\"," +
				"\"tool\":\"read_allowed_source_file\",\"arguments\":" +
				arguments + ",\"result\":{\"content\":[{\"type\":\"text\"," +
				"\"text\":\"" + page.Replace("\\", "\\\\").Replace("\"", "\\\"") +
				"\"}],\"structured_content\":" + page +
				",\"isError\":false},\"error\":null,\"status\":\"completed\"}}");
			offset = endOffset;
			pageIndex++;
		}
		while (offset < bytes.Length);
	}
	private static void WriteBundleSourceEvents(
		string scenario,
		string agentsBaseSha256,
		string readmeBaseSha256
	)
	{
		const string hash =
			"3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7";
		string arguments = "{\"path\":\"AGENTS.md\",\"offset_bytes\":0}";
		string started = "{\"type\":\"item.started\",\"item\":{" +
			"\"id\":\"bundle-source\",\"type\":\"mcp_tool_call\"," +
			"\"server\":\"source_inspection\"," +
			"\"tool\":\"read_allowed_source_file\",\"arguments\":" + arguments +
			",\"status\":\"in_progress\"}}";
		string page = "{\"path\":\"AGENTS.md\",\"encoding\":\"utf8\"," +
			"\"content\":\"data\",\"base_sha256\":\"" + hash +
			"\",\"offset_bytes\":0,\"content_bytes\":4," +
			"\"end_offset_bytes\":4,\"file_size_bytes\":4,\"eof\":true}";
		string completed = "{\"type\":\"item.completed\",\"item\":{" +
			"\"id\":\"bundle-source\",\"type\":\"mcp_tool_call\"," +
			"\"server\":\"source_inspection\"," +
			"\"tool\":\"read_allowed_source_file\",\"arguments\":" + arguments +
			",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"" +
			page.Replace("\\", "\\\\").Replace("\"", "\\\"") +
			"\"}],\"structured_content\":" + page +
			",\"isError\":false},\"error\":null,\"status\":\"completed\"}}";

		if (scenario == "passed-bundle-complete-pagination")
		{
			WriteCompletedSourceFile(
				"AGENTS.md", agentsBaseSha256, File.ReadAllBytes("AGENTS.md"), "agents"
			);
			WriteCompletedSourceFile(
				"README.md", readmeBaseSha256, File.ReadAllBytes("README.md"), "readme"
			);
		}
		else if (scenario == "passed-bundle-missing-replacement-source")
		{
			WriteCompletedSourceFile(
				"AGENTS.md", agentsBaseSha256, File.ReadAllBytes("AGENTS.md"), "agents"
			);
		}
		else if (scenario == "passed-bundle-mismatched-replacement-source")
		{
			WriteCompletedSourceFile(
				"AGENTS.md", agentsBaseSha256, File.ReadAllBytes("AGENTS.md"), "agents"
			);
			Console.WriteLine(started.Replace("AGENTS.md", "README.md"));
			Console.WriteLine(completed.Replace("AGENTS.md", "README.md"));
		}
		else if (scenario == "passed-bundle-mixed-create-replace")
		{
			WriteCompletedSourceFile(
				"AGENTS.md", agentsBaseSha256, File.ReadAllBytes("AGENTS.md"), "agents"
			);
		}
		else if (scenario == "passed-bundle-incomplete-pagination")
		{
			string incompletePage = page.Replace(
				"\"file_size_bytes\":4,\"eof\":true",
				"\"file_size_bytes\":8,\"eof\":false"
			);
			Console.WriteLine(started);
			Console.WriteLine(completed.Replace(
				page.Replace("\\", "\\\\").Replace("\"", "\\\""),
				incompletePage.Replace("\\", "\\\\").Replace("\"", "\\\"")
			).Replace(page, incompletePage));
		}
		else if (scenario == "passed-bundle-argument-validation-failed")
		{
			string invalidArguments =
				"{\"path\":\"AGENTS.md\",\"offset_bytes\":0,\"limit_bytes\":2048}";
			Console.WriteLine(started.Replace(arguments, invalidArguments));
			Console.WriteLine("{\"type\":\"item.completed\",\"item\":{" +
				"\"id\":\"bundle-source\",\"type\":\"mcp_tool_call\"," +
				"\"server\":\"source_inspection\"," +
				"\"tool\":\"read_allowed_source_file\",\"arguments\":" +
				invalidArguments + ",\"result\":null,\"error\":{" +
				"\"message\":\"private-invalid-argument\"},\"status\":\"failed\"}}"
			);
		}
		else if (scenario == "passed-bundle-source-policy-rejected")
		{
			Console.WriteLine(started);
			Console.WriteLine("{\"type\":\"item.completed\",\"item\":{" +
				"\"id\":\"bundle-source\",\"type\":\"mcp_tool_call\"," +
				"\"server\":\"source_inspection\"," +
				"\"tool\":\"read_allowed_source_file\",\"arguments\":" + arguments +
				",\"result\":{\"content\":[{\"type\":\"text\",\"text\":" +
				"\"[source_path_sensitive] private-policy-detail\"}],\"isError\":true}," +
				"\"error\":null,\"status\":\"completed\"}}"
			);
		}
		else if (scenario == "passed-bundle-protocol-rejected")
		{
			Console.WriteLine(completed);
		}
	}
	private static long ExtractJsonInt64(
		string source,
		string marker,
		int startIndex)
	{
		if (startIndex < 0)
		{
			return -1;
		}
		int markerIndex = source.IndexOf(marker, startIndex, StringComparison.Ordinal);
		if (markerIndex < 0)
		{
			return -1;
		}
		int cursor = markerIndex + marker.Length;
		int valueStart = cursor;
		while (cursor < source.Length && source[cursor] >= '0' && source[cursor] <= '9')
		{
			cursor++;
		}
		long value;
		if (cursor == valueStart || !Int64.TryParse(
			source.Substring(valueStart, cursor - valueStart),
			out value
		))
		{
			return -1;
		}
		return value;
	}
	private static bool? ExtractJsonBoolean(
		string source,
		string marker,
		int startIndex)
	{
		if (startIndex < 0)
		{
			return null;
		}
		int markerIndex = source.IndexOf(marker, startIndex, StringComparison.Ordinal);
		if (markerIndex < 0)
		{
			return null;
		}
		int valueStart = markerIndex + marker.Length;
		if (source.IndexOf("true", valueStart, StringComparison.Ordinal) == valueStart)
		{
			return true;
		}
		if (source.IndexOf("false", valueStart, StringComparison.Ordinal) == valueStart)
		{
			return false;
		}
		return null;
	}
	private static string DecodeJsonString(string value)
	{
		if (value == null)
		{
			return null;
		}
		StringBuilder decoded = new StringBuilder();
		for (int cursor = 0; cursor < value.Length; cursor++)
		{
			char current = value[cursor];
			if (current != '\\')
			{
				decoded.Append(current);
				continue;
			}
			if (++cursor >= value.Length)
			{
				return null;
			}
			char escaped = value[cursor];
			switch (escaped)
			{
				case '"': decoded.Append('"'); break;
				case '\\': decoded.Append('\\'); break;
				case '/': decoded.Append('/'); break;
				case 'b': decoded.Append('\b'); break;
				case 'f': decoded.Append('\f'); break;
				case 'n': decoded.Append('\n'); break;
				case 'r': decoded.Append('\r'); break;
				case 't': decoded.Append('\t'); break;
				case 'u':
					if (cursor + 4 >= value.Length)
					{
						return null;
					}
					int codePoint;
					if (!Int32.TryParse(
						value.Substring(cursor + 1, 4),
						System.Globalization.NumberStyles.HexNumber,
						System.Globalization.CultureInfo.InvariantCulture,
						out codePoint
					))
					{
						return null;
					}
					decoded.Append((char)codePoint);
					cursor += 4;
					break;
				default: return null;
			}
		}
		return decoded.ToString();
	}
	private static string ComputeSha256(byte[] bytes)
	{
		using (SHA256 hasher = SHA256.Create())
		{
			return BitConverter.ToString(hasher.ComputeHash(bytes))
				.Replace("-", "").ToLowerInvariant();
		}
	}
	private static string ExtractEscapedJsonValue(
		string source,
		string marker,
		int startIndex)
	{
		if (startIndex < 0)
		{
			return null;
		}
		int markerIndex = source.IndexOf(marker, startIndex, StringComparison.Ordinal);
		if (markerIndex < 0)
		{
			return null;
		}
		StringBuilder value = new StringBuilder();
		int cursor = markerIndex + marker.Length;
		while (cursor < source.Length)
		{
			char current = source[cursor];
			if (current == '\\')
			{
				if (cursor + 1 >= source.Length)
				{
					return null;
				}
				value.Append(current).Append(source[cursor + 1]);
				cursor += 2;
				continue;
			}
			if (current == '"')
			{
				return value.ToString();
			}
			value.Append(current);
			cursor++;
		}
		return null;
	}
}
'@ -OutputAssembly $FixtureCodexPath -OutputType ConsoleApplication

function Invoke-FailureEvidenceCase {
	param(
		[Parameter(Mandatory)]
		[string]$Scenario,

		[Parameter(Mandatory)]
		[string]$ExpectedError,

		[Parameter(Mandatory)]
		[int]$ExpectedFileCount,

		[Parameter(Mandatory)]
		[bool]$ExpectOutput
	)

	$RunId = "test-worker-$Scenario"
	$HandoffPath = Join-Path $TestRoot "$RunId.json"
	$Handoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
	$Handoff.run_id = $RunId
	# The worker fixture is created much earlier in this long-running suite. Bind
	# each real launcher case to the current bytes immediately before launch so
	# unrelated, parallel worktree edits cannot turn the intended stage failure
	# into a stale-baseline preflight rejection.
	$Handoff = Get-WorkerHandoffWithCurrentBaseline -Handoff $Handoff
	$Handoff | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $HandoffPath -Encoding UTF8
	$ArtifactRoot = Join-Path $TestRoot "$RunId-artifacts"
	$AuditPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-audit.json"
	$ManifestPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-evidence.json"
	$OutputPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-output.json"
	$StandardErrorPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-stderr.log"
	$PatchPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-candidate.patch"
	$OriginalPath = $env:PATH
	$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
	$ErrorMessage = $null
	try {
		$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $Scenario
		try {
			& $LaunchScript `
				-HandoffPath $HandoffPath `
				-ArtifactRoot $ArtifactRoot | Out-Null
		}
		catch {
			$ErrorMessage = $_.Exception.Message
		}
	}
	finally {
		$env:PATH = $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
	}

	$AuditExists = Test-Path -LiteralPath $AuditPath -PathType Leaf
	$ManifestExists = Test-Path -LiteralPath $ManifestPath -PathType Leaf
	$Manifest = if ($ManifestExists) {
		Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
	}
	else {
		$null
	}
	$Audit = if ($AuditExists) {
		Get-Content -Raw -LiteralPath $AuditPath | ConvertFrom-Json
	}
	else {
		$null
	}
	$StandardError = if (Test-Path -LiteralPath $StandardErrorPath -PathType Leaf) {
		Get-Content -Raw -LiteralPath $StandardErrorPath
	}
	$ManifestFiles = @($Manifest.Files)
	$OnlyExistingEvidence = $ManifestExists -and @(
		$ManifestFiles | Where-Object {
			-not (Test-Path -LiteralPath $_.Path -PathType Leaf)
		}
	).Count -eq 0

	$StandardErrorPassed = if ($Scenario -eq 'nonzero') {
		$StandardError -match 'NONZERO_FIXTURE_STDERR_DIAGNOSTIC' -and
		$ErrorMessage -notmatch 'NONZERO_FIXTURE_STDERR_DIAGNOSTIC' -and
		[string]$Audit.StandardErrorPath -eq $StandardErrorPath -and
		@($ManifestFiles | Where-Object { $_.Path -eq $StandardErrorPath }).Count -eq 1 -and
		(Get-Item -LiteralPath $StandardErrorPath -Force).IsReadOnly
	}
	else {
		$true
	}

	return [pscustomobject]@{
		Passed = (
			$ErrorMessage -match $ExpectedError -and
			$AuditExists -and
			$ManifestExists -and
			$OnlyExistingEvidence -and
			[string]$Manifest.Disposition -eq 'rejected' -and
			$ManifestFiles.Count -eq $ExpectedFileCount -and
			(Test-Path -LiteralPath $OutputPath -PathType Leaf) -eq $ExpectOutput -and
			-not (Test-Path -LiteralPath $PatchPath) -and
			@($ManifestFiles | Where-Object { $_.Path -eq $PatchPath }).Count -eq 0 -and
			$StandardErrorPassed
		)
		Detail = $ErrorMessage
	}
}

$FailureEvidenceCases = @(
	@('blocked', "reported status 'blocked': fixture blocked", 5, $true,
		'Blocked writer preserves stage status and seals existing evidence'),
	@('failed', "reported status 'failed': fixture failed", 5, $true,
		'Failed writer preserves stage status and seals existing evidence'),
	@('nonzero', 'failed with exit code 23', 4, $false,
		'Nonzero child exit preserves primary error and seals existing evidence'),
	@('missing-output', 'output artifact.+was not created', 4, $false,
		'Missing output preserves validation error and seals existing evidence'),
	@('passed-no-patch', 'returned no candidate artifact', 5, $true,
		'Passed writer without patch still fails closed'),
	@('issue45-initial', "reported status 'failed': sandbox-rejected-baseline", 5, $true,
		'Issue #45 initial sandbox-rejected baseline seals rejected evidence'),
	@('issue45-replacement', 'returned no candidate artifact', 5, $true,
		'Issue #45 replacement empty artifact fails closed without a patch')
)
foreach ($FailureEvidenceCase in $FailureEvidenceCases) {
	$FailureEvidenceResult = Invoke-FailureEvidenceCase `
		-Scenario $FailureEvidenceCase[0] `
		-ExpectedError $FailureEvidenceCase[1] `
		-ExpectedFileCount $FailureEvidenceCase[2] `
		-ExpectOutput $FailureEvidenceCase[3]
	Add-Result `
		-Name $FailureEvidenceCase[4] `
		-Passed $FailureEvidenceResult.Passed `
		-Detail $FailureEvidenceResult.Detail
}
$Issue45InitialAuditPath = Join-Path $TestRoot (
	'test-worker-issue45-initial-artifacts\' +
	'delivery-stage-test-worker-issue45-initial-audit.json'
)
$Issue45InitialAudit = if (Test-Path -LiteralPath $Issue45InitialAuditPath -PathType Leaf) {
	Get-Content -Raw -LiteralPath $Issue45InitialAuditPath | ConvertFrom-Json
}
$Issue45InitialTelemetry = if (
	$null -ne $Issue45InitialAudit -and
	(Test-Path -LiteralPath ([string]$Issue45InitialAudit.TelemetryPath) -PathType Leaf)
) {
	Get-Content -Raw -LiteralPath ([string]$Issue45InitialAudit.TelemetryPath) |
		ConvertFrom-Json
}
$Issue45ReplacementAuditPath = Join-Path $TestRoot (
	'test-worker-issue45-replacement-artifacts\' +
	'delivery-stage-test-worker-issue45-replacement-audit.json'
)
$Issue45ReplacementAudit = if (
	Test-Path -LiteralPath $Issue45ReplacementAuditPath -PathType Leaf
) {
	Get-Content -Raw -LiteralPath $Issue45ReplacementAuditPath | ConvertFrom-Json
}
$Issue45ReplacementTelemetry = if (
	$null -ne $Issue45ReplacementAudit -and
	(Test-Path -LiteralPath ([string]$Issue45ReplacementAudit.TelemetryPath) -PathType Leaf)
) {
	Get-Content -Raw -LiteralPath ([string]$Issue45ReplacementAudit.TelemetryPath) |
		ConvertFrom-Json
}
Add-Result `
	-Name 'Issue #45 reproductions retain zero changed paths and exact exit classes' `
	-Passed (
		$null -ne $Issue45InitialAudit -and
		$null -ne $Issue45InitialTelemetry -and
		$null -ne $Issue45ReplacementAudit -and
		$null -ne $Issue45ReplacementTelemetry -and
		@($Issue45InitialAudit.ChangedPaths).Count -eq 0 -and
		$null -eq $Issue45InitialAudit.PatchPath -and
		[string]$Issue45InitialAudit.BeforeSnapshotHash -eq
			[string]$Issue45InitialAudit.AfterSnapshotHash -and
		[string]$Issue45InitialTelemetry.ExitClass -eq 'stage_not_passed' -and
		[string]$Issue45InitialTelemetry.StageStatus -eq 'failed' -and
		@($Issue45ReplacementAudit.ChangedPaths).Count -eq 0 -and
		$null -eq $Issue45ReplacementAudit.PatchPath -and
		[string]$Issue45ReplacementAudit.BeforeSnapshotHash -eq
			[string]$Issue45ReplacementAudit.AfterSnapshotHash -and
		[string]$Issue45ReplacementTelemetry.ExitClass -eq 'output_invalid' -and
		[string]$Issue45ReplacementTelemetry.StageStatus -eq 'passed'
	)


$RejectedRunId = 'test-worker-passed-nonapplying-patch'
$RejectedHandoffPath = Join-Path $TestRoot "$RejectedRunId.json"
$RejectedHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath | ConvertFrom-Json
$RejectedHandoff.run_id = $RejectedRunId
$RejectedHandoff = Get-WorkerHandoffWithCurrentBaseline -Handoff $RejectedHandoff
$RejectedHandoff | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $RejectedHandoffPath -Encoding UTF8
$RejectedArtifactRoot = Join-Path $TestRoot "$RejectedRunId-artifacts"
$RejectedAuditPath = Join-Path $RejectedArtifactRoot `
	"delivery-stage-$RejectedRunId-audit.json"
$RejectedManifestPath = Join-Path $RejectedArtifactRoot `
	"delivery-stage-$RejectedRunId-evidence.json"
$RejectedTelemetryPath = Join-Path $RejectedArtifactRoot `
	"delivery-stage-$RejectedRunId-telemetry.json"
$RejectedPatchPath = Join-Path $RejectedArtifactRoot `
	"delivery-stage-$RejectedRunId-candidate.patch"
$ExpectedRejectedPatch = [string]::Join("`n", @(
	'diff --git a/AGENTS.md b/AGENTS.md',
	'--- a/AGENTS.md',
	'+++ b/AGENTS.md',
	'@@ -1 +1 @@',
	'-this line cannot exist in the attested snapshot',
	'+replacement line'
)) + "`n"
$OriginalPath = $env:PATH
$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
$RejectedError = $null
try {
	$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = 'passed-nonapplying-patch'
	try {
		& $LaunchScript `
			-HandoffPath $RejectedHandoffPath `
			-ArtifactRoot $RejectedArtifactRoot | Out-Null
	}
	catch {
		$RejectedError = $_.Exception.Message
	}
}
finally {
	$env:PATH = $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
}
$RejectedAudit = Get-Content -Raw -LiteralPath $RejectedAuditPath | ConvertFrom-Json
$RejectedTelemetry = Get-Content -Raw -LiteralPath $RejectedTelemetryPath |
	ConvertFrom-Json
$RejectedManifest = Get-Content -Raw -LiteralPath $RejectedManifestPath |
	ConvertFrom-Json
$RejectedManifestHash = (
	Get-FileHash -LiteralPath $RejectedManifestPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$RejectedPatchBytes = [System.IO.File]::ReadAllBytes($RejectedPatchPath)
$ExpectedRejectedPatchBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	$ExpectedRejectedPatch
)
$DefaultRejected = Invoke-ExpectedFailure `
	-Pattern 'rejected|not routable|integrity-only' `
	-Action {
		& $EvidenceValidationScript `
			-ManifestPath $RejectedManifestPath `
			-ExpectedManifestHash $RejectedManifestHash `
			-ExpectedHandoffHash ([string]$RejectedAudit.HandoffHash) | Out-Null
	}
$IntegrityOnlySucceeded = $false
try {
	& $EvidenceValidationScript `
		-ManifestPath $RejectedManifestPath `
		-ExpectedManifestHash $RejectedManifestHash `
		-ExpectedHandoffHash ([string]$RejectedAudit.HandoffHash) `
		-IntegrityOnly | Out-Null
	$IntegrityOnlySucceeded = $true
}
catch {
	$IntegrityOnlySucceeded = $false
}
Add-Result `
	-Name 'Rejected passed-stage patch is sealed without becoming routable evidence' `
	-Passed (
		$RejectedError -match 'Candidate patch does not apply cleanly' -and
		$RejectedAudit.ArtifactValidationError -match 'Candidate patch does not apply cleanly' -and
		$RejectedTelemetry.ExitClass -eq 'output_invalid' -and
		$RejectedTelemetry.StageStatus -eq 'passed' -and
		$RejectedAudit.ArtifactFailureKind -eq 'patch_nonapplying' -and
		[long]$RejectedTelemetry.PatchBytes -eq $RejectedPatchBytes.Length -and
		(Test-TestByteArrayEqual $RejectedPatchBytes $ExpectedRejectedPatchBytes) -and
		@($RejectedManifest.Files | Where-Object { $_.Path -eq $RejectedPatchPath }).Count -eq 1 -and
		[string]$RejectedManifest.Disposition -eq 'rejected' -and
		$DefaultRejected -and
		$IntegrityOnlySucceeded
	) `
	-Detail $RejectedError

$AcceptedBundleRunId = 'test-worker-passed-bundle'
$AcceptedBundleHandoffPath = Join-Path $TestRoot "$AcceptedBundleRunId.json"
$AcceptedBundleHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$AcceptedBundleHandoff.run_id = $AcceptedBundleRunId
$AcceptedBundleHandoff.output_contract = (
	'Return a delivery_file_bundle_v1 full-file artifact.'
)
$AcceptedBundleHandoff.allowed_paths = @('AGENTS.md', 'README.md')
$AcceptedBundleHandoff.work_package = (
	'Propose AGENTS.md and README.md changes. ' +
	'Descriptive source reader note: keep each response compact.'
)
$AcceptedBundleHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
$AcceptedBundleHandoff = Get-WorkerHandoffWithCurrentBaseline `
	-Handoff $AcceptedBundleHandoff
$AcceptedBundleHandoff | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $AcceptedBundleHandoffPath -Encoding UTF8
$AcceptedBundleArtifactRoot = Join-Path (
	$TestRoot
) "$AcceptedBundleRunId-artifacts"
$AcceptedBundleManifestPath = Join-Path (
	$AcceptedBundleArtifactRoot
) "delivery-stage-$AcceptedBundleRunId-evidence.json"
$AcceptedBundleAuditPath = Join-Path (
	$AcceptedBundleArtifactRoot
) "delivery-stage-$AcceptedBundleRunId-audit.json"
$AcceptedBundlePatchPath = Join-Path (
	$AcceptedBundleArtifactRoot
) "delivery-stage-$AcceptedBundleRunId-candidate.patch"
$AcceptedBundleBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$AcceptedBundleBaseSha256 = [ordered]@{}
foreach ($AcceptedBundlePath in @('AGENTS.md', 'README.md')) {
	$AcceptedBundleFingerprint = [string](
		$AcceptedBundleBefore.Files[$AcceptedBundlePath]
	)
	if ($AcceptedBundleFingerprint -cnotmatch (
			'^([0-9a-f]{64})\|attributes=-?[0-9]+$'
		)) {
		throw "Accepted bundle fixture $AcceptedBundlePath fingerprint is malformed."
	}
	$AcceptedBundleBaseSha256[$AcceptedBundlePath] = $Matches[1]
}
$AcceptedBundleResult = $null
$AcceptedBundleError = ''
$OriginalPath = $env:PATH
$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
$OriginalExpectedAgentsSha256 = $env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256
$OriginalExpectedReadmeSha256 = $env:DELIVERY_FIXTURE_EXPECTED_README_SHA256
try {
	$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = 'passed-bundle-complete-pagination'
	$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = (
		$AcceptedBundleBaseSha256['AGENTS.md']
	)
	$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = (
		$AcceptedBundleBaseSha256['README.md']
	)
	$AcceptedBundleResult = & $LaunchScript `
		-HandoffPath $AcceptedBundleHandoffPath `
		-ArtifactRoot $AcceptedBundleArtifactRoot `
		-PassThru
}
catch {
	$AcceptedBundleError = $_.Exception.Message
}
finally {
	$env:PATH = $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
	$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = $OriginalExpectedAgentsSha256
	$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = $OriginalExpectedReadmeSha256
}
$AcceptedBundleAfter = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$AcceptedBundlePassed = $false
if ($null -ne $AcceptedBundleResult) {
	try {
		$AcceptedBundleAudit = Get-Content -Raw -LiteralPath $AcceptedBundleAuditPath |
			ConvertFrom-Json
		$AcceptedBundleManifestHash = (
			Get-FileHash -LiteralPath $AcceptedBundleManifestPath -Algorithm SHA256
		).Hash.ToLowerInvariant()
		$AcceptedBundleEvidence = & $EvidenceValidationScript `
			-ManifestPath $AcceptedBundleManifestPath `
			-ExpectedManifestHash $AcceptedBundleManifestHash `
			-ExpectedHandoffHash ([string]$AcceptedBundleAudit.HandoffHash)
		$AcceptedBundlePatchValidation = & $PatchValidationScript `
			-PatchPath $AcceptedBundlePatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('AGENTS.md', 'README.md')
		$AcceptedBundlePassed = (
			$AcceptedBundleResult.ArtifactFormat -eq 'delivery_file_bundle_v1' -and
			$AcceptedBundleAudit.ArtifactFormat -eq 'delivery_file_bundle_v1' -and
			$AcceptedBundleAudit.ArtifactFailureKind -eq $null -and
			$AcceptedBundleAudit.BeforeSnapshotHash -eq
				$AcceptedBundleAudit.AfterSnapshotHash -and
			$AcceptedBundleBefore.Hash -eq $AcceptedBundleAfter.Hash -and
			@($AcceptedBundlePatchValidation.ProposedPaths).Count -eq 2 -and
			$AcceptedBundlePatchValidation.ProposedPaths -contains 'AGENTS.md' -and
			$AcceptedBundlePatchValidation.ProposedPaths -contains 'README.md' -and
			$AcceptedBundleAudit.SourceInspection.Outcome -ceq 'complete_pagination' -and
			@($AcceptedBundleAudit.SourceInspection.CompletedSources).Count -eq 2 -and
			@($AcceptedBundleAudit.SourceInspection.CompletedSources | Where-Object {
				$AcceptedBundleBaseSha256.Contains([string]$_.Path) -and
				[string]$_.BaseSha256 -ceq
				[string]$AcceptedBundleBaseSha256[[string]$_.Path]
			}).Count -eq 2 -and
			$AcceptedBundleEvidence.Disposition -eq 'accepted'
		)
	}
	catch {
		$AcceptedBundleError = $_.Exception.Message
	}
}
Add-Result `
	-Name 'Attested hash prompt enables direct structured replacement bundle output' `
	-Passed $AcceptedBundlePassed `
	-Detail $AcceptedBundleError

$RejectedSourceOutcomeCases = @(
	@('no-tool-call', 'no_tool_call'),
	@('incomplete-pagination', 'incomplete_pagination'),
	@('argument-validation-failed', 'argument_validation_failed'),
	@('source-policy-rejected', 'source_policy_rejected'),
	@('protocol-rejected', 'protocol_rejected'),
	@('missing-replacement-source', 'complete_pagination'),
	@('mismatched-replacement-source', 'complete_pagination')
)
foreach ($RejectedSourceOutcomeCase in $RejectedSourceOutcomeCases) {
	$RejectedSourceSlug = [string]$RejectedSourceOutcomeCase[0]
	$ExpectedSourceOutcome = [string]$RejectedSourceOutcomeCase[1]
	$RejectedSourceRunId = "test-worker-bundle-$RejectedSourceSlug"
	$RejectedSourceHandoffPath = Join-Path $TestRoot "$RejectedSourceRunId.json"
	$RejectedSourceHandoff = $AcceptedBundleHandoff | ConvertTo-Json -Depth 8 |
		ConvertFrom-Json
	$RejectedSourceHandoff.run_id = $RejectedSourceRunId
	$RejectedSourceHandoff = Get-WorkerHandoffWithCurrentBaseline `
		-Handoff $RejectedSourceHandoff
	$RejectedSourceHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $RejectedSourceHandoffPath -Encoding UTF8
	$RejectedSourceArtifactRoot = Join-Path $TestRoot "$RejectedSourceRunId-artifacts"
	$RejectedSourceAuditPath = Join-Path $RejectedSourceArtifactRoot `
		"delivery-stage-$RejectedSourceRunId-audit.json"
	$RejectedSourceTelemetryPath = Join-Path $RejectedSourceArtifactRoot `
		"delivery-stage-$RejectedSourceRunId-telemetry.json"
	$RejectedSourceManifestPath = Join-Path $RejectedSourceArtifactRoot `
		"delivery-stage-$RejectedSourceRunId-evidence.json"
	$RejectedSourceError = ''
	$OriginalPath = $env:PATH
	$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
	$OriginalExpectedAgentsSha256 = $env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256
	$OriginalExpectedReadmeSha256 = $env:DELIVERY_FIXTURE_EXPECTED_README_SHA256
	try {
		$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = "passed-bundle-$RejectedSourceSlug"
		$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = (
			$AcceptedBundleBaseSha256['AGENTS.md']
		)
		$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = (
			$AcceptedBundleBaseSha256['README.md']
		)
		try {
			& $LaunchScript `
				-HandoffPath $RejectedSourceHandoffPath `
				-ArtifactRoot $RejectedSourceArtifactRoot | Out-Null
		}
		catch {
			$RejectedSourceError = $_.Exception.Message
		}
	}
	finally {
		$env:PATH = $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
		$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = $OriginalExpectedAgentsSha256
		$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = $OriginalExpectedReadmeSha256
	}
	$RejectedSourceAudit = Get-Content -Raw -LiteralPath $RejectedSourceAuditPath |
		ConvertFrom-Json
	$RejectedSourceTelemetry = Get-Content -Raw -LiteralPath $RejectedSourceTelemetryPath |
		ConvertFrom-Json
	$RejectedSourceManifest = Get-Content -Raw -LiteralPath $RejectedSourceManifestPath |
		ConvertFrom-Json
	Add-Result `
		-Name "Valid bundle cannot override source outcome $ExpectedSourceOutcome" `
		-Passed (
			$RejectedSourceError -match 'required source inspection did not complete' -and
			$RejectedSourceError -notmatch 'private-invalid-argument|private-policy-detail' -and
			$RejectedSourceTelemetry.ExitClass -ceq 'source_inspection_invalid' -and
			$RejectedSourceTelemetry.SourceInspection.Outcome -ceq $ExpectedSourceOutcome -and
			$RejectedSourceAudit.SourceInspection.Outcome -ceq $ExpectedSourceOutcome -and
			$RejectedSourceManifest.Disposition -ceq 'rejected'
		) `
		-Detail $RejectedSourceError
}

foreach ($SupportedBundleSourceCase in @(
	@('create-only', 'no_tool_call', 1),
	@('mixed-create-replace', 'complete_pagination', 2)
)) {
	$SupportedBundleSourceSlug = [string]$SupportedBundleSourceCase[0]
	$SupportedBundleSourceOutcome = [string]$SupportedBundleSourceCase[1]
	$SupportedBundlePathCount = [int]$SupportedBundleSourceCase[2]
	$SupportedBundleRunId = "test-worker-bundle-$SupportedBundleSourceSlug"
	$SupportedBundleHandoffPath = Join-Path $TestRoot "$SupportedBundleRunId.json"
	$SupportedBundleHandoff = $AcceptedBundleHandoff | ConvertTo-Json -Depth 8 |
		ConvertFrom-Json
	$SupportedBundleHandoff.run_id = $SupportedBundleRunId
	$SupportedBundleHandoff.allowed_paths = @(
		'AGENTS.md', 'README.md', 'docs/source-created.md'
	)
	$SupportedBundleHandoff = Get-WorkerHandoffWithCurrentBaseline `
		-Handoff $SupportedBundleHandoff
	$SupportedBundleHandoff | ConvertTo-Json -Depth 8 | Set-Content `
		-LiteralPath $SupportedBundleHandoffPath -Encoding UTF8
	$SupportedBundleArtifactRoot = Join-Path $TestRoot `
		"$SupportedBundleRunId-artifacts"
	$SupportedBundleAuditPath = Join-Path $SupportedBundleArtifactRoot `
		"delivery-stage-$SupportedBundleRunId-audit.json"
	$SupportedBundleError = ''
	$OriginalPath = $env:PATH
	$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
	$OriginalExpectedAgentsSha256 = $env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256
	$OriginalExpectedReadmeSha256 = $env:DELIVERY_FIXTURE_EXPECTED_README_SHA256
	try {
		$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = "passed-bundle-$SupportedBundleSourceSlug"
		$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = (
			$AcceptedBundleBaseSha256['AGENTS.md']
		)
		$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = (
			$AcceptedBundleBaseSha256['README.md']
		)
		try {
			& $LaunchScript `
				-HandoffPath $SupportedBundleHandoffPath `
				-ArtifactRoot $SupportedBundleArtifactRoot | Out-Null
		}
		catch {
			$SupportedBundleError = $_.Exception.Message
		}
	}
	finally {
		$env:PATH = $OriginalPath
		$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
		$env:DELIVERY_FIXTURE_EXPECTED_AGENTS_SHA256 = $OriginalExpectedAgentsSha256
		$env:DELIVERY_FIXTURE_EXPECTED_README_SHA256 = $OriginalExpectedReadmeSha256
	}
	$SupportedBundleAudit = Get-Content -Raw -LiteralPath $SupportedBundleAuditPath |
		ConvertFrom-Json
	$SupportedBundleTelemetry = Get-Content -Raw -LiteralPath (
		[string]$SupportedBundleAudit.TelemetryPath
	) | ConvertFrom-Json
	Add-Result `
		-Name "Bundle source policy supports $SupportedBundleSourceSlug artifacts" `
		-Passed (
			[string]::IsNullOrWhiteSpace($SupportedBundleError) -and
			$SupportedBundleTelemetry.ExitClass -ceq 'completed' -and
			$SupportedBundleTelemetry.SourceInspection.Outcome -ceq
				$SupportedBundleSourceOutcome -and
			@($SupportedBundleTelemetry.SourceInspection.CompletedSources).Count -eq
				$(if ($SupportedBundleSourceSlug -ceq 'create-only') { 0 } else { 1 }) -and
			@($SupportedBundleAudit.ProposedPaths).Count -eq $SupportedBundlePathCount
		) `
		-Detail $SupportedBundleError
}
$CorrectedRunId = 'test-worker-issue141-corrected'
$CorrectedHandoffPath = Join-Path $TestRoot "$CorrectedRunId.json"
$CorrectedHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$CorrectedHandoff.run_id = $CorrectedRunId
$CorrectedHandoff.output_contract = (
	'Return a delivery_file_bundle_v1 full-file artifact.'
)
$CorrectedHandoff.work_package = (
	'Propose an AGENTS.md change from tool-read source.'
)
$CorrectedHandoff = Get-WorkerHandoffWithCurrentBaseline -Handoff $CorrectedHandoff
$CorrectedHandoff | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $CorrectedHandoffPath -Encoding UTF8
$CorrectedArtifactRoot = Join-Path $TestRoot "$CorrectedRunId-artifacts"
$CorrectedAuditPath = Join-Path (
	$CorrectedArtifactRoot
) "delivery-stage-$CorrectedRunId-audit.json"
$CorrectedManifestPath = Join-Path (
	$CorrectedArtifactRoot
) "delivery-stage-$CorrectedRunId-evidence.json"
$CorrectedPatchPath = Join-Path (
	$CorrectedArtifactRoot
) "delivery-stage-$CorrectedRunId-candidate.patch"
$CorrectedAttestationPath = Join-Path (
	$CorrectedArtifactRoot
) "delivery-stage-$CorrectedRunId-source-attestation.json"
$CorrectedBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$CorrectedResult = $null
$CorrectedError = ''
$OriginalPath = $env:PATH
$OriginalScenario = $env:DELIVERY_FIXTURE_SCENARIO
try {
	$env:PATH = $FixtureBin + [System.IO.Path]::PathSeparator + $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = 'issue141-corrected'
	$CorrectedResult = & $LaunchScript `
		-HandoffPath $CorrectedHandoffPath `
		-ArtifactRoot $CorrectedArtifactRoot `
		-PassThru
}
catch {
	$CorrectedError = $_.Exception.Message
}
finally {
	$env:PATH = $OriginalPath
	$env:DELIVERY_FIXTURE_SCENARIO = $OriginalScenario
}
$CorrectedAfter = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$CorrectedPassed = $false
if ($null -ne $CorrectedResult) {
	try {
		$CorrectedAudit = Get-Content -Raw -LiteralPath $CorrectedAuditPath |
			ConvertFrom-Json
		$CorrectedManifestHash = (
			Get-FileHash -LiteralPath $CorrectedManifestPath -Algorithm SHA256
		).Hash.ToLowerInvariant()
		$CorrectedEvidence = & $EvidenceValidationScript `
			-ManifestPath $CorrectedManifestPath `
			-ExpectedManifestHash $CorrectedManifestHash `
			-ExpectedHandoffHash ([string]$CorrectedAudit.HandoffHash)
		$CorrectedPatchValidation = & $PatchValidationScript `
			-PatchPath $CorrectedPatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('AGENTS.md')
		$CorrectedManifest = Get-Content -Raw -LiteralPath $CorrectedManifestPath |
			ConvertFrom-Json
		$CorrectedPassed = (
			$CorrectedResult.ArtifactFormat -eq 'delivery_file_bundle_v1' -and
			$CorrectedAudit.ArtifactFormat -eq 'delivery_file_bundle_v1' -and
			$CorrectedAudit.ArtifactFailureKind -eq $null -and
			$CorrectedAudit.BeforeSnapshotHash -eq
				$CorrectedAudit.AfterSnapshotHash -and
			$CorrectedBefore.Hash -eq $CorrectedAfter.Hash -and
			(Test-Path -LiteralPath $CorrectedAttestationPath -PathType Leaf) -and
			@($CorrectedManifest.Files | Where-Object {
				[string]$_.Path -eq $CorrectedAttestationPath
			}).Count -eq 0 -and
			@($CorrectedPatchValidation.ProposedPaths).Count -eq 1 -and
			$CorrectedPatchValidation.ProposedPaths[0] -eq 'AGENTS.md' -and
			$CorrectedEvidence.Disposition -eq 'accepted'
		)
	}
	catch {
		$CorrectedError = $_.Exception.Message
	}
}
Add-Result `
	-Name 'Restricted source-inspection surface produces an accepted full-file bundle' `
	-Passed $CorrectedPassed `
	-Detail $CorrectedError


try {
	$DryRun = & $LaunchScript -HandoffPath $WorkerHandoffPath -DryRun -PassThru
	$RequiredArguments = @(
		'--ephemeral',
		'--ignore-user-config',
		'--strict-config',
		'--disable',
		'apps',
		'--sandbox',
		'read-only',
		'features.shell_tool=false',
		'mcp_servers.source_inspection.required=true',
		'mcp_servers.source_inspection.enabled_tools=[''read_allowed_source_file'']',
		(
			'mcp_servers.source_inspection.tools.read_allowed_source_file.' +
			'approval_mode=''approve'''
		),
		'web_search="disabled"'
	)
	$MissingArguments = @($RequiredArguments | Where-Object {
		$DryRun.Arguments -notcontains $_
	})
	$SourceInspectionCommandArguments = @($DryRun.Arguments | Where-Object {
		$_ -match '^mcp_servers\.source_inspection\.command='
	})
	$SourceInspectionArgsArguments = @($DryRun.Arguments | Where-Object {
		$_ -match '^mcp_servers\.source_inspection\.args='
	})
	$AttestationArgumentMatch = if ($SourceInspectionArgsArguments.Count -eq 1) {
		[regex]::Match(
			$SourceInspectionArgsArguments[0],
			"'-AttestationPath', '([^']+)'"
		)
	}
	else {
		$null
	}

	Add-Result `
		-Name 'Artifact-producing worker is read-only' `
		-Passed (
			$MissingArguments.Count -eq 0 -and
			$DryRun.Arguments -notcontains 'mcp_servers={}' -and
			$SourceInspectionCommandArguments.Count -eq 1 -and
			$SourceInspectionArgsArguments.Count -eq 1 -and
			$SourceInspectionArgsArguments[0].Contains(
				'Invoke-DeliverySourceInspectionServer.ps1'
			) -and
			$SourceInspectionArgsArguments[0].Contains('-AttestationSha256') -and
			$SourceInspectionArgsArguments[0].Contains('-WorkspaceRoot') -and
			$SourceInspectionArgsArguments[0].Contains(
				'delivery-stage-test-worker-source-attestation.json'
			) -and
			$null -ne $AttestationArgumentMatch -and
			$AttestationArgumentMatch.Success -and
			-not (Test-Path -LiteralPath $AttestationArgumentMatch.Groups[1].Value) -and
			-not [string]::IsNullOrWhiteSpace($DryRun.PatchPath) -and
			$DryRun.Arguments[
				[Array]::IndexOf($DryRun.Arguments, '--output-schema') + 1
			] -eq (
				Join-Path $SkillRoot 'references\stage-output-producer-schema.json'
			)
		) `
		-Detail ($MissingArguments -join ', ')
}
catch {
	Add-Result `
		-Name 'Artifact-producing worker is read-only' `
		-Passed $false `
		-Detail $_.Exception.Message
}
$ProducerSurfaceCases = @(
	[pscustomobject]@{
		Stage = 'integrator'
		Handoff = [ordered]@{
			schema_version = 1
			stage = 'integrator'
			run_id = 'test-integrator-surface'
			workspace_root = $RepositoryRoot
			source_commit = $SourceCommit
			ticket = 'Issue #123'
			acceptance_criteria = @('Criterion')
			canonical_sources = @('AGENTS.md')
			output_contract = 'Return a delivery_file_bundle_v1 full-file artifact.'
			candidate_artifacts = @(
				New-NeutralEvidenceRecord -Kind artifact -Provenance launcher `
					-Source 'candidate-a' -Text 'candidate a'
			)
			integration_order = @('candidate-a')
			conflict_locations = New-NeutralEvidenceRecord -Kind text `
				-Provenance control_plane -Source 'conflicts' -Text 'none'
			allowed_paths = @('AGENTS.md')
			non_goals = @('Everything else')
			baseline_status = New-NeutralEvidenceRecord -Kind status `
				-Provenance launcher -Source 'baseline-status' `
				-Text $WorkerBaselineStatus
			baseline_diff = New-NeutralEvidenceRecord -Kind diff `
				-Provenance launcher -Source 'baseline-diff' `
				-Text $WorkerBaselineDiff -Encoding base64
		}
	},
	[pscustomobject]@{
		Stage = 'fixer'
		Handoff = [ordered]@{
			schema_version = 1
			stage = 'fixer'
			run_id = 'test-fixer-surface'
			workspace_root = $RepositoryRoot
			source_commit = $SourceCommit
			ticket = 'Issue #123'
			acceptance_criteria = @('Criterion')
			canonical_sources = @('AGENTS.md')
			output_contract = 'Return a delivery_file_bundle_v1 full-file artifact.'
			candidate_artifact = 'candidate artifact'
			accepted_findings = @('Finding')
			allowed_paths = @('AGENTS.md')
			non_goals = @('Everything else')
			required_checks = @('git diff --check')
			baseline_status = $WorkerBaselineStatus
			baseline_diff = $WorkerBaselineDiff
		}
	}
)

$IntegratorSourceConflictHandoff = $ProducerSurfaceCases[0].Handoff |
	ConvertTo-Json -Depth 12 | ConvertFrom-Json
$IntegratorSourceConflictHandoff.run_id = 'test-integrator-source-protocol-conflict'
$IntegratorSourceConflictHandoff.integration_order = @(
	'Use read_allowed_source_file with path, offset_bytes, and limit_bytes: 2048.'
)
$IntegratorSourceConflictHandoff | Add-Member `
	-NotePropertyName source_inspection_protocol `
	-NotePropertyValue $SupportedLauncherSourceProtocol
Invoke-SourceProtocolPreflightRejection `
	-Name 'Integrator integration order source conflict is retry-neutrally rejected' `
	-Handoff $IntegratorSourceConflictHandoff `
	-PrivateMarker 'private-integrator-source-member'

foreach ($ProducerSurfaceCase in $ProducerSurfaceCases) {
	$ProducerSurfaceName = (
		"Artifact-producing $($ProducerSurfaceCase.Stage) receives the " +
		'restricted source-inspection surface'
	)
	try {
		$ProducerSurfaceHandoffPath = Join-Path $TestRoot (
			"$($ProducerSurfaceCase.Stage)-surface.json"
		)
		$ProducerSurfaceCase.Handoff | ConvertTo-Json -Depth 8 | Set-Content `
			-LiteralPath $ProducerSurfaceHandoffPath -Encoding UTF8
		$ProducerSurfaceDryRun = & $LaunchScript `
			-HandoffPath $ProducerSurfaceHandoffPath `
			-DryRun `
			-PassThru
		Add-Result `
			-Name $ProducerSurfaceName `
			-Passed (
				$ProducerSurfaceDryRun.SandboxMode -eq 'read-only' -and
				$ProducerSurfaceDryRun.Arguments -contains (
					'features.shell_tool=false'
				) -and
				$ProducerSurfaceDryRun.Arguments -notcontains 'mcp_servers={}' -and
				$ProducerSurfaceDryRun.Arguments -contains (
					'mcp_servers.source_inspection.required=true'
				) -and
				$ProducerSurfaceDryRun.Arguments -contains (
					'mcp_servers.source_inspection.enabled_tools=' +
					'[''read_allowed_source_file'']'
				) -and
				$ProducerSurfaceDryRun.Arguments -contains (
					'mcp_servers.source_inspection.tools.read_allowed_source_file.' +
					'approval_mode=''approve'''
				) -and
				@($ProducerSurfaceDryRun.Arguments | Where-Object {
					$_ -match '^mcp_servers\.source_inspection\.command='
				}).Count -eq 1 -and
				@($ProducerSurfaceDryRun.Arguments | Where-Object {
					$_ -match '^mcp_servers\.source_inspection\.args='
				}).Count -eq 1 -and
				-not [string]::IsNullOrWhiteSpace($ProducerSurfaceDryRun.PatchPath)
			)
	}
	catch {
		Add-Result `
			-Name $ProducerSurfaceName `
			-Passed $false `
			-Detail $_.Exception.Message
	}
}


$ArtifactProducerProfiles = @(
	@{ Name = 'worker'; Path = '.codex\agents\delivery-worker.toml' },
	@{ Name = 'integrator'; Path = '.codex\agents\delivery-integrator.toml' },
	@{ Name = 'fixer'; Path = '.codex\agents\delivery-fixer.toml' }
)
$SourcePagingContractMarkers = @(
	'start with `offset_bytes` set to zero',
	'exact prior `end_offset_bytes` until `eof` is true',
	'each call returns at most 8192 bytes',
	'without gaps, overlaps, reordering, or duplication',
	'consistent `path`, `encoding`, `file_size_bytes`, and launcher-owned `base_sha256`',
	'final `end_offset_bytes` and reconstructed byte count to equal `file_size_bytes` exactly',
	'use that consistent launcher-owned `base_sha256` exactly without calculating or re-deriving it'
)
$ObsoleteOneCallContract = (
	'the tool returns the complete attested bytes'
)
$ObsoleteProducerHashContract = (
	'sha-256 equal to that consistent `base_sha256`'
)
foreach ($ProducerProfile in $ArtifactProducerProfiles) {
	$ProducerProfileSource = Get-Content -Raw -LiteralPath (
		Join-Path $RepositoryRoot $ProducerProfile.Path
	)
	$ProducerInstructionMatch = [regex]::Match(
		$ProducerProfileSource,
		'(?s)developer_instructions\s*=\s*"""\r?\n?(.*?)\r?\n?"""'
	)
	$EffectiveProducerPrompt = if ($ProducerInstructionMatch.Success) {
		$ProducerInstructionMatch.Groups[1].Value.ToLowerInvariant()
	}
	else {
		''
	}
	$MissingPagingMarkers = @($SourcePagingContractMarkers | Where-Object {
		-not $EffectiveProducerPrompt.Contains($_)
	})
	Add-Result `
		-Name "$($ProducerProfile.Name) effective prompt requires paged source reconstruction" `
		-Passed (
			$ProducerInstructionMatch.Success -and
			$MissingPagingMarkers.Count -eq 0
		) `
		-Detail ([string]::Join(', ', $MissingPagingMarkers))
	Add-Result `
		-Name "$($ProducerProfile.Name) effective prompt rejects obsolete one-call source reading" `
		-Passed (
			$ProducerInstructionMatch.Success -and
			-not $EffectiveProducerPrompt.Contains($ObsoleteOneCallContract)
		)
	Add-Result `
		-Name "$($ProducerProfile.Name) effective prompt rejects producer-driven hash verification" `
		-Passed (
			$ProducerInstructionMatch.Success -and
			-not $EffectiveProducerPrompt.Contains($ObsoleteProducerHashContract)
		)
}

$WildcardWorkerHandoffPath = Join-Path $TestRoot 'worker-wildcard-scope.json'
$WildcardWorkerHandoff = Get-Content -Raw -LiteralPath $WorkerHandoffPath |
	ConvertFrom-Json
$WildcardWorkerHandoff.run_id = 'test-worker-wildcard-scope'
$WildcardWorkerHandoff.allowed_paths = @('.delivery-scope/**')
$WildcardWorkerHandoff.work_package = 'Propose files inside the wildcard scope.'
$WildcardWorkerHandoff | ConvertTo-Json -Depth 8 | Set-Content `
	-LiteralPath $WildcardWorkerHandoffPath -Encoding UTF8
$WildcardWorkerDryRunPassed = $false
$WildcardWorkerDryRunDetail = ''
try {
	$WildcardWorkerDryRun = & $LaunchScript `
		-HandoffPath $WildcardWorkerHandoffPath `
		-DryRun `
		-PassThru
	$WildcardWorkerDryRunPassed = (
		$WildcardWorkerDryRun.Stage -eq 'worker' -and
		$WildcardWorkerDryRun.SandboxMode -eq 'read-only'
	)
}
catch {
	$WildcardWorkerDryRunDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Artifact-producer wildcard scope passes structural preflight' `
	-Passed $WildcardWorkerDryRunPassed `
	-Detail $WildcardWorkerDryRunDetail

$WorkerArtifactAliases = @(
	@('delivery-stage-test-worker-events.jsonl', 'event log'),
	@('delivery-stage-test-worker-evidence.json', 'evidence manifest'),
	@('delivery-stage-test-worker-candidate.patch', 'candidate patch')
)
foreach ($ArtifactAlias in $WorkerArtifactAliases) {
	$ArtifactAliasFailure = Invoke-ExpectedFailure `
		-Pattern 'resolve to the same path' `
		-Action {
			& $LaunchScript `
				-HandoffPath $WorkerHandoffPath `
				-OutputPath $ArtifactAlias[0] `
				-ArtifactRoot $AliasedArtifactRoot `
				-DryRun | Out-Null
		}
	Add-Result `
		-Name "Output collision with $($ArtifactAlias[1]) is rejected before launch" `
		-Passed $ArtifactAliasFailure
}

$LauncherTokens = $null
$LauncherParseErrors = $null
$LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile(
	$LaunchScript,
	[ref]$LauncherTokens,
	[ref]$LauncherParseErrors
)
$PatchWriterAst = $LauncherAst.Find({
	param($Node)
	$Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Node.Name -eq 'Write-CandidatePatchArtifact'
}, $true)
$PatchSerializationPassed = $false
$PatchSerializationDetail = ''
try {
	if ($LauncherParseErrors.Count -gt 0 -or $null -eq $PatchWriterAst) {
		throw 'Could not load the production candidate-patch serializer.'
	}

	Invoke-Expression $PatchWriterAst.Extent.Text
	$SerializedPatchPath = Join-Path $TestRoot 'serialized-candidate.patch'
	$SerializedPatch = "diff --git a/cafÃ© b/cafÃ©`n-no-newline`n+replacement"
	Write-CandidatePatchArtifact `
		-Path $SerializedPatchPath `
		-Content $SerializedPatch
	$SerializedBytes = [System.IO.File]::ReadAllBytes($SerializedPatchPath)
	$ExpectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($SerializedPatch)
	$PatchSerializationPassed = (
		[System.Convert]::ToBase64String($SerializedBytes) -ceq [System.Convert]::ToBase64String($ExpectedBytes) -and
		-not ($SerializedBytes.Length -ge 3 -and
			$SerializedBytes[0] -eq 0xEF -and
			$SerializedBytes[1] -eq 0xBB -and
			$SerializedBytes[2] -eq 0xBF) -and
		$SerializedBytes[$SerializedBytes.Length - 1] -ne 0x0A
	)
}
catch {
	$PatchSerializationDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Candidate patch serialization is BOM-free and preserves no terminal newline' `
	-Passed $PatchSerializationPassed `
	-Detail $PatchSerializationDetail

Add-Result `
	-Name 'Production launcher has no command override' `
	-Passed (-not (Get-Command $LaunchScript).Parameters.ContainsKey('CodexCommand'))

$LauncherTokens = $null
$LauncherParseErrors = $null
$LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile(
	$LaunchScript,
	[ref]$LauncherTokens,
	[ref]$LauncherParseErrors
)
$GitBytesFunctionAst = $LauncherAst.Find({
	param($Node)

	return (
		$Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Node.Name -ceq 'Invoke-DeliveryGitBytes'
	)
}, $true)
$EmptyGitBytesPassed = $false
$EmptyGitBytesDetail = ''
try {
	if ($LauncherParseErrors.Count -ne 0 -or $null -eq $GitBytesFunctionAst) {
		throw 'Could not isolate the production Git byte helper.'
	}

	$WorkspaceRoot = $RepositoryRoot
	. ([scriptblock]::Create($GitBytesFunctionAst.Extent.Text))
	$EmptyGitBytes = Invoke-DeliveryGitBytes `
		-Arguments 'status --porcelain=v1 -z --untracked-files=no -- .delivery-empty-output-probe'
	$EmptyGitBytesPassed = (
		$null -ne $EmptyGitBytes -and
		$EmptyGitBytes -is [byte[]] -and
		$EmptyGitBytes.Length -eq 0
	)
}
catch {
	$EmptyGitBytesDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Production Git byte helper preserves successful empty output' `
	-Passed $EmptyGitBytesPassed `
	-Detail $EmptyGitBytesDetail

$LauncherSource = Get-Content -Raw -LiteralPath $LaunchScript
$MutationGateIndex = $LauncherSource.IndexOf('$ChangedPaths.Count -eq 0')
$ArtifactReadIndex = $LauncherSource.IndexOf(
	'Get-Content -Raw -LiteralPath $OutputPath'
)
Add-Result `
	-Name 'Mutation gate precedes stage-output consumption' `
	-Passed (
		$MutationGateIndex -ge 0 -and
		$ArtifactReadIndex -gt $MutationGateIndex
	)

$EvidenceFile = Join-Path $TestRoot 'evidence-output.json'
$EvidenceManifest = Join-Path $TestRoot 'evidence-manifest.json'
Set-Content -LiteralPath $EvidenceFile -Value '{"result":"fixture"}' -Encoding UTF8

$InvalidEvidenceCases = @(
	[pscustomobject]@{
		Name = 'Blank declared evidence path is rejected'
		Path = ' '
		Pattern = 'must not be blank'
	},
	[pscustomobject]@{
		Name = 'Missing declared evidence path is rejected'
		Path = Join-Path $TestRoot 'missing-evidence.json'
		Pattern = 'does not exist'
	},
	[pscustomobject]@{
		Name = 'Non-file declared evidence path is rejected'
		Path = $TestRoot
		Pattern = 'not a file'
	}
)
foreach ($InvalidEvidenceCase in $InvalidEvidenceCases) {
	$RejectedManifest = Join-Path $TestRoot (
		[guid]::NewGuid().ToString('N') + '-rejected-manifest.json'
	)
	$InvalidEvidenceRejected = Invoke-ExpectedFailure `
		-Pattern $InvalidEvidenceCase.Pattern `
		-Action {
			& $EvidenceProtectionScript `
				-EvidencePaths @($EvidenceFile, $InvalidEvidenceCase.Path) `
				-ManifestPath $RejectedManifest `
				-HandoffHash ('a' * 64) `
				-Disposition 'accepted' | Out-Null
		}
	Add-Result `
		-Name $InvalidEvidenceCase.Name `
		-Passed ($InvalidEvidenceRejected -and -not (Test-Path -LiteralPath $RejectedManifest))
}

$LegacyEvidenceFile = Join-Path $TestRoot 'legacy-evidence-output.json'
$LegacyManifestPath = Join-Path $TestRoot 'legacy-evidence-manifest.json'
Set-Content `
	-LiteralPath $LegacyEvidenceFile `
	-Value '{"result":"legacy fixture"}' `
	-Encoding UTF8
$LegacyManifest = [ordered]@{
	HandoffHash = ('d' * 64)
	Files = @(
		[ordered]@{
			Path = (Resolve-Path -LiteralPath $LegacyEvidenceFile).Path
			Sha256 = (
				Get-FileHash -LiteralPath $LegacyEvidenceFile -Algorithm SHA256
			).Hash.ToLowerInvariant()
		}
	)
}
$LegacyManifest |
	ConvertTo-Json -Depth 8 |
	Set-Content -LiteralPath $LegacyManifestPath -Encoding UTF8
$LegacyManifestHash = (
	Get-FileHash -LiteralPath $LegacyManifestPath -Algorithm SHA256
).Hash.ToLowerInvariant()
(Get-Item -LiteralPath $LegacyEvidenceFile -Force).IsReadOnly = $true
(Get-Item -LiteralPath $LegacyManifestPath -Force).IsReadOnly = $true
$LegacyDefaultRejected = Invoke-ExpectedFailure `
	-Pattern 'legacy|not routable|unsupported schema' `
	-Action {
		& $EvidenceValidationScript `
			-ManifestPath $LegacyManifestPath `
			-ExpectedManifestHash $LegacyManifestHash `
			-ExpectedHandoffHash ('d' * 64) | Out-Null
	}
$LegacyIntegrityOnlySucceeded = $false
$LegacyIntegrityOnlyResult = $null
try {
	$LegacyIntegrityOnlyResult = & $EvidenceValidationScript `
		-ManifestPath $LegacyManifestPath `
		-ExpectedManifestHash $LegacyManifestHash `
		-ExpectedHandoffHash ('d' * 64) `
		-IntegrityOnly
	$LegacyIntegrityOnlySucceeded = $true
}
catch {
	$LegacyIntegrityOnlySucceeded = $false
}
Add-Result `
	-Name 'Legacy evidence is audit-only and never normally routable' `
	-Passed (
		$LegacyDefaultRejected -and
		$LegacyIntegrityOnlySucceeded -and
		$LegacyIntegrityOnlyResult.Disposition -eq 'legacy-unknown' -and
		$LegacyIntegrityOnlyResult.FileCount -eq 1
	)

$EvidenceProtection = & $EvidenceProtectionScript `
	-EvidencePaths @($EvidenceFile) `
	-ManifestPath $EvidenceManifest `
	-HandoffHash ('a' * 64) `
	-Disposition 'accepted'
$EvidenceValidation = & $EvidenceValidationScript `
	-ManifestPath $EvidenceManifest `
	-ExpectedManifestHash $EvidenceProtection.ManifestHash `
	-ExpectedHandoffHash ('a' * 64)
$EvidenceOverwriteRejected = Invoke-ExpectedFailure -Pattern 'read-only|access|denied' -Action {
	Set-Content -LiteralPath $EvidenceFile -Value 'tampered' -ErrorAction Stop
}
$EvidenceManifestContent = Get-Content -Raw -LiteralPath $EvidenceManifest | ConvertFrom-Json
Add-Result `
	-Name 'Evidence files are hash-bound and read-only' `
	-Passed (
		$EvidenceOverwriteRejected -and
		(Get-Item -LiteralPath $EvidenceFile).IsReadOnly -and
		(Get-Item -LiteralPath $EvidenceManifest).IsReadOnly -and
		$EvidenceProtection.Disposition -eq 'accepted' -and
		$EvidenceValidation.Disposition -eq 'accepted' -and
		$EvidenceManifestContent.Disposition -eq 'accepted' -and
		$EvidenceValidation.FileCount -eq 1 -and
		$EvidenceManifestContent.Files[0].Sha256 -eq (
			Get-FileHash -LiteralPath $EvidenceFile -Algorithm SHA256
		).Hash.ToLowerInvariant()
	)

$WrongHandoffRejected = Invoke-ExpectedFailure -Pattern 'different handoff' -Action {
	& $EvidenceValidationScript `
		-ManifestPath $EvidenceManifest `
		-ExpectedManifestHash $EvidenceProtection.ManifestHash `
		-ExpectedHandoffHash ('b' * 64) | Out-Null
}
Add-Result `
	-Name 'Evidence from another handoff is rejected' `
	-Passed $WrongHandoffRejected

$EvidenceItem = Get-Item -LiteralPath $EvidenceFile -Force
$EvidenceItem.IsReadOnly = $false
Set-Content -LiteralPath $EvidenceFile -Value 'tampered' -Encoding UTF8
$EvidenceItem = Get-Item -LiteralPath $EvidenceFile -Force
$EvidenceItem.IsReadOnly = $true
$EvidenceTamperDetected = Invoke-ExpectedFailure -Pattern 'manifest hash' -Action {
	& $EvidenceValidationScript `
		-ManifestPath $EvidenceManifest `
		-ExpectedManifestHash $EvidenceProtection.ManifestHash `
		-ExpectedHandoffHash ('a' * 64) | Out-Null
}
Add-Result `
	-Name 'Evidence manifest detects attribute-bypass tampering' `
	-Passed $EvidenceTamperDetected

# Deliberate in-repo fixture (#146): the sentinel must be a tracked file so
# the snapshot proves detection of tracked-tree mutation; it cannot move to
# temp. Its mutation window is the try/finally below only, restored on every
# path, and the suite lock guarantees no concurrent reader of this worktree.
$MutationSentinelPath = Join-Path (
	$ScriptRoot
) 'tests\fixtures\mutation-sentinel.txt'
$SentinelBytes = [System.IO.File]::ReadAllBytes($MutationSentinelPath)
$SentinelTimestamp = (Get-Item -LiteralPath $MutationSentinelPath).LastWriteTimeUtc
$BeforeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$MutationDetected = $false
try {
	$ReplacementBytes = [byte[]]::new($SentinelBytes.Length)
	for ($Index = 0; $Index -lt $ReplacementBytes.Length; $Index++) {
		$ReplacementBytes[$Index] = [byte][char]'x'
	}
	[System.IO.File]::WriteAllBytes($MutationSentinelPath, $ReplacementBytes)
	[System.IO.File]::SetLastWriteTimeUtc($MutationSentinelPath, $SentinelTimestamp)
	$AfterMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
	$MutationDetected = (
		$BeforeMutation.Hash -ne $AfterMutation.Hash -and
		$BeforeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		] -ne $AfterMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		]
	)
}
finally {
	[System.IO.File]::WriteAllBytes($MutationSentinelPath, $SentinelBytes)
	[System.IO.File]::SetLastWriteTimeUtc($MutationSentinelPath, $SentinelTimestamp)
}
Add-Result -Name 'Snapshot detects same-length timestamp-restored mutation' -Passed $MutationDetected

$BeforeAttributeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$OriginalReadOnly = (Get-Item -LiteralPath $MutationSentinelPath -Force).IsReadOnly
$AttributeMutationDetected = $false
try {
	$MutationSentinelItem = Get-Item -LiteralPath $MutationSentinelPath -Force
	$MutationSentinelItem.IsReadOnly = -not $OriginalReadOnly
	$AfterAttributeMutation = & $SnapshotScript -RepositoryRoot $RepositoryRoot
	$AttributeMutationDetected = (
		$BeforeAttributeMutation.Hash -ne $AfterAttributeMutation.Hash -and
		$BeforeAttributeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		] -ne $AfterAttributeMutation.Files[
			'.agents/skills/orchestrate-delivery/scripts/tests/fixtures/mutation-sentinel.txt'
		]
	)
}
finally {
	$MutationSentinelItem = Get-Item -LiteralPath $MutationSentinelPath -Force
	$MutationSentinelItem.IsReadOnly = $OriginalReadOnly
}
Add-Result `
	-Name 'Snapshot detects metadata-only read-only attribute mutation' `
	-Passed $AttributeMutationDetected

$OutOfScopePatchPath = Join-Path $TestRoot 'out-of-scope.patch'
@'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-before
+after
'@ | Set-Content -LiteralPath $OutOfScopePatchPath -Encoding UTF8
$OutOfScopeFailure = Invoke-ExpectedFailure -Pattern 'outside allowed paths|invalid artifact' -Action {
	& $PatchValidationScript `
		-PatchPath $OutOfScopePatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('AGENTS.md') | Out-Null
}
Add-Result -Name 'Out-of-scope candidate patch is rejected' -Passed $OutOfScopeFailure

$SensitiveCandidatePatchPath = Join-Path $TestRoot 'sensitive-candidate.patch'
@'
diff --git a/.delivery-scope/.env b/.delivery-scope/.env
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/.env
@@ -0,0 +1 @@
+placeholder
'@ | Set-Content -LiteralPath $SensitiveCandidatePatchPath -Encoding UTF8
$SensitiveCandidateFailure = Invoke-ExpectedFailure `
	-Pattern 'patch_path_sensitive|is sensitive' `
	-Action {
		& $PatchValidationScript `
			-PatchPath $SensitiveCandidatePatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('.delivery-scope/**') | Out-Null
	}
Add-Result `
	-Name 'Sensitive candidate path is rejected before applicability checks' `
	-Passed $SensitiveCandidateFailure

$OutOfScopeRenamePatchPath = Join-Path $TestRoot 'out-of-scope-rename.patch'
@'
diff --git a/README.md b/.delivery-scope/renamed-readme.md
similarity index 100%
rename from README.md
rename to .delivery-scope/renamed-readme.md
'@ | Set-Content -LiteralPath $OutOfScopeRenamePatchPath -Encoding UTF8
$OutOfScopeRenameFailure = Invoke-ExpectedFailure `
	-Pattern 'rename or copy metadata.*delete and add patches' `
	-Action {
		& $PatchValidationScript `
			-PatchPath $OutOfScopeRenamePatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('.delivery-scope/**') | Out-Null
	}
Add-Result `
	-Name 'Out-of-scope rename source is rejected' `
	-Passed $OutOfScopeRenameFailure

$PatchValidatorSource = Get-Content -Raw -LiteralPath $PatchValidationScript
Add-Result `
	-Name 'Patch paths use binary-safe Git output capture' `
	-Passed (
		$PatchValidatorSource -match 'StandardOutput\.BaseStream\.CopyToAsync' -and
		$PatchValidatorSource -match '--numstat -z' -and
		$PatchValidatorSource -match 'core\.autocrlf=false' -and
		$PatchValidatorSource -notmatch '--recount'
	)

$BinaryFixtureRepository = Join-Path $TestRoot 'binary-fixture-repository'
New-Item -ItemType Directory -Path $BinaryFixtureRepository | Out-Null
$null = Invoke-TestGitBytes `
	-Arguments 'init --quiet' `
	-WorkingDirectory $BinaryFixtureRepository
$BinaryFixtureRelativePath = '.delivery-scope/generated-binary.dat'
$BinaryFixturePath = Join-Path $BinaryFixtureRepository $BinaryFixtureRelativePath
New-Item -ItemType Directory -Path (Split-Path -Parent $BinaryFixturePath) |
	Out-Null
[System.IO.File]::WriteAllBytes(
	$BinaryFixturePath,
	[byte[]]@(0, 1, 2, 3, 0, 127, 128, 254, 255, 13, 10)
)
$null = Invoke-TestGitBytes `
	-Arguments "-c core.autocrlf=false add -- $BinaryFixtureRelativePath" `
	-WorkingDirectory $BinaryFixtureRepository
$BinaryPatchBytes = Invoke-TestGitBytes `
	-Arguments '-c core.autocrlf=false diff --cached --binary --full-index --no-ext-diff' `
	-WorkingDirectory $BinaryFixtureRepository
$BinaryPatchPath = Join-Path $TestRoot 'accepted-binary.patch'
[System.IO.File]::WriteAllBytes($BinaryPatchPath, $BinaryPatchBytes)
$BinaryPatchManifestPath = Join-Path $TestRoot 'accepted-binary-evidence.json'
$BinaryPatchAccepted = $false
$BinaryPatchDetail = ''
try {
	$BinaryPatchValidation = & $PatchValidationScript `
		-PatchPath $BinaryPatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @($BinaryFixtureRelativePath)
	$BinaryPatchProtection = & $EvidenceProtectionScript `
		-EvidencePaths @($BinaryPatchPath) `
		-ManifestPath $BinaryPatchManifestPath `
		-HandoffHash ('c' * 64) `
		-Disposition 'accepted'
	$BinaryPatchEvidence = & $EvidenceValidationScript `
		-ManifestPath $BinaryPatchManifestPath `
		-ExpectedManifestHash $BinaryPatchProtection.ManifestHash `
		-ExpectedHandoffHash ('c' * 64)
	$BinaryPatchText = [System.Text.Encoding]::ASCII.GetString($BinaryPatchBytes)
	$BinaryPatchAccepted = (
		$BinaryPatchText -match 'GIT binary patch' -and
		@($BinaryPatchValidation.ProposedPaths).Count -eq 1 -and
		$BinaryPatchValidation.ProposedPaths[0] -eq $BinaryFixtureRelativePath -and
		$BinaryPatchEvidence.Disposition -eq 'accepted'
	)
}
catch {
	$BinaryPatchDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Accepted Git binary candidate remains routable' `
	-Passed $BinaryPatchAccepted `
	-Detail $BinaryPatchDetail

$BundleTextPath = '.delivery-scope/bundle-text.txt'
$BundleBinaryPath = '.delivery-scope/bundle-binary.dat'
$BundleTextContent = 'caf' + [char]0x00E9 + "`nno-final-newline"
$BundleBinaryBytes = [byte[]]@(0, 1, 2, 3, 0, 127, 128, 254, 255, 13, 10)
$MultiFileBundle = [pscustomobject]@{
	format = 'delivery_file_bundle_v1'
	files = @(
		[pscustomobject]@{
			path = $BundleTextPath
			operation = 'create'
			base_sha256 = $null
			encoding = 'utf8'
			content = $BundleTextContent
		},
		[pscustomobject]@{
			path = $BundleBinaryPath
			operation = 'create'
			base_sha256 = $null
			encoding = 'base64'
			content = [System.Convert]::ToBase64String($BundleBinaryBytes)
		}
	)
}
$MultiFileBundlePatchPath = Join-Path $TestRoot 'multi-file-bundle.patch'
$MultiFileBundleBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
$MultiFileBundleAccepted = $false
$MultiFileBundleDetail = ''
try {
	$MultiFileBundleConversion = & $BundleConversionScript `
		-Bundle $MultiFileBundle `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('.delivery-scope/**') `
		-DeclaredPaths @($BundleTextPath, $BundleBinaryPath) `
		-SnapshotFiles $MultiFileBundleBefore.Files `
		-PatchPath $MultiFileBundlePatchPath
	$MultiFileBundleValidation = & $PatchValidationScript `
		-PatchPath $MultiFileBundlePatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('.delivery-scope/**')
	$MultiFileBundlePatchBytes = [System.IO.File]::ReadAllBytes(
		$MultiFileBundlePatchPath
	)
	$MultiFileBundlePatchText = [System.Text.Encoding]::ASCII.GetString(
		$MultiFileBundlePatchBytes
	)
	$MultiFileBundleMaterialization = Join-Path (
		$TestRoot
	) 'multi-file-bundle-materialization'
	New-Item -ItemType Directory -Path $MultiFileBundleMaterialization | Out-Null
	$null = Invoke-TestGitBytes `
		-Arguments 'init --quiet' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$null = Invoke-TestGitBytes `
		-Arguments 'config core.autocrlf true' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$null = Invoke-TestGitBytes `
		-Arguments 'config filter.reviewevil.required true' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$null = Invoke-TestGitBytes `
		-Arguments 'config filter.reviewevil.smudge false' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$null = Invoke-TestGitBytes `
		-Arguments 'config filter.reviewevil.clean false' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$ExternalAttributesPath = Join-Path (
		$MultiFileBundleMaterialization
	) 'external-attributes'
	$ExternalConfigPath = Join-Path (
		$MultiFileBundleMaterialization
	) 'external-gitconfig'
	[System.IO.File]::WriteAllBytes(
		$ExternalAttributesPath,
		([System.Text.UTF8Encoding]::new($false)).GetBytes(
			"*.dat filter=externalfail`n"
		)
	)
	$ExternalAttributesGitPath = $ExternalAttributesPath.Replace('\', '/')
	[System.IO.File]::WriteAllBytes(
		$ExternalConfigPath,
		([System.Text.UTF8Encoding]::new($false)).GetBytes(
			"[core]`n" +
			"`tattributesFile = $ExternalAttributesGitPath`n" +
			"[filter `"externalfail`"]`n" +
			"`trequired = true`n" +
			"`tsmudge = false`n" +
			"`tclean = false`n"
		)
	)
	$MaterializationAttributesPath = Join-Path (
		$MultiFileBundleMaterialization
	) '.gitattributes'
	$MaterializationAttributesBytes = (
		[System.Text.UTF8Encoding]::new($false)
	).GetBytes(
		"*.txt text eol=crlf ident working-tree-encoding=UTF-16LE " +
		"filter=reviewevil`n"
	)
	[System.IO.File]::WriteAllBytes(
		$MaterializationAttributesPath,
		$MaterializationAttributesBytes
	)
	$null = Invoke-TestGitBytes `
		-Arguments 'add -- .gitattributes' `
		-WorkingDirectory $MultiFileBundleMaterialization
	$MaterializationConfigPath = Join-Path (
		$MultiFileBundleMaterialization
	) '.git/config'
	$MaterializationConfigBytesBefore = [System.IO.File]::ReadAllBytes(
		$MaterializationConfigPath
	)
	$MaterializationAttributesBytesBefore = [System.IO.File]::ReadAllBytes(
		$MaterializationAttributesPath
	)
	$ExternalConfigBytesBefore = [System.IO.File]::ReadAllBytes(
		$ExternalConfigPath
	)
	$ExternalAttributesBytesBefore = [System.IO.File]::ReadAllBytes(
		$ExternalAttributesPath
	)
	$OriginalGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
	$OriginalGitConfigSystem = $env:GIT_CONFIG_SYSTEM
	try {
		$env:GIT_CONFIG_GLOBAL = $ExternalConfigPath
		$env:GIT_CONFIG_SYSTEM = $ExternalConfigPath
		$MultiFileBundleApplication = & $PatchApplicationScript `
			-PatchPath $MultiFileBundlePatchPath `
			-WorkspaceRoot $MultiFileBundleMaterialization `
			-AllowedPaths @('.delivery-scope/**')
	}
	finally {
		$env:GIT_CONFIG_GLOBAL = $OriginalGitConfigGlobal
		$env:GIT_CONFIG_SYSTEM = $OriginalGitConfigSystem
	}
	$StoredAutoCrlf = (
		[System.Text.Encoding]::UTF8.GetString(
			(Invoke-TestGitBytes `
				-Arguments 'config --get core.autocrlf' `
				-WorkingDirectory $MultiFileBundleMaterialization)
		)
	).Trim()
	$MaterializedTextBytes = [System.IO.File]::ReadAllBytes(
		(Join-Path $MultiFileBundleMaterialization $BundleTextPath)
	)
	$MaterializedBinaryBytes = [System.IO.File]::ReadAllBytes(
		(Join-Path $MultiFileBundleMaterialization $BundleBinaryPath)
	)
	$MaterializationConfigBytesAfter = [System.IO.File]::ReadAllBytes(
		$MaterializationConfigPath
	)
	$MaterializationAttributesBytesAfter = [System.IO.File]::ReadAllBytes(
		$MaterializationAttributesPath
	)
	$ExternalConfigBytesAfter = [System.IO.File]::ReadAllBytes(
		$ExternalConfigPath
	)
	$ExternalAttributesBytesAfter = [System.IO.File]::ReadAllBytes(
		$ExternalAttributesPath
	)
	$TrackedAttributesPath = (
		[System.Text.Encoding]::UTF8.GetString(
			(Invoke-TestGitBytes `
				-Arguments 'ls-files -- .gitattributes' `
				-WorkingDirectory $MultiFileBundleMaterialization)
		)
	).Trim()
	$ExpectedTextBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
		$BundleTextContent
	)
	$MultiFileBundleAccepted = (
		$MultiFileBundleConversion.Format -eq 'delivery_file_bundle_v1' -and
		$MultiFileBundleConversion.FileCount -eq 2 -and
		@($MultiFileBundleValidation.ProposedPaths).Count -eq 2 -and
		@($MultiFileBundleValidation.ProposedPaths) -contains $BundleTextPath -and
		@($MultiFileBundleValidation.ProposedPaths) -contains $BundleBinaryPath -and
		$MultiFileBundlePatchText -match 'GIT binary patch' -and
		@($MultiFileBundleApplication.ProposedPaths).Count -eq 2 -and
		$StoredAutoCrlf -eq 'true' -and
		$TrackedAttributesPath -eq '.gitattributes' -and
		(Test-TestByteArrayEqual `
			$MaterializationConfigBytesBefore `
			$MaterializationConfigBytesAfter) -and
		(Test-TestByteArrayEqual `
			$MaterializationAttributesBytesBefore `
			$MaterializationAttributesBytesAfter) -and
		(Test-TestByteArrayEqual `
			$ExternalConfigBytesBefore `
			$ExternalConfigBytesAfter) -and
		(Test-TestByteArrayEqual `
			$ExternalAttributesBytesBefore `
			$ExternalAttributesBytesAfter) -and
		(Test-TestByteArrayEqual $MaterializedTextBytes $ExpectedTextBytes) -and
		(Test-TestByteArrayEqual $MaterializedBinaryBytes $BundleBinaryBytes) -and
		$MaterializedTextBytes[$MaterializedTextBytes.Length - 1] -ne 0x0A
	)
}
catch {
	$MultiFileBundleDetail = $_.Exception.Message
}
$MultiFileBundleAfter = & $SnapshotScript -RepositoryRoot $RepositoryRoot
Add-Result `
	-Name 'Multi-file Unicode and binary bundle generates a strict applicable patch' `
	-Passed (
		$MultiFileBundleAccepted -and
		$MultiFileBundleBefore.Hash -eq $MultiFileBundleAfter.Hash
	) `
	-Detail $MultiFileBundleDetail

$DuplicateBundleFile = [pscustomobject]@{
	path = '.delivery-scope/duplicate.txt'
	operation = 'create'
	base_sha256 = $null
	encoding = 'utf8'
	content = 'duplicate'
}
$ReadmePath = Join-Path $RepositoryRoot 'README.md'
$ReadmeBytes = [System.IO.File]::ReadAllBytes($ReadmePath)
$ReadmeSha256 = (
	Get-FileHash -LiteralPath $ReadmePath -Algorithm SHA256
).Hash.ToLowerInvariant()
$InvalidBundleCases = @(
	[pscustomobject]@{
		Name = 'Stale replacement base hash is rejected'
		Pattern = 'bundle_stale|stale'
		AllowedPaths = @('README.md')
		DeclaredPaths = @('README.md')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = 'README.md'
				operation = 'replace'
				base_sha256 = ('0' * 64)
				encoding = 'utf8'
				content = 'replacement'
			})
		}
	},
	[pscustomobject]@{
		Name = 'Replacement absent from source snapshot is rejected before access'
		Pattern = 'bundle_stale|not present in the source snapshot'
		AllowedPaths = @('README.md')
		DeclaredPaths = @('README.md')
		SnapshotFiles = @{}
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = 'README.md'
				operation = 'replace'
				base_sha256 = $ReadmeSha256
				encoding = 'base64'
				content = [System.Convert]::ToBase64String($ReadmeBytes)
			})
		}
	},
	[pscustomobject]@{
		Name = 'Unchanged replacement content is rejected'
		Pattern = 'bundle_empty|does not change content'
		AllowedPaths = @('README.md')
		DeclaredPaths = @('README.md')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = 'README.md'
				operation = 'replace'
				base_sha256 = $ReadmeSha256
				encoding = 'base64'
				content = [System.Convert]::ToBase64String($ReadmeBytes)
			})
		}
	},
	[pscustomobject]@{
		Name = 'Duplicate bundle paths are rejected'
		Pattern = 'bundle_path_unsafe|duplicated'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('.delivery-scope/duplicate.txt')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @($DuplicateBundleFile, $DuplicateBundleFile)
		}
	},
	[pscustomobject]@{
		Name = 'Bundle traversal path is rejected'
		Pattern = 'bundle_path_unsafe|unsafe'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('../escape.txt')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = '../escape.txt'
				operation = 'create'
				base_sha256 = $null
				encoding = 'utf8'
				content = 'escape'
			})
		}
	},
	[pscustomobject]@{
		Name = 'Sensitive replacement path is rejected before file access'
		Pattern = 'bundle_path_sensitive|is sensitive'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('.delivery-scope/.env')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = '.delivery-scope/.env'
				operation = 'replace'
				base_sha256 = ('0' * 64)
				encoding = 'utf8'
				content = 'placeholder'
			})
		}
	},
	[pscustomobject]@{
		Name = 'Out-of-scope bundle path is rejected'
		Pattern = 'bundle_out_of_scope|outside allowed paths'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('README.md')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = 'README.md'
				operation = 'replace'
				base_sha256 = ('0' * 64)
				encoding = 'utf8'
				content = 'replacement'
			})
		}
	},
	[pscustomobject]@{
		Name = 'Bundle and declared changed paths must exactly match'
		Pattern = 'bundle_invalid|exactly match'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('.delivery-scope/other.txt')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = '.delivery-scope/declared.txt'
				operation = 'create'
				base_sha256 = $null
				encoding = 'utf8'
				content = 'declared'
			})
		}
	},
	[pscustomobject]@{
		Name = 'Bundle objects reject undeclared properties'
		Pattern = 'bundle_invalid|only the required properties'
		AllowedPaths = @('.delivery-scope/**')
		DeclaredPaths = @('.delivery-scope/extra.txt')
		Bundle = [pscustomobject]@{
			format = 'delivery_file_bundle_v1'
			files = @([pscustomobject]@{
				path = '.delivery-scope/extra.txt'
				operation = 'create'
				base_sha256 = $null
				encoding = 'utf8'
				content = 'extra'
				unexpected = 'rejected'
			})
		}
	}
)
$InvalidBundleSnapshotBefore = & $SnapshotScript -RepositoryRoot $RepositoryRoot
for ($InvalidBundleIndex = 0; $InvalidBundleIndex -lt $InvalidBundleCases.Count;
	$InvalidBundleIndex++) {
	$InvalidBundleCase = $InvalidBundleCases[$InvalidBundleIndex]
	$InvalidBundlePatchPath = Join-Path (
		$TestRoot
	) "invalid-bundle-$InvalidBundleIndex.patch"
	$InvalidBundleSnapshotFiles = if (
		$null -ne $InvalidBundleCase.PSObject.Properties['SnapshotFiles']
	) {
		[hashtable]$InvalidBundleCase.SnapshotFiles
	}
	else {
		[hashtable]$InvalidBundleSnapshotBefore.Files
	}
	$InvalidBundleRejected = Invoke-ExpectedFailure `
		-Pattern $InvalidBundleCase.Pattern `
		-Action {
			& $BundleConversionScript `
				-Bundle $InvalidBundleCase.Bundle `
				-WorkspaceRoot $RepositoryRoot `
				-AllowedPaths ([string[]]$InvalidBundleCase.AllowedPaths) `
				-DeclaredPaths ([string[]]$InvalidBundleCase.DeclaredPaths) `
				-SnapshotFiles $InvalidBundleSnapshotFiles `
				-PatchPath $InvalidBundlePatchPath | Out-Null
		}
	Add-Result `
		-Name $InvalidBundleCase.Name `
		-Passed (
			$InvalidBundleRejected -and
			-not (Test-Path -LiteralPath $InvalidBundlePatchPath)
		)
}
$InvalidBundleSnapshotAfter = & $SnapshotScript -RepositoryRoot $RepositoryRoot
Add-Result `
	-Name 'Rejected bundles preserve the repository snapshot' `
	-Passed ($InvalidBundleSnapshotBefore.Hash -eq $InvalidBundleSnapshotAfter.Hash)

$MalformedMultiFilePatchPath = Join-Path $TestRoot 'malformed-multi-file.patch'
@'
diff --git a/.delivery-scope/first.txt b/.delivery-scope/first.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/first.txt
@@ -0,0 +1,2 @@
+first
diff --git a/.delivery-scope/second.txt b/.delivery-scope/second.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/second.txt
@@ -0,0 +1 @@
+second
'@ | Set-Content -LiteralPath $MalformedMultiFilePatchPath -Encoding UTF8
$MalformedMultiFileFailure = Invoke-ExpectedFailure `
	-Pattern 'not a valid Git patch|corrupt patch' `
	-Action {
		& $PatchValidationScript `
			-PatchPath $MalformedMultiFilePatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @('.delivery-scope/**') | Out-Null
	}
Add-Result `
	-Name 'Malformed multi-file hunk metadata is never recounted into validity' `
	-Passed $MalformedMultiFileFailure

$ValidMultiFilePatchPath = Join-Path $TestRoot 'valid-multi-file.patch'
@'
diff --git a/.delivery-scope/first.txt b/.delivery-scope/first.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/first.txt
@@ -0,0 +1 @@
+first
diff --git a/.delivery-scope/second.txt b/.delivery-scope/second.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/second.txt
@@ -0,0 +1 @@
+second
'@ | Set-Content -LiteralPath $ValidMultiFilePatchPath -Encoding UTF8
$ValidMultiFileAccepted = $false
$ValidMultiFileDetail = ''
try {
	$ValidMultiFileValidation = & $PatchValidationScript `
		-PatchPath $ValidMultiFilePatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('.delivery-scope/**')
	$ValidMultiFileAccepted = (
		@($ValidMultiFileValidation.ProposedPaths).Count -eq 2 -and
		$ValidMultiFileValidation.ProposedPaths[0] -eq '.delivery-scope/first.txt' -and
		$ValidMultiFileValidation.ProposedPaths[1] -eq '.delivery-scope/second.txt'
	)
}
catch {
	$ValidMultiFileDetail = $_.Exception.Message
}
Add-Result `
	-Name 'Valid multi-file text candidate remains routable' `
	-Passed $ValidMultiFileAccepted `
	-Detail $ValidMultiFileDetail

$WildcardPatchPath = Join-Path $TestRoot 'wildcard-scope.patch'
@'
diff --git a/.delivery-scope/child/file.txt b/.delivery-scope/child/file.txt
new file mode 100644
--- /dev/null
+++ b/.delivery-scope/child/file.txt
@@ -0,0 +1 @@
+fixture
'@ | Set-Content -LiteralPath $WildcardPatchPath -Encoding UTF8

$AllowedScopeCases = @(
	@('.delivery-scope/child/file.txt', 'exact'),
	@('.delivery-scope', 'directory'),
	@('.delivery-scope/*/file.txt', 'single wildcard'),
	@('.delivery-scope/**', 'recursive wildcard')
)
foreach ($ScopeCase in $AllowedScopeCases) {
	try {
		& $PatchValidationScript `
			-PatchPath $WildcardPatchPath `
			-WorkspaceRoot $RepositoryRoot `
			-AllowedPaths @($ScopeCase[0]) | Out-Null
		$ScopePassed = $true
	}
	catch {
		$ScopePassed = $false
	}
	Add-Result `
		-Name "Safe $($ScopeCase[1]) scope is accepted" `
		-Passed $ScopePassed
}

$SingleWildcardFailure = Invoke-ExpectedFailure -Pattern 'outside allowed paths' -Action {
	& $PatchValidationScript `
		-PatchPath $WildcardPatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @('.delivery-scope/*') | Out-Null
}
Add-Result `
	-Name 'Single wildcard does not cross directories' `
	-Passed $SingleWildcardFailure

$UnsafeAllowedScopes = @(
	@('../.delivery-scope/**', 'traversal'),
	@((Join-Path $RepositoryRoot '.delivery-scope'), 'absolute'),
	@('.delivery-scope/*.txt', 'partial wildcard'),
	@('.delivery-scope/***', 'unsupported wildcard')
)
foreach ($ScopeCase in $UnsafeAllowedScopes) {
	$UnsafeScopeFailure = Invoke-ExpectedFailure `
		-Pattern 'unsafe|unsupported wildcard' `
		-Action {
			& $PatchValidationScript `
				-PatchPath $WildcardPatchPath `
				-WorkspaceRoot $RepositoryRoot `
				-AllowedPaths @($ScopeCase[0]) | Out-Null
		}
	Add-Result `
		-Name "Unsafe $($ScopeCase[1]) scope is rejected" `
		-Passed $UnsafeScopeFailure
}

$SafeFirstUnsafeSecondFailure = Invoke-ExpectedFailure -Pattern 'unsafe' -Action {
	& $PatchValidationScript `
		-PatchPath $WildcardPatchPath `
		-WorkspaceRoot $RepositoryRoot `
		-AllowedPaths @(
			'.delivery-scope/**',
			'../.delivery-scope/**'
		) | Out-Null
}
Add-Result `
	-Name 'Unsafe later scope is rejected after an earlier matching scope' `
	-Passed $SafeFirstUnsafeSecondFailure

$CompleteEventPath = Join-Path $TestRoot 'complete-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-123","extra":"ignored"}
{"type":"item.completed","item":{"type":"agent_message","text":"private payload"}}
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":4,"output_tokens":25,"reasoning_output_tokens":5},"extra":"ignored"}
'@ | Set-Content -LiteralPath $CompleteEventPath -Encoding UTF8
$CompleteTelemetry = & $EventTelemetryScript -EventLogPath $CompleteEventPath
Add-Result `
	-Name 'Complete event telemetry is parsed from observed values' `
	-Passed (
		$CompleteTelemetry.SessionId -eq 'session-123' -and
		$CompleteTelemetry.InputTokens -eq 100 -and
		$CompleteTelemetry.CachedInputTokens -eq 60 -and
		$CompleteTelemetry.CacheWriteInputTokens -eq 4 -and
		$CompleteTelemetry.OutputTokens -eq 25 -and
		$CompleteTelemetry.ReasoningOutputTokens -eq 5 -and
		$CompleteTelemetry.TotalTokens -eq 125 -and
		$null -eq $CompleteTelemetry.Model -and
		$null -eq $CompleteTelemetry.ReasoningTier
	)

$MissingUsagePath = Join-Path $TestRoot 'missing-usage-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-missing"}
{"type":"turn.completed"}
'@ | Set-Content -LiteralPath $MissingUsagePath -Encoding UTF8
$MissingTelemetry = & $EventTelemetryScript -EventLogPath $MissingUsagePath
Add-Result `
	-Name 'Missing usage remains null' `
	-Passed (
		$MissingTelemetry.SessionId -eq 'session-missing' -and
		$null -eq $MissingTelemetry.InputTokens -and
		$null -eq $MissingTelemetry.CachedInputTokens -and
		$null -eq $MissingTelemetry.CacheWriteInputTokens -and
		$null -eq $MissingTelemetry.OutputTokens -and
		$null -eq $MissingTelemetry.ReasoningOutputTokens -and
		$null -eq $MissingTelemetry.TotalTokens
	)

$LastTurnPath = Join-Path $TestRoot 'last-turn-events.jsonl'
@'
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}
'@ | Set-Content -LiteralPath $LastTurnPath -Encoding UTF8
$LastTurnTelemetry = & $EventTelemetryScript -EventLogPath $LastTurnPath
Add-Result `
	-Name 'Last completed turn usage wins' `
	-Passed (
		$LastTurnTelemetry.InputTokens -eq 10 -and
		$LastTurnTelemetry.OutputTokens -eq 20 -and
		$LastTurnTelemetry.TotalTokens -eq 30
	)

$MalformedEventPath = Join-Path $TestRoot 'malformed-events.jsonl'
'{"type":"thread.started"' | Set-Content -LiteralPath $MalformedEventPath -Encoding UTF8
$MalformedEventFailure = Invoke-ExpectedFailure -Pattern 'not valid JSON' -Action {
	& $EventTelemetryScript -EventLogPath $MalformedEventPath | Out-Null
}
Add-Result -Name 'Malformed JSON event is rejected' -Passed $MalformedEventFailure

$ConflictingThreadPath = Join-Path $TestRoot 'conflicting-thread-events.jsonl'
@'
{"type":"thread.started","thread_id":"session-one"}
{"type":"thread.started","thread_id":"session-two"}
'@ | Set-Content -LiteralPath $ConflictingThreadPath -Encoding UTF8
$ConflictingThreadFailure = Invoke-ExpectedFailure -Pattern 'conflicting nonempty thread IDs' -Action {
	& $EventTelemetryScript -EventLogPath $ConflictingThreadPath | Out-Null
}
Add-Result `
	-Name 'Conflicting thread IDs are rejected' `
	-Passed $ConflictingThreadFailure

$InvalidTokenCases = @(
	@('negative', '-1'),
	@('non-integral', '1.5')
)
foreach ($InvalidTokenCase in $InvalidTokenCases) {
	$InvalidTokenPath = Join-Path $TestRoot "$($InvalidTokenCase[0])-token-events.jsonl"
	("{`"type`":`"turn.completed`",`"usage`":{`"input_tokens`":$($InvalidTokenCase[1])}}") |
		Set-Content -LiteralPath $InvalidTokenPath -Encoding UTF8
	$InvalidTokenFailure = Invoke-ExpectedFailure `
		-Pattern 'token observations must be non-negative integers' `
		-Action {
			& $EventTelemetryScript -EventLogPath $InvalidTokenPath | Out-Null
		}
	Add-Result `
		-Name "$($InvalidTokenCase[0]) token observation is rejected" `
		-Passed $InvalidTokenFailure
}

$WrongTypeCases = @(
	@('event type', '{"type":42}', "invalid 'type'"),
	@('thread ID', '{"type":"thread.started","thread_id":42}', "invalid 'thread_id'"),
	@('usage', '{"type":"turn.completed","usage":[]}', "invalid 'usage'"),
	@('token', '{"type":"turn.completed","usage":{"output_tokens":"25"}}', "non-numeric 'output_tokens'")
)
foreach ($WrongTypeCase in $WrongTypeCases) {
	$WrongTypePath = Join-Path $TestRoot (
		'wrong-' + ($WrongTypeCase[0] -replace ' ', '-') + '-events.jsonl'
	)
	$WrongTypeCase[1] | Set-Content -LiteralPath $WrongTypePath -Encoding UTF8
	$WrongTypeFailure = Invoke-ExpectedFailure -Pattern $WrongTypeCase[2] -Action {
		& $EventTelemetryScript -EventLogPath $WrongTypePath | Out-Null
	}
	Add-Result `
		-Name "Wrong $($WrongTypeCase[0]) type is rejected" `
		-Passed $WrongTypeFailure
}

$LeakingEventPath = Join-Path $TestRoot 'payload-leak-events.jsonl'
@'
{"type":"item.started","item":{"type":"command_execution","command":"do-not-expose-command"}}
{"type":"item.completed","item":{"type":"agent_message","text":"do-not-expose-message"}}
'@ | Set-Content -LiteralPath $LeakingEventPath -Encoding UTF8
$LeakingTelemetryJson = & $EventTelemetryScript -EventLogPath $LeakingEventPath |
	ConvertTo-Json -Compress
Add-Result `
	-Name 'Event payload text is not exposed' `
	-Passed (
		$LeakingTelemetryJson -notmatch 'do-not-expose-command' -and
		$LeakingTelemetryJson -notmatch 'do-not-expose-message' -and
		$LeakingTelemetryJson -match 'no_tool_call'
	)

$ArgumentFailureEventPath = Join-Path $TestRoot 'source-argument-failure-events.jsonl'
@'
{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":0,"limit_bytes":2048},"status":"in_progress"}}
{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":0,"limit_bytes":2048},"result":null,"error":{"message":"do-not-retain-invalid-argument"},"status":"failed"}}
'@ | Set-Content -LiteralPath $ArgumentFailureEventPath -Encoding UTF8
$ArgumentFailureTelemetry = & $EventTelemetryScript -EventLogPath $ArgumentFailureEventPath
Add-Result `
	-Name 'Source inspection argument failures are classified without payload leakage' `
	-Passed (
		$ArgumentFailureTelemetry.SourceInspection.Outcome -ceq 'argument_validation_failed' -and
		$ArgumentFailureTelemetry.SourceInspection.CallCount -eq 1 -and
		((& $EventTelemetryScript -EventLogPath $ArgumentFailureEventPath |
			ConvertTo-Json -Compress) -notmatch 'do-not-retain-invalid-argument')
	)

foreach ($OutOfRangeOffset in @(
	'9223372036854775808',
	'-9223372036854775809'
)) {
	$OutOfRangeOffsetEventPath = Join-Path $TestRoot (
		'source-offset-int64-range-{0}-events.jsonl' -f
		($OutOfRangeOffset -replace '-', 'negative-')
	)
	$OutOfRangeOffsetEvents = @'
{"type":"item.started","item":{"id":"range-call","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":__OFFSET__},"status":"in_progress"}}
{"type":"item.completed","item":{"id":"range-call","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":__OFFSET__},"result":null,"error":{"message":"do-not-retain-range-error"},"status":"failed"}}
'@ -replace '__OFFSET__', $OutOfRangeOffset
	$OutOfRangeOffsetEvents | Set-Content `
		-LiteralPath $OutOfRangeOffsetEventPath -Encoding UTF8
	$OutOfRangeOffsetTelemetry = & $EventTelemetryScript `
		-EventLogPath $OutOfRangeOffsetEventPath
	Add-Result `
		-Name "Out-of-Int64 source offset $OutOfRangeOffset is classified safely" `
		-Passed (
			$OutOfRangeOffsetTelemetry.SourceInspection.Outcome -ceq
				'argument_validation_failed' -and
			((& $EventTelemetryScript -EventLogPath $OutOfRangeOffsetEventPath |
				ConvertTo-Json -Compress) -notmatch 'do-not-retain-range-error')
		)
}

foreach ($OffsetFailureCode in @(
	'source_offset_out_of_range',
	'source_offset_utf8_boundary'
)) {
	$OffsetFailureEventPath = Join-Path $TestRoot "$OffsetFailureCode-events.jsonl"
	$OffsetFailureEvents = @(
		[ordered]@{
			type = 'item.started'
			item = [ordered]@{
				id = $OffsetFailureCode
				type = 'mcp_tool_call'
				server = 'source_inspection'
				tool = 'read_allowed_source_file'
				arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = 0 }
				status = 'in_progress'
			}
		}
		[ordered]@{
			type = 'item.completed'
			item = [ordered]@{
				id = $OffsetFailureCode
				type = 'mcp_tool_call'
				server = 'source_inspection'
				tool = 'read_allowed_source_file'
				arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = 0 }
				result = [ordered]@{
					content = @([ordered]@{
						type = 'text'
						text = "[$OffsetFailureCode] do-not-retain-offset-message"
					})
					isError = $true
				}
				error = $null
				status = 'completed'
			}
		}
	) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
	$OffsetFailureEvents | Set-Content -LiteralPath $OffsetFailureEventPath -Encoding UTF8
	$OffsetFailureTelemetry = & $EventTelemetryScript -EventLogPath $OffsetFailureEventPath
	Add-Result `
		-Name "$OffsetFailureCode is classified as an argument validation failure" `
		-Passed (
			$OffsetFailureTelemetry.SourceInspection.Outcome -ceq 'argument_validation_failed' -and
			((& $EventTelemetryScript -EventLogPath $OffsetFailureEventPath |
				ConvertTo-Json -Compress) -notmatch 'do-not-retain-offset-message')
		)
}

function New-TestSourcePageEventJson {
	param(
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$Encoding,
		[Parameter(Mandatory)][string]$Content,
		[Parameter(Mandatory)][string]$BaseSha256,
		[Parameter(Mandatory)][int64]$OffsetBytes,
		[Parameter(Mandatory)][int64]$ContentBytes,
		[Parameter(Mandatory)][int64]$EndOffsetBytes,
		[Parameter(Mandatory)][int64]$FileSizeBytes,
		[Parameter(Mandatory)][bool]$Eof
	)

	$Page = [ordered]@{
		path = $Path
		encoding = $Encoding
		content = $Content
		base_sha256 = $BaseSha256
		offset_bytes = $OffsetBytes
		content_bytes = $ContentBytes
		end_offset_bytes = $EndOffsetBytes
		file_size_bytes = $FileSizeBytes
		eof = $Eof
	}
	$PageText = $Page | ConvertTo-Json -Compress
	$StartedEvent = [ordered]@{
		type = 'item.started'
		item = [ordered]@{
			id = $Id
			type = 'mcp_tool_call'
			server = 'source_inspection'
			tool = 'read_allowed_source_file'
			arguments = [ordered]@{ path = $Path; offset_bytes = $OffsetBytes }
			status = 'in_progress'
		}
	} | ConvertTo-Json -Depth 8 -Compress
	$CompletedEvent = [ordered]@{
		type = 'item.completed'
		item = [ordered]@{
			id = $Id
			type = 'mcp_tool_call'
			server = 'source_inspection'
			tool = 'read_allowed_source_file'
			arguments = [ordered]@{ path = $Path; offset_bytes = $OffsetBytes }
			result = [ordered]@{
				content = @([ordered]@{ type = 'text'; text = $PageText })
				structured_content = $Page
				isError = $false
			}
			error = $null
			status = 'completed'
		}
	} | ConvertTo-Json -Depth 8 -Compress
	return @($StartedEvent, $CompletedEvent)
}

$IncompletePaginationEventPath = Join-Path $TestRoot 'source-incomplete-pagination-events.jsonl'
@(
	New-TestSourcePageEventJson -Id 'page-1' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'abcd' `
		-BaseSha256 '72399361da6a7754fec986dca5b7cbaf1c810a28ded4abaf56b2106d06cb78b0' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 10 -Eof $false
	New-TestSourcePageEventJson -Id 'page-2' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'efgh' `
		-BaseSha256 '72399361da6a7754fec986dca5b7cbaf1c810a28ded4abaf56b2106d06cb78b0' `
		-OffsetBytes 4 -ContentBytes 4 -EndOffsetBytes 8 -FileSizeBytes 10 -Eof $false
) | Set-Content -LiteralPath $IncompletePaginationEventPath -Encoding UTF8
$IncompletePaginationTelemetry = & $EventTelemetryScript -EventLogPath $IncompletePaginationEventPath
Add-Result `
	-Name 'Incomplete source pagination is classified from contiguous metadata' `
	-Passed (
		$IncompletePaginationTelemetry.SourceInspection.Outcome -ceq 'incomplete_pagination' -and
		$IncompletePaginationTelemetry.SourceInspection.CallCount -eq 2 -and
		$IncompletePaginationTelemetry.SourceInspection.CompletedPageCount -eq 2 -and
		$IncompletePaginationTelemetry.SourceInspection.CompletedPathCount -eq 0
	)

$CompletePaginationEventPath = Join-Path $TestRoot 'source-complete-pagination-events.jsonl'
New-TestSourcePageEventJson -Id 'page-complete' -Path 'AGENTS.md' -Encoding 'utf8' `
	-Content 'data' `
	-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
	-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true |
	Set-Content -LiteralPath $CompletePaginationEventPath -Encoding UTF8
$CompletePaginationTelemetry = & $EventTelemetryScript -EventLogPath $CompletePaginationEventPath
Add-Result `
	-Name 'Complete source pagination is classified at exact EOF' `
	-Passed (
		$CompletePaginationTelemetry.SourceInspection.Outcome -ceq 'complete_pagination' -and
		$CompletePaginationTelemetry.SourceInspection.CompletedPageCount -eq 1 -and
		$CompletePaginationTelemetry.SourceInspection.CompletedPathCount -eq 1
	)

$HtmlSensitiveContent = "<&>'+"
$HtmlSensitiveBytes = [Text.Encoding]::UTF8.GetBytes($HtmlSensitiveContent)
$HtmlSensitiveHash = [BitConverter]::ToString(
	([Security.Cryptography.SHA256]::Create()).ComputeHash($HtmlSensitiveBytes)
).Replace('-', '').ToLowerInvariant()
$HtmlSensitiveEvents = @(
	New-TestSourcePageEventJson -Id 'html-sensitive' -Path 'Symbols.txt' -Encoding 'utf8' `
		-Content $HtmlSensitiveContent -BaseSha256 $HtmlSensitiveHash `
		-OffsetBytes 0 -ContentBytes 5 -EndOffsetBytes 5 -FileSizeBytes 5 -Eof $true
)
$HtmlSensitiveCompletion = $HtmlSensitiveEvents[1] | ConvertFrom-Json
$HtmlSensitiveCompletion.item.result.content[0].text = (
	'{"path":"Symbols.txt","encoding":"utf8","content":"<&>''+",' +
	'"base_sha256":"' + $HtmlSensitiveHash + '","offset_bytes":0,' +
	'"content_bytes":5,"end_offset_bytes":5,"file_size_bytes":5,"eof":true}'
)
$HtmlSensitiveEventPath = Join-Path $TestRoot 'source-html-sensitive-events.jsonl'
@(
	$HtmlSensitiveEvents[0]
	$HtmlSensitiveCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $HtmlSensitiveEventPath -Encoding UTF8
$HtmlSensitiveTelemetry = & $EventTelemetryScript -EventLogPath $HtmlSensitiveEventPath
Add-Result `
	-Name 'Canonical source text is stable across PowerShell runtimes' `
	-Passed ($HtmlSensitiveTelemetry.SourceInspection.Outcome -ceq 'complete_pagination')

$EscapedHtmlCompletion = $HtmlSensitiveCompletion |
	ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
$EscapedHtmlCompletion.item.result.content[0].text = (
	[string]$EscapedHtmlCompletion.item.result.content[0].text
).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026').Replace("'", '\u0027').Replace('+', '\u002b')
$EscapedHtmlEventPath = Join-Path $TestRoot 'source-escaped-html-events.jsonl'
@(
	$HtmlSensitiveEvents[0]
	$EscapedHtmlCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $EscapedHtmlEventPath -Encoding UTF8
$EscapedHtmlTelemetry = & $EventTelemetryScript -EventLogPath $EscapedHtmlEventPath
Add-Result `
	-Name 'Runtime-specific escaped source text is noncanonical' `
	-Passed ($EscapedHtmlTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$CorrelatedPageEvents = @(
	New-TestSourcePageEventJson -Id 'correlation' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$OrphanCompletionEventPath = Join-Path $TestRoot 'source-orphan-completion-events.jsonl'
$CorrelatedPageEvents[1] | Set-Content -LiteralPath $OrphanCompletionEventPath -Encoding UTF8
$OrphanCompletionTelemetry = & $EventTelemetryScript -EventLogPath $OrphanCompletionEventPath
Add-Result `
	-Name 'Source completion without a start is protocol rejection' `
	-Passed ($OrphanCompletionTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$ReversedSourceEventPath = Join-Path $TestRoot 'source-completion-before-start-events.jsonl'
@($CorrelatedPageEvents[1], $CorrelatedPageEvents[0]) |
	Set-Content -LiteralPath $ReversedSourceEventPath -Encoding UTF8
$ReversedSourceTelemetry = & $EventTelemetryScript -EventLogPath $ReversedSourceEventPath
Add-Result `
	-Name 'Source completion before its start is protocol rejection' `
	-Passed ($ReversedSourceTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$MismatchedStart = $CorrelatedPageEvents[0] | ConvertFrom-Json
$MismatchedStart.item.arguments.path = 'agents.md'
$MismatchedSourceEventPath = Join-Path $TestRoot 'source-mismatched-call-events.jsonl'
@(
	$MismatchedStart | ConvertTo-Json -Depth 8 -Compress
	$CorrelatedPageEvents[1]
) | Set-Content -LiteralPath $MismatchedSourceEventPath -Encoding UTF8
$MismatchedSourceTelemetry = & $EventTelemetryScript -EventLogPath $MismatchedSourceEventPath
Add-Result `
	-Name 'Source start and completion arguments must match exactly' `
	-Passed ($MismatchedSourceTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$CaseVariantIdentityEvents = @(
	New-TestSourcePageEventJson -Id 'case-identity' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$CaseVariantIdentityStart = $CaseVariantIdentityEvents[0] | ConvertFrom-Json
$CaseVariantIdentityCompletion = $CaseVariantIdentityEvents[1] | ConvertFrom-Json
foreach ($IdentityEvent in @($CaseVariantIdentityStart, $CaseVariantIdentityCompletion)) {
	$IdentityEvent.item.server = 'Source_Inspection'
	$IdentityEvent.item.tool = 'Read_Allowed_Source_File'
}
$CaseVariantIdentityEventPath = Join-Path $TestRoot 'source-case-identity-events.jsonl'
@(
	$CaseVariantIdentityStart | ConvertTo-Json -Depth 8 -Compress
	$CaseVariantIdentityCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $CaseVariantIdentityEventPath -Encoding UTF8
$CaseVariantIdentityTelemetry = & $EventTelemetryScript `
	-EventLogPath $CaseVariantIdentityEventPath
Add-Result `
	-Name 'Source server and tool identities are case-sensitive' `
	-Passed (
		$CaseVariantIdentityTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected' -and
		$CaseVariantIdentityTelemetry.SourceInspection.CallCount -eq 1
	)

$ContradictoryStartedEvents = @(
	New-TestSourcePageEventJson -Id 'contradictory-start' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$ContradictoryStarted = $ContradictoryStartedEvents[0] | ConvertFrom-Json
$ContradictoryStarted.item.status = 'completed'
$ContradictoryStartedEventPath = Join-Path $TestRoot 'source-contradictory-start-events.jsonl'
@(
	$ContradictoryStarted | ConvertTo-Json -Depth 8 -Compress
	$ContradictoryStartedEvents[1]
) | Set-Content -LiteralPath $ContradictoryStartedEventPath -Encoding UTF8
$ContradictoryStartedTelemetry = & $EventTelemetryScript `
	-EventLogPath $ContradictoryStartedEventPath
Add-Result `
	-Name 'Source start requires the canonical in-progress envelope' `
	-Passed ($ContradictoryStartedTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$PopulatedStartedEvents = @(
	New-TestSourcePageEventJson -Id 'populated-start' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$PopulatedStarted = $PopulatedStartedEvents[0] | ConvertFrom-Json
$PopulatedStarted.item | Add-Member -NotePropertyName result -NotePropertyValue ([ordered]@{ value = 1 })
$PopulatedStarted.item | Add-Member -NotePropertyName error -NotePropertyValue ([ordered]@{ code = 'bad' })
$PopulatedStartedEventPath = Join-Path $TestRoot 'source-populated-start-events.jsonl'
@(
	$PopulatedStarted | ConvertTo-Json -Depth 8 -Compress
	$PopulatedStartedEvents[1]
) | Set-Content -LiteralPath $PopulatedStartedEventPath -Encoding UTF8
$PopulatedStartedTelemetry = & $EventTelemetryScript -EventLogPath $PopulatedStartedEventPath
Add-Result `
	-Name 'Source start rejects populated result and error fields' `
	-Passed ($PopulatedStartedTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$DualStructuredEvents = @(
	New-TestSourcePageEventJson -Id 'dual-structured' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$DualStructuredCompletion = $DualStructuredEvents[1] | ConvertFrom-Json
$ConflictingStructured = $DualStructuredCompletion.item.result.structured_content |
	ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json
$ConflictingStructured.content = 'different'
$DualStructuredCompletion.item.result | Add-Member `
	-NotePropertyName structuredContent -NotePropertyValue $ConflictingStructured
$DualStructuredEventPath = Join-Path $TestRoot 'source-dual-structured-events.jsonl'
@(
	$DualStructuredEvents[0]
	$DualStructuredCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $DualStructuredEventPath -Encoding UTF8
$DualStructuredTelemetry = & $EventTelemetryScript -EventLogPath $DualStructuredEventPath
Add-Result `
	-Name 'Source completion rejects dual structured-result aliases' `
	-Passed ($DualStructuredTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$DualErrorEvents = @(
	New-TestSourcePageEventJson -Id 'dual-error' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$DualErrorCompletion = $DualErrorEvents[1] | ConvertFrom-Json
$DualErrorCompletion.item.result | Add-Member -NotePropertyName is_error -NotePropertyValue $false
$DualErrorEventPath = Join-Path $TestRoot 'source-dual-error-events.jsonl'
@(
	$DualErrorEvents[0]
	$DualErrorCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $DualErrorEventPath -Encoding UTF8
$DualErrorTelemetry = & $EventTelemetryScript -EventLogPath $DualErrorEventPath
Add-Result `
	-Name 'Source completion rejects dual tool-error aliases' `
	-Passed ($DualErrorTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$NonBooleanErrorEvents = @(
	New-TestSourcePageEventJson -Id 'nonboolean-error' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$NonBooleanErrorCompletion = $NonBooleanErrorEvents[1] | ConvertFrom-Json
$NonBooleanErrorCompletion.item.result.isError = 'false'
$NonBooleanErrorEventPath = Join-Path $TestRoot 'source-nonboolean-error-events.jsonl'
@(
	$NonBooleanErrorEvents[0]
	$NonBooleanErrorCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $NonBooleanErrorEventPath -Encoding UTF8
$NonBooleanErrorTelemetry = & $EventTelemetryScript -EventLogPath $NonBooleanErrorEventPath
Add-Result `
	-Name 'Source completion rejects non-boolean tool-error state' `
	-Passed ($NonBooleanErrorTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$CaseVariantEnvelopeEvents = @(
	New-TestSourcePageEventJson -Id 'case-envelope' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$CaseVariantEnvelopeStart = $CaseVariantEnvelopeEvents[0] | ConvertFrom-Json
$CaseVariantEnvelopeCompletion = $CaseVariantEnvelopeEvents[1] | ConvertFrom-Json
$CaseVariantEnvelopeStart.type = 'Item.Started'
$CaseVariantEnvelopeCompletion.type = 'Item.Completed'
$CaseVariantEnvelopeStart.item.type = 'MCP_Tool_Call'
$CaseVariantEnvelopeCompletion.item.type = 'MCP_Tool_Call'
$CaseVariantEnvelopeEventPath = Join-Path $TestRoot 'source-case-envelope-events.jsonl'
@(
	$CaseVariantEnvelopeStart | ConvertTo-Json -Depth 8 -Compress
	$CaseVariantEnvelopeCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $CaseVariantEnvelopeEventPath -Encoding UTF8
$CaseVariantEnvelopeTelemetry = & $EventTelemetryScript -EventLogPath $CaseVariantEnvelopeEventPath
Add-Result `
	-Name 'Source event and item envelope identities are case-sensitive' `
	-Passed ($CaseVariantEnvelopeTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$FirstOverlappingPage = @(
	New-TestSourcePageEventJson -Id 'overlap-1' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'abcd' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 8 -Eof $false
)
$SecondOverlappingPage = @(
	New-TestSourcePageEventJson -Id 'overlap-2' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'efgh' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 4 -ContentBytes 4 -EndOffsetBytes 8 -FileSizeBytes 8 -Eof $true
)
$OverlappingSourceEventPath = Join-Path $TestRoot 'source-overlapping-call-events.jsonl'
@(
	$FirstOverlappingPage[0]
	$SecondOverlappingPage[0]
	$FirstOverlappingPage[1]
	$SecondOverlappingPage[1]
) | Set-Content -LiteralPath $OverlappingSourceEventPath -Encoding UTF8
$OverlappingSourceTelemetry = & $EventTelemetryScript -EventLogPath $OverlappingSourceEventPath
Add-Result `
	-Name 'Same-path source calls cannot overlap before continuation metadata exists' `
	-Passed ($OverlappingSourceTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$NoncanonicalTextEvents = @(
	New-TestSourcePageEventJson -Id 'noncanonical-text' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'data' `
		-BaseSha256 '3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 4 -Eof $true
)
$NoncanonicalCompletion = $NoncanonicalTextEvents[1] | ConvertFrom-Json
$NoncanonicalCompletion.item.result.content[0].text = (
	' ' + [string]$NoncanonicalCompletion.item.result.content[0].text
)
$NoncanonicalTextEventPath = Join-Path $TestRoot 'source-noncanonical-text-events.jsonl'
@(
	$NoncanonicalTextEvents[0]
	$NoncanonicalCompletion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $NoncanonicalTextEventPath -Encoding UTF8
$NoncanonicalTextTelemetry = & $EventTelemetryScript -EventLogPath $NoncanonicalTextEventPath
Add-Result `
	-Name 'Source text result must equal canonical structured serialization' `
	-Passed ($NoncanonicalTextTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$ProtocolFailureEventPath = Join-Path $TestRoot 'source-protocol-failure-events.jsonl'
@(
	New-TestSourcePageEventJson -Id 'gap-1' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'abcd' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 8 -Eof $false
	New-TestSourcePageEventJson -Id 'gap-2' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'fgh' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 5 -ContentBytes 3 -EndOffsetBytes 8 -FileSizeBytes 8 -Eof $true
) | Set-Content -LiteralPath $ProtocolFailureEventPath -Encoding UTF8
$ProtocolFailureTelemetry = & $EventTelemetryScript -EventLogPath $ProtocolFailureEventPath
Add-Result `
	-Name 'Source pagination gaps are classified as protocol rejection' `
	-Passed ($ProtocolFailureTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$CaseVariantEventPath = Join-Path $TestRoot 'source-case-variant-events.jsonl'
@(
	New-TestSourcePageEventJson -Id 'case-1' -Path 'AGENTS.md' -Encoding 'utf8' `
		-Content 'abcd' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 0 -ContentBytes 4 -EndOffsetBytes 4 -FileSizeBytes 8 -Eof $false
	New-TestSourcePageEventJson -Id 'case-2' -Path 'agents.md' -Encoding 'utf8' `
		-Content 'efgh' `
		-BaseSha256 '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab' `
		-OffsetBytes 4 -ContentBytes 4 -EndOffsetBytes 8 -FileSizeBytes 8 -Eof $true
) | Set-Content -LiteralPath $CaseVariantEventPath -Encoding UTF8
$CaseVariantTelemetry = & $EventTelemetryScript -EventLogPath $CaseVariantEventPath
Add-Result `
	-Name 'Source path continuity is case-sensitive' `
	-Passed ($CaseVariantTelemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$Base64EventPath = Join-Path $TestRoot 'source-base64-events.jsonl'
$Base64Bytes = [byte[]]@(255, 0, 128)
$Base64Hash = [BitConverter]::ToString(
	([Security.Cryptography.SHA256]::Create()).ComputeHash($Base64Bytes)
).Replace('-', '').ToLowerInvariant()
New-TestSourcePageEventJson -Id 'base64-1' -Path 'Content.bin' -Encoding 'base64' `
	-Content ([Convert]::ToBase64String($Base64Bytes)) -BaseSha256 $Base64Hash `
	-OffsetBytes 0 -ContentBytes 3 -EndOffsetBytes 3 -FileSizeBytes 3 -Eof $true |
	Set-Content -LiteralPath $Base64EventPath -Encoding UTF8
$Base64Telemetry = & $EventTelemetryScript -EventLogPath $Base64EventPath
Add-Result `
	-Name 'Valid base64 source pagination is classified complete' `
	-Passed ($Base64Telemetry.SourceInspection.Outcome -ceq 'complete_pagination')

$NoncanonicalBase64Events = @(
	New-TestSourcePageEventJson -Id 'base64-whitespace' -Path 'Content.bin' -Encoding 'base64' `
		-Content ([Convert]::ToBase64String($Base64Bytes)) -BaseSha256 $Base64Hash `
		-OffsetBytes 0 -ContentBytes 3 -EndOffsetBytes 3 -FileSizeBytes 3 -Eof $true
)
$NoncanonicalBase64Completion = $NoncanonicalBase64Events[1] | ConvertFrom-Json
$NoncanonicalBase64Completion.item.result.structured_content.content = (
	[Convert]::ToBase64String($Base64Bytes).Insert(2, ' ')
)
$NoncanonicalBase64Completion.item.result.content[0].text = (
	$NoncanonicalBase64Completion.item.result.structured_content |
		ConvertTo-Json -Depth 4 -Compress
)
$NoncanonicalBase64EventPath = Join-Path $TestRoot 'source-noncanonical-base64-events.jsonl'
@(
	$NoncanonicalBase64Events[0]
	$NoncanonicalBase64Completion | ConvertTo-Json -Depth 8 -Compress
) | Set-Content -LiteralPath $NoncanonicalBase64EventPath -Encoding UTF8
$NoncanonicalBase64Telemetry = & $EventTelemetryScript `
	-EventLogPath $NoncanonicalBase64EventPath
Add-Result `
	-Name 'Source base64 content must use canonical encoding' `
	-Passed ($NoncanonicalBase64Telemetry.SourceInspection.Outcome -ceq 'protocol_rejected')

$SourcePolicyEventPath = Join-Path $TestRoot 'source-policy-rejection-events.jsonl'
@'
{"type":"item.started","item":{"id":"policy-1","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":0},"status":"in_progress"}}
{"type":"item.completed","item":{"id":"policy-1","type":"mcp_tool_call","server":"source_inspection","tool":"read_allowed_source_file","arguments":{"path":"AGENTS.md","offset_bytes":0},"result":{"content":[{"type":"text","text":"[source_path_sensitive] do-not-retain-policy-message"}],"isError":true},"error":null,"status":"completed"}}
'@ | Set-Content -LiteralPath $SourcePolicyEventPath -Encoding UTF8
$SourcePolicyTelemetry = & $EventTelemetryScript -EventLogPath $SourcePolicyEventPath
Add-Result `
	-Name 'Source policy rejection is classified without retaining error text' `
	-Passed (
		$SourcePolicyTelemetry.SourceInspection.Outcome -ceq 'source_policy_rejected' -and
		((& $EventTelemetryScript -EventLogPath $SourcePolicyEventPath |
			ConvertTo-Json -Compress) -notmatch 'do-not-retain-policy-message')
	)

function Get-FixtureTelemetry {
	param([Parameter(Mandatory)][string]$RunId)

	$ArtifactRoot = Join-Path $TestRoot "$RunId-artifacts"
	$AuditPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-audit.json"
	$Audit = Get-Content -Raw -LiteralPath $AuditPath | ConvertFrom-Json
	$TelemetryPath = [string]$Audit.TelemetryPath
	$TelemetryExists = -not [string]::IsNullOrWhiteSpace($TelemetryPath) -and
		(Test-Path -LiteralPath $TelemetryPath -PathType Leaf)
	$Telemetry = if ($TelemetryExists) {
		Get-Content -Raw -LiteralPath $TelemetryPath | ConvertFrom-Json
	} else {
		$null
	}
	$ManifestPath = Join-Path $ArtifactRoot "delivery-stage-$RunId-evidence.json"
	return [pscustomobject]@{
		RunId = $RunId
		ArtifactRoot = $ArtifactRoot
		AuditPath = $AuditPath
		Audit = $Audit
		TelemetryPath = $TelemetryPath
		TelemetryExists = $TelemetryExists
		Telemetry = $Telemetry
		ManifestPath = $ManifestPath
		Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
	}
}

$TelemetryRootProperties = @(
	'SchemaVersion', 'RunId', 'Ticket', 'Stage', 'SourceCommit', 'HandoffHash',
	'BeforeSnapshotHash', 'AfterSnapshotHash', 'StartedAtUtc', 'EndedAtUtc',
	'DurationMilliseconds', 'AttemptOrdinal', 'AttemptClass', 'CapabilityClass',
	'RetryCause', 'Limits', 'SessionId', 'Model', 'ReasoningTier', 'InputTokens',
	'CachedInputTokens', 'CacheWriteInputTokens', 'OutputTokens',
	'ReasoningOutputTokens', 'TotalTokens', 'ExitClass', 'ChangedPathCount',
	'ProposedPathCount', 'OutputBytes', 'PatchBytes', 'StageStatus',
	'SourceInspection', 'EvidenceManifestPath', 'EvidenceManifestHash', 'TelemetryError'
)
$SourceInspectionTelemetryProperties = @(
	'Outcome', 'CallCount', 'CompletedPageCount', 'CompletedPathCount',
	'CompletedSources'
)
$TelemetryLimitsProperties = @(
	'TotalTokens', 'ElapsedMilliseconds', 'ConcurrentStages', 'ExecutionRetries',
	'FixCycles', 'Provenance', 'ApprovedAtUtc'
)

$BlockedTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-blocked'
$BlockedTelemetry = $BlockedTelemetryFixture.Telemetry
$BlockedAudit = $BlockedTelemetryFixture.Audit
$BlockedTelemetryPath = $BlockedTelemetryFixture.TelemetryPath
$BlockedEventLog = Get-Content -Raw -LiteralPath ([string]$BlockedAudit.EventLogPath)
$BlockedManifestTelemetryEntries = @($BlockedTelemetryFixture.Manifest.Files |
	Where-Object { [string]$_.Path -eq $BlockedTelemetryPath })
Add-Result `
	-Name 'Blocked launch exposes distinct telemetry with observed usage' `
	-Passed (
		$BlockedTelemetryFixture.TelemetryExists -and
		@(
			$BlockedTelemetryFixture.AuditPath,
			[string]$BlockedAudit.EventLogPath,
			(Join-Path $BlockedTelemetryFixture.ArtifactRoot 'delivery-stage-test-worker-blocked-output.json'),
			$BlockedTelemetryFixture.ManifestPath
		) -notcontains $BlockedTelemetryPath -and
		$BlockedEventLog -notmatch 'IGNORED_FIXTURE_DIAGNOSTIC' -and
		$BlockedTelemetry.SessionId -eq 'fixture-session' -and
		$BlockedTelemetry.InputTokens -eq 100 -and
		$BlockedTelemetry.CachedInputTokens -eq 40 -and
		$BlockedTelemetry.CacheWriteInputTokens -eq 0 -and
		$BlockedTelemetry.OutputTokens -eq 20 -and
		$BlockedTelemetry.ReasoningOutputTokens -eq 5 -and
		$BlockedTelemetry.TotalTokens -eq 120
	)

Add-Result `
	-Name 'Telemetry receives default execution policy' `
	-Passed (
		$BlockedTelemetry.AttemptOrdinal -eq 1 -and
		$BlockedTelemetry.AttemptClass -eq 'initial' -and
		$BlockedTelemetry.CapabilityClass -eq 'standard' -and
		$null -eq $BlockedTelemetry.RetryCause -and
		@($BlockedTelemetry.Limits.PSObject.Properties.Value |
			Where-Object { $null -ne $_ }).Count -eq 0
	)

$ObservedTelemetryProperties = [string]::Join(
	'|', [string[]]@($BlockedTelemetry.PSObject.Properties.Name)
)
$ExpectedTelemetryProperties = [string]::Join('|', [string[]]$TelemetryRootProperties)
$ObservedLimitsProperties = [string]::Join(
	'|', [string[]]@($BlockedTelemetry.Limits.PSObject.Properties.Name)
)
$ExpectedLimitsProperties = [string]::Join('|', [string[]]$TelemetryLimitsProperties)
$ObservedSourceInspectionProperties = [string]::Join(
	'|', [string[]]@($BlockedTelemetry.SourceInspection.PSObject.Properties.Name)
)
$ExpectedSourceInspectionProperties = [string]::Join(
	'|', [string[]]$SourceInspectionTelemetryProperties
)
Add-Result `
	-Name 'Telemetry schema has exact ordered properties' `
	-Passed (
		$BlockedTelemetry.SchemaVersion -eq 1 -and
		$ObservedTelemetryProperties -ceq $ExpectedTelemetryProperties -and
		$ObservedLimitsProperties -ceq $ExpectedLimitsProperties -and
		$ObservedSourceInspectionProperties -ceq $ExpectedSourceInspectionProperties
	)

Add-Result `
	-Name 'Telemetry records bounded metadata and nullable unavailable values' `
	-Passed (
		[string]$BlockedTelemetry.RunId -eq 'test-worker-blocked' -and
		[string]$BlockedTelemetry.Ticket -eq 'Issue #123' -and
		[string]$BlockedTelemetry.Stage -eq 'worker' -and
		[string]$BlockedTelemetry.StartedAtUtc -cmatch 'Z$' -and
		[string]$BlockedTelemetry.EndedAtUtc -cmatch 'Z$' -and
		$BlockedTelemetry.DurationMilliseconds -ge 0 -and
		$BlockedTelemetry.ChangedPathCount -ge 0 -and
		$BlockedTelemetry.ProposedPathCount -ge 0 -and
		$null -eq $BlockedTelemetry.Model -and
		$null -eq $BlockedTelemetry.ReasoningTier -and
		$BlockedTelemetry.OutputBytes -gt 0 -and
		$null -eq $BlockedTelemetry.PatchBytes -and
		[string]$BlockedTelemetry.StageStatus -eq 'blocked' -and
		[string]$BlockedTelemetry.SourceInspection.Outcome -eq 'no_tool_call' -and
		$BlockedTelemetry.SourceInspection.CallCount -eq 0 -and
		$null -eq $BlockedTelemetry.EvidenceManifestHash
	)

Add-Result `
	-Name 'Telemetry is hash-bound and read-only evidence' `
	-Passed (
		$BlockedManifestTelemetryEntries.Count -eq 1 -and
		$BlockedManifestTelemetryEntries[0].Sha256 -eq (
			Get-FileHash -LiteralPath $BlockedTelemetryPath -Algorithm SHA256
		).Hash.ToLowerInvariant() -and
		(Get-Item -LiteralPath $BlockedTelemetryPath -Force).IsReadOnly -and
		[string]$BlockedTelemetry.EvidenceManifestPath -eq $BlockedTelemetryFixture.ManifestPath
	)

$NonzeroTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-nonzero'
$NonzeroTelemetry = $NonzeroTelemetryFixture.Telemetry
Add-Result `
	-Name 'Nonzero child produces telemetry with unavailable observations null' `
	-Passed (
		$NonzeroTelemetryFixture.TelemetryExists -and
		$null -eq $NonzeroTelemetry.SessionId -and
		$null -eq $NonzeroTelemetry.InputTokens -and
		$null -eq $NonzeroTelemetry.CachedInputTokens -and
		$null -eq $NonzeroTelemetry.CacheWriteInputTokens -and
		$null -eq $NonzeroTelemetry.OutputTokens -and
		$null -eq $NonzeroTelemetry.ReasoningOutputTokens -and
		$null -eq $NonzeroTelemetry.TotalTokens -and
		$null -eq $NonzeroTelemetry.OutputBytes -and
		$null -eq $NonzeroTelemetry.PatchBytes
	)

$MalformedFixtureResult = Invoke-FailureEvidenceCase `
	-Scenario 'malformed-event' `
	-ExpectedError "reported status 'blocked': fixture blocked" `
	-ExpectedFileCount 5 `
	-ExpectOutput $true
$MalformedTelemetryFixture = Get-FixtureTelemetry -RunId 'test-worker-malformed-event'
$MalformedTelemetry = $MalformedTelemetryFixture.Telemetry
Add-Result `
	-Name 'Malformed event is sanitized without replacing the blocked primary error' `
	-Passed (
		$MalformedFixtureResult.Passed -and
		$MalformedTelemetryFixture.TelemetryExists -and
		-not [string]::IsNullOrWhiteSpace([string]$MalformedTelemetry.TelemetryError) -and
		[string]$MalformedTelemetry.TelemetryError -notmatch 'MALFORMED_EVENT_FIXTURE' -and
		$null -eq $MalformedTelemetry.SessionId -and
		$null -eq $MalformedTelemetry.InputTokens -and
		$null -eq $MalformedTelemetry.CachedInputTokens -and
		$null -eq $MalformedTelemetry.CacheWriteInputTokens -and
		$null -eq $MalformedTelemetry.OutputTokens -and
		$null -eq $MalformedTelemetry.ReasoningOutputTokens -and
		$null -eq $MalformedTelemetry.TotalTokens
	) `
	-Detail $MalformedFixtureResult.Detail

function New-EfficiencyFixture {
	param(
		[Parameter(Mandatory)][string]$Name,
		[AllowNull()][object]$Tokens,
		[string]$CriteriaVersion = 'issue-70-quality-v1',
		[string]$EnvironmentId = 'local-windows',
		[bool]$QualityPassed = $true
	)

	$Path = Join-Path $TestRoot "$Name.json"
	[ordered]@{
		schema_version = 1
		quality_criteria_version = $CriteriaVersion
		environment_id = $EnvironmentId
		total_tokens = $Tokens
		quality = [ordered]@{
			mandatory_checks_passed = $QualityPassed
			attestations_passed = $true
			acceptance_evidence_complete = $true
			unresolved_material_findings = 0
			approval_passed = $true
		}
	} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
	return $Path
}

$EfficiencyBaselinePath = New-EfficiencyFixture -Name 'efficiency-baseline' -Tokens 100
$EfficiencyClassificationCases = @(
	@('improved', 80, 'improved', -20),
	@('equal', 100, 'not_improved', 0),
	@('greater', 120, 'not_improved', 20)
)
foreach ($Case in $EfficiencyClassificationCases) {
	$CandidatePath = New-EfficiencyFixture `
		-Name "efficiency-$($Case[0])" `
		-Tokens $Case[1]
	$Comparison = & $EfficiencyComparisonScript `
		-BaselinePath $EfficiencyBaselinePath `
		-CandidatePath $CandidatePath
	Add-Result `
		-Name "Efficiency comparison classifies $($Case[0]) tokens" `
		-Passed (
			$Comparison.Classification -eq $Case[2] -and
			$Comparison.BaselineQualityPassed -and
			$Comparison.CandidateQualityPassed -and
			$Comparison.BaselineTotalTokens -eq 100 -and
			$Comparison.CandidateTotalTokens -eq $Case[1] -and
			$Comparison.TokenDelta -eq $Case[3]
		)
}

foreach ($TokenMode in @('measured', 'missing')) {
	$RegressionBaselineTokens = if ($TokenMode -eq 'measured') { 100 } else { $null }
	$RegressionCandidateTokens = if ($TokenMode -eq 'measured') { 50 } else { $null }
	$RegressionBaselinePath = New-EfficiencyFixture `
		-Name "regression-$TokenMode-baseline" `
		-Tokens $RegressionBaselineTokens
	$RegressionCandidatePath = New-EfficiencyFixture `
		-Name "regression-$TokenMode-candidate" `
		-Tokens $RegressionCandidateTokens `
		-QualityPassed $false
	$RegressionComparison = & $EfficiencyComparisonScript `
		-BaselinePath $RegressionBaselinePath `
		-CandidatePath $RegressionCandidatePath
	Add-Result `
		-Name "Quality regression takes precedence with $TokenMode tokens" `
		-Passed (
			$RegressionComparison.Classification -eq 'quality_regression' -and
			$RegressionComparison.BaselineQualityPassed -and
			-not $RegressionComparison.CandidateQualityPassed -and
			(
				($TokenMode -eq 'measured' -and $RegressionComparison.TokenDelta -eq -50) -or
				($TokenMode -eq 'missing' -and $null -eq $RegressionComparison.TokenDelta)
			)
		)
}

$NotMeasurableCases = @(
	@('environment mismatch', 'issue-70-quality-v1', 'development-linux', 90, $true),
	@('missing tokens', 'issue-70-quality-v1', 'local-windows', $null, $true),
	@('failing baseline quality', 'issue-70-quality-v1', 'local-windows', 90, $false)
)
foreach ($Case in $NotMeasurableCases) {
	if ($Case[0] -eq 'failing baseline quality') {
		$CaseBaselinePath = New-EfficiencyFixture `
			-Name 'failing-baseline' -Tokens 100 -QualityPassed $false
		$CaseCandidatePath = New-EfficiencyFixture `
			-Name 'failing-baseline-candidate' -Tokens $Case[3]
	} else {
		$CaseBaselinePath = $EfficiencyBaselinePath
		$CaseCandidatePath = New-EfficiencyFixture `
			-Name ('not-measurable-' + ($Case[0] -replace ' ', '-')) `
			-Tokens $Case[3] `
			-CriteriaVersion $Case[1] `
			-EnvironmentId $Case[2]
	}
	$NotMeasurableComparison = & $EfficiencyComparisonScript `
		-BaselinePath $CaseBaselinePath `
		-CandidatePath $CaseCandidatePath
	Add-Result `
		-Name "Efficiency comparison rejects $($Case[0])" `
		-Passed ($NotMeasurableComparison.Classification -eq 'not_measurable')
}

$WrongCandidateCriteriaPath = New-EfficiencyFixture `
	-Name 'wrong-candidate-criteria' `
	-Tokens 90 `
	-CriteriaVersion 'issue-70-quality-v2'
$WrongCandidateCriteriaRejected = Invoke-ExpectedFailure `
	-Pattern 'Candidate quality_criteria_version' `
	-Action {
	& $EfficiencyComparisonScript `
		-BaselinePath $EfficiencyBaselinePath `
		-CandidatePath $WrongCandidateCriteriaPath | Out-Null
}
Add-Result `
	-Name 'Efficiency comparison rejects a noncanonical candidate criteria version' `
	-Passed $WrongCandidateCriteriaRejected

$WrongCriteriaBaselinePath = New-EfficiencyFixture `
	-Name 'wrong-criteria-baseline' `
	-Tokens 100 `
	-CriteriaVersion 'anything'
$WrongCriteriaCandidatePath = New-EfficiencyFixture `
	-Name 'wrong-criteria-candidate' `
	-Tokens 90 `
	-CriteriaVersion 'anything'
$WrongCriteriaRejected = Invoke-ExpectedFailure -Pattern 'issue-70-quality-v1' -Action {
	& $EfficiencyComparisonScript `
		-BaselinePath $WrongCriteriaBaselinePath `
		-CandidatePath $WrongCriteriaCandidatePath | Out-Null
}
Add-Result `
	-Name 'Efficiency comparison rejects a shared noncanonical criteria version' `
	-Passed $WrongCriteriaRejected

$ExactOutputCandidatePath = New-EfficiencyFixture `
	-Name 'exact-output-candidate' -Tokens 90
$ExactOutput = & $EfficiencyComparisonScript `
	-BaselinePath $EfficiencyBaselinePath `
	-CandidatePath $ExactOutputCandidatePath
$ExpectedComparisonProperties = @(
	'Classification', 'BaselineQualityPassed', 'CandidateQualityPassed',
	'BaselineTotalTokens', 'CandidateTotalTokens', 'TokenDelta', 'Reason'
)
Add-Result `
	-Name 'Efficiency comparison output has exact ordered fields' `
	-Passed (
		[string]::Join('|', $ExactOutput.PSObject.Properties.Name) -ceq
		[string]::Join('|', $ExpectedComparisonProperties)
	)

$ValidEfficiencyJson = Get-Content -Raw -LiteralPath $EfficiencyBaselinePath |
	ConvertFrom-Json
$InvalidEfficiencyCases = @(
	@('unknown root field', 'root', 'unexpected', $true),
	@('missing root field', 'root', 'environment_id', $null),
	@('unknown quality field', 'quality', 'unexpected', $true),
	@('missing quality field', 'quality', 'approval_passed', $null),
	@('wrong schema type', 'root', 'schema_version', '1'),
	@('wrong criteria type', 'root', 'quality_criteria_version', 1),
	@('wrong environment type', 'root', 'environment_id', 1),
	@('wrong token type', 'root', 'total_tokens', '100'),
	@('wrong quality type', 'root', 'quality', @()),
	@('wrong boolean type', 'quality', 'mandatory_checks_passed', 'true'),
	@('negative tokens', 'root', 'total_tokens', -1),
	@('fractional tokens', 'root', 'total_tokens', 1.5),
	@('negative findings', 'quality', 'unresolved_material_findings', -1),
	@('fractional findings', 'quality', 'unresolved_material_findings', 1.5)
)
foreach ($Case in $InvalidEfficiencyCases) {
	$InvalidRecord = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$Target = if ($Case[1] -eq 'quality') { $InvalidRecord.quality } else { $InvalidRecord }
	if ($Case[0] -like 'missing*') {
		$Target.PSObject.Properties.Remove($Case[2])
	} elseif ($Case[0] -like 'unknown*') {
		$Target | Add-Member -NotePropertyName $Case[2] -NotePropertyValue $Case[3]
	} else {
		$Target.($Case[2]) = $Case[3]
	}
	$InvalidPath = Join-Path $TestRoot (
		'invalid-efficiency-' + ($Case[0] -replace ' ', '-') + '.json'
	)
	$InvalidRecord | ConvertTo-Json -Depth 4 | Set-Content `
		-LiteralPath $InvalidPath -Encoding UTF8
	$InvalidRejected = Invoke-ExpectedFailure -Pattern 'Baseline' -Action {
		& $EfficiencyComparisonScript `
			-BaselinePath $InvalidPath `
			-CandidatePath $ExactOutputCandidatePath | Out-Null
	}
	Add-Result `
		-Name "Efficiency input rejects $($Case[0])" `
		-Passed $InvalidRejected
}

$BlankStringCases = @('quality_criteria_version', 'environment_id')
foreach ($FieldName in $BlankStringCases) {
	$BlankRecord = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$BlankRecord.$FieldName = ' '
	$BlankPath = Join-Path $TestRoot "blank-$FieldName.json"
	$BlankRecord | ConvertTo-Json -Depth 4 | Set-Content `
		-LiteralPath $BlankPath -Encoding UTF8
	$BlankRejected = Invoke-ExpectedFailure -Pattern $FieldName -Action {
		& $EfficiencyComparisonScript `
			-BaselinePath $BlankPath `
			-CandidatePath $ExactOutputCandidatePath | Out-Null
	}
	Add-Result -Name "Efficiency input rejects blank $FieldName" -Passed $BlankRejected
}

$LeakMarker = 'do-not-expose-efficiency-payload'
$LeakingEfficiencyPath = Join-Path $TestRoot 'leaking-efficiency.json'
$LeakingEfficiency = $ValidEfficiencyJson | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$LeakingEfficiency.quality.mandatory_checks_passed = $LeakMarker
$LeakingEfficiency | ConvertTo-Json -Depth 4 | Set-Content `
	-LiteralPath $LeakingEfficiencyPath -Encoding UTF8
$LeakError = ''
try {
	& $EfficiencyComparisonScript `
		-BaselinePath $LeakingEfficiencyPath `
		-CandidatePath $ExactOutputCandidatePath | Out-Null
}
catch {
	$LeakError = $_.Exception.Message
}
Add-Result `
	-Name 'Efficiency validation errors do not leak payload values' `
	-Passed (
		-not [string]::IsNullOrWhiteSpace($LeakError) -and
		$LeakError -notmatch [regex]::Escape($LeakMarker)
	)

$IndependentGateProfiles = @(
	@{ Name = 'verifier'; Path = '.codex\agents\delivery-verifier.toml' },
	@{ Name = 'reviewer'; Path = '.codex\agents\delivery-reviewer.toml' },
	@{ Name = 'approver'; Path = '.codex\agents\delivery-approver.toml' },
	@{ Name = 'adjudicator'; Path = '.codex\agents\delivery-adjudicator.toml' }
)
$NeutralInputMarkers = @(
	'ticket acceptance criteria',
	'non-goals',
	'required check commands',
	'output schema or contract',
	'required response labels',
	'raw machine-generated command and test logs',
	'normative neutral inputs',
	'not prior conclusions',
	'must not be rejected'
)
$PriorJudgmentMarkers = @(
	'prior agent-produced',
	'findings',
	'corrections',
	'outcome claims',
	'confidence',
	'severity',
	'preferred framing',
	'narrative'
)
foreach ($GateProfile in $IndependentGateProfiles) {
	$GateProfilePath = Join-Path $RepositoryRoot $GateProfile.Path
	$GateProfileSource = (
		Get-Content -Raw -LiteralPath $GateProfilePath
	).ToLowerInvariant()
	$MissingNeutralMarkers = @($NeutralInputMarkers | Where-Object {
		-not $GateProfileSource.Contains($_)
	})
	Add-Result `
		-Name "$($GateProfile.Name) profile admits normative neutral inputs" `
		-Passed ($MissingNeutralMarkers.Count -eq 0) `
		-Detail ([string]::Join(', ', $MissingNeutralMarkers))
	$MissingPriorJudgmentMarkers = @($PriorJudgmentMarkers | Where-Object {
		-not $GateProfileSource.Contains($_)
	})
	Add-Result `
		-Name "$($GateProfile.Name) profile rejects prior agent judgments" `
		-Passed ($MissingPriorJudgmentMarkers.Count -eq 0) `
		-Detail ([string]::Join(', ', $MissingPriorJudgmentMarkers))
}

$Results | Format-Table -AutoSize

$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) delivery-stage launcher test(s) failed. Test artifacts: $TestRoot"
}

Write-Host "All delivery-stage launcher tests passed. Test artifacts: $TestRoot"
}
catch {
	if (
		$SuiteLockProbeMode -ne 'FailureRelease' -or
		$_.Exception.Message -cne $FailureReleaseProbeMessage
	) {
		throw
	}
	$FailureReleaseProbeError = $_.Exception
}
finally {
	# Every path after successful acquisition, including assertion failures and
	# probe returns, deterministically releases machine-global mutex ownership.
	if ($SuiteLockOwned) {
		$SuiteLockMutex.ReleaseMutex()
	}
	$SuiteLockMutex.Dispose()
}

if ($SuiteLockProbeMode -eq 'FailureRelease') {
	if ($null -eq $FailureReleaseProbeError) {
		throw 'The suite-lock failure-release probe did not exercise its throw path.'
	}

	$ReacquiredSuiteLockMutex = [System.Threading.Mutex]::new(
		$false,
		$SuiteLockName
	)
	$ReacquiredSuiteLockOwned = $false
	try {
		$ReacquiredSuiteLockOwned = $ReacquiredSuiteLockMutex.WaitOne(0)
		if (-not $ReacquiredSuiteLockOwned) {
			throw 'The suite mutex remained owned after the failure-release probe.'
		}
	}
	finally {
		if ($ReacquiredSuiteLockOwned) {
			$ReacquiredSuiteLockMutex.ReleaseMutex()
		}
		$ReacquiredSuiteLockMutex.Dispose()
	}
}
