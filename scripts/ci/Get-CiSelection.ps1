[CmdletBinding()]
param(
	[string] $ContextJson,
	[string] $OutputPath,
	[string] $RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CiSelectionSchema = 'aetheln.ci-selection/v1'
$script:CiSelectionAttemptAnchorSchema = 'aetheln.current-attempt-anchor/v1'
$script:CiSelectionPolicyVersion = 'shadow-v1'
$script:CiSelectionCheckIds = @(
	'portable',
	'visual-package',
	'delivery-harness',
	'native-client-server-compile',
	'unreal-editor-automation',
	'content-reference-validation',
	'controller-contract',
	'controller-operational-proof',
	'clean-package-provenance-smoke'
)
$script:CiSelectionLimits = [ordered]@{
	gitOperationSeconds = 120
	rawBytes = 8MB
	stderrBytes = 64KB
	diffEntries = 4096
	treeEntries = 4096
	pathBytes = 4096
	reportBytes = 4MB
}
$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CiSelectionSourcePath = $PSCommandPath

function Assert-ClosedObject {
	param($Value, [string[]] $PropertyNames, [string] $Reason = 'context_schema_invalid')
	if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw $Reason }
	$Actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($Actual.Count -ne $PropertyNames.Count) { throw $Reason }
	foreach ($Name in $PropertyNames) { if ($Actual -cnotcontains $Name) { throw $Reason } }
}

function Assert-UniqueJsonProperties {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates every property scope in one JSON document.')]
	param([string] $Raw, [string] $Reason = 'context_schema_invalid')
	$Scopes = New-Object System.Collections.Stack
	$PendingName = $null
	$Index = 0
	while ($Index -lt $Raw.Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object System.Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index]); $Index++
					if ($Index -ge $Raw.Length) { throw $Reason }
				}
				[void] $Builder.Append($Raw[$Index]); $Index++
			}
			if ($Index -ge $Raw.Length) { throw $Reason }
			try { $PendingName = [string] (('"' + $Builder.ToString() + '"') | ConvertFrom-Json) } catch { throw $Reason }
			$Index++; continue
		}
		if ($Character -eq '{') { $Scopes.Push((New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))); $PendingName = $null }
		elseif ($Character -eq '}') { if ($Scopes.Count -eq 0) { throw $Reason }; [void] $Scopes.Pop(); $PendingName = $null }
		elseif ($Character -eq ':') { if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) { throw $Reason }; $PendingName = $null }
		elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') { $PendingName = $null }
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw $Reason }
}

function Test-Revision([object] $Value) {
	return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{40}$'
}

