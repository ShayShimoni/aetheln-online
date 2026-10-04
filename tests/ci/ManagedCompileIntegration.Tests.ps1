Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$GatePath = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$Tokens = $null
$ParseErrors = $null
$GateAst = [Management.Automation.Language.Parser]::ParseFile($GatePath, [ref] $Tokens, [ref] $ParseErrors)
if ($ParseErrors.Count -ne 0) { throw 'Managed compile integration: gate must parse.' }
$ParameterNames = @($GateAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($RequiredParameter in @('ManagedWorkspaceRoot', 'HostLeasePath')) {
	if ($ParameterNames -cnotcontains $RequiredParameter) {
		throw ('Managed compile integration: gate must declare ' + $RequiredParameter + '.')
	}
}

# Production code is inspected without invoking the real engine, runner,
# retained workspace, or executable gate entry point. Behavioral supervision
# fixtures below exercise the existing function against explicit test doubles.
function Import-GateFixtureFunction {
	param([Parameter(Mandatory)][string] $Name)
	$Definitions = @($GateAst.FindAll({ param($Node)
		$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name
	}, $true))
	if ($Definitions.Count -ne 1) { throw ('Expected exactly one gate function: ' + $Name) }
	return $Definitions[0].Extent.Text
}

foreach ($FunctionName in @('ConvertTo-DriverLiteral', 'ConvertTo-DriverValueText', 'New-NamedInvocationText', 'Invoke-CompileSupervisor', 'Add-Check', 'Write-RunnerReport')) {
	$Definition = Import-GateFixtureFunction -Name $FunctionName
	# ScriptBlock.Create has no source-file metadata. Bind only these automatic
	# path variables to the original gate location; do not rewrite its logic.
	$Definition = $Definition.Replace('$PSScriptRoot', ("'" + (Split-Path $GatePath).Replace("'", "''") + "'"))
	$Definition = $Definition.Replace('$PSCommandPath', ("'" + $GatePath.Replace("'", "''") + "'"))
	. ([scriptblock]::Create($Definition))
}
$WorkspaceCatch = @($GateAst.FindAll({ param($Node)
	$Node -is [Management.Automation.Language.TryStatementAst] -and
	@($Node.CatchClauses | Where-Object { $_.Extent.Text -match "Add-Check -Name 'managed-compile-workspace'" }).Count -eq 1
}, $true))
if ($WorkspaceCatch.Count -ne 1) { throw 'Expected one managed workspace report catch.' }
$WorkspaceCatchDefinition = 'function Invoke-FixtureWorkspaceCatch { param([string] $FixtureReason) try { throw $FixtureReason } ' +
	$WorkspaceCatch[0].CatchClauses[0].Extent.Text + ' }'
. ([scriptblock]::Create($WorkspaceCatchDefinition))
foreach ($Case in @(
	@('managed_workspace_partial_checkout', 'managed_workspace_partial_checkout'),
	@('managed_workspace_checkout_failed', 'managed_workspace_checkout_failed'),
	@('compile_timeout', 'compile_timeout'),
	@('unsafe raw Git stderr: token=value', 'managed_workspace_failed')
)) {
	$script:Checks = New-Object System.Collections.ArrayList
	$script:WorkspaceStarted = [DateTime]::UtcNow
	$Observed = ''
	try { Invoke-FixtureWorkspaceCatch -FixtureReason $Case[0] } catch { $Observed = $_.Exception.Message }
	if ($Observed -cne $Case[1] -or $script:Checks.Count -ne 1 -or $script:Checks[0].status -cne 'failed' -or $script:Checks[0].message -cne $Case[1]) {
		throw ('Managed workspace report did not preserve a safe reason: ' + $Case[0])
	}
}
Write-Output 'PASS managed-workspace-safe-failure-reporting'
$OuterTry = @($GateAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($OuterTry.Count -ne 1 -or $OuterTry[0].CatchClauses.Count -ne 1) { throw 'Expected exactly one outer gate try/catch/finally.' }
# Exercise the real outer catch/finally and real report publisher without the
# engine-discovery/Git/build body or process-level exit statement.
$PublicationFixture = 'function Invoke-FixturePublishedSupervisor { try { Invoke-CompileSupervisor } ' +
	$OuterTry[0].CatchClauses[0].Extent.Text + ' finally ' + $OuterTry[0].Finally.Extent.Text +
	'; return [pscustomobject]@{ requiredFailed = $RequiredFailed; failureCode = $FailureCode } }'
. ([scriptblock]::Create($PublicationFixture))

$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnManagedCompileIntegration-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
. (Join-Path $RepositoryRoot 'scripts/ci/EngineRunnerHostLease.ps1')
. (Join-Path $RepositoryRoot 'scripts/ci/RoutineCompileDeadline.ps1')
$script:FixtureFailures = New-Object 'Collections.Generic.List[string]'
$script:FixtureAssertions = 0
function Assert-Fixture($Condition, [string] $Message) {
	if (-not $Condition) { throw ('Fixture assertion: ' + $Message) }
	$script:FixtureAssertions++
}

function Invoke-PhaseChildScript {
	param([string] $InvocationText, [double] $TimeoutMinutes, [bool] $UseNativeExitCode,
		[string] $WatchdogRoot, [datetime] $AbsoluteDeadlineUtc, [scriptblock] $RemainingBudget)
	trap { $script:ChildFixtureFailure = $_.Exception.Message; throw }
	$script:FixtureChildCalls++
	Assert-Fixture -Condition $UseNativeExitCode -Message 'Supervisor requests native child exit status'
	Assert-Fixture -Condition ($TimeoutMinutes -eq $CompileTimeoutMinutes) -Message 'Configured duration forwarded unchanged'
	Assert-Fixture -Condition ($AbsoluteDeadlineUtc -eq $FixtureUtc.AddMilliseconds(50000)) -Message 'Hard deadline charges twelve seconds of staging rather than granting a fresh minute'
	Assert-Fixture -Condition ($null -ne $RemainingBudget -and (& $RemainingBudget) -eq 50000) -Message 'Hard OS wait also receives the shared monotonic remainder'
	$InvocationTokens = $null
	$InvocationErrors = $null
	$InvocationAst = [Management.Automation.Language.Parser]::ParseInput($InvocationText, [ref] $InvocationTokens, [ref] $InvocationErrors)
	Assert-Fixture -Condition ($InvocationErrors.Count -eq 0) -Message 'Generated child invocation parses'
	$Commands = @($InvocationAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.CommandAst] }, $true))
	Assert-Fixture -Condition ($Commands.Count -eq 1) -Message 'One child gate command only'
	$Elements = @($Commands[0].CommandElements)
	Assert-Fixture -Condition ($Elements[0].Value -ceq $GatePath) -Message 'Reinvokes the same gate, not an alternate executable'
	$Forwarded = @{}
	for ($Index = 1; $Index -lt $Elements.Count; $Index += 2) {
		Assert-Fixture -Condition ($Elements[$Index] -is [Management.Automation.Language.CommandParameterAst]) -Message 'Named child parameter'
		$Forwarded[$Elements[$Index].ParameterName] = $Elements[$Index + 1].SafeGetValue()
	}
	foreach ($Pair in @{
		Mode = $Mode; RepositoryRoot = $ResolvedRepository; SourceRevision = $SourceRevision; ArchiveRoot = $ArchiveRoot;
		RunnerName = $RunnerName; Repository = $Repository; ManagedWorkspaceRoot = $ManagedWorkspaceRoot;
		ManagedWorkspaceRegistrationPath = $ManagedWorkspaceRegistrationPath; ManagedWorkspaceRegistrationSha256 = $ManagedWorkspaceRegistrationSha256;
		HostLeasePath = $HostLeasePath; ReportPath = (Join-Path $WatchdogRoot 'child-report.json'); LogRoot = (Join-Path $ResolvedLogs 'compile')
	}.GetEnumerator()) {
		Assert-Fixture -Condition ($Forwarded.ContainsKey($Pair.Key) -and $Forwarded[$Pair.Key] -ceq $Pair.Value) -Message ('Exact child parameter: ' + $Pair.Key)
	}
	$Assignments = @($InvocationAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.AssignmentStatementAst] }, $true))
	Assert-Fixture -Condition ($Assignments.Count -eq 1 -and $Assignments[0].Left.Extent.Text -ceq '$global:AethelnCompileGateContext') -Message 'Exactly one original-start context'
	$ContextNodes = @($Assignments[0].Right.FindAll({ param($Node) $Node -is [Management.Automation.Language.HashtableAst] }, $true))
	Assert-Fixture -Condition ($ContextNodes.Count -eq 1) -Message 'One literal context hashtable'
	$ContextValue = $ContextNodes[0].SafeGetValue()
	Assert-Fixture -Condition ($ContextValue.startedUtc -ceq $Started.ToString('o')) -Message 'Child receives exact original start instant'
	Assert-Fixture -Condition ($ContextValue.startedTimestamp -eq $CompileStartedTimestamp) -Message 'Child receives the unchanged pre-checkout monotonic anchor'
	$SharingFailure = $null
	try {
		$Unexpected = [IO.File]::Open($HostLeasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		$Unexpected.Dispose()
	} catch {
		$SharingFailure = $_.Exception
		while ($null -ne $SharingFailure.InnerException) { $SharingFailure = $SharingFailure.InnerException }
	}
	Assert-Fixture -Condition ($SharingFailure -is [IO.IOException] -and ($SharingFailure.HResult -band 65535) -eq 32) -Message 'Real host lease is exclusive while child executes'
	if ($Scenario -ceq 'success') {
		# A separate harmless PowerShell process also observes the parent's real
		# exclusive file handle; no engine or gate entry point executes here.
		$ChildCode = 'try { $f=[IO.File]::Open(' + (ConvertTo-DriverLiteral -Value $HostLeasePath) + ',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $f.Dispose(); exit 7 } catch { $e=$_.Exception; while($null -ne $e.InnerException){$e=$e.InnerException}; if(($e.HResult -band 65535) -eq 32){exit 0}; exit 8 }'
		$Child = New-Object Diagnostics.Process
		$Child.StartInfo = New-Object Diagnostics.ProcessStartInfo
		$Child.StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
		$Child.StartInfo.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildCode))
		$Child.StartInfo.UseShellExecute = $false
		$Child.StartInfo.CreateNoWindow = $true
		try {
			Assert-Fixture -Condition ($Child.Start()) -Message 'Separate lock observer started'
			Assert-Fixture -Condition ($Child.WaitForExit(5000)) -Message 'Separate lock observer bounded exit'
			Assert-Fixture -Condition ($Child.ExitCode -eq 0) -Message 'Real separate child cannot acquire parent host lock'
		} finally {
			if (-not $Child.HasExited) { $Child.Kill(); $null = $Child.WaitForExit(1000) }
			$Child.Dispose()
		}
	}
	if ($Scenario -ceq 'child-throws') { throw 'fixture_child_launch_failed' }
	$null = New-Item -ItemType Directory -Path $WatchdogRoot
	if ($Scenario -cne 'missing-report') {
		$Report = [ordered]@{
			schemaVersion = 1; mode = $Mode; policy = 'incremental-target-compilation'; revision = $SourceRevision;
			runnerName = $RunnerName; startedUtc = $Started.ToString('o'); finishedUtc = [DateTime]::UtcNow.ToString('o');
			checks = @('incremental-client-build', 'incremental-server-build', 'managed-compile-workspace' | ForEach-Object { @{ name = $_; tier = 'required'; status = 'passed'; durationSeconds = 0; command = 'fixture'; message = 'fixture_child_passed' } });
			summary = @{ total = 3; passed = 3; failed = 0; skipped = 0; requiredFailed = 0 }; compileEvidence = $null
			managedWorkspace = @{ schemaVersion = 1; registrationId = ('a' * 32); registrationSha256 = $ManagedWorkspaceRegistrationSha256; preparationReceiptSha256 = ('d' * 64); revision = $SourceRevision; synchronized = $true }
			compileResources = @{ schemaVersion = 1; sampleCount = 1; measurementCount = 3; targetAdmissionCount = 2; minimumActionLimit = 1; maximumActionLimit = 4; failureReason = $null; volumes = @(@{ volumeId = 'fixture-volume'; knownAllocationBytes = 0; minimumAvailableBytes = 30GB }) }
		}
		if ($Scenario -eq 'empty-report') { $Report.checks = @() }
		if ($Scenario -eq 'missing-target') { $Report.checks = @($Report.checks | Where-Object name -ne 'incremental-server-build') }
		if ($Scenario -eq 'skipped-target') { $Report.checks[0].status = 'skipped' }
		if ($Scenario -eq 'duplicate-target') { $Report.checks += $Report.checks[0] }
		if ($Scenario -in @('empty-report', 'missing-target', 'skipped-target', 'duplicate-target')) {
			$Report.summary.total = $Report.checks.Count; $Report.summary.passed = @($Report.checks | Where-Object status -eq 'passed').Count; $Report.summary.skipped = @($Report.checks | Where-Object status -eq 'skipped').Count
		}
		if ($Scenario -eq 'missing-workspace-proof') { $Report.Remove('managedWorkspace') }
		if ($Scenario -eq 'wrong-registration-proof') { $Report.managedWorkspace.registrationSha256 = 'e' * 64 }
		if ($Scenario -eq 'missing-resource-proof') { $Report.Remove('compileResources') }
		if ($Scenario -eq 'single-target-admission') { $Report.compileResources.targetAdmissionCount = 1 }
		if ($Scenario -eq 'resource-proof-failed') { $Report.compileResources.failureReason = 'resource_pressure' }
		if ($Scenario -ceq 'failed-report') { $Report.summary.requiredFailed = 1 }
		if ($Scenario -in @('child-fails', 'contradictory-report')) {
			$Report.checks = @(@{ name = 'fixture-child'; tier = 'required'; status = 'failed'; message = 'fixture_child_failed'; command = 'fixture'; durationSeconds = 0 })
			if ($Scenario -ceq 'child-fails') { $Report.summary.total = 1; $Report.summary.passed = 0; $Report.summary.failed = 1; $Report.summary.requiredFailed = 1 }
		}
		if ($Scenario -ceq 'missing-summary') { $Report.Remove('summary') }
		if ($Scenario -ceq 'missing-checks') { $Report.Remove('checks') }
		[IO.File]::WriteAllText($Forwarded.ReportPath, ($Report | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
	}
	$Result = [ordered]@{ timedOut = $false; exitCode = 0; output = @(); cleanupFailure = $null; cleanupVerified = $true }
	switch -CaseSensitive ($Scenario) {
		'child-fails' { $Result.exitCode = 7 }
		'nonzero-green-report' { $Result.exitCode = 7 }
		'timeout-clean' { $Result.timedOut = $true }
		'cleanup-fails' { $Result.timedOut = $true; $Result.cleanupFailure = 'phase_cleanup_failed'; $Result.cleanupVerified = $false }
		'cleanup-fails-without-timeout' { $Result.cleanupFailure = 'phase_cleanup_failed'; $Result.cleanupVerified = $false }
		'cleanup-not-verified' { $Result.cleanupVerified = $false }
		'cleanup-proof-string' { $Result.cleanupVerified = 'true' }
		'cleanup-proof-missing' { $Result.Remove('cleanupVerified') }
		'null-result' { return $null }
	}
	return $Result
}

function Test-SupervisorScenario {
	param([string] $Scenario, [bool] $ExpectSuccess, [bool] $ExpectReleased)
	$CaseRoot = Join-Path $FixtureRoot $Scenario
	$null = New-Item -ItemType Directory -Path $CaseRoot
	$script:ResolvedLogs = $CaseRoot
	$script:ResolvedRepository = $RepositoryRoot
	$script:Mode = 'Compile'
	$script:SourceRevision = 'b' * 40
	$script:ArchiveRoot = Join-Path $CaseRoot "archive's fixture"
	$script:RunnerName = 'fixture-runner'
	$script:Repository = 'fixture/repository'
	$script:ManagedCompile = $true
	$script:ManagedWorkspaceRoot = Join-Path $CaseRoot "managed's fixture"
	$script:ManagedWorkspaceRegistrationPath = Join-Path $CaseRoot 'registration.json'
	$script:ManagedWorkspaceRegistrationSha256 = 'c' * 64
	$HostLeasePath = Join-Path $CaseRoot 'host.lease'
	$script:CompileTimeoutMinutes = 1.0
	$script:Started = [DateTime]::UtcNow.AddSeconds(-12)
	$script:FixtureUtc = [DateTime]::UtcNow
	$script:FixtureTick = 13000L
	$script:CompileStartedTimestamp = 1000L
	$script:RoutineDeadline = New-RoutineCompileDeadline -StartedUtc $Started.ToString('o') -StartedTimestamp $CompileStartedTimestamp -TimeoutMinutes $CompileTimeoutMinutes -TimestampFrequency 1000 -ReadTimestamp { return $script:FixtureTick } -ReadUtcNow { return $script:FixtureUtc }
	if ($Scenario -ceq 'lease-deadline') { $script:FixtureTick = 63000L }
	if ($Scenario -ceq 'lease-invalid') { $HostLeasePath = Join-Path $CaseRoot 'missing/host.lease' }
	$script:FixtureChildCalls = 0
	$script:ChildFixtureFailure = $null
	$script:FixtureChecks = New-Object 'Collections.Generic.List[object]'
	$script:RelayedReport = $null
	$script:SupervisorReceipt = $null
	$script:Checks = New-Object Collections.ArrayList
	$script:RequiredFailed = $false
	$script:FailureCode = $null
	$script:ManagedRegistration = $null
	$script:ManagedWorkspaceEvidence = $null
	$script:RoutineResourceMonitor = $null
	$script:CompileEvidenceIdentity = $null
	$script:CompileBuilds = @()
	$script:SupervisedChildExited = $false
	$script:ExplicitReportRequested = $true
	$script:ResolvedReportPath = Join-Path $CaseRoot 'final-report.json'
	$script:Policy = 'incremental-target-compilation'
	$script:RunnerNamePattern = '^[A-Za-z0-9-]+$'
	$Failure = $null
	$PublishedState = Invoke-FixturePublishedSupervisor
	if ($PublishedState.requiredFailed) { $Failure = $PublishedState.failureCode }
	$Problems = New-Object 'Collections.Generic.List[string]'
	if ($ExpectSuccess -and $null -ne $Failure) { $Problems.Add('Expected success; received ' + $Failure) }
	if (-not $ExpectSuccess -and $null -eq $Failure) { $Problems.Add('Failure scenario was accepted green') }
	$ExpectedCalls = if ($Scenario -in @('lease-deadline', 'lease-invalid')) { 0 } else { 1 }
	if ($script:FixtureChildCalls -ne $ExpectedCalls) { $Problems.Add('Unexpected child invocation count') }
	if (-not (Test-Path -LiteralPath $ResolvedReportPath -PathType Leaf)) { $Problems.Add('Final report was not published') }
	else {
		$FinalReport = Get-Content -LiteralPath $ResolvedReportPath -Raw | ConvertFrom-Json
		if ($FinalReport.PSObject.Properties.Name -cnotcontains 'summary' -or $FinalReport.PSObject.Properties.Name -cnotcontains 'checks') { $Problems.Add('Final JSON is missing checks or summary') }
		else {
			$FinalFailures = @($FinalReport.checks | Where-Object status -eq 'failed')
			if (-not $ExpectSuccess -and ($FinalReport.summary.requiredFailed -lt 1 -or $FinalFailures.Count -lt 1)) { $Problems.Add('Failure JSON must have nonzero requiredFailed and an explicit failed row') }
			if ($ExpectSuccess -and ($FinalReport.summary.requiredFailed -ne 0 -or $FinalFailures.Count -ne 0)) { $Problems.Add('Successful invocation published failure evidence') }
			if ($Scenario -ceq 'child-fails' -and ($FinalFailures.Count -ne 1 -or $FinalReport.summary.requiredFailed -ne 1 -or $FinalFailures[0].name -cne 'fixture-child')) {
				$Problems.Add('A validated child failure must retain its original row without a duplicate parent failure')
			}
		}
	}
	if (Test-Path -LiteralPath $HostLeasePath -PathType Leaf) {
		try {
			$Reader = [IO.File]::Open($HostLeasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
			$Reader.Dispose()
			$Rows = @(Get-Content -LiteralPath $HostLeasePath | ForEach-Object { $_ | ConvertFrom-Json })
			$ExpectedState = if ($ExpectReleased) { 'released' } else { 'held' }
			if ($Rows[-1].state -cne $ExpectedState) { $Problems.Add('Expected terminal journal state ' + $ExpectedState + '; got ' + $Rows[-1].state) }
			if ($ExpectReleased -and ($Rows[-1].cleanupVerified -isnot [bool] -or -not $Rows[-1].cleanupVerified)) { $Problems.Add('Release is missing literal cleanup proof') }
		} catch { $Problems.Add('Lease handle was not closed after supervisor returned: ' + $_.Exception.Message) }
	}
	# Failed fixture diagnostics never leave an in-process handle leak. This closes
	# only this test's own lease without forging a release or deleting evidence.
	$Registry = Get-Variable -Name EngineRunnerHostLeases -Scope Script -ErrorAction SilentlyContinue
	if ($null -ne $Registry -and $Registry.Value.ContainsKey($HostLeasePath)) {
		$OwnEntry = $Registry.Value[$HostLeasePath]
		Close-EngineRunnerHostLease -Lease $OwnEntry.lease
	}
	if ($Problems.Count -gt 0) { throw (($Problems -join '; ') + '; supervisor result=' + $Failure + '; fixture detail=' + $script:ChildFixtureFailure) }
	$script:FixtureAssertions++
}

function Test-BlankManagedTuple {
	param([string] $Name, [AllowEmptyString()][string] $Value)
	$CaseRoot = Join-Path $FixtureRoot $Name
	$null = New-Item -ItemType Directory -Path $CaseRoot
	# The deliberate nonexistent repository is a second safety boundary: even a
	# fail-open tuple reaches repository_root_invalid before Git or engine work.
	$Arguments = [ordered]@{ Mode = 'Compile'; RepositoryRoot = (Join-Path $CaseRoot 'nonexistent-repository'); SourceRevision = ('d' * 40);
		LogRoot = (Join-Path $CaseRoot 'logs'); ManagedWorkspaceRoot = $Value; ManagedWorkspaceRegistrationPath = $Value;
		ManagedWorkspaceRegistrationSha256 = $Value; HostLeasePath = $Value; ReportPath = (Join-Path $CaseRoot 'report.json') }
	$Code = New-NamedInvocationText -Target $GatePath -Parameters $Arguments
	$Child = New-Object Diagnostics.Process
	$Child.StartInfo = New-Object Diagnostics.ProcessStartInfo
	$Child.StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
	$Child.StartInfo.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
	$Child.StartInfo.UseShellExecute = $false
	$Child.StartInfo.CreateNoWindow = $true
	$Child.StartInfo.RedirectStandardOutput = $true
	$Child.StartInfo.RedirectStandardError = $true
	try {
		Assert-Fixture -Condition ($Child.Start()) -Message 'Blank tuple fixture starts'
		$OutputTask = $Child.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Child.StandardError.ReadToEndAsync()
		Assert-Fixture -Condition ($Child.WaitForExit(10000)) -Message 'Blank tuple fixture has bounded exit'
		$Child.WaitForExit()
		$Output = $OutputTask.Result + $ErrorTask.Result
		Assert-Fixture -Condition ($Child.ExitCode -ne 0 -and $Output -match 'managed_workspace_configuration_invalid') -Message ('Explicit ' + $Name + ' must reject managed configuration, not silently select legacy compile. Observed: ' + $Output)
	} finally {
		if (-not $Child.HasExited) { $Child.Kill(); $null = $Child.WaitForExit(1000) }
		$Child.Dispose()
	}
}

foreach ($Case in @(
	@('success', $true, $true), @('lease-invalid', $false, $false), @('lease-deadline', $false, $false),
	@('child-fails', $false, $true), @('timeout-clean', $false, $true), @('missing-report', $false, $true), @('failed-report', $false, $true),
	@('nonzero-green-report', $false, $true), @('contradictory-report', $false, $true), @('missing-summary', $false, $true), @('missing-checks', $false, $true),
	@('empty-report', $false, $true), @('missing-target', $false, $true), @('skipped-target', $false, $true), @('duplicate-target', $false, $true),
	@('missing-workspace-proof', $false, $true), @('wrong-registration-proof', $false, $true), @('missing-resource-proof', $false, $true), @('single-target-admission', $false, $true), @('resource-proof-failed', $false, $true),
	@('cleanup-fails', $false, $false), @('cleanup-fails-without-timeout', $false, $false), @('cleanup-not-verified', $false, $false),
	@('cleanup-proof-string', $false, $false), @('cleanup-proof-missing', $false, $false), @('null-result', $false, $false), @('child-throws', $false, $false)
)) {
	try { Test-SupervisorScenario -Scenario $Case[0] -ExpectSuccess $Case[1] -ExpectReleased $Case[2]; Write-Output ('PASS ' + $Case[0]) }
	catch { $script:FixtureFailures.Add($Case[0] + ': ' + $_.Exception.Message); Write-Output ('FAIL ' + $script:FixtureFailures[-1]) }
}
foreach ($BlankCase in @(@('blank-tuple', ''), @('whitespace-tuple', '   '))) {
	try { Test-BlankManagedTuple -Name $BlankCase[0] -Value $BlankCase[1]; Write-Output ('PASS ' + $BlankCase[0]) }
	catch { $script:FixtureFailures.Add($BlankCase[0] + ': ' + $_.Exception.Message); Write-Output ('FAIL ' + $script:FixtureFailures[-1]) }
}
# #239: run the gate's real trust callback (extracted from the gate source)
# inside the real Sync-ManagedCompileWorkspace. An unbound callback reads the
# sync's own ControlRoot/SourceRevision parameters and trusts any value.
. (Join-Path $RepositoryRoot 'scripts/ci/ManagedCompileWorkspace.ps1')
$TrustAssignments = @($GateAst.FindAll({ param($Node)
	$Node -is [Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -ceq '$TrustRegisteredWorkspace'
}, $true))
if ($TrustAssignments.Count -ne 1) { throw 'Expected exactly one gate trust callback assignment.' }
$TrustRoot = Join-Path $FixtureRoot 'trust'
foreach ($Name in @('control-a', 'control-b', 'target', 'common')) { $null = New-Item -ItemType Directory -Path (Join-Path $TrustRoot $Name) }
function Invoke-GateTrustFixture {
	param([string] $GateControl, [string] $GateRevision, [string] $SyncControl, [string] $SyncRevision)
	$ControlRoot = $GateControl
	$SourceRevision = $GateRevision
	$Registered = [pscustomobject]@{ targetRoot = (Join-Path $TrustRoot 'target'); repository = 'owner/repository' }
	. ([scriptblock]::Create($TrustAssignments[0].Extent.Text))
	try {
		$null = Sync-ManagedCompileWorkspace -ControlRoot $SyncControl -TargetRoot $Registered.targetRoot -SourceRevision $SyncRevision -Repository 'owner/repository' -ExpectedGitCommonDirectory (Join-Path $TrustRoot 'common') -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(2)) -AssertRepositoryTrust $TrustRegisteredWorkspace
		return 'none'
	} catch { return $_.Exception.Message }
}
$ControlA = Join-Path $TrustRoot 'control-a'
$ControlB = Join-Path $TrustRoot 'control-b'
$RevisionA = 'a' * 40
$RevisionB = 'b' * 40
# Matching values and a casing-only control-root difference pass the trust
# gate (the sync then fails later on the fixture's missing Git state).
foreach ($Case in @(
	@('trust-callback-accepts-matching-values', $ControlA, $RevisionA, $ControlA, $RevisionA, $false),
	@('trust-callback-accepts-control-root-casing-difference', $ControlA, $RevisionA, $ControlA.ToUpperInvariant(), $RevisionA, $false),
	@('trust-callback-rejects-mismatched-control-root', $ControlA, $RevisionA, $ControlB, $RevisionA, $true),
	@('trust-callback-rejects-mismatched-revision', $ControlA, $RevisionA, $ControlA, $RevisionB, $true)
)) {
	try {
		$Observed = Invoke-GateTrustFixture -GateControl $Case[1] -GateRevision $Case[2] -SyncControl $Case[3] -SyncRevision $Case[4]
		$Rejected = $Observed -ceq 'managed_workspace_trust_required'
		Assert-Fixture -Condition ($Rejected -eq $Case[5]) -Message ('Trust callback outcome was ' + $Observed)
		Write-Output ('PASS ' + $Case[0])
	} catch { $script:FixtureFailures.Add($Case[0] + ': ' + $_.Exception.Message); Write-Output ('FAIL ' + $script:FixtureFailures[-1]) }
}
Write-Output ('Fixtures retained: ' + $FixtureRoot)
if ($script:FixtureFailures.Count -gt 0) { throw ($script:FixtureFailures.Count.ToString() + ' managed compile integration cases failed.') }
Write-Output ('PASS ' + $script:FixtureAssertions + ' assertions across 29 managed compile supervisor/publication/argument scenarios.')
