param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$Module = Join-Path $RepositoryRoot 'scripts/ci/EngineRunnerHostLease.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) { throw 'routine_host_lease_module_missing' }
. $Module
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnHostLease-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$script:AssertionCount = 0
function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
	$script:AssertionCount++
}
function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	$Failure = ''
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; got $Failure"
}
$Path = Join-Path $FixtureRoot 'host.lease'
$BudgetPath = Join-Path $FixtureRoot 'monotonic.lease'
$BudgetLease = Enter-EngineRunnerHostLease -LeasePath $BudgetPath -OwnerId 'wall-clock-forward' -DeadlineUtc ([DateTime]::UtcNow.AddDays(-1)) -RemainingBudget { 10000 }
Exit-EngineRunnerHostLease -Lease $BudgetLease -CleanupVerified $true
Assert-True -Condition (Test-Path -LiteralPath $BudgetPath) -Message 'An expired UTC projection must not reject remaining monotonic budget'
$ExpiredPath = Join-Path $FixtureRoot 'expired-budget.lease'
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $ExpiredPath -OwnerId 'expired' -DeadlineUtc ([DateTime]::UtcNow.AddDays(1)) -RemainingBudget { 0 } } -Reason 'compile_timeout'
Assert-True -Condition (-not (Test-Path -LiteralPath $ExpiredPath)) -Message 'Expired budget must not create or append a lease'
foreach ($Value in @($null, '1000', $true, [double]::NaN, [double]::PositiveInfinity, @('one', 'two'))) {
	$Malformed = { $Value }.GetNewClosure()
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $ExpiredPath -OwnerId 'malformed' -DeadlineUtc ([DateTime]::UtcNow.AddDays(1)) -RemainingBudget $Malformed } -Reason 'compile_clock_invalid'
}
foreach ($Reason in @('compile_timeout', 'resource_pressure', 'disk_floor_reached')) {
	$ProgressFailure = { throw $Reason }.GetNewClosure()
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $ExpiredPath -OwnerId 'progress' -DeadlineUtc ([DateTime]::UtcNow.AddDays(1)) -RemainingBudget { 10000 } -OnProgress $ProgressFailure } -Reason $Reason
}
$Contended = [IO.File]::Open($BudgetPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
	$BudgetWait = [Diagnostics.Stopwatch]::StartNew()
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $BudgetPath -OwnerId 'contended' -DeadlineUtc ([DateTime]::UtcNow.AddDays(1)) -RemainingBudget { 350 } } -Reason 'compile_timeout'
	Assert-True -Condition ($BudgetWait.Elapsed.TotalMilliseconds -ge 300 -and $BudgetWait.Elapsed.TotalSeconds -lt 3) -Message 'Constant callback cannot reset a contended lease wait budget'
} finally { $Contended.Dispose() }
$Lease = Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'routine-one' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Assert-True -Condition ($Lease.ownerPid -eq $PID) -Message 'Actual PID is bound'
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified 'true' } -Reason 'cleanup_unproven'
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $false } -Reason 'cleanup_unproven'
Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true
$Again = Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'routine-two' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Exit-EngineRunnerHostLease -Lease $Again -CleanupVerified $true

$Records = @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
Assert-True -Condition ($Records.Count -eq 4 -and $Records[0].state -ceq 'held' -and $Records[3].state -ceq 'released') -Message 'Append-only paired journal'
Assert-True -Condition ($Records[0].leaseId -ceq $Lease.leaseId -and $Records[2].leaseId -ceq $Again.leaseId) -Message 'A small journal appends without compaction'
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Again -CleanupVerified $true } -Reason 'lease_lost'
foreach ($BadDeadline in @('2026-09-13T00:00:00Z', [DateTime]::Now, 123)) {
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'invalid' -DeadlineUtc $BadDeadline } -Reason 'lease_deadline_invalid'
}
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1)) } -Reason 'lease_deadline_elapsed'
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'bad owner' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_owner_invalid'
foreach ($BadPath in @('relative.lease', 'C:\', '\\server\share\host.lease', (Join-Path $FixtureRoot '.env.lease'),
	(Join-Path $FixtureRoot 'host.lease:stream'), (Join-Path $FixtureRoot '..\host.lease'), (Join-Path $RepositoryRoot 'host.lease'),
	(Join-Path $FixtureRoot 'credential.pem'), (Join-Path $FixtureRoot 'missing\host.lease'))) {
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $BadPath -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_path_invalid'
}
$Lease = Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'identity' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $Path.ToUpperInvariant() -OwnerId 'nested' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_nested'
$Forged = $Lease | ConvertTo-Json | ConvertFrom-Json
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Forged -CleanupVerified $true } -Reason 'lease_lost'
foreach ($Field in @('leaseId', 'ownerId', 'ownerPid', 'ownerStartUtc')) {
	$Original = $Lease.$Field
	$Lease.$Field = 'forged'
	Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true } -Reason 'lease_lost'
	$Lease.$Field = $Original
}
foreach ($Proof in @('false', 1, @($true), [pscustomobject]@{ ok = $true })) {
	Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $Proof } -Reason 'cleanup_unproven'
}
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified @($true) } -Reason 'cleanup_unproven'
Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true

