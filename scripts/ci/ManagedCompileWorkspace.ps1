# Runs only inside the gate's hard-bounded, process-tree-owned Compile child.
# The caller retains the shared host lease through final child-tree cleanup.
# This module never acquires a lease, copies outputs, or extends that deadline.
function Initialize-ManagedWorkspaceNative {
	if ('Aetheln.ManagedWorkspaceGit' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Aetheln {
 public sealed class ManagedWorkspaceGit : IDisposable {
  [StructLayout(LayoutKind.Sequential)] private struct FileInfo {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
   public uint Volume, HighSize, LowSize, Links, HighIndex, LowIndex;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo information);
  public static SafeFileHandle OpenPlain(string path, bool directory) {
   var handle = CreateFile(path, directory ? 0U : 0x80000000U, directory ? 3U : 1U, IntPtr.Zero, 3U, 0x00200000U | (directory ? 0x02000000U : 0U), IntPtr.Zero);
   FileInfo info;
   if (handle.IsInvalid || !GetFileInformationByHandle(handle, out info) ||
       (info.Attributes & 0x400U) != 0 || ((info.Attributes & 0x10U) != 0) != directory || (!directory && info.Links != 1)) {
    handle.Dispose(); throw new IOException("managed_workspace_plain_handle_required");
   }
   return handle;
  }
  public Process Process;
  public Task<string> Output;
  public Task<string> Error;
  public volatile bool Overflow;
  private async Task<string> Read(StreamReader reader, bool retain) {
   char[] buffer = new char[4096]; var text = new StringBuilder(); int total = 0;
   int count;
   while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
    total += count;
    if (total > 2097152) { Overflow = true; return ""; }
    if (retain) text.Append(buffer, 0, count);
   }
   return text.ToString();
  }
  public ManagedWorkspaceGit(string executable, string arguments) {
   Process = new Process();
   Process.StartInfo = new ProcessStartInfo(executable, arguments) {
    UseShellExecute = false, CreateNoWindow = true,
    RedirectStandardOutput = true, RedirectStandardError = true,
    RedirectStandardInput = true, StandardOutputEncoding = new UTF8Encoding(false, true)
   };
   if (!Process.Start()) throw new InvalidOperationException();
   Process.StandardInput.Close();
   Output = Read(Process.StandardOutput, true); Error = Read(Process.StandardError, false);
  }
  public bool Completed { get { return Process.HasExited && Output.IsCompleted && Error.IsCompleted; } }
  public void Dispose() {
   // The enclosing gate owns descendants and must verify its Job Object cleanup.
   // Never infer tree cleanup from this direct-child stop.
   try { if (!Process.HasExited) Process.Kill(); } catch { }
   Process.Dispose();
  }
 }
}
'@
}

function Get-ManagedWorkspaceRemainingMillisecondCount {
	param($Context)
	if ($Context.ContainsKey('remainingBudget') -and $null -ne $Context.remainingBudget) {
		if ($Context.milliseconds -le $Context.clock.Elapsed.TotalMilliseconds) { throw 'compile_timeout' }
		try { $Fresh = & $Context.remainingBudget } catch {
			if ($_.Exception.Message -cin @('compile_timeout', 'compile_clock_invalid', 'resource_pressure', 'disk_floor_reached')) { throw }
			throw 'compile_clock_invalid'
		}
		if ($null -eq $Fresh -or $Fresh.GetType().FullName -cnotin @('System.Int32', 'System.Int64', 'System.Double', 'System.Decimal', 'System.Single', 'System.UInt32', 'System.UInt64', 'System.Int16', 'System.UInt16', 'System.Byte', 'System.SByte') -or [double]::IsNaN([double] $Fresh) -or [double]::IsInfinity([double] $Fresh)) { throw 'compile_clock_invalid' }
		if ($Fresh -le 0) { throw 'compile_timeout' }
		$Context.milliseconds = [Math]::Min($Context.milliseconds, $Context.clock.Elapsed.TotalMilliseconds + [double] $Fresh)
		$Remaining = $Context.milliseconds - $Context.clock.Elapsed.TotalMilliseconds
		if ($Remaining -le 0) { throw 'compile_timeout' }
	} else {
		$Remaining = [Math]::Min(($Context.deadline - [DateTime]::UtcNow).TotalMilliseconds, ($Context.seconds - $Context.clock.Elapsed.TotalSeconds) * 1000)
		if ($Remaining -le 0) { throw 'managed_workspace_deadline' }
	}
	return $Remaining
}