function Test-CiRunIdentity {
	param($Context)
	if ($Context.PSObject.Properties.Name -cnotcontains 'runId' -or $Context.runId -isnot [string] -or $Context.runId -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
	$ParsedRunId = [long] 0
	if (-not [long]::TryParse($Context.runId, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $ParsedRunId) -or $ParsedRunId -le 0) { return $false }
	if ($Context.PSObject.Properties.Name -cnotcontains 'runAttempt' -or ($Context.runAttempt -isnot [int] -and $Context.runAttempt -isnot [long]) -or [long] $Context.runAttempt -le 0) { return $false }
	return $true
}

function Assert-CiSelectionContext {
	param($Context)
	if ($null -eq $Context -or $Context -isnot [System.Management.Automation.PSCustomObject]) { throw 'context_schema_invalid' }
	if ($Context.PSObject.Properties.Name -cnotcontains 'kind' -or $Context.kind -isnot [string]) { throw 'context_schema_invalid' }
	switch -CaseSensitive ([string] $Context.kind) {
		'pull_request' {
			Assert-ClosedObject $Context @('kind', 'runId', 'runAttempt', 'baseRevision', 'headRevision', 'workflowRevision', 'controllerRevision')
			foreach ($Name in @('baseRevision', 'headRevision', 'workflowRevision', 'controllerRevision')) { if (-not (Test-Revision $Context.$Name)) { throw 'context_revision_invalid' } }
			if ($Context.baseRevision -ceq $Context.headRevision) { throw 'context_revision_relationship_invalid' }
			if ($Context.controllerRevision -cne $Context.baseRevision) { throw 'context_controller_not_accepted_base' }
		}
		'push' {
			Assert-ClosedObject $Context @('kind', 'runId', 'runAttempt', 'beforeRevision', 'afterRevision', 'controllerRevision')
			if (-not (Test-Revision $Context.afterRevision) -or -not (Test-Revision $Context.controllerRevision)) { throw 'context_revision_invalid' }
			if ($null -ne $Context.beforeRevision -and ($Context.beforeRevision -isnot [string] -or $Context.beforeRevision -notmatch '^[0-9a-f]{40}$')) { throw 'context_revision_invalid' }
			if ($Context.controllerRevision -cne $Context.afterRevision) { throw 'context_controller_revision_invalid' }
		}
		'schedule' {
			Assert-ClosedObject $Context @('kind', 'runId', 'runAttempt', 'revision', 'controllerRevision')
			if (-not (Test-Revision $Context.revision) -or $Context.controllerRevision -cne $Context.revision) { throw 'context_revision_invalid' }
		}
		'workflow_call' {
			Assert-ClosedObject $Context @('kind', 'runId', 'runAttempt', 'callerKind', 'baseRevision', 'headRevision', 'workflowRevision', 'revision', 'controllerRevision')
			if ($Context.callerKind -isnot [string] -or $Context.callerKind -cnotin @('pull_request', 'push', 'schedule')) { throw 'context_caller_invalid' }
			foreach ($Name in @('baseRevision', 'headRevision', 'workflowRevision', 'revision')) { if ($null -ne $Context.$Name -and -not (Test-Revision $Context.$Name)) { throw 'context_revision_invalid' } }
			if (-not (Test-Revision $Context.controllerRevision)) { throw 'context_revision_invalid' }
			switch ($Context.callerKind) {
				'pull_request' { if ($null -eq $Context.baseRevision -or $null -eq $Context.headRevision -or $null -eq $Context.workflowRevision -or $null -ne $Context.revision -or $Context.baseRevision -ceq $Context.headRevision -or $Context.controllerRevision -cne $Context.baseRevision) { throw 'context_revision_relationship_invalid' } }
				'push' { if ($null -eq $Context.baseRevision -or $null -eq $Context.headRevision -or $Context.workflowRevision -cne $Context.headRevision -or $null -ne $Context.revision -or $Context.controllerRevision -cne $Context.headRevision) { throw 'context_revision_relationship_invalid' } }
				'schedule' { if ($null -ne $Context.baseRevision -or $null -ne $Context.headRevision -or $null -eq $Context.revision -or $Context.workflowRevision -cne $Context.revision -or $Context.controllerRevision -cne $Context.revision) { throw 'context_revision_relationship_invalid' } }
			}
		}
		default { throw 'context_kind_unsupported' }
	}
	if (-not (Test-CiRunIdentity $Context)) { throw 'context_run_identity_invalid' }
	return $Context
}

function Assert-CiSelectionAttemptAnchor {
	param($AttemptAnchor, $Context)
	Assert-CiSelectionContext $Context | Out-Null
	Assert-ClosedObject -Value $AttemptAnchor -PropertyNames @('schemaVersion', 'runId', 'runAttempt', 'nonce') -Reason 'attempt_anchor_schema_invalid'
	if ($AttemptAnchor.schemaVersion -isnot [string] -or $AttemptAnchor.schemaVersion -cne $script:CiSelectionAttemptAnchorSchema) { throw 'attempt_anchor_schema_invalid' }
	if ($AttemptAnchor.runId -isnot [string] -or $AttemptAnchor.runId -cnotmatch '\A[1-9][0-9]{0,18}\z' -or ($AttemptAnchor.runAttempt -isnot [int] -and $AttemptAnchor.runAttempt -isnot [long]) -or [long] $AttemptAnchor.runAttempt -le 0) { throw 'attempt_anchor_run_identity_invalid' }
	if ($AttemptAnchor.nonce -isnot [string] -or $AttemptAnchor.nonce -cnotmatch '\A[0-9a-f]{64}\z' -or $AttemptAnchor.nonce -ceq ('0' * 64)) { throw 'attempt_anchor_nonce_invalid' }
	if ($AttemptAnchor.runId -cne $Context.runId -or [long] $AttemptAnchor.runAttempt -ne [long] $Context.runAttempt) { throw 'attempt_anchor_context_mismatch' }
	return $AttemptAnchor
}

function New-CiSelectionAttemptAnchor {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory current-attempt anchor and changes no external state.')]
	param($Context, [scriptblock] $TestRandomBytesProvider)
	Assert-CiSelectionContext $Context | Out-Null
	if ($null -ne $TestRandomBytesProvider) {
		try { $RandomBytes = & $TestRandomBytesProvider } catch { throw 'attempt_anchor_rng_failed' }
	} else {
		$RandomBytes = [byte[]]::new(32)
		$Generator = $null
		try {
			$Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
			$Generator.GetBytes($RandomBytes)
		} catch { throw 'attempt_anchor_rng_failed' }
		finally { if ($null -ne $Generator) { $Generator.Dispose() } }
	}
	if ($RandomBytes -isnot [byte[]] -or $RandomBytes.Length -ne 32) { throw 'attempt_anchor_rng_invalid' }
	$Nonce = [BitConverter]::ToString($RandomBytes).Replace('-', '').ToLowerInvariant()
	$AttemptAnchor = [pscustomobject][ordered]@{ schemaVersion=$script:CiSelectionAttemptAnchorSchema; runId=$Context.runId; runAttempt=[long]$Context.runAttempt; nonce=$Nonce }
	Assert-CiSelectionAttemptAnchor $AttemptAnchor $Context | Out-Null
	return $AttemptAnchor
}

function ConvertTo-ProcessArgument([string] $Value) {
	if ($Value -notmatch '[\s"]') { return $Value }
	return '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Initialize-CiGitRunner {
	if ('Aetheln.CiGitRunner' -as [type]) { return }
	$null = Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
namespace Aetheln {
 public sealed class CiGitResult { public int ExitCode; public byte[] Stdout; public byte[] Stderr; public string Failure; }
 public static class CiGitRunner {
  static byte[] ReadBounded(Stream stream, int limit, Action overflow) {
   using (var value = new MemoryStream()) {
    var buffer = new byte[8192];
    while (true) { int read = stream.Read(buffer, 0, buffer.Length); if (read == 0) break; if (value.Length + read > limit) { overflow(); throw new InvalidDataException("limit"); } value.Write(buffer, 0, read); }
    return value.ToArray();
   }
  }
  static void KillTree(Process process) {
   try { if (!process.HasExited) { using (var killer = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + process.Id + " /T /F") { UseShellExecute=false, CreateNoWindow=true })) { killer.WaitForExit(5000); } } } catch { try { process.Kill(); } catch {} }
  }
  public static CiGitResult Run(string cwd, string arguments, byte[] input, int timeoutMs, int stdoutLimit, int stderrLimit) {
   var result = new CiGitResult(); var sync = new object(); bool overflow = false;
   using (var process = new Process()) {
    process.StartInfo = new ProcessStartInfo("git.exe", arguments) { WorkingDirectory=cwd, UseShellExecute=false, CreateNoWindow=true, RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true };
    process.StartInfo.EnvironmentVariables["GIT_ATTR_NOSYSTEM"] = "1";
    process.Start();
    Action exceeded = () => { lock(sync) { overflow = true; } KillTree(process); };
    var stdoutTask = Task.Factory.StartNew(() => ReadBounded(process.StandardOutput.BaseStream, stdoutLimit, exceeded));
    var stderrTask = Task.Factory.StartNew(() => ReadBounded(process.StandardError.BaseStream, stderrLimit, exceeded));
    var stdinTask = Task.Factory.StartNew(() => { try { if (input != null && input.Length != 0) process.StandardInput.BaseStream.Write(input, 0, input.Length); } finally { process.StandardInput.Close(); } });
    if (!process.WaitForExit(timeoutMs)) { KillTree(process); result.Failure="git_timeout"; }
    try { Task.WaitAll(new Task[] { stdinTask, stdoutTask, stderrTask }, 5000); } catch { }
    if (result.Failure == null && overflow) result.Failure="git_output_limit";
    if (result.Failure == null && (!stdinTask.IsCompleted || !stdoutTask.IsCompleted || !stderrTask.IsCompleted)) result.Failure="git_cleanup_failed";
    if (result.Failure == null && stdinTask.IsFaulted) result.Failure="git_stdin_failed";
    if (stdoutTask.Status == TaskStatus.RanToCompletion) result.Stdout=stdoutTask.Result; else result.Stdout=new byte[0];
    if (stderrTask.Status == TaskStatus.RanToCompletion) result.Stderr=stderrTask.Result; else result.Stderr=new byte[0];
    try { result.ExitCode=process.ExitCode; } catch { result.ExitCode=-1; }
   }
   return result;
  }
 }
}
'@
}

