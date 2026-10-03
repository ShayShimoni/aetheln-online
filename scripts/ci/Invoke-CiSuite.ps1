[CmdletBinding()]
param(
	[string] $ChecksPath,
	[string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ReportPath) {
	$ReportPath = Join-Path $RepositoryRoot 'TestResults\ci-report.json'
}

# Default manifest. Engine-dependent compile and packaged-smoke gates run in
# trusted self-hosted workflow jobs; their wrapper fixture suite runs here.
$DefaultChecks = @(
	@{ name = 'formatting-policy'; tier = 'required'; script = 'scripts/ci/Test-FormattingPolicy.ps1' },
	@{ name = 'markdown-links'; tier = 'required'; script = 'scripts/ci/Test-MarkdownLinks.ps1' },
	@{ name = 'source-control-policy'; tier = 'required'; script = 'scripts/tests/Test-SourceControlPolicy.ps1' },
	@{ name = 'observability-contract'; tier = 'required'; script = 'scripts/tests/Test-ObservabilityContract.ps1' },
	@{ name = 'build-packaged-artifacts-tests'; tier = 'required'; script = 'tests/build/Build-PackagedArtifacts.Tests.ps1' },
	@{ name = 'host-tool-provisioning-tests'; tier = 'required'; script = 'tests/build/Invoke-HostToolProvisioning.Tests.ps1' },
	@{ name = 'packaged-smoke-test-tests'; tier = 'required'; script = 'tests/build/Invoke-PackagedSmokeTest.Tests.ps1' },
	@{ name = 'network-authority-spike-tests'; tier = 'required'; script = 'tests/build/Invoke-NetworkAuthoritySpike.Tests.ps1' },
	# Keep independently isolated expensive fixtures consecutive so the two slots
	# can be reused; every other manifest identity remains a serial barrier.
	@{ name = 'engine-runner-gate-tests'; tier = 'required'; script = 'tests/ci/Invoke-EngineRunnerGate.Tests.ps1' },
	@{ name = 'unreal-automation-tests'; tier = 'required'; script = 'tests/ci/Invoke-UnrealAutomationTests.Tests.ps1' },
	@{ name = 'server-cook-reference-tests'; tier = 'required'; script = 'tests/build/Validate-ServerCookReferences.Tests.ps1' },
	@{ name = 'target-composition-tests'; tier = 'required'; script = 'tests/build/Validate-TargetComposition.Tests.ps1' },
	@{ name = 'build-provenance-tests'; tier = 'required'; script = 'tests/build/Write-BuildProvenance.Tests.ps1' },
	@{ name = 'markdown-link-tests'; tier = 'required'; script = 'tests/ci/Test-MarkdownLinks.Tests.ps1' },
	@{ name = 'formatting-policy-tests'; tier = 'required'; script = 'tests/ci/Test-FormattingPolicy.Tests.ps1' },
	@{ name = 'observability-contract-tests'; tier = 'required'; script = 'tests/ci/Test-ObservabilityContract.Tests.ps1' },
	@{ name = 'ci-suite-tests'; tier = 'required'; script = 'tests/ci/Invoke-CiSuite.Tests.ps1' },
	@{ name = 'engine-runner-post-command-state-tests'; tier = 'required'; script = 'tests/ci/Invoke-EngineRunnerPostCommandState.Tests.ps1' },
	@{ name = 'prototype-quality-workflow-tests'; tier = 'required'; script = 'tests/ci/Test-PrototypeQualityWorkflow.Tests.ps1' },
	@{ name = 'visual-package-evidence-tests'; tier = 'required'; script = 'tests/ci/Invoke-VisualPackageValidation.Tests.ps1' },
	@{ name = 'runner-scheduling-policy-tests'; tier = 'required'; script = 'tests/ci/Test-RunnerSchedulingPolicy.Tests.ps1' },
	@{ name = 'ci-selection-tests'; tier = 'required'; script = 'tests/ci/Get-CiSelection.Tests.ps1' },
	@{ name = 'ci-acceptance-receipt-tests'; tier = 'required'; script = 'tests/ci/New-CiAcceptanceReceipt.Tests.ps1' },
	@{ name = 'ci-acceptance-aggregate-tests'; tier = 'required'; script = 'tests/ci/Invoke-CiAcceptanceAggregate.Tests.ps1' },
	@{ name = 'ci-acceptance-publisher-tests'; tier = 'required'; script = 'tests/ci/Publish-CiAcceptanceReceipt.Tests.ps1' },
	@{ name = 'ci-acceptance-context-tests'; tier = 'required'; script = 'tests/ci/New-CiAcceptanceAggregateContext.Tests.ps1' },
	@{ name = 'ci-activation-candidate-tests'; tier = 'required'; script = 'tests/ci/Test-CiActivationCandidate.Tests.ps1' },
	@{ name = 'compile-workspace-tests'; tier = 'required'; script = 'tests/ci/Initialize-CompileWorkspace.Tests.ps1' },
	@{ name = 'engine-host-lease-tests'; tier = 'required'; script = 'tests/ci/EngineRunnerHostLease.Tests.ps1' },
	@{ name = 'managed-compile-registration-tests'; tier = 'required'; script = 'tests/ci/ManagedCompileRegistration.Tests.ps1' },
	@{ name = 'managed-compile-workspace-tests'; tier = 'required'; script = 'tests/ci/ManagedCompileWorkspace.Tests.ps1' },
	@{ name = 'managed-compile-integration-tests'; tier = 'required'; script = 'tests/ci/ManagedCompileIntegration.Tests.ps1' },
	@{ name = 'routine-compile-deadline-tests'; tier = 'required'; script = 'tests/ci/RoutineCompileDeadline.Tests.ps1' },
	@{ name = 'routine-compile-resources-tests'; tier = 'required'; script = 'tests/ci/RoutineCompileResources.Tests.ps1' },
	@{ name = 'routine-compile-command-tests'; tier = 'required'; script = 'tests/ci/RoutineCompileCommand.Tests.ps1' },
	@{ name = 'routine-compile-gate-tests'; tier = 'required'; script = 'tests/ci/RoutineCompileGate.Tests.ps1' },
	@{ name = 'board-integrity-tests'; tier = 'required'; script = 'tests/delivery/Test-BoardIntegrity.Tests.ps1' },
	@{ name = 'pull-request-policy-tests'; tier = 'required'; script = 'tests/delivery/Test-PullRequestPolicy.Tests.ps1' },
	@{
		name = 'psscriptanalyzer'
		tier = 'advisory'
		requiredModule = 'PSScriptAnalyzer'
		requiredModuleVersion = '1.25.0'
		command = '$ErrorActionPreference = ''Stop''; Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -ErrorAction Stop; $Loaded = @(Get-Module -Name PSScriptAnalyzer); if ($Loaded.Count -ne 1 -or $Loaded[0].Version.ToString() -cne ''1.25.0'') { throw ''psscriptanalyzer_version_invalid'' }; $Findings = @(foreach ($AnalyzerPath in @(''scripts'', ''tests'')) { Invoke-ScriptAnalyzer -Path $AnalyzerPath -Recurse }); $Findings | Format-Table -AutoSize | Out-String -Width 200 | Write-Output; if ($Findings.Count -gt 0) { exit 1 } exit 0'
	}
)

function Get-CheckField {
	param(
		[Parameter(Mandatory)] $Check,
		[Parameter(Mandatory)][string] $Name,
		$Default = $null
	)

	if ($Check -is [hashtable]) {
		if ($Check.ContainsKey($Name)) {
			return $Check[$Name]
		}
		return $Default
	}
	$Property = $Check.PSObject.Properties[$Name]
	if ($null -ne $Property) {
		return $Property.Value
	}
	return $Default
}

function Get-OutputTail {
	param(
		[AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
		[int] $MaximumLines = 40
	)

	$Lines = @($Lines | Where-Object { $null -ne $_ })
	if ($Lines.Count -gt $MaximumLines) {
		$Lines = @('...') + @($Lines | Select-Object -Last $MaximumLines)
	}
	return ($Lines -join "`n")
}

# A private kill-on-close job owns each check tree, including grandchildren.
# The bootstrap waits until assignment before it can execute the actual check.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace AethelnCi {
	public sealed class CheckJob : IDisposable {
		IntPtr handle;
		[StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a,b,c,d,e,f; }
		[StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long processTime,jobTime; public uint flags; public UIntPtr minimum,maximum; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
		[StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits basic; public IoCounters io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
		[StructLayout(LayoutKind.Sequential)] struct Accounting { public long userTime,kernelTime,periodUser,periodKernel; public uint faults,total,active,terminated; }
		[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
		[DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,uint size);
		[DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr returned);
		[DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
		[DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr value);
		public CheckJob() {
			handle=CreateJobObject(IntPtr.Zero,null);
			if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed");
			ExtendedLimits limits=new ExtendedLimits(); limits.basic.flags=0x2000;
			if(!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
				int error=Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error,"SetInformationJobObject failed");
			}
		}
		public void Assign(IntPtr process) {
			if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed");
		}
		public uint ActiveProcesses() {
			Accounting info;
			if(!QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(),"QueryInformationJobObject failed");
			return info.active;
		}
		public void Dispose() { IntPtr current=handle; handle=IntPtr.Zero; if(current!=IntPtr.Zero) CloseHandle(current); GC.SuppressFinalize(this); }
		~CheckJob() { Dispose(); }
	}
}
'@

function Start-HiddenPowerShell {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([hashtable])]
	param(
		[Parameter(Mandatory)][string] $Arguments,
		[Parameter(Mandatory)][string] $WorkingDirectory
	)

	# Decide before allocating: a declined launch must leave no named gate, job
	# object, handle, or child behind, and must not look like a running check.
	if (-not $PSCmdlet.ShouldProcess($WorkingDirectory, "Start a hidden CI check process: powershell.exe $Arguments")) {
		return
	}

	$PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
	$GateName = 'Local\AethelnCiCheck-' + [guid]::NewGuid().ToString('N')
	$Gate = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $GateName)
	$ResultGate = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, ($GateName + '-result'))
	$Job = $null
	$Process = $null
	$Started = $false
	$Bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$Gate = [System.Threading.EventWaitHandle]::OpenExisting('$GateName')
try { if (-not `$Gate.WaitOne(30000)) { throw 'CI process ownership handshake timed out.' } }
finally { `$Gate.Dispose() }
`$Info = [Diagnostics.ProcessStartInfo]::new()
`$Info.FileName = '$($PowerShell.Replace("'", "''"))'
`$Info.Arguments = '$($Arguments.Replace("'", "''"))'
`$Info.UseShellExecute = `$false
`$Info.CreateNoWindow = `$true
`$Info.RedirectStandardOutput = `$true
`$Info.RedirectStandardError = `$true
`$Child = [Diagnostics.Process]::Start(`$Info)
try {
	# Forward incrementally so an infrastructure failure cannot discard output
	# already written by the check. Both OS streams remain separate and raw.
	`$Output = `$Child.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
	`$ErrorOutput = `$Child.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
	`$Child.WaitForExit()
	if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]] @(`$Output, `$ErrorOutput), 5000)) {
		[Console]::Error.WriteLine('CI output pipes remained open after the check exited.')
		exit 1
	}
	`$Result = [Threading.EventWaitHandle]::OpenExisting('$GateName-result')
	try { [void] `$Result.Set() } finally { `$Result.Dispose() }
	exit `$Child.ExitCode
}
finally { `$Child.Dispose() }
"@
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $PowerShell
	$StartInfo.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Bootstrap))
	$StartInfo.WorkingDirectory = $WorkingDirectory
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true

	try {
		$Job = [AethelnCi.CheckJob]::new()
		$Process = [System.Diagnostics.Process]::new()
		$Process.StartInfo = $StartInfo
		if (-not $Process.Start()) {
			throw 'Could not start the CI child PowerShell process.'
		}
		$Started = $true
		$StandardOutput = $Process.StandardOutput.ReadToEndAsync()
		$StandardError = $Process.StandardError.ReadToEndAsync()
		$Job.Assign($Process.Handle)
		[void] $Gate.Set()
		return @{ Process = $Process; StandardOutput = $StandardOutput; StandardError = $StandardError; Job = $Job; Gate = $Gate; ResultGate = $ResultGate }
	}
	catch {
		$PrimaryFailure = $_
		if ($null -ne $Job) { $Job.Dispose() }
		if ($null -ne $Process) {
			try { if ($Started -and -not $Process.HasExited) { $Process.Kill(); [void] $Process.WaitForExit(5000) } }
			catch { Write-Warning "CI launch cleanup failed: $($_.Exception.Message)" }
			$Process.Dispose()
		}
		$Gate.Dispose()
		$ResultGate.Dispose()
		throw $PrimaryFailure
	}
}

function Wait-CiJobQuiescence {
	param([Parameter(Mandatory)] $Job)
	# Root process signaling can precede job accounting becoming empty. Observe
	# termination for at most five seconds using a monotonic clock; do not rerun
	# the check or replace its exit/result. This is separate from the bootstrap's
	# five-second post-exit pipe drain. Persistent descendants still fail closed.
	$GraceMilliseconds = 5000
	$Quiescence = [Diagnostics.Stopwatch]::StartNew()
	do {
		$Remaining = $Job.ActiveProcesses()
		if ($Remaining -eq 0) { return $Remaining }
		$WaitMilliseconds = $GraceMilliseconds - $Quiescence.ElapsedMilliseconds
		if ($WaitMilliseconds -le 0) { return $Remaining }
		Start-Sleep -Milliseconds ([int] [Math]::Min(25, $WaitMilliseconds))
	} while ($true)
}

function Complete-CiCheck {
	param([Parameter(Mandatory)] $Running)
	$Check = $Running.Check
	$Status = 'failed'
	$Message = ''
	try {
		$Running.Child.Process.WaitForExit()
		$ExitCode = $Running.Child.Process.ExitCode
		$Remaining = Wait-CiJobQuiescence -Job $Running.Child.Job
		# Close the owned tree before draining streams: a leaked descendant can
		# otherwise retain pipe handles after the check process has exited.
		$Running.Child.Job.Dispose()
		$Output = @(
			@($Running.Child.StandardOutput.GetAwaiter().GetResult() -split "`r?`n")
			@($Running.Child.StandardError.GetAwaiter().GetResult() -split "`r?`n")
		) | Where-Object { -not [string]::IsNullOrEmpty($_) }
		$Message = Get-OutputTail -Lines @($Output)
		$HasResult = $Running.Child.ResultGate.WaitOne(0)
		if (-not $HasResult) {
			$script:InfrastructureFailed = $true
			$Message += "`nCI bootstrap did not return a complete check result."
		}
		if ($Remaining -gt 0) {
			$script:InfrastructureFailed = $true
			$Message += "`nCI check left $Remaining owned process(es) running after the 5-second quiescence grace; terminated its process tree."
		}
		elseif ($HasResult -and $ExitCode -eq 0) { $Status = 'passed' }
	}
	catch {
		$script:InfrastructureFailed = $true
		$Message += "`nCI result capture failed: $($_.Exception.Message)"
	}
	finally {
		$Running.Child.Job.Dispose()
		$Running.Child.Gate.Dispose()
		$Running.Child.ResultGate.Dispose()
		$Running.Child.Process.Dispose()
		$Running.Stopwatch.Stop()
	}
	$script:Results[$Check.Index] = [ordered]@{
		name = $Check.Name; tier = $Check.Tier; status = $Status
		durationSeconds = [Math]::Round($Running.Stopwatch.Elapsed.TotalSeconds, 3)
		command = $Check.CommandText; message = $Message
	}
	Write-Output "[$($Check.Tier)] $($Check.Name): $Status ($([Math]::Round($Running.Stopwatch.Elapsed.TotalSeconds, 1))s)"
}

