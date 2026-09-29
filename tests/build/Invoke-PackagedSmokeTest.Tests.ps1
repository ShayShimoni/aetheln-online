[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Invoke-PackagedSmokeTest.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnSmokeTests-{0}" -f [guid]::NewGuid().ToString('N'))
$SuiteCompleted = $false

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Set-FixtureMountPoint([string] $Directory, [string] $Target) {
	if ($null -eq ('AethelnSmokeFixtureMountPoint' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AethelnSmokeFixtureMountPoint {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)]
 public static extern bool DeviceIoControl(SafeFileHandle handle,uint code,byte[] input,int inputSize,IntPtr output,int outputSize,out int returned,IntPtr overlapped);
}
'@
	}
	$Substitute = [Text.Encoding]::Unicode.GetBytes('\??\' + $Target.TrimEnd('\') + '\')
	$Print = [Text.Encoding]::Unicode.GetBytes($Target)
	$DataLength = 8 + $Substitute.Length + 2 + $Print.Length + 2
	$Buffer = New-Object byte[] (8 + $DataLength)
	[BitConverter]::GetBytes([uint32] 2684354563).CopyTo($Buffer, 0)
	[BitConverter]::GetBytes([uint16] $DataLength).CopyTo($Buffer, 4)
	[BitConverter]::GetBytes([uint16] 0).CopyTo($Buffer, 8)
	[BitConverter]::GetBytes([uint16] $Substitute.Length).CopyTo($Buffer, 10)
	[BitConverter]::GetBytes([uint16] ($Substitute.Length + 2)).CopyTo($Buffer, 12)
	[BitConverter]::GetBytes([uint16] $Print.Length).CopyTo($Buffer, 14)
	$Substitute.CopyTo($Buffer, 16)
	$Print.CopyTo($Buffer, 16 + $Substitute.Length + 2)
	$Handle = [AethelnSmokeFixtureMountPoint]::CreateFileW($Directory, 0x100, 0x7, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
	try {
		if ($Handle.IsInvalid) { throw "fixture_mount_open_failed_$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
		$Returned = 0
		if (-not [AethelnSmokeFixtureMountPoint]::DeviceIoControl($Handle, 0x900A4, $Buffer, $Buffer.Length, [IntPtr]::Zero, 0, [ref] $Returned, [IntPtr]::Zero)) { throw "fixture_mount_set_failed_$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
	} finally { $Handle.Dispose() }
}

function Stop-FixtureProcess($Process, [string] $Root) {
	# Bind a handle first, then prove through that handle that the image lives under
	# the fixture root before a handle-bound kill; a reused PID can never be targeted.
	if ($null -eq ('AethelnSmokeFixtureProcessImage' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AethelnSmokeFixtureProcessImage {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder name,ref int size);
 public static string Get(IntPtr process) { StringBuilder name = new StringBuilder(32768); int size = name.Capacity; return QueryFullProcessImageNameW(process, 0, name, ref size) ? name.ToString(0, size) : null; }
}
'@
	}
	try { $Handle = $Process.Handle } catch { Write-Warning "Fixture process $($Process.Id) could not be opened; not terminated."; return }
	$Image = [AethelnSmokeFixtureProcessImage]::Get($Handle)
	$Prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
	if ([string]::IsNullOrWhiteSpace($Image) -or -not [System.IO.Path]::GetFullPath($Image).StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { Write-Warning "Fixture process $($Process.Id) identity is not proven under the fixture root; not terminated."; return }
	try { if (-not $Process.HasExited) { $Process.Kill() } } catch [System.InvalidOperationException] { }
	try { [void] $Process.WaitForExit(5000) } catch { Write-Warning "Fixture cleanup could not wait for PID $($Process.Id): $($_.Exception.GetType().Name)" }
}

$ParseErrors = $null
$Tokens = $null
$ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref] $Tokens, [ref] $ParseErrors)
$IdentityFunction = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in @('Resolve-ProcessIdentity', 'Test-IsPreexistingProcessIdentity') }, $true))
Assert-True ($ParseErrors.Count -eq 0 -and $IdentityFunction.Count -eq 2) 'The process-identity helpers must be parseable and uniquely testable.'
foreach ($Definition in $IdentityFunction) { . ([scriptblock]::Create($Definition.Extent.Text)) }
$OriginalStart = [DateTime]::UtcNow.AddMinutes(-5)
$ReusedStart = $OriginalStart.AddMinutes(1)
$BaselineTicks = $OriginalStart.AddSeconds(30).Ticks
$IdentityBaseline = @{ '4242' = [long] $OriginalStart.Ticks }
Assert-True (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4242; StartTime = $OriginalStart }) $IdentityBaseline) 'A matching PID and start time must remain preexisting.'
Assert-True (-not (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4242; StartTime = $ReusedStart }) $IdentityBaseline)) 'A reused PID with a different start time must be treated as a new process.'
Assert-True (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4343; StartTime = $OriginalStart }) $IdentityBaseline $BaselineTicks) 'A pre-launch process omitted from a path-filtered baseline must never become a termination target.'
Assert-True (-not (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4343; StartTime = $ReusedStart }) $IdentityBaseline $BaselineTicks)) 'A baseline-absent process needs a readable post-baseline start time before it can be new.'
Assert-True (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4343; StartTime = $ReusedStart }) $IdentityBaseline) 'An absent PID without a captured time boundary must remain unresolved.'
# Unreadable identity (access denied, or the process exited mid-read) must never
# turn into permission to terminate a process that was present before the smoke.
$UnreadableBaselineProcess = [pscustomobject]@{ Id = 4242 } | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw [System.ComponentModel.Win32Exception]::new(5) } -PassThru
$UnreadableUnknownProcess = [pscustomobject]@{ Id = 4343 } | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw [System.ComponentModel.Win32Exception]::new(5) } -PassThru
Assert-True (Test-IsPreexistingProcessIdentity $UnreadableBaselineProcess $IdentityBaseline) 'A baseline PID whose start time cannot be read must stay protected.'
Assert-True (Test-IsPreexistingProcessIdentity $UnreadableUnknownProcess $IdentityBaseline $BaselineTicks) 'A PID absent from the baseline with unreadable start time must remain protected.'
Assert-True (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4444; StartTime = $ReusedStart }) @{ '4444' = $null }) 'A baseline entry recorded without identity must remain preexisting.'
foreach ($HelperName in @('Get-PreexistingProcessIdentityBaseline', 'Wait-ForOwnedProcessExit')) {
	$Helper = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $HelperName }, $true))
	Assert-True ($Helper.Count -eq 1) "The $HelperName helper must be uniquely testable."
	. ([scriptblock]::Create($Helper[0].Extent.Text))
}
$Baseline = Get-PreexistingProcessIdentityBaseline -Processes @(([pscustomobject]@{ Id = 5151; StartTime = $OriginalStart }), $UnreadableUnknownProcess)
Assert-True ($Baseline.Count -eq 2 -and $Baseline['5151'] -eq [long] $OriginalStart.Ticks -and $Baseline.ContainsKey('4343') -and $null -eq $Baseline['4343']) 'The baseline must keep every observed PID and mark unreadable identities as unknown instead of dropping them.'
Write-Output 'PASS: unreadable process identity is recorded as protected, never as a termination target'

function Test-BaselineSnapshot {
	$Observation = @{ PathReads = 0; FailInventory = $false }
	$HiddenPathProcess = [pscustomobject]@{ Id = 7777; StartTime = $OriginalStart } | Add-Member -MemberType ScriptProperty -Name Path -Value { $Observation.PathReads++; throw [System.ComponentModel.Win32Exception]::new(5) } -PassThru
	function Invoke-FakeProcessInventory {
		[CmdletBinding()] param()
		if ($Observation.FailInventory) { Write-Error 'Synthetic process inventory failure'; return }
		$HiddenPathProcess
		$UnreadableUnknownProcess
	}
	Set-Alias -Name Get-Process -Value Invoke-FakeProcessInventory -Scope Local
	$Assignment = @($ScriptAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$PreexistingClientProcessIdentities' })
	Assert-True ($Assignment.Count -eq 1) 'The production process-baseline capture must be uniquely executable.'
	$PreexistingClientProcessIdentities = $null
	. ([scriptblock]::Create($Assignment[0].Extent.Text))
	Assert-True ($Observation.PathReads -eq 0 -and $PreexistingClientProcessIdentities.Count -eq 2 -and $PreexistingClientProcessIdentities['7777'] -eq $OriginalStart.Ticks -and $PreexistingClientProcessIdentities.ContainsKey('4343')) 'Actual baseline capture must retain all observed identities without excluding unreadable executable paths.'
	$Observation.FailInventory = $true
	$InventoryFailure = $null
	try { . ([scriptblock]::Create($Assignment[0].Extent.Text)) } catch { $InventoryFailure = $_.Exception.Message }
	Assert-True ($InventoryFailure -match 'Synthetic process inventory failure') 'Incomplete process enumeration must fail before smoke launch instead of producing a successful partial baseline.'
	Write-Output 'PASS: actual baseline capture preserves unreadable-path identities and rejects incomplete enumeration before launch'
}

function Test-EvidenceWriter {
	$EvidenceFunction = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Write-Evidence' }, $true))
	Assert-True ($EvidenceFunction.Count -eq 1) 'The production evidence writer must be uniquely testable.'
	. ([scriptblock]::Create($EvidenceFunction[0].Extent.Text))
	$EvidencePath = Join-Path $FixtureRoot 'writer-evidence.jsonl'
	$UnicodeDetail = 'Detail ' + [char] 0x00e9 + [char] 0x05e9 + [char] 0x4e16 + [char]::ConvertFromUtf32(0x1f525) + "`nsecond line"
	Write-Evidence 'writer' 'fixture' 'record-0' 'fixture' $UnicodeDetail 'connection-0'
	# This live reader permits append but denies read access to the writer. The
	# Windows PowerShell Add-Content provider can fail its sharing open or fall
	# back to a write-only stream and throw "Stream was not readable".
	$Reader = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Write)
	try {
		foreach ($Index in 1..20) { Write-Evidence 'writer' 'fixture' "record-$Index" 'fixture' $UnicodeDetail "connection-$Index" }
	} finally { $Reader.Dispose() }
	$Bytes = [System.IO.File]::ReadAllBytes($EvidencePath)
	Assert-True ($Bytes.Length -gt 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) 'The writer must preserve the Windows PowerShell UTF-8 BOM contract.'
	$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
	$Text = $StrictUtf8.GetString($Bytes, 3, $Bytes.Length - 3)
	Assert-True (-not $Text.Contains([string] [char] 0xfeff)) 'Appending must never insert another BOM into JSONL records.'
	$Lines = @([System.IO.File]::ReadAllLines($EvidencePath, $StrictUtf8))
	Assert-True ($Lines.Count -eq 21) 'Concurrent readers must not cause missing, duplicate, or split records.'
	$Records = @($Lines | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True (@($Records.event | Sort-Object -Unique).Count -eq 21) 'Every evidence event must occur exactly once.'
	foreach ($Index in 0..20) {
		Assert-True ($Records[$Index].event -eq "record-$Index" -and $Records[$Index].connection_id -eq "connection-$Index" -and $Records[$Index].detail -ceq $UnicodeDetail) 'The writer must preserve event order, connection identity, Unicode, and escaped newlines.'
	}
	$Lock = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
	$Timer = [System.Diagnostics.Stopwatch]::StartNew()
	$Failure = $null
	try {
		try { Write-Evidence 'writer' 'fixture' 'locked-record' 'fixture' 'must not append' } catch { $Failure = $_ }
	} finally { $Timer.Stop(); $Lock.Dispose() }
	Assert-True ($null -ne $Failure) 'An exclusive evidence lock must fail closed.'
	Assert-True ($Timer.Elapsed.TotalSeconds -lt 5) 'Sharing retries must fail within a bounded interval.'
	Assert-True ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($EvidencePath)) -ceq [Convert]::ToBase64String($Bytes)) 'A failed append open must preserve every existing byte.'
	Write-Evidence 'writer' 'fixture' 'record-21' 'fixture' $UnicodeDetail 'connection-21'
	$AfterLock = @([System.IO.File]::ReadAllLines($EvidencePath, $StrictUtf8) | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($AfterLock.Count -eq 22 -and $AfterLock[-1].event -eq 'record-21') 'Releasing the lock must permit the next append without replaying the failed record.'
	Write-Output 'PASS: actual evidence writer preserves UTF-8 JSONL under concurrent readers and fails closed under a bounded exclusive lock'
}