function Invoke-BoundedGitBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The contract returns an exact byte sequence, not one byte.')]
	param(
		[Parameter(Mandatory)] [string] $Repository,
		[Parameter(Mandatory)] [string[]] $Arguments,
		[byte[]] $InputBytes = $null,
		[int] $StdoutLimit = $script:CiSelectionLimits.rawBytes,
		[int] $StderrLimit = $script:CiSelectionLimits.stderrBytes,
		[int] $TimeoutSeconds = $script:CiSelectionLimits.gitOperationSeconds
	)
	Initialize-CiGitRunner
	if ($null -ne $InputBytes -and $InputBytes.Length -gt $script:CiSelectionLimits.rawBytes) { throw 'git_input_limit' }
	$EmptyAttributes = Join-Path ([IO.Path]::GetTempPath()) 'aetheln-empty-attributes'
	if (-not (Test-Path -LiteralPath $EmptyAttributes -PathType Leaf)) { [IO.File]::WriteAllBytes($EmptyAttributes, [byte[]]@()) }
	$All = @('-C', $Repository, '-c', "core.attributesFile=$EmptyAttributes") + $Arguments
	$CommandLine = ($All | ForEach-Object { ConvertTo-ProcessArgument ([string] $_) }) -join ' '
	$Result = [Aetheln.CiGitRunner]::Run($Repository, $CommandLine, $InputBytes, $TimeoutSeconds * 1000, $StdoutLimit, $StderrLimit)
	if ($Result.Failure) { throw $Result.Failure }
	if ($Result.ExitCode -ne 0) {
		$Diagnostic = try { $script:StrictUtf8.GetString($Result.Stderr) } catch { '<invalid-utf8>' }
		throw ('git_failed:' + (($Diagnostic -replace '[\r\n]+', ' ').Trim()))
	}
	return $Result
}

function Split-NulBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns all byte records from one NUL stream.')]
	param([byte[]] $Bytes)
	$Values = New-Object System.Collections.Generic.List[byte[]]
	$Start = 0
	for ($Index = 0; $Index -lt $Bytes.Length; $Index++) {
		if ($Bytes[$Index] -eq 0) {
			$Length = $Index - $Start; $Part = New-Object byte[] $Length
			if ($Length -gt 0) { [Array]::Copy($Bytes, $Start, $Part, 0, $Length) }
			$Values.Add($Part); $Start = $Index + 1
		}
	}
	if ($Start -ne $Bytes.Length) { throw 'nul_stream_truncated' }
	return ,$Values.ToArray()
}

function Convert-StrictPath([byte[]] $Bytes) {
	if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $script:CiSelectionLimits.pathBytes -or [Array]::IndexOf($Bytes, [byte] 0) -ge 0) { throw 'path_invalid' }
	try { return $script:StrictUtf8.GetString($Bytes) } catch { throw 'path_utf8_invalid' }
}