function Assert-ManagedWorkspaceProgress {
	param([Parameter(Mandatory)] $Context)
	$null = Get-ManagedWorkspaceRemainingMillisecondCount -Context $Context
	if ($null -ne $Context.progress) { & $Context.progress | Out-Null }
	$null = Get-ManagedWorkspaceRemainingMillisecondCount -Context $Context
}

function Invoke-ManagedWorkspaceGit {
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Arguments,
		[Parameter(Mandatory)] $Context, [switch] $AllowMissing)
	Assert-ManagedWorkspaceProgress -Context $Context
	$Native = $null
	try {
		$Native = New-Object Aetheln.ManagedWorkspaceGit($Context.git, ('--no-replace-objects --no-optional-locks -C "' + $Root + '" ' + $Arguments))
		while (-not $Native.Completed) {
			Assert-ManagedWorkspaceProgress -Context $Context
			if ($Native.Overflow) { throw 'managed_workspace_git_output_limit' }
			Start-Sleep -Milliseconds 25
		}
		Assert-ManagedWorkspaceProgress -Context $Context
		if ($Native.Overflow) { throw 'managed_workspace_git_output_limit' }
		if ($Native.Process.ExitCode -ne 0) {
			if ($AllowMissing) { return $null }
			throw 'managed_workspace_git_failed'
		}
		return [string] $Native.Output.Result
	} catch {
		if ($_.Exception.Message -cmatch '^managed_workspace_[a-z_]+$' -or $_.Exception.Message -cin @('compile_timeout', 'compile_clock_invalid', 'resource_pressure', 'disk_floor_reached')) { throw }
		throw 'managed_workspace_git_failed'
	} finally { if ($null -ne $Native) { $Native.Dispose() } }
}

function Test-ManagedWorkspaceRelativePath {
	param([Parameter(Mandatory)][string] $Path)
	if ($Path.Length -gt 1024 -or $Path -match '[\\:\x00-\x1f\x7f"<>|?*\uFFFD]' -or $Path.StartsWith('/')) { throw 'managed_workspace_path_invalid' }
	foreach ($Part in $Path.Split('/')) {
		if ($Part -in @('', '.', '..') -or $Part -match '[. ]$' -or $Part -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)' -or $Part -ieq '.git') { throw 'managed_workspace_path_invalid' }
		if ($Part -match '^(?i:\.env.*|\.gitmodules|\.lfsconfig|\.ssh|\.aws|\.azure|\.kube|\.gnupg|\.npmrc|\.pypirc|\.netrc|auth\.json|tokens?\.json|credentials?(?:\..*)?|secrets?(?:\..*)?|id_rsa(?:\..*)?|id_ed25519(?:\..*)?|.*\.(?:pem|key|pfx|p12|keystore|jks))$') { throw 'managed_workspace_sensitive_path' }
		if ($Part -in @('Binaries', 'Intermediate', 'DerivedDataCache', 'Saved')) { throw 'managed_workspace_generated_path' }
	}
	return ($Path -match '^(?i:Source|Config|Content|Plugins|Build|Platforms)/' -or $Path -imatch '^(AethelnOnline\.uproject|\.gitattributes)$')
}

function Assert-ManagedWorkspacePlainPath {
	param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Context)
	$Cursor = $Path
	while ($Cursor) {
		Assert-ManagedWorkspaceProgress -Context $Context
		if (Test-Path -LiteralPath $Cursor) {
			$Item = Get-Item -LiteralPath $Cursor -Force -ErrorAction Stop
			if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'managed_workspace_reparse_path' }
			if ($Item.PSIsContainer -and -not $Context.pins.ContainsKey($Cursor)) {
				if ($Context.pins.Count -ge 10000) { throw 'managed_workspace_input_limit' }
				$Context.pins[$Cursor] = [Aetheln.ManagedWorkspaceGit]::OpenPlain($Cursor, $true)
			}
		}
		$Parent = [IO.Path]::GetDirectoryName($Cursor)
		if ($Parent -eq $Cursor) { break }
		$Cursor = $Parent
	}
}

