param([string] $YamlAssemblyPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'GitHub preparation adapter is missing' }
. $Module

function Assert-Condition($Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}
function Assert-Failure([scriptblock] $Action, [string] $Code) {
	$Actual = ''
	try { & $Action | Out-Null } catch { $Actual = $_.Exception.Message }
	Assert-Condition -Condition ($Actual -ceq $Code) -Message "Expected $Code; received $Actual"
}

# Exercise the actual .NET Framework transport: redirected StreamWriter defaults
# must not inject a UTF-8 BOM into Git batch identities or API request bodies.
Initialize-PreparationGitHubTransport
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PreparationArgumentFixture {
 [DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)]string command,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
 public static string[] Parse(string command) {
  int count; IntPtr pointer=CommandLineToArgvW(command,out count);
  if(pointer==IntPtr.Zero) throw new InvalidOperationException("argument_fixture_failed");
  try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer,i*IntPtr.Size)); return result; }
  finally { LocalFree(pointer); }
 }
}
'@
foreach ($ArgumentTag in @('"strong"', 'W/"weak"', 'W/"with\slash"')) {
	$HeaderArgument = 'If-None-Match: ' + $ArgumentTag
	$ParsedArguments = [PreparationArgumentFixture]::Parse('gh.exe --header ' + [Aetheln.PreparationGitHubTransport]::QuoteArgument($HeaderArgument) + ' sentinel')
	Assert-Condition -Condition ($ParsedArguments.Count -eq 4 -and $ParsedArguments[2] -ceq $HeaderArgument -and $ParsedArguments[3] -ceq 'sentinel') -Message 'Quoted ETag did not survive as exactly one native argument'
}
$OriginalInputEncoding = [Console]::InputEncoding
$InputProbe = '$s=[Console]::OpenStandardInput();$m=New-Object IO.MemoryStream;$s.CopyTo($m);[Console]::Write([BitConverter]::ToString($m.ToArray()))'
$InputProbeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($InputProbe))
$NativeInput = [Aetheln.PreparationGitHubTransport]::Run((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -EncodedCommand ' + $InputProbeEncoded), "abc`n", 10000)
Assert-Condition -Condition ($NativeInput.ExitCode -eq 0 -and $NativeInput.Output -ceq '61-62-63-0A') -Message ('Transport changed synthetic request bytes: exit=' + $NativeInput.ExitCode + '; output=' + $NativeInput.Output)
$EmptyInput = [Aetheln.PreparationGitHubTransport]::Run((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -EncodedCommand ' + $InputProbeEncoded), $null, 10000)
Assert-Condition -Condition ($EmptyInput.ExitCode -eq 0 -and $EmptyInput.Output.Length -eq 0) -Message 'Empty stdin must contain no BOM'
Assert-Condition -Condition ([Console]::InputEncoding.CodePage -eq $OriginalInputEncoding.CodePage -and [BitConverter]::ToString([Console]::InputEncoding.GetPreamble()) -ceq [BitConverter]::ToString($OriginalInputEncoding.GetPreamble())) -Message 'Transport did not restore process input encoding'
$UnreadProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 30'))
$UnreadTimer = [Diagnostics.Stopwatch]::StartNew()
$UnreadFailed = $false
try { $null = [Aetheln.PreparationGitHubTransport]::Run((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -EncodedCommand ' + $UnreadProbe), ('x' * 100000), 500) }
catch { $UnreadFailed = $_.Exception.ToString().Contains('github_api_timeout') }
$UnreadTimer.Stop()
Assert-Condition -Condition ($UnreadFailed -and $UnreadTimer.Elapsed.TotalSeconds -lt 5) -Message 'Unread stdin bypassed the transport deadline'
$StartFailed = $false
try { $null = [Aetheln.PreparationGitHubTransport]::Run((Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.exe')), '', $null, 1000) }
catch { $StartFailed = $true }
Assert-Condition -Condition ($StartFailed -and [Console]::InputEncoding.CodePage -eq $OriginalInputEncoding.CodePage -and [BitConverter]::ToString([Console]::InputEncoding.GetPreamble()) -ceq [BitConverter]::ToString($OriginalInputEncoding.GetPreamble())) -Message 'Failed startup did not restore encoding'

$Fixture = [pscustomobject]@{
	labels = @('self-hosted', 'Windows', 'X64', 'aetheln-engine', 'unrelated')
	requests = New-Object Collections.ArrayList
	status = 'online'
	corruptRemoval = $false
	failRestore = $false
}
$Transport = {
	param($Request)
	[void] $Fixture.requests.Add($Request)
	if ($Request.method -ceq 'DELETE') {
		if ($Request.path -cnotmatch '/labels/aetheln-engine$') { throw 'unexpected_label_mutation' }
		$Fixture.labels = @($Fixture.labels | Where-Object { $_ -cne 'aetheln-engine' })
		if ($Fixture.corruptRemoval) { $Fixture.labels = @($Fixture.labels | Where-Object { $_ -cne 'unrelated' }) }
	} elseif ($Request.method -ceq 'POST') {
		if ($Fixture.failRestore) { throw 'transport_failed' }
		Assert-Condition -Condition ($Request.body.labels.Count -eq 1 -and $Request.body.labels[0] -ceq 'aetheln-engine') -Message 'Restoration must add only the routing label.'
		$Fixture.labels = @($Fixture.labels) + @('aetheln-engine')
	} elseif ($Request.method -cne 'GET') { throw 'unexpected_method' }
	$Labels = @($Fixture.labels | ForEach-Object { [pscustomobject]@{ name = $_; type = $(if ($_ -in @('self-hosted', 'Windows', 'X64')) { 'read-only' } else { 'custom' }) } })
	if ($Request.path -cmatch '/labels(?:\?|$)' -or $Request.method -cne 'GET') {
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = $Labels.Count; labels = $Labels } }
	}
	return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ id = 21; name = 'aetheln-engine-pc'; status = $Fixture.status; busy = $false; labels = $Labels } }
}

$Runner = Get-InitialPreparationRunner -Repository 'owner/repository' -RunnerId 21 -ExpectedName 'aetheln-engine-pc' -Transport $Transport
Assert-Condition -Condition ($Runner.originalLabels.Count -eq 5) -Message 'Original complete labels must be retained.'
$null = Set-InitialPreparationQuarantine -Runner $Runner -Transport $Transport
Assert-Condition -Condition ($Fixture.labels.Count -eq 4 -and $Fixture.labels -cnotcontains 'aetheln-engine') -Message 'Only the custom routing label may be removed.'
$null = Restore-InitialPreparationRouting -Runner $Runner -Transport $Transport
Assert-Condition -Condition ($Fixture.labels.Count -eq 5 -and $Fixture.labels -ccontains 'unrelated') -Message 'Restoration must preserve unrelated labels.'
Assert-Condition -Condition (@($Fixture.requests | Where-Object { $_.method -ceq 'PUT' }).Count -eq 0) -Message 'Replace-all label operations are forbidden.'

$Fixture.corruptRemoval = $true
Assert-Failure -Action { Set-InitialPreparationQuarantine -Runner $Runner -Transport $Transport } -Code 'label_readback_mismatch'
$Fixture.corruptRemoval = $false
$Fixture.labels = @('self-hosted', 'Windows', 'X64', 'unrelated')
$Fixture.failRestore = $true
Assert-Failure -Action { Restore-InitialPreparationRouting -Runner $Runner -Transport $Transport } -Code 'label_restoration_failed'
$Fixture.failRestore = $false
$Fixture.status = 'offline'
Assert-Failure -Action { Get-InitialPreparationRunner -Repository 'owner/repository' -RunnerId 21 -ExpectedName 'aetheln-engine-pc' -Transport $Transport } -Code 'runner_offline'
$Fixture.status = 'online'
Assert-Failure -Action { Get-InitialPreparationRunner -Repository 'owner/repository' -RunnerId 21 -ExpectedName 'different-runner' -Transport $Transport } -Code 'runner_identity_mismatch'

. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
$AdmissionAttempt = New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId 'admission-fixture'
$AdmissionClock = [pscustomobject]@{ ticks = $AdmissionAttempt.monotonicStartTicks; busyAlways = $false; injectLateAssignment = $true; safe = $true }
$ReadClock = { return $AdmissionClock.ticks }
$AdvanceClock = { param($Milliseconds) $AdmissionClock.ticks += [long] ($Milliseconds * $AdmissionAttempt.monotonicFrequency / 1000) }
$Inventory = {
	$Elapsed = ($AdmissionClock.ticks - $AdmissionAttempt.monotonicStartTicks) / $AdmissionAttempt.monotonicFrequency
	$Busy = $AdmissionClock.busyAlways -or ($AdmissionClock.injectLateAssignment -and $Elapsed -ge 60 -and $Elapsed -lt 70)
	return [pscustomobject]@{ complete = $true; routesSafe = $AdmissionClock.safe; runnerId = 21; runnerName = 'aetheln-engine-pc'; online = $true; busy = [bool] $Busy;
		labels = @('self-hosted', 'Windows', 'X64', 'unrelated'); activeJobs = @(); activityKey = $(if ($Busy) { 'assigned' } else { 'idle' }) }
}
$LocalProbe = { return [pscustomobject]@{ complete = $true; activeProcessCount = 0 } }
$Admission = Wait-InitialPreparationAdmission -Attempt $AdmissionAttempt -Runner $Runner -InventoryProbe $Inventory -LocalWorkerProbe $LocalProbe -ReadTicks $ReadClock -DelayMilliseconds $AdvanceClock
Assert-Condition -Condition ($Admission.admitted -and ($AdmissionClock.ticks - $AdmissionAttempt.monotonicStartTicks) / $AdmissionAttempt.monotonicFrequency -ge 190) -Message 'A late assignment must reset the entire 120-second quiet interval.'
Assert-Condition -Condition ($Admission.observation.activityKey -ceq 'idle' -and -not $Admission.observation.busy) -Message 'Admission must carry its actual final observation to runtime monitoring.'
$AdmissionClock.ticks = $AdmissionAttempt.monotonicStartTicks
$AdmissionClock.busyAlways = $true
$Admission = Wait-InitialPreparationAdmission -Attempt $AdmissionAttempt -Runner $Runner -InventoryProbe $Inventory -LocalWorkerProbe $LocalProbe -ReadTicks $ReadClock -DelayMilliseconds $AdvanceClock
Assert-Condition -Condition (-not $Admission.admitted -and $Admission.code -ceq 'maintenance_not_admitted' -and $AdmissionClock.ticks -eq $AdmissionAttempt.admissionDeadlineTicks) -Message 'Healthy work exceeding the admission window must be left alone and admission must expire.'
$AdmissionClock.ticks = $AdmissionAttempt.monotonicStartTicks
$AdmissionClock.busyAlways = $false
$AdmissionClock.safe = $false
$Admission = Wait-InitialPreparationAdmission -Attempt $AdmissionAttempt -Runner $Runner -InventoryProbe $Inventory -LocalWorkerProbe $LocalProbe -ReadTicks $ReadClock -DelayMilliseconds $AdvanceClock
Assert-Condition -Condition (-not $Admission.admitted -and $Admission.reason -ceq 'inventory_incomplete') -Message 'Unresolved or bypassing routes must never be admitted.'

$PaginationFixture = [pscustomobject]@{ omitNext = $false; duplicate = $false; changeTotal = $false; pages = 0 }
$PageTransport = {
	param($Request)
	$PaginationFixture.pages++
	$Second = $Request.path -match 'page=2(?:&|$)'
	$Rows = if ($Second) { @([pscustomobject]@{ id = $(if ($PaginationFixture.duplicate) { 1 } else { 101 }) }) }
		else { @(1..100 | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
	$Headers = @{}
	if (-not $Second -and -not $PaginationFixture.omitNext) { $Headers['Link'] = '<https://api.github.com/repos/owner/repository/actions/runners?per_page=100&page=2>; rel="next"' }
	return [pscustomobject]@{ statusCode = 200; headers = $Headers; data = [pscustomobject]@{ total_count = $(if ($Second -and $PaginationFixture.changeTotal) { 102 } else { 101 }); runners = $Rows } }
}
$Pages = Get-PreparationGitHubPageSet -Path 'repos/owner/repository/actions/runners' -CollectionName runners -Transport $PageTransport
Assert-Condition -Condition ($Pages.items.Count -eq 101 -and $Pages.pageCount -eq 2) -Message 'Inventory must consume every page.'
$PaginationFixture.omitNext = $true
Assert-Failure -Action { Get-PreparationGitHubPageSet -Path 'repos/owner/repository/actions/runners' -CollectionName runners -Transport $PageTransport } -Code 'inventory_incomplete'
$PaginationFixture.omitNext = $false
$PaginationFixture.duplicate = $true
Assert-Failure -Action { Get-PreparationGitHubPageSet -Path 'repos/owner/repository/actions/runners' -CollectionName runners -Transport $PageTransport } -Code 'inventory_incomplete'
$PaginationFixture.duplicate = $false
$PaginationFixture.changeTotal = $true
Assert-Failure -Action { Get-PreparationGitHubPageSet -Path 'repos/owner/repository/actions/runners' -CollectionName runners -Transport $PageTransport } -Code 'inventory_incomplete'

$QueueFixture = [pscustomobject]@{ secondRunner = $false; active = $false; attemptDrift = $false; requestedStatuses = New-Object Collections.ArrayList }
$QueueTransport = {
	param($Request)
	if ($Request.path -match '/actions/runners\?') {
		$RunnerRows = @([pscustomobject]@{ id = 21; name = 'aetheln-engine-pc'; status = 'online'; busy = $false; labels = @([pscustomobject]@{ name = 'aetheln-engine' }) })
		if ($QueueFixture.secondRunner) { $RunnerRows += [pscustomobject]@{ id = 22; name = 'other-engine'; status = 'online'; busy = $false; labels = @([pscustomobject]@{ name = 'aetheln-engine' }) } }
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = $RunnerRows.Count; runners = $RunnerRows } }
	}
	if ($Request.path -match '/actions/runs\?status=([^&]+)') {
		$RequestedStatus = $Matches[1]
		[void] $QueueFixture.requestedStatuses.Add($RequestedStatus)
		if ($QueueFixture.active -and $RequestedStatus -ceq 'in_progress') {
			return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = 1; workflow_runs = @([pscustomobject]@{ id = 10; status = 'in_progress'; head_sha = ('a' * 40); run_attempt = 2 }) } }
		}
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = 0; workflow_runs = @() } }
	}
	if ($Request.path -match '/runs/10/attempts/2/jobs\?') {
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = 1; jobs = @([pscustomobject]@{ id = 100; run_id = 10; head_sha = ('a' * 40); status = 'in_progress'; runner_id = 21; labels = @('self-hosted', 'aetheln-engine') }) } }
	}
	if ($Request.path -match '/runs/10$') {
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ id = 10; status = 'in_progress'; head_sha = ('a' * 40); run_attempt = $(if ($QueueFixture.attemptDrift) { 3 } else { 2 }) } }
	}
	throw 'unexpected_inventory_request'
}
$Queue = Get-InitialPreparationQueueInventory -Repository 'owner/repository' -ExpectedRunnerId 21 -ExpectedRunnerName 'aetheln-engine-pc' -Transport $QueueTransport
Assert-Condition -Condition ($Queue.complete -and $Queue.jobs.Count -eq 0 -and $QueueFixture.requestedStatuses.Count -eq 5) -Message 'Every nonterminal workflow-run status must be inventoried.'
$QueueFixture.secondRunner = $true
Assert-Failure -Action { Get-InitialPreparationQueueInventory -Repository 'owner/repository' -ExpectedRunnerId 21 -ExpectedRunnerName 'aetheln-engine-pc' -Transport $QueueTransport } -Code 'unexpected_shared_engine_runner'
$QueueFixture.secondRunner = $false
$QueueFixture.active = $true
$Queue = Get-InitialPreparationQueueInventory -Repository 'owner/repository' -ExpectedRunnerId 21 -ExpectedRunnerName 'aetheln-engine-pc' -Transport $QueueTransport
Assert-Condition -Condition ($Queue.activeJobs.Count -eq 1 -and $Queue.jobs[0].runAttempt -eq 2) -Message 'Assigned active work must bind the current run attempt and head.'
$QueueFixture.attemptDrift = $true
Assert-Failure -Action { Get-InitialPreparationQueueInventory -Repository 'owner/repository' -ExpectedRunnerId 21 -ExpectedRunnerName 'aetheln-engine-pc' -Transport $QueueTransport } -Code 'inventory_incomplete'
Assert-Failure -Action {
	Get-PreparationGitHubPageSet -Path 'repos/owner/repository/pulls' -Transport {
		param($Request)
		$null = $Request
		return [pscustomobject]@{ statusCode = 200; headers = @{ Link = 'malformed' }; data = @([pscustomobject]@{ id = 1 }) }
	}
} -Code 'inventory_incomplete'

