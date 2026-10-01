[CmdletBinding()]
param(
	[string] $RepositoryRoot,
	[string] $BaseRevision,
	[string] $HeadRevision,
	[string] $TestedRevision,
	[string] $ExpectedAcceptedBaseRevision,
	[string] $ExpectedPolicySha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ActivationPolicyLimit = 64KB
$script:ActivationOutputLimit = 64KB
$script:ActivationProcessOutputLimit = 8MB
$script:ActivationProcessErrorLimit = 64KB
$script:ActivationPolicyPath = 'scripts/ci/activation/ci-activation-policy.json'
$script:ActivationUtf8 = New-Object Text.UTF8Encoding($false, $true)
$script:ActivationUtf8NoBom = New-Object Text.UTF8Encoding($false)
$script:ActivationTrustedExecutables = $null

function Test-ActivationRevision {
	param($Value)
	return $Value -is [string] -and $Value -cmatch '\A[0-9a-f]{40}\z'
}

function Test-ActivationSha256 {
	param($Value)
	return $Value -is [string] -and $Value -cmatch '\A[0-9a-f]{64}\z'
}

function Assert-ActivationClosedObject {
	param($Value, [string[]] $Properties, [string] $Reason)
	if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw $Reason }
	$Actual = @($Value.PSObject.Properties.Name)
	if ($Actual.Count -ne $Properties.Count) { throw $Reason }
	foreach ($Property in $Properties) {
		if ($Actual -cnotcontains $Property) { throw $Reason }
	}
}

function Assert-ActivationSafePath {
	param($Value, [string] $Reason)
	if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 240 -or
		$Value -cnotmatch '\A[A-Za-z0-9._/-]+\z' -or $Value.StartsWith('/') -or
		$Value.EndsWith('/') -or $Value.Contains('//') -or $Value.Contains('..') -or
		$Value.Contains(':') -or $Value.Contains('\') -or
		$Value.Normalize([Text.NormalizationForm]::FormC) -cne $Value) {
		throw $Reason
	}
}

function Assert-ActivationJsonPropertyUniqueness {
	param([string] $Raw)
	$Scopes = New-Object Collections.Stack
	$PendingName = $null
	$Index = 0
	while ($Index -lt $Raw.Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index])
					$Index++
					if ($Index -ge $Raw.Length) { throw 'activation_policy_json_invalid' }
				}
				[void] $Builder.Append($Raw[$Index])
				$Index++
			}
			if ($Index -ge $Raw.Length) { throw 'activation_policy_json_invalid' }
			try { $PendingName = [string] (ConvertFrom-Json -InputObject ('"' + $Builder.ToString() + '"')) }
			catch { throw 'activation_policy_json_invalid' }
			$Index++
			continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)))
			$PendingName = $null
		}
		elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw 'activation_policy_json_invalid' }
			[void] $Scopes.Pop()
			$PendingName = $null
		}
		elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) {
				throw 'activation_policy_duplicate_property'
			}
			$PendingName = $null
		}
		elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw 'activation_policy_json_invalid' }
}

function Get-ActivationSha256 {
	param([byte[]] $Bytes)
	$Algorithm = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Algorithm.Dispose() }
}

function Assert-ActivationTrustedExecutable {
	param([string] $Path, [string] $Reason)
	if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw $Reason }
	$FullPath = [IO.Path]::GetFullPath($Path)
	if ($FullPath -cne $Path -or -not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { throw $Reason }
	$Current = Get-Item -LiteralPath $FullPath
	while ($null -ne $Current) {
		if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw $Reason }
		$Current = if ($Current -is [IO.FileInfo]) { $Current.Directory } else { $Current.Parent }
	}
	$Signature = Get-AuthenticodeSignature -LiteralPath $FullPath
	if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid) { throw $Reason }
	return [pscustomobject][ordered]@{ path=$FullPath; sha256=(Get-ActivationSha256 -Bytes ([IO.File]::ReadAllBytes($FullPath))) }
}