function ConvertFrom-GitRawZ {
	param([byte[]] $Bytes)
	$Tokens = Split-NulBytes $Bytes
	$Entries = New-Object System.Collections.Generic.List[object]
	$Index = 0
	while ($Index -lt $Tokens.Count) {
		if ($Tokens[$Index].Length -eq 0) { if ($Index -eq $Tokens.Count - 1) { break }; throw 'diff_record_empty' }
		try { $Header = $script:StrictUtf8.GetString($Tokens[$Index]) } catch { throw 'diff_header_utf8_invalid' }
		$Match = [regex]::Match($Header, '^:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMDTC]|[MRC][0-9]{1,3})$')
		if (-not $Match.Success) { throw 'diff_record_invalid' }
		$Status = $Match.Groups[5].Value.Substring(0, 1)
		$Score = if ($Match.Groups[5].Value.Length -gt 1) { [int] $Match.Groups[5].Value.Substring(1) } else { $null }
		if ($null -ne $Score -and ($Score -lt 0 -or $Score -gt 100)) { throw 'diff_score_invalid' }
		if ($Status -notin @('R', 'C') -and $Match.Groups[5].Value.Length -gt 1 -and $Status -ne 'M') { throw 'diff_score_invalid' }
		$Index++; if ($Index -ge $Tokens.Count) { throw 'diff_path_missing' }
		$OldPath = Convert-StrictPath $Tokens[$Index]; $Index++
		$NewPath = $OldPath
		if ($Status -in @('R', 'C')) { if ($Index -ge $Tokens.Count) { throw 'diff_path_missing' }; $NewPath = Convert-StrictPath $Tokens[$Index]; $Index++ }
		$OldMode = $Match.Groups[1].Value; $NewMode = $Match.Groups[2].Value; $OldOid = $Match.Groups[3].Value; $NewOid = $Match.Groups[4].Value
		$Zero = '0000000000000000000000000000000000000000'
		if (($Status -eq 'A' -and ($OldMode -ne '000000' -or $OldOid -ne $Zero -or $NewMode -eq '000000' -or $NewOid -eq $Zero)) -or
			($Status -eq 'D' -and ($NewMode -ne '000000' -or $NewOid -ne $Zero -or $OldMode -eq '000000' -or $OldOid -eq $Zero)) -or
			($Status -notin @('A','D') -and ($OldMode -eq '000000' -or $NewMode -eq '000000' -or $OldOid -eq $Zero -or $NewOid -eq $Zero))) { throw 'diff_sentinel_invalid' }
		$Entries.Add([pscustomobject][ordered]@{ status=$Status; score=$Score; oldMode=$OldMode; newMode=$NewMode; oldOid=$OldOid; newOid=$NewOid; oldPath=$OldPath; newPath=$NewPath })
		if ($Entries.Count -gt $script:CiSelectionLimits.diffEntries) { throw 'diff_entry_limit' }
	}
	return $Entries.ToArray()
}

function Get-TrackedTreeEntries {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the complete bounded tree entry set.')]
	param([string] $Repository, [string] $Revision)
	$Raw = (Invoke-BoundedGitBytes $Repository @('ls-tree', '-r', '-z', '--full-tree', $Revision)).Stdout
	$Tokens = Split-NulBytes $Raw; $Entries = New-Object System.Collections.Generic.List[object]
	foreach ($Token in $Tokens) {
		if ($Token.Length -eq 0) { continue }
		try { $Text = $script:StrictUtf8.GetString($Token) } catch { throw 'tree_utf8_invalid' }
		$Match = [regex]::Match($Text, '^([0-7]{6}) (blob|commit) ([0-9a-f]{40})\t([\s\S]+)$')
		if (-not $Match.Success) { throw 'tree_record_invalid' }
		$PathBytes = $script:StrictUtf8.GetBytes($Match.Groups[4].Value)
		if ($PathBytes.Length -gt $script:CiSelectionLimits.pathBytes) { throw 'path_limit' }
		$Entries.Add([pscustomobject][ordered]@{ mode=$Match.Groups[1].Value; type=$Match.Groups[2].Value; oid=$Match.Groups[3].Value; path=$Match.Groups[4].Value })
		if ($Entries.Count -gt $script:CiSelectionLimits.treeEntries) { throw 'tree_entry_limit' }
	}
	return $Entries.ToArray()
}

function Test-WindowsCheckoutPath {
	param([string] $Path)
	if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 260 -or $Path.StartsWith('/') -or $Path.StartsWith('\') -or $Path -match '^[A-Za-z]:' -or $Path.Contains('\')) { return $false }
	$Components = $Path.Split('/')
	foreach ($Component in $Components) {
		if ([string]::IsNullOrEmpty($Component) -or $Component -in @('.', '..') -or $Component.Length -gt 255 -or $Component.EndsWith('.') -or $Component.EndsWith(' ')) { return $false }
		if ($Component.IndexOfAny([char[]]@(':','*','?','"','<','>','|')) -ge 0) { return $false }
		foreach ($Character in $Component.ToCharArray()) { if ([int] $Character -lt 32) { return $false } }
		$Stem = $Component.Split('.')[0]
		if ($Stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $Component -match '^(?i:\.git|git~1)(?:\.|$)') { return $false }
		if ($Stem.Length -eq 4 -and $Stem.Substring(0, 3) -in @('COM', 'com', 'LPT', 'lpt') -and $Stem[3] -in @([char] 0xB9, [char] 0xB2, [char] 0xB3)) { return $false }
	}
	return $true
}

function Test-WindowsCheckoutTree {
	param([object[]] $Entries)
	if ($Entries.Count -gt $script:CiSelectionLimits.treeEntries) { throw 'tree_entry_limit' }
	$Case = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Normalized = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Entry in $Entries) {
		if ($Entry.type -eq 'commit' -or $Entry.mode -eq '120000') { throw 'checkout_unsupported_entry' }
		if ($Entry.type -ne 'blob' -or $Entry.mode -notin @('100644','100755')) { throw 'checkout_unsupported_mode' }
		if (-not (Test-WindowsCheckoutPath $Entry.path)) { throw 'checkout_path_unsafe' }
		if (-not $Case.Add($Entry.path)) { throw 'checkout_case_collision' }
		$Nfc = $Entry.path.Normalize([Text.NormalizationForm]::FormC)
		if (-not $Normalized.Add($Nfc)) { throw 'checkout_unicode_collision' }
	}
	return $true
}