if (-not $YamlAssemblyPath) { throw 'Supply the pinned YamlDotNet net47 assembly path for workflow fixtures.' }
$Workflow = @'
name: fixture
on: [push]
jobs:
  hosted:
    runs-on: windows-latest
    steps:
      - run: echo ok
  engine:
    runs-on: [self-hosted, Windows, X64, aetheln-engine]
    steps:
      - run: echo ok
'@
$Capabilities = @('self-hosted', 'Windows', 'X64', 'aetheln-engine')
$Routes = Get-PreparationWorkflowRoute -Yaml $Workflow -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath
Assert-Condition -Condition ($Routes.Count -eq 2 -and @($Routes | Where-Object { $_.eligible }).Count -eq 1) -Message 'Every job must be classified from parsed YAML.'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml ($Workflow.Replace(', aetheln-engine', '')) -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'eligible_route_bypasses_label'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml ($Workflow.Replace('[self-hosted, Windows, X64, aetheln-engine]', '${{ matrix.runner }}')) -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml ($Workflow + "`n  engine:`n    runs-on: windows-latest") -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'workflow_yaml_invalid'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: owner/repo/.github/workflows/other.yml@main" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
$CallRoutes = Get-PreparationWorkflowRoute -Yaml ($Workflow + "`n  visual-proof:`n    uses: ./.github/workflows/visual-package-validation.yml`n    with:`n      non_authoritative: true") -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath
Assert-Condition -Condition ($CallRoutes.Count -eq 2 -and @($CallRoutes | Where-Object { $_.jobId -ceq 'visual-proof' }).Count -eq 0) -Message 'A local reusable-workflow call has no runner of its own and must not produce a route.'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: ./.github/workflows/other.yml@main" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml ("jobs:`n  caller:`n    uses: ./.github/workflows/" + '${{ matrix.workflow }}' + '.yml') -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: ./.github/workflows/../x.yml" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: ./.github/workflows/sub/x.yml" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: [./.github/workflows/x.yml]" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml ("jobs:`n  caller:`n    uses: " + '"./.github/workflows/a.yml\n"') -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: |`n      ./.github/workflows/a.yml`n" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  caller:`n    uses: ./.github/workflows/x.yml`n    runs-on: [self-hosted, Windows, X64]" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'routing_dynamic_unresolved'
Assert-Failure -Action { Get-PreparationWorkflowRoute -Yaml "jobs:`n  engine: &shared`n    runs-on: windows-latest`n  other: *shared" -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath } -Code 'workflow_yaml_invalid'

