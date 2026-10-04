Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$GatePath = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$Tokens = $null
$ParseErrors = $null
$GateAst = [Management.Automation.Language.Parser]::ParseFile($GatePath, [ref] $Tokens, [ref] $ParseErrors)
if ($ParseErrors.Count -ne 0) { throw 'Routine gate fixture requires a parseable production gate.' }
$script:RoutineAssertions = 0
function Assert-RoutineGateFixture {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw ('Routine gate fixture: ' + $Message) }
	$script:RoutineAssertions++
}
foreach ($FunctionName in @('Initialize-ManagedCompileResourceMonitor', 'Assert-RoutineCompileProgress', 'Invoke-RoutineManagedBuild', 'Invoke-Captured',
	'Read-JsonStrict', 'Assert-ClosedObject', 'Assert-UniqueJsonProperties', 'Test-IsReparsePoint', 'Resolve-RequiredDirectory', 'Resolve-OutputRoot', 'Test-IsWithin', 'Write-RunnerReport',
	'ConvertTo-DriverLiteral', 'ConvertTo-DriverValueText', 'New-NamedInvocationText')) {
	$Definitions = @($GateAst.FindAll({ param($Node)
		$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $FunctionName
	}, $true))
	Assert-RoutineGateFixture -Condition ($Definitions.Count -eq 1) -Message ('Expected exactly one production function: ' + $FunctionName)
	$Definition = $Definitions[0].Extent.Text.Replace('$PSScriptRoot', ("'" + (Split-Path $GatePath).Replace("'", "''") + "'"))
	$Definition = $Definition.Replace('$PSCommandPath', ("'" + $GatePath.Replace("'", "''") + "'"))
	. ([scriptblock]::Create($Definition))
}
. (Join-Path $RepositoryRoot 'scripts/ci/ManagedCompileWorkspace.ps1')
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnRoutineGate-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$ControlRoot = Join-Path $FixtureRoot 'control'
$ManagedWorkspaceRoot = Join-Path $FixtureRoot 'target'
$EngineRoot = Join-Path $FixtureRoot 'engine'
$ToolchainRoot = Join-Path $FixtureRoot 'toolchain'
$LogRoot = Join-Path $FixtureRoot 'logs/compile'
$CommonRoot = Join-Path $FixtureRoot 'common-git'
foreach ($Path in @($ControlRoot, $ManagedWorkspaceRoot, $EngineRoot, $ToolchainRoot, $LogRoot, $CommonRoot)) { $null = New-Item -ItemType Directory -Path $Path -Force }
$ResolvedRepository = $ManagedWorkspaceRoot
$ResolvedLogs = $LogRoot
$RoutineDeadline = [pscustomobject]@{ fixtureDeadline = $true }
$RoutineResourceMonitor = [pscustomobject]@{ fixtureMonitor = $true }
$script:ManagedCompile = $true
$script:IsCompileChild = $true
$script:Mode = 'Compile'
$FixtureCaptureExecutable = Join-Path $PSHOME 'powershell.exe'
$script:DeadlineCalls = 0
$script:ResourceCalls = 0
$script:CommandCalls = 0
$script:ActionCalls = 0
$script:DeadlineFailure = $null
$script:ResourceFailure = $null
$script:ActionFailure = $null
$script:ActionLimit = 3
$script:CommandScenario = 'success'
$script:LastEvidenceRoot = $null
$script:EvidenceRoots = New-Object 'Collections.Generic.HashSet[string]'
$script:ObservedRoots = $null
$script:RoutineFailures = New-Object 'Collections.Generic.List[string]'
function Assert-RoutineGateFailure {
	param([scriptblock] $Action, [string] $Case)
	$Observed = $null
	try { $null = & $Action } catch { $Observed = $_.Exception.Message }
	Assert-RoutineGateFixture -Condition (-not [string]::IsNullOrWhiteSpace($Observed) -and $Observed -cmatch '^[a-z0-9_]+$') -Message ($Case + ' must fail with a bounded stable reason; got ' + $Observed)
}
function Get-RoutineCompileRemainingMillisecondCount {
	param($Deadline)
	Assert-RoutineGateFixture -Condition ($Deadline -eq $RoutineDeadline) -Message 'Original deadline forwarded.'
	$script:DeadlineCalls++
	if ($null -ne $script:DeadlineFailure) { throw $script:DeadlineFailure }
	return 12000L
}
function Update-RoutineCompileResources {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only test counters; no external state changes.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Matches the production seam under test.')]
	[CmdletBinding()]
	[OutputType([bool])]
	param($Monitor)
	Assert-RoutineGateFixture -Condition ($Monitor -eq $RoutineResourceMonitor) -Message 'Same resource monitor forwarded.'
	$script:ResourceCalls++
	if ($null -ne $script:ResourceFailure) { throw $script:ResourceFailure }
	return $true
}
function Get-RoutineCompileActionLimit {
	param($Monitor)
	Assert-RoutineGateFixture -Condition ($Monitor -eq $RoutineResourceMonitor) -Message 'Action admission uses shared monitor.'
	$script:ActionCalls++
	if ($null -ne $script:ActionFailure) { throw $script:ActionFailure }
	return $script:ActionLimit
}
function New-RoutineCompileResourceMonitor {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Captures injected roots and returns an in-memory test monitor.')]
	[CmdletBinding()]
	param($Roots, $KnownAllocations)
	$null = $KnownAllocations
	$script:ObservedRoots = $Roots
	return [pscustomobject]@{ fixtureMonitor = $true }
}
function Get-RoutineCompileResourceProof {
	param($Monitor)
	Assert-RoutineGateFixture -Condition ($Monitor -eq $RoutineResourceMonitor) -Message 'Report uses current resource monitor.'
	return [pscustomobject]@{ schemaVersion = 1; sampleCount = 3; failureReason = 'resource_pressure' }
}
function Invoke-RoutineCompileCommand {
	param([string] $Executable, [string[]] $Arguments, [string] $WorkingDirectory, [scriptblock] $OnProgress)
	$script:CommandCalls++
	Assert-RoutineGateFixture -Condition ($WorkingDirectory -ceq $ResolvedRepository) -Message 'Managed command working directory is retained target.'
	Assert-RoutineGateFixture -Condition ($null -ne $OnProgress) -Message 'Managed command has progress callback.'
	$BeforeDeadline = $script:DeadlineCalls
	$BeforeResource = $script:ResourceCalls
	& $OnProgress
	Assert-RoutineGateFixture -Condition ($script:DeadlineCalls -gt $BeforeDeadline -and $script:ResourceCalls -gt $BeforeResource) -Message 'Command callback enforces deadline and resources.'
	if ($Executable -ceq $FixtureCaptureExecutable) {
		Assert-RoutineGateFixture -Condition ($Arguments.Count -eq 2 -and $Arguments[0] -ceq 'argument with spaces' -and $Arguments[1] -ceq 'tail') -Message 'Managed captured command preserves argument vector.'
		return @{ exitCode = 19; output = @('fixture-command-output') }
	}
	Assert-RoutineGateFixture -Condition ($Executable -ceq (Join-Path (Split-Path $GatePath) 'InitialPreparation.BuildInvocation.ps1')) -Message 'Build invokes the control-root pinned wrapper, never raw Build.bat.'
	Assert-RoutineGateFixture -Condition ($Arguments.Count % 2 -eq 0) -Message 'Wrapper has paired named arguments.'
	$Forwarded = @{}
	for ($Index = 0; $Index -lt $Arguments.Count; $Index += 2) { $Forwarded[$Arguments[$Index]] = $Arguments[$Index + 1] }
	foreach ($Pair in @{
		'-Target' = $FixtureTarget.target; '-Platform' = $FixtureTarget.platform; '-ActionLimit' = $script:ActionLimit.ToString([Globalization.CultureInfo]::InvariantCulture);
		'-EngineRoot' = $EngineRoot; '-TargetRoot' = $ResolvedRepository; '-LinuxToolchainRoot' = $ToolchainRoot
	}.GetEnumerator()) {
		Assert-RoutineGateFixture -Condition ($Forwarded.ContainsKey($Pair.Key) -and $Forwarded[$Pair.Key] -ceq $Pair.Value) -Message ('Pinned wrapper argument ' + $Pair.Key)
	}
	Assert-RoutineGateFixture -Condition ($Forwarded.Count -eq 7 -and $Forwarded.ContainsKey('-EvidenceRoot')) -Message 'Exact wrapper argument set.'
	$Evidence = $Forwarded['-EvidenceRoot']
	Assert-RoutineGateFixture -Condition ((Test-Path -LiteralPath $Evidence -PathType Container) -and @(Get-ChildItem -LiteralPath $Evidence -Force).Count -eq 0) -Message 'Build evidence directory starts empty.'
	Assert-RoutineGateFixture -Condition ($script:EvidenceRoots.Add($Evidence)) -Message 'Each target invocation gets fresh evidence directory.'
	$script:LastEvidenceRoot = $Evidence
	$Receipt = [ordered]@{ schemaVersion = 1; target = $FixtureTarget.target; platform = $FixtureTarget.platform; nativeExitCode = 0; infrastructureFailure = $null }
	$WrapperExit = 0
	switch -CaseSensitive ($script:CommandScenario) {
		'native-failure' { $Receipt.nativeExitCode = 7; $WrapperExit = 7 }
		'wrapper-failure-green-receipt' { $WrapperExit = 7 }
		'green-wrapper-native-failure' { $Receipt.nativeExitCode = 7 }
		'infrastructure-failure' { $Receipt.infrastructureFailure = 'build_capture_failed' }
		'null-native' { $Receipt.nativeExitCode = $null }
		'string-native' { $Receipt.nativeExitCode = '0' }
		'boolean-native' { $Receipt.nativeExitCode = $false }
		'string-schema' { $Receipt.schemaVersion = '1' }
		'wrong-schema' { $Receipt.schemaVersion = 2 }
		'wrong-target' { $Receipt.target = 'UnrealEditor' }
		'wrong-platform' { $Receipt.platform = 'Linux-Wrong' }
		'missing-field' { $Receipt.Remove('infrastructureFailure') }
		'extra-field' { $Receipt['unexpected'] = $true }
	}
	if ($script:CommandScenario -cne 'missing-receipt') {
		$Json = $Receipt | ConvertTo-Json -Compress
		if ($script:CommandScenario -ceq 'malformed-receipt') { $Json = '{' }
		if ($script:CommandScenario -ceq 'duplicate-receipt') { $Json = $Json.Insert(1, '"schemaVersion":1,') }
		if ($script:CommandScenario -ceq 'oversized-receipt') { $Json += ' ' * 8193 }
		[IO.File]::WriteAllText((Join-Path $Evidence 'native-result.json'), $Json, (New-Object Text.UTF8Encoding($false)))
	}
	if ($script:CommandScenario -cne 'missing-log') {
		$LogPath = Join-Path $Evidence 'build.log'
		if ($script:CommandScenario -in @('oversized-log', 'exact-limit-log')) {
			$Length = if ($script:CommandScenario -ceq 'oversized-log') { 16MB + 1L } else { 16MB }
			$Stream = [IO.File]::Open($LogPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
			try { $Stream.SetLength($Length) } finally { $Stream.Dispose() }
		} elseif ($script:CommandScenario -ceq 'newline-flood-log') {
			[IO.File]::WriteAllText($LogPath, ("`n" * 65537), (New-Object Text.UTF8Encoding($false)))
		} else { [IO.File]::WriteAllText($LogPath, 'Target is up to date', (New-Object Text.UTF8Encoding($false))) }
	}
	return @{ exitCode = $WrapperExit; output = @('wrapper output is not native build evidence') }
}

# Initialize against harmless fixture directories; inspect only the two
# explicitly scoped non-secret toolchain path variables and restore them.
$PreviousEngineRoot = [Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')
$PreviousToolchainRoot = [Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')
$RepositoryRoot = $ControlRoot
$script:ManagedRegistration = [pscustomobject]@{ record = [pscustomobject]@{ gitCommonDirectory = $CommonRoot } }
try {
	[Environment]::SetEnvironmentVariable('AETHELN_ENGINE_ROOT', $EngineRoot, 'Process')
	[Environment]::SetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', $ToolchainRoot, 'Process')
	Initialize-ManagedCompileResourceMonitor
} finally {
	[Environment]::SetEnvironmentVariable('AETHELN_ENGINE_ROOT', $PreviousEngineRoot, 'Process')
	[Environment]::SetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', $PreviousToolchainRoot, 'Process')
}
Assert-RoutineGateFixture -Condition ($script:ObservedRoots.Count -eq 7) -Message 'Exactly the seven actual touched root roles are monitored.'
foreach ($Pair in @{
	control = $ControlRoot; target = $ManagedWorkspaceRoot; engine = $EngineRoot; toolchain = $ToolchainRoot;
	evidence = $ResolvedLogs; temporary = [IO.Path]::GetTempPath(); git = $CommonRoot
}.GetEnumerator()) {
	Assert-RoutineGateFixture -Condition ($script:ObservedRoots.Contains($Pair.Key) -and
		[IO.Path]::GetFullPath($script:ObservedRoots[$Pair.Key]) -ieq [IO.Path]::GetFullPath($Pair.Value)) -Message ('Actual monitored root ' + $Pair.Key)
}
$script:DeadlineCalls = 0
$script:ResourceCalls = 0
# Cooperative callback checks are independent of any real engine process.
$null = Assert-RoutineCompileProgress
Assert-RoutineGateFixture -Condition ($script:DeadlineCalls -eq 1 -and $script:ResourceCalls -eq 1) -Message 'Progress checks both gates.'
$script:DeadlineFailure = 'compile_timeout'
Assert-RoutineGateFailure -Action { Assert-RoutineCompileProgress } -Case 'deadline'
Assert-RoutineGateFixture -Condition ($script:ResourceCalls -eq 1) -Message 'Expired deadline stops before resource probe.'
$script:DeadlineFailure = $null
$script:ResourceFailure = 'resource_pressure'
Assert-RoutineGateFailure -Action { Assert-RoutineCompileProgress } -Case 'resource pressure'
$script:ResourceFailure = $null
$SavedMonitor = $RoutineResourceMonitor
$RoutineResourceMonitor = $null
$null = Assert-RoutineCompileProgress
$RoutineResourceMonitor = $SavedMonitor
$Captured = Invoke-Captured -Executable $FixtureCaptureExecutable -Arguments @('argument with spaces', 'tail')
Assert-RoutineGateFixture -Condition ($Captured.exitCode -eq 19 -and $Captured.output[0] -ceq 'fixture-command-output') -Message 'Managed capture delegates without masking native status.'
$BeforeCommands = $script:CommandCalls
$script:ResourceFailure = 'resource_pressure'
Assert-RoutineGateFailure -Action { Invoke-Captured -Executable $FixtureCaptureExecutable -Arguments @('argument with spaces', 'tail') } -Case 'captured command callback pressure'
Assert-RoutineGateFixture -Condition ($script:CommandCalls -le $BeforeCommands + 1) -Message 'No command retry or unmanaged fallback after callback failure.'
$script:ResourceFailure = $null
$BeforeCommands = $script:CommandCalls
$script:ManagedCompile = $false
function Invoke-FixtureLegacyNative { $global:LASTEXITCODE = 23; return 'legacy-output' }
$Legacy = Invoke-Captured -Executable 'Invoke-FixtureLegacyNative' -Arguments @()
Assert-RoutineGateFixture -Condition ($script:CommandCalls -eq $BeforeCommands -and $Legacy.exitCode -eq 23 -and $Legacy.output[0] -ceq 'legacy-output') -Message 'Legacy capture remains unchanged and does not invoke managed command path.'
$script:ManagedCompile = $true
$Targets = @(
	[ordered]@{ name = 'incremental-client-build'; target = 'AethelnOnlineClient'; platform = 'Win64'; arguments = @('forbidden-raw-build-fallback'); label = 'client' },
	[ordered]@{ name = 'incremental-server-build'; target = 'AethelnOnlineServer'; platform = 'Linux'; arguments = @('forbidden-raw-build-fallback'); label = 'server' }
)
foreach ($FixtureTarget in $Targets) {
	$script:CommandScenario = 'success'
	$BeforeActions = $script:ActionCalls
	$Result = Invoke-RoutineManagedBuild -Target $FixtureTarget
	Assert-RoutineGateFixture -Condition ($Result.exitCode -eq 0 -and @($Result.output) -contains 'Target is up to date') -Message 'Native log, not wrapper stdout, feeds build evidence.'
	Assert-RoutineGateFixture -Condition ($script:ActionCalls -eq $BeforeActions + 1) -Message 'Each target independently admits an action cap.'
	$script:ActionLimit = 2
}
$FixtureTarget = $Targets[0]
$script:ActionFailure = 'resource_admission_refused'
$BeforeCommands = $script:CommandCalls
Assert-RoutineGateFailure -Action { Invoke-RoutineManagedBuild -Target $FixtureTarget } -Case 'action admission refused'
Assert-RoutineGateFixture -Condition ($script:CommandCalls -eq $BeforeCommands) -Message 'Admission failure launches no wrapper.'
$script:ActionFailure = $null
$script:ResourceFailure = 'resource_pressure'
Assert-RoutineGateFailure -Action { Invoke-RoutineManagedBuild -Target $FixtureTarget } -Case 'build resource pressure before launch'
Assert-RoutineGateFixture -Condition ($script:CommandCalls -eq $BeforeCommands) -Message 'Resource pressure launches no wrapper or fallback.'
$script:ResourceFailure = $null
foreach ($Scenario in @('native-failure', 'wrapper-failure-green-receipt', 'green-wrapper-native-failure', 'infrastructure-failure',
	'null-native', 'string-native', 'boolean-native', 'string-schema', 'wrong-schema', 'wrong-target', 'wrong-platform',
	'missing-field', 'extra-field', 'missing-receipt', 'malformed-receipt', 'duplicate-receipt', 'oversized-receipt', 'missing-log', 'oversized-log', 'exact-limit-log', 'newline-flood-log')) {
	try {
		$script:CommandScenario = $Scenario
		$BeforeCommands = $script:CommandCalls
		if ($Scenario -in @('native-failure', 'exact-limit-log')) {
			$Result = Invoke-RoutineManagedBuild -Target $FixtureTarget
			$ExpectedExit = if ($Scenario -ceq 'native-failure') { 7 } else { 0 }
			Assert-RoutineGateFixture -Condition ($Result.exitCode -eq $ExpectedExit) -Message ($Scenario + ' preserves valid native status.')
		} else { Assert-RoutineGateFailure -Action { Invoke-RoutineManagedBuild -Target $FixtureTarget } -Case $Scenario }
		Assert-RoutineGateFixture -Condition ($script:CommandCalls -eq $BeforeCommands + 1) -Message ($Scenario + ' uses exactly one supervised wrapper invocation.')
		Write-Output ('PASS ' + $Scenario)
	} catch { $script:RoutineFailures.Add($Scenario + ': ' + $_.Exception.Message); Write-Output ('FAIL ' + $script:RoutineFailures[-1]) }
}
$script:ExplicitReportRequested = $true
$ResolvedReportPath = Join-Path $FixtureRoot 'resource-failure-report.json'
$Checks = New-Object Collections.ArrayList
$null = $Checks.Add([ordered]@{ name = 'compile-gate'; tier = 'required'; status = 'failed'; durationSeconds = 0; command = 'fixture'; message = 'resource_pressure' })
$script:Started = [DateTime]::UtcNow
$script:Policy = 'incremental-target-compilation'
$script:SourceRevision = 'b' * 40
$script:RunnerName = 'fixture-runner'
$script:RunnerNamePattern = '^[A-Za-z0-9-]+$'
$script:CompileEvidenceIdentity = $null
$script:CompileBuilds = @()
$script:RelayedReport = $null
$script:ManagedWorkspaceEvidence = $null
$script:SupervisorReceipt = $null
Write-RunnerReport
$Report = Get-Content -LiteralPath $ResolvedReportPath -Raw | ConvertFrom-Json
Assert-RoutineGateFixture -Condition ($Report.summary.requiredFailed -eq 1 -and $Report.compileResources.sampleCount -eq 3 -and $Report.compileResources.failureReason -ceq 'resource_pressure') -Message 'Failed child report preserves resource aggregate and failure reason.'

# Inspect real entrypoint wiring without invoking Git synchronization or build.
$EntryCommands = @($GateAst.EndBlock.FindAll({ param($Node) $Node -is [Management.Automation.Language.CommandAst] }, $true))
$RegistrationCalls = @($EntryCommands | Where-Object { $_.GetCommandName() -ceq 'Get-ManagedCompileRegistration' })
$InitializationCalls = @($EntryCommands | Where-Object { $_.GetCommandName() -ceq 'Initialize-ManagedCompileResourceMonitor' })
$SyncCalls = @($EntryCommands | Where-Object { $_.GetCommandName() -ceq 'Sync-ManagedCompileWorkspace' })
Assert-RoutineGateFixture -Condition ($RegistrationCalls.Count -eq 1 -and $InitializationCalls.Count -eq 1 -and $SyncCalls.Count -eq 1) -Message 'Managed entrypoint performs registration, resource initialization and synchronization once.'
Assert-RoutineGateFixture -Condition ($RegistrationCalls[0].Extent.StartOffset -lt $InitializationCalls[0].Extent.StartOffset -and $InitializationCalls[0].Extent.StartOffset -lt $SyncCalls[0].Extent.StartOffset) -Message 'Resources established after registration and before retained synchronization.'
Assert-RoutineGateFixture -Condition ($SyncCalls[0].Extent.Text -match '-OnProgress\s+\{\s*Assert-RoutineCompileProgress\s*\}') -Message 'Retained synchronization uses combined deadline/resource callback.'
$ManagedBuildCalls = @($EntryCommands | Where-Object { $_.GetCommandName() -ceq 'Invoke-RoutineManagedBuild' })
Assert-RoutineGateFixture -Condition ($ManagedBuildCalls.Count -eq 1) -Message 'Existing compile target loop selects managed build once per target.'

# A real managed entrypoint, process supervisor, registration, disposable Git
# synchronization and command binding run together. Only Unreal execution and
# resource measurements are substituted; none of the retained project/runner
# directories participates in this fixture.
function Set-RoutineEntryFixtureFile {
	[CmdletBinding(SupportsShouldProcess)]
	param([string] $Path, [string] $Value)
	if (-not $PSCmdlet.ShouldProcess($Path, 'Create disposable entrypoint fixture')) { return }
	$null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
	[IO.File]::WriteAllText($Path, $Value, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-RoutineEntryFixtureGit {
	param([string] $Root, [string[]] $Arguments)
	$Lines = @(& git -C $Root -c core.autocrlf=false @Arguments 2>&1)
	if ($LASTEXITCODE -ne 0) { throw ('Disposable fixture Git failed: ' + ($Lines -join ' ')) }
	return (($Lines | ForEach-Object { [string] $_ }) -join "`n")
}
function Invoke-RoutineEntryFixtureProcess {
	param([string] $EntryGate, [Collections.IDictionary] $Parameters, [string] $FixtureEngine, [string] $FixtureToolchain)
	$Code = New-NamedInvocationText -Target $EntryGate -Parameters $Parameters
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = New-Object Diagnostics.ProcessStartInfo
	$Process.StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
	$Process.StartInfo.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
	$Process.StartInfo.UseShellExecute = $false
	$Process.StartInfo.CreateNoWindow = $true
	$Process.StartInfo.RedirectStandardOutput = $true
	$Process.StartInfo.RedirectStandardError = $true
	$Process.StartInfo.EnvironmentVariables['AETHELN_ENGINE_ROOT'] = $FixtureEngine
	$Process.StartInfo.EnvironmentVariables['AETHELN_LINUX_TOOLCHAIN_ROOT'] = $FixtureToolchain
	try {
		$null = $Process.Start()
		$OutputTask = $Process.StandardOutput.ReadToEndAsync()
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		if (-not $Process.WaitForExit(90000)) { throw 'routine_entry_fixture_timeout' }
		$Process.WaitForExit()
		return @{ exitCode = $Process.ExitCode; output = $OutputTask.Result + $ErrorTask.Result }
	} finally {
		if (-not $Process.HasExited) { $Process.Kill(); $null = $Process.WaitForExit(5000) }
		$Process.Dispose()
	}
}
$EntryRoot = Join-Path $FixtureRoot 'actual-entrypoint'
$EntryControl = Join-Path $EntryRoot 'control'
$EntryTarget = Join-Path $EntryRoot 'target'
$EntryEngine = Join-Path $EntryRoot 'engine'
$EntryToolchain = Join-Path $EntryRoot 'toolchain'
$EntryScripts = Join-Path $EntryControl 'scripts/ci'
foreach ($Path in @($EntryScripts, $EntryEngine, $EntryToolchain)) { $null = [IO.Directory]::CreateDirectory($Path) }
foreach ($ModuleName in @('Invoke-EngineRunnerGate.ps1', 'EngineRunnerHostLease.ps1', 'ManagedCompileRegistration.ps1', 'ManagedCompileWorkspace.ps1',
	'InitialPreparation.Core.ps1', 'RoutineCompileDeadline.ps1', 'RoutineCompileCommand.ps1')) {
	Copy-Item -LiteralPath (Join-Path (Split-Path $GatePath) $ModuleName) -Destination (Join-Path $EntryScripts $ModuleName)
}
Copy-Item -LiteralPath (Join-Path (Split-Path $GatePath) 'RoutineCompileResources.ps1') -Destination (Join-Path $EntryScripts 'RoutineCompileResources.Production.ps1')
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryScripts 'RoutineCompileResources.ps1') -Value @'
. (Join-Path $PSScriptRoot 'RoutineCompileResources.Production.ps1')
$script:FixtureResourceConstructor = (Get-Item Function:\New-RoutineCompileResourceMonitor).ScriptBlock
function New-RoutineCompileResourceMonitor {
 param($Roots)
 return (& $script:FixtureResourceConstructor -Roots $Roots -ResolveVolume {
  param($Root) return [pscustomobject]@{ volumeId = 'fixture-volume'; mount = $Root }
 } -ReadDisk {
  param($Volume) return [pscustomobject]@{ volumeId = $Volume.volumeId; availableBytes = 128GB }
 } -ReadMemory { return [pscustomobject]@{ availableRamBytes = 24GB; commitHeadroomBytes = 24GB } } -ReadPhysicalCores { return 4 })
}
'@
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryScripts 'InitialPreparation.BuildInvocation.ps1') -Value @'
param(
 [Parameter(Mandatory)][ValidateSet('AethelnOnlineClient','AethelnOnlineServer')][string] $Target,
 [Parameter(Mandatory)][ValidateSet('Win64','Linux')][string] $Platform,
 [Parameter(Mandatory)][ValidateRange(1,4)][int] $ActionLimit,
 [Parameter(Mandatory)][string] $EngineRoot,
 [Parameter(Mandatory)][string] $TargetRoot,
 [Parameter(Mandatory)][string] $LinuxToolchainRoot,
 [Parameter(Mandatory)][string] $EvidenceRoot
)
$ErrorActionPreference = 'Stop'
if (($Target -ceq 'AethelnOnlineClient') -ne ($Platform -ceq 'Win64')) { throw 'fixture_target_binding_wrong' }
foreach ($Root in @($EngineRoot,$TargetRoot,$LinuxToolchainRoot,$EvidenceRoot)) {
 if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'fixture_path_binding_wrong' }
}
$Receipt = [ordered]@{ schemaVersion=1; target=$Target; platform=$Platform; nativeExitCode=0; infrastructureFailure=$null }
[IO.File]::WriteAllText((Join-Path $EvidenceRoot 'native-result.json'),($Receipt | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $EvidenceRoot 'build.log'),("Target is up to date`nFixtureTarget=$Target Platform=$Platform ActionLimit=$ActionLimit"),(New-Object Text.UTF8Encoding($false)))
exit 0
'@
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryControl 'AethelnOnline.uproject') -Value '{}'
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryControl 'Source/input.cpp') -Value '// disposable input'
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryControl '.gitignore') -Value "Binaries/`nIntermediate/`nTestResults/`n"
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryEngine 'Engine/Build/BatchFiles/Build.bat') -Value "@echo off`r`nexit /b 87`r`n"
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('init', '--quiet')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('config', 'core.autocrlf', 'false')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('add', '.')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'managed-entry-fixture')
$EntryRevision = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('rev-parse', 'HEAD')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryRoot -Arguments @('clone', '--quiet', '--no-hardlinks', $EntryControl, $EntryTarget)
$null = Invoke-RoutineEntryFixtureGit -Root $EntryTarget -Arguments @('config', 'core.autocrlf', 'false')
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryControl 'Source/candidate.cpp') -Value '// initial disposable candidate'
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('add', '.')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'candidate-needs-sync')
$EntryRevision = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('rev-parse', 'HEAD')
$EntryCommon = Invoke-RoutineEntryFixtureGit -Root $EntryTarget -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
$RegistrationPath = Join-Path $EntryRoot 'registration.json'
$Registration = [ordered]@{ schemaVersion = 1; registrationId = ('a' * 32); repository = 'fixture/repository'; targetRoot = $EntryTarget; gitCommonDirectory = $EntryCommon; preparationReceiptSha256 = ('b' * 64) }
Set-RoutineEntryFixtureFile -Path $RegistrationPath -Value ($Registration | ConvertTo-Json -Compress)
$EntryGate = Join-Path $EntryScripts 'Invoke-EngineRunnerGate.ps1'
$AnchorUtc = [DateTime]::UtcNow.AddSeconds(-3).ToString('o')
$AnchorTimestamp = [Diagnostics.Stopwatch]::GetTimestamp() - 3L * [Diagnostics.Stopwatch]::Frequency
$EntryParameters = [ordered]@{
	Mode = 'Compile'; RepositoryRoot = $EntryControl; SourceRevision = $EntryRevision; ArchiveRoot = (Join-Path $EntryRoot 'archive'); LogRoot = (Join-Path $EntryRoot 'logs');
	Repository = 'fixture/repository'; RunnerName = 'fixture-runner'; ManagedWorkspaceRoot = $EntryTarget; ManagedWorkspaceRegistrationPath = $RegistrationPath;
	ManagedWorkspaceRegistrationSha256 = (Get-FileHash -LiteralPath $RegistrationPath -Algorithm SHA256).Hash.ToLowerInvariant();
	HostLeasePath = (Join-Path $EntryRoot 'host.lease'); CompileTimeoutMinutes = 30; CompileStartedUtc = $AnchorUtc; CompileStartedTimestamp = $AnchorTimestamp;
	ReportPath = (Join-Path $EntryRoot 'report.json')
}
$EntryResult = Invoke-RoutineEntryFixtureProcess -EntryGate $EntryGate -Parameters $EntryParameters -FixtureEngine $EntryEngine -FixtureToolchain $EntryToolchain
Assert-RoutineGateFixture -Condition ($EntryResult.exitCode -eq 0) -Message ('Actual managed entrypoint must pass: ' + $EntryResult.output)
$EntryReport = Get-Content -LiteralPath $EntryParameters.ReportPath -Raw | ConvertFrom-Json
Assert-RoutineGateFixture -Condition ($EntryReport.summary.requiredFailed -eq 0 -and $EntryReport.managedWorkspace.synchronized -eq $true -and $EntryReport.supervisor.cleanupVerified -eq $true -and $EntryReport.supervisor.childExitCode -eq 0) -Message 'Actual entrypoint publishes successful synchronization and owned cleanup proof.'
Assert-RoutineGateFixture -Condition ($EntryReport.startedUtc -ceq $AnchorUtc -and $EntryReport.compileResources.targetAdmissionCount -eq 2 -and $EntryReport.compileResources.minimumActionLimit -eq 4) -Message 'Actual child preserves pre-staging origin and admits both target caps.'
Assert-RoutineGateFixture -Condition ((Invoke-RoutineEntryFixtureGit -Root $EntryTarget -Arguments @('rev-parse', 'HEAD')) -ceq $EntryRevision -and (Test-Path -LiteralPath (Join-Path $EntryTarget 'Source/candidate.cpp'))) -Message 'Actual supervised operation synchronizes the exact new control revision.'
$EntryLeaseRows = @(Get-Content -LiteralPath $EntryParameters.HostLeasePath | ForEach-Object { $_ | ConvertFrom-Json })
Assert-RoutineGateFixture -Condition ($EntryLeaseRows[-1].state -ceq 'released' -and $EntryLeaseRows[-1].cleanupVerified -eq $true) -Message 'Successful actual supervisor releases its shared host lease with cleanup proof.'
$EntryBuilds = @(Get-ChildItem -LiteralPath (Join-Path $EntryRoot 'logs/compile') -Directory -Filter 'routine-*')
Assert-RoutineGateFixture -Condition ($EntryBuilds.Count -eq 2) -Message 'Actual named invocation produces exactly two target evidence directories.'
foreach ($Pair in @(@('AethelnOnlineClient', 'Win64'), @('AethelnOnlineServer', 'Linux'))) {
	$TargetMatches = @($EntryBuilds | Where-Object { $_.Name.StartsWith('routine-' + $Pair[0] + '-') })
	Assert-RoutineGateFixture -Condition ($TargetMatches.Count -eq 1) -Message ('One actual target invocation for ' + $Pair[0])
	$Native = Get-Content -LiteralPath (Join-Path $TargetMatches[0].FullName 'native-result.json') -Raw | ConvertFrom-Json
	$NativeLog = Get-Content -LiteralPath (Join-Path $TargetMatches[0].FullName 'build.log') -Raw
	Assert-RoutineGateFixture -Condition ($Native.target -ceq $Pair[0] -and $Native.platform -ceq $Pair[1] -and $Native.nativeExitCode -eq 0 -and $NativeLog.Contains('ActionLimit=4')) -Message 'Actual PowerShell wrapper receives correctly bound pinned target/cap arguments.'
}
# Advance only disposable control source. An already-expired original anchor
# must not import this commit or start either target in the retained fixture.
Set-RoutineEntryFixtureFile -Path (Join-Path $EntryControl 'Source/next.cpp') -Value '// new disposable candidate'
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('add', '.')
$null = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'expired-candidate')
$EntryParameters.SourceRevision = Invoke-RoutineEntryFixtureGit -Root $EntryControl -Arguments @('rev-parse', 'HEAD')
$EntryParameters.CompileStartedUtc = [DateTime]::UtcNow.AddMinutes(-31).ToString('o')
$EntryParameters.CompileStartedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp() - 1860L * [Diagnostics.Stopwatch]::Frequency
$EntryParameters.LogRoot = Join-Path $EntryRoot 'expired-logs'
$EntryParameters.ArchiveRoot = Join-Path $EntryRoot 'expired-archive'
$EntryParameters.HostLeasePath = Join-Path $EntryRoot 'expired-host.lease'
$EntryParameters.ReportPath = Join-Path $EntryRoot 'expired-report.json'
$ExpiredResult = Invoke-RoutineEntryFixtureProcess -EntryGate $EntryGate -Parameters $EntryParameters -FixtureEngine $EntryEngine -FixtureToolchain $EntryToolchain
Assert-RoutineGateFixture -Condition ($ExpiredResult.exitCode -ne 0) -Message 'Expired original anchor exits nonzero.'
$ExpiredReport = Get-Content -LiteralPath $EntryParameters.ReportPath -Raw | ConvertFrom-Json
Assert-RoutineGateFixture -Condition ($ExpiredReport.summary.requiredFailed -gt 0 -and @($ExpiredReport.checks | Where-Object { $_.message -ceq 'compile_timeout' }).Count -gt 0) -Message 'Expired original anchor publishes timeout failure.'
Assert-RoutineGateFixture -Condition ((Invoke-RoutineEntryFixtureGit -Root $EntryTarget -Arguments @('rev-parse', 'HEAD')) -ceq $EntryRevision -and -not (Test-Path -LiteralPath (Join-Path $EntryTarget 'Source/next.cpp'))) -Message 'Expired anchor performs no Git synchronization.'
Assert-RoutineGateFixture -Condition (-not (Test-Path -LiteralPath $EntryParameters.HostLeasePath) -and -not (Test-Path -LiteralPath $EntryParameters.LogRoot)) -Message 'Expired anchor acquires no host lease and starts no build.'
Write-Output 'PASS actual managed entrypoint and expired original deadline'
# Issue #243: a deadline that is not yet expired but leaves under the fixed
# 5-minute minimum after the lease must not start the checkout, and still
# releases the lease it took.
$EntryParameters.CompileTimeoutMinutes = 4
$EntryParameters.CompileStartedUtc = [DateTime]::UtcNow.ToString('o')
$EntryParameters.CompileStartedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
$EntryParameters.LogRoot = Join-Path $EntryRoot 'short-logs'
$EntryParameters.ArchiveRoot = Join-Path $EntryRoot 'short-archive'
$EntryParameters.HostLeasePath = Join-Path $EntryRoot 'short-host.lease'
$EntryParameters.ReportPath = Join-Path $EntryRoot 'short-report.json'
$ShortResult = Invoke-RoutineEntryFixtureProcess -EntryGate $EntryGate -Parameters $EntryParameters -FixtureEngine $EntryEngine -FixtureToolchain $EntryToolchain
Assert-RoutineGateFixture -Condition ($ShortResult.exitCode -ne 0) -Message 'Under the minimum after the lease exits nonzero.'
$ShortReport = Get-Content -LiteralPath $EntryParameters.ReportPath -Raw | ConvertFrom-Json
Assert-RoutineGateFixture -Condition ($ShortReport.summary.requiredFailed -gt 0 -and @($ShortReport.checks | Where-Object { $_.message -ceq 'managed_workspace_time_insufficient' }).Count -gt 0) -Message 'Under the minimum publishes the distinct insufficient-time failure.'
Assert-RoutineGateFixture -Condition ((Invoke-RoutineEntryFixtureGit -Root $EntryTarget -Arguments @('rev-parse', 'HEAD')) -ceq $EntryRevision -and -not (Test-Path -LiteralPath (Join-Path $EntryTarget 'Source/next.cpp'))) -Message 'Under the minimum starts no Git synchronization.'
$ShortLeaseRows = @(Get-Content -LiteralPath $EntryParameters.HostLeasePath | ForEach-Object { $_ | ConvertFrom-Json })
Assert-RoutineGateFixture -Condition ($ShortLeaseRows[-1].state -ceq 'released' -and $ShortLeaseRows[-1].cleanupVerified -eq $true -and @(Get-ChildItem -LiteralPath (Join-Path $EntryParameters.LogRoot 'compile') -Directory -Filter 'routine-*').Count -eq 0) -Message 'Under the minimum releases the lease with cleanup proof and starts no build.'
Write-Output 'PASS actual managed entrypoint refuses a checkout under the minimum remaining time'
Write-Output ('Fixtures retained: ' + $FixtureRoot)
if ($script:RoutineFailures.Count -gt 0) { throw ($script:RoutineFailures.Count.ToString() + ' routine gate integration cases failed.') }
Write-Output ('PASS ' + $script:RoutineAssertions + ' routine gate integration assertions.')