# Same on-disk protocol and real kernel exclusion in both directions.
. (Join-Path $RepositoryRoot 'scripts/ci/InitialPreparation.Core.ps1')
$Attempt = New-InitialPreparationAttempt -Repository 'fixture/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId 'preparation-fixture'
$Preparation = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $Path
$Timer = [Diagnostics.Stopwatch]::StartNew()
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'routine-wait' -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(350)) } -Reason 'lease_deadline_elapsed'
Assert-True -Condition ($Timer.Elapsed.TotalMilliseconds -ge 300 -and $Timer.Elapsed.TotalSeconds -lt 3) -Message 'Finite wait consumes deadline without spinning'
$null = Stop-InitialPreparationOwnedTree -Lease $Preparation -DeadlineTicks ([Diagnostics.Stopwatch]::GetTimestamp() + 5L * [Diagnostics.Stopwatch]::Frequency)
Exit-InitialPreparationLease -Lease $Preparation
$Lease = Enter-EngineRunnerHostLease -LeasePath $Path -OwnerId 'routine-after-preparation' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
$PreparationFailure = $null
try { $null = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $Path } catch {
	$PreparationFailure = $_.Exception
	while ($null -ne $PreparationFailure.InnerException) { $PreparationFailure = $PreparationFailure.InnerException }
}
Assert-True -Condition ($PreparationFailure -is [IO.IOException] -and ($PreparationFailure.HResult -band 65535) -eq 32) -Message 'Preparation receives native sharing violation while routine owns file'

function Invoke-ChildFixture([string] $Body) {
	$OutPath = Join-Path $FixtureRoot ([guid]::NewGuid().ToString('N') + '.out')
	$ErrorPath = $OutPath + '.err'
	$Code = '$ErrorActionPreference = ''Stop''; . ''' + $Module.Replace("'", "''") + '''; ' + $Body
	$Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
	$Child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile', '-EncodedCommand', $Encoded) -WindowStyle Hidden -PassThru -RedirectStandardOutput $OutPath -RedirectStandardError $ErrorPath
	$null = $Child.Handle
	Assert-True -Condition ($Child.WaitForExit(15000)) -Message 'Bounded fixture child exits'
	$Child.Refresh()
	Assert-True -Condition ($Child.ExitCode -eq 0) -Message "Child exit: $($Child.ExitCode); stderr retained at $ErrorPath"
	$Child.Dispose()
	return Get-Content -LiteralPath $OutPath -Raw
}
$QuotedPath = "'" + $Path.Replace("'", "''") + "'"
$Output = Invoke-ChildFixture -Body ('try { $null = Enter-EngineRunnerHostLease -LeasePath ' + $QuotedPath + ' -OwnerId child -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(400)); exit 7 } catch { if ($_.Exception.Message -cne ''lease_deadline_elapsed'') { throw }; Write-Output ''EXCLUDED'' }')
Assert-True -Condition ($Output.Trim() -ceq 'EXCLUDED') -Message 'Separate process denied while parent holds same file'
Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $true
$Output = Invoke-ChildFixture -Body ('$lease = Enter-EngineRunnerHostLease -LeasePath ' + $QuotedPath + ' -OwnerId child -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5)); Exit-EngineRunnerHostLease -Lease $lease -CleanupVerified $true; Write-Output ''RELEASED''')
Assert-True -Condition ($Output.Trim() -ceq 'RELEASED') -Message 'Separate process acquires after verified release'
$Preparation = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $Path
$null = Stop-InitialPreparationOwnedTree -Lease $Preparation -DeadlineTicks ([Diagnostics.Stopwatch]::GetTimestamp() + 5L * [Diagnostics.Stopwatch]::Frequency)
Exit-InitialPreparationLease -Lease $Preparation