$SourceFixture = [pscustomobject]@{ blobMismatch = $false; truncated = $false; revision = ('a' * 40); blob = $null; bytes = [Text.Encoding]::UTF8.GetBytes($Workflow); corruptHash = $false; symlink = $false; commitDrift = $false }
$SourceHasher = [Security.Cryptography.SHA1]::Create()
try {
	$GitHeader = [Text.Encoding]::ASCII.GetBytes(('blob ' + $SourceFixture.bytes.Length + [char]0))
	$SourceFixture.blob = ([BitConverter]::ToString($SourceHasher.ComputeHash([byte[]] ($GitHeader + $SourceFixture.bytes)))).Replace('-', '').ToLowerInvariant()
} finally { $SourceHasher.Dispose() }
$SourceTransport = {
	param($Request)
	$Data = $null
	if ($Request.path -match '/git/commits/') { $Data = [pscustomobject]@{ sha = $SourceFixture.revision; tree = [pscustomobject]@{ sha = ('b' * 40) } } }
	elseif ($Request.path -match ('/git/trees/' + ('b' * 40) + '$')) { $Data = [pscustomobject]@{ sha = ('b' * 40); truncated = $false; tree = @([pscustomobject]@{ path = '.github'; mode = '040000'; type = 'tree'; sha = ('c' * 40) }) } }
	elseif ($Request.path -match ('/git/trees/' + ('c' * 40) + '$')) { $Data = [pscustomobject]@{ sha = ('c' * 40); truncated = $false; tree = @([pscustomobject]@{ path = 'workflows'; mode = '040000'; type = 'tree'; sha = ('d' * 40) }) } }
	elseif ($Request.path -match ('/git/trees/' + ('d' * 40) + '$')) { $Data = [pscustomobject]@{ sha = ('d' * 40); truncated = $SourceFixture.truncated; tree = @([pscustomobject]@{ path = 'ci.yml'; mode = '100644'; type = 'blob'; sha = $SourceFixture.blob }) } }
	elseif ($Request.path -match '/git/blobs/') { $Data = [pscustomobject]@{ sha = $SourceFixture.blob; encoding = 'base64'; size = $SourceFixture.bytes.Length; content = [Convert]::ToBase64String($(if ($SourceFixture.blobMismatch) { [Text.Encoding]::UTF8.GetBytes('different bytes') } else { $SourceFixture.bytes })) } }
	else { throw 'unexpected_source_request' }
	if ($SourceFixture.commitDrift -and $Request.path -match '/git/commits/') { $Data.sha = 'e' * 40 }
	if ($SourceFixture.symlink -and $Request.path -match ('/git/trees/' + ('d' * 40) + '$')) { $Data.tree[0].mode = '120000' }
	if ($SourceFixture.corruptHash -and $Request.path -match '/git/blobs/') {
		$CorruptBytes = [byte[]] $SourceFixture.bytes.Clone()
		$CorruptBytes[0] = $CorruptBytes[0] -bxor 1
		$Data.content = [Convert]::ToBase64String($CorruptBytes)
	}
	return [pscustomobject]@{ statusCode = 200; headers = @{}; data = $Data }
}
$Sources = Get-PreparationWorkflowSource -Repository 'owner/repository' -Revision $SourceFixture.revision -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $SourceTransport
Assert-Condition -Condition ($Sources.Count -eq 1 -and $Sources[0].revision -ceq $SourceFixture.revision -and $Sources[0].blobId -ceq $SourceFixture.blob -and $Sources[0].routes.Count -eq 2) -Message 'Parsed routing must bind the exact commit tree and workflow blob.'
$SourceFixture.blobMismatch = $true
Assert-Failure -Action { Get-PreparationWorkflowSource -Repository 'owner/repository' -Revision $SourceFixture.revision -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $SourceTransport } -Code 'workflow_source_invalid'
$SourceFixture.blobMismatch = $false
$SourceFixture.truncated = $true
Assert-Failure -Action { Get-PreparationWorkflowSource -Repository 'owner/repository' -Revision $SourceFixture.revision -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $SourceTransport } -Code 'workflow_source_invalid'
$SourceFixture.truncated = $false
foreach ($FailureMode in @('commitDrift', 'symlink', 'corruptHash')) {
	$SourceFixture.$FailureMode = $true
	Assert-Failure -Action { Get-PreparationWorkflowSource -Repository 'owner/repository' -Revision $SourceFixture.revision -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $SourceTransport } -Code 'workflow_source_invalid'
	$SourceFixture.$FailureMode = $false
}

foreach ($JsonFixture in @('[]', '[{"id":4457848873}]', '[{"id":4457848873},{"id":4477675804}]')) {
	$ParsedBody = ConvertFrom-PreparationGitHubJson -Json $JsonFixture
	$ExpectedBody = ('{"rows":' + $JsonFixture + '}') | ConvertFrom-Json
	Assert-Condition -Condition ($ParsedBody -is [array] -and $ParsedBody.Count -eq $ExpectedBody.rows.Count) -Message 'JSON arrays must retain their exact shape on Windows PowerShell 5.1.'
	foreach ($ParsedRow in $ParsedBody) { Assert-Condition -Condition ($ParsedRow.id -is [long]) -Message 'Large GitHub IDs must remain scalar Int64 fields, not nested arrays.' }
}

Assert-Failure -Action { ConvertFrom-PreparationGitHubJson -Json '1,"unexpected":2' } -Code 'github_response_invalid'

$RevisionFixture = [pscustomobject]@{ mergeable = $true; badParents = $false; wrongRepository = $false; defaultSha = ('a' * 40); mergeBase = ('a' * 40) }
$RevisionTransport = {
	param($Request)
	$Data = $null
	if ($Request.path -ceq 'repos/owner/repository') {
		$Data = [pscustomobject]@{ full_name = 'owner/repository'; default_branch = 'develop' }
	} elseif ($Request.path -ceq 'repos/owner/repository/git/ref/heads/develop') {
		$Data = [pscustomobject]@{ ref = 'refs/heads/develop'; object = [pscustomobject]@{ type = 'commit'; sha = $RevisionFixture.defaultSha } }
	} elseif ($Request.path -match '/pulls\?') {
		$Data = @([pscustomobject]@{ id = 100; number = 1 })
	} elseif ($Request.path -ceq 'repos/owner/repository/pulls/1') {
		$Data = [pscustomobject]@{ id = 100; number = 1; state = 'open'; mergeable = $RevisionFixture.mergeable
			head = [pscustomobject]@{ sha = ('b' * 40); repo = [pscustomobject]@{ full_name = 'fork/repository' } }
			base = [pscustomobject]@{ ref = 'develop'; sha = ('a' * 40); repo = [pscustomobject]@{ full_name = $(if ($RevisionFixture.wrongRepository) { 'other/repository' } else { 'owner/repository' }) } }
		}
	} elseif ($Request.path -ceq 'repos/owner/repository/git/ref/pull/1/merge') {
		$Data = [pscustomobject]@{ ref = 'refs/pull/1/merge'; object = [pscustomobject]@{ type = 'commit'; sha = ('c' * 40) } }
	} elseif ($Request.path -ceq ('repos/owner/repository/git/commits/' + ('c' * 40))) {
		$Data = [pscustomobject]@{ sha = ('c' * 40); parents = @([pscustomobject]@{ sha = $RevisionFixture.mergeBase }, [pscustomobject]@{ sha = $(if ($RevisionFixture.badParents) { 'd' * 40 } else { 'b' * 40 }) }) }
	} else { throw 'unexpected_revision_request' }
	return [pscustomobject]@{ statusCode = 200; headers = @{}; data = $Data }
}
$Revisions = Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport
Assert-Condition -Condition ($Revisions.revisions.Count -eq 4 -and $Revisions.pullRequests.Count -eq 1 -and $Revisions.revisions[1].repository -ceq 'fork/repository') -Message 'Default, fork head, base and validated test merge must all be represented.'
$RevisionFixture.badParents = $true
Assert-Failure -Action { Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport } -Code 'revision_inventory_invalid'
$RevisionFixture.badParents = $false
$RevisionFixture.mergeable = $null
Assert-Failure -Action { Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport } -Code 'revision_inventory_invalid'
$RevisionFixture.mergeable = $false
$Revisions = Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport
Assert-Condition -Condition ($Revisions.revisions.Count -eq 3 -and $null -eq $Revisions.pullRequests[0].mergeSha) -Message 'Conflicted PRs retain head/base coverage without claiming a test merge.'
$RevisionFixture.mergeable = $true
$RevisionFixture.wrongRepository = $true
Assert-Failure -Action { Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport } -Code 'revision_inventory_invalid'
$RevisionFixture.wrongRepository = $false
$RevisionFixture.defaultSha = 'e' * 40
$RevisionFixture.mergeBase = 'd' * 40
$Revisions = Get-PreparationRevisionInventory -Repository 'owner/repository' -Transport $RevisionTransport
Assert-Condition -Condition ($Revisions.revisions.Count -eq 6 -and $Revisions.pullRequests[0].currentBaseSha -ceq ('e' * 40) -and $Revisions.pullRequests[0].mergeBaseSha -ceq ('d' * 40)) -Message 'Reported base, live base and historical merge parent require distinct source coverage.'
$RevisionFixture.defaultSha = 'a' * 40
$RevisionFixture.mergeBase = 'a' * 40

$RoutingFixture = [pscustomobject]@{ changeDuringRead = $false }
$ReferenceTransport = {
	param($Request)
	if ($Request.path -match '/git/commits/([a-f0-9]{40})$') {
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ sha = $Matches[1]; tree = [pscustomobject]@{ sha = ('b' * 40) }; parents = @([pscustomobject]@{ sha = ('a' * 40) }, [pscustomobject]@{ sha = ('b' * 40) }) } }
	}
	if ($Request.path -match '/git/(trees|blobs)/') {
		if ($RoutingFixture.changeDuringRead) { $RevisionFixture.defaultSha = 'e' * 40 }
		return (& $SourceTransport $Request)
	}
	return (& $RevisionTransport $Request)
}
$ReferenceRoutes = Get-PreparationReferenceRouting -Repository owner/repository -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $ReferenceTransport
Assert-Condition -Condition ($ReferenceRoutes.referencesStable -and $ReferenceRoutes.sources.Count -eq 3) -Message 'Distinct immutable sources must be read once per repository and revision, followed by reference revalidation.'
$RoutingFixture.changeDuringRead = $true
Assert-Failure -Action { Get-PreparationReferenceRouting -Repository owner/repository -RunnerLabels $Capabilities -YamlAssemblyPath $YamlAssemblyPath -Transport $ReferenceTransport } -Code 'revision_inventory_changed'
$RoutingFixture.changeDuringRead = $false
$RevisionFixture.defaultSha = 'a' * 40