function Wait-CiSlot {
	param([switch] $Drain)
	do {
		foreach ($Running in @($script:Active.ToArray())) {
			if ($Running.Child.Process.HasExited) {
				Complete-CiCheck -Running $Running
				[void] $script:Active.Remove($Running)
			}
		}
		if ($script:Active.Count -eq 0 -or (-not $Drain -and $script:Active.Count -lt 2)) { return }
		Start-Sleep -Milliseconds 25
	} while ($true)
}

if ($ChecksPath) {
	$ParsedChecks = Get-Content -LiteralPath $ChecksPath -Raw | ConvertFrom-Json
	$Checks = @($ParsedChecks)
}
else {
	$Checks = $DefaultChecks
}

$PreviousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
	$RevisionOutput = @(& git -C $RepositoryRoot rev-parse HEAD 2>&1 | ForEach-Object { "$_" })
	$RevisionExitCode = $LASTEXITCODE
}
finally {
	$ErrorActionPreference = $PreviousPreference
}
$Revision = if ($RevisionExitCode -eq 0) { $RevisionOutput[0] } else { 'unknown' }

$StartedUtc = [DateTime]::UtcNow.ToString('o')
$Results = [object[]]::new($Checks.Count)
$FailureDetails = @()
$Prepared = @()
$Names = @{}
$InfrastructureFailed = $false
$Active = [System.Collections.Generic.List[object]]::new()
# Keep smoke serial: its package-process quiescence fixture has an unresolved
# concurrent-run failure. It remains required, with all deadlines unchanged.
$ConcurrentChecks = @('build-packaged-artifacts-tests', 'network-authority-spike-tests', 'engine-runner-gate-tests', 'unreal-automation-tests')