function Get-RevisionAttributes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Git evaluates the closed attribute tuple for every supplied path.')]
	param([string] $Repository, [string] $Revision, [string[]] $Paths)
	$GitPathRaw = (Invoke-BoundedGitBytes -Repository $Repository -Arguments @('rev-parse', '--git-path', 'info/attributes') -StdoutLimit 16KB).Stdout
	try { $GitPath = $script:StrictUtf8.GetString($GitPathRaw).Trim() } catch { throw 'git_path_utf8_invalid' }
	$InfoAttributes = if ([IO.Path]::IsPathRooted($GitPath)) { $GitPath } else { Join-Path $Repository $GitPath }
	if (Test-Path -LiteralPath $InfoAttributes -PathType Leaf) { throw 'repository_info_attributes_present' }
	if ($Paths.Count -eq 0) { return @{} }
	$InputStream = New-Object System.IO.MemoryStream
	foreach ($Path in $Paths) { $Bytes = $script:StrictUtf8.GetBytes($Path); $InputStream.Write($Bytes,0,$Bytes.Length); $InputStream.WriteByte(0) }
	$Raw = (Invoke-BoundedGitBytes -Repository $Repository -Arguments @('check-attr', "--source=$Revision", '--stdin', '-z', 'filter', 'diff', 'merge', 'text') -InputBytes $InputStream.ToArray()).Stdout
	$Tokens = Split-NulBytes $Raw
	if (($Tokens.Count % 3) -ne 0) { throw 'attribute_record_invalid' }
	$Result = @{}
	for ($Index=0; $Index -lt $Tokens.Count; $Index += 3) {
		if ($Tokens[$Index].Length -eq 0) { continue }
		$Path = Convert-StrictPath $Tokens[$Index]
		try { $Name=$script:StrictUtf8.GetString($Tokens[$Index+1]); $Value=$script:StrictUtf8.GetString($Tokens[$Index+2]) } catch { throw 'attribute_utf8_invalid' }
		if ($Name -notin @('filter','diff','merge','text')) { throw 'attribute_name_invalid' }
		if (-not $Result.ContainsKey($Path)) { $Result[$Path] = [ordered]@{} }
		$Result[$Path][$Name] = $Value
	}
	foreach ($Path in $Paths) { if (-not $Result.ContainsKey($Path) -or $Result[$Path].Count -ne 4) { throw 'attribute_incomplete' } }
	return $Result
}

function Get-ControllerIdentity {
	param([string] $Repository, [string] $Revision)
	$Path = 'scripts/ci/Get-CiSelection.ps1'
	$OidRaw = (Invoke-BoundedGitBytes $Repository @('rev-parse', "$Revision`:$Path") -StdoutLimit 1024).Stdout
	try { $Oid = $script:StrictUtf8.GetString($OidRaw).Trim() } catch { throw 'controller_oid_utf8_invalid' }
	if ($Oid -cnotmatch '^[0-9a-f]{40}$') { throw 'controller_oid_invalid' }
	$Bytes = (Invoke-BoundedGitBytes $Repository @('cat-file', 'blob', $Oid) -StdoutLimit $script:CiSelectionLimits.reportBytes).Stdout
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { $Sha256 = ([BitConverter]::ToString($Hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $Hash.Dispose() }
	return [pscustomobject][ordered]@{ oid=$Oid; sha256=$Sha256 }
}

function Get-PathCheckSelection {
	param([string] $Path, [hashtable] $Attributes)
	$Ids = New-Object System.Collections.Generic.List[string]
	$Ids.Add('portable')
	$Recognized = $false
	$PortableOnlyPaths = @(
		'scripts/ci/Invoke-CiSuite.ps1',
		'scripts/ci/Test-FormattingPolicy.ps1',
		'scripts/ci/Test-MarkdownLinks.ps1'
	)
	if ($PortableOnlyPaths -ccontains $Path -or $Path -cmatch '^docs/.+' -or $Path -cmatch '^output/pdf/.+' -or
		$Path -cmatch '^tests/.+\.(ps1|md)$' -or $Path -cmatch '^[^/]+\.md$' -or
		$Path -cmatch '^\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)/[^/]+\.(md|yml|yaml)$' -or
		$Path -cmatch '^\.github/(PULL_REQUEST_TEMPLATE|pull_request_template)\.md$') { $Recognized = $true }
	if ($Path -ceq '.gitattributes' -or $Path.EndsWith('/.gitattributes', [StringComparison]::Ordinal)) { $Ids.Add('controller-contract'); $Ids.Add('controller-operational-proof'); $Recognized = $true }
	if ($Path.StartsWith('visuals/', [StringComparison]::Ordinal)) { $Ids.Add('visual-package'); $Recognized = $true }
	if ($Path -ceq 'scripts/ci/Invoke-VisualPackageValidation.ps1') { $Ids.Add('visual-package'); $Recognized = $true }
	if ($Path.StartsWith('.agents/', [StringComparison]::Ordinal) -or $Path.StartsWith('tests/build/', [StringComparison]::Ordinal)) { $Ids.Add('delivery-harness'); $Recognized = $true }
	if ($Path -match '^(Source|Config|Content|Plugins)/' -or $Path -eq 'AethelnOnline.uproject') {
		$Ids.Add('native-client-server-compile'); $Ids.Add('unreal-editor-automation'); $Recognized = $true
	}
	if ($Path.StartsWith('Content/', [StringComparison]::Ordinal) -or $Path.StartsWith('Config/', [StringComparison]::Ordinal) -or $Path -cmatch '^Plugins/[^/]+/Content/.+') { $Ids.Add('content-reference-validation') }
	if ($Path.StartsWith('.github/workflows/', [StringComparison]::Ordinal) -or $Path.StartsWith('scripts/ci/', [StringComparison]::Ordinal) -or $Path.StartsWith('tests/ci/', [StringComparison]::Ordinal)) { $Ids.Add('controller-contract'); $Recognized = $true }
	if ($Path.StartsWith('.github/workflows/', [StringComparison]::Ordinal) -or $Path.StartsWith('scripts/ci/', [StringComparison]::Ordinal)) { $Ids.Add('controller-operational-proof') }
	if ($Path.StartsWith('scripts/build/', [StringComparison]::Ordinal) -or $Path -in @('scripts/ci/Invoke-EngineRunnerGate.ps1','scripts/ci/Initialize-CompileWorkspace.ps1')) { $Ids.Add('controller-operational-proof'); $Ids.Add('clean-package-provenance-smoke'); $Ids.Add('delivery-harness'); $Recognized = $true }
	if ($null -ne $Attributes -and $Attributes.ContainsKey('filter') -and $Attributes.filter -eq 'lfs') {
		if ($Path.StartsWith('Content/', [StringComparison]::Ordinal)) { $Ids.Add('content-reference-validation'); $Ids.Add('native-client-server-compile') }
		elseif ($Path -cmatch '^Plugins/[^/]+/Content/.+') { $Ids.Add('content-reference-validation'); $Ids.Add('native-client-server-compile') }
		elseif ($Path.StartsWith('visuals/', [StringComparison]::Ordinal)) { $Ids.Add('visual-package') }
	}
	if (-not $Recognized) { throw 'path_unclassified' }
	return @($Ids | Sort-Object -Unique)
}

function Get-PolicyDigest {
	if ([string]::IsNullOrWhiteSpace($script:CiSelectionSourcePath) -or -not (Test-Path -LiteralPath $script:CiSelectionSourcePath -PathType Leaf)) { throw 'policy_source_unavailable' }
	try { $Source = $script:StrictUtf8.GetString([IO.File]::ReadAllBytes($script:CiSelectionSourcePath)) } catch { throw 'policy_source_invalid' }
	$Canonical = $Source.Replace("`r`n", "`n").Replace("`r", "`n")
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hash.ComputeHash($script:Utf8NoBom.GetBytes($Canonical))).Replace('-','').ToLowerInvariant()) } finally { $Hash.Dispose() }
}