$AdmissionFixture = [pscustomobject]@{ sourceReads = 0; queueReads = 0; lateAssignment = $false; unknownEvent = $false; labelOrderDrift = $false }
$AdmissionTransport = {
	param($Request)
	if ($Request.path -match '/actions/') {
		if ($Request.path -match '/actions/runners\?') {
			$AdmissionFixture.queueReads++
			if ($AdmissionFixture.lateAssignment -and $AdmissionFixture.queueReads -gt 1) { $QueueFixture.active = $true }
		}
		$Reply = & $QueueTransport $Request
		if ($Request.path -match '/actions/runners\?') {
			$Reply.data.runners[0].labels = @($Capabilities | ForEach-Object { [pscustomobject]@{ name = $_ } })
			if ($AdmissionFixture.labelOrderDrift -and $AdmissionFixture.queueReads % 2 -eq 0) { [array]::Reverse($Reply.data.runners[0].labels) }
		}
		if ($Request.path -match '/actions/runs\?') {
			foreach ($RunRow in $Reply.data.workflow_runs) {
				$RunRow | Add-Member -NotePropertyName event -NotePropertyValue $(if ($AdmissionFixture.unknownEvent) { 'pull_request_target' } else { 'push' })
				$RunRow | Add-Member -NotePropertyName path -NotePropertyValue '.github/workflows/ci.yml'
				$RunRow | Add-Member -NotePropertyName head_repository -NotePropertyValue ([pscustomobject]@{ full_name = 'owner/repository' })
			}
		}
		return $Reply
	}
	if ($Request.path -match '/git/blobs/') { $AdmissionFixture.sourceReads++ }
	return (& $ReferenceTransport $Request)
}
$QueueFixture.attemptDrift = $false
$QueueFixture.active = $false
$AdmissionCache = @{}
$AdmissionRunner = [pscustomobject]@{ repository = 'owner/repository'; id = 21; name = 'aetheln-engine-pc'; originalLabels = $Capabilities }
$ObservedAdmission = Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport
Assert-Condition -Condition ($ObservedAdmission.complete -and $ObservedAdmission.routesSafe -and $ObservedAdmission.activeJobs.Count -eq 0) -Message 'Real inventory composition must provide every admission field without admitting by itself.'
$InitialSourceReads = $AdmissionFixture.sourceReads
$null = Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport
Assert-Condition -Condition ($InitialSourceReads -gt 0 -and $AdmissionFixture.sourceReads -eq $InitialSourceReads) -Message 'Unchanged immutable sources must be cached while fresh queues are re-read.'
$AdmissionFixture.labelOrderDrift = $true
$ObservedAdmission = Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport
Assert-Condition -Condition ($ObservedAdmission.complete) -Message 'Label set ordering alone must not cause a false activity change.'
$AdmissionFixture.labelOrderDrift = $false
$QueueFixture.active = $true
$ObservedAdmission = Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport
Assert-Condition -Condition ($ObservedAdmission.activeJobs.Count -eq 1) -Message 'Known active workflow must remain visible to the quiet-period gate.'
$AdmissionFixture.unknownEvent = $true
Assert-Failure -Action { Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport } -Code 'active_run_source_unresolved'
$AdmissionFixture.unknownEvent = $false
$QueueFixture.active = $false
$AdmissionFixture.queueReads = 0
$AdmissionFixture.lateAssignment = $true
Assert-Failure -Action { Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport } -Code 'inventory_changed'
$AdmissionFixture.lateAssignment = $false
$QueueFixture.active = $false