# Validate the entire manifest before allowing any child to run.
foreach ($Check in $Checks) {
	$Name = Get-CheckField -Check $Check -Name 'name'
	$Tier = Get-CheckField -Check $Check -Name 'tier'
	$Script = Get-CheckField -Check $Check -Name 'script'
	$Command = Get-CheckField -Check $Check -Name 'command'
	$RequiredModule = Get-CheckField -Check $Check -Name 'requiredModule'
	$RequiredModuleVersion = Get-CheckField -Check $Check -Name 'requiredModuleVersion'
	if (-not $Name -or $Tier -notin @('required', 'advisory') -or (-not $Script -and -not $Command)) {
		throw "Check manifest entry is invalid: every check needs a name, a tier of 'required' or 'advisory', and a script or command."
	}
	if ($Names.ContainsKey($Name)) { throw "Duplicate check name: '$Name'." }
	$Names[$Name] = $true

	if ($Script) {
		$ScriptPath = if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $RepositoryRoot ($Script -replace '/', [IO.Path]::DirectorySeparatorChar) }
		$ProcessArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
		$CommandText = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
	}
	else {
		$EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
		$ProcessArguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $EncodedCommand"
		$CommandText = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
	}

	$Prepared += @{
		Index = $Prepared.Count; Name = $Name; Tier = $Tier
		Arguments = $ProcessArguments; CommandText = $CommandText; RequiredModule = $RequiredModule; RequiredModuleVersion = $RequiredModuleVersion
	}
}

