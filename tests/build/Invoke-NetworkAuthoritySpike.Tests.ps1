[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Invoke-NetworkAuthoritySpike.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnAuthoritySpikeTests-{0}" -f [guid]::NewGuid().ToString('N'))
$FixtureSucceeded = $false

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$RunnerSource = Get-Content -LiteralPath $Script -Raw
	Assert-True ($RunnerSource -match 'ProcessStartInfo') 'The runner must launch runtime children through ProcessStartInfo.'
	Assert-True ($RunnerSource -match 'UseShellExecute\s*=\s*\$false') 'Runtime child launches must disable shell execution.'
	Assert-True ($RunnerSource -match 'CreateNoWindow\s*=\s*\$true') 'Runtime child launches must not create windows.'
	Assert-True ($RunnerSource -notmatch '\bStart-Process\b') 'The runner must not launch runtime children through Start-Process.'
	Assert-True ($RunnerSource -match 'ServerLauncherExecutable') 'The runner must support an explicit Linux-server launcher executable.'
	Assert-True ($RunnerSource -match 'ServerLauncherArguments') 'The runner must support explicit Linux-server launcher arguments.'
	Assert-True ($RunnerSource -match 'ServerIdentityArguments') 'The runner must authenticate the exact launcher-side server executable.'
	Assert-True ($RunnerSource -match 'ServerCleanupArguments') 'The runner must own launcher-side descendant cleanup.'
	Assert-True ($RunnerSource -match 'ServerProcessIdPattern') 'The runner must capture a launcher-side descendant process identity.'
	Assert-True ($RunnerSource -match 'RequiredRejectionCategories') 'The runner must fail closed unless every required invalid-claim category is observed.'
	Assert-True ($RunnerSource -match 'NetworkProfileCatalogPath') 'The runner must accept one versioned caller-supplied network-profile catalog.'
	Assert-True ($RunnerSource -match 'ScenarioContractPath') 'The runner must accept one versioned ordered scenario contract.'
	Assert-True ($RunnerSource -match 'DeathPattern') 'The scenario contract must bind authoritative death evidence.'
	Assert-True ($RunnerSource -match 'RespawnPattern') 'The scenario contract must bind authoritative respawn evidence.'
	Assert-True ($RunnerSource -match 'ShutdownPattern') 'The scenario contract must bind controlled-shutdown evidence.'
	Assert-True ($RunnerSource -match 'failure_details') 'Machine-readable results must expose normalized role and stage failure identity.'
	Assert-True ($RunnerSource -match 'process_outcomes') 'Machine-readable schema-v2 results must expose bounded process outcomes.'

	$RunnerTokens = $null
	$RunnerParseErrors = $null
	$RunnerAst = [System.Management.Automation.Language.Parser]::ParseInput($RunnerSource, [ref] $RunnerTokens, [ref] $RunnerParseErrors)
	Assert-True ($RunnerParseErrors.Count -eq 0) 'The network-authority runner must parse without PowerShell syntax errors.'
	$ObservationFunctionAst = $RunnerAst.Find({
		param($Ast)
		$Ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Ast.Name -eq 'Wait-ForObservationInterval'
	}, $true)
	Assert-True ($null -ne $ObservationFunctionAst) 'The runner must define Wait-ForObservationInterval.'

	$BoundaryFailure = & {
		param([string] $FunctionSource)

		function Get-RuntimeError([string[]] $Paths) { return $null }
		# Dot-sourced so the extracted runner function lands in this isolated
		# scriptblock scope exactly as Invoke-Expression placed it.
		. ([scriptblock]::Create($FunctionSource))

		$Clock = [pscustomobject]@{ UtcNow = [DateTime]::Parse('2026-08-12T00:00:00Z').ToUniversalTime() }
		$ProcessState = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
		$ProcessState | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
		$ProcessState | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
		$RequiredProcess = [pscustomobject]@{
			Name = 'boundary-runtime'
			Process = $ProcessState
			StandardOutputPath = 'boundary.stdout.log'
			StandardErrorPath = 'boundary.stderr.log'
		}
		$BoundaryState = [pscustomobject]@{ SleepCount = 0 }
		$UtcNow = { $Clock.UtcNow }.GetNewClosure()
		$Sleep = {
			param([int] $Milliseconds)
			$BoundaryState.SleepCount++
			$Clock.UtcNow = $Clock.UtcNow.AddMilliseconds($Milliseconds)
			if ($Clock.UtcNow -ge [DateTime]::Parse('2026-08-12T00:00:01Z').ToUniversalTime()) {
				$ProcessState.HasExited = $true
			}
		}.GetNewClosure()

		try {
			Wait-ForObservationInterval @($RequiredProcess) 1 -UtcNow $UtcNow -Sleep $Sleep
			return [pscustomobject]@{ Message = $null; SleepCount = $BoundaryState.SleepCount }
		}
		catch {
			return [pscustomobject]@{ Message = $_.Exception.Message; SleepCount = $BoundaryState.SleepCount }
		}
	} $ObservationFunctionAst.Extent.Text
	Assert-True ($BoundaryFailure.SleepCount -eq 10) 'The deterministic boundary fixture must reach the final 100 ms polling sleep.'
	Assert-True ($BoundaryFailure.Message -match "Required process 'boundary-runtime' exited unexpectedly with code 0 during the 1-second observation interval") 'A required process that exits during the final polling sleep must be rejected by the post-sleep health check.'
	Write-Output 'PASS: final polling-sleep exits are rejected by a deterministic post-sleep health check'

	# A declined hidden launch must decide before it allocates anything: no
	# command-line preparation, no redirected capture files, no child process,
	# and no fabricated handle for the caller to treat as running.
	$LaunchFunctionAst = $RunnerAst.Find({
		param($Ast)
		$Ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Ast.Name -eq 'Start-HiddenProcess'
	}, $true)
	Assert-True ($null -ne $LaunchFunctionAst) 'The runner must define Start-HiddenProcess.'
	$DeclinedStandardOutput = Join-Path $FixtureRoot 'declined-launch.stdout.log'
	$DeclinedStandardError = Join-Path $FixtureRoot 'declined-launch.stderr.log'
	$DeclinedLaunch = & {
		param([string] $FunctionSource, [string] $StandardOutputPath, [string] $StandardErrorPath)

		function ConvertTo-ProcessArgument([string] $Argument) { throw 'A declined hidden launch must not prepare a child command line.' }
		. ([scriptblock]::Create($FunctionSource))
		return Start-HiddenProcess -Executable (Join-Path $StandardOutputPath 'never-launched.exe') -Arguments @('-run') -StandardOutputPath $StandardOutputPath -StandardErrorPath $StandardErrorPath -WhatIf
	} $LaunchFunctionAst.Extent.Text $DeclinedStandardOutput $DeclinedStandardError
	Assert-True ($null -eq $DeclinedLaunch) 'A declined hidden launch must return no handle.'
	Assert-True (-not (Test-Path -LiteralPath $DeclinedStandardOutput)) 'A declined hidden launch must create no redirected standard-output capture.'
	Assert-True (-not (Test-Path -LiteralPath $DeclinedStandardError)) 'A declined hidden launch must create no redirected standard-error capture.'
	Write-Output 'PASS: a declined hidden launch starts no process and allocates no capture'

	$CaptureDisposeIndex = $RunnerSource.LastIndexOf('$Handle.Capture.Dispose()', [System.StringComparison]::Ordinal)
	$FinalInventoryIndex = $RunnerSource.LastIndexOf('Assert-ExactRejectionInventory -Lines @($FinalServerLines + $FinalServerErrorLines)', [System.StringComparison]::Ordinal)
	$SuccessfulResultIndex = $RunnerSource.LastIndexOf("`$Result = if (`$EvidenceMode -ceq 'packaged')", [System.StringComparison]::Ordinal)
	$EvidenceWriteIndex = $RunnerSource.LastIndexOf('$Evidence | ConvertTo-Json', [System.StringComparison]::Ordinal)
	Assert-True ($CaptureDisposeIndex -ge 0) 'The runner must close and drain process captures.'
	Assert-True ($FinalInventoryIndex -gt $CaptureDisposeIndex) 'The final rejection inventory must be validated only after every process capture is closed and drained.'
	Assert-True ($SuccessfulResultIndex -gt $FinalInventoryIndex) 'A successful result must be assigned only after final rejection-inventory validation.'
	Assert-True ($EvidenceWriteIndex -gt $SuccessfulResultIndex) 'Evidence must be written only after final rejection-inventory validation and result assignment.'
	Write-Output 'PASS: cleanup-boundary rejection validation runs after capture drain and before success publication'

	$PowerShellExecutable = (Get-Process -Id $PID).Path
	$FakeRuntime = Join-Path $FixtureRoot 'fake-runtime.ps1'
	Set-Content -LiteralPath $FakeRuntime -Encoding UTF8 -Value @'
param(
	[string] $Role,
	[string] $ClientId,
	[string] $Endpoint,
	[string] $Map,
	[string] $ScenarioId,
	[string] $ProfileId,
	[string] $RunId,
	[string] $NetworkConfigIdentity,
	[string] $Environment,
	[string] $Behavior = 'normal',
	[string] $RejectionReason = 'duplicate-sequence',
	[string] $ExitAfterMarkers = 'false',
	[string] $ControlledExitSignalPath = 'none',
	[int] $StartupDelaySeconds = 0,
	[string] $ObservationExitSignalPath = 'none',
	[Parameter(ValueFromRemainingArguments)] [string[]] $Remaining
)
if ($Role -eq 'server') {
	Start-Sleep -Seconds $StartupDelaySeconds
	if ($Behavior -eq 'literal-profile-token') {
		if (@($Remaining | Where-Object { $_ -ceq '{RunId}' }).Count -ne 1) { throw 'Opaque profile argument was not delivered literally to the server.' }
		Write-Output 'FIXTURE_OPAQUE_ARGUMENT value={RunId}'
	}
	$Identity = "scenario=$ScenarioId profile=$ProfileId run=$RunId"
	$AdversarialSuffix = if ($Behavior -in @('adversarial-public-lines','path-bearing-runtime-error')) { " opaque=$($Remaining[0]) executable=$((Get-Process -Id $PID).Path)" } else { '' }
	Write-Output "AUTHORITY server_ready endpoint=$Endpoint map=$Map network_config=$NetworkConfigIdentity $Identity$AdversarialSuffix"
	Write-Output "AUTHORITY network_config network_config=$NetworkConfigIdentity $Identity"
	if ($Behavior -eq 'path-bearing-runtime-error') {
		[Console]::Error.WriteLine("fatal error runtime path $($Remaining[0]) executable=$((Get-Process -Id $PID).Path)")
	}
	Write-Output "AUTHORITY enemy_spawned enemy=spike-enemy-1 $Identity"
	Write-Output "AUTHORITY connection client=client-1 connection=connection-1 $Identity"
	Write-Output "AUTHORITY connection client=client-2 connection=connection-2 $Identity"
	Write-Output "AUTHORITY movement client=client-1 $Identity"
	Write-Output "AUTHORITY movement client=client-2 $Identity"
	$PlaySequence = if ($Behavior -eq 'join-play-sequence-reordered') { 10 } elseif ($Behavior -eq 'invalid-play-sequence') { 0 } else { 20 }
	if ($Behavior -eq 'reordered') { Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 sequence=$PlaySequence $Identity" }
	Write-Output "AUTHORITY melee_resolved attacker=client-1 enemy=spike-enemy-1 $Identity"
	if ($Behavior -ne 'missing-damage' -and $Behavior -ne 'reordered') {
		$DamageIdentity = if ($Behavior -eq 'mismatched-run') { "scenario=$ScenarioId profile=$ProfileId run=another-run" } else { $Identity }
		Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 sequence=$PlaySequence $DamageIdentity$AdversarialSuffix"
		if ($Behavior -eq 'duplicate-damage') { Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 sequence=$PlaySequence $DamageIdentity" }
	}
	$StructuredSequence = 1
	foreach ($Category in @('movement','aim','activation','hit','cooldown','dodge','block','resource','death','respawn')) {
		$Reason = if ($Category -eq 'aim') { 'impossible-aim-transition' } elseif ($Category -in @('activation','cooldown','dodge','block')) { 'activation-blocked' } else { 'malformed-intent' }
		if ($Category -eq 'movement') { $Reason = $RejectionReason }
		Write-Output "AUTHORITY rejection category=$Category reason=$Reason client=client-2 $Identity"
		$StructuredSubject = if ($Category -eq 'activation') { 'ability' } else { $Category }
		$StructuredReason = if ($Reason -eq 'malformed-intent') { 'malformed-request' } else { $Reason }
		Write-Output "LogAethelnObservability: event schema=`"aetheln.observability-event`" version=1 category=`"rejection`" subject=`"$StructuredSubject`" reason=`"$StructuredReason`" flow=`"prototype-authority`" run=`"$RunId`" connection=`"connection-2`" instance=`"network-authority-server`" activation=`"activation-$StructuredSequence`" ability=`"Ability.Melee.Combo1`" sequence=$StructuredSequence source_revision=`"fixture-revision`" build=`"fixture-build`" configuration=`"Development`" engine=`"5.8.1-fixture`" toolchain=`"UE-5.8.1-fixture`" network_profile=`"$ProfileId`"$AdversarialSuffix"
		++$StructuredSequence
	}
	Write-Output "LogAethelnObservability: metric name=`"rejection-count`" category=`"movement`" reason=`"malformed-request`" environment=`"$Environment`" value=1"
	$DeathIdentity = if ($Behavior -eq 'stale-profile-death') { "scenario=$ScenarioId profile=network-profile.stale run=$RunId" } else { $Identity }
	if ($Behavior -eq 'reordered-scenario') {
		Write-Output "AUTHORITY respawn client=client-2 $Identity"
	}
	if ($Behavior -ne 'missing-death' -and $Behavior -ne 'reordered-scenario') {
		$DeathClient = if ($Behavior -eq 'wrong-client-death') { 'client-1' } else { 'client-2' }
		Write-Output "AUTHORITY death client=$DeathClient $DeathIdentity$AdversarialSuffix"
		if ($Behavior -eq 'duplicate-death') { Write-Output "AUTHORITY death client=$DeathClient $DeathIdentity" }
	}
	if ($Behavior -ne 'missing-respawn' -and $Behavior -ne 'reordered-scenario') {
		Write-Output "AUTHORITY respawn client=client-2 $Identity$AdversarialSuffix"
		if ($Behavior -eq 'duplicate-respawn') { Write-Output "AUTHORITY respawn client=client-2 $Identity" }
	}
	$ReconnectConnection = if ($Behavior -eq 'reused-connection') { 'connection-1' } else { 'connection-3' }
	if ($Behavior -eq 'reordered-lifecycle') {
		Write-Output "AUTHORITY connection client=client-1-reconnect connection=$ReconnectConnection $Identity"
		Write-Output "AUTHORITY reconnected client=client-1-reconnect connection=$ReconnectConnection $Identity"
	}
	if ($Behavior -ne 'missing-disconnect') {
		Write-Output "AUTHORITY disconnected client=client-1 connection=connection-1 $Identity$AdversarialSuffix"
	}
	if ($Behavior -eq 'fabricated-disconnected-command') {
		Write-Output "AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity"
	}
	if ($Behavior -eq 'fabricated-disconnected-command-stderr') {
		[Console]::Error.WriteLine("AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity")
	}
	if ($Behavior -eq 'unexpected-rejection-category') {
		Write-Output "AUTHORITY rejection category=unexpected reason=malformed-intent client=client-2 $Identity"
		Write-Output "LogAethelnObservability: event schema=`"aetheln.observability-event`" version=1 category=`"rejection`" subject=`"unexpected`" reason=`"malformed-request`" flow=`"prototype-authority`" run=`"$RunId`" connection=`"connection-2`" instance=`"network-authority-server`" activation=`"`" ability=`"Ability.Melee.Combo1`" sequence=99 source_revision=`"fixture-revision`" build=`"fixture-build`" configuration=`"Development`" engine=`"5.8.1-fixture`" toolchain=`"UE-5.8.1-fixture`" network_profile=`"$ProfileId`""
	}
	if ($Behavior -ne 'missing-reconnect' -and $Behavior -ne 'reordered-lifecycle') {
		Write-Output "AUTHORITY connection client=client-1-reconnect connection=$ReconnectConnection $Identity"
		Write-Output "AUTHORITY reconnected client=client-1-reconnect connection=$ReconnectConnection $Identity$AdversarialSuffix"
	}
	if ($Behavior -ne 'missing-shutdown') {
		$ShutdownIdentity = if ($Behavior -eq 'stale-profile-shutdown') { "scenario=$ScenarioId profile=network-profile.stale run=$RunId" } else { $Identity }
		Write-Output "AUTHORITY shutdown_complete role=server $ShutdownIdentity$AdversarialSuffix"
		if ($Behavior -eq 'duplicate-shutdown') { Write-Output "AUTHORITY shutdown_complete role=server $ShutdownIdentity" }
	}
	if ($Behavior -eq 'delayed-fabricated-disconnected-command') {
		Start-Sleep -Milliseconds 750
		Write-Output "AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity"
	}
	if ($ExitAfterMarkers -eq 'true') {
		if ($ObservationExitSignalPath -eq 'none') { throw 'The early-exit fixture requires an observation-entry signal.' }
		while (-not (Test-Path -LiteralPath $ObservationExitSignalPath -PathType Leaf)) { Start-Sleep -Milliseconds 50 }
		exit 0
	}
	if ($ControlledExitSignalPath -ne 'none') {
		while (-not (Test-Path -LiteralPath $ControlledExitSignalPath -PathType Leaf)) { Start-Sleep -Milliseconds 50 }
		exit 0
	}
	while ($true) { Start-Sleep -Milliseconds 50 }
}
if ($Behavior -eq 'slow-client-start') { Start-Sleep -Seconds 3 }
if ($Behavior -eq 'literal-profile-token') {
	if (@($Remaining | Where-Object { $_ -ceq '{RunId}' }).Count -ne 1) { throw "Opaque profile argument was not delivered literally to '$ClientId'." }
	Write-Output 'FIXTURE_OPAQUE_ARGUMENT value={RunId}'
}
if (($Behavior -eq 'client-1-failure' -and $ClientId -eq 'client-1') -or
	($Behavior -eq 'client-2-failure' -and $ClientId -eq 'client-2') -or
	($Behavior -eq 'reconnect-client-failure' -and $ClientId -eq 'client-1-reconnect')) {
	exit 31
}
$AdversarialSuffix = if ($Behavior -in @('adversarial-public-lines','path-bearing-runtime-error')) { " opaque=$($Remaining[0]) executable=$((Get-Process -Id $PID).Path)" } else { '' }
Write-Output "AUTHORITY client_ready client=$ClientId endpoint=$Endpoint map=$Map scenario=$ScenarioId profile=$ProfileId run=$RunId$AdversarialSuffix"
if ($ClientId -eq 'client-2') {
	$JoinSequence = if ($Behavior -eq 'invalid-join-sequence') { 0 } else { 10 }
	Write-Output "AUTHORITY join_in_progress client=client-2 enemy=spike-enemy-1 sequence=$JoinSequence scenario=$ScenarioId profile=$ProfileId run=$RunId$AdversarialSuffix"
}
Start-Sleep -Seconds 30
'@
	$FakeLauncher = Join-Path $FixtureRoot 'fake-launcher.ps1'
Set-Content -LiteralPath $FakeLauncher -Encoding UTF8 -Value @'
param([string] $Mode, [string] $Target, [string] $StatePath, [Parameter(ValueFromRemainingArguments)] [string[]] $Remaining)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'identity') {
	Write-Output ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $Target)
	exit 0
}
if ($Mode -eq 'cleanup') {
	$TargetProcess = $null
	try {
		$IdentityText = Get-Content -LiteralPath $StatePath -Raw
		$Identity = $IdentityText | ConvertFrom-Json
		if ($Identity.pid -ne [int] $Target -or $Identity.start_ticks -le 0) { throw 'Fixture process identity mismatch.' }
		$ExitReceiptPath = "$StatePath.exited"
		if (Test-Path -LiteralPath $ExitReceiptPath) {
			if ((Get-Content -LiteralPath $ExitReceiptPath -Raw) -cne $IdentityText) { throw 'Fixture exit receipt identity mismatch.' }
		} else {
			$TargetProcess = Get-Process -Id ([int] $Target) -ErrorAction Stop
			# Retain the handle before reading identity or terminating: a later PID
			# lookup can refer to a different process and cannot prove an owned leak.
			$null = $TargetProcess.Handle
			if ($TargetProcess.Id -ne $Identity.pid -or $TargetProcess.StartTime.ToUniversalTime().Ticks -ne $Identity.start_ticks) { throw 'Fixture live process identity mismatch.' }
			if (-not $TargetProcess.HasExited) {
				try { $TargetProcess.Kill() } catch { if (-not $TargetProcess.HasExited) { throw } }
			}
			if (-not $TargetProcess.WaitForExit(2000) -or -not $TargetProcess.HasExited) { throw 'Fixture owned process did not exit.' }
		}
	} catch {
		[Console]::Error.WriteLine($_.Exception.Message)
		exit 43
	} finally {
		if ($null -ne $TargetProcess) { $TargetProcess.Dispose() }
	}
	if ($env:AETHELN_TEST_CLEANUP_FAIL -eq 'true') { exit 42 }
	Write-Output "AETHELN_SERVER_DESCENDANT_EXITED=$Target"
	exit 0
}
if ($Mode -ne 'launch') { throw "Unsupported launcher mode '$Mode'." }
if ($env:AETHELN_TEST_LAUNCHER_FAIL -eq 'true') { exit 41 }
$Child = Start-Process -FilePath $Target -ArgumentList $Remaining -PassThru -NoNewWindow
$null = $Child.Handle
$IdentityText = [ordered]@{ pid = $Child.Id; start_ticks = $Child.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($StatePath, $IdentityText)
Write-Output "AETHELN_SERVER_DESCENDANT_PID=$($Child.Id)"
$Child.WaitForExit()
[System.IO.File]::WriteAllText("$StatePath.exited", $IdentityText)
exit $Child.ExitCode
'@

	# Exercise cleanup against real owned processes while deterministically making
	# a second PID lookup observe a different process after the first has exited.
	$CleanupProbe = Join-Path $FixtureRoot 'cleanup-probe.ps1'
	Set-Content -LiteralPath $CleanupProbe -Encoding UTF8 -Value @'
param([string] $Launcher, [int] $TargetId, [int] $SentinelId, [string] $StatePath, [string] $Behavior = 'second-lookup')
$script:LookupCount = 0
function Get-Process {
	param([int] $Id, [string] $ErrorAction)
	$script:LookupCount++
	if ($Behavior -eq 'first-unrelated' -or $script:LookupCount -gt 1) { return Microsoft.PowerShell.Management\Get-Process -Id $SentinelId }
	if ($Behavior -eq 'first-reused') {
		$Actual = Microsoft.PowerShell.Management\Get-Process -Id $SentinelId
		$Original = Microsoft.PowerShell.Management\Get-Process -Id $Id
		$Reused = [pscustomobject]@{ Id = $Id; StartTime = $Original.StartTime.AddTicks(1); Handle = $Actual.Handle; HasExited = $false; Actual = $Actual }
		$Reused | Add-Member ScriptMethod Kill { $this.Actual.Kill() }
		$Reused | Add-Member ScriptMethod Dispose { $this.Actual.Dispose() }
		return $Reused
	}
	if ($Behavior -eq 'termination-refused') {
		$Actual = Microsoft.PowerShell.Management\Get-Process -Id $Id
		$Refused = [pscustomobject]@{ Id = $Actual.Id; StartTime = $Actual.StartTime; Handle = $Actual.Handle; HasExited = $false }
		$Refused | Add-Member ScriptMethod Kill { }
		$Refused | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $false }
		$Refused | Add-Member ScriptMethod Dispose { }
		return $Refused
	}
	return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
}
& $Launcher cleanup $TargetId $StatePath
exit $LASTEXITCODE
'@
	function Invoke-CleanupProbe([string[]] $ProbeArguments, [string] $Name) {
		$StartInfo = New-Object System.Diagnostics.ProcessStartInfo
		$StartInfo.FileName = $PowerShellExecutable
		$StartInfo.Arguments = (@('-NoProfile', '-File') + $ProbeArguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
		$StartInfo.UseShellExecute = $false
		$StartInfo.CreateNoWindow = $true
		$StartInfo.RedirectStandardOutput = $true
		$StartInfo.RedirectStandardError = $true
		$Probe = [System.Diagnostics.Process]::Start($StartInfo)
		try {
			$OutputRead = $Probe.StandardOutput.ReadToEndAsync()
			$ErrorRead = $Probe.StandardError.ReadToEndAsync()
			if (-not $Probe.WaitForExit(8000)) { throw 'Fixture cleanup probe timed out.' }
			$OutputText = $OutputRead.GetAwaiter().GetResult()
			$ErrorText = $ErrorRead.GetAwaiter().GetResult()
			[System.IO.File]::WriteAllText((Join-Path $FixtureRoot "$Name.stdout.log"), $OutputText)
			[System.IO.File]::WriteAllText((Join-Path $FixtureRoot "$Name.stderr.log"), $ErrorText)
			return [pscustomobject]@{ ExitCode = $Probe.ExitCode; Output = $OutputText; Error = $ErrorText }
		} finally {
			if (-not $Probe.HasExited) { $Probe.Kill(); $Probe.WaitForExit() }
			$Probe.Dispose()
		}
	}
	$CleanupTarget = $null
	$CleanupSentinel = $null
	try {
		$CleanupTarget = Start-Process -FilePath $PowerShellExecutable -ArgumentList @('-NoProfile', '-Command', 'while ($true) { Start-Sleep -Seconds 1 }') -PassThru -WindowStyle Hidden
		$CleanupSentinel = Start-Process -FilePath $PowerShellExecutable -ArgumentList @('-NoProfile', '-Command', 'while ($true) { Start-Sleep -Seconds 1 }') -PassThru -WindowStyle Hidden
		# Retain the exact original process handle through cleanup and its assertions.
		$null = $CleanupTarget.Handle
		$CleanupStatePath = Join-Path $FixtureRoot 'cleanup-probe-identity.json'
		$CleanupIdentityText = [ordered]@{ pid = $CleanupTarget.Id; start_ticks = $CleanupTarget.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json -Compress
		[System.IO.File]::WriteAllText($CleanupStatePath, $CleanupIdentityText)
		foreach ($ProbeBehavior in @('first-unrelated', 'first-reused', 'termination-refused')) {
			$ProbeResult = Invoke-CleanupProbe @($CleanupProbe, $FakeLauncher, $CleanupTarget.Id, $CleanupSentinel.Id, $CleanupStatePath, $ProbeBehavior) $ProbeBehavior
			Assert-True ($ProbeResult.ExitCode -eq 43) "Cleanup must report $ProbeBehavior as failure. Actual: $($ProbeResult.ExitCode) $($ProbeResult.Error)"
			Assert-True (-not $CleanupTarget.HasExited -and -not $CleanupSentinel.HasExited) 'Rejected cleanup must not terminate the target or unrelated process.'
		}
		$ProbeResult = Invoke-CleanupProbe @($CleanupProbe, $FakeLauncher, $CleanupTarget.Id, $CleanupSentinel.Id, $CleanupStatePath) 'second-lookup'
		$CleanupOutput = $ProbeResult.Output
		$CleanupExitCode = $ProbeResult.ExitCode
		Write-Output "Cleanup identity probe: exit=$CleanupExitCode target_exited=$($CleanupTarget.HasExited) sentinel_exited=$($CleanupSentinel.HasExited) output=$CleanupOutput"
		Assert-True $CleanupTarget.HasExited 'Launcher cleanup must actually terminate the owned process.'
		Assert-True (-not $CleanupSentinel.HasExited) 'Launcher cleanup must preserve an unrelated process observed through a reused PID.'
		Assert-True ($CleanupExitCode -eq 0) 'A later PID lookup must not turn confirmed owned-process termination into cleanup failure.'
		$MissingStatePath = Join-Path $FixtureRoot 'missing-cleanup-identity.json'
		$ProbeResult = Invoke-CleanupProbe @($FakeLauncher, 'cleanup', $CleanupTarget.Id, $MissingStatePath) 'missing-identity'
		Assert-True ($ProbeResult.ExitCode -eq 43) 'Missing launch identity cannot establish cleanup success.'
		$ProbeResult = Invoke-CleanupProbe @($FakeLauncher, 'cleanup', $CleanupTarget.Id, $CleanupStatePath) 'missing-exit-receipt'
		Assert-True ($ProbeResult.ExitCode -eq 43) 'An absent PID without a launcher exit receipt cannot establish cleanup success.'
		[System.IO.File]::WriteAllText("$CleanupStatePath.exited", $CleanupIdentityText)
		$ProbeResult = Invoke-CleanupProbe @($CleanupProbe, $FakeLauncher, $CleanupTarget.Id, $CleanupSentinel.Id, $CleanupStatePath, 'first-unrelated') 'already-exited'
		Assert-True ($ProbeResult.ExitCode -eq 0 -and -not $CleanupSentinel.HasExited) 'An identity-matched exit receipt must accept an already-exited target without touching a reused PID.'
		$MismatchStatePath = Join-Path $FixtureRoot 'mismatched-cleanup-identity.json'
		[System.IO.File]::WriteAllText($MismatchStatePath, $CleanupIdentityText)
		[System.IO.File]::WriteAllText("$MismatchStatePath.exited", '{"pid":1,"start_ticks":1}')
		$ProbeResult = Invoke-CleanupProbe @($FakeLauncher, 'cleanup', $CleanupTarget.Id, $MismatchStatePath) 'mismatched-exit-receipt'
		Assert-True ($ProbeResult.ExitCode -eq 43) 'Mismatched exit receipts must fail cleanup.'
	}
	finally {
		foreach ($ProbeProcess in @($CleanupTarget, $CleanupSentinel)) {
			if ($null -ne $ProbeProcess) {
				if (-not $ProbeProcess.HasExited) { $ProbeProcess.Kill(); $ProbeProcess.WaitForExit() }
				$ProbeProcess.Dispose()
			}
		}
	}
	Write-Output 'PASS: launcher cleanup confirms owned-process exit without interpreting a later PID occupant as a leak'

	function Invoke-FixtureRun(
		[string] $FixtureLogRoot,
		[string] $FixtureRunId,
		[string] $RejectionReason,
		[int] $DurationSeconds = 5,
		[bool] $ExitAfterMarkers = $false,
		[bool] $UseLauncher = $false,
		[string] $Behavior = 'normal',
		[int] $TimeoutSeconds = 8,
		[string] $EvidenceMode = 'fixture',
		[string] $PackagedBuildProvenancePath,
		[string] $ServerProvenanceExecutable,
		[string] $FixtureEnvironment,
		[bool] $UseContracts = $false,
		[string] $ProfileCatalogOverridePath,
		[string] $ScenarioContractOverridePath,
		[string] $ServerExecutableOverride,
		[string[]] $ServerArgumentsOverride,
		[string[]] $ClientArgumentsOverride,
		[string] $JoinInProgressPatternOverride,
		[string] $DamagePatternOverride,
		[int] $ObservationStartDelaySeconds = 0,
		[bool] $WithholdShutdownRelease = $false,
		[int] $ServerStartupDelaySeconds = 0,
		[string] $BoundaryTimeoutDescription
	) {
		$ControlledExitSignalPath = if ($UseContracts -and -not $ExitAfterMarkers -and $Behavior -in @('normal','literal-profile-token','adversarial-public-lines','duplicate-death','duplicate-respawn','duplicate-shutdown')) { Join-Path $FixtureRoot ("shutdown-release-$FixtureRunId") } else { 'none' }
		$ObservationExitSignalPath = if ($ExitAfterMarkers) { Join-Path $FixtureRoot ("observation-exit-$FixtureRunId") } else { 'none' }
		$Arguments = @{
			ServerExecutable = $PowerShellExecutable
			ServerArguments = @('-NoProfile', '-File', $FakeRuntime, 'server', 'server', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}', '{NetworkConfigIdentity}', '{Environment}', $Behavior, $RejectionReason, $ExitAfterMarkers.ToString().ToLowerInvariant(), $ControlledExitSignalPath, $ServerStartupDelaySeconds, $ObservationExitSignalPath)
			ClientExecutable = $PowerShellExecutable
			ClientArguments = @('-NoProfile', '-File', $FakeRuntime, 'client', '{ClientId}', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}', '{NetworkConfigIdentity}', '{Environment}', $Behavior)
			ServerEndpoint = '127.0.0.1:7777'
			ServerMap = '/Game/Maps/StarterMap'
			ScenarioId = 'network-authority.baseline.v1'
			ProfileId = 'network-profile.unset'
			NetworkConfigIdentity = 'network-emulation.caller-supplied'
			RunId = $FixtureRunId
			Environment = if ($FixtureEnvironment) { $FixtureEnvironment } elseif ($EvidenceMode -ceq 'packaged') { 'development' } else { 'local' }
			SourceRevision = 'fixture-revision'
			BuildIdentity = 'fixture-build'
			ToolchainIdentity = 'UE-5.8.1-fixture'
			HardwareIdentity = 'fixture-host'
			TopologyIdentity = 'one-server-two-clients-local-fixture'
			ActorMixIdentity = 'network-authority.actor-mix.v1'
			EvidenceMode = $EvidenceMode
			DurationSeconds = $DurationSeconds
			LogRoot = $FixtureLogRoot
			ServerReadyPattern = 'AUTHORITY server_ready.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ServerConnectionPattern = 'AUTHORITY connection client=(?<ClientId>[^ ]+) connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ClientReadyPattern = 'AUTHORITY client_ready client={ClientId}.*map={ServerMap}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			MovementPattern = 'AUTHORITY movement client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			EnemyPattern = 'AUTHORITY enemy_spawned enemy=.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			MeleePattern = 'AUTHORITY melee_resolved attacker=.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			DamagePattern = 'AUTHORITY damage_applied attacker=.*sequence=(?<Sequence>[0-9]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			JoinInProgressPattern = 'AUTHORITY join_in_progress client=client-2.*sequence=(?<Sequence>[0-9]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			DisconnectPattern = 'AUTHORITY disconnected client=client-1.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ReconnectPattern = 'AUTHORITY reconnected client=client-1-reconnect connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			NetworkConfigPattern = 'AUTHORITY network_config network_config={NetworkConfigIdentity}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			TimeoutSeconds = $TimeoutSeconds
		}
		if ($ServerExecutableOverride) { $Arguments.ServerExecutable = $ServerExecutableOverride }
		if ($null -ne $ServerArgumentsOverride) { $Arguments.ServerArguments = @($ServerArgumentsOverride) }
		if ($null -ne $ClientArgumentsOverride) { $Arguments.ClientArguments = @($ClientArgumentsOverride) }
		if ($UseContracts) {
			$ContractRoot = Join-Path $FixtureRoot ("contracts-$FixtureRunId")
			New-Item -ItemType Directory -Path $ContractRoot -Force | Out-Null
			$CatalogPath = if ($ProfileCatalogOverridePath) { $ProfileCatalogOverridePath } else { Join-Path $ContractRoot 'network-profiles.json' }
			$ScenarioPath = if ($ScenarioContractOverridePath) { $ScenarioContractOverridePath } else { Join-Path $ContractRoot 'scenario.json' }
			if (-not $ProfileCatalogOverridePath) {
				$Profiles = foreach ($Kind in @('clean','representative','harsh','loss','duplication','reordering')) {
					[ordered]@{
						id = "network-profile.$Kind"
						version = 'fixture-v1'
						kind = $Kind
						runtime_config_identity = "network-emulation.$Kind"
						server_arguments = @("--fixture-server-profile-$Kind")
						client_arguments = @("--fixture-client-profile-$Kind")
					}
				}
				[ordered]@{ schema_id = 'aetheln.network-profile-catalog'; schema_version = 1; selected_profile_id = 'network-profile.clean'; profiles = @($Profiles) } |
					ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CatalogPath -Encoding UTF8
			}
			if (-not $ScenarioContractOverridePath) {
				[ordered]@{ schema_id = 'aetheln.network-authority-scenario'; schema_version = 1; id = 'network-authority.baseline.v1'; version = 'fixture-v1'; lifecycle_stages = @('join','play','death','respawn','disconnect','reconnect','shutdown') } |
					ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ScenarioPath -Encoding UTF8
			}
			$Arguments.ProfileId = 'network-profile.clean'
			$Arguments.NetworkConfigIdentity = 'network-emulation.clean'
			$Arguments.NetworkProfileCatalogPath = $CatalogPath
			$Arguments.ScenarioContractPath = $ScenarioPath
			$Arguments.DeathPattern = 'AUTHORITY death client=client-2.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			$Arguments.RespawnPattern = 'AUTHORITY respawn client=client-2.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			$Arguments.ShutdownPattern = 'AUTHORITY shutdown_complete role=server.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
		}
		if ($JoinInProgressPatternOverride) { $Arguments.JoinInProgressPattern = $JoinInProgressPatternOverride }
		if ($DamagePatternOverride) { $Arguments.DamagePattern = $DamagePatternOverride }
		if ($UseLauncher) {
			$LauncherStatePath = Join-Path $FixtureRoot "launcher-identity-$FixtureRunId.json"
			$Arguments.ServerLauncherExecutable = $PowerShellExecutable
			$Arguments.ServerLauncherArguments = @('-NoProfile', '-File', $FakeLauncher, 'launch', '{ServerExecutable}', $LauncherStatePath, '{ServerArguments}')
			$Arguments.ServerIdentityArguments = @('-NoProfile', '-File', $FakeLauncher, 'identity', '{ServerExecutable}')
			$Arguments.ServerCleanupArguments = @('-NoProfile', '-File', $FakeLauncher, 'cleanup', '{ServerProcessId}', $LauncherStatePath)
			$Arguments.ServerProcessIdPattern = 'AETHELN_SERVER_DESCENDANT_PID=(?<ProcessId>[1-9][0-9]*)'
		}
		if ($PackagedBuildProvenancePath) { $Arguments.PackagedBuildProvenancePath = $PackagedBuildProvenancePath }
		if ($ServerProvenanceExecutable) { $Arguments.ServerProvenanceExecutable = $ServerProvenanceExecutable }
		$ObservationDelayBreakpoint = $null
		$ShutdownReleaseBreakpoint = $null
		$ObservationExitBreakpoint = $null
		$BoundaryTimeoutBreakpoints = @()
		try {
			if ($BoundaryTimeoutDescription) {
				# Command breakpoint actions run in a child scope of the invoked function,
				# after parameter binding. Shadow the runner's timeout only in that wait's
				# local scope; initialization, other markers, and cleanup retain their allowance.
				# The real production wait body and its wall-clock deadline still execute.
				# Do not bind a module closure: Scope 1 must be the actual wait invocation.
				$BoundaryActionSource = {
					if ((Get-Variable -Name Description -Scope 1 -ValueOnly) -ceq '__BOUNDARY_DESCRIPTION__') {
						Set-Variable -Name TimeoutSeconds -Value 2 -Scope 1
					}
				}.ToString().Replace('__BOUNDARY_DESCRIPTION__', $BoundaryTimeoutDescription.Replace("'", "''"))
				$SetBoundaryTimeout = [scriptblock]::Create($BoundaryActionSource)
				$BoundaryTimeoutBreakpoints = @(Set-PSBreakpoint -Script $Script -Command @('Wait-ForMatch','Wait-ForSuccessfulProcessExit') -Action $SetBoundaryTimeout)
			}
			if ($ObservationStartDelaySeconds -gt 0) {
				$DelayObservation = { Start-Sleep -Seconds $ObservationStartDelaySeconds }.GetNewClosure()
				$ObservationDelayBreakpoint = Set-PSBreakpoint -Script $Script -Command Wait-ForObservationInterval -Action $DelayObservation
			}
			if ($ExitAfterMarkers) {
				# Deliberately exit a real required process when observation starts, even
				# after slow client initialization. The production health check must fail.
				$ReleaseObservationExit = { [System.IO.File]::WriteAllText($ObservationExitSignalPath, 'exit') }.GetNewClosure()
				$ObservationExitBreakpoint = Set-PSBreakpoint -Script $Script -Command Wait-ForObservationInterval -Action $ReleaseObservationExit
			}
			if ($ControlledExitSignalPath -ne 'none' -and -not $WithholdShutdownRelease) {
				# A non-breaking, script-scoped action releases only the fake server, after
				# the real observation interval and shutdown-marker validation complete.
				# Production health checks, exit timeout, and cleanup remain unchanged.
				$ReleaseShutdown = { [System.IO.File]::WriteAllText($ControlledExitSignalPath, 'release') }.GetNewClosure()
				$ShutdownReleaseBreakpoint = Set-PSBreakpoint -Script $Script -Command Wait-ForSuccessfulProcessExit -Action $ReleaseShutdown
			}
			& $Script @Arguments
		}
		finally {
			foreach ($Breakpoint in $BoundaryTimeoutBreakpoints) { Remove-PSBreakpoint -Breakpoint $Breakpoint }
			if ($null -ne $ObservationDelayBreakpoint) { Remove-PSBreakpoint -Breakpoint $ObservationDelayBreakpoint }
			if ($null -ne $ShutdownReleaseBreakpoint) { Remove-PSBreakpoint -Breakpoint $ShutdownReleaseBreakpoint }
			if ($null -ne $ObservationExitBreakpoint) { Remove-PSBreakpoint -Breakpoint $ObservationExitBreakpoint }
		}
	}

	$LogRoot = Join-Path $FixtureRoot 'success'
	$SuccessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Invoke-FixtureRun -FixtureLogRoot $LogRoot -FixtureRunId 'fixture-run-001' -RejectionReason 'malformed-intent'
	$SuccessStopwatch.Stop()
	Assert-True ($SuccessStopwatch.Elapsed.TotalSeconds -ge 5) 'The successful fixture must sustain execution for the requested five-second observation interval.'

	$EvidencePath = Join-Path $LogRoot 'network-authority-spike-evidence.json'
	Assert-True (Test-Path -LiteralPath $EvidencePath -PathType Leaf) 'The runner must emit one machine-readable evidence document.'
	$Evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
	Assert-True ($Evidence.schema_id -eq 'aetheln.network-authority-evidence') 'Evidence must use the canonical schema identity.'
	Assert-True ($Evidence.schema_version -eq 1) 'Evidence must use schema version 1.'
	foreach ($ContractOnlyField in @('failure_details','scenario_lifecycle','scenario_lifecycle_summary','process_outcomes','cleanup')) {
		Assert-True ($Evidence.PSObject.Properties.Name -notcontains $ContractOnlyField) "Legacy version-1 evidence must not gain contract-only field '$ContractOnlyField'."
	}
	Assert-True ($Evidence.scenario.id -eq 'network-authority.baseline.v1') 'Evidence must preserve immutable scenario identity.'
	Assert-True ($Evidence.scenario.map -eq '/Game/Maps/StarterMap' -and $Evidence.scenario.duration_seconds -eq 5) 'Map and duration must be correlated.'
	Assert-True ($Evidence.scenario.actor_mix -eq 'network-authority.actor-mix.v1') 'Actor mix must be correlated.'
	Assert-True ($Evidence.provenance.source_revision -eq 'fixture-revision' -and $Evidence.provenance.build -eq 'fixture-build') 'Source and build provenance must be explicit.'
	Assert-True ($Evidence.provenance.toolchain -eq 'UE-5.8.1-fixture' -and $Evidence.provenance.hardware -eq 'fixture-host') 'Toolchain and hardware provenance must be explicit.'
	Assert-True ($Evidence.provenance.topology -eq 'one-server-two-clients-local-fixture') 'Topology must be explicit.'
	Assert-True ($Evidence.network_profile.schema_id -eq 'aetheln.network-profile' -and $Evidence.network_profile.schema_version -eq 1) 'Network profile schema identity and version must be stable.'
	Assert-True ($Evidence.network_profile.id -eq 'network-profile.unset') 'Profile identity must be stable.'
	Assert-True ($Evidence.network_profile.runtime_config_identity -eq 'network-emulation.caller-supplied') 'The runtime-confirmed caller network configuration identity must be preserved.'
	foreach ($Field in @('latency_ms','jitter_ms','loss_percent','duplication_percent','reorder_percent','server_tick_hz','history_ms','bandwidth_limit_kbps','capacity_players')) {
		Assert-True ($null -eq $Evidence.network_profile.$Field) "$Field must remain null when unavailable."
	}
	Assert-True (@($Evidence.clients | Where-Object { $_.id -in @('client-1','client-2') } | Select-Object -ExpandProperty id -Unique).Count -eq 2) 'Two distinct initial client identities are required.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'server_ready' }).Count -eq 1) 'Server readiness must be observed.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'disconnect' }).Count -eq 1) 'Disconnect must be observed.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'reconnect' -and $_.client_id -eq 'client-1-reconnect' }).Count -eq 1) 'Reconnect must use a new client identity.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'movement' }).Count -eq 2) 'Movement must be observed for both clients.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'melee_resolved' }).Count -eq 1) 'One server-resolved melee observation is required.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'damage_applied' }).Count -eq 1) 'Authoritative damage must be observed.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.detail -notmatch '^AUTHORITY ' }).Count -eq 0) 'Legacy version-1 lifecycle details must retain their complete matched runtime lines.'
	Assert-True (@($Evidence.observations | Where-Object { $_.detail -notmatch '^AUTHORITY ' }).Count -eq 0) 'Legacy version-1 observation details must retain their complete matched runtime lines.'
	foreach ($Category in @('movement','aim','ability','hit','cooldown','dodge','block','resource','death','respawn')) {
		Assert-True (@($Evidence.rejections | Where-Object { $_.category -eq $Category }).Count -eq 1) "Exactly one observable rejection is required for $Category."
	}
	Assert-True (@($Evidence.rejections).Count -eq 10) 'Evidence must contain exactly the ten structured invalid-claim rejections.'
	Assert-True ($Evidence.rejections[0].PSObject.Properties.Name -notcontains 'profile_version') 'Legacy version-1 rejection records must retain their original shape.'
	Assert-True ($Evidence.scenario.environment -eq 'local') 'Fixture evidence must preserve the explicit local environment.'
	Assert-True (@($Evidence.rejections | Where-Object { $_.category -eq 'disconnected-command' }).Count -eq 0) 'Logout must not be admitted as disconnected-command rejection evidence.'
	$MeasurementFields = @(
		'server_game_thread_milliseconds',
		'server_replication_cpu_milliseconds',
		'client_memory_bytes',
		'server_memory_bytes',
		'bandwidth_per_connection_bits_per_second',
		'aggregate_bandwidth_bits_per_second',
		'correction_count',
		'correction_magnitude_centimeters',
		'relevant_actor_count',
		'destruction_event_count',
		'implementation_complexity',
		'failure_behavior'
	)
	$ActualMeasurementFields = @($Evidence.measurements.PSObject.Properties.Name)
	Assert-True ($ActualMeasurementFields.Count -eq $MeasurementFields.Count) 'Measurements must contain exactly the canonical 12 fields.'
	Assert-True (@(Compare-Object ($ActualMeasurementFields | Sort-Object) ($MeasurementFields | Sort-Object)).Count -eq 0) 'Measurement field names must match FAethelnNetworkSpikeMeasurements exactly.'
	foreach ($Field in $MeasurementFields) {
		Assert-True ($null -eq $Evidence.measurements.$Field) "$Field must be explicit null when capture is unavailable."
	}
	Assert-True ($Evidence.evidence_mode -eq 'fixture' -and $Evidence.result -eq 'fixture-passed') 'A complete fixture validates orchestration but can never claim packaged success.'
	Assert-True ($Evidence.result -ne 'passed') 'Synthetic marker output must never be admitted as successful packaged evidence.'
	Start-Sleep -Milliseconds 200
	$PowerShellExecutableName = [System.IO.Path]::GetFileName($PowerShellExecutable)
	$FixtureProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $PID" -ErrorAction Stop | Where-Object {
		$_.Name -eq $PowerShellExecutableName
	})
	$UninspectableFixtureProcesses = @($FixtureProcesses | Where-Object {
		-not $_.ExecutablePath -or -not $_.CommandLine
	})
	Assert-True ($UninspectableFixtureProcesses.Count -eq 0) 'Runner-owned fixture process command lines must remain inspectable for cleanup verification.'
	$OwnedProcesses = @($FixtureProcesses | Where-Object {
		$_.ExecutablePath -eq $PowerShellExecutable -and
		$_.CommandLine.IndexOf($FakeRuntime, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
	})
	Assert-True ($OwnedProcesses.Count -eq 0) 'Runner-owned fixture processes must be cleaned up.'
	Write-Output 'PASS: authority spike runner correlates lifecycle, authority, rejection, provenance, null measurements, observation duration, and cleanup evidence'

	$ContractLogRoot = Join-Path $FixtureRoot 'contract-success'
	Invoke-FixtureRun -FixtureLogRoot $ContractLogRoot -FixtureRunId 'fixture-contract-success' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true
	$ContractEvidencePath = Join-Path $ContractLogRoot 'network-authority-spike-evidence.json'
	$ContractEvidenceJson = Get-Content -LiteralPath $ContractEvidencePath -Raw
	$ContractEvidence = $ContractEvidenceJson | ConvertFrom-Json
	Assert-True ($ContractEvidence.schema_version -eq 2) 'Versioned scenario/profile execution must publish evidence schema version 2.'
	Assert-True ($ContractEvidence.scenario.version -eq 'fixture-v1') 'Scenario evidence must preserve the versioned contract identity.'
	Assert-True ($ContractEvidence.network_profile.id -eq 'network-profile.clean' -and $ContractEvidence.network_profile.version -eq 'fixture-v1' -and $ContractEvidence.network_profile.kind -eq 'clean') 'Selected profile identity, version, and kind must be explicit.'
	Assert-True ($ContractEvidence.network_profile.server_argument_count -eq 1 -and $ContractEvidence.network_profile.client_argument_count -eq 1) 'Evidence must record opaque profile argument counts without exposing values.'
	Assert-True ($ContractEvidence.network_profile.arguments_sha256 -match '^[0-9a-f]{64}$') 'Opaque profile arguments must be correlated by a deterministic SHA-256 digest.'
	foreach ($Field in @('latency_ms','jitter_ms','loss_percent','duplication_percent','reorder_percent','server_tick_hz','history_ms','bandwidth_limit_kbps','capacity_players')) {
		Assert-True ($null -eq $ContractEvidence.network_profile.$Field) "$Field must remain null instead of inventing a network value."
	}
	$ExpectedContractStages = @('join','play','death','respawn','disconnect','reconnect','shutdown')
	$ExpectedAuthoritativeResults = @('joined','damage-applied','dead','respawned','disconnected','reconnected','shutdown-complete')
	$ObservedContractStages = @($ContractEvidence.scenario_lifecycle | Select-Object -ExpandProperty stage)
	Assert-True (@(Compare-Object $ExpectedContractStages $ObservedContractStages -SyncWindow 0).Count -eq 0) 'Scenario lifecycle evidence must match the exact seven-stage ordered contract.'
	Assert-True ((@($ContractEvidence.scenario_lifecycle | Select-Object -ExpandProperty ordinal) -join ',') -eq '1,2,3,4,5,6,7') 'Scenario lifecycle ordinals must be stable and contiguous.'
	Assert-True ((@($ContractEvidence.scenario_lifecycle | Select-Object -ExpandProperty authoritative_result) -join ',') -eq ($ExpectedAuthoritativeResults -join ',')) 'Every lifecycle stage must publish its exact authoritative result.'
	Assert-True (@($ContractEvidence.scenario_lifecycle | Where-Object { $_.source_revision -ne 'fixture-revision' -or $_.build -ne 'fixture-build' -or $_.scenario_id -ne 'network-authority.baseline.v1' -or $_.scenario_version -ne 'fixture-v1' -or $_.profile_id -ne 'network-profile.clean' -or $_.profile_version -ne 'fixture-v1' -or $null -ne $_.activation_id }).Count -eq 0) 'Every lifecycle stage must carry exact build/scenario/profile identity and explicit null activation when not applicable.'
	Assert-True ($ContractEvidence.scenario_lifecycle[0].sequence_id -eq 10 -and $ContractEvidence.scenario_lifecycle[1].sequence_id -eq 20) 'Join and play lifecycle stages must publish their validated cross-stream authority sequences.'
	Assert-True (@($ContractEvidence.scenario_lifecycle | Select-Object -Skip 2 | Where-Object { $null -ne $_.sequence_id }).Count -eq 0) 'Lifecycle stages without a cross-stream sequence contract must retain explicit null sequence identity.'
	$ExpectedStageClientIds = @('client-2','client-1','client-2','client-2','client-1','client-1-reconnect',$null)
	for ($StageIndex = 0; $StageIndex -lt $ContractEvidence.scenario_lifecycle.Count; $StageIndex++) {
		$StageEvidence = $ContractEvidence.scenario_lifecycle[$StageIndex]
		Assert-True ($StageEvidence.PSObject.Properties.Name -ccontains 'client_id') "Lifecycle stage '$($StageEvidence.stage)' must expose a stable client_id property."
		Assert-True ($StageEvidence.client_id -eq $ExpectedStageClientIds[$StageIndex]) "Lifecycle stage '$($StageEvidence.stage)' must publish its exact client identity or explicit JSON null."
	}
	Assert-True ($ContractEvidence.scenario_lifecycle_summary.expected_stage_count -eq 7 -and $ContractEvidence.scenario_lifecycle_summary.observed_stage_count -eq 7 -and $ContractEvidence.scenario_lifecycle_summary.completed) 'Scenario lifecycle summary must report exact completion.'
	Assert-True ($null -eq $ContractEvidence.failure_details) 'Successful contract evidence must not fabricate failure details.'
	$ProcessOutcomes = @($ContractEvidence.process_outcomes)
	Assert-True ($ProcessOutcomes.Count -eq 4) 'Successful contract evidence must publish exactly one process outcome for every server and client role.'
	foreach ($ExpectedOutcome in @(
		@{ Role = 'server'; Client = $null; State = 'exited'; ExitCode = 0 },
		@{ Role = 'client-1'; Client = 'client-1'; State = 'runner-terminated'; ExitCode = $null },
		@{ Role = 'client-2'; Client = 'client-2'; State = 'runner-terminated'; ExitCode = $null },
		@{ Role = 'client-1-reconnect'; Client = 'client-1-reconnect'; State = 'runner-terminated'; ExitCode = $null }
	)) {
		$Outcome = @($ProcessOutcomes | Where-Object { $_.process_role -ceq $ExpectedOutcome.Role })
		Assert-True ($Outcome.Count -eq 1) "Process role '$($ExpectedOutcome.Role)' must have exactly one stable outcome."
		Assert-True ($Outcome[0].client_id -eq $ExpectedOutcome.Client -and -not $Outcome[0].timed_out -and $Outcome[0].termination_state -ceq $ExpectedOutcome.State) "Process role '$($ExpectedOutcome.Role)' must publish exact client, timeout, and termination state."
		Assert-True ($null -ne $Outcome[0].exit_code) "Process role '$($ExpectedOutcome.Role)' must publish its exit code after exit confirmation."
		if ($null -ne $ExpectedOutcome.ExitCode) { Assert-True ($Outcome[0].exit_code -eq $ExpectedOutcome.ExitCode) "Process role '$($ExpectedOutcome.Role)' must exit with code $($ExpectedOutcome.ExitCode)." }
	}
	Assert-True ($ContractEvidence.cleanup.attempted -and $ContractEvidence.cleanup.succeeded -and $null -eq $ContractEvidence.cleanup.failure) 'Controlled cleanup must be explicit in successful evidence.'
	Assert-True (@($ContractEvidence.rejections | Where-Object { $_.process_role -ne 'server' -or $_.client_id -ne 'client-2' -or -not $_.activation_id -or $_.sequence_id -le 0 -or $_.authoritative_result -ne 'rejected' -or $_.build -ne 'fixture-build' -or $_.scenario_id -ne 'network-authority.baseline.v1' -or $_.profile_id -ne 'network-profile.clean' }).Count -eq 0) 'Every invalid command result must identify its role, client, activation, sequence, authoritative result, build, scenario, and profile.'
	Assert-True ($ContractEvidenceJson.IndexOf($FixtureRoot, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Normalized v2 evidence must not expose the fixture or log root.'
	Assert-True ($ContractEvidenceJson -notmatch '--fixture-(server|client)-profile') 'Normalized v2 evidence must not expose raw opaque profile arguments.'
	Write-Output 'PASS: versioned fixture contracts produce exact lifecycle, profile, rejection, cleanup, and path-safe schema-v2 evidence'

	$DelayedObservationRoot = Join-Path $FixtureRoot 'delayed-observation-start'
	Invoke-FixtureRun -FixtureLogRoot $DelayedObservationRoot -FixtureRunId 'fixture-delayed-observation-start' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ObservationStartDelaySeconds 4
	$DelayedObservationEvidence = Get-Content -LiteralPath (Join-Path $DelayedObservationRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($DelayedObservationEvidence.result -eq 'fixture-passed' -and $DelayedObservationEvidence.cleanup.succeeded) 'Delaying observation beyond the former server-relative exit timer must still complete observation, controlled shutdown, and cleanup.'
	Write-Output 'PASS: delayed observation entry does not race controlled fixture shutdown'

	$WithheldReleaseRoot = Join-Path $FixtureRoot 'withheld-shutdown-release'
	$WithheldReleaseFailure = $null
	try { Invoke-FixtureRun -FixtureLogRoot $WithheldReleaseRoot -FixtureRunId 'fixture-withheld-shutdown-release' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -WithholdShutdownRelease $true -ServerStartupDelaySeconds 3 -BoundaryTimeoutDescription 'authoritative server exit after controlled shutdown' } catch { $WithheldReleaseFailure = $_.Exception.Message }
	Assert-True ($WithheldReleaseFailure -match '^Timed out after 2 seconds waiting for authoritative server exit after controlled shutdown\.$') "A withheld fixture shutdown release must reach the production exit timeout after slow initialization. Actual: $WithheldReleaseFailure"
	$WithheldReleaseEvidence = Get-Content -LiteralPath (Join-Path $WithheldReleaseRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($WithheldReleaseEvidence.result -eq 'failed' -and $WithheldReleaseEvidence.failure_details.observed_stage -eq 'shutdown' -and $WithheldReleaseEvidence.cleanup.succeeded) 'A withheld fixture shutdown release must fail at shutdown and clean up owned runtime processes.'
	Assert-True ($WithheldReleaseEvidence.failure_details.timed_out -and $WithheldReleaseEvidence.failure_details.process_role -eq 'server') 'The withheld release must record an actual server exit timeout.'
	Write-Output 'PASS: slow initialization preserves the two-second withheld-release timeout and owned-process cleanup'

	function Write-ContractCatalog([string] $Path, [object[]] $Profiles, [string] $SelectedProfileId = 'network-profile.clean') {
		[ordered]@{ schema_id = 'aetheln.network-profile-catalog'; schema_version = 1; selected_profile_id = $SelectedProfileId; profiles = @($Profiles) } |
			ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
	}
	function Get-ContractProfile {
		return @('clean','representative','harsh','loss','duplication','reordering') | ForEach-Object {
			[ordered]@{ id = "network-profile.$_"; version = 'fixture-v1'; kind = $_; runtime_config_identity = "network-emulation.$_"; server_arguments = @("--server-$_"); client_arguments = @("--client-$_") }
		}
	}
	$LiteralProfileCatalog = Join-Path $FixtureRoot 'literal-profile-token.json'
	$LiteralProfiles = @(Get-ContractProfile)
	$LiteralProfiles[0].server_arguments = @('{RunId}')
	$LiteralProfiles[0].client_arguments = @('{RunId}')
	Write-ContractCatalog $LiteralProfileCatalog $LiteralProfiles
	$LiteralProfileRoot = Join-Path $FixtureRoot 'literal-profile-token'
	Invoke-FixtureRun -FixtureLogRoot $LiteralProfileRoot -FixtureRunId 'fixture-literal-profile-token' -RejectionReason 'malformed-intent' -DurationSeconds 1 -Behavior 'literal-profile-token' -UseContracts $true -ProfileCatalogOverridePath $LiteralProfileCatalog
	foreach ($LiteralProfileRole in @('server','client-1','client-2','client-1-reconnect')) {
		$LiteralProfileLog = Get-Content -LiteralPath (Join-Path $LiteralProfileRoot "$LiteralProfileRole.stdout.log") -Raw
		Assert-True ($LiteralProfileLog -match 'FIXTURE_OPAQUE_ARGUMENT value=\{RunId\}') "Opaque profile argument must reach '$LiteralProfileRole' literally without runner placeholder expansion."
	}
	$LiteralProfileEvidence = Get-Content -LiteralPath (Join-Path $LiteralProfileRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	$LiteralProfileJson = [ordered]@{ server = @('{RunId}'); client = @('{RunId}') } | ConvertTo-Json -Depth 4 -Compress
	$LiteralProfileHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$ExpectedLiteralProfileDigest = [System.BitConverter]::ToString($LiteralProfileHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($LiteralProfileJson))).Replace('-', '').ToLowerInvariant()
	} finally {
		$LiteralProfileHasher.Dispose()
	}
	Assert-True ($LiteralProfileEvidence.network_profile.server_argument_count -eq 1 -and $LiteralProfileEvidence.network_profile.client_argument_count -eq 1 -and $LiteralProfileEvidence.network_profile.arguments_sha256 -ceq $ExpectedLiteralProfileDigest) 'Profile argument counts and digest must correlate the exact opaque values launched without expansion.'
	$ServerArgumentsWithoutRunPlaceholder = @('-NoProfile', '-File', $FakeRuntime, 'server', 'server', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', 'caller-run-identity', '{NetworkConfigIdentity}', '{Environment}', 'normal', 'malformed-intent', 'false', '0')
	$ClientArgumentsWithoutRunPlaceholder = @('-NoProfile', '-File', $FakeRuntime, 'client', '{ClientId}', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', 'caller-run-identity', '{NetworkConfigIdentity}', '{Environment}', 'normal')
	foreach ($MissingCallerPlaceholder in @(
		@{ Name = 'server'; Server = $ServerArgumentsWithoutRunPlaceholder; Client = $null; Failure = 'ServerArguments must contain {RunId}' },
		@{ Name = 'client'; Server = $null; Client = $ClientArgumentsWithoutRunPlaceholder; Failure = 'ClientArguments must contain {RunId}' }
	)) {
		$MissingCallerPlaceholderFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot "profile-cannot-supply-$($MissingCallerPlaceholder.Name)-placeholder") -FixtureRunId "fixture-profile-cannot-supply-$($MissingCallerPlaceholder.Name)-placeholder" -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ProfileCatalogOverridePath $LiteralProfileCatalog -ServerArgumentsOverride $MissingCallerPlaceholder.Server -ClientArgumentsOverride $MissingCallerPlaceholder.Client
		} catch { $MissingCallerPlaceholderFailure = $_.Exception.Message }
		Assert-True ($MissingCallerPlaceholderFailure -match [regex]::Escape($MissingCallerPlaceholder.Failure)) "Opaque profile arguments must not satisfy a missing caller-owned $($MissingCallerPlaceholder.Name) placeholder. Actual: $MissingCallerPlaceholderFailure"
	}
	foreach ($MissingSequencePattern in @(
		@{ Name = 'join'; Join = 'AUTHORITY join_in_progress client=client-2.*sequence=[0-9]+.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; Damage = $null; Failure = 'JoinInProgressPattern must contain a named Sequence capture' },
		@{ Name = 'play'; Join = $null; Damage = 'AUTHORITY damage_applied attacker=.*sequence=[0-9]+.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; Failure = 'DamagePattern must contain a named Sequence capture' }
	)) {
		$MissingSequencePatternFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot "missing-$($MissingSequencePattern.Name)-sequence-capture") -FixtureRunId "fixture-missing-$($MissingSequencePattern.Name)-sequence-capture" -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -JoinInProgressPatternOverride $MissingSequencePattern.Join -DamagePatternOverride $MissingSequencePattern.Damage
		} catch { $MissingSequencePatternFailure = $_.Exception.Message }
		Assert-True ($MissingSequencePatternFailure -match [regex]::Escape($MissingSequencePattern.Failure)) "Schema-v2 $($MissingSequencePattern.Name) pattern must require its named Sequence capture. Actual: $MissingSequencePatternFailure"
	}
	Write-Output 'PASS: schema-v2 join and play patterns require named authority Sequence captures before launch'
	Write-Output 'PASS: opaque profile arguments remain literal, correlate exact launched values, and cannot satisfy caller-owned runner placeholders'
	$InvalidCatalogRoot = Join-Path $FixtureRoot 'invalid-contract-catalogs'
	New-Item -ItemType Directory -Path $InvalidCatalogRoot -Force | Out-Null
	$MissingVersionProfiles = @(Get-ContractProfile)
	$MissingVersionProfiles[0].Remove('version')
	$MissingVersionCatalog = Join-Path $InvalidCatalogRoot 'missing-version.json'
	Write-ContractCatalog $MissingVersionCatalog $MissingVersionProfiles
	$DuplicateKindProfiles = @(Get-ContractProfile)
	$DuplicateKindProfiles[1].kind = 'clean'
	$DuplicateKindCatalog = Join-Path $InvalidCatalogRoot 'duplicate-kind.json'
	Write-ContractCatalog $DuplicateKindCatalog $DuplicateKindProfiles
	$UnselectedCatalog = Join-Path $InvalidCatalogRoot 'unselected.json'
	Write-ContractCatalog -Path $UnselectedCatalog -Profiles @(Get-ContractProfile) -SelectedProfileId 'network-profile.absent'
	$ArbitraryIdProfiles = @(Get-ContractProfile)
	$ArbitraryIdProfiles[0].id = 'network-profile.custom'
	$ArbitraryIdCatalog = Join-Path $InvalidCatalogRoot 'arbitrary-id.json'
	Write-ContractCatalog -Path $ArbitraryIdCatalog -Profiles $ArbitraryIdProfiles -SelectedProfileId 'network-profile.custom'
	$CaseVariantIdProfiles = @(Get-ContractProfile)
	$CaseVariantIdProfiles[0].id = 'network-profile.Clean'
	$CaseVariantIdCatalog = Join-Path $InvalidCatalogRoot 'case-variant-id.json'
	Write-ContractCatalog -Path $CaseVariantIdCatalog -Profiles $CaseVariantIdProfiles -SelectedProfileId 'network-profile.Clean'
	$EmptyServerArgumentsProfiles = @(Get-ContractProfile)
	$EmptyServerArgumentsProfiles[0].server_arguments = @()
	$EmptyServerArgumentsCatalog = Join-Path $InvalidCatalogRoot 'empty-server-arguments.json'
	Write-ContractCatalog $EmptyServerArgumentsCatalog $EmptyServerArgumentsProfiles
	$EmptyClientArgumentsProfiles = @(Get-ContractProfile)
	$EmptyClientArgumentsProfiles[0].client_arguments = @()
	$EmptyClientArgumentsCatalog = Join-Path $InvalidCatalogRoot 'empty-client-arguments.json'
	Write-ContractCatalog $EmptyClientArgumentsCatalog $EmptyClientArgumentsProfiles
	foreach ($InvalidCatalog in @(
		@{ Name = 'missing-version'; Path = $MissingVersionCatalog; Failure = 'unsupported or missing fields' },
		@{ Name = 'duplicate-kind'; Path = $DuplicateKindCatalog; Failure = 'Duplicate network profile kind' },
		@{ Name = 'unselected'; Path = $UnselectedCatalog; Failure = 'select exactly one declared profile' },
		@{ Name = 'arbitrary-id'; Path = $ArbitraryIdCatalog; Failure = "must use exact id 'network-profile.clean'" },
		@{ Name = 'case-variant-id'; Path = $CaseVariantIdCatalog; Failure = "must use exact id 'network-profile.clean'" },
		@{ Name = 'empty-server-arguments'; Path = $EmptyServerArgumentsCatalog; Failure = 'Network profile server_arguments' },
		@{ Name = 'empty-client-arguments'; Path = $EmptyClientArgumentsCatalog; Failure = 'Network profile client_arguments' }
	)) {
		$InvalidCatalogFailure = $null
		try { Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot $InvalidCatalog.Name) -FixtureRunId ("fixture-$($InvalidCatalog.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ProfileCatalogOverridePath $InvalidCatalog.Path } catch { $InvalidCatalogFailure = $_.Exception.Message }
		Assert-True ($InvalidCatalogFailure -match [regex]::Escape($InvalidCatalog.Failure)) "$($InvalidCatalog.Name) profile catalog must fail closed before launch."
	}
	Write-Output 'PASS: incomplete, duplicate, unselected, arbitrary-id, case-variant-id, and empty-argument network profile catalogs fail closed before launch'

	$DuplicateCatalogPropertyPath = Join-Path $InvalidCatalogRoot 'duplicate-catalog-property.json'
	@'
{
  "schema_id": "aetheln.network-profile-catalog",
  "schema_version": 1,
  "selected_profile_id": "network-profile.clean",
  "selected_profile_id": "network-profile.harsh",
  "profiles": []
}
'@ | Set-Content -LiteralPath $DuplicateCatalogPropertyPath -Encoding UTF8
	$DuplicateNestedProfilePropertyPath = Join-Path $InvalidCatalogRoot 'duplicate-nested-profile-property.json'
	@'
{
  "schema_id": "aetheln.network-profile-catalog",
  "schema_version": 1,
  "selected_profile_id": "network-profile.clean",
  "profiles": [
    {
      "id": "network-profile.clean",
      "version": "fixture-v1",
      "kind": "clean",
      "kind": "harsh",
      "runtime_config_identity": "network-emulation.clean",
      "server_arguments": ["--fixture-server-profile-clean"],
      "client_arguments": ["--fixture-client-profile-clean"]
    }
  ]
}
'@ | Set-Content -LiteralPath $DuplicateNestedProfilePropertyPath -Encoding UTF8
	foreach ($DuplicateCatalog in @(
		@{ Name = 'duplicate-catalog-property'; Path = $DuplicateCatalogPropertyPath; Property = 'selected_profile_id' },
		@{ Name = 'duplicate-nested-profile-property'; Path = $DuplicateNestedProfilePropertyPath; Property = 'kind' }
	)) {
		$DuplicateCatalogFailure = $null
		try { Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot $DuplicateCatalog.Name) -FixtureRunId ("fixture-$($DuplicateCatalog.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ProfileCatalogOverridePath $DuplicateCatalog.Path } catch { $DuplicateCatalogFailure = $_.Exception.Message }
		Assert-True ($DuplicateCatalogFailure -match [regex]::Escape("duplicate JSON property '$($DuplicateCatalog.Property)'")) "$($DuplicateCatalog.Name) must reject its duplicate property before launch. Actual: $DuplicateCatalogFailure"
	}
	Write-Output 'PASS: profile catalog JSON rejects duplicate top-level and nested profile properties before conversion'

	function Write-SensitiveContractCatalog([string] $Path, [string] $SensitiveServerArgument, [string] $SensitiveClientArgument) {
		$SensitiveProfiles = @(Get-ContractProfile)
		$SensitiveProfiles[0].server_arguments = @($SensitiveServerArgument)
		$SensitiveProfiles[0].client_arguments = @($SensitiveClientArgument)
		Write-ContractCatalog $Path $SensitiveProfiles
	}
	$AdversarialLogRoot = Join-Path $FixtureRoot 'contract-adversarial-public-lines'
	$AdversarialLogRootVariant = $AdversarialLogRoot.ToUpperInvariant().Replace('\', '/')
	$AdversarialServerArgument = "--opaque-server=$AdversarialLogRootVariant"
	$AdversarialClientArgument = "--opaque-client=$AdversarialLogRootVariant"
	$AdversarialCatalog = Join-Path $InvalidCatalogRoot 'adversarial-public-lines.json'
	Write-SensitiveContractCatalog -Path $AdversarialCatalog -SensitiveServerArgument $AdversarialServerArgument -SensitiveClientArgument $AdversarialClientArgument
	Invoke-FixtureRun -FixtureLogRoot $AdversarialLogRoot -FixtureRunId 'fixture-adversarial-public-lines' -RejectionReason 'malformed-intent' -DurationSeconds 1 -Behavior 'adversarial-public-lines' -UseContracts $true -ProfileCatalogOverridePath $AdversarialCatalog
	$AdversarialEvidenceJson = Get-Content -LiteralPath (Join-Path $AdversarialLogRoot 'network-authority-spike-evidence.json') -Raw
	$AdversarialEvidence = $AdversarialEvidenceJson | ConvertFrom-Json
	Assert-True (@($AdversarialEvidence.lifecycle | Where-Object { $_.detail -cne $_.event }).Count -eq 0) 'Schema-v2 lifecycle detail must equal its canonical event identifier.'
	Assert-True (@($AdversarialEvidence.observations | Where-Object { $_.detail -cne $_.event }).Count -eq 0) 'Schema-v2 observation detail must equal its canonical event identifier.'
	Assert-True (@($AdversarialEvidence.scenario_lifecycle | Where-Object { $_.detail -notin @('joined','damage-applied','dead','respawned','disconnected','reconnected','shutdown-complete') }).Count -eq 0) 'Schema-v2 lifecycle detail must use only canonical authoritative-result values.'
	Assert-True (@($AdversarialEvidence.rejections | Where-Object { $_.detail -cne "rejected:$($_.reason)" }).Count -eq 0) 'Schema-v2 rejection detail must use only its canonical rejection result and reason.'
	foreach ($ForbiddenPublicValue in @($AdversarialServerArgument, $AdversarialClientArgument, $AdversarialLogRootVariant, $AdversarialLogRoot, $PowerShellExecutable)) {
		Assert-True ($AdversarialEvidenceJson.IndexOf($ForbiddenPublicValue, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Serialized schema-v2 evidence must not expose '$ForbiddenPublicValue'."
	}
	Write-Output 'PASS: adversarial matched public lines produce only canonical lifecycle and observation details and cannot expose opaque arguments or absolute paths anywhere in schema-v2 evidence'

	$PathFailureLogRoot = Join-Path $FixtureRoot 'contract-path-bearing-failure'
	$PathFailureLogRootVariant = $PathFailureLogRoot.ToUpperInvariant().Replace('\', '/')
	$PathFailureArgument = "--opaque-failure=$PathFailureLogRootVariant"
	$PathFailureCatalog = Join-Path $InvalidCatalogRoot 'path-bearing-failure.json'
	Write-SensitiveContractCatalog -Path $PathFailureCatalog -SensitiveServerArgument $PathFailureArgument -SensitiveClientArgument $PathFailureArgument
	$PathFailure = $null
	try { Invoke-FixtureRun -FixtureLogRoot $PathFailureLogRoot -FixtureRunId 'fixture-path-bearing-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -Behavior 'path-bearing-runtime-error' -UseContracts $true -ProfileCatalogOverridePath $PathFailureCatalog } catch { $PathFailure = $_.Exception.Message }
	Assert-True ($PathFailure -match 'Runtime reported an error') 'The adversarial path-bearing runtime error fixture must exercise contract failure publication.'
	$PathFailureEvidenceJson = Get-Content -LiteralPath (Join-Path $PathFailureLogRoot 'network-authority-spike-evidence.json') -Raw
	$PathFailureEvidence = $PathFailureEvidenceJson | ConvertFrom-Json
	Assert-True ($PathFailureEvidence.failure -match '^stage=[^;]+;role=[^;]+;reason=runtime-error$') 'Schema-v2 failure must publish one canonical runtime-error reason.'
	Assert-True ($PathFailureEvidence.failure_details.failure_reason -ceq $PathFailureEvidence.failure) 'Schema-v2 failure details must reuse the canonical public failure reason.'
	foreach ($ForbiddenFailureValue in @($PathFailureArgument, $PathFailureLogRootVariant, $PathFailureLogRoot, $PowerShellExecutable)) {
		Assert-True ($PathFailureEvidenceJson.IndexOf($ForbiddenFailureValue, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Schema-v2 failure evidence must not expose '$ForbiddenFailureValue'."
	}

	$InvalidExecutable = Join-Path $InvalidCatalogRoot 'not-an-executable.txt'
	Set-Content -LiteralPath $InvalidExecutable -Encoding UTF8 -Value 'not executable'
	$ProcessStartLogRoot = Join-Path $FixtureRoot 'contract-process-start-failure'
	$ProcessStartFailure = $null
	try { Invoke-FixtureRun -FixtureLogRoot $ProcessStartLogRoot -FixtureRunId 'fixture-process-start-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ServerExecutableOverride $InvalidExecutable } catch { $ProcessStartFailure = $_.Exception.Message }
	Assert-True (-not [string]::IsNullOrWhiteSpace($ProcessStartFailure)) 'The invalid executable fixture must exercise a process-start failure.'
	$ProcessStartEvidenceJson = Get-Content -LiteralPath (Join-Path $ProcessStartLogRoot 'network-authority-spike-evidence.json') -Raw
	$ProcessStartEvidence = $ProcessStartEvidenceJson | ConvertFrom-Json
	Assert-True ($ProcessStartEvidence.failure -ceq 'stage=server-start;role=server;reason=contract-validation-failed') 'Schema-v2 process-start failure must publish one canonical reason without exception text.'
	Assert-True ($ProcessStartEvidence.failure_details.failure_reason -ceq $ProcessStartEvidence.failure) 'Schema-v2 process-start failure details must reuse the canonical public reason.'
	Assert-True ($ProcessStartEvidenceJson.IndexOf($InvalidExecutable, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Schema-v2 process-start failure evidence must not expose the absolute executable path.'
	Write-Output 'PASS: schema-v2 path-bearing runtime and process-start failures publish canonical path-safe reasons'

	$MissingScenarioVersion = Join-Path $InvalidCatalogRoot 'scenario-missing-version.json'
	[ordered]@{ schema_id = 'aetheln.network-authority-scenario'; schema_version = 1; id = 'network-authority.baseline.v1'; lifecycle_stages = @('join','play','death','respawn','disconnect','reconnect','shutdown') } |
		ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $MissingScenarioVersion -Encoding UTF8
	$ReorderedScenarioContract = Join-Path $InvalidCatalogRoot 'scenario-reordered.json'
	[ordered]@{ schema_id = 'aetheln.network-authority-scenario'; schema_version = 1; id = 'network-authority.baseline.v1'; version = 'fixture-v1'; lifecycle_stages = @('play','join','death','respawn','disconnect','reconnect','shutdown') } |
		ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReorderedScenarioContract -Encoding UTF8
	$DuplicateScenarioProperty = Join-Path $InvalidCatalogRoot 'scenario-duplicate-property.json'
	@'
{
  "schema_id": "aetheln.network-authority-scenario",
  "schema_version": 1,
  "id": "network-authority.baseline.v1",
  "version": "fixture-v1",
  "version": "fixture-v2",
  "lifecycle_stages": ["join", "play", "death", "respawn", "disconnect", "reconnect", "shutdown"]
}
'@ | Set-Content -LiteralPath $DuplicateScenarioProperty -Encoding UTF8
	foreach ($InvalidScenario in @(
		@{ Name = 'scenario-missing-version'; Path = $MissingScenarioVersion; Failure = 'unsupported or missing fields' },
		@{ Name = 'scenario-reordered'; Path = $ReorderedScenarioContract; Failure = 'lifecycle stages must be ordered' },
		@{ Name = 'scenario-duplicate-property'; Path = $DuplicateScenarioProperty; Failure = "duplicate JSON property 'version'" }
	)) {
		$InvalidScenarioFailure = $null
		try { Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot $InvalidScenario.Name) -FixtureRunId ("fixture-$($InvalidScenario.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseContracts $true -ScenarioContractOverridePath $InvalidScenario.Path } catch { $InvalidScenarioFailure = $_.Exception.Message }
		Assert-True ($InvalidScenarioFailure -match [regex]::Escape($InvalidScenario.Failure)) "$($InvalidScenario.Name) contract must fail closed before launch."
	}
	Write-Output 'PASS: incomplete, reordered, and duplicate-property scenario contracts fail closed before launch'

	$ContractFailureCases = @(
		@{ Name = 'contract-join-play-sequence-reordered'; Behavior = 'join-play-sequence-reordered'; Failure = 'Contract join sequence must precede authoritative play sequence'; Stage = 'play'; Role = 'server'; Client = 'client-1'; TimedOut = $false },
		@{ Name = 'contract-invalid-join-sequence'; Behavior = 'invalid-join-sequence'; Failure = 'join-in-progress Sequence must be a positive 64-bit integer'; Stage = 'join'; Role = 'client-2'; Client = 'client-2'; TimedOut = $false },
		@{ Name = 'contract-invalid-play-sequence'; Behavior = 'invalid-play-sequence'; Failure = 'authoritative damage Sequence must be a positive 64-bit integer'; Stage = 'play'; Role = 'server'; Client = 'client-1'; TimedOut = $false },
		@{ Name = 'contract-missing-death'; Behavior = 'missing-death'; Failure = 'waiting for authoritative death'; Stage = 'death'; Role = 'server'; Client = 'client-2'; TimedOut = $true },
		@{ Name = 'contract-duplicate-death'; Behavior = 'duplicate-death'; Failure = 'Expected exactly one authoritative death record'; Stage = 'shutdown'; Role = 'server'; Client = $null; TimedOut = $false },
		@{ Name = 'contract-duplicate-respawn'; Behavior = 'duplicate-respawn'; Failure = 'Expected exactly one authoritative respawn record'; Stage = 'shutdown'; Role = 'server'; Client = $null; TimedOut = $false },
		@{ Name = 'contract-duplicate-shutdown'; Behavior = 'duplicate-shutdown'; Failure = 'Expected exactly one controlled shutdown record'; Stage = 'shutdown'; Role = 'server'; Client = $null; TimedOut = $false },
		@{ Name = 'contract-reordered'; Behavior = 'reordered-scenario'; Failure = 'waiting for authoritative death'; Stage = 'death'; Role = 'server'; Client = 'client-2'; TimedOut = $true },
		@{ Name = 'contract-wrong-client'; Behavior = 'wrong-client-death'; Failure = 'waiting for authoritative death'; Stage = 'death'; Role = 'server'; Client = 'client-2'; TimedOut = $true },
		@{ Name = 'contract-stale-profile'; Behavior = 'stale-profile-death'; Failure = 'waiting for authoritative death'; Stage = 'death'; Role = 'server'; Client = 'client-2'; TimedOut = $true },
		@{ Name = 'contract-missing-respawn'; Behavior = 'missing-respawn'; Failure = 'waiting for authoritative respawn'; Stage = 'respawn'; Role = 'server'; Client = 'client-2'; TimedOut = $true },
		@{ Name = 'contract-missing-shutdown'; Behavior = 'missing-shutdown'; Failure = 'waiting for controlled shutdown'; Stage = 'shutdown'; Role = 'server'; Client = $null; TimedOut = $true },
		@{ Name = 'contract-shutdown-marker-without-exit'; Behavior = 'shutdown-marker-stays-alive'; Failure = 'waiting for authoritative server exit after controlled shutdown'; Stage = 'shutdown'; Role = 'server'; Client = $null; TimedOut = $true },
		@{ Name = 'contract-client-1-failure'; Behavior = 'client-1-failure'; Failure = 'Process exited with code 31 while waiting for client-1 readiness'; Stage = 'client-ready'; Role = 'client-1'; Client = 'client-1'; TimedOut = $false },
		@{ Name = 'contract-client-2-failure'; Behavior = 'client-2-failure'; Failure = 'Process exited with code 31 while waiting for client-2 readiness'; Stage = 'client-ready'; Role = 'client-2'; Client = 'client-2'; TimedOut = $false },
		@{ Name = 'contract-reconnect-client-failure'; Behavior = 'reconnect-client-failure'; Failure = 'Process exited with code 31 while waiting for reconnect client readiness'; Stage = 'reconnect'; Role = 'client-1-reconnect'; Client = 'client-1-reconnect'; TimedOut = $false }
	)
	foreach ($FailureCase in $ContractFailureCases) {
		$ContractFailure = $null
		$FailureRoot = Join-Path $FixtureRoot $FailureCase.Name
		$BoundaryDescription = if ($FailureCase.TimedOut) { $FailureCase.Failure -replace '^waiting for ', '' } else { '' }
		$StartupDelay = if ($FailureCase.Name -eq 'contract-missing-death') { 3 } else { 0 }
		try { Invoke-FixtureRun -FixtureLogRoot $FailureRoot -FixtureRunId ("fixture-$($FailureCase.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -Behavior $FailureCase.Behavior -UseContracts $true -BoundaryTimeoutDescription $BoundaryDescription -ServerStartupDelaySeconds $StartupDelay } catch { $ContractFailure = $_.Exception.Message }
		Assert-True ($ContractFailure -match [regex]::Escape($FailureCase.Failure)) "$($FailureCase.Name) must fail closed with its expected reason. Actual: $ContractFailure"
		if ($FailureCase.TimedOut) {
			Assert-True ($ContractFailure -match '^Timed out after 2 seconds waiting for ') "$($FailureCase.Name) must retain the two-second negative boundary. Actual: $ContractFailure"
		}
		$FailedContractJson = Get-Content -LiteralPath (Join-Path $FailureRoot 'network-authority-spike-evidence.json') -Raw
		$FailedContractEvidence = $FailedContractJson | ConvertFrom-Json
		Assert-True ($FailedContractEvidence.schema_version -eq 2 -and $FailedContractEvidence.result -eq 'failed') "$($FailureCase.Name) must emit failed v2 evidence."
		Assert-True ($FailedContractEvidence.failure_details.observed_stage -eq $FailureCase.Stage -and $FailedContractEvidence.failure_details.process_role -eq $FailureCase.Role -and $FailedContractEvidence.failure_details.client_id -eq $FailureCase.Client) "$($FailureCase.Name) must identify the failing stage, role, and client."
		Assert-True ($FailedContractEvidence.failure_details.timed_out -eq $FailureCase.TimedOut) "$($FailureCase.Name) must normalize timeout state."
		Assert-True ($FailedContractEvidence.failure_details.source_revision -eq 'fixture-revision' -and $FailedContractEvidence.failure_details.build -eq 'fixture-build' -and $FailedContractEvidence.failure_details.scenario_version -eq 'fixture-v1' -and $FailedContractEvidence.failure_details.profile_version -eq 'fixture-v1') "$($FailureCase.Name) must preserve source, build, scenario, and profile identity."
		Assert-True ($FailedContractJson.IndexOf($FixtureRoot, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "$($FailureCase.Name) normalized evidence must not expose the fixture or log root."
	}
	$ContractServerExitRoot = Join-Path $FixtureRoot 'contract-server-exit'
	$ContractServerExitFailure = $null
	try { Invoke-FixtureRun -FixtureLogRoot $ContractServerExitRoot -FixtureRunId 'fixture-contract-server-exit' -RejectionReason 'malformed-intent' -DurationSeconds 3 -ExitAfterMarkers $true -Behavior 'slow-client-start' -UseContracts $true } catch { $ContractServerExitFailure = $_.Exception.Message }
	Assert-True (Test-Path -LiteralPath (Join-Path $FixtureRoot 'observation-exit-fixture-contract-server-exit') -PathType Leaf) "The early-exit regression must reach observation after slow client initialization. Actual: $ContractServerExitFailure"
	Assert-True ($ContractServerExitFailure -match "Required process 'server' exited unexpectedly with code 0") "A contract-mode server exit must fail during observation. Actual: $ContractServerExitFailure"
	$ContractServerExitEvidence = Get-Content -LiteralPath (Join-Path $ContractServerExitRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($ContractServerExitEvidence.failure_details.process_role -eq 'server' -and $ContractServerExitEvidence.failure_details.observed_stage -eq 'observation' -and $ContractServerExitEvidence.failure_details.exit_code -eq 0) 'Server exit evidence must normalize server role, observation stage, and exit code.'
	Write-Output 'PASS: lifecycle, identity, timeout, and role-specific contract failures produce normalized evidence'

	$EarlyExitLogRoot = Join-Path $FixtureRoot 'early-exit-after-markers'
	$EarlyExitFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot $EarlyExitLogRoot -FixtureRunId 'fixture-early-exit' -RejectionReason 'malformed-intent' -DurationSeconds 3 -ExitAfterMarkers $true
	} catch { $EarlyExitFailure = $_.Exception.Message }
	Assert-True ($EarlyExitFailure -match "(Process exited with code 0 while waiting|Required process 'server' exited unexpectedly with code 0)") 'A server that exits after emitting all markers must fail before the run can pass.'
	$EarlyExitEvidencePath = Join-Path $EarlyExitLogRoot 'network-authority-spike-evidence.json'
	Assert-True (Test-Path -LiteralPath $EarlyExitEvidencePath -PathType Leaf) 'An early required-process exit must still write evidence.'
	$EarlyExitEvidence = Get-Content -LiteralPath $EarlyExitEvidencePath -Raw | ConvertFrom-Json
	Assert-True ($EarlyExitEvidence.result -eq 'failed') 'An early required-process exit must produce failed evidence.'
	Assert-True ($EarlyExitEvidence.failure -match "(Process exited with code 0 while waiting|Required process 'server' exited unexpectedly with code 0)") 'Failed evidence must preserve the early-exit reason.'
	Write-Output 'PASS: a runtime child that exits after all markers is rejected during the observation interval'

	$LauncherLogRoot = Join-Path $FixtureRoot 'launcher-success'
	Invoke-FixtureRun -FixtureLogRoot $LauncherLogRoot -FixtureRunId 'fixture-launcher' -RejectionReason 'malformed-intent' -DurationSeconds 1 -ExitAfterMarkers $false -UseLauncher $true
	$LauncherEvidence = Get-Content -LiteralPath (Join-Path $LauncherLogRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($LauncherEvidence.result -eq 'fixture-passed') 'The explicit server launcher topology must preserve fixture validation without claiming packaged success.'
	$LauncherDescendants = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
		$_.ExecutablePath -eq $PowerShellExecutable -and
		$_.CommandLine -and
		$_.CommandLine.IndexOf($FakeRuntime, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
	})
	Assert-True ($LauncherDescendants.Count -eq 0) 'Launcher-side server descendants must be confirmed stopped, not merely detached from the launcher.'
	Write-Output 'PASS: explicit Linux-server launcher indirection remains hidden, redirected, monitored, provenance-ready, and descendant-cleaned'

	$env:AETHELN_TEST_CLEANUP_FAIL = 'true'
	$CleanupFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'cleanup-failure') -FixtureRunId 'fixture-cleanup-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -UseContracts $true
	} catch { $CleanupFailure = $_.Exception.Message }
	Remove-Item -LiteralPath Env:AETHELN_TEST_CLEANUP_FAIL -ErrorAction Ignore
	Assert-True ($CleanupFailure -match 'server descendant cleanup.*exited with code 42') "A launcher-side cleanup failure must fail the run. Actual: $CleanupFailure"
	$CleanupFailureEvidence = Get-Content -LiteralPath (Join-Path $FixtureRoot 'cleanup-failure/network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($CleanupFailureEvidence.schema_version -eq 2 -and $CleanupFailureEvidence.result -eq 'failed') 'Cleanup failure must downgrade otherwise complete contract evidence to failed.'
	Assert-True ($CleanupFailureEvidence.failure_details.observed_stage -eq 'cleanup' -and $CleanupFailureEvidence.failure_details.process_role -eq 'server' -and $CleanupFailureEvidence.failure_details.cleanup_attempted -and -not $CleanupFailureEvidence.failure_details.cleanup_succeeded) 'Cleanup failure evidence must identify the cleanup stage, server role, attempt, and outcome.'
	Write-Output 'PASS: launcher-side descendant cleanup failure is observable and fails closed'

	$env:AETHELN_TEST_CLEANUP_FAIL = 'true'
	$CombinedFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'combined-primary-and-cleanup-failure') -FixtureRunId 'fixture-combined-primary-and-cleanup-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -Behavior 'missing-death' -BoundaryTimeoutDescription 'authoritative death' -UseLauncher $true -UseContracts $true
	} catch { $CombinedFailure = $_.Exception.Message }
	Remove-Item -LiteralPath Env:AETHELN_TEST_CLEANUP_FAIL -ErrorAction Ignore
	Assert-True ($CombinedFailure -match 'waiting for authoritative death') "The combined failure fixture must preserve the primary execution exception. Actual: $CombinedFailure"
	$CombinedFailureEvidence = Get-Content -LiteralPath (Join-Path $FixtureRoot 'combined-primary-and-cleanup-failure/network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($CombinedFailureEvidence.failure -ceq 'stage=death;role=server;reason=timeout') 'A cleanup failure must not replace the primary public failure location.'
	Assert-True ($CombinedFailureEvidence.failure_details.observed_stage -eq 'death' -and $CombinedFailureEvidence.failure_details.process_role -eq 'server' -and $CombinedFailureEvidence.failure_details.client_id -eq 'client-2') 'A cleanup failure must not replace the primary stage, role, or client identity.'
	Assert-True ($CombinedFailureEvidence.failure_details.cleanup_attempted -and -not $CombinedFailureEvidence.failure_details.cleanup_succeeded -and $CombinedFailureEvidence.failure_details.cleanup_failure -ceq 'stage=cleanup;role=server;reason=cleanup-failed') 'The combined failure must record cleanup only through its normalized cleanup fields.'
	Write-Output 'PASS: combined primary execution and cleanup failures preserve the primary failure location'

	$PowerShellArchive = Split-Path -Parent $PowerShellExecutable
	$PowerShellInventoryPath = [System.IO.Path]::GetFileName($PowerShellExecutable)
	$ClientSha256 = (Get-FileHash -LiteralPath $PowerShellExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
	$RunnerTokens = $null
	$RunnerParseErrors = $null
	$RunnerAst = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref] $RunnerTokens, [ref] $RunnerParseErrors)
	Assert-True ($RunnerParseErrors.Count -eq 0) 'The authority runner must parse before its path-comparison helper is inspected.'
	$ComparisonFunction = @($RunnerAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Get-ProvenancePathComparison' }, $true))
	Assert-True ($ComparisonFunction.Count -eq 1) 'The authority runner must define one OS-aware provenance path-comparison helper.'
	$ComparisonProbe = [scriptblock]::Create($ComparisonFunction[0].Extent.Text + "`n[pscustomobject]@{ Windows = Get-ProvenancePathComparison ([char] 92); Posix = Get-ProvenancePathComparison ([char] 47) }")
	$ComparisonResult = & $ComparisonProbe
	Assert-True ($ComparisonResult.Windows -eq [System.StringComparison]::OrdinalIgnoreCase) 'Windows provenance containment must be case-insensitive.'
	Assert-True ($ComparisonResult.Posix -eq [System.StringComparison]::Ordinal) 'Case-sensitive hosts must use ordinal provenance containment.'
	Write-Output 'PASS: provenance containment selects OS-appropriate case sensitivity'
	function Write-ProvenanceFixture([string] $Path, [object[]] $Inventory, [string] $ClientArchive = $PowerShellArchive, [string] $ServerArchive = $PowerShellArchive) {
		[ordered]@{
			schemaVersion = 2
			source = [ordered]@{ revision = 'fixture-revision'; clean = $true }
			host = [ordered]@{ buildIdentity = 'fixture-build' }
			artifacts = [ordered]@{
				clientArchive = $ClientArchive
				serverArchive = $ServerArchive
				inventory = @($Inventory)
			}
		} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
	}

	$MissingHostPathProvenance = Join-Path $FixtureRoot 'missing-host-path-provenance.json'
	Write-ProvenanceFixture $MissingHostPathProvenance @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$MissingHostPathFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'missing-host-path') -FixtureRunId 'fixture-missing-host-path' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $MissingHostPathProvenance
	} catch { $MissingHostPathFailure = $_.Exception.Message }
	Assert-True ($MissingHostPathFailure -match 'ServerProvenanceExecutable is required') 'Packaged launcher evidence must require an explicit host-side server provenance path.'
	Write-Output 'PASS: packaged launcher provenance requires an explicit host-side server path'

	$ProvenancePath = Join-Path $FixtureRoot 'mismatched-server-provenance.json'
	Write-ProvenanceFixture $ProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = ('0' * 64) }
	)
	$ServerIdentityFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'server-identity-mismatch') -FixtureRunId 'fixture-server-identity-mismatch' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $ProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ServerIdentityFailure = $_.Exception.Message }
	Assert-True ($ServerIdentityFailure -match 'Packaged executable identity is not uniquely bound') 'Packaged evidence must hash and authenticate the exact launcher-side server path.'
	Write-Output 'PASS: mismatched launcher-side server digest cannot use unrelated packaged provenance'

	$MismatchedClientProvenancePath = Join-Path $FixtureRoot 'mismatched-client-path-provenance.json'
	Write-ProvenanceFixture $MismatchedClientProvenancePath @(
		[ordered]@{ kind = 'client'; path = 'unrelated/powershell.exe'; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$ClientPathFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'client-path-mismatch') -FixtureRunId 'fixture-client-path-mismatch' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $MismatchedClientProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ClientPathFailure = $_.Exception.Message }
	Assert-True ($ClientPathFailure -match 'Packaged executable identity is not uniquely bound') 'Packaged evidence must bind the exact selected-client path, not only filename and digest.'
	Write-Output 'PASS: same-named client at an unrelated path cannot use packaged provenance'

	foreach ($UnsafeInventoryCase in @(
		@{ Name = 'rooted'; Path = $PowerShellExecutable },
		@{ Name = 'escape'; Path = '../powershell.exe' },
		@{ Name = 'dot-alias'; Path = "./$PowerShellInventoryPath" },
		@{ Name = 'parent-alias'; Path = "unused/../$PowerShellInventoryPath" }
	)) {
		$UnsafeProvenancePath = Join-Path $FixtureRoot ("unsafe-$($UnsafeInventoryCase.Name)-provenance.json")
		Write-ProvenanceFixture $UnsafeProvenancePath @(
			[ordered]@{ kind = 'client'; path = $UnsafeInventoryCase.Path; sha256 = $ClientSha256 },
			[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
		)
		$UnsafeFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot ("unsafe-$($UnsafeInventoryCase.Name)")) -FixtureRunId ("fixture-unsafe-$($UnsafeInventoryCase.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $UnsafeProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
		} catch { $UnsafeFailure = $_.Exception.Message }
		Assert-True ($UnsafeFailure -match 'archive-relative') "A $($UnsafeInventoryCase.Name) inventory path must fail closed. Actual: $UnsafeFailure"
	}
	Write-Output 'PASS: rooted and escaping provenance inventory paths fail closed'

	$ClientArchiveParent = Split-Path -Parent $PowerShellArchive
	$ClientArchiveDirectory = Split-Path -Leaf $PowerShellArchive
	$SeparatorAliasProvenancePath = Join-Path $FixtureRoot 'separator-alias-provenance.json'
	Write-ProvenanceFixture $SeparatorAliasProvenancePath @(
		[ordered]@{ kind = 'client'; path = "$ClientArchiveDirectory\$PowerShellInventoryPath"; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	) -ClientArchive $ClientArchiveParent
	$SeparatorAliasFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'separator-alias') -FixtureRunId 'fixture-separator-alias' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $SeparatorAliasProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $SeparatorAliasFailure = $_.Exception.Message }
	Assert-True ($SeparatorAliasFailure -match 'exact canonical archive-relative path') 'Backslash-separated inventory aliases must fail closed.'
	Write-Output 'PASS: provenance inventory paths require canonical forward slashes'

	$OutsideRootProvenancePath = Join-Path $FixtureRoot 'outside-root-provenance.json'
	Write-ProvenanceFixture $OutsideRootProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	) -ServerArchive $FixtureRoot
	$OutsideRootFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'outside-root') -FixtureRunId 'fixture-outside-root' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $OutsideRootProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $OutsideRootFailure = $_.Exception.Message }
	Assert-True ($OutsideRootFailure -match 'ServerProvenanceExecutable.*serverArchive') 'The host-side server provenance path must remain beneath serverArchive.'
	Write-Output 'PASS: host-side server provenance path outside serverArchive fails closed'

	$LinkedServerArchive = Join-Path $FixtureRoot 'linked-server-archive'
	$LinkedServerTarget = Join-Path $LinkedServerArchive 'linked'
	New-Item -ItemType Directory -Path $LinkedServerArchive -Force | Out-Null
	$LinkItemType = if ([System.IO.Path]::DirectorySeparatorChar -ceq '\') { 'Junction' } else { 'SymbolicLink' }
	New-Item -ItemType $LinkItemType -Path $LinkedServerTarget -Target $PowerShellArchive | Out-Null
	$LinkedServerProvenancePath = Join-Path $FixtureRoot 'linked-server-provenance.json'
	Write-ProvenanceFixture $LinkedServerProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
	) -ServerArchive $LinkedServerArchive
	$LinkedServerFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'linked-server') -FixtureRunId 'fixture-linked-server' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $LinkedServerProvenancePath -ServerProvenanceExecutable (Join-Path $LinkedServerTarget $PowerShellInventoryPath)
	} catch { $LinkedServerFailure = $_.Exception.Message }
	Assert-True ($LinkedServerFailure -match 'reparse point') 'A host-side server provenance path traversing a filesystem link must fail closed.'
	Write-Output 'PASS: host-side server provenance path cannot escape through a filesystem link'

	$InventoryLinkedServerArchive = Join-Path $FixtureRoot 'inventory-linked-server-archive'
	$InventoryLinkedServerExecutable = Join-Path $InventoryLinkedServerArchive 'server.exe'
	$InventoryLinkedTarget = Join-Path $InventoryLinkedServerArchive 'linked'
	New-Item -ItemType Directory -Path $InventoryLinkedServerArchive -Force | Out-Null
	Copy-Item -LiteralPath $PowerShellExecutable -Destination $InventoryLinkedServerExecutable
	New-Item -ItemType $LinkItemType -Path $InventoryLinkedTarget -Target $PowerShellArchive | Out-Null
	$InventoryLinkedProvenancePath = Join-Path $FixtureRoot 'inventory-linked-provenance.json'
	Write-ProvenanceFixture $InventoryLinkedProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = 'server.exe'; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
	) -ServerArchive $InventoryLinkedServerArchive
	$InventoryLinkedFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'inventory-linked') -FixtureRunId 'fixture-inventory-linked' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $InventoryLinkedProvenancePath -ServerProvenanceExecutable $InventoryLinkedServerExecutable
	} catch { $InventoryLinkedFailure = $_.Exception.Message }
	Assert-True ($InventoryLinkedFailure -match 'reparse point') 'Every provenance inventory entry must fail closed when it traverses a filesystem link.'
	Write-Output 'PASS: every provenance inventory entry rejects filesystem-link escape'

	foreach ($InvalidKind in @('auxiliary', 'CLIENT', 'SERVER')) {
		$InvalidKindProvenancePath = Join-Path $FixtureRoot ("invalid-kind-$InvalidKind-provenance.json")
		Write-ProvenanceFixture $InvalidKindProvenancePath @(
			[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
			[ordered]@{ kind = 'server'; path = 'server.exe'; sha256 = $ClientSha256 },
			[ordered]@{ kind = $InvalidKind; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
		) -ServerArchive $InventoryLinkedServerArchive
		$InvalidKindFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot ("invalid-kind-$InvalidKind")) -FixtureRunId ("fixture-invalid-kind-$InvalidKind") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $InvalidKindProvenancePath -ServerProvenanceExecutable $InventoryLinkedServerExecutable
		} catch { $InvalidKindFailure = $_.Exception.Message }
		Assert-True ($InvalidKindFailure -match 'kind must be client or server') "Invalid provenance inventory kind '$InvalidKind' must fail closed."
	}
	Write-Output 'PASS: provenance inventory kinds require exact lowercase client or server'

	$DuplicateProvenancePath = Join-Path $FixtureRoot 'duplicate-provenance.json'
	Write-ProvenanceFixture $DuplicateProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$DuplicateFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'duplicate-provenance') -FixtureRunId 'fixture-duplicate-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $DuplicateProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $DuplicateFailure = $_.Exception.Message }
	Assert-True ($DuplicateFailure -match 'Packaged executable identity is not uniquely bound') 'Duplicate matching inventory entries must fail closed.'
	Write-Output 'PASS: duplicate matching provenance entries fail closed'

	$ConflictingDigestProvenancePath = Join-Path $FixtureRoot 'conflicting-digest-provenance.json'
	Write-ProvenanceFixture $ConflictingDigestProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = ('0' * 64) }
	)
	$ConflictingDigestFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'conflicting-digest-provenance') -FixtureRunId 'fixture-conflicting-digest-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $ConflictingDigestProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ConflictingDigestFailure = $_.Exception.Message }
	Assert-True ($ConflictingDigestFailure -match 'Packaged executable identity is not uniquely bound') 'Conflicting digests for one kind and relative path must fail closed.'
	Write-Output 'PASS: conflicting provenance digests for one artifact identity fail closed'

	$WrongKindProvenancePath = Join-Path $FixtureRoot 'wrong-kind-provenance.json'
	Write-ProvenanceFixture $WrongKindProvenancePath @(
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'client'; path = 'unrelated/powershell.exe'; sha256 = $ClientSha256 }
	)
	$WrongKindFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'wrong-kind-provenance') -FixtureRunId 'fixture-wrong-kind-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $WrongKindProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $WrongKindFailure = $_.Exception.Message }
	Assert-True ($WrongKindFailure -match 'Packaged executable identity is not uniquely bound') 'Wrong-kind provenance entries must fail closed.'
	Write-Output 'PASS: wrong-kind provenance entries fail closed'

	$SelfAuthoredProvenancePath = Join-Path $FixtureRoot 'self-authored-provenance.json'
	Write-ProvenanceFixture $SelfAuthoredProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$SelfAuthoredRoot = Join-Path $FixtureRoot 'self-authored-packaged'
	Invoke-FixtureRun -FixtureLogRoot $SelfAuthoredRoot -FixtureRunId 'fixture-self-authored' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $SelfAuthoredProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	$SelfAuthoredEvidence = Get-Content -LiteralPath (Join-Path $SelfAuthoredRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($SelfAuthoredEvidence.result -eq 'packaged-candidate') 'Even matching caller-authored provenance can produce only a candidate awaiting independent gates.'
	Assert-True ($SelfAuthoredEvidence.result -ne 'passed') 'The runner must never self-award packaged success.'
	Write-Output 'PASS: self-authored matching provenance cannot self-award packaged success'

	$PackagedLocalFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'packaged-local') -FixtureRunId 'fixture-packaged-local' -RejectionReason 'malformed-intent' -DurationSeconds 1 -EvidenceMode 'packaged' -FixtureEnvironment 'local'
	} catch { $PackagedLocalFailure = $_.Exception.Message }
	Assert-True ($PackagedLocalFailure -match 'Packaged authority evidence must use the development environment') 'Packaged multiplayer evidence must reject the local environment before launch.'
	Write-Output 'PASS: packaged authority evidence requires the explicit development environment'

	$NegativeScenarios = @(
		@{ Name = 'missing'; Behavior = 'missing-damage'; Failure = 'waiting for authoritative damage' },
		@{ Name = 'duplicate'; Behavior = 'duplicate-damage'; Failure = 'Expected exactly one damage-application record, observed 2' },
		@{ Name = 'mismatched'; Behavior = 'mismatched-run'; Failure = 'waiting for authoritative damage' },
		@{ Name = 'reordered'; Behavior = 'reordered'; Failure = 'reordered before authoritative damage' },
		@{ Name = 'missing-disconnect'; Behavior = 'missing-disconnect'; Failure = 'waiting for disconnect cleanup' },
		@{ Name = 'missing-reconnect'; Behavior = 'missing-reconnect'; Failure = 'waiting for new reconnect identity' },
		@{ Name = 'reordered-lifecycle'; Behavior = 'reordered-lifecycle'; Failure = 'Authority rejection, disconnect, and reconnect observations were reordered' },
		@{ Name = 'reused'; Behavior = 'reused-connection'; Failure = 'Reconnect reused the disconnected connection identity' },
		@{ Name = 'fabricated-disconnected-command'; Behavior = 'fabricated-disconnected-command'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'delayed-fabricated-disconnected-command'; Behavior = 'delayed-fabricated-disconnected-command'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'fabricated-disconnected-command-stderr'; Behavior = 'fabricated-disconnected-command-stderr'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'unexpected-rejection-category'; Behavior = 'unexpected-rejection-category'; Failure = "Unexpected authority rejection category 'unexpected'" }
	)
	foreach ($Scenario in $NegativeScenarios) {
		$NegativeFailure = $null
		try { Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot $Scenario.Name) -FixtureRunId ("fixture-" + $Scenario.Name) -RejectionReason 'malformed-intent' -DurationSeconds 1 -ExitAfterMarkers $false -UseLauncher $false -Behavior $Scenario.Behavior } catch { $NegativeFailure = $_.Exception.Message }
		Assert-True ($NegativeFailure -match [regex]::Escape($Scenario.Failure)) "$($Scenario.Name) evidence must fail closed. Actual: $NegativeFailure"
	}
	Write-Output 'PASS: missing, duplicate, mismatched-run, reordered, lifecycle, reused-connection, and fabricated-command evidence fails closed'

	$env:AETHELN_TEST_LAUNCHER_FAIL = 'true'
	$LauncherFailure = $null
	try { Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'launcher-failure') -FixtureRunId 'fixture-launcher-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -ExitAfterMarkers $false -UseLauncher $true -Behavior 'normal' } catch { $LauncherFailure = $_.Exception.Message }
	Remove-Item -LiteralPath Env:AETHELN_TEST_LAUNCHER_FAIL -ErrorAction Ignore
	Assert-True ($LauncherFailure -match 'Process exited with code 41 while waiting for server descendant process identity') "A launcher failure must fail before gameplay evidence can pass. Actual: $LauncherFailure"
	Write-Output 'PASS: launcher failure cannot fabricate a successful authority capture'

	$FabricatedPackagedFailure = $null
	try {
		$FabricatedArgs = @{
			ServerExecutable = $PowerShellExecutable; ServerArguments = @('-NoProfile','-File',$FakeRuntime,'server','server','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}','{NetworkConfigIdentity}','{Environment}','normal','malformed-intent','false')
			ClientExecutable = $PowerShellExecutable; ClientArguments = @('-NoProfile','-File',$FakeRuntime,'client','{ClientId}','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}','{NetworkConfigIdentity}','{Environment}')
			ServerEndpoint = '127.0.0.1:7777'; ServerMap = '/Game/Maps/StarterMap'; ScenarioId = 'network-authority.baseline.v1'; ProfileId = 'network-profile.unset'; NetworkConfigIdentity = 'network-emulation.caller-supplied'; RunId = 'fabricated-packaged'
			Environment = 'development'
			SourceRevision = 'fixture-revision'; BuildIdentity = 'fixture-build'; ToolchainIdentity = 'fixture-toolchain'; HardwareIdentity = 'fixture-host'; TopologyIdentity = 'fixture-topology'; ActorMixIdentity = 'network-authority.actor-mix.v1'; EvidenceMode = 'packaged'; DurationSeconds = 1; LogRoot = (Join-Path $FixtureRoot 'fabricated-packaged')
			ServerReadyPattern = 'AUTHORITY server_ready.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ServerConnectionPattern = 'AUTHORITY connection client=(?<ClientId>[^ ]+) connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ClientReadyPattern = 'AUTHORITY client_ready client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; MovementPattern = 'AUTHORITY movement client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; EnemyPattern = 'AUTHORITY enemy_spawned.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; MeleePattern = 'AUTHORITY melee_resolved.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; DamagePattern = 'AUTHORITY damage_applied.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; JoinInProgressPattern = 'AUTHORITY join_in_progress.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; DisconnectPattern = 'AUTHORITY disconnected.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ReconnectPattern = 'AUTHORITY reconnected.*connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; NetworkConfigPattern = 'AUTHORITY network_config.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
		}
		& $Script @FabricatedArgs
	} catch { $FabricatedPackagedFailure = $_.Exception.Message }
	Assert-True ($FabricatedPackagedFailure -match 'PackagedBuildProvenancePath is required') 'Fake marker processes cannot claim packaged success without exact build provenance.'
	Write-Output 'PASS: fixture output cannot masquerade as provenance-bound packaged evidence'

	foreach ($InvalidReason in @('duplicate_sequence', 'unknown-reason')) {
		$InvalidReasonLogRoot = Join-Path $FixtureRoot "invalid-rejection-$InvalidReason"
		$RejectionFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot $InvalidReasonLogRoot -FixtureRunId "fixture-$InvalidReason" -RejectionReason $InvalidReason
		} catch { $RejectionFailure = $_.Exception.Message }
		Assert-True ($RejectionFailure -match [regex]::Escape("Unsupported rejection reason '$InvalidReason'.")) "Rejection reason '$InvalidReason' must fail closed."
		$InvalidEvidence = Get-Content -LiteralPath (Join-Path $InvalidReasonLogRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
		Assert-True ($InvalidEvidence.result -eq 'failed') "Invalid rejection reason '$InvalidReason' must produce failed evidence."
		Assert-True (@($InvalidEvidence.rejections | Where-Object { $_.reason -eq $InvalidReason }).Count -eq 0) "Invalid rejection reason '$InvalidReason' must not be accepted into evidence."
	}
	Write-Output 'PASS: rejection reason vocabulary accepts stable hyphenated values and rejects unsafe spellings'

	$Failure = $null
	try {
		& $Script -ServerExecutable $PowerShellExecutable -ServerArguments @('{ServerEndpoint}', '{ServerMap}') -ClientExecutable $PowerShellExecutable -ClientArguments @('{ClientId}') -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' -ScenarioId 'network-authority.baseline.v1' -ProfileId 'network-profile.unset' -NetworkConfigIdentity 'network-emulation.caller-supplied' -RunId 'invalid' -Environment 'local' -SourceRevision 'revision' -BuildIdentity 'build' -ToolchainIdentity 'toolchain' -HardwareIdentity 'hardware' -TopologyIdentity 'topology' -ActorMixIdentity 'network-authority.actor-mix.v1' -EvidenceMode 'fixture' -DurationSeconds 1 -LogRoot (Join-Path $FixtureRoot 'invalid') -ServerReadyPattern 'ready' -ServerConnectionPattern 'connection' -ClientReadyPattern 'ready' -MovementPattern 'movement' -EnemyPattern 'enemy' -MeleePattern 'melee' -DamagePattern 'damage' -JoinInProgressPattern 'join' -DisconnectPattern 'disconnect' -ReconnectPattern 'reconnect' -NetworkConfigPattern 'network'
	} catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'ServerArguments must contain.*ScenarioId') 'Missing correlation placeholders must fail before launch.'
	Write-Output 'PASS: incomplete launch correlation fails closed'
	$FixtureSucceeded = $true
}
finally {
	foreach ($FixtureProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
		try { $ProcessPath = [string] $FixtureProcess.Path } catch { continue }
		if ($ProcessPath -and $ProcessPath.StartsWith($FixtureRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
			Stop-Process -Id $FixtureProcess.Id -Force -ErrorAction SilentlyContinue
		}
	}
	if ($FixtureSucceeded) {
		if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
	} else {
		Write-Output "Failed network-authority fixtures retained at '$FixtureRoot'."
	}
}