# Two-second successful API calls reproduce cumulative runtime latency without
# sleeping or touching GitHub. A cold worker must not repeat full admission.
$RuntimeTiming = [pscustomobject]@{ milliseconds = 0; requests = 0; delay = 2000; smallestTimeout = 30000; paths = New-Object Collections.ArrayList }
$DelayedAdmissionTransport = {
	param($Request)
	$RuntimeTiming.milliseconds += $RuntimeTiming.delay
	$RuntimeTiming.requests++
	[void] $RuntimeTiming.paths.Add($Request.path)
	if ($Request.PSObject.Properties.Name -ccontains 'timeoutMilliseconds') { $RuntimeTiming.smallestTimeout = [Math]::Min($RuntimeTiming.smallestTimeout, $Request.timeoutMilliseconds) }
	return (& $AdmissionTransport $Request)
}
$RuntimeAttempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ('runtime-' + [guid]::NewGuid().ToString('N'))
$RuntimeClock = { return $RuntimeAttempt.monotonicStartTicks + [long] ($RuntimeTiming.milliseconds * $RuntimeAttempt.monotonicFrequency / 1000) }
$RuntimeCycle = [pscustomobject]@{ startedTicks = 0L; finishedTicks = $null; requestCount = 0; phase = ''; failureCode = $null }
$RuntimeProof = (Get-InitialPreparationAdmissionInventory -Runner $AdmissionRunner -YamlAssemblyPath $YamlAssemblyPath -Cache $AdmissionCache -Transport $AdmissionTransport).runtimeProof
$RuntimeResult = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport
Assert-Condition -Condition ($RuntimeTiming.milliseconds -eq 52000 -and $RuntimeTiming.requests -eq 26 -and $RuntimeResult.complete -and $RuntimeCycle.phase -ceq 'complete') -Message 'Frozen runtime should need26 requests/52 virtual seconds, not33/66'
Assert-Condition -Condition (@($RuntimeTiming.paths | Where-Object { $_ -ceq 'repos/owner/repository' }).Count -eq 2 -and @($RuntimeTiming.paths | Where-Object { $_ -match '/actions/runners\?' }).Count -eq 2 -and @($RuntimeTiming.paths | Where-Object { $_ -match '/git/(trees|blobs)/' }).Count -eq 0) -Message 'Runtime must bracket queues with two reference sweeps and never download sources'
Assert-Condition -Condition ($RuntimeTiming.smallestTimeout -eq 5000) -Message 'Late requests must inherit the remaining aggregate deadline'
$RuntimeTiming.milliseconds = 0; $RuntimeTiming.requests = 0; $RuntimeTiming.delay = 3000
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport } -Code 'runtime_cycle_deadline'
Assert-Condition -Condition ($RuntimeTiming.requests -eq 19 -and $RuntimeCycle.failureCode -ceq 'runtime_cycle_deadline') -Message 'Cumulative successful requests must stop at the aggregate budget'
$RuntimeTiming.milliseconds = 0; $RuntimeTiming.requests = 0; $RuntimeTiming.delay = 0
$RevisionFixture.defaultSha = 'e' * 40
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport } -Code 'runtime_references_changed'
$RevisionFixture.defaultSha = 'a' * 40
$AdmissionFixture.queueReads = 0; $AdmissionFixture.lateAssignment = $true
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport } -Code 'inventory_changed'
$AdmissionFixture.lateAssignment = $false; $QueueFixture.active = $true
$RuntimeResult = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport
Assert-Condition -Condition ($RuntimeResult.activeJobs.Count -eq 1) -Message 'Known immutable active source still reaches the consumer rejection gate'
$UnknownProof = $RuntimeProof | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$UnknownProof.sources = @($UnknownProof.sources | Where-Object { $_.revision -cne ('a' * 40) })
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $UnknownProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport } -Code 'active_run_source_unresolved'
$AdmissionFixture.unknownEvent = $true
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $DelayedAdmissionTransport } -Code 'active_run_source_unresolved'
$AdmissionFixture.unknownEvent = $false; $QueueFixture.active = $false
$BadRuntimeProof = $RuntimeProof | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$BadRuntimeProof.sources[0].workflows[0].routes[0].labels = @('self-hosted')
Assert-Failure -Action { Assert-InitialPreparationRuntimeProof -Proof $BadRuntimeProof -Runner $AdmissionRunner } -Code 'runtime_proof_invalid'
$LateReferences = [pscustomobject]@{ reads = 0 }
$LateReferenceTransport = {
	param($Request)
	if ($Request.path -ceq 'repos/owner/repository') {
		$LateReferences.reads++
		if ($LateReferences.reads -eq 2) { $RevisionFixture.defaultSha = 'e' * 40 }
	}
	return (& $AdmissionTransport $Request)
}
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $LateReferenceTransport } -Code 'runtime_references_changed'
Assert-Condition -Condition ($LateReferences.reads -eq 2 -and $RuntimeCycle.phase -ceq 'references_after') -Message 'Late reference changes were not checked after both queue sweeps'
$RevisionFixture.defaultSha = 'a' * 40
$PrivateFailureTransport = { param($Request) $null = $Request; throw 'synthetic_private_payload_C:/private_fixture' }
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $PrivateFailureTransport } -Code 'github_api_failed'
$SafeDiagnostic = $RuntimeCycle | ConvertTo-Json -Compress
Assert-Condition -Condition ($SafeDiagnostic -cnotmatch 'synthetic_private|C:/|response|arguments' -and $RuntimeCycle.failureCode -ceq 'github_api_failed' -and $RuntimeCycle.requestCount -eq 1) -Message 'Cycle diagnostics exposed raw transport failure detail'
foreach ($ProofField in @('repository', 'runnerName', 'referenceKey')) {
	$BadRuntimeProof = $RuntimeProof | ConvertTo-Json -Depth 12 | ConvertFrom-Json
	$BadRuntimeProof.$ProofField = @($BadRuntimeProof.$ProofField)
	Assert-Failure -Action { Assert-InitialPreparationRuntimeProof -Proof $BadRuntimeProof -Runner $AdmissionRunner } -Code 'runtime_proof_invalid'
}
$ConditionalProbe = [pscustomobject]@{ repositoryReads = 0; validators = 0 }
$ConditionalProbeTransport = {
	param($Request)
	$Reply = & $AdmissionTransport $Request
	if ($Request.path -ceq 'repos/owner/repository') {
		$ConditionalProbe.repositoryReads++
		if ($Request.PSObject.Properties.Name -ccontains 'ifNoneMatch') {
			$ConditionalProbe.validators++
			return [pscustomobject]@{ statusCode = 304; nativeExitCode = 1; headers = @{ ETag = $Request.ifNoneMatch }; bodyJson = ''; data = $null }
		}
		$Reply.headers['ETag'] = 'W/"fixture-repository"'
		$Reply | Add-Member -NotePropertyName bodyJson -NotePropertyValue (ConvertTo-Json -InputObject $Reply.data -Depth 12 -Compress)
	}
	return $Reply
}
$RuntimeTiming.milliseconds = 0
$null = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $ConditionalProbeTransport
Assert-Condition -Condition ($ConditionalProbe.repositoryReads -eq 2 -and $ConditionalProbe.validators -eq 1) -Message 'Repeated singleton GET did not send the exact prior ETag for live revalidation'
Assert-Condition -Condition ($RuntimeCycle.notModifiedCount -eq 1 -and $RuntimeCycle.okCount -eq 25 -and $RuntimeCycle.requestCount -eq 26 -and $RuntimeCycle.phase -ceq 'complete') -Message 'Live304 did not flow through complete runtime before/after checks and bounded counters'
# Match the observed native GitHub path: weak200 ETag, strong304 ETag with
# identical opaque value, native exit1 and an empty body. Exercise native
# parsing AND the conditional wrapper inside the entire runtime inventory.
$WeakNativeFixture = [pscustomobject]@{ firstTag = 'W/"native-runtime"'; returnedTag = '"native-runtime"'; calls = 0; validators = 0 }
$WeakNativeTransport = {
	param($Request)
	if ($Request.path -cne 'repos/owner/repository') { return (& $AdmissionTransport $Request) }
	$WeakNativeFixture.calls++
	if ($Request.PSObject.Properties.Name -ccontains 'ifNoneMatch') {
		$WeakNativeFixture.validators++
		Assert-Condition -Condition ($Request.ifNoneMatch -ceq $WeakNativeFixture.firstTag) -Message 'The exact original wire validator changed'
		return ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 1; Output = ("HTTP/2.0 304 Not Modified`r`nETag: " + $WeakNativeFixture.returnedTag + "`r`n`r`n") }) -ExpectedEntityTag $Request.ifNoneMatch
	}
	$Reply = & $AdmissionTransport $Request
	$Json = ConvertTo-Json -InputObject $Reply.data -Depth 12 -Compress
	return ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 0; Output = ("HTTP/2.0 200 OK`r`nETag: " + $WeakNativeFixture.firstTag + "`r`n`r`n" + $Json) })
}
$WeakRuntimeCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$null = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $WeakNativeTransport -ConditionalCache $WeakRuntimeCache
Assert-Condition -Condition ($WeakNativeFixture.calls -eq 2 -and $WeakNativeFixture.validators -eq 1 -and $RuntimeCycle.notModifiedCount -eq 1 -and $RuntimeCycle.phase -ceq 'complete') -Message 'Native weak-to-strong304 failed through full runtime'
foreach ($NativeTagPair in @(
	@{ first = '"native-runtime"'; returned = 'W/"native-runtime"' },
	@{ first = '"native-runtime"'; returned = '"native-runtime"' },
	@{ first = 'W/"native-runtime"'; returned = 'W/"native-runtime"' })) {
	$WeakNativeFixture.firstTag = $NativeTagPair.first; $WeakNativeFixture.returnedTag = $NativeTagPair.returned
	$WeakNativeFixture.calls = 0; $WeakNativeFixture.validators = 0
	$WeakRuntimeCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
	$null = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $WeakNativeTransport -ConditionalCache $WeakRuntimeCache
	Assert-Condition -Condition ($RuntimeCycle.notModifiedCount -eq 1 -and $RuntimeCycle.phase -ceq 'complete' -and @($WeakRuntimeCache.entries.Values)[0].etag -ceq $NativeTagPair.first) -Message 'Native304 weak comparison changed cached/wire validator identity'
}
foreach ($InvalidReturnedTag in @('"different"', '"Native-runtime"', 'w/"native-runtime"', 'W/native-runtime', '"native-runtime", "other"', '*', "W/`"native-runtime`"`r`nETag: `"native-runtime`"")) {
	$WeakNativeFixture.firstTag = 'W/"native-runtime"'; $WeakNativeFixture.returnedTag = $InvalidReturnedTag
	$WeakRuntimeCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
	Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $WeakNativeTransport -ConditionalCache $WeakRuntimeCache } -Code 'github_api_failed'
	Assert-Condition -Condition ($RuntimeCycle.notModifiedCount -eq 0 -and $RuntimeCycle.retryCount -eq 0 -and $RuntimeCycle.lastFailure.httpStatus -eq 304 -and $RuntimeCycle.lastFailure.nativeExitCode -eq 1) -Message 'Invalid native304 escaped typed rejection or gained a retry'
}
foreach ($InvalidInputTag in @($null, @('"one"'), '*', '"one", "two"', 'w/"one"')) {
	Assert-Condition -Condition (-not (Test-PreparationWeakEntityTag -Left $InvalidInputTag -Right '"one"') -and -not (Test-PreparationWeakEntityTag -Left '"one"' -Right $InvalidInputTag)) -Message 'Weak comparison admitted malformed/list/wildcard operand'
}
Write-Output 'PASS: native weak/strong304 equivalence through full runtime; exact sent/cache identity retained; opaque/case/malformed/list/wildcard mismatches rejected'
# Exercise live revalidation independently of pagination, and retain no shared
# parsed objects. These synthetic responses use the native envelope contract.
$ConditionalCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$ConditionalState = [pscustomobject]@{ okCount = 0; notModifiedCount = 0 }
$ConditionalRequest = [pscustomobject]@{ method = 'GET'; path = 'repos/owner/repository'; body = $null; timeoutMilliseconds = 30000 }
$ConditionalFixture = [pscustomobject]@{ calls = 0; mode = 'normal'; json = '{"value":"one"}'; etag = 'W/"fixture-one"' }
$ConditionalTransport = {
	param($Request)
	$ConditionalFixture.calls++
	$HasValidator = $Request.PSObject.Properties.Name -ccontains 'ifNoneMatch'
	if ($ConditionalFixture.mode -ceq 'error') { throw 'synthetic_private_payload C:/private_fixture' }
	if ($HasValidator -and $ConditionalFixture.mode -cne 'changed' -and $ConditionalFixture.mode -cne 'missing') {
		if ($ConditionalFixture.mode -ceq 'coherent-mutation') {
			$Entry = @($ConditionalCache.entries.Values)[0]
			$Entry.json = '{"value":"tampered"}'
			$Digest = Get-PreparationBodyDigest -Json $Entry.json
			$Entry.sha256 = $Digest.sha256; $Entry.bytes = $Digest.bytes
		}
		return [pscustomobject]@{ statusCode = $(if ($ConditionalFixture.mode -ceq 'status-string') { '304' } else { 304 }); nativeExitCode = $(if ($ConditionalFixture.mode -ceq 'native-zero') { 0 } elseif ($ConditionalFixture.mode -ceq 'native-other') { 2 } elseif ($ConditionalFixture.mode -ceq 'native-string') { '1' } else { 1 });
			headers = @{ ETag = $(if ($ConditionalFixture.mode -ceq 'wrong-tag') { '"different"' } else { $Request.ifNoneMatch }) };
			data = $null; bodyJson = $(if ($ConditionalFixture.mode -ceq 'body') { ' ' } else { '' }) }
	}
	$Headers = @{}
	if ($ConditionalFixture.mode -cne 'missing') { $Headers.ETag = $ConditionalFixture.etag }
	return [pscustomobject]@{ statusCode = 200; nativeExitCode = 0; headers = $Headers; bodyJson = $ConditionalFixture.json; data = ($ConditionalFixture.json | ConvertFrom-Json) }
}
$FirstConditional = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
$FirstConditional.data.value = 'caller-mutation'
$SecondConditional = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
Assert-Condition -Condition ($SecondConditional.data.value -ceq 'one' -and $ConditionalFixture.calls -eq 2 -and $ConditionalState.notModifiedCount -eq 1) -Message '304 must perform a live call and return a fresh immutable-body copy'
foreach ($Mode in @('native-zero', 'native-other', 'status-string', 'native-string', 'wrong-tag', 'body', 'error', 'coherent-mutation')) {
	$ConditionalFixture.mode = $Mode
	Assert-Failure -Action { Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState } -Code 'github_api_failed'
}
$ConditionalCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$ConditionalFixture.mode = 'normal'
$null = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
$ConditionalFixture.mode = 'changed'; $ConditionalFixture.etag = '"fixture-two"'; $ConditionalFixture.json = '{"value":"two"}'
$ChangedConditional = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
$ConditionalFixture.mode = 'normal'
$FreshChanged = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
Assert-Condition -Condition ($ChangedConditional.data.value -ceq 'two' -and $FreshChanged.data.value -ceq 'two' -and $ConditionalCache.entries.Count -eq 1) -Message 'Changed200 did not replace the exact cached representation'
$ConditionalFixture.mode = 'missing'
$null = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
Assert-Condition -Condition ($ConditionalCache.entries.Count -eq 0 -and $ConditionalCache.bytes -eq 0) -Message 'MissingETag must invalidate the old entry'
$Unsolicited = { param($Request) $null = $Request; return [pscustomobject]@{ statusCode = 304; nativeExitCode = 1; headers = @{ ETag = '"fixture-two"' }; bodyJson = ''; data = $null } }
Assert-Failure -Action { Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $Unsolicited -State $ConditionalState } -Code 'github_api_failed'
foreach ($ExcludedPath in @('repos/owner/repository/pulls?state=open&per_page=100&page=1', 'repos/owner/repository/actions/runners?per_page=100&page=1', 'repos/owner/repository/actions/runs?status=queued', 'repos/owner/repository/pulls', 'repos/owner/repository?x=1')) {
	$Excluded = [pscustomobject]@{ method = 'GET'; path = $ExcludedPath; body = $null; timeoutMilliseconds = 30000 }
	Assert-Condition -Condition (-not (Test-PreparationConditionalPath -Request $Excluded)) -Message 'Pagination/query collection entered conditional allowlist'
	Assert-Failure -Action { Invoke-PreparationConditionalRequest -Request $Excluded -Cache $ConditionalCache -Transport $Unsolicited -State $ConditionalState } -Code 'github_api_failed'
}
foreach ($Method in @('POST', 'DELETE')) {
	Assert-Condition -Condition (-not (Test-PreparationConditionalPath -Request ([pscustomobject]@{ method = $Method; path = 'repos/owner/repository' }))) -Message 'Mutation entered conditional allowlist'
}
foreach ($Tag in @('unquoted', '"one","two"', "`"bad`r`nheader`"", ('"' + ('x' * 257) + '"'))) {
	Assert-Condition -Condition (-not (Test-PreparationEntityTag -Value $Tag)) -Message 'Ambiguous/oversized entity tag accepted'
}
foreach ($NativeCase in @(
	@{ exit = 0; tag = 'W/"one"'; body = ''; expected = 'W/"one"' },
	@{ exit = 2; tag = 'W/"one"'; body = ''; expected = 'W/"one"' },
	@{ exit = 1; tag = 'W/"other"'; body = ''; expected = 'W/"one"' },
	@{ exit = 1; tag = 'W/"one"'; body = ' '; expected = 'W/"one"' },
	@{ exit = 1; tag = 'W/"one"'; body = ''; expected = $null },
	@{ exit = 1; tag = "W/`"one`"`r`nETag: W/`"one`""; body = ''; expected = 'W/"one"' })) {
	Assert-Failure -Action { ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = $NativeCase.exit; Output = ("HTTP/2.0 304 Not Modified`r`nETag: " + $NativeCase.tag + "`r`n`r`n" + $NativeCase.body) }) -ExpectedEntityTag $NativeCase.expected } -Code 'github_api_failed'
}
$Native304 = ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 304 Not Modified`r`nETag: W/`"one`"`r`n`r`n" }) -ExpectedEntityTag 'W/"one"'
Assert-Condition -Condition ($Native304.statusCode -eq 304 -and $Native304.nativeExitCode -eq 1 -and $Native304.bodyJson -ceq '') -Message 'Exact gh304/native1 contract rejected'
Assert-Failure -Action { ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 200 OK`r`nETag: W/`"one`"`r`n`r`n{}" }) -ExpectedEntityTag 'W/"one"' } -Code 'github_api_failed'
$WrongCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$WrongCache.identity += 'wrong-attempt'
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $ConditionalProbeTransport -ConditionalCache $WrongCache } -Code 'runtime_proof_invalid'
# Conditional responses do not bypass reference drift, even when warm entries
# exist. Every before/after inventory still calls the transport.
$WarmCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$null = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $ConditionalProbeTransport -ConditionalCache $WarmCache
$LateReferences.reads = 0
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -Transport $LateReferenceTransport -ConditionalCache $WarmCache } -Code 'runtime_references_changed'
$RevisionFixture.defaultSha = 'a' * 40
foreach ($Corruption in @('json', 'bytes', 'sha256', 'etag', 'key')) {
	$ConditionalCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
	$ConditionalFixture.mode = 'normal'
	$null = Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState
	$DamagedEntry = @($ConditionalCache.entries.Values)[0]
	if ($Corruption -ceq 'bytes') { $DamagedEntry.bytes++ } else { $DamagedEntry.$Corruption += 'damaged' }
	$CallsBeforeCorruption = $ConditionalFixture.calls
	Assert-Failure -Action { Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache $ConditionalCache -Transport $ConditionalTransport -State $ConditionalState } -Code 'github_api_failed'
	Assert-Condition -Condition ($ConditionalFixture.calls -eq $CallsBeforeCorruption) -Message 'Corrupt cached representation sent a validator'
}
$CapacityCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$ConditionalFixture.mode = 'normal'
foreach ($Index in 1..129) {
	$CapacityRequest = [pscustomobject]@{ method = 'GET'; path = ('repos/owner/repository/pulls/' + $Index); body = $null; timeoutMilliseconds = 30000 }
	$null = Invoke-PreparationConditionalRequest -Request $CapacityRequest -Cache $CapacityCache -Transport $ConditionalTransport -State $ConditionalState
}
Assert-Condition -Condition ($CapacityCache.entries.Count -eq 128) -Message 'Conditional cache exceeded128entry bound'
$CapacityCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$CapacityCache.bytes = 16777216L
$null = Invoke-PreparationConditionalRequest -Request $CapacityRequest -Cache $CapacityCache -Transport $ConditionalTransport -State $ConditionalState
Assert-Condition -Condition ($CapacityCache.entries.Count -eq 0 -and $CapacityCache.bytes -eq 16777216L) -Message 'Byte-full cache must keep observing live without allocating another entry'
$BadBody = { param($Request) $null = $Request; return [pscustomobject]@{ statusCode = 200; nativeExitCode = 0; headers = @{ ETag = '"valid"' }; bodyJson = 'synthetic_private_payload C:/private_fixture'; data = [pscustomobject]@{} } }
Assert-Failure -Action { Invoke-PreparationConditionalRequest -Request $ConditionalRequest -Cache (New-PreparationConditionalCache -Attempt $RuntimeAttempt) -Transport $BadBody -State $ConditionalState } -Code 'github_api_failed'
Write-Output 'PASS: conditional singleton live revalidation, native304 binding, mutation rejection, invalidation, exclusions and drift'
# Virtual5.5h baseline uses the retained live path distribution:20 singleton
# observations and14 paginated observations per cycle. Actual wrapper/cache and
# cadence helpers run throughout; this is not a claim about shared live quotas.
$QuotaCache = New-PreparationConditionalCache -Attempt $RuntimeAttempt
$QuotaState = [pscustomobject]@{ okCount = 0; notModifiedCount = 0 }
$QuotaModel = [pscustomobject]@{ calls = 0; pages = 0; validators = 0 }
$QuotaTransport = {
	param($Request)
	$QuotaModel.calls++
	if ($Request.PSObject.Properties.Name -ccontains 'ifNoneMatch') {
		$QuotaModel.validators++
		return [pscustomobject]@{ statusCode = 304; nativeExitCode = 1; headers = @{ ETag = $Request.ifNoneMatch }; data = $null; bodyJson = '' }
	}
	$Headers = @{}
	if (Test-PreparationConditionalPath -Request $Request) { $Headers.ETag = 'W/"stable"' } else { $QuotaModel.pages++ }
	return [pscustomobject]@{ statusCode = 200; nativeExitCode = 0; headers = $Headers; data = [pscustomobject]@{ value = 'stable' }; bodyJson = '{"value":"stable"}' }
}
$QuotaNow = $RuntimeAttempt.monotonicStartTicks; $QuotaCycles = 0
$QuotaPaths = @('repos/owner/repository', 'repos/owner/repository/git/ref/heads/develop', 'repos/owner/repository/git/ref/heads/main', 'repos/owner/repository/git/ref/pull/1/merge', 'repos/owner/repository/git/ref/pull/2/merge', 'repos/owner/repository/pulls/1', 'repos/owner/repository/pulls/2', ('repos/owner/repository/git/commits/' + ('a' * 40)), ('repos/owner/repository/git/commits/' + ('b' * 40)), 'repos/owner/repository/git/ref/heads/develop')
$QuotaPages = @('actions/runners?per_page=100&page=1', 'pulls?state=open&per_page=100&page=1', 'actions/runs?status=queued', 'actions/runs?status=in_progress', 'actions/runs?status=waiting', 'actions/runs?status=pending', 'actions/runs?status=requested')
while ($QuotaNow -lt $RuntimeAttempt.stopUsefulWorkTicks) {
	$QuotaStart = $QuotaNow
	foreach ($Pass in 1..2) {
		$null = $Pass
		foreach ($Path in $QuotaPaths) { $null = Invoke-PreparationConditionalRequest -Request ([pscustomobject]@{ method = 'GET'; path = $Path; body = $null; timeoutMilliseconds = 30000 }) -Cache $QuotaCache -Transport $QuotaTransport -State $QuotaState }
		foreach ($Page in $QuotaPages) { $null = Invoke-PreparationConditionalRequest -Request ([pscustomobject]@{ method = 'GET'; path = ('repos/owner/repository/' + $Page); body = $null; timeoutMilliseconds = 30000 }) -Cache $QuotaCache -Transport $QuotaTransport -State $QuotaState }
	}
	$QuotaNow += 17 * $RuntimeAttempt.monotonicFrequency
	$Pause = Get-PreparationMonitorDelayMilliseconds -Attempt $RuntimeAttempt -StartedTicks $QuotaStart -NowTicks $QuotaNow
	Assert-Condition -Condition ($Pause -eq 13000) -Message 'Stable quota cadence changed'
	$QuotaNow += [long] ($Pause * $RuntimeAttempt.monotonicFrequency / 1000)
	$QuotaCycles++
}
Assert-Condition -Condition ($QuotaCycles -eq 660 -and $QuotaModel.calls -eq 22440 -and $QuotaModel.pages -eq 9240 -and $QuotaState.okCount -eq 9249 -and $QuotaState.notModifiedCount -eq 13191 -and $QuotaCache.entries.Count -eq 9) -Message 'Full330-minute quota model no longer bounds34 live calls/30s with only singleton304 relief'
Write-Output 'PASS: virtual330minutes/660cycles:22440 liveGETs,9249 HTTP200 including9 cold singleton entries,13191 HTTP304;14 uncached pages/cycle'
$TransientFixture = [pscustomobject]@{ calls = 0 }
$TransientTransport = {
	param($Request)
	$TransientFixture.calls++
	if ($TransientFixture.calls -eq 1) { return [pscustomobject]@{ statusCode = 503; headers = @{}; data = [pscustomobject]@{} } }
	return (& $AdmissionTransport $Request)
}
$VirtualRetryDelay = { param($Milliseconds) $RuntimeTiming.milliseconds += $Milliseconds }
$AfterTransient = Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -DelayMilliseconds $VirtualRetryDelay -Transport $TransientTransport
Assert-Condition -Condition ($AfterTransient.complete -and $TransientFixture.calls -eq 27) -Message 'A classified503 GET must allow one bounded retry without restarting inventory'
Assert-Condition -Condition ($RuntimeCycle.retryCount -eq 1 -and $RuntimeCycle.lastFailure.httpStatus -eq 503 -and $RuntimeCycle.lastFailure.retryDelayMilliseconds -eq 1000) -Message 'Recovered transient cause must remain in bounded cycle evidence'