function Get-ManagedWorkspaceRoot {
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)] $Context)
	if ($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Length -gt 4096 -or $Root -match '["\x00-\x1f]' -or $Root.Substring(2).Contains(':')) { throw 'managed_workspace_root_invalid' }
	foreach ($Part in $Root.Substring(3).Split([char[]] '\/')) {
		if ($Part -in @('.', '..') -or $Part -match '[. ]$') { throw 'managed_workspace_root_invalid' }
	}
	$Full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	if ($Full.Length -le 3 -or -not (Test-Path -LiteralPath $Full -PathType Container)) { throw 'managed_workspace_root_invalid' }
	Assert-ManagedWorkspacePlainPath -Path $Full -Context $Context
	return $Full
}

function Get-ManagedWorkspaceTree {
	param([string] $Root, [string] $Revision, $Context)
	$Text = Invoke-ManagedWorkspaceGit -Root $Root -Arguments ('ls-tree -r -l -z ' + $Revision) -Context $Context
	if (-not $Text -or -not $Text.EndsWith([string][char]0)) { throw 'managed_workspace_tree_invalid' }
	$Rows = New-Object Collections.ArrayList
	$Components = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
	$Names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Line in $Text.TrimEnd([char]0).Split([char]0)) {
		Assert-ManagedWorkspaceProgress -Context $Context
		if ($Rows.Count -ge 10000 -or $Line -cnotmatch '^(100644|100755) blob ([0-9a-f]{40}) +([0-9]{1,12})\t(.+)$') { throw 'managed_workspace_tree_invalid' }
		$Mode = $Matches[1]; $Blob = $Matches[2]; $Size = [long] $Matches[3]; $Path = $Matches[4]
		$Selected = Test-ManagedWorkspaceRelativePath -Path $Path
		if (-not $Names.Add($Path)) { throw 'managed_workspace_path_collision' }
		$Prefix = ''
		foreach ($Part in $Path.Split('/')) {
			$Prefix = if ($Prefix) { $Prefix + '/' + $Part } else { $Part }
			if ($Components.ContainsKey($Prefix) -and $Components[$Prefix] -cne $Prefix) { throw 'managed_workspace_path_collision' }
			$Components[$Prefix] = $Prefix
		}
		[void] $Rows.Add([pscustomobject]@{ path = $Path; mode = $Mode; blob = $Blob; size = $Size; selected = $Selected })
	}
	if (@($Rows | Where-Object { $_.path -ceq 'AethelnOnline.uproject' }).Count -ne 1) { throw 'managed_workspace_project_missing' }
	return ,@($Rows)
}