$AbandonedPath = Join-Path $FixtureRoot 'abandoned.lease'
$Lease = Enter-EngineRunnerHostLease -LeasePath $AbandonedPath -OwnerId 'abandoned' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Assert-Rejected -Action { Exit-EngineRunnerHostLease -Lease $Lease -CleanupVerified $false } -Reason 'cleanup_unproven'
Close-EngineRunnerHostLease -Lease $Lease
Assert-True -Condition ((Get-Content -LiteralPath $AbandonedPath | ConvertFrom-Json).state -ceq 'held') -Message 'Unproven cleanup never writes released'
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $AbandonedPath -OwnerId 'retry' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_owner_ambiguous'
Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $AbandonedPath } -Reason 'lease_owner_ambiguous'
$DeadPath = Join-Path $FixtureRoot 'dead.lease'
$null = Invoke-ChildFixture -Body ('$null = Enter-EngineRunnerHostLease -LeasePath ''' + $DeadPath.Replace("'", "''") + ''' -OwnerId dead -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5)); Write-Output ''HELD''')
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $DeadPath -OwnerId 'retry' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_owner_ambiguous'

$GoodJournal = [IO.File]::ReadAllText($Path)
$BadJournals = @(
	'garbage',
	($GoodJournal + '{"schemaVersion":1,"state":"released","leaseId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","attemptId":"forged","cleanupVerified":true}' + "`n"),
	$GoodJournal.Replace('"cleanupVerified":true', '"cleanupVerified":"true"'),
	$GoodJournal.Replace('"state":"held"', '"state":"held","state":"released"'),
	$GoodJournal.Replace('"attemptId":"identity"', '"attemptId":"wrong"'),
	$GoodJournal.TrimEnd([char] 10)
)
# Only mutate the released half for the owner mismatch fixture.
$BadJournals[4] = $GoodJournal.Replace('"attemptId":"identity","cleanupVerified"', '"attemptId":"wrong","cleanupVerified"')
foreach ($Journal in $BadJournals) {
	$BadPath = Join-Path $FixtureRoot ([guid]::NewGuid().ToString('N') + '.lease')
	[IO.File]::WriteAllText($BadPath, $Journal, (New-Object Text.UTF8Encoding($false)))
	$Before = (Get-FileHash -LiteralPath $BadPath -Algorithm SHA256).Hash
	Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $BadPath -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_owner_ambiguous'
	Assert-True -Condition ((Get-FileHash -LiteralPath $BadPath -Algorithm SHA256).Hash -ceq $Before) -Message 'Invalid journal bytes preserved'
}
$LargePath = Join-Path $FixtureRoot 'large.lease'
[IO.File]::WriteAllText($LargePath, ('x' * 65537))
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $LargePath -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_journal_limit'
function Initialize-JournalFixture([string] $Name, [int] $MinimumLength, [bool] $EndHeld = $false) {
	$FixturePath = Join-Path $FixtureRoot $Name
	$Builder = New-Object Text.StringBuilder
	$StartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
	while ($Builder.Length -lt $MinimumLength) {
		$Token = [guid]::NewGuid().ToString('N')
		$HeldRecord = [ordered]@{ schemaVersion = 1; state = 'held'; leaseId = $Token; attemptId = 'fixture'; ownerPid = $PID; ownerStartUtc = $StartUtc }
		$ReleasedRecord = [ordered]@{ schemaVersion = 1; state = 'released'; leaseId = $Token; attemptId = 'fixture'; cleanupVerified = $true }
		$null = $Builder.Append(($HeldRecord | ConvertTo-Json -Compress) + "`n")
		if (-not $EndHeld -or $Builder.Length -lt $MinimumLength) { $null = $Builder.Append(($ReleasedRecord | ConvertTo-Json -Compress) + "`n") }
	}
	[IO.File]::WriteAllText($FixturePath, $Builder.ToString(), (New-Object Text.UTF8Encoding($false)))
	return $FixturePath
}
# A full, completely released journal is compacted to the new held record instead of being refused.
$ReservedPath = Initialize-JournalFixture -Name 'reserve.lease' -MinimumLength 65000
Assert-True -Condition ((Get-Item -LiteralPath $ReservedPath).Length -le 65536) -Message 'Valid almost-full journal is within read limit'
$Compacting = Enter-EngineRunnerHostLease -LeasePath $ReservedPath -OwnerId ('x' * 128) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Assert-True -Condition ($script:EngineRunnerHostLeases[$ReservedPath].stream.Length -lt 1000) -Message 'Compaction leaves only the new held record while the lease is held'
Exit-EngineRunnerHostLease -Lease $Compacting -CleanupVerified $true
$Compacted = @([IO.File]::ReadAllLines($ReservedPath) | ForEach-Object { $_ | ConvertFrom-Json })
Assert-True -Condition ($Compacted.Count -eq 2 -and $Compacted[0].state -ceq 'held' -and $Compacted[0].leaseId -ceq $Compacting.leaseId -and $Compacted[1].state -ceq 'released' -and $Compacted[1].leaseId -ceq $Compacting.leaseId -and $Compacted[1].cleanupVerified) -Message 'Compacted journal holds exactly the new verified held/released pair'
$Next = Enter-EngineRunnerHostLease -LeasePath $ReservedPath -OwnerId 'after-compaction' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
Exit-EngineRunnerHostLease -Lease $Next -CleanupVerified $true
Assert-True -Condition (@([IO.File]::ReadAllLines($ReservedPath)).Count -eq 4) -Message 'A compacted journal appends normally afterwards'
# An unreleased held record must still be refused, byte for byte, even when the journal is nearly full.
$HeldTailPath = Initialize-JournalFixture -Name 'reserve-held.lease' -MinimumLength 65300 -EndHeld $true
$HeldTailHash = (Get-FileHash -LiteralPath $HeldTailPath -Algorithm SHA256).Hash
Assert-True -Condition ((Get-Item -LiteralPath $HeldTailPath).Length -le 65536 -and ([IO.File]::ReadAllLines($HeldTailPath)[-1] | ConvertFrom-Json).state -ceq 'held') -Message 'Almost-full journal fixture ends with an unreleased held record'
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $HeldTailPath -OwnerId ('x' * 128) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_owner_ambiguous'
Assert-True -Condition ((Get-FileHash -LiteralPath $HeldTailPath -Algorithm SHA256).Hash -ceq $HeldTailHash) -Message 'Held almost-full journal is not compacted'
# A valid journal already beyond the reader limit stays refused and unchanged; compaction never raises the limit.
$OverLimitPath = Initialize-JournalFixture -Name 'over-limit.lease' -MinimumLength 65537
$OverLimitHash = (Get-FileHash -LiteralPath $OverLimitPath -Algorithm SHA256).Hash
Assert-True -Condition ((Get-Item -LiteralPath $OverLimitPath).Length -gt 65536) -Message 'Over-limit journal fixture exceeds the reader limit'
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $OverLimitPath -OwnerId 'over-limit' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_journal_limit'
Assert-True -Condition ((Get-FileHash -LiteralPath $OverLimitPath -Algorithm SHA256).Hash -ceq $OverLimitHash) -Message 'Over-limit journal is preserved'
$LinkPath = Join-Path $FixtureRoot 'hardlink.lease'
$null = New-Item -ItemType HardLink -Path $LinkPath -Target $Path
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath $LinkPath -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_path_invalid'
$Junction = Join-Path $FixtureRoot 'junction'
$RealDirectory = Join-Path $FixtureRoot 'real'
$null = New-Item -ItemType Directory -Path $RealDirectory
$null = New-Item -ItemType Junction -Path $Junction -Target $RealDirectory
Assert-Rejected -Action { Enter-EngineRunnerHostLease -LeasePath (Join-Path $Junction 'host.lease') -OwnerId 'invalid' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10)) } -Reason 'lease_path_invalid'
Write-Output "PASS $script:AssertionCount assertions: routine host lease, journal, identity, cleanup, path, deadline, cross-process and preparation interoperability; fixtures retained at $FixtureRoot"