# Native HTTP failures are parsed before their nonzero exit is rejected. Error
# bodies are deliberately arbitrary private-looking text, never JSON inputs.
$SafeNativeFailure = $null
try { $null = ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 503 Service Unavailable`r`nRetry-After: 2`r`n`r`nsynthetic_private_payload C:/private_fixture" }) }
catch { $SafeNativeFailure = Get-PreparationGitHubFailure -Exception $_.Exception }
Assert-Condition -Condition ($SafeNativeFailure.Category -ceq 'http_transient' -and $SafeNativeFailure.HttpStatus -eq 503 -and $SafeNativeFailure.NativeExitCode -eq 1 -and $SafeNativeFailure.RetryAfterSeconds -eq 2) -Message 'HTTP/native cause was discarded before classification'
$PreservedFailure = $null
try { $null = Invoke-PreparationGitHubRequest -Method GET -Path 'repos/owner/repository' -Body $null -Transport { param($Request) $null = $Request; throw $SafeNativeFailure } }
catch { $PreservedFailure = Get-PreparationGitHubFailure -Exception $_.Exception }
Assert-Condition -Condition ($PreservedFailure.HttpStatus -eq 503 -and $PreservedFailure.NativeExitCode -eq 1) -Message 'Outer request wrapper discarded typed failure'
$NativeSuccess = ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 0; Output = "HTTP/2.0 200 OK`n`n{}" })
Assert-Condition -Condition ($NativeSuccess.statusCode -eq 200) -Message 'Valid zero-exit native response rejected'