function Assert-ManagedWorkspaceFile {
	param([string] $Root, [object[]] $Tree, $Context, [switch] $VerifyBytes)
	$Total = 0L
	foreach ($Row in $Tree) {
		Assert-ManagedWorkspaceProgress -Context $Context
		$Path = Join-Path $Root $Row.path
		Assert-ManagedWorkspacePlainPath -Path $Path -Context $Context
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'managed_workspace_dirty' }
		if (-not $VerifyBytes) { continue }
		# Raw-byte comparison does not trust assume-unchanged/skip-worktree or a
		# clean filter's claim. Managed workspaces use byte-preserving checkout.
		$Pointer = $null
		if ($Row.size -le 1024) {
			$BlobText = Invoke-ManagedWorkspaceGit -Root $Root -Arguments ('cat-file blob ' + $Row.blob) -Context $Context
			if ($BlobText.StartsWith('version https://git-lfs.github.com/spec/v1')) {
				if ($BlobText -cnotmatch '\Aversion https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize (0|[1-9][0-9]{0,11})\n\z') { throw 'managed_workspace_lfs_pointer_invalid' }
				$Pointer = @{ oid = $Matches[1]; size = [long] $Matches[2] }
			}
		}
		$Stream = $null; $Sha1 = $null; $Sha256 = $null
		try {
			$Handle = [Aetheln.ManagedWorkspaceGit]::OpenPlain($Path, $false)
			try { $Stream = New-Object IO.FileStream($Handle, [IO.FileAccess]::Read) } catch { $Handle.Dispose(); throw }
			$Total += $Stream.Length
			if ($Stream.Length -gt 2GB -or $Total -gt 8GB) { throw 'managed_workspace_input_limit' }
			$Sha1 = [Security.Cryptography.SHA1]::Create(); $Sha256 = [Security.Cryptography.SHA256]::Create()
			$Header = [Text.Encoding]::ASCII.GetBytes('blob ' + $Stream.Length + [char]0)
			$null = $Sha1.TransformBlock($Header, 0, $Header.Length, $Header, 0)
			$Buffer = New-Object byte[] 65536
			while (($Count = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
				$null = $Sha1.TransformBlock($Buffer, 0, $Count, $Buffer, 0)
				$null = $Sha256.TransformBlock($Buffer, 0, $Count, $Buffer, 0)
				Assert-ManagedWorkspaceProgress -Context $Context
			}
			$null = $Sha1.TransformFinalBlock(@(), 0, 0); $null = $Sha256.TransformFinalBlock(@(), 0, 0)
			$ActualBlob = ([BitConverter]::ToString($Sha1.Hash)).Replace('-', '').ToLowerInvariant()
			$ActualOid = ([BitConverter]::ToString($Sha256.Hash)).Replace('-', '').ToLowerInvariant()
			if ($null -ne $Pointer) {
				# Preparation hydrates compile inputs, not unrelated rendered docs.
				# An unchanged pointer outside that set is clean Git materialization;
				# selected inputs always require the actual OID-bound payload bytes.
				$UnselectedPointer = (-not $Row.selected -and $ActualBlob -ceq $Row.blob)
				if (-not $UnselectedPointer -and ($Stream.Length -ne $Pointer.size -or $ActualOid -cne $Pointer.oid)) { throw 'managed_workspace_lfs_hydration_required' }
			} elseif ($ActualBlob -cne $Row.blob) { throw 'managed_workspace_dirty' }
			if ($Row.path -imatch '\.u(project|plugin)$') {
				if ($Stream.Length -gt 65536) { throw 'managed_workspace_descriptor_limit' }
				$Stream.Position = 0
				$Bytes = New-Object byte[] ([int] $Stream.Length)
				if ($Stream.Read($Bytes, 0, $Bytes.Length) -ne $Bytes.Length) { throw 'managed_workspace_descriptor_invalid' }
				$Descriptor = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes)
				$Parsed = $Descriptor | ConvertFrom-Json
				if ($Parsed -isnot [Management.Automation.PSCustomObject]) { throw 'managed_workspace_descriptor_invalid' }
				foreach ($Key in [regex]::Matches($Descriptor, '"(?<key>(?:[^"\\]|\\.)*)"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(50))) {
					$Name = $Key.Groups['key'].Value
					if ($Name.Contains('\') -or $Name -in @('AdditionalRootDirectories', 'AdditionalPluginDirectories')) { throw 'managed_workspace_external_descriptor_root' }
				}
			}
		} finally {
			if ($null -ne $Stream) { $Stream.Dispose() }
			if ($null -ne $Sha1) { $Sha1.Dispose() }; if ($null -ne $Sha256) { $Sha256.Dispose() }
		}
	}
}

function Assert-ManagedWorkspaceIndex {
	param([string] $Root, [object[]] $Tree, $Context)
	$Expected = New-Object Text.StringBuilder
	foreach ($Row in $Tree) { [void] $Expected.Append($Row.mode + ' ' + $Row.blob + " 0`t" + $Row.path + [char]0) }
	$Actual = Invoke-ManagedWorkspaceGit -Root $Root -Arguments 'ls-files --stage -z' -Context $Context
	if ($Actual -cne $Expected.ToString()) { throw 'managed_workspace_index_mismatch' }
}

function Sync-ManagedCompileWorkspace {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $ControlRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)][string] $SourceRevision, [Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string] $ExpectedGitCommonDirectory,
		[Parameter(Mandatory)][DateTime] $DeadlineUtc, [scriptblock] $OnProgress,
		[scriptblock] $AssertRepositoryTrust, [scriptblock] $RemainingBudget)
	$Started = [DateTime]::UtcNow
	$Context = @{ deadline = $DeadlineUtc.ToUniversalTime(); seconds = ($DeadlineUtc.ToUniversalTime() - $Started).TotalSeconds; clock = [Diagnostics.Stopwatch]::StartNew(); progress = $OnProgress; git = $null; pins = @{}; remainingBudget = $RemainingBudget; milliseconds = [double]::PositiveInfinity }
	try {
		if ($PSBoundParameters.ContainsKey('RemainingBudget') -and $null -eq $RemainingBudget) { throw 'compile_clock_invalid' }
		Assert-ManagedWorkspaceProgress -Context $Context
		if ($DeadlineUtc.Kind -ne [DateTimeKind]::Utc -or $SourceRevision -cnotmatch '\A[0-9a-f]{40}\z' -or $Repository -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z') { throw 'managed_workspace_identity_invalid' }
		Initialize-ManagedWorkspaceNative
		$ControlRoot = Get-ManagedWorkspaceRoot -Root $ControlRoot -Context $Context
		$TargetRoot = Get-ManagedWorkspaceRoot -Root $TargetRoot -Context $Context
		$ExpectedGitCommonDirectory = Get-ManagedWorkspaceRoot -Root $ExpectedGitCommonDirectory -Context $Context
		if ($ControlRoot.Equals($TargetRoot, [StringComparison]::OrdinalIgnoreCase) -or $ControlRoot.StartsWith($TargetRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $TargetRoot.StartsWith($ControlRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'managed_workspace_root_overlap' }
		# Procedural trusted-owner authorization is required for both existing
		# Git contexts, including normal hooks/filters. This is not certification
		# inferred from configuration, candidate data, or a repository-name string.
		if ($null -eq $AssertRepositoryTrust) { throw 'managed_workspace_trust_required' }
		$Trusted = & $AssertRepositoryTrust $ControlRoot $TargetRoot $Repository $SourceRevision
		if ($Trusted -isnot [bool] -or -not $Trusted) { throw 'managed_workspace_trust_required' }
		Assert-ManagedWorkspaceProgress -Context $Context
		$Context.git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
		foreach ($Root in @($ControlRoot, $TargetRoot)) {
			Assert-ManagedWorkspacePlainPath -Path (Join-Path $Root '.git') -Context $Context
			$Top = (Invoke-ManagedWorkspaceGit -Root $Root -Arguments 'rev-parse --show-toplevel' -Context $Context).Trim()
			if (-not [string]::Equals([IO.Path]::GetFullPath($Top).TrimEnd('\', '/'), $Root, [StringComparison]::OrdinalIgnoreCase)) { throw 'managed_workspace_root_invalid' }
		}
		$Common = (Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments 'rev-parse --path-format=absolute --git-common-dir' -Context $Context).Trim()
		if (-not [string]::Equals([IO.Path]::GetFullPath($Common).TrimEnd('\', '/'), $ExpectedGitCommonDirectory, [StringComparison]::OrdinalIgnoreCase)) { throw 'managed_workspace_common_directory_mismatch' }
		$ControlHead = (Invoke-ManagedWorkspaceGit -Root $ControlRoot -Arguments 'rev-parse --verify HEAD' -Context $Context).Trim()
		if ($ControlHead -cne $SourceRevision) { throw 'managed_workspace_revision_mismatch' }
		$OldHead = (Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments 'rev-parse --verify HEAD' -Context $Context).Trim()
		if ($OldHead -cnotmatch '^[0-9a-f]{40}$') { throw 'managed_workspace_revision_mismatch' }
		$Incoming = Get-ManagedWorkspaceTree -Root $ControlRoot -Revision $SourceRevision -Context $Context
		$Current = Get-ManagedWorkspaceTree -Root $TargetRoot -Revision $OldHead -Context $Context
		Assert-ManagedWorkspaceIndex -Root $ControlRoot -Tree $Incoming -Context $Context
		Assert-ManagedWorkspaceIndex -Root $TargetRoot -Tree $Current -Context $Context
		Assert-ManagedWorkspaceFile -Root $ControlRoot -Tree $Incoming -Context $Context
		Assert-ManagedWorkspaceFile -Root $TargetRoot -Tree $Current -Context $Context -VerifyBytes
		$Tracked = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Row in $Current) { $null = $Tracked.Add($Row.path) }
		foreach ($Row in $Incoming) {
			$Path = Join-Path $TargetRoot $Row.path
			Assert-ManagedWorkspacePlainPath -Path $Path -Context $Context
			if (-not $Tracked.Contains($Row.path) -and (Test-Path -LiteralPath $Path)) { throw 'managed_workspace_collision' }
			$Parent = Split-Path -Parent $Path
			while ($Parent.Length -gt $TargetRoot.Length) {
				if (Test-Path -LiteralPath $Parent -PathType Leaf) { throw 'managed_workspace_collision' }
				$Parent = Split-Path -Parent $Parent
			}
		}
		$Others = Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments 'ls-files --others -z -- ":(icase)Source" ":(icase)Config" ":(icase)Content" ":(icase)Plugins" ":(icase)Build" ":(icase)Platforms" ":(icase)AethelnOnline.uproject" ":(icase).gitattributes" ":(icase).gitmodules" ":(icase).lfsconfig" ":(exclude,icase,glob)**/Binaries/**" ":(exclude,icase,glob)**/Intermediate/**"' -Context $Context
		if ($Others.Length -ne 0) { throw 'managed_workspace_untracked_input' }
		$Imported = $false
		if ($OldHead -cne $SourceRevision) {
			$Exists = Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments ('rev-parse --verify ' + $SourceRevision + '^{commit}') -Context $Context -AllowMissing
			if ($null -eq $Exists) {
				$null = Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments ('fetch --no-tags --no-recurse-submodules "' + $ControlRoot + '" ' + $SourceRevision) -Context $Context
				$Imported = $true
			}
			# Managed workspaces are verified against raw Git blob bytes. Never let
			# a machine-level core.autocrlf setting rewrite tracked inputs while
			# advancing the prepared target to the candidate revision.
			$null = Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments ('-c core.autocrlf=false -c core.eol=lf checkout --detach ' + $SourceRevision) -Context $Context
		}
		$FinalHead = (Invoke-ManagedWorkspaceGit -Root $TargetRoot -Arguments 'rev-parse --verify HEAD' -Context $Context).Trim()
		if ($FinalHead -cne $SourceRevision) { throw 'managed_workspace_revision_mismatch' }
		Assert-ManagedWorkspaceIndex -Root $TargetRoot -Tree $Incoming -Context $Context
		Assert-ManagedWorkspaceFile -Root $TargetRoot -Tree $Incoming -Context $Context -VerifyBytes
		if ((Invoke-ManagedWorkspaceGit -Root $ControlRoot -Arguments 'rev-parse --verify HEAD' -Context $Context).Trim() -cne $SourceRevision) { throw 'managed_workspace_revision_mismatch' }
		Assert-ManagedWorkspaceProgress -Context $Context
		return [pscustomobject]@{ sourceRevision = $FinalHead; previousRevision = $OldHead; repository = $Repository; targetRoot = $TargetRoot; changed = ($OldHead -cne $FinalHead); imported = $Imported; elapsedSeconds = $Context.clock.Elapsed.TotalSeconds; selectedInputCount = @($Incoming | Where-Object { $_.selected }).Count }
	} catch {
		if ($_.Exception.Message -cmatch '^managed_workspace_[a-z_]+$' -or $_.Exception.Message -cin @('compile_timeout', 'compile_clock_invalid', 'resource_pressure', 'disk_floor_reached')) { throw }
		throw 'managed_workspace_failed'
	} finally { foreach ($Pin in $Context.pins.Values) { $Pin.Dispose() } }
}