function New-Obligations {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The report always contains the complete closed obligation set.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory report value and changes no external state.')]
	param([hashtable] $Selected, [string] $FallbackReason)
	$Values = New-Object System.Collections.Generic.List[object]
	foreach ($Id in $script:CiSelectionCheckIds) {
		$Reasons = @(if ($Selected.ContainsKey($Id)) { $Selected[$Id] | Sort-Object -Unique } elseif ($FallbackReason) { $FallbackReason })
		$Values.Add([pscustomobject][ordered]@{ id=$Id; selected=($Reasons.Count -gt 0); reasons=$Reasons })
	}
	return $Values.ToArray()
}

function New-ConservativeSelection {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory report value and changes no external state.')]
	param([string] $Reason, $Context, $LegacyEngineRequired = $null, [string] $LegacyReason = 'not_observed', $AttemptAnchor = $null)
	Assert-CiSelectionContext $Context | Out-Null
	if ($null -eq $AttemptAnchor) { $AttemptAnchor = New-CiSelectionAttemptAnchor $Context }
	else { Assert-CiSelectionAttemptAnchor $AttemptAnchor $Context | Out-Null }
	$All = @{}; foreach ($Id in $script:CiSelectionCheckIds) { $All[$Id] = @($Reason) }
	$Kind = [string] $Context.kind
	$Controller = [string] $Context.controllerRevision
	$ExecutionMode = if ($Reason -eq 'accepted_controller_unavailable') { 'accepted_controller_unavailable' } else { 'accepted-base' }
	$Source = [ordered]@{ kind=$Kind; callerKind=$null; baseRevision=$null; headRevision=$null; workflowRevision=$null; revision=$null }
	if ($null -ne $Context) {
		if ($Context.PSObject.Properties.Name -ccontains 'callerKind') { $Source.callerKind=$Context.callerKind }
		if ($Context.PSObject.Properties.Name -ccontains 'baseRevision') { $Source.baseRevision=$Context.baseRevision }
		elseif ($Context.PSObject.Properties.Name -ccontains 'beforeRevision') { $Source.baseRevision=$Context.beforeRevision }
		if ($Context.PSObject.Properties.Name -ccontains 'headRevision') { $Source.headRevision=$Context.headRevision }
		elseif ($Context.PSObject.Properties.Name -ccontains 'afterRevision') { $Source.headRevision=$Context.afterRevision }
		if ($Context.PSObject.Properties.Name -ccontains 'workflowRevision') { $Source.workflowRevision=$Context.workflowRevision }
		if ($Context.PSObject.Properties.Name -ccontains 'revision') { $Source.revision=$Context.revision }
	}
	return [pscustomobject][ordered]@{
		schemaVersion=$script:CiSelectionSchema
		attemptAnchor=$AttemptAnchor
		policy=[pscustomobject][ordered]@{ version=$script:CiSelectionPolicyVersion; digest=(Get-PolicyDigest); checkIds=@($script:CiSelectionCheckIds) }
		source=[pscustomobject]$Source
		execution=[pscustomobject][ordered]@{ mode=$ExecutionMode; controllerRevision=$Controller; controllerBlobOid=$null; controllerSha256=$null; checkoutAllowed=$false; complete=$true; reason=$Reason }
		classification=[pscustomobject][ordered]@{ changedPaths=@(); entries=@(); uncertainties=@($Reason) }
		selection=[pscustomobject][ordered]@{ shadow=$true; authoritative=$false; obligations=(New-Obligations $All $Reason) }
		legacyAuthority=[pscustomobject][ordered]@{ authoritative=$true; engineRequired=$LegacyEngineRequired; reason=$LegacyReason }
		comparison=[pscustomobject][ordered]@{ status='uncertain'; differences=@($Reason) }
	}
}