function Test-CleanupWaitEvidence {
	$EvidenceFunction = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Write-Evidence' }, $true))
	. ([scriptblock]::Create($EvidenceFunction[0].Extent.Text))
	$EvidencePath = Join-Path $FixtureRoot 'cleanup-wait-evidence.jsonl'
	$ThrowingProcess = [pscustomobject]@{ Id = 6161 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { throw [System.ComponentModel.Win32Exception]::new(5, 'sensitive handle detail') } -PassThru
	$ExitedProcess = [pscustomobject]@{ Id = 6262 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { return $true } -PassThru
	Assert-True (-not (Wait-ForOwnedProcessExit -Process $ThrowingProcess -TimeoutMilliseconds 10 -Source (Join-Path $FixtureRoot 'package'))) 'An unreadable process wait must not confirm exit.'
	Assert-True (Wait-ForOwnedProcessExit -Process $ExitedProcess -TimeoutMilliseconds 10 -Source (Join-Path $FixtureRoot 'package')) 'A successful bounded wait must confirm exit.'
	$Records = @(Get-Content -LiteralPath $EvidencePath | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($Records.Count -eq 1 -and $Records[0].event -eq 'process_cleanup_wait_failed' -and $Records[0].role -eq 'cleanup') 'A failed cleanup wait must leave exactly one evidence record and a clean wait must leave none.'
	Assert-True ($Records[0].detail -like '*6161*' -and $Records[0].detail -like '*Win32Exception*' -and $Records[0].detail -notlike '*sensitive handle detail*') 'Cleanup wait evidence must name the PID and exception type without raw exception text.'
	Write-Output 'PASS: cleanup wait failures are recorded as sanitized evidence instead of being swallowed'
}

function New-FakeClientJob([string] $Id, [long[]] $Members, [scriptblock] $ActiveScript, [switch] $FailQuery) {
	$State = @{ Terminated = $false; Disposed = $false; Members = $Members; FailQuery = [bool] $FailQuery }
	$Job = [pscustomobject]@{ State = $State }
	$Job | Add-Member -MemberType ScriptMethod -Name GetProcessIds -Value { if ($this.State.FailQuery) { throw [System.ComponentModel.Win32Exception]::new(5) }; if ($this.State.Terminated -and -not $this.State.Active) { return @() }; return $this.State.Members }
	$Job | Add-Member -MemberType ScriptMethod -Name GetActiveProcessCount -Value { if ($this.State.Terminated -and -not $this.State.Active) { return 0 }; return @($this.State.Members).Count }
	$Job | Add-Member -MemberType ScriptMethod -Name Terminate -Value { $this.State.Terminated = $true }
	$Job | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.State.Disposed = $true }
	$State.Active = if ($ActiveScript) { & $ActiveScript } else { $false }
	return [pscustomobject]@{ Id = $Id; Job = $Job }
}

function Invoke-CleanupFixture([string] $Name, [hashtable] $Baseline, [scriptblock] $ScanScript, [object[]] $DirectProcesses = @(), [object[]] $Jobs = @(), [scriptblock] $OpaqueScript = { }, [switch] $FailEvidence) {
	# Run the production finally block verbatim against fakes: the real evidence writer
	# appends to an isolated fixture file; process scanning and termination are faked.
	foreach ($Definition in @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))) {
		. ([scriptblock]::Create($Definition.Extent.Text))
	}
	$Stopped = [System.Collections.Generic.List[int]]::new()
	function Get-ProcessesUnderPath([string] $Root) { & $ScanScript }
	function Get-OpaquePackageNamedProcesses($Names) { & $OpaqueScript }
	if ($FailEvidence) { function Write-Evidence { throw 'synthetic evidence append failure' } }
	function Invoke-FakeProcessStop {
		[CmdletBinding()] param([int] $Id, [switch] $Force)
		if (-not $Force) { throw 'Cleanup must terminate smoke-owned processes with -Force.' }
		$Stopped.Add($Id)
	}
	Set-Alias -Name Stop-Process -Value Invoke-FakeProcessStop -Scope Local
	$EvidenceFile = Join-Path $FixtureRoot "cleanup-decision-$Name.jsonl"
	# Script-scope state the production finally block reads.
	$CleanupState = @{
		Processes = $DirectProcesses
		ClientJobs = $Jobs
		PackageExecutableNames = [System.Collections.Generic.HashSet[string]]::new([string[]] @('ClientRuntime'), [System.StringComparer]::OrdinalIgnoreCase)
		EvidencePath = $EvidenceFile
		ClientPackageRoot = Join-Path $FixtureRoot 'package'
		PreexistingClientProcessIdentities = $Baseline
		ClientProcessBaselineTicks = $BaselineTicks
	}
	foreach ($Variable in $CleanupState.Keys) { Set-Variable -Name $Variable -Value $CleanupState[$Variable] }
	$TryStatements = @($ScriptAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
	Assert-True ($TryStatements.Count -eq 1 -and $null -ne $TryStatements[0].Finally) 'The smoke script must own exactly one top-level try/finally cleanup block.'
	$FinallyText = $TryStatements[0].Finally.Extent.Text
	$FinallyBody = $FinallyText.Substring(1, $FinallyText.Length - 2)
	$Failure = $null
	$Timer = [System.Diagnostics.Stopwatch]::StartNew()
	try { . ([scriptblock]::Create($FinallyBody)) } catch { $Failure = $_.Exception.Message }
	$Timer.Stop()
	$Events = @(if (Test-Path -LiteralPath $EvidenceFile) { Get-Content -LiteralPath $EvidenceFile | ForEach-Object { $Record = $_ | ConvertFrom-Json; "$($Record.event)|$($Record.detail)" } })
	return [pscustomobject]@{ Events = $Events; Stopped = @($Stopped); Failure = $Failure; Seconds = $Timer.Elapsed.TotalSeconds }
}

function Test-DirectCleanupWait {
	$WaitCalls = [System.Collections.Generic.List[int]]::new()
	$Disposal = @{ Count = 0 }
	$Kills = [System.Collections.Generic.List[int]]::new()
	$Stubborn = [pscustomobject]@{ Id = 6565; HasExited = $false } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
		param($TimeoutMilliseconds)
		if ($null -eq $TimeoutMilliseconds) { throw 'Unbounded direct wait attempted.' }
		$WaitCalls.Add([int] $TimeoutMilliseconds)
		return $false
	} -PassThru | Add-Member -MemberType ScriptMethod -Name Kill -Value { $Kills.Add($this.Id) } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $Disposal.Count++ } -PassThru
	$Timeout = Invoke-CleanupFixture -Name direct-timeout -Baseline @{} -ScanScript { } -DirectProcesses @($Stubborn)
	Assert-True ($WaitCalls.Count -eq 1 -and $WaitCalls[0] -ge 0 -and $WaitCalls[0] -le 5000) "A direct-process wait must always receive a bounded timeout. Actual: $($Timeout.Failure)"
	# Direct termination must use the retained handle; a PID-based stop could reach a reused PID.
	Assert-True ($Timeout.Failure -match 'direct process' -and $Timeout.Stopped.Count -eq 0 -and @($Kills) -join ',' -eq '6565' -and $Disposal.Count -eq 1 -and $Timeout.Seconds -lt 15) 'An ineffective direct termination must use the retained handle, dispose it, continue bounded cleanup and fail explicitly.'
	$ExitedDuringKill = [pscustomobject]@{ Id = 6767; HasExited = $false } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMilliseconds) if ($null -eq $TimeoutMilliseconds) { throw 'Unbounded direct wait attempted.' }; return $true } -PassThru | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw [System.InvalidOperationException]::new('No process is associated with this object.') } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $Disposal.Count++ } -PassThru
	$Raced = Invoke-CleanupFixture -Name direct-exited-during-kill -Baseline @{} -ScanScript { } -DirectProcesses @($ExitedDuringKill)
	Assert-True ($null -eq $Raced.Failure -and $Raced.Stopped.Count -eq 0 -and @($Raced.Events | Where-Object { $_ -like 'process_cleanup_stop_failed|*6767*' }).Count -eq 1 -and $Raced.Events[-1] -like 'process_cleanup_complete|*') "A process that exits between the check and the handle kill must be recorded and still confirmed by the bounded wait. Actual: $($Raced.Failure)"
	$Disposal.Count = 1
	Assert-True (@($Timeout.Events | Where-Object { $_ -like 'process_cleanup_wait_failed|*6565*' }).Count -eq 1 -and -not @($Timeout.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'A direct-process timeout must retain bounded evidence and prohibit successful cleanup completion.'
	$Exited = [pscustomobject]@{ Id = 6666; HasExited = $true } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMilliseconds) if ($null -eq $TimeoutMilliseconds) { throw 'Unbounded direct wait attempted.' }; return $true } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $Disposal.Count++ } -PassThru
	$Complete = Invoke-CleanupFixture -Name direct-exited -Baseline @{} -ScanScript { } -DirectProcesses @($Exited)
	Assert-True ($null -eq $Complete.Failure -and $Complete.Stopped.Count -eq 0 -and @($Kills).Count -eq 1 -and $Disposal.Count -eq 2 -and $Complete.Events[-1] -like 'process_cleanup_complete|*') 'An already-exited direct process must be disposed without termination and allow quiescent cleanup success.'
	Write-Output 'PASS: direct-process waits are bounded, termination uses the retained handle, and ineffective termination fails cleanup without completion evidence'
}