try {
	foreach ($Check in $Prepared) {
		$Concurrent = $Check.Name -in $ConcurrentChecks
		if ($Concurrent) { Wait-CiSlot } else { Wait-CiSlot -Drain }
		$AvailableModule = @(if ($Check.RequiredModuleVersion) {
			Get-Module -ListAvailable -Name $Check.RequiredModule | Where-Object { $_.Version.ToString() -ceq $Check.RequiredModuleVersion }
		} elseif ($Check.RequiredModule) {
			Get-Module -ListAvailable -Name $Check.RequiredModule
		})
		if ($Check.RequiredModule -and $AvailableModule.Count -eq 0) {
			$ModuleIdentity = if ($Check.RequiredModuleVersion) { "$($Check.RequiredModule) $($Check.RequiredModuleVersion)" } else { [string] $Check.RequiredModule }
			$Results[$Check.Index] = [ordered]@{
				name = $Check.Name; tier = $Check.Tier; status = 'skipped'; durationSeconds = 0
				command = $Check.CommandText; message = "Skipped: module '$ModuleIdentity' is not available on this runner."
			}
			Write-Output "[$($Check.Tier)] $($Check.Name): skipped (module '$ModuleIdentity' unavailable)"
			continue
		}
		$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		try {
			$Child = Start-HiddenPowerShell -Arguments $Check.Arguments -WorkingDirectory $RepositoryRoot
			$Active.Add(@{ Check = $Check; Child = $Child; Stopwatch = $Stopwatch })
		}
		catch {
			$InfrastructureFailed = $true
			$Stopwatch.Stop()
			$Results[$Check.Index] = [ordered]@{
				name = $Check.Name; tier = $Check.Tier; status = 'failed'
				durationSeconds = [Math]::Round($Stopwatch.Elapsed.TotalSeconds, 3)
				command = $Check.CommandText; message = "CI child launch failed: $($_.Exception.Message)"
			}
		}
		if (-not $Concurrent) { Wait-CiSlot -Drain }
	}
	Wait-CiSlot -Drain
}
finally {
	# Abrupt parent termination also closes its job handles in the OS.
	foreach ($Running in $Active) {
		$Running.Child.Job.Dispose()
		$Running.Child.Gate.Dispose()
		$Running.Child.ResultGate.Dispose()
		$Running.Child.Process.Dispose()
	}
}