function New-CiSelectionReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory report value and changes no external state.')]
	param($Context, [string] $Repository, $LegacyEngineRequired = $null, [string] $LegacyReason = 'not_observed', $AttemptAnchor = $null)
	Assert-CiSelectionContext $Context | Out-Null
	if ($null -eq $AttemptAnchor) { $AttemptAnchor = New-CiSelectionAttemptAnchor $Context }
	else { Assert-CiSelectionAttemptAnchor $AttemptAnchor $Context | Out-Null }
	$ControllerIdentity = Get-ControllerIdentity $Repository $Context.controllerRevision
	if ($Context.kind -eq 'schedule' -or ($Context.kind -eq 'workflow_call' -and $Context.callerKind -eq 'schedule')) {
		$Revision = if ($Context.kind -eq 'schedule') { $Context.revision } else { $Context.revision }
		$CallerKind = if ($Context.kind -eq 'workflow_call') { $Context.callerKind } else { $null }
		$Selected=@{ portable=@('scheduled_event'); 'native-client-server-compile'=@('scheduled_event'); 'content-reference-validation'=@('scheduled_event'); 'controller-operational-proof'=@('scheduled_event'); 'clean-package-provenance-smoke'=@('scheduled_event') }
		return [pscustomobject][ordered]@{ schemaVersion=$script:CiSelectionSchema; attemptAnchor=$AttemptAnchor; policy=[pscustomobject][ordered]@{version=$script:CiSelectionPolicyVersion;digest=(Get-PolicyDigest);checkIds=@($script:CiSelectionCheckIds)};source=[pscustomobject][ordered]@{kind=$Context.kind;callerKind=$CallerKind;baseRevision=$null;headRevision=$null;workflowRevision=$Context.controllerRevision;revision=$Revision};execution=[pscustomobject][ordered]@{mode='accepted-base';controllerRevision=$Context.controllerRevision;controllerBlobOid=$ControllerIdentity.oid;controllerSha256=$ControllerIdentity.sha256;checkoutAllowed=$false;complete=$true;reason='scheduled_fixed_obligations'};classification=[pscustomobject][ordered]@{changedPaths=@();entries=@();uncertainties=@()};selection=[pscustomobject][ordered]@{shadow=$true;authoritative=$false;obligations=(New-Obligations $Selected $null)};legacyAuthority=[pscustomobject][ordered]@{authoritative=$true;engineRequired=$LegacyEngineRequired;reason=$LegacyReason};comparison=[pscustomobject][ordered]@{status='unavailable';differences=@('legacy_authority_not_observed')} }
	}
	$Base = if ($Context.kind -eq 'pull_request') { $Context.baseRevision } elseif ($Context.kind -eq 'push') { $Context.beforeRevision } else { $Context.baseRevision }
	$Head = if ($Context.kind -eq 'pull_request') { $Context.headRevision } elseif ($Context.kind -eq 'push') { $Context.afterRevision } else { $Context.headRevision }
	if ([string]::IsNullOrEmpty($Base) -or $Base -eq ('0' * 40)) { throw 'comparison_base_unavailable' }
	if ($Context.kind -eq 'pull_request' -or ($Context.kind -eq 'workflow_call' -and $Context.callerKind -eq 'pull_request')) {
		$ParentsRaw = (Invoke-BoundedGitBytes $Repository @('show','-s','--format=%P',$Context.workflowRevision) -StdoutLimit 1024).Stdout
		$Parents = ($script:StrictUtf8.GetString($ParentsRaw).Trim() -split ' ')
		if ($Parents.Count -ne 2 -or $Parents[0] -cne $Base -or $Parents[1] -cne $Head) { throw 'workflow_revision_parents_invalid' }
	}
	$BaseTree = @(Get-TrackedTreeEntries $Repository $Base); $HeadTree = @(Get-TrackedTreeEntries $Repository $Head)
	Test-WindowsCheckoutTree $BaseTree | Out-Null
	Test-WindowsCheckoutTree $HeadTree | Out-Null
	$Raw = (Invoke-BoundedGitBytes $Repository @('diff','--raw','-z','--no-abbrev','--no-ext-diff','--no-textconv','--find-renames','--find-copies-harder',$Base,$Head,'--')).Stdout
	$Entries = @(ConvertFrom-GitRawZ $Raw)
	if ($Entries.Count -eq 0) { throw 'empty_diff' }
	if (@($Entries | Where-Object { $_.oldPath -eq '.lfsconfig' -or $_.newPath -eq '.lfsconfig' }).Count -gt 0) { throw 'lfsconfig_changed' }
	$AttributeChanged = @($Entries | Where-Object { $_.oldPath -eq '.gitattributes' -or $_.newPath -eq '.gitattributes' -or $_.oldPath.EndsWith('/.gitattributes') -or $_.newPath.EndsWith('/.gitattributes') }).Count -gt 0
	$BasePaths = if ($AttributeChanged) { @($BaseTree | Where-Object {$_.type -eq 'blob'} | ForEach-Object {$_.path}) } else { @($Entries | Where-Object {$_.status -ne 'A'} | ForEach-Object {$_.oldPath}) }
	$HeadPaths = if ($AttributeChanged) { @($HeadTree | Where-Object {$_.type -eq 'blob'} | ForEach-Object {$_.path}) } else { @($Entries | Where-Object {$_.status -ne 'D'} | ForEach-Object {$_.newPath}) }
	$BaseAttrs=Get-RevisionAttributes -Repository $Repository -Revision $Base -Paths @($BasePaths | Sort-Object -Unique); $HeadAttrs=Get-RevisionAttributes -Repository $Repository -Revision $Head -Paths @($HeadPaths | Sort-Object -Unique)
	$Selected=@{}; $Classified=New-Object System.Collections.Generic.List[object]; $Changed=New-Object System.Collections.Generic.List[string]
	foreach ($Entry in $Entries) {
		foreach ($Side in @(@{path=$Entry.oldPath;attrs=$BaseAttrs},@{path=$Entry.newPath;attrs=$HeadAttrs})) {
			$Path=[string]$Side.path; if (-not $Changed.Contains($Path)) {$Changed.Add($Path)}
			$Attr=if ($Side.attrs.ContainsKey($Path)) {$Side.attrs[$Path]} else {$null}
			foreach ($Id in @(Get-PathCheckSelection $Path $Attr)) { if (-not $Selected.ContainsKey($Id)) {$Selected[$Id]=@()}; $Selected[$Id]+= "path:$Path" }
		}
		$Classified.Add($Entry)
	}
	if ($AttributeChanged) {
		foreach ($Path in @($BasePaths + $HeadPaths | Sort-Object -Unique)) {
			$Old=if($BaseAttrs.ContainsKey($Path)){($BaseAttrs[$Path] | ConvertTo-Json -Compress)}else{''}; $New=if($HeadAttrs.ContainsKey($Path)){($HeadAttrs[$Path] | ConvertTo-Json -Compress)}else{''}
			if ($Old -cne $New) {
				$EffectiveAttributes = if ($HeadAttrs.ContainsKey($Path)) { $HeadAttrs[$Path] } else { $BaseAttrs[$Path] }
				foreach($Id in @(Get-PathCheckSelection $Path $EffectiveAttributes)){if(-not $Selected.ContainsKey($Id)){$Selected[$Id]=@()};$Selected[$Id]+="attribute:$Path"}
			}
		}
	}
	$WorkflowRevision = if ($Context.PSObject.Properties.Name -ccontains 'workflowRevision') { $Context.workflowRevision } else { $null }
	$CallerKind = if ($Context.PSObject.Properties.Name -ccontains 'callerKind') { $Context.callerKind } else { $null }
	return [pscustomobject][ordered]@{
		schemaVersion=$script:CiSelectionSchema; attemptAnchor=$AttemptAnchor; policy=[pscustomobject][ordered]@{version=$script:CiSelectionPolicyVersion;digest=(Get-PolicyDigest);checkIds=@($script:CiSelectionCheckIds)}
		source=[pscustomobject][ordered]@{kind=$Context.kind;callerKind=$CallerKind;baseRevision=$Base;headRevision=$Head;workflowRevision=$WorkflowRevision;revision=$null}
		execution=[pscustomobject][ordered]@{mode='accepted-base';controllerRevision=$Context.controllerRevision;controllerBlobOid=$ControllerIdentity.oid;controllerSha256=$ControllerIdentity.sha256;checkoutAllowed=$false;complete=$true;reason='classified'}
		classification=[pscustomobject][ordered]@{changedPaths=@($Changed | Sort-Object);entries=@($Classified | Sort-Object oldPath,newPath,status);uncertainties=@()}
		selection=[pscustomobject][ordered]@{shadow=$true;authoritative=$false;obligations=(New-Obligations $Selected $null)}
		legacyAuthority=[pscustomobject][ordered]@{authoritative=$true;engineRequired=$LegacyEngineRequired;reason=$LegacyReason}
		comparison=[pscustomobject][ordered]@{status='unavailable';differences=@('legacy_authority_not_observed')}
	}
}