function Test-CleanupDecision {
	$Ambiguous = [pscustomobject]@{ Id = 4242; StartTime = $OriginalStart }
	$Persisting = Invoke-CleanupFixture -Name persisting -Baseline @{ '4242' = $null } -ScanScript { $Ambiguous }
	Assert-True ($Persisting.Stopped.Count -eq 0) 'A process with unresolved identity must never be terminated.'
	Assert-True ($null -ne $Persisting.Failure -and $Persisting.Failure -match 'unresolved identity' -and $Persisting.Failure -notmatch 'quiescence') "Persisting identity ambiguity must fail cleanup explicitly instead of claiming completion. Actual: $($Persisting.Failure)"
	Assert-True (@($Persisting.Events | Where-Object { $_ -like 'process_cleanup_unresolved|*4242*' }).Count -eq 1 -and -not @($Persisting.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'Persisting ambiguity must leave sanitized unresolved evidence and no completion evidence.'
	Assert-True ($Persisting.Seconds -lt 15) 'Unresolved-identity failure must stay inside the bounded cleanup window.'
	$ScanState = @{ Calls = 0 }
	$Vanishing = Invoke-CleanupFixture -Name vanishing -Baseline @{ '4242' = $null } -ScanScript { $ScanState.Calls++; if ($ScanState.Calls -le 3) { $Ambiguous } }
	Assert-True ($null -eq $Vanishing.Failure -and $Vanishing.Stopped.Count -eq 0 -and $Vanishing.Events[-1] -like 'process_cleanup_complete|*') "Ambiguity that vanishes inside the window must permit success without termination. Actual: $($Vanishing.Failure)"
	$Preexisting = Invoke-CleanupFixture -Name preexisting -Baseline @{ '4242' = [long] $OriginalStart.Ticks } -ScanScript { $Ambiguous }
	Assert-True ($null -eq $Preexisting.Failure -and $Preexisting.Stopped.Count -eq 0 -and $Preexisting.Events[-1] -like 'process_cleanup_complete|*') "A proven preexisting process must stay protected without blocking success. Actual: $($Preexisting.Failure)"
	$Omitted = Invoke-CleanupFixture -Name omitted -Baseline @{} -ScanScript { $Ambiguous }
	Assert-True ($null -eq $Omitted.Failure -and $Omitted.Stopped.Count -eq 0 -and $Omitted.Events[-1] -like 'process_cleanup_complete|*') 'A baseline-omitted process whose start predates launch must remain protected when its path becomes visible.'
	$UnreadableOmitted = Invoke-CleanupFixture -Name omitted-unreadable -Baseline @{} -ScanScript { $UnreadableUnknownProcess }
	Assert-True ($UnreadableOmitted.Stopped.Count -eq 0 -and $UnreadableOmitted.Failure -match 'unresolved identity' -and $UnreadableOmitted.Seconds -lt 15) 'An omitted process with unreadable current identity must fail closed inside the bounded window without termination.'
	Assert-True (@($UnreadableOmitted.Events | Where-Object { $_ -like 'process_cleanup_unresolved|*4343*' }).Count -eq 1 -and -not @($UnreadableOmitted.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'Unknown baseline-absent identity must produce sanitized evidence, never cleanup completion.'
	# A new package process outside every smoke-owned job may belong to someone else:
	# the path scan must never terminate it, and cleanup must not claim completion.
	$NewProcess = [pscustomobject]@{ Id = 9999; StartTime = $ReusedStart } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { return $true } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
	$Untracked = Invoke-CleanupFixture -Name untracked -Baseline @{ '4242' = [long] $OriginalStart.Ticks } -ScanScript { $NewProcess }
	Assert-True ($Untracked.Stopped.Count -eq 0 -and $Untracked.Failure -match 'outside smoke-owned jobs' -and $Untracked.Seconds -lt 15) "A new package process outside the client jobs must never be terminated and must fail cleanup. Actual: $($Untracked.Failure)"
	Assert-True (@($Untracked.Events | Where-Object { $_ -like 'process_cleanup_untracked|*9999*' }).Count -eq 1 -and -not @($Untracked.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'An untracked package process must leave evidence and no completion record.'
	$ScanState.Calls = 0
	$TransientUntracked = Invoke-CleanupFixture -Name untracked-exits -Baseline @{ '4242' = [long] $OriginalStart.Ticks } -ScanScript { $ScanState.Calls++; if ($ScanState.Calls -le 3) { $NewProcess } }
	Assert-True ($null -eq $TransientUntracked.Failure -and $TransientUntracked.Stopped.Count -eq 0 -and $TransientUntracked.Events[-1] -like 'process_cleanup_complete|*') "An untracked process that exits inside the window must permit success without termination. Actual: $($TransientUntracked.Failure)"
	# A new process whose path is unreadable but whose image name matches a package
	# executable cannot be proven unrelated: withhold completion, never terminate.
	$OpaqueNamed = [pscustomobject]@{ Id = 9898; StartTime = $ReusedStart; ProcessName = 'ClientRuntime'; AethelnOpaque = $true }
	$Opaque = Invoke-CleanupFixture -Name opaque-package-named -Baseline @{ '4242' = [long] $OriginalStart.Ticks } -ScanScript { } -OpaqueScript { $OpaqueNamed }
	Assert-True ($Opaque.Stopped.Count -eq 0 -and $Opaque.Failure -match 'outside smoke-owned jobs' -and $Opaque.Seconds -lt 15) "An opaque package-named process must fail cleanup without termination. Actual: $($Opaque.Failure)"
	Assert-True (@($Opaque.Events | Where-Object { $_ -like 'process_cleanup_untracked|PID 9898 started with an unreadable path and a package executable name*' }).Count -eq 1 -and -not @($Opaque.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'An opaque package-named process must leave specific evidence and no completion record.'
	$OpaqueUnrelated = Invoke-CleanupFixture -Name opaque-unrelated -Baseline @{ '4242' = [long] $OriginalStart.Ticks } -ScanScript { } -OpaqueScript { }
	Assert-True ($null -eq $OpaqueUnrelated.Failure -and $OpaqueUnrelated.Events[-1] -like 'process_cleanup_complete|*') "No opaque package-named process must allow completion. Actual: $($OpaqueUnrelated.Failure)"
	foreach ($Definition in @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Resolve-ProcessIdentity' }, $false))) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	Assert-True ((Resolve-ProcessIdentity $Ambiguous @{ '4242' = [long] $OriginalStart.Ticks }) -ceq 'preexisting' -and (Resolve-ProcessIdentity $Ambiguous @{ '4242' = $null }) -ceq 'unresolved' -and (Resolve-ProcessIdentity $UnreadableBaselineProcess $IdentityBaseline) -ceq 'unresolved' -and (Resolve-ProcessIdentity $NewProcess @{} $BaselineTicks) -ceq 'new' -and (Resolve-ProcessIdentity ([pscustomobject]@{ Id = 4242; StartTime = $ReusedStart }) $IdentityBaseline) -ceq 'new') 'Identity resolution must distinguish proven preexisting, proven new, and unresolved.'
	Write-Output 'PASS: cleanup decision protects unresolved identities and refuses to claim completion while ambiguity persists'
}

function Test-JobCleanupDecision {
	$Draining = New-FakeClientJob -Id 'client-1' -Members @(1201, 1202)
	$Drained = Invoke-CleanupFixture -Name job-drained -Baseline @{} -ScanScript { } -Jobs @($Draining)
	Assert-True ($null -eq $Drained.Failure -and $Draining.Job.State.Terminated -and $Draining.Job.State.Disposed -and $Drained.Events[-1] -like 'process_cleanup_complete|*') "A terminated job that reports no member process must permit completion. Actual: $($Drained.Failure)"
	Assert-True (@($Drained.Events | Where-Object { $_ -like 'process_cleanup_job|client-1 job members PID `[1201, 1202`]; activeProcesses=0; listedProcesses=0.' }).Count -eq 1) 'Job cleanup must record the owned member PIDs and the zero active/listed counts.'
	# An owned process whose executable path is unreadable is invisible to the package
	# path scan; job accounting must still block a false completion.
	$Stuck = New-FakeClientJob -Id 'client-2' -Members @(1301) -ActiveScript { $true }
	$StuckResult = Invoke-CleanupFixture -Name job-stuck -Baseline @{} -ScanScript { } -Jobs @($Stuck)
	Assert-True ($StuckResult.Failure -match 'job cleanup could not prove.*client-2' -and $StuckResult.Stopped.Count -eq 0 -and $Stuck.Job.State.Disposed -and $StuckResult.Seconds -lt 15) "A job that still reports a member must fail cleanup within the bounded window. Actual: $($StuckResult.Failure)"
	Assert-True (@($StuckResult.Events | Where-Object { $_ -like 'process_cleanup_job|client-2 job members PID `[1301`]; activeProcesses=1; listedProcesses=1.' }).Count -eq 1 -and -not @($StuckResult.Events | Where-Object { $_ -like 'process_cleanup_complete|*' }).Count) 'A stuck job must leave its counts as evidence and no completion record.'
	$Unqueryable = New-FakeClientJob -Id 'client-1' -Members @(1401) -FailQuery
	$UnqueryableResult = Invoke-CleanupFixture -Name job-unqueryable -Baseline @{} -ScanScript { } -Jobs @($Unqueryable)
	Assert-True ($UnqueryableResult.Failure -match 'job cleanup could not prove.*client-1' -and $Unqueryable.Job.State.Disposed -and @($UnqueryableResult.Events | Where-Object { $_ -like 'process_cleanup_job_failed|client-1: Win32Exception' }).Count -eq 1) "An unqueryable job must fail closed with sanitized evidence. Actual: $($UnqueryableResult.Failure)"
	Write-Output 'PASS: job cleanup requires zero active and listed members and fails closed on stuck or unqueryable jobs'
}

function Test-OpaqueInventory {
	foreach ($Definition in @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in @('Get-PackageExecutableNames', 'Get-OpaquePackageNamedProcesses') }, $true))) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	$InventoryRoot = Join-Path $FixtureRoot 'opaque-inventory'
	New-Item -ItemType Directory -Path (Join-Path $InventoryRoot 'Nested') -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $InventoryRoot 'Nested\ClientRuntime.exe') -Value 'fixture' -Encoding ASCII
	Set-Content -LiteralPath (Join-Path $InventoryRoot 'readme.txt') -Value 'fixture' -Encoding ASCII
	$Names = Get-PackageExecutableNames $InventoryRoot
	Assert-True ($Names.Count -eq 1 -and $Names.Contains('clientruntime')) 'The package inventory must record nested executable base names case-insensitively and nothing else.'
	$SameNameOpaque = [pscustomobject]@{ Id = 7101; ProcessName = 'ClientRuntime' } | Add-Member -MemberType ScriptProperty -Name Path -Value { throw [System.ComponentModel.Win32Exception]::new(5) } -PassThru
	$BlankPathSameName = [pscustomobject]@{ Id = 7102; ProcessName = 'ClientRuntime'; Path = '' }
	$UnrelatedOpaque = [pscustomobject]@{ Id = 7103; ProcessName = 'svchost' } | Add-Member -MemberType ScriptProperty -Name Path -Value { throw [System.ComponentModel.Win32Exception]::new(5) } -PassThru
	$ReadableSameName = [pscustomobject]@{ Id = 7104; ProcessName = 'ClientRuntime'; Path = 'C:\Elsewhere\ClientRuntime.exe' }
	function Invoke-FakeOpaqueInventory { [CmdletBinding()] param() $SameNameOpaque; $BlankPathSameName; $UnrelatedOpaque; $ReadableSameName }
	Set-Alias -Name Get-Process -Value Invoke-FakeOpaqueInventory -Scope Local
	$Reported = @(Get-OpaquePackageNamedProcesses $Names)
	Assert-True ((@($Reported | ForEach-Object { $_.Id }) -join ',') -ceq '7101,7102' -and -not @($Reported | Where-Object { -not $_.AethelnOpaque }).Count) 'Only unreadable- or blank-path processes with a package executable name may be reported; unrelated opaque and readable-path processes are excluded.'
	Write-Output 'PASS: opaque inventory reports only unreadable-path processes named like package executables'
}

function Test-LiveLogSharing {
	foreach ($Definition in @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in @('Initialize-PackagedSmokeClientJobType', 'Start-OwnedClientProcess') }, $true))) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	Initialize-PackagedSmokeClientJobType
	$ShareRoot = Join-Path $FixtureRoot 'log-sharing'
	New-Item -ItemType Directory -Path $ShareRoot | Out-Null
	$Writer = Join-Path $ShareRoot 'LogWriter.exe'
	Add-Type -TypeDefinition ('public static class LogWriter' + [guid]::NewGuid().ToString('N') + ' { public static int Main() { System.Console.WriteLine("first live line"); System.Console.Out.Flush(); System.Threading.Thread.Sleep(15000); return 0; } }') -OutputAssembly $Writer -OutputType ConsoleApplication
	$OutLog = Join-Path $ShareRoot 'writer.stdout.log'
	$Job = [Aetheln.PackagedSmokeClientJob]::new()
	try {
		$Process = Start-OwnedClientProcess -Job $Job -Executable $Writer -Arguments @() -StdOutPath $OutLog -StdErrPath (Join-Path $ShareRoot 'writer.stderr.log')
		try {
			$Deadline = [DateTime]::UtcNow.AddSeconds(10)
			$Tail = @()
			while ([DateTime]::UtcNow -lt $Deadline -and -not ($Tail -contains 'first live line')) { $Tail = @(Get-Content -LiteralPath $OutLog -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 100 }
			Assert-True ($Tail -contains 'first live line' -and -not $Process.HasExited) 'A reader must be able to tail a live client log while the client is running.'
			$WriteDenied = $false
			try { ([System.IO.File]::Open($OutLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)).Dispose() } catch [System.IO.IOException] { $WriteDenied = $true }
			$DeleteDenied = $false
			try { [System.IO.File]::Delete($OutLog) } catch [System.IO.IOException] { $DeleteDenied = $true } catch [System.UnauthorizedAccessException] { $DeleteDenied = $true }
			$RenameDenied = $false
			try { [System.IO.File]::Move($OutLog, "$OutLog.moved") } catch [System.IO.IOException] { $RenameDenied = $true } catch [System.UnauthorizedAccessException] { $RenameDenied = $true }
			Assert-True ($WriteDenied -and $DeleteDenied -and $RenameDenied -and (Test-Path -LiteralPath $OutLog) -and -not (Test-Path -LiteralPath "$OutLog.moved")) 'While the client holds its log, no other writer, deleter, or renamer may open it.'
		} finally {
			$Job.Terminate()
			[void] $Process.WaitForExit(5000)
			$Process.Dispose()
		}
	} finally { $Job.Dispose() }
	Write-Output 'PASS: live client logs can be tailed but not written, deleted, or renamed by others'
}

function Test-FailSafeJobDisposal {
	foreach ($Definition in @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in @('Initialize-PackagedSmokeClientJobType', 'Start-OwnedClientProcess') }, $true))) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	Initialize-PackagedSmokeClientJobType
	$FailSafeRoot = Join-Path $FixtureRoot 'fail-safe-job'
	New-Item -ItemType Directory -Path $FailSafeRoot | Out-Null
	$Spawner = Join-Path $FailSafeRoot 'FailSafeSpawner.exe'
	Add-Type -TypeDefinition ('public static class FailSafeSpawner' + [guid]::NewGuid().ToString('N') + ' { public static int Main(string[] args) { if (args.Length == 0) { System.Diagnostics.Process child = System.Diagnostics.Process.Start(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName, "child"); System.IO.File.WriteAllText(System.AppDomain.CurrentDomain.BaseDirectory + "grandchild.pid", child.Id.ToString()); } System.Threading.Thread.Sleep(60000); return 0; } }') -OutputAssembly $Spawner -OutputType ConsoleApplication
	$Job = [Aetheln.PackagedSmokeClientJob]::new()
	$Client = Start-OwnedClientProcess -Job $Job -Executable $Spawner -Arguments @() -StdOutPath (Join-Path $FailSafeRoot 'out.log') -StdErrPath (Join-Path $FailSafeRoot 'err.log')
	$ClientId = $Client.Id
	$Client.Dispose()
	$Marker = Join-Path $FailSafeRoot 'grandchild.pid'
	$Deadline = [DateTime]::UtcNow.AddSeconds(10)
	while (-not (Test-Path -LiteralPath $Marker) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
	Assert-True (Test-Path -LiteralPath $Marker) 'The fail-safe fixture must start a grandchild inside the client job.'
	$GrandchildId = [int] (Get-Content -LiteralPath $Marker -Raw)
	# A direct process whose termination fails forces an evidence append before the
	# job loop; the evidence writer itself fails, so the job loop never runs.
	$Throwing = [pscustomobject]@{ Id = 6868; HasExited = $false } | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw [System.InvalidOperationException]::new('synthetic kill failure') } -PassThru | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMilliseconds) return $true } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
	$Result = Invoke-CleanupFixture -Name fail-safe-job -Baseline @{} -ScanScript { } -DirectProcesses @($Throwing) -Jobs @([pscustomobject]@{ Id = 'client-1'; Job = $Job }) -FailEvidence
	$Deadline = [DateTime]::UtcNow.AddSeconds(10)
	while (@(Get-Process -Id $ClientId, $GrandchildId -ErrorAction SilentlyContinue).Count -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 100 }
	$Survivors = @(Get-Process -Id $ClientId, $GrandchildId -ErrorAction SilentlyContinue)
	$Closed = $false
	try { [void] $Job.GetActiveProcessCount() } catch [System.ObjectDisposedException] { $Closed = $true }
	Assert-True ($Result.Failure -match 'synthetic evidence append failure' -and $Closed -and $Survivors.Count -eq 0) "An evidence failure before the job loop must still close every client job and leave no owned child or grandchild. Actual: $($Result.Failure); survivors: $(($Survivors | ForEach-Object { $_.Id }) -join ',')"
	Write-Output 'PASS: the cleanup fail-safe closes every client job even when evidence writing fails first'
}

