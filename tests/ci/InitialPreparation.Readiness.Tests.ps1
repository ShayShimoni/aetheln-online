[CmdletBinding()]
param([switch] $SchemaOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Readiness.ps1')
function Assert-ReadinessTest([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}
function Assert-ReadinessRejected([scriptblock] $Action, [string] $Reason) {
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-ReadinessTest ($Failure -ceq $Reason) "Expected $Reason; received $Failure"
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnReadiness-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
function New-ReadinessFixture {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([hashtable])]
	param([string] $Name, [string] $ScanContent, [string] $BatchBody = '')
	$Root = Join-Path $FixtureRoot $Name
	if (-not $PSCmdlet.ShouldProcess($Root, 'Create owned readiness fixture')) { throw 'fixture_creation_declined' }
	$Engine = Join-Path $Root 'engine'
	$Evidence = Join-Path $Root 'evidence'
	foreach ($Relative in @('Engine/Build/BatchFiles', 'Engine/Source/Programs/UnrealBuildTool', 'Engine/Intermediate/Build', 'Engine/Binaries/DotNET/UnrealBuildTool', 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64')) {
		$null = New-Item -ItemType Directory -Path (Join-Path $Engine $Relative) -Force
	}
	$null = New-Item -ItemType Directory -Path $Evidence
	$BatchRoot = Join-Path $Engine 'Engine/Build/BatchFiles'
	$DotnetRoot = Join-Path $Engine 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	[IO.File]::WriteAllText((Join-Path $DotnetRoot 'dotnet.exe'), 'fixture dotnet')
	[IO.File]::WriteAllText((Join-Path $Engine 'Engine/Source/Programs/UnrealBuildTool/UnrealBuildTool.sln'), 'fake solution')
	[IO.File]::WriteAllText((Join-Path $Engine 'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll'), 'fake published dll')
	$Receipt = Join-Path $Engine 'Engine/Intermediate/Build/UnrealBuildTool.dep.csv'
	[IO.File]::WriteAllText($Receipt, "D:\source\Alpha.cs,ABCDEF`r`nD:\source\Beta.cs,123456`r`n", [Text.Encoding]::ASCII)
	[IO.File]::WriteAllText((Join-Path $BatchRoot 'fixture.csv'), $ScanContent, [Text.Encoding]::ASCII)
	if (-not $BatchBody) { $BatchBody = 'copy /b "%~dp0fixture.csv" "%~2" >nul' + "`r`nexit /b 0" }
	$DotnetGuard = "if not `"%UE_USE_SYSTEM_DOTNET%`"==`"0`" exit /b 93`r`nif not `"%UE_DOTNET_VERSION%`"==`"10.0`" exit /b 92`r`nif not `"%DOTNET_ROOT%`"==`"$DotnetRoot`" exit /b 91`r`nif not `"%UE_DOTNET_DIR%`"==`"$DotnetRoot`" exit /b 90`r`nif not `"%DOTNET_MULTILEVEL_LOOKUP%`"==`"0`" exit /b 89`r`nif not `"%DOTNET_ROLL_FORWARD%`"==`"LatestMajor`" exit /b 88`r`nif not `"%NoDefaultCurrentDirectoryInExePath%`"==`"1`" exit /b 87`r`n"
	$Script = "@echo off`r`n" + $DotnetGuard + "echo entered > `"%~dp0scan-started.txt`"`r`necho fixture-stdout`r`necho fixture-stderr 1>&2`r`n" + $BatchBody + "`r`n"
	[IO.File]::WriteAllText((Join-Path $BatchRoot 'DotnetDepends.bat'), $Script, [Text.Encoding]::ASCII)
	[IO.File]::WriteAllText((Join-Path $BatchRoot 'BuildUBT.bat'), "@echo off`r`necho forbidden > `"%~dp0build-started.txt`"`r`nexit /b 99`r`n", [Text.Encoding]::ASCII)
	return @{ root = $Root; engine = $Engine; evidence = $Evidence; receipt = $Receipt; batchRoot = $BatchRoot }
}
function New-ReadinessAttempt {
	[CmdletBinding(SupportsShouldProcess)]
	param()
	if (-not $PSCmdlet.ShouldProcess('readiness fixture', 'Create bounded fixture attempt')) { throw 'fixture_attempt_declined' }
	return New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ([guid]::NewGuid().ToString('N'))
}
function Test-ReadinessReceiptType {
	# Replace only the transport in this scope. Exercise the public reader with
	# exact hostile JSON shapes; native transport and watchdog tests remain below.
	function Start-InitialPreparationProcess {
		[CmdletBinding(SupportsShouldProcess)]
		param($Attempt, $Lease, $Executable, $Arguments, $WorkingDirectory)
		Assert-InitialPreparationAttempt -Attempt $Attempt
		Assert-ReadinessTest -Condition ($Lease.leaseId -and $Executable -ceq (Join-Path $PSHOME 'powershell.exe') -and
			$Arguments.Count -eq 8 -and $Arguments[0] -ceq '-NoProfile' -and $Arguments[1] -ceq '-NonInteractive' -and
			$Arguments[2] -ceq '-File' -and (Split-Path -Leaf $Arguments[3]) -ceq 'InitialPreparation.ReadinessInvocation.ps1' -and
			$Arguments[4] -ceq '-EngineRoot' -and $Arguments[5] -ceq $Fixture.engine -and $Arguments[6] -ceq '-EvidenceRoot' -and
			$Arguments[7] -ceq $Fixture.evidence -and $WorkingDirectory -ceq $Fixture.evidence) -Message 'Readiness transport arguments changed'
		if (-not $PSCmdlet.ShouldProcess($WorkingDirectory, 'Publish fake native readiness receipt')) { throw 'fixture_transport_declined' }
		[IO.File]::WriteAllText((Join-Path $WorkingDirectory 'readiness-native-result.json'), ($NativeFixtureRecord | ConvertTo-Json -Depth 5 -Compress))
		$Supervision = [pscustomobject]@{ TimedOut = $false }
		$Supervision | Add-Member -MemberType ScriptMethod -Name StopAndWait -Value {
			param($Milliseconds)
			if ($Milliseconds -ne 5000) { throw 'fixture_cleanup_budget_changed' }
		}
		return [pscustomobject]@{ process = [pscustomobject]@{ ExitCode = $(if ($NativeFixtureRecord.ready) { 0 } else { 1 }); HasExited = $true }; supervision = $Supervision }
	}
	function Watch-InitialPreparationResource {
		param($Attempt, $OwnedProducer, $Roots, $KnownAllocations, $OnSample, $CompletionProbe)
		Assert-InitialPreparationAttempt -Attempt $Attempt
		Assert-ReadinessTest -Condition ($OwnedProducer.process.HasExited -and $Roots.Count -eq 1 -and
			$Roots.fixture -ceq $Fixture.root -and $KnownAllocations.Count -eq 0 -and $OnSample -is [scriptblock] -and
			$CompletionProbe -is [scriptblock] -and (& $CompletionProbe $OwnedProducer)) -Message 'Readiness monitoring arguments changed'
		& $OnSample ([pscustomobject]@{ fixture = 'schema' }) | Out-Null
		return [pscustomobject]@{ code = 'producer_completed' }
	}
	$Cases = @(
		@{ name = 'version-single'; field = 'schemaVersion'; value = @(1); failed = $false },
		@{ name = 'version-empty'; field = 'schemaVersion'; value = @(); failed = $false },
		@{ name = 'version-string'; field = 'schemaVersion'; value = '1'; failed = $false },
		@{ name = 'version-bool'; field = 'schemaVersion'; value = $true; failed = $false },
		@{ name = 'scope-single'; field = 'scope'; value = @('ubt_dependency_rebuild_branch'); failed = $false },
		@{ name = 'scope-empty'; field = 'scope'; value = @(); failed = $false },
		@{ name = 'failure-single'; field = 'failureCode'; value = @('ubt_dependency_scan_failed'); failed = $true },
		@{ name = 'failure-empty'; field = 'failureCode'; value = @(); failed = $true },
		@{ name = 'failure-null'; field = 'failureCode'; value = $null; failed = $true },
		@{ name = 'success-failure-empty'; field = 'failureCode'; value = @(); failed = $false },
		@{ name = 'success-failure-single'; field = 'failureCode'; value = @('ubt_dependency_scan_failed'); failed = $false }
	)
	foreach ($Case in $Cases) {
		$Fixture = New-ReadinessFixture ('schema-' + $Case.name) 'unused'
		$Attempt = New-ReadinessAttempt
		$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $Fixture.root 'owner.lease')
		$NativeFixtureRecord = [ordered]@{ schemaVersion = 1; scope = 'ubt_dependency_rebuild_branch'; ready = (-not $Case.failed);
			scanExitCode = 0; comparisonExitCode = 0; dependencySha256 = ('a' * 64); scanSha256 = ('b' * 64); failureCode = $null }
		$NativeFixtureRecord[$Case.field] = $Case.value
		try {
			Assert-ReadinessRejected {
				Invoke-InitialPreparationUbtReadiness -Attempt $Attempt -Lease $Lease -EngineRoot $Fixture.engine -EvidenceRoot $Fixture.evidence -Roots @{ fixture = $Fixture.root } -OnSample {}
			} 'readiness_result_invalid'
			$Receipt = Get-Content -LiteralPath (Join-Path $Fixture.evidence 'readiness-result.json') -Raw | ConvertFrom-Json
			Assert-ReadinessTest (-not $Receipt.ready -and $Receipt.failureCode -ceq 'readiness_result_invalid') "Malformed $($Case.name) yielded accepted readiness evidence"
		} finally {
			$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
			Exit-InitialPreparationLease -Lease $Lease
		}
	}
	Write-Output 'PASS: readiness receipt rejects array and coerced scalar schema fields'
}
Test-ReadinessReceiptType
if ($SchemaOnly) { return }
function Invoke-ReadinessCase($Fixture, [string] $ExpectedFailure = '', [scriptblock] $OnSample = {}) {
	$Attempt = New-ReadinessAttempt
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $Fixture.root 'owner.lease')
	$BeforeHash = if (Test-Path -LiteralPath $Fixture.receipt) { (Get-FileHash -LiteralPath $Fixture.receipt -Algorithm SHA256).Hash } else { $null }
	try {
		$Parameters = @{ Attempt = $Attempt; Lease = $Lease; EngineRoot = $Fixture.engine; EvidenceRoot = $Fixture.evidence; Roots = @{ fixture = $Fixture.root }; OnSample = $OnSample }
		if ($ExpectedFailure) { Assert-ReadinessRejected { Invoke-InitialPreparationUbtReadiness @Parameters } $ExpectedFailure } else {
			$Result = Invoke-InitialPreparationUbtReadiness @Parameters
			Assert-ReadinessTest ($Result.ready -and $Result.cleanupVerified -and $Result.scope -ceq 'ubt_dependency_rebuild_branch' -and $Result.scanExitCode -eq 0 -and $Result.comparisonExitCode -eq 0) 'Readiness result lost scope, comparison, or cleanup evidence'
			Assert-ReadinessTest ($Result.dependencySha256 -cmatch '^[0-9a-f]{64}$' -and $Result.baselineVerified -eq $false) 'Readiness must retain dependency identity and avoid full baseline claim'
			$Log = [IO.File]::ReadAllText((Join-Path $Fixture.evidence 'scan.log'))
			Assert-ReadinessTest ($Log.Contains('fixture-stdout') -and $Log.Contains('fixture-stderr')) 'Readiness must drain both output streams'
			$Hash = (Get-FileHash -LiteralPath (Join-Path $Fixture.evidence 'readiness-result.json') -Algorithm SHA256).Hash
			Assert-ReadinessRejected { Invoke-InitialPreparationUbtReadiness @Parameters } 'readiness_evidence_exists'
			Assert-ReadinessTest ((Get-FileHash -LiteralPath (Join-Path $Fixture.evidence 'readiness-result.json') -Algorithm SHA256).Hash -ceq $Hash) 'Readiness overwrote prior evidence'
		}
		if ($BeforeHash) { Assert-ReadinessTest ((Get-FileHash -LiteralPath $Fixture.receipt -Algorithm SHA256).Hash -ceq $BeforeHash) 'Engine dependency receipt was overwritten' }
		Assert-ReadinessTest (-not (Test-Path -LiteralPath (Join-Path $Fixture.batchRoot 'build-started.txt'))) 'Readiness invoked the forbidden build helper'
		$Entry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })[0]
		if ($Entry.PSObject.Properties.Name -contains 'supervisedJobs') { foreach ($Job in $Entry.supervisedJobs) { Assert-ReadinessTest ($Job.ActiveCount -eq 0) 'Readiness left an owned process alive' } }
	} finally {
		$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		Exit-InitialPreparationLease -Lease $Lease
	}
}
$Matching = "D:\source\Alpha.cs,ABCDEF`r`nD:\source\Beta.cs,123456`r`n"
Invoke-ReadinessCase (New-ReadinessFixture 'match' $Matching)
Invoke-ReadinessCase (New-ReadinessFixture 'case-only' $Matching.ToLowerInvariant())
Invoke-ReadinessCase (New-ReadinessFixture 'mismatch' $Matching.Replace('ABCDEF', '000000')) 'ubt_dependencies_changed'
Invoke-ReadinessCase (New-ReadinessFixture 'order' "D:\source\Beta.cs,123456`r`nD:\source\Alpha.cs,ABCDEF`r`n") 'ubt_dependencies_changed'
Invoke-ReadinessCase -Fixture (New-ReadinessFixture -Name 'scan-error' -ScanContent $Matching -BatchBody 'exit /b 7') -ExpectedFailure 'ubt_dependency_scan_failed'
Invoke-ReadinessCase -Fixture (New-ReadinessFixture -Name 'missing-output' -ScanContent $Matching -BatchBody 'exit /b 0') -ExpectedFailure 'ubt_dependency_scan_invalid'
$MissingDll = New-ReadinessFixture 'missing-dll' $Matching
# Preserve the fixture file while making the expected path absent.
[IO.File]::Move((Join-Path $MissingDll.engine 'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll'), (Join-Path $MissingDll.root 'preserved-dll'))
Invoke-ReadinessCase $MissingDll 'ubt_readiness_input_missing'
Assert-ReadinessTest (-not (Test-Path -LiteralPath (Join-Path $MissingDll.batchRoot 'scan-started.txt'))) 'Missing DLL must reject before scan'
$MissingReceipt = New-ReadinessFixture 'missing-receipt' $Matching
[IO.File]::Move($MissingReceipt.receipt, (Join-Path $MissingReceipt.root 'preserved-receipt'))
Invoke-ReadinessCase $MissingReceipt 'ubt_readiness_input_missing'
foreach ($Name in @('shell&operator', 'shell%expansion%', 'scratch with spaces')) {
	$Unsafe = New-ReadinessFixture $Name $Matching
	Invoke-ReadinessCase $Unsafe 'readiness_path_invalid'
	Assert-ReadinessTest (-not (Test-Path -LiteralPath (Join-Path $Unsafe.batchRoot 'scan-started.txt'))) 'Unsafe shell input reached native scan'
}
$LockProbe = @'
powershell.exe -NoProfile -NonInteractive -Command "try { $s=[IO.File]::Open('%~dp0..\..\Intermediate\Build\UnrealBuildTool.dep.csv',[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $s.Dispose(); exit 98 } catch { exit 0 }"
if errorlevel 1 exit /b 98
copy /b "%~dp0fixture.csv" "%~2" >nul
exit /b 0
'@
Invoke-ReadinessCase -Fixture (New-ReadinessFixture -Name 'receipt-pinned' -ScanContent $Matching -BatchBody $LockProbe)
Invoke-ReadinessCase -Fixture (New-ReadinessFixture -Name 'monitor-failure' -ScanContent $Matching -BatchBody 'ping 127.0.0.1 -n 30 >nul') -ExpectedFailure 'resource_evidence_failed' -OnSample { throw 'fixture_quarantine_changed' }
$Flood = New-ReadinessFixture -Name 'output-cap' -ScanContent $Matching -BatchBody 'powershell.exe -NoProfile -NonInteractive -Command "[Console]::Out.Write((''x'' * 2100000))"'
Invoke-ReadinessCase $Flood 'ubt_readiness_capture_failed'
Assert-ReadinessTest ((Get-Item -LiteralPath (Join-Path $Flood.evidence 'scan.log')).Length -le 1MB) 'Readiness output exceeded the byte cap'