if (@($Results | Where-Object { $null -eq $_ }).Count -gt 0 -or $Results.Count -ne $Checks.Count) {
	throw 'CI result accounting failed: missing check result.'
}
foreach ($Result in $Results) {
	if ($Result.status -eq 'failed') {
		$FailureDetails += "FAILED [$($Result.tier)] $($Result.name)`nCommand: $($Result.command)`nOutput tail:`n$($Result.message)"
	}
}

$FinishedUtc = [DateTime]::UtcNow.ToString('o')
$Summary = [ordered]@{
	total = $Results.Count
	passed = @($Results | Where-Object { $_.status -eq 'passed' }).Count
	failed = @($Results | Where-Object { $_.status -eq 'failed' }).Count
	skipped = @($Results | Where-Object { $_.status -eq 'skipped' }).Count
	requiredFailed = @($Results | Where-Object { $_.tier -eq 'required' -and $_.status -eq 'failed' }).Count
}

$Report = [ordered]@{
	schemaVersion = 1
	revision = $Revision
	startedUtc = $StartedUtc
	finishedUtc = $FinishedUtc
	checks = $Results
	summary = $Summary
}
$ReportDirectory = Split-Path -Parent $ReportPath
if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
	New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
}
[System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $Report -Depth 6))

Write-Output ''
Write-Output ($Results | ForEach-Object { [pscustomobject]$_ } | Format-Table -Property name, tier, status, durationSeconds -AutoSize | Out-String -Width 200).TrimEnd()
Write-Output ''
Write-Output "Report: $ReportPath"

foreach ($Detail in $FailureDetails) {
	Write-Output ''
	Write-Output $Detail
}

if ($Summary.requiredFailed -gt 0 -or $InfrastructureFailed) {
	Write-Output ''
	Write-Output "CI suite failed: $($Summary.requiredFailed) required check(s) failed; infrastructure failure: $InfrastructureFailed."
	exit 1
}

Write-Output ''
Write-Output 'CI suite passed: no required check failed.'
exit 0