function Test-FixtureProcessIdentity {
	# Fixture cleanup must refuse a process whose handle-bound image is outside the root.
	$Outside = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
	try {
		Stop-FixtureProcess $Outside $FixtureRoot 3>$null
		Assert-True (-not $Outside.HasExited) 'Fixture cleanup must never kill a process whose image is outside the fixture root.'
	} finally {
		if (-not $Outside.HasExited) { $Outside.Kill() }
		[void] $Outside.WaitForExit(5000)
		$Outside.Dispose()
	}
	Write-Output 'PASS: fixture cleanup kills only handle-verified fixture-root processes'
}

function Test-JobAssignFailure {
	$InitDefinition = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in @('Initialize-PackagedSmokeClientJobType', 'Start-OwnedClientProcess') }, $true))
	Assert-True ($InitDefinition.Count -eq 2) 'The client job helpers must be uniquely testable.'
	foreach ($Definition in $InitDefinition) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	Initialize-PackagedSmokeClientJobType
	$AssignRoot = Join-Path $FixtureRoot 'assign-failure'
	New-Item -ItemType Directory -Path $AssignRoot | Out-Null
	$Probe = Join-Path $AssignRoot 'AssignProbe.exe'
	Add-Type -TypeDefinition ('public static class AssignProbe' + [guid]::NewGuid().ToString('N') + ' { public static int Main() { System.IO.File.WriteAllText(System.AppDomain.CurrentDomain.BaseDirectory + "ran.txt", "ran"); return 0; } }') -OutputAssembly $Probe -OutputType ConsoleApplication
	# A disposed job cannot accept the suspended process: the assignment fails after
	# CreateProcess, so the process must be terminated before it ever runs.
	$Job = [Aetheln.PackagedSmokeClientJob]::new()
	$Job.Dispose()
	$AssignFailure = $null
	try { [void] (Start-OwnedClientProcess -Job $Job -Executable $Probe -Arguments @() -StdOutPath (Join-Path $AssignRoot 'out.log') -StdErrPath (Join-Path $AssignRoot 'err.log')) } catch { $AssignFailure = $_.Exception.GetBaseException() }
	Start-Sleep -Milliseconds 500
	$Survivors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { [string] $_.Path -ieq $Probe } catch { $false } })
	Assert-True ($AssignFailure -is [System.ObjectDisposedException] -and $Survivors.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $AssignRoot 'ran.txt'))) "A failed job assignment must terminate the suspended client before it runs. Actual: $AssignFailure"
	$Owned = [Aetheln.PackagedSmokeClientJob]::new()
	try {
		$Process = Start-OwnedClientProcess -Job $Owned -Executable $Probe -Arguments @() -StdOutPath (Join-Path $AssignRoot 'owned-out.log') -StdErrPath (Join-Path $AssignRoot 'owned-err.log')
		try { Assert-True ($Process.WaitForExit(10000) -and $Process.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $AssignRoot 'ran.txt'))) 'A successfully assigned client must run to completion with its exit code.' } finally { $Process.Dispose() }
		# The job can still list a member for a few milliseconds while its process object
		# is torn down after WaitForExit returns; production cleanup polls for the same
		# reason. Allow a bounded settle, and require any member listed meanwhile to be
		# an exited process, never a running descendant.
		$Settle = [System.Diagnostics.Stopwatch]::StartNew()
		$RunningMembers = [System.Collections.Generic.List[string]]::new()
		while (($Owned.GetActiveProcessCount() -ne 0 -or @($Owned.GetProcessIds()).Count -ne 0) -and $Settle.ElapsedMilliseconds -lt 2000) {
			foreach ($MemberId in @($Owned.GetProcessIds())) {
				$Member = Get-Process -Id $MemberId -ErrorAction SilentlyContinue
				if ($null -ne $Member) { try { if (-not $Member.HasExited -and $Member.ProcessName) { $RunningMembers.Add("$MemberId=$($Member.ProcessName)") } } finally { $Member.Dispose() } }
			}
			Start-Sleep -Milliseconds 10
		}
		Assert-True ($Owned.GetActiveProcessCount() -eq 0 -and @($Owned.GetProcessIds()).Count -eq 0 -and $RunningMembers.Count -eq 0) "An exited job member must leave zero active and listed processes within 2 seconds, with no running descendant meanwhile. Waited $($Settle.ElapsedMilliseconds) ms; running members: $($RunningMembers -join ',')"
	} finally { $Owned.Dispose() }
	Write-Output 'PASS: a failed job assignment terminates the suspended client before it runs'
}

