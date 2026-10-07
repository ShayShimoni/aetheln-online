[CmdletBinding()]
param([switch] $SequenceOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Build.ps1')
function Assert-BuildTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-BuildRejected {
	param([scriptblock] $Action, [string] $Reason)
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-BuildTest -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; received $Failure"
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnBuildFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$Attempt = New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ([guid]::NewGuid().ToString('N'))
$Capacity = [pscustomobject]@{ physicalCores = 8; availablePhysicalRamGiB = 24.0; commitHeadroomGiB = 24.0; volumes = @([pscustomobject]@{ availableBytes = 100GB; knownAllocationBytes = 0L; recoveryFloorBytes = 20GB }) }

function Test-BuildSequence {
	# These mocks are local to this function; the real child transport is tested below.
	function Invoke-InitialPreparationUbtReadiness {
		param($Attempt, $Lease, $EngineRoot, $EvidenceRoot, $Roots, $OnSample, $KnownAllocations)
		Assert-BuildTest -Condition ($Attempt.targetRevision -ceq ('b' * 40) -and $Lease.leaseId -and $EngineRoot -ceq $FixtureRoot -and (Test-Path -LiteralPath $EvidenceRoot -PathType Container) -and $Roots.Count -eq 1 -and $OnSample -is [scriptblock] -and $KnownAllocations.Count -eq 0) -Message 'Readiness integration arguments changed'
		$State.readinessCalls++
		if ($State.mode -ceq 'ubt_failure') { throw 'ubt_dependencies_changed' }
		return [pscustomobject]@{ schemaVersion = 1; attemptId = $Attempt.attemptId; targetRevision = $Attempt.targetRevision;
			scope = 'ubt_dependency_rebuild_branch'; ready = $true; cleanupVerified = ($State.mode -cne 'ubt_unproven');
			scanExitCode = 0; comparisonExitCode = 0; failureCode = $null; dependencySha256 = ('c' * 64); scanSha256 = ('c' * 64) }
	}
	function Get-InitialPreparationCapacity {
		param($Roots, $Attempt, $KnownAllocations)
		Assert-BuildTest -Condition ($Roots.Count -eq 1 -and $Attempt.targetRevision -ceq ('b' * 40) -and $KnownAllocations.Count -eq 0) -Message 'Capacity arguments changed'
		return $Capacity
	}
	function Invoke-InitialPreparationSingleBuild {
		param($Attempt, $Lease, $EngineRoot, $TargetRoot, $LinuxToolchainRoot, $EvidenceRoot, $Target, $Platform, $ActionLimit, $Roots, $KnownAllocations, $OnSample)
		Assert-BuildTest -Condition ($Attempt.targetRevision -ceq ('b' * 40) -and $Lease.leaseId -and $EngineRoot -ceq $FixtureRoot -and $TargetRoot -ceq $FixtureRoot -and $LinuxToolchainRoot -ceq $FixtureRoot -and (Test-Path -LiteralPath $EvidenceRoot -PathType Container) -and $Platform -in @('Win64', 'Linux') -and $ActionLimit -eq 4 -and $Roots.Count -eq 1 -and $KnownAllocations.Count -eq 0 -and $OnSample -is [scriptblock]) -Message 'Build invocation arguments changed'
		[void] $State.calls.Add($Target)
		if ($State.mode -ceq 'infra' -or ($State.mode -ceq 'late_failure' -and $State.calls.Count -eq 3)) { throw 'fixture_monitor_failure' }
		return [pscustomobject]@{ nativeExitCode = $(if ($State.mode -ceq 'native') { 7 } else { 0 }); cleanupVerified = $true }
	}
	foreach ($Mode in @('success', 'native', 'infra', 'drift', 'readiness', 'late_failure', 'ubt_failure', 'ubt_unproven')) {
		$State = @{ calls = (New-Object Collections.ArrayList); reads = 0; readinessCalls = 0; mode = $Mode }
		$Evidence = Join-Path $FixtureRoot $Mode
		$null = New-Item -ItemType Directory -Path $Evidence
		$Inputs = { $State.reads++; if ($State.mode -ceq 'drift' -and $State.reads -gt 1) { return ('e' * 64) }; return ('d' * 64) }
		$Readiness = { return ($State.mode -cne 'readiness') }
		$Parameters = @{ Attempt = $Attempt; Lease = $SequenceLease; EngineRoot = $FixtureRoot; TargetRoot = $FixtureRoot; LinuxToolchainRoot = $FixtureRoot; EvidenceRoot = $Evidence; InputDigest = ('d' * 64); Roots = @{ test = $FixtureRoot }; ValidateInputs = $Inputs; AssertReadiness = $Readiness; OnSample = {} }
		if ($Mode -ceq 'success') {
			$Results = Invoke-InitialPreparationBuildSequence @Parameters
			Assert-BuildTest -Condition ($Results.Count -eq 6 -and $State.calls.Count -eq 6 -and $State.reads -eq 12) -Message 'Six builds and twelve identity checks required'
			Assert-BuildTest -Condition ($State.readinessCalls -eq 6) -Message 'Each target must have a current UBT readiness probe'
			foreach ($Built in $Results) { Assert-BuildTest -Condition ($Built.ubtReadiness.ready -and $Built.ubtReadiness.cleanupVerified -and $Built.ubtReadiness.scope -ceq 'ubt_dependency_rebuild_branch') -Message 'UBT readiness evidence missing from sequence result' }
			Assert-BuildTest -Condition (($Results.ordinal -join ',') -ceq '1,2,3,4,5,6') -Message 'Ordinal evidence changed'
			Assert-BuildTest -Condition (Test-InitialPreparationBuildSequence -Builds $Results -Attempt $Attempt -InputDigest ('d' * 64)) -Message 'Production Core rejects build sequence evidence'
			foreach ($Timed in $Results) { Assert-BuildTest -Condition ($Timed.finishedTicks -ge $Timed.startedTicks -and $Timed.executorFlags.Count -eq 6) -Message 'Timing/executor evidence missing' }
			Assert-BuildTest -Condition (($State.calls -join ',') -ceq ((@('AethelnOnlineClient', 'AethelnOnlineServer') * 3) -join ',')) -Message 'Client/server ordering changed'
		} else {
			$Reason = @{ native = 'build_failed'; infra = 'fixture_monitor_failure'; drift = 'build_input_drift'; readiness = 'build_readiness_unproven'; late_failure = 'fixture_monitor_failure'; ubt_failure = 'ubt_dependencies_changed'; ubt_unproven = 'build_ubt_readiness_unproven' }[$Mode]
			Assert-BuildRejected -Action { Invoke-InitialPreparationBuildSequence @Parameters } -Reason $Reason
			Assert-BuildTest -Condition ($State.calls.Count -eq $(if ($Mode -ceq 'late_failure') { 3 } elseif ($Mode -in @('readiness', 'ubt_failure', 'ubt_unproven')) { 0 } else { 1 })) -Message 'Failure started another build'
		}
		$SummaryPath = Join-Path $Evidence 'sequence-result.json'
		Assert-BuildTest -Condition (Test-Path -LiteralPath $SummaryPath -PathType Leaf) -Message 'Sequence evidence missing after completion or failure'
		$Summary = Get-Content -LiteralPath $SummaryPath -Raw | ConvertFrom-Json
		Assert-BuildTest -Condition ($Summary.attemptId -ceq $Attempt.attemptId -and $Summary.targetRevision -ceq $Attempt.targetRevision -and $Summary.baselineVerified -eq $false) -Message 'Sequence evidence identity or acceptance claim invalid'
		Assert-BuildTest -Condition ($Summary.complete -eq ($Mode -ceq 'success') -and @($Summary.builds).Count -eq $(if ($Mode -ceq 'success') { 6 } elseif ($Mode -ceq 'late_failure') { 2 } else { 0 })) -Message 'Partial sequence misclassified'
		if ($Mode -cne 'success') { Assert-BuildTest -Condition ($Summary.failureCode -ceq $Reason) -Message 'Sequence failure evidence missing' }
	}
}
function Test-BuildReadinessCapacity {
	function Get-InitialPreparationCapacity {
		param($Roots, $Attempt, $KnownAllocations)
		Assert-BuildTest -Condition ($Roots.test -ceq $FixtureRoot -and $Attempt.targetRevision -ceq ('b' * 40) -and $KnownAllocations.Count -eq 0) -Message 'Readiness capacity fixture arguments changed'
		[void] $Observation.events.Add('capacity-' + $Observation.stage)
		$Ram = if ($Observation.stage -ceq 'after') { 12.0 } else { 24.0 }
		$Free = if ($Observation.mode -ceq 'pre_floor' -or ($Observation.mode -ceq 'post_floor' -and $Observation.stage -ceq 'after')) { 20GB } else { 100GB }
		return [pscustomobject]@{ physicalCores = 8; availablePhysicalRamGiB = $Ram; commitHeadroomGiB = $Ram;
			volumes = @([pscustomobject]@{ availableBytes = $Free; knownAllocationBytes = 0L; recoveryFloorBytes = 20GB }) }
	}
	function Invoke-InitialPreparationUbtReadiness {
		param($Attempt, $Lease, $EngineRoot, $EvidenceRoot, $Roots, $OnSample, $KnownAllocations)
		Assert-BuildTest -Condition ($Attempt.targetRevision -ceq ('b' * 40) -and $Lease.leaseId -and $EngineRoot -ceq $FixtureRoot -and
			(Test-Path -LiteralPath $EvidenceRoot -PathType Container) -and $Roots.test -ceq $FixtureRoot -and
			$OnSample -is [scriptblock] -and $KnownAllocations.Count -eq 0) -Message 'Readiness capacity transport arguments changed'
		[void] $Observation.events.Add('readiness')
		$Observation.readinessCalls++
		$Observation.stage = 'after'
		return [pscustomobject]@{ schemaVersion = 1; attemptId = $Attempt.attemptId; targetRevision = $Attempt.targetRevision;
			scope = 'ubt_dependency_rebuild_branch'; ready = $true; cleanupVerified = $true; scanExitCode = 0; comparisonExitCode = 0;
			failureCode = $null; dependencySha256 = ('c' * 64); scanSha256 = ('c' * 64) }
	}
	function Invoke-InitialPreparationSingleBuild {
		param($Attempt, $Lease, $EngineRoot, $TargetRoot, $LinuxToolchainRoot, $EvidenceRoot, $Target, $Platform, $ActionLimit, $Roots, $KnownAllocations, $OnSample)
		Assert-BuildTest -Condition ($Attempt.targetRevision -ceq ('b' * 40) -and $Lease.leaseId -and $EngineRoot -ceq $FixtureRoot -and
			$TargetRoot -ceq $FixtureRoot -and $LinuxToolchainRoot -ceq $FixtureRoot -and (Test-Path -LiteralPath $EvidenceRoot -PathType Container) -and
			$Target -cin @('AethelnOnlineClient', 'AethelnOnlineServer') -and $Platform -cin @('Win64', 'Linux') -and $Roots.test -ceq $FixtureRoot -and
			$KnownAllocations.Count -eq 0 -and $OnSample -is [scriptblock]) -Message 'Readiness capacity build arguments changed'
		Assert-BuildTest -Condition ($ActionLimit -eq 2) -Message 'Readiness reduced RAM from 24 to 12 GiB but build retained the stale four-action limit'
		[void] $Observation.events.Add('build')
		[void] $Observation.limits.Add($ActionLimit)
		$Observation.stage = 'before'
		return [pscustomobject]@{ nativeExitCode = 0; cleanupVerified = $true }
	}
	foreach ($Mode in @('drop', 'pre_floor', 'post_floor', 'post_sample_failure')) {
		$Observation = @{ stage = 'before'; mode = $Mode; readinessCalls = 0; events = (New-Object Collections.ArrayList); limits = (New-Object Collections.ArrayList) }
		$Evidence = Join-Path $FixtureRoot ('capacity-' + $Mode)
		$null = New-Item -ItemType Directory -Path $Evidence
		$Sampler = {
			param($Sample)
			[void] $Observation.events.Add('sample-' + $Sample.availablePhysicalRamGiB)
			if ($Observation.mode -ceq 'post_sample_failure' -and $Observation.stage -ceq 'after') { throw 'fixture_boundary_monitor_failed' }
		}
		$Parameters = @{ Attempt = $Attempt; Lease = $SequenceLease; EngineRoot = $FixtureRoot; TargetRoot = $FixtureRoot;
			LinuxToolchainRoot = $FixtureRoot; EvidenceRoot = $Evidence; InputDigest = ('d' * 64); Roots = @{ test = $FixtureRoot };
			ValidateInputs = { return ('d' * 64) }; AssertReadiness = { return $true }; OnSample = $Sampler }
		if ($Mode -ceq 'drop') {
			$Results = Invoke-InitialPreparationBuildSequence @Parameters
			Assert-BuildTest -Condition ($Results.Count -eq 6 -and $Observation.limits.Count -eq 6 -and @($Results | Where-Object { $_.actionLimit -ne 2 }).Count -eq 0) -Message 'Each target must receive the refreshed capacity limit'
			$ExpectedEvents = @('capacity-before', 'sample-24', 'readiness', 'capacity-after', 'sample-12', 'build') * 6
			Assert-BuildTest -Condition (($Observation.events -join ',') -ceq ($ExpectedEvents -join ',')) -Message 'Capacity admission and evidence must occur both before readiness and immediately before build'
		} else {
			$Expected = if ($Mode -ceq 'post_sample_failure') { 'fixture_boundary_monitor_failed' } else { 'resource_admission_refused' }
			Assert-BuildRejected -Action { Invoke-InitialPreparationBuildSequence @Parameters } -Reason $Expected
			Assert-BuildTest -Condition ($Observation.limits.Count -eq 0 -and $Observation.readinessCalls -eq $(if ($Mode -ceq 'pre_floor') { 0 } else { 1 })) -Message 'Resource or sample failure launched another target'
			$Summary = Get-Content -LiteralPath (Join-Path $Evidence 'sequence-result.json') -Raw | ConvertFrom-Json
			Assert-BuildTest -Condition (-not $Summary.complete -and $Summary.failureCode -ceq $Expected -and @($Summary.builds).Count -eq 0) -Message 'Resource failure was not retained as incomplete sequence evidence'
		}
	}
	Write-Output 'PASS: build capacity is refreshed after UBT readiness and failures prevent target launch'
}
$SequenceLease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $FixtureRoot 'sequence.lease')
try { Test-BuildSequence; Test-BuildReadinessCapacity } finally {
	$null = Stop-InitialPreparationOwnedTree -Lease $SequenceLease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $SequenceLease
}
if ($SequenceOnly) { return }

# Actual lightweight native batch execution, never Unreal. Each fixture owns a
# new isolated fake engine/project root and lease, and retains its evidence.
foreach ($Native in @(0, 7)) {
	$NativeRoot = Join-Path $FixtureRoot ('native-' + $Native)
	$BatchRoot = Join-Path $NativeRoot 'Engine/Build/BatchFiles'
	$null = New-Item -ItemType Directory -Path $BatchRoot
	$DotnetRoot = Join-Path $NativeRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	$null = New-Item -ItemType Directory -Path $DotnetRoot
	[IO.File]::WriteAllText((Join-Path $DotnetRoot 'dotnet.exe'), 'fixture')
	$SearchGuard = 'if not "%NoDefaultCurrentDirectoryInExePath%"=="1" exit /b 87' + "`r`n"
	[IO.File]::WriteAllText((Join-Path $BatchRoot 'Build.bat'), "@echo off`r`n$SearchGuard" + "echo fixture-output`r`necho fixture-error 1>&2`r`necho %*`r`nif not `"%LINUX_MULTIARCH_ROOT%`"==`"$NativeRoot`" exit /b 94`r`nif not `"%UE_USE_SYSTEM_DOTNET%`"==`"0`" exit /b 93`r`nif not `"%UE_DOTNET_VERSION%`"==`"10.0`" exit /b 92`r`nif not `"%DOTNET_ROOT%`"==`"$DotnetRoot`" exit /b 91`r`nif not `"%UE_DOTNET_DIR%`"==`"$DotnetRoot`" exit /b 90`r`nif not `"%DOTNET_MULTILEVEL_LOOKUP%`"==`"0`" exit /b 89`r`nif not `"%DOTNET_ROLL_FORWARD%`"==`"LatestMajor`" exit /b 88`r`nexit /b $Native`r`n")
	[IO.File]::WriteAllText((Join-Path $NativeRoot 'AethelnOnline.uproject'), '{}')
	$NativeEvidence = Join-Path $NativeRoot 'evidence'
	$null = New-Item -ItemType Directory -Path $NativeEvidence
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $NativeRoot 'owner.lease')
	$OriginalSystemDotnet = [Environment]::GetEnvironmentVariable('UE_USE_SYSTEM_DOTNET', 'Process')
	try {
		[Environment]::SetEnvironmentVariable('UE_USE_SYSTEM_DOTNET', '1', 'Process')
		$Record = Invoke-InitialPreparationSingleBuild -Attempt $Attempt -Lease $Lease -EngineRoot $NativeRoot -TargetRoot $NativeRoot -LinuxToolchainRoot $NativeRoot -EvidenceRoot $NativeEvidence -Target AethelnOnlineClient -Platform Win64 -ActionLimit 1 -Roots @{ evidence = $NativeRoot } -OnSample { 'ignored_sample_output' }
		Assert-BuildTest -Condition ($Record.nativeExitCode -eq $Native -and $Record.cleanupVerified) -Message 'Native exit or cleanup lost'
		Assert-BuildTest -Condition ([Environment]::GetEnvironmentVariable('UE_USE_SYSTEM_DOTNET', 'Process') -ceq '1') -Message 'Build changed parent dotnet selection'
		$Log = [IO.File]::ReadAllText((Join-Path $NativeEvidence 'build.log'))
		Assert-BuildTest -Condition ($Log.Contains('fixture-output') -and $Log.Contains('fixture-error')) -Message 'Both streams required'
		foreach ($Flag in @('-UBA', '-UBADisableRemote', '-NoXGE', '-NoSNDBS', '-NoFASTBuild', '-MaxParallelActions=1', '-Compiler=VisualStudio2022', '-CompilerVersion=14.44.35207', '-WindowsSDKVersion=10.0.26100.0')) {
			Assert-BuildTest -Condition $Log.Contains($Flag) -Message "Missing supported local-only flag $Flag"
		}
		$OriginalLogHash = (Get-FileHash -LiteralPath (Join-Path $NativeEvidence 'build.log') -Algorithm SHA256).Hash
		Assert-BuildRejected -Action {
			Invoke-InitialPreparationSingleBuild -Attempt $Attempt -Lease $Lease -EngineRoot $NativeRoot -TargetRoot $NativeRoot -LinuxToolchainRoot $NativeRoot -EvidenceRoot $NativeEvidence -Target AethelnOnlineClient -Platform Win64 -ActionLimit 1 -Roots @{ evidence = $NativeRoot } -OnSample {}
		} -Reason 'build_result_invalid'
		Assert-BuildTest -Condition ((Get-FileHash -LiteralPath (Join-Path $NativeEvidence 'build.log') -Algorithm SHA256).Hash -ceq $OriginalLogHash) -Message 'Repeated invocation overwrote existing log'
		$MonitorEvidence = Join-Path $NativeRoot 'monitor-evidence'
		$null = New-Item -ItemType Directory -Path $MonitorEvidence
		Assert-BuildRejected -Action {
			Invoke-InitialPreparationSingleBuild -Attempt $Attempt -Lease $Lease -EngineRoot $NativeRoot -TargetRoot $NativeRoot -LinuxToolchainRoot $NativeRoot -EvidenceRoot $MonitorEvidence -Target AethelnOnlineClient -Platform Win64 -ActionLimit 1 -Roots @{ evidence = $NativeRoot } -OnSample { throw 'quarantine_changed' }
		} -Reason 'resource_evidence_failed'
		$Entry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })[0]
		foreach ($Job in $Entry.supervisedJobs) { Assert-BuildTest -Condition ($Job.ActiveCount -eq 0) -Message 'Monitor failure left owned descendants' }
	} finally {
		[Environment]::SetEnvironmentVariable('UE_USE_SYSTEM_DOTNET', $OriginalSystemDotnet, 'Process')
		$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		Exit-InitialPreparationLease -Lease $Lease
	}
}
# Per-target UBT flags (TA-020): the editor omits -Compiler= so it resolves the
# contributor toolchain enum for the shared engine tree and keeps the version
# pins; client and server arguments are unchanged. -NoEngineChanges stays off
# the editor until the TA-020 NetCore UHT regeneration follow-up lands: every
# CI editor run still relinks NetCore, so the flag would fail every run.
$FlagRoot = Join-Path $FixtureRoot 'target-flags'
$null = New-Item -ItemType Directory -Path (Join-Path $FlagRoot 'Engine/Build/BatchFiles'), (Join-Path $FlagRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64')
[IO.File]::WriteAllText((Join-Path $FlagRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $FlagRoot 'Engine/Build/BatchFiles/Build.bat'), "@echo off`r`necho %*`r`nexit /b 0`r`n")
[IO.File]::WriteAllText((Join-Path $FlagRoot 'AethelnOnline.uproject'), '{}')
foreach ($FlagCase in @(
	@{ target = 'AethelnOnlineEditor'; platform = 'Win64'; present = @('-CompilerVersion=14.44.35207', '-WindowsSDKVersion=10.0.26100.0'); absent = @('-Compiler=', '-NoEngineChanges') },
	@{ target = 'AethelnOnlineClient'; platform = 'Win64'; present = @('-Compiler=VisualStudio2022', '-CompilerVersion=14.44.35207', '-WindowsSDKVersion=10.0.26100.0'); absent = @('-NoEngineChanges') },
	@{ target = 'AethelnOnlineServer'; platform = 'Linux'; present = @(); absent = @('-NoEngineChanges', '-Compiler=', '-CompilerVersion=', '-WindowsSDKVersion=') }
)) {
	$FlagEvidence = Join-Path $FlagRoot ('evidence-' + $FlagCase.target)
	$null = New-Item -ItemType Directory -Path $FlagEvidence
	& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.BuildInvocation.ps1') `
		-Target $FlagCase.target -Platform $FlagCase.platform -ActionLimit 1 -EngineRoot $FlagRoot -TargetRoot $FlagRoot -LinuxToolchainRoot $FlagRoot -EvidenceRoot $FlagEvidence 2>&1 | Out-Null
	Assert-BuildTest -Condition ($LASTEXITCODE -eq 0) -Message "$($FlagCase.target) flag fixture did not run"
	$FlagLog = [IO.File]::ReadAllText((Join-Path $FlagEvidence 'build.log'))
	foreach ($Flag in $FlagCase.present) { Assert-BuildTest -Condition $FlagLog.Contains($Flag) -Message "$($FlagCase.target) is missing $Flag" }
	foreach ($Flag in $FlagCase.absent) { Assert-BuildTest -Condition (-not $FlagLog.Contains($Flag)) -Message "$($FlagCase.target) must not carry $Flag" }
}
Write-Output 'PASS: only the editor target omits -Compiler=; no target passes -NoEngineChanges yet'
# Short output must survive an owned abrupt stop, not remain solely in the
# capture process's managed FileStream buffer until a normal native exit.
$LiveRoot = Join-Path $FixtureRoot 'live-output'
$LiveBatchRoot = Join-Path $LiveRoot 'Engine/Build/BatchFiles'
$null = New-Item -ItemType Directory -Path $LiveBatchRoot
$LiveDotnet = Join-Path $LiveRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
$null = New-Item -ItemType Directory -Path $LiveDotnet
[IO.File]::WriteAllText((Join-Path $LiveDotnet 'dotnet.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $LiveRoot 'AethelnOnline.uproject'), '{}')
[IO.File]::WriteAllText((Join-Path $LiveBatchRoot 'Build.bat'), "@echo off`r`necho retained-before-stop`r`necho ready>`"$LiveRoot/emitted.txt`"`r`npowershell.exe -NoProfile -NonInteractive -Command `"Start-Sleep -Seconds 20`"`r`n")
$LiveEvidence = Join-Path $LiveRoot 'evidence'
$null = New-Item -ItemType Directory -Path $LiveEvidence
$LiveLease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $LiveRoot 'owner.lease')
$LiveOwned = $null
try {
	$LiveArguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.BuildInvocation.ps1'),
		'-Target', 'AethelnOnlineClient', '-Platform', 'Win64', '-ActionLimit', '1',
		'-EngineRoot', $LiveRoot, '-TargetRoot', $LiveRoot, '-LinuxToolchainRoot', $LiveRoot, '-EvidenceRoot', $LiveEvidence)
	$LiveOwned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $LiveLease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $LiveArguments -WorkingDirectory $LiveRoot
	$LiveTimer = [Diagnostics.Stopwatch]::StartNew()
	$LiveLog = Join-Path $LiveEvidence 'build.log'
	while ($LiveTimer.Elapsed.TotalSeconds -lt 8 -and -not $LiveOwned.process.HasExited) {
		if ((Test-Path -LiteralPath (Join-Path $LiveRoot 'emitted.txt')) -and (Test-Path -LiteralPath $LiveLog) -and (Get-Item -LiteralPath $LiveLog).Length -gt 0) { break }
		Start-Sleep -Milliseconds 20
	}
	Assert-BuildTest -Condition (Test-Path -LiteralPath (Join-Path $LiveRoot 'emitted.txt')) -Message 'Live-output fixture did not emit its marker'
	Assert-BuildTest -Condition (-not $LiveOwned.process.HasExited -and (Get-Item -LiteralPath $LiveLog).Length -gt 0) -Message 'Live captured output remained buffered until native exit'
	$null = Stop-InitialPreparationOwnedTree -Lease $LiveLease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Assert-BuildTest -Condition ($LiveOwned.supervision.ActiveCount -eq 0) -Message 'Live-output fixture left owned descendants'
	Assert-BuildTest -Condition ($LiveOwned.process.WaitForExit(5000)) -Message 'Live-output capture did not exit after owned stop'
	$ReadTimer = [Diagnostics.Stopwatch]::StartNew()
	$RetainedLog = $null
	do {
		try { $RetainedLog = [IO.File]::ReadAllText($LiveLog) } catch [IO.IOException] { Start-Sleep -Milliseconds 20 }
	} while ($null -eq $RetainedLog -and $ReadTimer.Elapsed.TotalSeconds -lt 5)
	Assert-BuildTest -Condition ($null -ne $RetainedLog -and $RetainedLog.Contains('retained-before-stop')) -Message 'Abrupt owned stop lost captured output'
} finally {
	$null = Stop-InitialPreparationOwnedTree -Lease $LiveLease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $LiveLease
}
$CapRoot = Join-Path $FixtureRoot 'output-cap'
$CapBatch = Join-Path $CapRoot 'Engine/Build/BatchFiles'
$null = New-Item -ItemType Directory -Path $CapBatch
$CapDotnet = Join-Path $CapRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
$null = New-Item -ItemType Directory -Path $CapDotnet
[IO.File]::WriteAllText((Join-Path $CapDotnet 'dotnet.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $CapBatch 'Build.bat'), "@echo off`r`npowershell.exe -NoProfile -NonInteractive -Command `"[Console]::Out.Write(('x' * 17000000))`"`r`nexit /b 0`r`n")
[IO.File]::WriteAllText((Join-Path $CapRoot 'AethelnOnline.uproject'), '{}')
$CapEvidence = Join-Path $CapRoot 'evidence'
$null = New-Item -ItemType Directory -Path $CapEvidence
$CapLease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $CapRoot 'owner.lease')
try {
	Assert-BuildRejected -Action {
		Invoke-InitialPreparationSingleBuild -Attempt $Attempt -Lease $CapLease -EngineRoot $CapRoot -TargetRoot $CapRoot -LinuxToolchainRoot $CapRoot -EvidenceRoot $CapEvidence -Target AethelnOnlineClient -Platform Win64 -ActionLimit 1 -Roots @{ evidence = $CapRoot } -OnSample {}
	} -Reason 'build_result_invalid'
	$LogLength = (Get-Item -LiteralPath (Join-Path $CapEvidence 'build.log')).Length
	Assert-BuildTest -Condition ($LogLength -gt 0 -and $LogLength -le 16MB) -Message 'Combined output bound violated'
	$CapRecord = Get-Content -LiteralPath (Join-Path $CapEvidence 'native-result.json') -Raw | ConvertFrom-Json
	Assert-BuildTest -Condition ($null -ne $CapRecord.infrastructureFailure -and $null -ne $CapRecord.nativeExitCode) -Message 'Capture infrastructure failure must retain actual native exit'
} finally {
	$null = Stop-InitialPreparationOwnedTree -Lease $CapLease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $CapLease
}
Write-Output "PASS: preparation build fixtures; retained $FixtureRoot"