$RetryCases = @(
	@{ name = '503'; status = 503; calls = 2; wait = 1000; success = $true },
	@{ name = '500'; status = 500; calls = 2; wait = 1000; success = $true },
	@{ name = '502'; status = 502; calls = 2; wait = 1000; success = $true },
	@{ name = '504'; status = 504; calls = 2; wait = 1000; success = $true },
	@{ name = 'second-fault'; status = 503; repeat = $true; calls = 2; wait = 1000; success = $false },
	@{ name = 'small-budget'; status = 503; budget = 2500; calls = 1; wait = 0; success = $false },
	@{ name = 'retry-original-call-deadline'; status = 503; firstTime = 26000; secondTime = 4000; calls = 2; wait = 1000; success = $false },
	@{ name = 'retry-remaining-call-timeout'; status = 503; firstTime = 26000; secondTime = 1000; calls = 2; wait = 1000; success = $true },
	@{ name = 'long-retry-after'; status = 503; headers = @{ 'Retry-After' = '40' }; calls = 1; wait = 0; success = $false },
	@{ name = '401'; status = 401; calls = 1; wait = 0; success = $false },
	@{ name = 'plain403'; status = 403; calls = 1; wait = 0; success = $false },
	@{ name = '404'; status = 404; calls = 1; wait = 0; success = $false },
	@{ name = '408-not-enabled'; status = 408; calls = 1; wait = 0; success = $false },
	@{ name = 'POST'; method = 'POST'; status = 503; calls = 1; wait = 0; success = $false },
	@{ name = 'DELETE'; method = 'DELETE'; status = 503; calls = 1; wait = 0; success = $false },
	@{ name = 'secondary-no-wait'; status = 429; calls = 1; wait = 0; success = $false },
	@{ name = 'secondary-supplied-wait'; status = 429; headers = @{ 'Retry-After' = '3' }; calls = 2; wait = 3000; success = $true },
	@{ name = 'secondary403-supplied-wait'; status = 403; headers = @{ 'Retry-After' = '3' }; calls = 2; wait = 3000; success = $true },
	@{ name = 'primary-both-waits'; status = 429; headers = @{ 'Retry-After' = '5'; 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1000020' }; calls = 2; wait = 20000; success = $true },
	@{ name = 'primary-long-reset'; status = 403; headers = @{ 'Retry-After' = '5'; 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1000035' }; calls = 1; wait = 0; success = $false },
	@{ name = 'primary-long-retry-after'; status = 429; headers = @{ 'Retry-After' = '35'; 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1000005' }; calls = 1; wait = 0; success = $false },
	@{ name = 'primary-reset-missing'; status = 429; headers = @{ 'Retry-After' = '2'; 'X-RateLimit-Remaining' = '0' }; calls = 1; wait = 0; success = $false },
	@{ name = 'fractional-wait'; status = 429; headers = @{ 'Retry-After' = '1.5' }; calls = 1; wait = 0; success = $false; category = 'delay_invalid' },
	@{ name = 'overflow-wait'; status = 429; headers = @{ 'Retry-After' = '2147483648' }; calls = 1; wait = 0; success = $false; category = 'delay_invalid' },
	@{ name = 'ambiguous-wait'; status = 429; headers = @{ 'Retry-After' = @('1', '2') }; calls = 1; wait = 0; success = $false; category = 'delay_invalid' },
	@{ name = 'negative-reset'; status = 429; headers = @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '-1' }; calls = 1; wait = 0; success = $false; category = 'delay_invalid' },
	@{ name = 'unknown-cli'; native = [pscustomobject]@{ ExitCode = 1; Output = 'synthetic_private_payload C:/private_fixture' }; calls = 1; wait = 0; success = $false; category = 'native_failure' },
	@{ name = '2xx-native-failure'; native = [pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 200 OK`n`n{}" }; calls = 1; wait = 0; success = $false; category = 'native_failure' },
	@{ name = 'malformed-response'; native = [pscustomobject]@{ ExitCode = 0; Output = 'synthetic_private_payload' }; calls = 1; wait = 0; success = $false; category = 'response_invalid' },
	@{ name = 'duplicate-delay'; native = [pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 503 Unavailable`nRetry-After: 1`nretry-after: 2`n`nsynthetic_private_payload" }; calls = 1; wait = 0; success = $false; category = 'delay_invalid' },
	@{ name = 'oversized-response'; native = [pscustomobject]@{ ExitCode = 1; Output = ('x' * 1048577) }; calls = 1; wait = 0; success = $false; category = 'response_limit' },
	@{ name = 'timeout-unproven-cleanup'; exception = [TimeoutException]::new('synthetic_private_payload'); calls = 1; wait = 0; success = $false; category = 'native_timeout' },
	@{ name = 'cleanup-unproven'; exception = [InvalidOperationException]::new('github_cli_cleanup_failed'); calls = 1; wait = 0; success = $false; category = 'native_cleanup_unproven' }
)
foreach ($Case in $RetryCases) {
	$CaseClock = [pscustomobject]@{ elapsed = 0L; calls = 0; wait = 0; timeouts = New-Object Collections.ArrayList }
	$CaseState = [pscustomobject]@{ requestCount = 0; retryCount = 0; lastFailure = $null }
	$CaseStart = $RuntimeAttempt.monotonicStartTicks
	$CaseBudgetMs = if ($Case.ContainsKey('budget')) { $Case.budget } else { 55000 }
	$CaseBudget = [pscustomobject]@{ deadline = $CaseStart + [long] ($CaseBudgetMs * $RuntimeAttempt.monotonicFrequency / 1000); frequency = $RuntimeAttempt.monotonicFrequency; state = $CaseState }
	$CaseReadClock = { $CaseStart + [long] ($CaseClock.elapsed * $RuntimeAttempt.monotonicFrequency / 1000) }
	$CaseDelay = { param($Milliseconds) $CaseClock.elapsed += $Milliseconds; $CaseClock.wait += $Milliseconds }
	$CaseTransport = {
		param($Request)
		$CaseClock.calls++
		[void] $CaseClock.timeouts.Add($Request.timeoutMilliseconds)
		if ($CaseClock.calls -eq 1 -and $Case.ContainsKey('firstTime')) { $CaseClock.elapsed += $Case.firstTime }
		if ($CaseClock.calls -eq 2 -and $Case.ContainsKey('secondTime')) { $CaseClock.elapsed += $Case.secondTime }
		if ($CaseClock.calls -eq 1 -or ($Case.ContainsKey('repeat') -and $Case.repeat)) {
			if ($Case.ContainsKey('native')) { return ConvertFrom-PreparationGitHubNativeResult -Result $Case.native }
			if ($Case.ContainsKey('exception')) { throw (Get-PreparationGitHubNativeFailure -Exception $Case.exception) }
			$CaseHeaders = if ($Case.ContainsKey('headers')) { $Case.headers } else { @{} }
			return [pscustomobject]@{ statusCode = $Case.status; headers = $CaseHeaders; data = [pscustomobject]@{} }
		}
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{} }
	}
	$CaseMethod = if ($Case.ContainsKey('method')) { $Case.method } else { 'GET' }
	$CasePassed = $false
	try {
		$Reply = Invoke-PreparationRuntimeRequest -Request ([pscustomobject]@{ method = $CaseMethod; path = 'repos/owner/repository'; body = $null }) -Budget $CaseBudget -Transport $CaseTransport -ReadTicks $CaseReadClock -ReadUtcSeconds { 1000000L } -DelayMilliseconds $CaseDelay
		$CasePassed = $Reply.statusCode -eq 200
	} catch { $null = $_ }
	Assert-Condition -Condition ($CasePassed -eq $Case.success -and $CaseClock.calls -eq $Case.calls -and $CaseClock.wait -eq $Case.wait) -Message ('Retry case failed: ' + $Case.name + '; passed=' + $CasePassed + '; calls=' + $CaseClock.calls + '; wait=' + $CaseClock.wait)
	if ($Case.ContainsKey('category')) { Assert-Condition -Condition ($CaseState.lastFailure.category -ceq $Case.category) -Message ('Typed cause lost: ' + $Case.name) }
	if ($Case.name -ceq 'retry-remaining-call-timeout') { Assert-Condition -Condition ($CaseClock.timeouts[1] -eq 3000) -Message 'Retry reset the original30-second call deadline' }
	if ($Case.name -ceq 'timeout-unproven-cleanup') { Assert-Condition -Condition ($CaseState.lastFailure.timedOut -and -not $CaseState.lastFailure.cleanupVerified -and $CaseState.retryCount -eq 0) -Message 'Root timeout was falsely promoted to descendant cleanup proof' }
	$CaseJson = $CaseState | ConvertTo-Json -Depth 3 -Compress
	Assert-Condition -Condition ($CaseJson.Length -lt 1500 -and $CaseJson -cnotmatch 'synthetic_private|C:/|Output|Exception|stderr|headers') -Message ('Unsafe diagnostic disclosure: ' + $Case.name)
}

# One recovered transient spends the entire cycle retry allowance. A later
# transient is not a second retry opportunity, even on a different GET.
$AllowanceState = [pscustomobject]@{ requestCount = 0; retryCount = 0; lastFailure = $null }
$AllowanceClock = [pscustomobject]@{ elapsed = 0L; calls = 0 }
$AllowanceBudget = [pscustomobject]@{ deadline = $RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency; frequency = $RuntimeAttempt.monotonicFrequency; state = $AllowanceState }
$AllowanceRead = { $RuntimeAttempt.monotonicStartTicks + [long] ($AllowanceClock.elapsed * $RuntimeAttempt.monotonicFrequency / 1000) }
$AllowanceTransport = { param($Request) $null = $Request; $AllowanceClock.calls++; return [pscustomobject]@{ statusCode = $(if ($AllowanceClock.calls -eq 2) { 200 } else { 503 }); headers = @{}; data = [pscustomobject]@{} } }
$AllowanceDelay = { param($Milliseconds) $AllowanceClock.elapsed += $Milliseconds }
$null = Invoke-PreparationRuntimeRequest -Request ([pscustomobject]@{ method = 'GET'; path = 'repos/owner/repository'; body = $null }) -Budget $AllowanceBudget -Transport $AllowanceTransport -ReadTicks $AllowanceRead -ReadUtcSeconds { 1000000L } -DelayMilliseconds $AllowanceDelay
Assert-Failure -Action { Invoke-PreparationRuntimeRequest -Request ([pscustomobject]@{ method = 'GET'; path = 'repos/owner/repository/pulls'; body = $null }) -Budget $AllowanceBudget -Transport $AllowanceTransport -ReadTicks $AllowanceRead -ReadUtcSeconds { 1000000L } -DelayMilliseconds $AllowanceDelay } -Code 'github_api_failed'
Assert-Condition -Condition ($AllowanceClock.calls -eq 3 -and $AllowanceState.retryCount -eq 1 -and $AllowanceState.lastFailure.retryDecision -ceq 'retry_limit') -Message 'More than one extra GET was allowed in a cycle'
$TransientFixture.calls = 0; $LateReferences.reads = 0; $RuntimeTiming.milliseconds = 0
$DriftAfterRetryTransport = { param($Request) $TransientFixture.calls++; if ($TransientFixture.calls -eq 1) { return [pscustomobject]@{ statusCode = 503; headers = @{}; data = [pscustomobject]@{} } }; return (& $LateReferenceTransport $Request) }
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -DelayMilliseconds $VirtualRetryDelay -Transport $DriftAfterRetryTransport } -Code 'runtime_references_changed'
Assert-Condition -Condition ($RuntimeCycle.retryCount -eq 1 -and $RuntimeCycle.phase -ceq 'references_after') -Message 'Retry skipped final reference revalidation'
$RevisionFixture.defaultSha = 'a' * 40
$RuntimeTiming.milliseconds = 0
$NativeRejectedTransport = {
	param($Request)
	$null = $Request
	return ConvertFrom-PreparationGitHubNativeResult -Result ([pscustomobject]@{ ExitCode = 1; Output = "HTTP/2.0 403 Forbidden`n`nsynthetic_private_payload" })
}
Assert-Failure -Action { Get-InitialPreparationRuntimeInventory -Runner $AdmissionRunner -Proof $RuntimeProof -Attempt $RuntimeAttempt -DeadlineTicks ($RuntimeAttempt.monotonicStartTicks + 55 * $RuntimeAttempt.monotonicFrequency) -CycleState $RuntimeCycle -ReadTicks $RuntimeClock -DelayMilliseconds $VirtualRetryDelay -Transport $NativeRejectedTransport } -Code 'github_api_failed'
Assert-Condition -Condition ($RuntimeCycle.requestCount -eq 1 -and $RuntimeCycle.retryCount -eq 0 -and $RuntimeCycle.lastFailure.httpStatus -eq 403 -and $RuntimeCycle.lastFailure.nativeExitCode -eq 1 -and ($RuntimeCycle | ConvertTo-Json -Depth 3 -Compress) -cnotmatch 'synthetic_private') -Message 'Typed HTTP/native failure was lost on the complete runtime path'
Write-Output ('PASS: ' + $RetryCases.Count + ' bounded HTTP/native retry cases; one extra GET per cycle; typed redacted causes; post-retry reference drift rejection')
Write-Output 'PASS: virtual runtime26GET/52s versus repeated-admission33GET/66s; aggregate deadline and frozen source rejection'

$LifecycleRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnMaintenanceFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $LifecycleRoot
$LifecycleFixture = [pscustomobject]@{ failWork = $false; failFreeze = $false; failRemovalResponse = $false; nativeFailure = $false; failCleanup = $false; freezeCalled = $false; postAfterRelease = $false; lease = $null }
$RunnerFixtureTransport = $Transport
$LifecycleTransport = {
	param($Request)
	if ($Request.method -ceq 'POST') {
		$LifecycleFixture.postAfterRelease = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.attemptId -ceq $LifecycleAttempt.attemptId }).Count -eq 0
	}
	$Reply = & $RunnerFixtureTransport $Request
	if ($Request.method -ceq 'DELETE' -and $LifecycleFixture.failRemovalResponse) { throw 'response_lost_after_removal' }
	return $Reply
}
$LifecycleInventory = {
	Assert-Condition -Condition (@($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.attemptId -ceq $LifecycleAttempt.attemptId }).Count -eq 0) -Message 'Admission must not wait while holding the host lease.'
	return [pscustomobject]@{ complete = $true; routesSafe = $true; runnerId = 21; runnerName = 'aetheln-engine-pc'; online = $true; busy = $false; labels = @($Fixture.labels); activeJobs = @(); activityKey = 'quiet' }
}
$LifecycleWork = {
	param($Context)
	Assert-Condition -Condition ($Context.admission.admitted -and $Context.admission.observation.activityKey -ceq 'quiet') -Message 'Work must receive the proven admission observation, not a fabricated monitor seed.'
	$LifecycleFixture.lease = $Context.lease
	Assert-Condition -Condition ($Fixture.labels -cnotcontains 'aetheln-engine') -Message 'Retained work requires routing quarantine.'
	Assert-Condition -Condition (@($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Context.lease.leaseId }).Count -eq 1) -Message 'Work requires the acquired host lease.'
	if ($LifecycleFixture.failWork) { throw 'fixture_work_failure' }
	if ($LifecycleFixture.failCleanup) {
		$Entry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Context.lease.leaseId })[0]
		$FailedJob = [pscustomobject]@{ ActiveCount = 1 }
		$FailedJob | Add-Member -MemberType ScriptMethod -Name StopAndWait -Value { param($Milliseconds) $null = $Milliseconds; throw 'fixture_cleanup_unproven' }
		$Entry | Add-Member -NotePropertyName supervisedJobs -NotePropertyValue @($FailedJob)
	}
	return [pscustomobject]@{ nativeExitCode = $(if ($LifecycleFixture.nativeFailure) { 7 } else { 0 }) }
}
$LifecycleFreeze = {
	param($Context)
	$LifecycleFixture.freezeCalled = $true
	Assert-Condition -Condition (@($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Context.lease.leaseId }).Count -eq 1) -Message 'Evidence freezes before lease release.'
	if ($LifecycleFixture.failFreeze) { throw 'fixture_freeze_failure' }
}
$LifecyclePersist = {
	param($IntentAttempt, $IntentRunner)
	Assert-Condition -Condition ($IntentAttempt.attemptId -ceq $LifecycleAttempt.attemptId -and $IntentRunner.id -eq $Runner.id -and $Fixture.labels -ccontains 'aetheln-engine') -Message 'Intent must precede label mutation and bind the attempt/runner.'
	if ($Failure -ceq 'failIntent') { throw 'fixture_intent_failed' }
	if ($Failure -ceq 'falseIntent') { return $false }
	if ($Failure -ceq 'arrayIntent') { return ,@($true) }
	if ($Failure -ceq 'intentAtDeadline') { $LifecycleClock.ticks = $LifecycleAttempt.admissionDeadlineTicks }
	if ($Failure -ceq 'intentAfterDeadline') { $LifecycleClock.ticks = $LifecycleAttempt.admissionDeadlineTicks + 1 }
	return $true
}
foreach ($Failure in @('none', 'failWork', 'failFreeze', 'failRemovalResponse', 'nativeFailure', 'failCleanup', 'failRestore', 'failIntent', 'falseIntent', 'arrayIntent', 'intentAtDeadline', 'intentAfterDeadline')) {
	$Fixture.labels = @($Runner.originalLabels)
	$LifecycleFixture.failWork = $false; $LifecycleFixture.failFreeze = $false; $LifecycleFixture.failRemovalResponse = $false
	$LifecycleFixture.nativeFailure = $false; $LifecycleFixture.failCleanup = $false; $Fixture.failRestore = $false
	$LifecycleFixture.freezeCalled = $false; $LifecycleFixture.postAfterRelease = $false
	if ($Failure -ceq 'failRestore') { $Fixture.failRestore = $true }
	elseif ($Failure -notin @('none', 'failIntent', 'falseIntent', 'arrayIntent', 'intentAtDeadline', 'intentAfterDeadline')) { $LifecycleFixture.$Failure = $true }
	$LifecycleAttempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ('lifecycle-' + $Failure)
	$LifecycleClock = [pscustomobject]@{ ticks = $LifecycleAttempt.monotonicStartTicks }
	$RequestsBefore = $Fixture.requests.Count
	$LifecycleResult = Invoke-InitialPreparationMaintenance -Attempt $LifecycleAttempt -Runner $Runner -LeasePath (Join-Path $LifecycleRoot ($Failure + '.lease')) -InventoryProbe $LifecycleInventory -LocalWorkerProbe $LocalProbe -Work $LifecycleWork -FreezeEvidence $LifecycleFreeze -PersistQuarantineIntent $LifecyclePersist -Transport $LifecycleTransport -ReadTicks { $LifecycleClock.ticks } -DelayMilliseconds { param($Milliseconds) $LifecycleClock.ticks += [long] ($Milliseconds * $LifecycleAttempt.monotonicFrequency / 1000) }
	if ($Failure -in @('failIntent', 'falseIntent', 'arrayIntent', 'intentAtDeadline', 'intentAfterDeadline')) {
		Assert-Condition -Condition ($Fixture.requests.Count -eq $RequestsBefore -and $Fixture.labels -ccontains 'aetheln-engine' -and -not $LifecycleResult.admitted -and -not $LifecycleResult.routingRestored) -Message 'Intent writer failure must make zero routing API calls.'
	} elseif ($Failure -ceq 'failCleanup') {
		Assert-Condition -Condition (-not $LifecycleResult.routingRestored -and -not $LifecycleResult.leaseReleased -and -not $LifecycleFixture.postAfterRelease -and $Fixture.labels -cnotcontains 'aetheln-engine') -Message 'Unproven cleanup must retain quarantine and lease; never attempt restoration.'
		# Recover only the synthetic failure object; no real process was created.
		$Entry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $LifecycleFixture.lease.leaseId })[0]
		$Entry.PSObject.Properties.Remove('supervisedJobs')
		$null = Stop-InitialPreparationOwnedTree -Lease $LifecycleFixture.lease -DeadlineTicks $LifecycleAttempt.cleanupDeadlineTicks
		Exit-InitialPreparationLease -Lease $LifecycleFixture.lease
	} elseif ($Failure -ceq 'failRestore') {
		Assert-Condition -Condition (-not $LifecycleResult.routingRestored -and $LifecycleResult.leaseReleased -and $LifecycleResult.errors -contains 'routing_restoration_failed') -Message 'Restoration failure must remain explicit after verified cleanup.'
	} else {
		Assert-Condition -Condition ($LifecycleResult.routingRestored -and $LifecycleFixture.postAfterRelease) -Message 'Restoration must follow lease release, including failures and an uncertain removal response.'
	}
	if ($Failure -ceq 'none') { Assert-Condition -Condition ($LifecycleResult.cycleCompleted -and $LifecycleResult.cleanup.cleanupVerified) -Message 'Normal maintenance must finish cleanup and restoration.' }
	else { Assert-Condition -Condition (-not $LifecycleResult.cycleCompleted -and $LifecycleResult.errors.Count -gt 0) -Message 'A failed phase cannot become completed maintenance.' }
}
Write-Output ('Lifecycle fixture journals retained at: ' + $LifecycleRoot)
Write-Output 'PASS: GitHub preparation inventory, routing and source-binding fixtures'