# Backdate only the fixture's attempt creation while retaining Core's exact
# immutable six-hour arithmetic. All subsequent timing and process supervision
# is real; the fake scanner must be reached and then stopped by Core's watchdog.
function New-NearReadinessDeadline {
	[CmdletBinding(SupportsShouldProcess)]
	param()
	if (-not $PSCmdlet.ShouldProcess('readiness fixture', 'Create attempt near its useful-work deadline')) { throw 'fixture_deadline_declined' }
	function Get-InitialPreparationTick { return [long] ([Diagnostics.Stopwatch]::GetTimestamp() - [long] (19792 * [Diagnostics.Stopwatch]::Frequency)) }
	return New-ReadinessAttempt
}
$Hanging = New-ReadinessFixture -Name 'deadline' -ScanContent $Matching -BatchBody 'ping 127.0.0.1 -n 90 >nul'
$DeadlineAttempt = New-NearReadinessDeadline
$DeadlineLease = Enter-InitialPreparationLease -Attempt $DeadlineAttempt -LeasePath (Join-Path $Hanging.root 'owner.lease')
$Timer = [Diagnostics.Stopwatch]::StartNew()
try {
	Assert-ReadinessRejected {
		Invoke-InitialPreparationUbtReadiness -Attempt $DeadlineAttempt -Lease $DeadlineLease -EngineRoot $Hanging.engine -EvidenceRoot $Hanging.evidence -Roots @{ fixture = $Hanging.root } -OnSample {}
	} 'useful_work_deadline'
	Assert-ReadinessTest ($Timer.Elapsed.TotalSeconds -lt 20) 'Readiness exceeded its real useful-work deadline and cleanup allowance'
	Assert-ReadinessTest (Test-Path -LiteralPath (Join-Path $Hanging.batchRoot 'scan-started.txt')) 'Deadline fixture did not reach the fake native scanner'
	$DeadlineRecord = Get-Content -LiteralPath (Join-Path $Hanging.evidence 'readiness-result.json') -Raw | ConvertFrom-Json
	Assert-ReadinessTest (-not $DeadlineRecord.ready -and $DeadlineRecord.cleanupVerified -and $DeadlineRecord.failureCode -ceq 'useful_work_deadline') 'Deadline published readiness or lost cleanup evidence'
	$Entry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $DeadlineLease.leaseId })[0]
	foreach ($Job in $Entry.supervisedJobs) { Assert-ReadinessTest ($Job.ActiveCount -eq 0) 'Deadline left an owned descendant alive' }
} finally {
	$null = Stop-InitialPreparationOwnedTree -Lease $DeadlineLease -DeadlineTicks $DeadlineAttempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $DeadlineLease
}
Write-Output "PASS: UBT readiness fixtures; retained $FixtureRoot"