function Write-BoundedUtf8Json {
	param($Value, [string] $Path, [int] $Limit = $script:CiSelectionLimits.reportBytes)
	$Json = $Value | ConvertTo-Json -Depth 16 -Compress
	$Bytes = $script:Utf8NoBom.GetBytes($Json + "`n")
	if ($Bytes.Length -gt $Limit) { throw 'report_size_limit' }
	$Directory=Split-Path -Parent $Path; if ($Directory -and -not (Test-Path -LiteralPath $Directory)) {[void](New-Item -ItemType Directory -Path $Directory -Force)}
	[IO.File]::WriteAllBytes($Path,$Bytes)
	return $Bytes.Length
}

if ($ContextJson -or $OutputPath) {
	if (-not $ContextJson -or -not $OutputPath) { throw 'ContextJson and OutputPath are required together.' }
	$Context=$null
	$AttemptAnchor=$null
	$ContextAccepted=$false
	try {
		$Raw=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ContextJson),$script:StrictUtf8)
		Assert-UniqueJsonProperties $Raw
		$Context=$Raw | ConvertFrom-Json
		Assert-CiSelectionContext $Context | Out-Null
		$ContextAccepted=$true
		$AttemptAnchor=New-CiSelectionAttemptAnchor $Context
		$Report=New-CiSelectionReport $Context (Resolve-Path -LiteralPath $RepositoryRoot).Path -AttemptAnchor $AttemptAnchor
	} catch {
		$Reason=($_.Exception.Message -split ':')[0]
		if (-not $ContextAccepted -or $null -eq $AttemptAnchor -or $Reason.StartsWith('attempt_anchor_', [StringComparison]::Ordinal)) { throw }
		if ($Reason -cnotmatch '^[a-z0-9_]+$') { $Reason='selector_internal_error' }
		$Report=New-ConservativeSelection $Reason $Context -AttemptAnchor $AttemptAnchor
	}
	try { [void](Write-BoundedUtf8Json $Report $OutputPath) } catch {
		$Fallback=New-ConservativeSelection 'report_size_limit' $Context -AttemptAnchor $AttemptAnchor
		[void](Write-BoundedUtf8Json $Fallback $OutputPath)
	}
}