function Get-ActivationTrustedExecutables {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the closed Git and taskkill executable identity set.')]
	param()
	if ($null -ne $script:ActivationTrustedExecutables) { return $script:ActivationTrustedExecutables }
	$InstallPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($View in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
		$BaseKey = $null; $GitKey = $null
		try {
			$BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
			$GitKey = $BaseKey.OpenSubKey('SOFTWARE\GitForWindows', $false)
			if ($null -ne $GitKey) {
				$InstallPath = $GitKey.GetValue('InstallPath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
				if ($InstallPath -is [string] -and -not [string]::IsNullOrWhiteSpace($InstallPath)) { [void] $InstallPaths.Add([IO.Path]::GetFullPath($InstallPath)) }
			}
		} finally {
			if ($null -ne $GitKey) { $GitKey.Dispose() }
			if ($null -ne $BaseKey) { $BaseKey.Dispose() }
		}
	}
	if ($InstallPaths.Count -ne 1) { throw 'activation_git_identity_unavailable' }
	$GitPath = Join-Path @($InstallPaths)[0] 'cmd\git.exe'
	$TaskkillPath = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
	$Git = Assert-ActivationTrustedExecutable -Path $GitPath -Reason 'activation_git_identity_invalid'
	$Taskkill = Assert-ActivationTrustedExecutable -Path $TaskkillPath -Reason 'activation_taskkill_identity_invalid'
	$script:ActivationTrustedExecutables = [pscustomobject][ordered]@{ git=$Git; taskkill=$Taskkill }
	return $script:ActivationTrustedExecutables
}

function ConvertTo-ActivationProcessArgument {
	param([string] $Value)
	if ($Value.IndexOf([char] 0) -ge 0 -or $Value.Contains("`r") -or $Value.Contains("`n")) { throw 'activation_git_argument_invalid' }
	if ($Value -notmatch '[\s"]') { return $Value }
	return '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Initialize-ActivationGitRunner {
	if ('Aetheln.ActivationGitRunner' -as [type]) { return }
	$null = Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
namespace Aetheln {
 public sealed class ActivationGitResult { public int ExitCode; public byte[] Stdout; public byte[] Stderr; public string Failure; }
 public static class ActivationGitRunner {
  static byte[] ReadBounded(Stream stream, int limit, Action exceeded) {
   using (var value = new MemoryStream()) {
    var buffer = new byte[8192];
    while (true) {
     int read = stream.Read(buffer, 0, buffer.Length);
     if (read == 0) break;
     if (value.Length + read > limit) { exceeded(); throw new InvalidDataException("limit"); }
     value.Write(buffer, 0, read);
    }
    return value.ToArray();
   }
  }
  static bool KillTree(Process process, string taskkillPath) {
   try {
    if (process.HasExited) return true;
    var start = new ProcessStartInfo(taskkillPath, "/PID " + process.Id + " /T /F") {
     UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true
    };
    using (var killer = Process.Start(start)) {
     var output = killer.StandardOutput.ReadToEndAsync();
     var error = killer.StandardError.ReadToEndAsync();
     killer.WaitForExit(5000);
     try { Task.WaitAll(new Task[] { output, error }, 1000); } catch { }
    }
    return process.WaitForExit(5000);
   } catch {
    try { process.Kill(); return process.WaitForExit(5000); } catch { return false; }
   }
  }
  static void NeutralizeEnvironment(ProcessStartInfo start) {
   var exact = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH", "GIT_NAMESPACE", "GIT_REPLACE_REF_BASE",
    "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_CEILING_DIRECTORIES", "GIT_PREFIX", "GIT_IMPLICIT_WORK_TREE",
    "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_NO_REPLACE_OBJECTS",
    "GIT_EXEC_PATH", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_PAGER"
   };
   var keys = new List<string>();
   foreach (DictionaryEntry entry in start.EnvironmentVariables) keys.Add((string)entry.Key);
   foreach (var key in keys) {
    if (exact.Contains(key) || key.StartsWith("GIT_CONFIG_KEY_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("GIT_CONFIG_VALUE_", StringComparison.OrdinalIgnoreCase)) start.EnvironmentVariables.Remove(key);
   }
   start.EnvironmentVariables["GIT_CONFIG_NOSYSTEM"] = "1";
   start.EnvironmentVariables["GIT_CONFIG_GLOBAL"] = "NUL";
   start.EnvironmentVariables["GIT_CONFIG_SYSTEM"] = "NUL";
   start.EnvironmentVariables["GIT_ATTR_NOSYSTEM"] = "1";
   start.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0";
   start.EnvironmentVariables["GIT_OPTIONAL_LOCKS"] = "0";
   start.EnvironmentVariables["GIT_NO_REPLACE_OBJECTS"] = "1";
  }
  public static ActivationGitResult Run(string gitPath, string taskkillPath, string cwd, string arguments, int timeoutMs, int stdoutLimit, int stderrLimit) {
   var result = new ActivationGitResult();
   var sync = new object();
   bool overflow = false, cleanupFailed = false, timedOut = false;
   using (var process = new Process()) {
    var start = new ProcessStartInfo(gitPath, arguments) {
     WorkingDirectory=cwd, UseShellExecute=false, CreateNoWindow=true,
     RedirectStandardOutput=true, RedirectStandardError=true
    };
    NeutralizeEnvironment(start);
    process.StartInfo = start;
    try {
     if (!process.Start()) { result.Failure="activation_git_start_failed"; return result; }
    } catch { result.Failure="activation_git_start_failed"; return result; }
    Action exceeded = () => {
     bool first = false;
     lock (sync) { if (!overflow) { overflow=true; first=true; } }
     if (first && !KillTree(process, taskkillPath)) lock (sync) { cleanupFailed=true; }
    };
    var stdoutTask = Task.Factory.StartNew(() => ReadBounded(process.StandardOutput.BaseStream, stdoutLimit, exceeded));
    var stderrTask = Task.Factory.StartNew(() => ReadBounded(process.StandardError.BaseStream, stderrLimit, exceeded));
    if (!process.WaitForExit(timeoutMs)) {
     timedOut = true;
     if (!KillTree(process, taskkillPath)) cleanupFailed = true;
    }
    try { Task.WaitAll(new Task[] { stdoutTask, stderrTask }, 5000); } catch { }
    if (!stdoutTask.IsCompleted || !stderrTask.IsCompleted) cleanupFailed = true;
    if (cleanupFailed) result.Failure="activation_git_cleanup_failed";
    else if (overflow) result.Failure="activation_git_output_limit";
    else if (timedOut) result.Failure="activation_git_timeout";
    else if (stdoutTask.IsFaulted || stderrTask.IsFaulted) result.Failure="activation_git_stream_failed";
    result.Stdout = stdoutTask.Status == TaskStatus.RanToCompletion ? stdoutTask.Result : new byte[0];
    result.Stderr = stderrTask.Status == TaskStatus.RanToCompletion ? stderrTask.Result : new byte[0];
    try { result.ExitCode=process.ExitCode; } catch { result.ExitCode=-1; }
   }
   return result;
  }
 }
}
'@
}

function Invoke-ActivationGitBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the exact bounded stdout byte sequence.')]
	param(
		[Parameter(Mandatory)] [string] $Root,
		[Parameter(Mandatory)] [string[]] $Arguments,
		[ValidateRange(1, 120)] [int] $TimeoutSeconds = 30,
		[ValidateRange(1, 16777216)] [int] $MaximumBytes = $script:ActivationProcessOutputLimit,
		[ValidateRange(1, 1048576)] [int] $MaximumErrorBytes = $script:ActivationProcessErrorLimit
	)
	Initialize-ActivationGitRunner
	$Executables = Get-ActivationTrustedExecutables
	$GitArguments = @('--no-replace-objects','--no-optional-locks','--literal-pathspecs','-c','core.useReplaceRefs=false','-c','core.hooksPath=NUL','-c','core.fsmonitor=false','-c','diff.external=') + $Arguments
	$CommandLine = ($GitArguments | ForEach-Object { ConvertTo-ActivationProcessArgument ([string] $_) }) -join ' '
	$Result = [Aetheln.ActivationGitRunner]::Run($Executables.git.path, $Executables.taskkill.path, $Root, $CommandLine, $TimeoutSeconds * 1000, $MaximumBytes, $MaximumErrorBytes)
	if ($Result.Failure) { throw $Result.Failure }
	if ($Result.ExitCode -ne 0) {
		$Diagnostic = try { $script:ActivationUtf8.GetString($Result.Stderr) } catch { '<invalid-utf8>' }
		throw ('activation_git_failed:' + $Result.ExitCode + ':' + (($Diagnostic -replace '[\r\n]+', ' ').Trim()))
	}
	return ,$Result.Stdout
}

function Get-ActivationGitText {
	param([string] $Root, [string[]] $Arguments, [int] $MaximumBytes = 65536)
	$Bytes = Invoke-ActivationGitBytes -Root $Root -Arguments $Arguments -MaximumBytes $MaximumBytes
	try { return $script:ActivationUtf8.GetString($Bytes).TrimEnd("`r", "`n") }
	catch { throw 'activation_git_output_invalid' }
}

function Get-ActivationBlob {
	param([string] $Root, [string] $Revision, [string] $Path, [int] $MaximumBytes = $script:ActivationProcessOutputLimit)
	Assert-ActivationSafePath -Value $Path -Reason 'activation_path_invalid'
	$TreeText = Get-ActivationGitText -Root $Root -Arguments @('ls-tree', $Revision, '--', $Path)
	$Match = [regex]::Match($TreeText, '^100644 blob ([0-9a-f]{40,64})\t(.+)$')
	if (-not $Match.Success -or $Match.Groups[2].Value -cne $Path) { throw ('activation_blob_invalid:' + $Path) }
	$Bytes = Invoke-ActivationGitBytes -Root $Root -Arguments @('cat-file', 'blob', $Match.Groups[1].Value) -MaximumBytes $MaximumBytes
	return [pscustomobject][ordered]@{
		path = $Path
		blobOid = $Match.Groups[1].Value
		sha256 = Get-ActivationSha256 -Bytes $Bytes
		bytes = $Bytes
	}
}

function ConvertFrom-CiActivationPolicyBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Parses one policy from its exact accepted-base byte sequence.')]
	param([byte[]] $Bytes)
	if ($null -eq $Bytes -or $Bytes.Length -lt 1 -or $Bytes.Length -gt $script:ActivationPolicyLimit) { throw 'activation_policy_invalid' }
	try { $Raw = $script:ActivationUtf8.GetString($Bytes) }
	catch { throw 'activation_policy_invalid' }
	Assert-ActivationJsonPropertyUniqueness -Raw $Raw
	try { $Policy = ConvertFrom-Json -InputObject $Raw }
	catch { throw 'activation_policy_json_invalid' }
	Assert-ActivationClosedObject -Value $Policy -Properties @('schemaVersion','repository','policyPath','workflowPath','templatePath','pinnedFiles') -Reason 'activation_policy_schema_invalid'
	if ($Policy.schemaVersion -cne 'aetheln.ci-activation-policy/v1' -or $Policy.repository -isnot [string] -or $Policy.repository -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*\z') { throw 'activation_policy_schema_invalid' }
	Assert-ActivationSafePath -Value $Policy.policyPath -Reason 'activation_policy_schema_invalid'
	Assert-ActivationSafePath -Value $Policy.workflowPath -Reason 'activation_policy_schema_invalid'
	Assert-ActivationSafePath -Value $Policy.templatePath -Reason 'activation_policy_schema_invalid'
	if ($Policy.policyPath -cne $script:ActivationPolicyPath -or $Policy.policyPath -ceq $Policy.workflowPath -or $Policy.policyPath -ceq $Policy.templatePath -or
		$Policy.workflowPath -ceq $Policy.templatePath -or $Policy.pinnedFiles -isnot [array] -or
		$Policy.pinnedFiles.Count -lt 1 -or $Policy.pinnedFiles.Count -gt 32) { throw 'activation_policy_schema_invalid' }
	$Paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$PreviousPath = $null
	foreach ($PinnedFile in @($Policy.pinnedFiles)) {
		Assert-ActivationClosedObject -Value $PinnedFile -Properties @('path','sha256') -Reason 'activation_policy_schema_invalid'
		Assert-ActivationSafePath -Value $PinnedFile.path -Reason 'activation_policy_schema_invalid'
		if (-not (Test-ActivationSha256 $PinnedFile.sha256) -or -not $Paths.Add([string] $PinnedFile.path) -or $PinnedFile.path -ceq $Policy.workflowPath) { throw 'activation_policy_schema_invalid' }
		if ($null -ne $PreviousPath -and [StringComparer]::Ordinal.Compare($PreviousPath, [string] $PinnedFile.path) -ge 0) { throw 'activation_policy_not_sorted' }
		$PreviousPath = [string] $PinnedFile.path
	}
	if (-not $Paths.Contains([string] $Policy.templatePath)) { throw 'activation_policy_template_unpinned' }
	return $Policy
}

function Test-CiActivationCandidate {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $RepositoryRoot,
		[Parameter(Mandatory)] [string] $BaseRevision,
		[Parameter(Mandatory)] [string] $HeadRevision,
		[Parameter(Mandatory)] [string] $TestedRevision,
		[Parameter(Mandatory)] [string] $ExpectedAcceptedBaseRevision,
		[Parameter(Mandatory)] [string] $ExpectedPolicySha256
	)
	if (-not (Test-ActivationRevision $BaseRevision) -or -not (Test-ActivationRevision $HeadRevision) -or
		-not (Test-ActivationRevision $TestedRevision) -or -not (Test-ActivationRevision $ExpectedAcceptedBaseRevision) -or
		-not (Test-ActivationSha256 $ExpectedPolicySha256) -or $BaseRevision -ceq $HeadRevision) { throw 'activation_revision_invalid' }
	if ($BaseRevision -cne $ExpectedAcceptedBaseRevision) { throw 'activation_accepted_base_mismatch' }
	if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw 'activation_repository_missing' }
	$Root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
	try { $ResolvedBase = Get-ActivationGitText -Root $Root -Arguments @('rev-parse', ($BaseRevision + '^{commit}')) }
	catch { throw 'activation_revision_missing' }
	try { $ResolvedHead = Get-ActivationGitText -Root $Root -Arguments @('rev-parse', ($HeadRevision + '^{commit}')) }
	catch { throw 'activation_revision_missing' }
	try { $ResolvedTested = Get-ActivationGitText -Root $Root -Arguments @('rev-parse', ($TestedRevision + '^{commit}')) }
	catch { throw 'activation_revision_missing' }
	if ($ResolvedBase -cne $BaseRevision -or $ResolvedHead -cne $HeadRevision -or $ResolvedTested -cne $TestedRevision) { throw 'activation_revision_mismatch' }
	try { $MergeBase = Get-ActivationGitText -Root $Root -Arguments @('merge-base', $BaseRevision, $HeadRevision) }
	catch { throw 'activation_base_mismatch' }
	if ($MergeBase -cne $BaseRevision) { throw 'activation_base_mismatch' }
	$ParentLine = Get-ActivationGitText -Root $Root -Arguments @('rev-list', '--parents', '-n', '1', $TestedRevision)
	$ParentTokens = @($ParentLine.Split([char[]] @(' '), [StringSplitOptions]::RemoveEmptyEntries))
	if ($ParentTokens.Count -ne 3 -or $ParentTokens[0] -cne $TestedRevision -or
		$ParentTokens[1] -cne $BaseRevision -or $ParentTokens[2] -cne $HeadRevision) { throw 'activation_tested_parents_mismatch' }
	$HeadTree = Get-ActivationGitText -Root $Root -Arguments @('rev-parse', ($HeadRevision + '^{tree}'))
	$TestedTree = Get-ActivationGitText -Root $Root -Arguments @('rev-parse', ($TestedRevision + '^{tree}'))
	if ($HeadTree -cne $TestedTree) { throw 'activation_tested_tree_mismatch' }

	$BasePolicy = Get-ActivationBlob -Root $Root -Revision $BaseRevision -Path $script:ActivationPolicyPath -MaximumBytes $script:ActivationPolicyLimit
	$HeadPolicy = Get-ActivationBlob -Root $Root -Revision $HeadRevision -Path $script:ActivationPolicyPath -MaximumBytes $script:ActivationPolicyLimit
	if ($BasePolicy.sha256 -cne $ExpectedPolicySha256 -or $HeadPolicy.sha256 -cne $ExpectedPolicySha256 -or
		$BasePolicy.blobOid -cne $HeadPolicy.blobOid) { throw 'activation_policy_identity_mismatch' }
	$Policy = ConvertFrom-CiActivationPolicyBytes -Bytes $BasePolicy.bytes

	$ChangedBytes = Invoke-ActivationGitBytes -Root $Root -Arguments @('diff', '--name-only', '--no-renames', '--no-ext-diff', '--no-textconv', '-z', $BaseRevision, $HeadRevision)
	try { $ChangedRaw = $script:ActivationUtf8.GetString($ChangedBytes) }
	catch { throw 'activation_changed_paths_invalid' }
	$ChangedPaths = @($ChangedRaw.Split([char[]] @([char]0), [StringSplitOptions]::RemoveEmptyEntries))
	if ($ChangedPaths.Count -ne 1 -or $ChangedPaths[0] -cne $Policy.workflowPath) { throw 'activation_scope_invalid' }

	$Pinned = New-Object Collections.ArrayList
	foreach ($Expected in @($Policy.pinnedFiles)) {
		$BaseBlob = Get-ActivationBlob -Root $Root -Revision $BaseRevision -Path $Expected.path
		$HeadBlob = Get-ActivationBlob -Root $Root -Revision $HeadRevision -Path $Expected.path
		if ($BaseBlob.sha256 -cne $Expected.sha256 -or $HeadBlob.sha256 -cne $Expected.sha256 -or $BaseBlob.blobOid -cne $HeadBlob.blobOid) { throw ('activation_pinned_file_mismatch:' + $Expected.path) }
		[void] $Pinned.Add([pscustomobject][ordered]@{path=$Expected.path;blobOid=$BaseBlob.blobOid;sha256=$BaseBlob.sha256})
	}

	$Template = Get-ActivationBlob -Root $Root -Revision $BaseRevision -Path $Policy.templatePath
	$BaseWorkflow = Get-ActivationBlob -Root $Root -Revision $BaseRevision -Path $Policy.workflowPath
	$HeadWorkflow = Get-ActivationBlob -Root $Root -Revision $HeadRevision -Path $Policy.workflowPath
	if ($HeadWorkflow.sha256 -cne $Template.sha256 -or $HeadWorkflow.bytes.Length -ne $Template.bytes.Length -or
		[Convert]::ToBase64String($HeadWorkflow.bytes) -cne [Convert]::ToBase64String($Template.bytes)) { throw 'activation_template_mismatch' }
	if ($BaseWorkflow.sha256 -ceq $HeadWorkflow.sha256) { throw 'activation_candidate_noop' }

	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-activation-candidate/v1'
		repository = [string] $Policy.repository
		baseRevision = $BaseRevision
		expectedAcceptedBaseRevision = $ExpectedAcceptedBaseRevision
		headRevision = $HeadRevision
		testedRevision = $TestedRevision
		policySha256 = $BasePolicy.sha256
		executables = [pscustomobject][ordered]@{gitPath=$script:ActivationTrustedExecutables.git.path;gitSha256=$script:ActivationTrustedExecutables.git.sha256;taskkillPath=$script:ActivationTrustedExecutables.taskkill.path;taskkillSha256=$script:ActivationTrustedExecutables.taskkill.sha256}
		changedPaths = @($ChangedPaths)
		workflow = [pscustomobject][ordered]@{path=[string]$Policy.workflowPath;baseSha256=$BaseWorkflow.sha256;headSha256=$HeadWorkflow.sha256;templateSha256=$Template.sha256}
		pinnedFiles = @($Pinned)
		decision = [pscustomobject][ordered]@{complete=$true;approved=$true;reason='exact_accepted_template'}
	}
}

function ConvertTo-CiActivationCandidateReportBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the exact bounded byte sequence for one report.')]
	param($Report)
	$Bytes = $script:ActivationUtf8NoBom.GetBytes(($Report | ConvertTo-Json -Depth 8 -Compress) + "`n")
	if ($Bytes.Length -gt $script:ActivationOutputLimit) { throw 'activation_output_limit' }
	return ,$Bytes
}

if ($MyInvocation.InvocationName -ne '.') {
	$Report = Test-CiActivationCandidate -RepositoryRoot $RepositoryRoot -BaseRevision $BaseRevision -HeadRevision $HeadRevision -TestedRevision $TestedRevision -ExpectedAcceptedBaseRevision $ExpectedAcceptedBaseRevision -ExpectedPolicySha256 $ExpectedPolicySha256
	$Bytes = ConvertTo-CiActivationCandidateReportBytes -Report $Report
	$StandardOutput = [Console]::OpenStandardOutput()
	$StandardOutput.Write($Bytes, 0, $Bytes.Length)
	$StandardOutput.Flush()
}