function Invoke-Smoke([string] $Scenario, [string] $LogRoot, [int] $TimeoutSeconds = 8, [string] $ServerConnectionPattern = 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)', [string] $ClientExecutable = '', [string[]] $ClientArguments = @(), [string] $ServerExecutable = '/package/AethelnOnlineServer.sh', [string] $ErrorPattern = '', [switch] $CaptureStartup, [string] $BuildProvenancePath = '', [string] $ServerProvenanceExecutable = '') {
	$SelectedClientExecutable = if ($ClientExecutable) { $ClientExecutable } else { $PackagedLauncher }
	$SelectedClientArguments = if ($ClientArguments.Count) { $ClientArguments } else { @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', $Scenario) }
	$OptionalArguments = @{}
	if ($ErrorPattern) { $OptionalArguments['ErrorPattern'] = $ErrorPattern }
	if ($CaptureStartup) {
		$OptionalArguments['CaptureStartup'] = $true
		$OptionalArguments['BuildProvenancePath'] = $BuildProvenancePath
		$OptionalArguments['ServerProvenanceExecutable'] = $ServerProvenanceExecutable
	}
	$SelectedServerExecutable = if ($CaptureStartup -and $ServerExecutable -ceq '/package/AethelnOnlineServer.sh') { $HostServerWslPath } else { $ServerExecutable }
	Assert-True ($SelectedClientExecutable.StartsWith($PackageRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) 'Every smoke fixture client must live inside its GUID-scoped package root before cleanup can run.'
	& $Script @OptionalArguments `
		-ServerExecutable $SelectedServerExecutable `
		-ServerLauncherExecutable $LauncherCommandName `
		-ServerLauncherArguments @('-NoProfile', '-File', $FakeLauncher, '-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput', '-Scenario', $Scenario) `
		-ClientExecutable $SelectedClientExecutable `
		-ClientBaseArguments $SelectedClientArguments `
		-ServerEndpoint '127.0.0.1:7777' `
		-ServerMap '/Game/Maps/StarterMap' `
		-LogRoot $LogRoot `
		-ServerReadyPattern 'Listening on {ServerEndpoint}.*{ServerMap}' `
		-ServerClientConnectedPattern $ServerConnectionPattern `
		-ClientConnectedPattern 'Connected {ClientId} to {ServerEndpoint}' `
		-ClientMapPattern 'Loaded {ServerMap}' `
		-TimeoutSeconds $TimeoutSeconds
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	Test-BaselineSnapshot
	Test-DirectCleanupWait
	Test-EvidenceWriter
	Test-CleanupWaitEvidence
	Test-CleanupDecision
	Test-JobCleanupDecision
	Test-JobAssignFailure
	Test-OpaqueInventory
	Test-LiveLogSharing
	Test-FailSafeJobDisposal
	Test-FixtureProcessIdentity
	$PowerShellExecutable = (Get-Process -Id $PID).Path
	$LauncherCommandName = Split-Path -Leaf $PowerShellExecutable
	$FakeLauncher = Join-Path $FixtureRoot 'fake-launcher.ps1'
	Set-Content -LiteralPath $FakeLauncher -Value @'
param([Alias('d')] [string] $Distribution, [Alias('u')] [string] $User, [Alias('exec')] [string] $ServerExecutable, [string] $Map, [string] $Scenario, [Parameter(ValueFromRemainingArguments)] [string[]] $Ignored)
Write-Output "Listening on 127.0.0.1:7777 map $Map"
if ($Scenario -ne 'missing-second') {
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden'
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51002, Name: overridden'
} else {
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden'
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden duplicate'
}
Start-Sleep -Seconds 20
'@ -Encoding UTF8
	$PackageRoot = Join-Path $FixtureRoot 'WindowsClient'
	$RuntimeRoot = Join-Path $PackageRoot 'Binaries'
	New-Item -ItemType Directory -Path $RuntimeRoot | Out-Null
	$PackagedLauncher = Join-Path $PackageRoot 'ClientLauncher.exe'
	$CaptureClientRoot = Join-Path $PackageRoot 'AethelnOnline\Binaries\Win64'
	$CaptureClientExecutable = Join-Path $CaptureClientRoot 'AethelnOnlineClient.exe'
	$PackagedRuntime = Join-Path $RuntimeRoot 'ClientRuntime.exe'
	$RuntimeClass = 'Runtime' + [guid]::NewGuid().ToString('N')
	$RuntimeSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class CLASS {
	private static bool ContainsCleanup(string path) {
		if (!File.Exists(path)) return false;
		using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
		using (StreamReader reader = new StreamReader(stream)) return reader.ReadToEnd().Contains("process_cleanup_started");
	}
	public static int Main(string[] args) {
		if (args.Length == 2 && args[0] == "orphan") {
			// Start a grandchild, publish its PID, and exit so the grandchild is orphaned.
			Process orphan = Process.Start(Process.GetCurrentProcess().MainModule.FileName);
			File.WriteAllText(args[1], orphan.Id.ToString());
			return 0;
		}
		if (args.Length == 2) {
			File.WriteAllText(args[1] + ".ready", Process.GetCurrentProcess().Id.ToString());
			bool cleanupStarted = false;
			while (!cleanupStarted) {
				try { cleanupStarted = ContainsCleanup(args[0]); }
				catch (IOException) { }
				Thread.Sleep(25);
			}
			Thread.Sleep(500);
			Process delayed = Process.Start(Process.GetCurrentProcess().MainModule.FileName);
			File.WriteAllText(args[1], delayed.Id.ToString());
		}
		Thread.Sleep(60000);
		return 0;
	}
}
'@.Replace('CLASS', $RuntimeClass)
	Add-Type -TypeDefinition $RuntimeSource -OutputAssembly $PackagedRuntime -OutputType ConsoleApplication
	$LauncherClass = 'Launcher' + [guid]::NewGuid().ToString('N')
	$LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class CLASS {
	public static int Main(string[] args) {
		string clientId = args[0], endpoint = args[1], map = args[2], scenario = args[3];
		string root = AppDomain.CurrentDomain.BaseDirectory;
		if (scenario == "early-exit" && clientId == "client-2") return 17;
		if (scenario == "logged-error" && clientId == "client-1") Console.WriteLine("Connection TIMED OUT while joining server");
		if (scenario == "child-process" || scenario == "child-process-failure" || scenario == "capture-sibling-child") {
			string archiveRoot = scenario == "capture-sibling-child" ? Path.GetFullPath(Path.Combine(root, "..", "..", "..")) : root;
			Process child = Process.Start(Path.Combine(archiveRoot, "Binaries", "ClientRuntime.exe"));
			File.WriteAllText(Path.Combine(archiveRoot, clientId + "-" + scenario + "-child.pid"), child.Id.ToString());
		}
		if (scenario == "orphan-grandchild") {
			ProcessStartInfo intermediate = new ProcessStartInfo(Path.Combine(root, "Binaries", "ClientRuntime.exe"), "orphan \"" + Path.Combine(root, clientId + "-orphan-grandchild.pid") + "\"");
			intermediate.UseShellExecute = false;
			Process.Start(intermediate).WaitForExit();
		}
		if (scenario != "child-process-failure") {
			Console.WriteLine("Connected " + clientId + " to " + endpoint);
			Console.WriteLine("Loaded " + map);
		}
		Thread.Sleep(20000);
		return 0;
	}
}
'@.Replace('CLASS', $LauncherClass)
	Add-Type -TypeDefinition $LauncherSource -OutputAssembly $PackagedLauncher -OutputType ConsoleApplication
	New-Item -ItemType Directory -Path $CaptureClientRoot | Out-Null
	Copy-Item -LiteralPath $PackagedLauncher -Destination $CaptureClientExecutable
	$ServerPackageRoot = Join-Path $FixtureRoot 'server-package'
	New-Item -ItemType Directory -Path $ServerPackageRoot | Out-Null
	$HostServerLauncher = Join-Path $ServerPackageRoot 'AethelnOnlineServer.sh'
	Set-Content -LiteralPath $HostServerLauncher -Value '# synthetic packaged server launcher' -Encoding UTF8
	$HostServerWslPath = '/mnt/' + $HostServerLauncher.Substring(0, 1).ToLowerInvariant() + '/' + $HostServerLauncher.Substring(3).Replace('\', '/')
	$SourceRevision = 'a' * 40
	$BuildProvenancePath = Join-Path $FixtureRoot 'build-provenance.json'
	$BuildProvenance = [ordered]@{
		schemaVersion = 2
		source = [ordered]@{ revision = $SourceRevision; clean = $true }
		host = [ordered]@{ buildIdentity = "AethelnOnline@$SourceRevision/Development" }
		build = [ordered]@{ configuration = 'Development'; clientPlatform = 'Win64'; serverPlatform = 'Linux' }
		artifacts = [ordered]@{
			clientArchive = $PackageRoot
			serverArchive = $ServerPackageRoot
			inventory = @(
				[ordered]@{ kind = 'client'; path = 'AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe'; sizeBytes = (Get-Item -LiteralPath $CaptureClientExecutable).Length; sha256 = (Get-FileHash -LiteralPath $CaptureClientExecutable -Algorithm SHA256).Hash.ToLowerInvariant() },
				[ordered]@{ kind = 'server'; path = 'AethelnOnlineServer.sh'; sizeBytes = (Get-Item -LiteralPath $HostServerLauncher).Length; sha256 = (Get-FileHash -LiteralPath $HostServerLauncher -Algorithm SHA256).Hash.ToLowerInvariant() }
			)
		}
	}
	$BuildProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BuildProvenancePath -Encoding UTF8

	$LogRoot = Join-Path $FixtureRoot 'success'
	Invoke-Smoke -Scenario success -LogRoot $LogRoot -ServerExecutable '/package/custom/AethelnOnlineServer.sh'
	$Evidence = @(Get-Content -LiteralPath (Join-Path $LogRoot 'smoke-evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
	$ServerStart = @($Evidence | Where-Object { $_.event -eq 'process_started' -and $_.process -eq 'server' })
	Assert-True ($ServerStart.Count -eq 1 -and $ServerStart[0].detail -like '*--exec /package/custom/AethelnOnlineServer.sh /Game/Maps/StarterMap*' -and $ServerStart[0].detail -notlike '*{ServerExecutable}*') 'The caller-supplied ServerExecutable must replace its placeholder in the launched server arguments.'
	Assert-True ($Evidence.Count -ge 9) 'Evidence should include launch and correlated readiness observations.'
	Assert-True (-not @($Evidence | Where-Object { -not $_.schema -or -not $_.timestamp -or -not $_.process -or -not $_.role -or -not $_.event -or -not $_.source }).Count) 'Every evidence line should use the smoke evidence schema.'
	$ServerConnections = @($Evidence | Where-Object { $_.event -eq 'server_observed_connection' })
	Assert-True ($ServerConnections.Count -eq 2) 'Server evidence should contain exactly two unique observed connections.'
	Assert-True (@($ServerConnections.connection_id | Sort-Object -Unique).Count -eq 2) 'Server evidence should use distinct ConnectionId captures without mapping them to client names.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'client_map_confirmed' }).Count -eq 2) 'Both clients should confirm the requested map.'
	Assert-True (@($Evidence | Where-Object { $_.event -in @('client_connected', 'client_map_confirmed') -and $_.source -like '*client-*.stdout.log' }).Count -eq 4) 'Client evidence should come from redirected packaged-client stdout.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'server.log'))) 'WSL-style launch should not depend on a Windows server log path.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'client-1.log'))) 'Client launch should not depend on Unreal accepting a Windows -log path.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'server_listening' -and $_.source -like '*server.stdout.log' }).Count -eq 1) 'Server readiness evidence should come from redirected WSL stdout.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'process_started' -and $_.process -eq 'server' -and $_.source -eq $PowerShellExecutable }).Count -eq 1) 'PATH launcher resolution should produce one concrete executable string.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'startup-capture.json'))) 'The default packaged smoke must not create an Issue #45 startup capture.'
	Write-Output 'PASS: correlated packaged connection evidence is emitted as JSONL'

	$CaptureLogRoot = Join-Path $FixtureRoot 'capture-success'
	Invoke-Smoke -Scenario success -LogRoot $CaptureLogRoot -ClientExecutable $CaptureClientExecutable -CaptureStartup -BuildProvenancePath $BuildProvenancePath -ServerProvenanceExecutable $HostServerLauncher
	$CapturePath = Join-Path $CaptureLogRoot 'startup-capture.json'
	Assert-True (Test-Path -LiteralPath $CapturePath -PathType Leaf) 'An opted-in successful smoke must produce a startup capture.'
	$Capture = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json
	Assert-True ($Capture.schema -ceq 'aetheln.packaged-smoke.startup-capture/v1' -and $Capture.classification -ceq 'measured' -and $Capture.method -ceq 'windows_host_launch_to_stdout_map_observation_upper_bound' -and $Capture.sourceRevision -ceq $SourceRevision) 'Capture must label the observed upper-bound method and bind the exact source revision.'
	Assert-True ($Capture.provenance.sha256 -ceq (Get-FileHash -LiteralPath $BuildProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant() -and $Capture.package.client.sha256 -ceq (Get-FileHash -LiteralPath $CaptureClientExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -and $Capture.package.client.relativePath -ceq 'AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe' -and $Capture.package.server.sha256 -ceq (Get-FileHash -LiteralPath $HostServerLauncher -Algorithm SHA256).Hash.ToLowerInvariant()) 'Capture must bind provenance, the inner game executable, and the packaged server launcher bytes.'
	Assert-True (@($Capture.clients).Count -eq 2 -and $Capture.clients[0].id -ceq 'client-1' -and $Capture.clients[1].id -ceq 'client-2') 'Capture must include the exact two launched Windows clients.'
	Assert-True (@($Capture.clients | Where-Object { $_.launchToMapObservationMilliseconds -ge 0 -and $_.workingSetBytes -gt 0 -and $_.peakWorkingSetBytes -gt 0 -and $_.privateMemoryBytes -gt 0 -and $_.pid -gt 0 }).Count -eq 2) 'Both live clients must have nonnegative launch-to-map observation upper bounds and measured Windows process memory.'
	Assert-True ($Capture.serverMetrics.status -ceq 'unknown' -and $Capture.serverMetrics.reason -ceq 'linux_server_not_observed_by_windows_process_snapshot' -and $Capture.combatMetrics.status -ceq 'unknown') 'WSL launcher observations must never be promoted to Linux server or representative combat measurements.'
	Assert-True ($Capture.scenario.topology.status -ceq 'unknown' -and $Capture.serverLauncher.path -ceq $PowerShellExecutable -and $Capture.serverExecution.status -ceq 'unknown' -and $Capture.package.server.identityBasis -ceq 'declared_provenance_inventory') 'A configurable fake launcher must be recorded without claiming verified WSL topology or Linux server execution.'
	Assert-True ($Capture.smokeEvidence.cleanup -ceq 'complete' -and $Capture.smokeEvidence.sha256 -ceq (Get-FileHash -LiteralPath (Join-Path $CaptureLogRoot 'smoke-evidence.jsonl') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Successful capture must bind the final smoke evidence only after cleanup completes.'
	Write-Output 'PASS: opt-in startup capture binds provenance and measures both live Windows clients without inferring unsupported metrics'
	$BroadClientRoot = Join-Path $FixtureRoot 'broad-client-archive'
	$BroadClientExecutable = Join-Path $BroadClientRoot 'AethelnOnline\Binaries\Win64\AethelnOnlineClient.exe'
	New-Item -ItemType Directory -Path (Split-Path -Parent $BroadClientExecutable) | Out-Null
	Copy-Item -LiteralPath $CaptureClientExecutable -Destination $BroadClientExecutable
	$BroadProvenancePath = Join-Path $FixtureRoot 'broad-client-provenance.json'
	$BroadProvenance = $BuildProvenance | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	$BroadProvenance.artifacts.clientArchive = $BroadClientRoot
	$BroadProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BroadProvenancePath -Encoding UTF8
	$BroadLogRoot = Join-Path $FixtureRoot 'capture-broad-client-archive'
	$BroadFailure = $null
	try {
		& $Script -ServerExecutable $HostServerWslPath -ServerLauncherExecutable $LauncherCommandName -ServerLauncherArguments @('-NoProfile', '-File', $FakeLauncher, '-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput', '-Scenario', 'success') -ClientExecutable $BroadClientExecutable -ClientBaseArguments @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'success') -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' -LogRoot $BroadLogRoot -ServerReadyPattern 'Listening on {ServerEndpoint}.*{ServerMap}' -ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' -ClientConnectedPattern 'Connected {ClientId} to {ServerEndpoint}' -ClientMapPattern 'Loaded {ServerMap}' -TimeoutSeconds 8 -CaptureStartup -BuildProvenancePath $BroadProvenancePath -ServerProvenanceExecutable $HostServerLauncher
	} catch { $BroadFailure = $_.Exception.Message }
	Assert-True ($BroadFailure -match 'WindowsClient' -and -not (Test-Path -LiteralPath $BroadLogRoot)) "A valid inner executable and inventory under a noncanonical archive must fail before launch or log-root creation. Actual: $BroadFailure"
	Write-Output 'PASS: capture rejects a broad client archive before launch'
	$SiblingCaptureLogRoot = Join-Path $FixtureRoot 'capture-sibling-child'
	Invoke-Smoke -Scenario capture-sibling-child -LogRoot $SiblingCaptureLogRoot -ClientExecutable $CaptureClientExecutable -CaptureStartup -BuildProvenancePath $BuildProvenancePath -ServerProvenanceExecutable $HostServerLauncher
	$SiblingChildProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-capture-sibling-child-child.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
	Assert-True ($SiblingChildProcessIds.Count -eq 2) 'The capture fixture must launch one packaged helper beside the inner game directory for each client.'
	Assert-True (-not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $SiblingChildProcessIds }).Count) 'Capture cleanup must terminate smoke-owned sibling helpers before recording completion.'
	$SiblingCapture = Get-Content -LiteralPath (Join-Path $SiblingCaptureLogRoot 'startup-capture.json') -Raw | ConvertFrom-Json
	Assert-True ($SiblingCapture.smokeEvidence.cleanup -ceq 'complete') 'Capture must record cleanup completion only after sibling helpers are gone.'
	Write-Output 'PASS: capture cleanup covers smoke-owned helpers beside the inner game directory'
	foreach ($CaptureHelperName in @('Assert-NoReparsePath', 'Get-PackagedExecutableBinding', 'Get-StartupProvenance', 'Assert-StableStartupProvenance', 'Initialize-CaptureDirectoryPin', 'Get-CaptureDirectoryPins', 'Assert-CaptureDirectoryPins', 'Write-StartupCapture')) {
		$CaptureHelper = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $CaptureHelperName }, $true))
		Assert-True ($CaptureHelper.Count -eq 1) "The $CaptureHelperName helper must be uniquely testable."
		. ([scriptblock]::Create($CaptureHelper[0].Extent.Text))
	}
	$CaptureBytes = [System.IO.File]::ReadAllBytes($CapturePath)
	$OverwriteFailure = $null
	try { Write-StartupCapture -Path $CapturePath -Document @{ schema = 'overwrite-attempt' } } catch { $OverwriteFailure = $_.Exception.Message }
	Assert-True ($OverwriteFailure -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($CapturePath)) -ceq [Convert]::ToBase64String($CaptureBytes)) 'Create-only capture publication must preserve an existing record byte-for-byte.'
	Write-Output 'PASS: startup capture publication refuses overwrite'
	$InterruptedCapturePath = Join-Path $CaptureLogRoot 'interrupted-startup-capture.json'
	$PublishFailure = $null
	try { Write-StartupCapture -Path $InterruptedCapturePath -Document @{ schema = 'synthetic-partial-write' } -AfterTempWrite { throw 'synthetic interrupted publication' } } catch { $PublishFailure = $_.Exception.Message }
	Assert-True ($PublishFailure -match 'synthetic interrupted publication' -and -not (Test-Path -LiteralPath $InterruptedCapturePath) -and -not @(Get-ChildItem -LiteralPath $CaptureLogRoot -Filter '.startup-capture-*.tmp' -Force).Count) 'An interrupted write must leave neither final-named evidence nor a temporary file.'
	Write-Output 'PASS: interrupted startup publication leaves no final or temporary evidence'
	$PreSwapAncestor = Join-Path $FixtureRoot 'pre-swap-ancestor'
	$PreSwapOutput = Join-Path $PreSwapAncestor 'output'
	$PreParkedAncestor = Join-Path $FixtureRoot 'pre-parked-ancestor'
	$PreVictimAncestor = Join-Path $FixtureRoot 'pre-victim-ancestor'
	$PreVictimOutput = Join-Path $PreVictimAncestor 'output'
	New-Item -ItemType Directory -Path $PreSwapOutput | Out-Null
	New-Item -ItemType Directory -Path $PreVictimOutput | Out-Null
	$PreVictimFinal = Join-Path $PreVictimOutput 'startup-capture.json'
	Set-Content -LiteralPath $PreVictimFinal -Value 'pre-open unrelated victim final bytes' -Encoding UTF8
	$PreVictimBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PreVictimFinal))
	$PreSwapState = @{ MoveSucceeded = $false; MoveDenied = $false }
	$PreSwapFailure = $null
	try {
		Write-StartupCapture -Path (Join-Path $PreSwapOutput 'startup-capture.json') -Document @{ schema = 'synthetic-pre-open-swap' } -AfterDirectoryPin {
			try { Move-Item -LiteralPath $PreSwapAncestor -Destination $PreParkedAncestor -ErrorAction Stop; $PreSwapState.MoveSucceeded = $true } catch { $PreSwapState.MoveDenied = $true; throw 'synthetic pre-open ancestor move denied' }
			New-Item -ItemType Junction -Path $PreSwapAncestor -Target $PreVictimAncestor -ErrorAction Stop | Out-Null
		}
	} catch { $PreSwapFailure = $_.Exception.Message }
	$PreActualOutput = if ($PreSwapState.MoveSucceeded) { Join-Path $PreParkedAncestor 'output' } else { $PreSwapOutput }
	Assert-True (($PreSwapState.MoveDenied -or $PreSwapState.MoveSucceeded) -and (($PreSwapState.MoveDenied -and $PreSwapFailure -match 'synthetic pre-open ancestor move denied') -or ($PreSwapState.MoveSucceeded -and $PreSwapFailure -match 'capture_output_ancestor_changed')) -and -not @(Get-ChildItem -LiteralPath $PreVictimOutput -Filter '.startup-capture-*.tmp' -Force).Count -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PreVictimFinal)) -ceq $PreVictimBefore -and -not @(Get-ChildItem -LiteralPath $PreActualOutput -Force).Count) 'A pre-open ancestor swap must be denied or fail before writing bytes, preserving victim files and discarding only its own empty temporary file.'
	$FixturePrefix = [System.IO.Path]::GetFullPath($FixtureRoot).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
	Assert-True ([System.IO.Path]::GetFullPath($PreSwapAncestor).StartsWith($FixturePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Path]::GetFullPath($PreParkedAncestor).StartsWith($FixturePrefix, [System.StringComparison]::OrdinalIgnoreCase)) 'The pre-open swap fixture paths must stay within the isolated root.'
	if ($PreSwapState.MoveSucceeded) {
		$PreSwapJunction = Get-Item -LiteralPath $PreSwapAncestor -Force
		Assert-True (($PreSwapJunction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $PreSwapJunction.LinkType -ceq 'Junction' -and [System.IO.Path]::GetFullPath([string] $PreSwapJunction.Target) -ceq [System.IO.Path]::GetFullPath($PreVictimAncestor)) 'Only the exact pre-open fixture junction may be removed.'
		[System.IO.Directory]::Delete($PreSwapAncestor)
		Move-Item -LiteralPath $PreParkedAncestor -Destination $PreSwapAncestor -ErrorAction Stop
	}
	Write-Output 'PASS: pre-open ancestor swap is denied or fails closed, with victim bytes preserved'
	$MountOutput = Join-Path $FixtureRoot 'mount-output'
	$MountVictim = Join-Path $FixtureRoot 'mount-victim'
	New-Item -ItemType Directory -Path $MountOutput | Out-Null
	New-Item -ItemType Directory -Path $MountVictim | Out-Null
	$MountVictimFinal = Join-Path $MountVictim 'startup-capture.json'
	Set-Content -LiteralPath $MountVictimFinal -Value 'mount-point victim final bytes' -Encoding UTF8
	$MountVictimBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($MountVictimFinal))
	$MountState = @{ Swapped = $false }
	$MountFailure = $null
	try {
		Write-StartupCapture -Path (Join-Path $MountOutput 'startup-capture.json') -Document @{ schema = 'synthetic-in-place-mount-swap' } -AfterDirectoryPin {
			Set-FixtureMountPoint -Directory $MountOutput -Target $MountVictim
			$MountState.Swapped = $true
		}
	} catch { $MountFailure = $_.Exception.Message }
	Assert-True ($MountState.Swapped -and $MountFailure -match 'capture_(output_ancestor_changed|temp_create_failed)' -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($MountVictimFinal)) -ceq $MountVictimBefore -and @((Get-ChildItem -LiteralPath $MountVictim -Force)).Count -eq 1) 'An in-place output mount-point swap must fail closed without creating or deleting any victim entry.'
	$MountItem = Get-Item -LiteralPath $MountOutput -Force
	Assert-True ([System.IO.Path]::GetFullPath($MountOutput).StartsWith($FixturePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and ($MountItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) 'Only the exact fixture-owned mount point may be removed.'
	[System.IO.Directory]::Delete($MountOutput)
	Write-Output 'PASS: in-place mount-point swap leaves victim directory byte-for-byte unchanged'
	$SwapAncestor = Join-Path $FixtureRoot 'swap-ancestor'
	$SwapOutput = Join-Path $SwapAncestor 'output'
	$ParkedAncestor = Join-Path $FixtureRoot 'parked-swap-ancestor'
	New-Item -ItemType Directory -Path $SwapOutput | Out-Null
	$VictimAncestor = Join-Path $FixtureRoot 'victim-ancestor'
	$VictimOutput = Join-Path $VictimAncestor 'output'
	New-Item -ItemType Directory -Path $VictimOutput | Out-Null
	$VictimFinal = Join-Path $VictimOutput 'startup-capture.json'
	Set-Content -LiteralPath $VictimFinal -Value 'unrelated victim final bytes' -Encoding UTF8
	$VictimFinalBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($VictimFinal))
	$SwapState = @{ MoveSucceeded = $false; MoveDenied = $false; VictimTemp = ''; VictimTempBefore = '' }
	$SwapFailure = $null
	try {
		Write-StartupCapture -Path (Join-Path $SwapOutput 'startup-capture.json') -Document @{ schema = 'synthetic-ancestor-swap' } -AfterTempWrite {
			$TempName = (Get-ChildItem -LiteralPath $SwapOutput -Filter '.startup-capture-*.tmp' -Force | Select-Object -First 1).Name
			$VictimTemp = Join-Path $VictimOutput $TempName
			Set-Content -LiteralPath $VictimTemp -Value 'unrelated victim temporary bytes' -Encoding UTF8
			$SwapState.VictimTemp = $VictimTemp
			$SwapState.VictimTempBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($VictimTemp))
			try { Move-Item -LiteralPath $SwapAncestor -Destination $ParkedAncestor -ErrorAction Stop; $SwapState.MoveSucceeded = $true } catch { $SwapState.MoveDenied = $true; throw 'synthetic ancestor move denied' }
			# A replaced junction would route both File.Move and temp cleanup to
			# unrelated same-named victim files if ancestor identity were unpinned.
			New-Item -ItemType Junction -Path $SwapAncestor -Target $VictimAncestor -ErrorAction Stop | Out-Null
		}
	} catch { $SwapFailure = $_.Exception.Message }
	$ActualOutput = if ($SwapState.MoveSucceeded) { Join-Path $ParkedAncestor 'output' } else { $SwapOutput }
	Assert-True (($SwapState.MoveDenied -or $SwapState.MoveSucceeded) -and (($SwapState.MoveDenied -and $SwapFailure -match 'synthetic ancestor move denied') -or ($SwapState.MoveSucceeded -and $SwapFailure -match 'capture_output_ancestor_changed')) -and -not (Test-Path -LiteralPath (Join-Path $ActualOutput 'startup-capture.json')) -and -not @(Get-ChildItem -LiteralPath $ActualOutput -Filter '.startup-capture-*.tmp' -Force).Count -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($VictimFinal)) -ceq $VictimFinalBefore -and [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($SwapState.VictimTemp)) -ceq $SwapState.VictimTempBefore) 'After temp open, ancestor swap must either be denied or fail closed with handle-only cleanup, leaving victim files unchanged.'
	Assert-True ([System.IO.Path]::GetFullPath($SwapAncestor).StartsWith($FixturePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and [System.IO.Path]::GetFullPath($ParkedAncestor).StartsWith($FixturePrefix, [System.StringComparison]::OrdinalIgnoreCase)) 'The post-publication rename probe must stay within its isolated fixture root.'
	if ($SwapState.MoveSucceeded) {
		$SwapJunction = Get-Item -LiteralPath $SwapAncestor -Force
		Assert-True (($SwapJunction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $SwapJunction.LinkType -ceq 'Junction' -and [System.IO.Path]::GetFullPath([string] $SwapJunction.Target) -ceq [System.IO.Path]::GetFullPath($VictimAncestor)) 'Only the exact fixture-owned junction may be removed.'
		[System.IO.Directory]::Delete($SwapAncestor)
		Move-Item -LiteralPath $ParkedAncestor -Destination $SwapAncestor -ErrorAction Stop
	}
	Write-Output 'PASS: open-temp ancestor swap is denied or fails closed, with victim bytes preserved'
	$MissingProvenanceRoot = Join-Path $FixtureRoot 'capture-missing-provenance'
	$CaptureFailure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $MissingProvenanceRoot -CaptureStartup } catch { $CaptureFailure = $_.Exception.Message }
	Assert-True ($CaptureFailure -match 'CaptureStartup requires BuildProvenancePath' -and -not (Test-Path -LiteralPath $MissingProvenanceRoot)) 'Opt-in without both identity inputs must fail before launch or log-root creation.'
	$RootBootstrapProvenancePath = Join-Path $FixtureRoot 'root-bootstrap-provenance.json'
	$RootBootstrapProvenance = $BuildProvenance | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	$RootBootstrapProvenance.artifacts.inventory[0].path = 'ClientLauncher.exe'
	$RootBootstrapProvenance.artifacts.inventory[0].sizeBytes = (Get-Item -LiteralPath $PackagedLauncher).Length
	$RootBootstrapProvenance.artifacts.inventory[0].sha256 = (Get-FileHash -LiteralPath $PackagedLauncher -Algorithm SHA256).Hash.ToLowerInvariant()
	$RootBootstrapProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RootBootstrapProvenancePath -Encoding UTF8
	$RootBootstrapLogRoot = Join-Path $FixtureRoot 'capture-root-bootstrap'
	$CaptureFailure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $RootBootstrapLogRoot -ClientExecutable $PackagedLauncher -CaptureStartup -BuildProvenancePath $RootBootstrapProvenancePath -ServerProvenanceExecutable $HostServerLauncher } catch { $CaptureFailure = $_.Exception.Message }
	Assert-True ($CaptureFailure -match 'inner packaged Win64 game executable' -and -not (Test-Path -LiteralPath $RootBootstrapLogRoot)) 'An inventory-valid root bootstrap must be rejected before smoke launch rather than measured as a client game process.'
	Write-Output 'PASS: capture requires provenance-bound inner packaged game executable, not root bootstrap'
	$OriginalProvenanceBytes = [System.IO.File]::ReadAllBytes($BuildProvenancePath)
	$OriginalProvenanceHash = (Get-FileHash -LiteralPath $BuildProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
	$ChangedProvenance = $BuildProvenance | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	$ChangedProvenance.source.revision = 'b' * 40
	$ChangedProvenance.host.buildIdentity = "AethelnOnline@$($ChangedProvenance.source.revision)/Development"
	try {
		$ReadBinding = Get-StartupProvenance -Path $BuildProvenancePath -ClientPath $CaptureClientExecutable -ServerPath $HostServerLauncher -AfterProvenanceRead {
			$ChangedProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BuildProvenancePath -Encoding UTF8
		}
		$StableFailure = $null
		try { Assert-StableStartupProvenance -Binding $ReadBinding } catch { $StableFailure = $_.Exception.Message }
		Assert-True ($ReadBinding.sha256 -ceq $OriginalProvenanceHash -and $ReadBinding.sourceRevision -ceq $SourceRevision -and $StableFailure -match 'provenance changed during smoke') 'Provenance source fields and SHA must bind the same read bytes, then detect a path swap.'
	} finally { [System.IO.File]::WriteAllBytes($BuildProvenancePath, $OriginalProvenanceBytes) }
	Write-Output 'PASS: provenance parser and SHA bind the same BOM-bearing bytes across a deterministic path swap'

	$BadProvenancePath = Join-Path $FixtureRoot 'bad-build-provenance.json'
	$BadProvenance = $BuildProvenance | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	$BadProvenance.artifacts.inventory[0].sha256 = '0' * 64
	$BadProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BadProvenancePath -Encoding UTF8
	$BadLogRoot = Join-Path $FixtureRoot 'capture-bad-provenance'
	$CaptureFailure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $BadLogRoot -ClientExecutable $CaptureClientExecutable -CaptureStartup -BuildProvenancePath $BadProvenancePath -ServerProvenanceExecutable $HostServerLauncher } catch { $CaptureFailure = $_.Exception.Message }
	Assert-True ($CaptureFailure -match 'provenance.*client.*identity' -and -not (Test-Path -LiteralPath (Join-Path $BadLogRoot 'startup-capture.json'))) "Tampered client inventory must reject capture before launch. Actual: $CaptureFailure"
	$DuplicateProvenancePath = Join-Path $FixtureRoot 'duplicate-build-provenance.json'
	$DuplicateProvenance = $BuildProvenance | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	$DuplicateProvenance.artifacts.inventory = @($DuplicateProvenance.artifacts.inventory) + @($DuplicateProvenance.artifacts.inventory[0])
	$DuplicateProvenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DuplicateProvenancePath -Encoding UTF8
	$DuplicateLogRoot = Join-Path $FixtureRoot 'capture-duplicate-provenance'
	$CaptureFailure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $DuplicateLogRoot -ClientExecutable $CaptureClientExecutable -CaptureStartup -BuildProvenancePath $DuplicateProvenancePath -ServerProvenanceExecutable $HostServerLauncher } catch { $CaptureFailure = $_.Exception.Message }
	Assert-True ($CaptureFailure -match 'provenance.*client.*not unique' -and -not (Test-Path -LiteralPath $DuplicateLogRoot)) 'Duplicate executable inventory entries must fail before launch.'
	$WrongServerRoot = Join-Path $FixtureRoot 'capture-wrong-server-mapping'
	$CaptureFailure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $WrongServerRoot -ClientExecutable $CaptureClientExecutable -CaptureStartup -BuildProvenancePath $BuildProvenancePath -ServerProvenanceExecutable $HostServerLauncher -ServerExecutable '/mnt/z/other/AethelnOnlineServer.sh' } catch { $CaptureFailure = $_.Exception.Message }
	Assert-True ($CaptureFailure -match 'does not map.*default WSL drive mount' -and -not (Test-Path -LiteralPath $WrongServerRoot)) 'The launched Linux path must match the exact host-visible provenance-bound server file before launch.'
	Write-Output 'PASS: invalid packaged provenance fails before startup capture'

	$ChildLogRoot = Join-Path $FixtureRoot 'child-process'
	$ChildArguments = @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'child-process')
	Invoke-Smoke -Scenario child-process -LogRoot $ChildLogRoot -ClientExecutable $PackagedLauncher -ClientArguments $ChildArguments
	$ChildProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-child-process-child.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
	Assert-True ($ChildProcessIds.Count -eq 2) 'The fixture must launch one differently named packaged runtime per client.'
	Assert-True (-not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $ChildProcessIds }).Count) 'Successful smoke cleanup must terminate differently named packaged client child processes through the client jobs.'
	$ChildJobEvidence = @(Get-Content -LiteralPath (Join-Path $ChildLogRoot 'smoke-evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'process_cleanup_job' })
	Assert-True ($ChildJobEvidence.Count -eq 2 -and -not @($ChildJobEvidence | Where-Object { $_.detail -notlike '*activeProcesses=0; listedProcesses=0.' }).Count) 'Each client job must record zero active and listed members after cleanup.'
	foreach ($ChildProcessId in $ChildProcessIds) { Assert-True (@($ChildJobEvidence | Where-Object { $_.detail -match "\b$ChildProcessId\b" }).Count -eq 1) "Child PID $ChildProcessId must appear as exactly one client job member." }
	Write-Output 'PASS: client jobs own and reap packaged client child processes'

	$OrphanLogRoot = Join-Path $FixtureRoot 'orphan-grandchild'
	Invoke-Smoke -Scenario orphan-grandchild -LogRoot $OrphanLogRoot -ClientExecutable $PackagedLauncher -ClientArguments @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'orphan-grandchild')
	$OrphanProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-orphan-grandchild.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
	Assert-True ($OrphanProcessIds.Count -eq 2) 'Each client must start an intermediate that orphans one grandchild.'
	Assert-True (-not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $OrphanProcessIds }).Count) 'An orphaned grandchild inside a client job must be terminated even though its parent exited.'
	$OrphanJobEvidence = @(Get-Content -LiteralPath (Join-Path $OrphanLogRoot 'smoke-evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'process_cleanup_job' })
	foreach ($OrphanProcessId in $OrphanProcessIds) { Assert-True (@($OrphanJobEvidence | Where-Object { $_.detail -match "\b$OrphanProcessId\b" -and $_.detail -like '*activeProcesses=0; listedProcesses=0.' }).Count -eq 1) "Orphan PID $OrphanProcessId must be recorded as a reaped client job member." }
	Write-Output 'PASS: client jobs reap orphaned grandchildren'

	$UnrelatedLogRoot = Join-Path $FixtureRoot 'unrelated-archive-process'
	$UnrelatedMarker = Join-Path $PackageRoot 'unrelated-delayed.pid'
	# The watcher is not a smoke descendant. It starts a new process from the same
	# package after the baseline, while cleanup runs; that process must survive.
	$UnrelatedWatcher = Start-Process -FilePath $PackagedRuntime -ArgumentList @((Join-Path $UnrelatedLogRoot 'smoke-evidence.jsonl'), $UnrelatedMarker) -RedirectStandardOutput (Join-Path $FixtureRoot 'unrelated-watcher.stdout.log') -RedirectStandardError (Join-Path $FixtureRoot 'unrelated-watcher.stderr.log') -WindowStyle Hidden -PassThru
	$UnrelatedDelayed = $null
	try {
		$ReadyDeadline = [DateTime]::UtcNow.AddSeconds(5)
		while (-not (Test-Path -LiteralPath "$UnrelatedMarker.ready") -and [DateTime]::UtcNow -lt $ReadyDeadline) { Start-Sleep -Milliseconds 50 }
		Assert-True (Test-Path -LiteralPath "$UnrelatedMarker.ready") 'The unrelated watcher must be ready before the smoke baseline.'
		$Failure = $null
		try { Invoke-Smoke -Scenario success -LogRoot $UnrelatedLogRoot } catch { $Failure = $_.Exception.Message }
		Assert-True (Test-Path -LiteralPath $UnrelatedMarker -PathType Leaf) "The unrelated watcher must publish its delayed process PID before cleanup returns; retained evidence: $FixtureRoot."
		$UnrelatedDelayedId = [int] (Get-Content -LiteralPath $UnrelatedMarker -Raw)
		$UnrelatedDelayed = Get-Process -Id $UnrelatedDelayedId -ErrorAction SilentlyContinue
		Assert-True ($null -ne $UnrelatedDelayed -and -not $UnrelatedWatcher.HasExited) 'A process started from the same package outside the client jobs must never be terminated by smoke cleanup.'
		Assert-True ($Failure -match 'outside smoke-owned jobs.*not terminated and cleanup is not complete') "An untracked same-package process must fail the smoke closed instead of claiming cleanup. Actual: $Failure"
		$UnrelatedEvidence = @(Get-Content -LiteralPath (Join-Path $UnrelatedLogRoot 'smoke-evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
		Assert-True (@($UnrelatedEvidence | Where-Object { $_.event -eq 'process_cleanup_untracked' -and $_.detail -match "\b$UnrelatedDelayedId\b" }).Count -eq 1 -and -not @($UnrelatedEvidence | Where-Object { $_.event -eq 'process_cleanup_complete' }).Count) 'The untracked process must be recorded without a cleanup completion record.'
		Write-Output 'PASS: an unrelated same-package process started during the smoke survives and fails cleanup closed'
	} finally {
		foreach ($FixtureOwned in @($UnrelatedDelayed, $UnrelatedWatcher)) {
			if ($null -eq $FixtureOwned) { continue }
			Stop-FixtureProcess $FixtureOwned $FixtureRoot
			$FixtureOwned.Dispose()
		}
	}

	$FailureLogRoot = Join-Path $FixtureRoot 'child-process-failure'
	$PreexistingFailureRuntime = Start-Process -FilePath $PackagedRuntime -RedirectStandardOutput (Join-Path $FixtureRoot 'failure-preexisting.stdout.log') -RedirectStandardError (Join-Path $FixtureRoot 'failure-preexisting.stderr.log') -WindowStyle Hidden -PassThru
	try {
		$Failure = $null
		$FailureArguments = @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'child-process-failure')
		try { Invoke-Smoke -Scenario child-process-failure -LogRoot $FailureLogRoot -TimeoutSeconds 3 -ClientExecutable $PackagedLauncher -ClientArguments $FailureArguments } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match 'Timed out after 3 seconds.*client connection confirmation') "The failure fixture must reach client evidence timeout with the caller-supplied bound after spawning packaged runtimes. Actual failure: $Failure"
		$FailureChildProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-child-process-failure-child.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
		Assert-True ($FailureChildProcessIds.Count -eq 2 -and -not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $FailureChildProcessIds }).Count) 'Failed smoke cleanup must terminate differently named packaged client child processes through the client jobs.'
		Assert-True (-not $PreexistingFailureRuntime.HasExited) 'Failed smoke cleanup must preserve a preexisting process under the package root.'
		Write-Output 'PASS: failed smoke cleanup reaps job-owned children without touching preexisting package processes'
	} finally {
		Stop-FixtureProcess $PreexistingFailureRuntime $FixtureRoot
		$PreexistingFailureRuntime.Dispose()
	}

	$EvidenceCountBeforeReuse = $Evidence.Count
	$Failure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $LogRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'LogRoot.*must be absent or empty.*existing item.*unique clean directory') 'Reusing smoke evidence output should fail actionably.'
	$EvidenceAfterReuse = @(Get-Content -LiteralPath (Join-Path $LogRoot 'smoke-evidence.jsonl'))
	Assert-True ($EvidenceAfterReuse.Count -eq $EvidenceCountBeforeReuse) 'Rejected reuse must not append or overwrite run-specific evidence.'
	Write-Output 'PASS: non-empty LogRoot reuse is rejected before evidence is written'

	$Failure = $null
	try { Invoke-Smoke -Scenario missing-second -LogRoot (Join-Path $FixtureRoot 'missing') -TimeoutSeconds 3 } catch { $Failure = $_.Exception.Message }
	Write-Output "Observed missing-client failure: $Failure"
	Assert-True ($Failure -match 'two unique server connections.*only 1 unique.*server\.stdout\.log') 'A duplicate server connection line must not satisfy the two-connection requirement.'
	Write-Output 'PASS: duplicate server connection IDs do not count twice'

	$Failure = $null
	try { Invoke-Smoke -Scenario success -LogRoot (Join-Path $FixtureRoot 'invalid-pattern') -ServerConnectionPattern 'AddClientConnection:.*RemoteAddr: ([^,]+)' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must contain a named regex capture.*ConnectionId') 'The server connection contract should reject an unnamed identity capture.'
	Write-Output 'PASS: server connection pattern requires the ConnectionId capture'

	$Failure = $null
	try { Invoke-Smoke -Scenario early-exit -LogRoot (Join-Path $FixtureRoot 'exit') -TimeoutSeconds 10 } catch { $Failure = $_.Exception.Message }
	Write-Output "Observed early-exit failure: $Failure"
	Assert-True ($Failure -match 'client-2.*exited.*exit code.*client-2\.stdout\.log.*client-2\.stderr\.log') 'Early client exit should identify its role, exit-code field, and actionable redirected logs.'
	Write-Output 'PASS: early process exit fails actionably'

	$Failure = $null
	try { Invoke-Smoke -Scenario logged-error -LogRoot (Join-Path $FixtureRoot 'error') -TimeoutSeconds 10 } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'client-1 reported an error.*Connection TIMED OUT') 'A connection timeout log event should fail even when readiness text is present.'
	Write-Output 'PASS: connection-timeout source-log events fail the smoke'

	$Failure = $null
	try { Invoke-Smoke -Scenario success -LogRoot (Join-Path $FixtureRoot 'error-pattern') -TimeoutSeconds 10 -ErrorPattern 'Connected client-2 to' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'client-2 reported an error while waiting for client connection confirmation.*Connected client-2 to') "A caller-supplied ErrorPattern must reach the client evidence wait instead of the default pattern. Actual failure: $Failure"
	Write-Output 'PASS: nondefault ErrorPattern flows into evidence waits'
	$ClientStarts = @(Get-ChildItem -LiteralPath $FixtureRoot -Filter 'smoke-evidence.jsonl' -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName | ForEach-Object { $_ | ConvertFrom-Json } } | Where-Object { $_.event -eq 'process_started' -and $_.role -eq 'client' })
	Assert-True ($ClientStarts.Count -ge 12) 'Isolation evidence must include client launches across success and failure scenarios.'
	Assert-True (-not @($ClientStarts | Where-Object { -not $_.source.StartsWith($PackageRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) }).Count) 'Every actual smoke client launch must remain inside this GUID-scoped package root.'
	Write-Output 'PASS: all smoke fixture client launches use an isolated package root'
	$SuiteCompleted = $true
}
finally {
	foreach ($FixtureProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
		try { $FixtureProcessPath = [string] $FixtureProcess.Path } catch { $FixtureProcess.Dispose(); continue }
		# The enumerated path only selects candidates; Stop-FixtureProcess revalidates the
		# image through a bound handle before any kill.
		if ($FixtureProcessPath -and $FixtureProcessPath.StartsWith($FixtureRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
			Stop-FixtureProcess $FixtureProcess $FixtureRoot
		}
		$FixtureProcess.Dispose()
	}
	if ($SuiteCompleted -and (Test-Path -LiteralPath $FixtureRoot)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
	elseif (Test-Path -LiteralPath $FixtureRoot) { Write-Output "Failed smoke fixture evidence retained: $FixtureRoot" }
}
