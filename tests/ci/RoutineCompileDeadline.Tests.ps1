[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/RoutineCompileDeadline.ps1')
$script:Assertions = 0
function Assert-DeadlineCondition([bool] $Condition, [string] $Message) {
	$script:Assertions++
	if (-not $Condition) { throw $Message }
}
function Assert-DeadlineFailure([scriptblock] $Action, [string] $Reason) {
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	$ReasonMatches = if ($Reason -like 'compile_*') { $Failure -ceq $Reason } else { $null -ne $Failure -and $Failure.Contains($Reason) }
	Assert-DeadlineCondition -Condition $ReasonMatches -Message "Expected $Reason; got $Failure"
}
$State = @{ Tick = [long] 301000; Utc = [DateTime]::Parse('2026-09-20T12:05:00.0000000Z').ToUniversalTime() }
$ReadTick = { $State.Tick }.GetNewClosure()
$ReadUtc = { $State.Utc }.GetNewClosure()
$Arguments = @{ StartedUtc = '2026-09-20T12:00:00.0000000Z'; StartedTimestamp = [long] 1000; TimeoutMinutes = 30; TimestampFrequency = [long] 1000; ReadTimestamp = $ReadTick; ReadUtcNow = $ReadUtc }
$Deadline = New-RoutineCompileDeadline @Arguments
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline) -eq 1500000) -Message 'Five minutes of staging must consume five minutes of the original budget.'
$Child = New-RoutineCompileDeadline @Arguments
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Child) -eq 1500000) -Message 'A child reconstructed from the original anchor must not receive a fresh budget.'
$State.Utc = $State.Utc.AddDays(2)
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline) -eq 1500000) -Message 'Forward wall-clock change must not alter remaining work.'
$State.Utc = $State.Utc.AddDays(-4)
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline) -eq 1500000) -Message 'Backward wall-clock change must not replenish work.'
Assert-DeadlineCondition -Condition ((Get-RoutineCompileDeadlineUtc -Deadline $Deadline) -eq $State.Utc.AddMilliseconds(1500000)) -Message 'Legacy projection must use the current wall clock and remaining monotonic budget.'
Assert-DeadlineFailure -Action { $Deadline.StartedTimestamp = [long] 301000 } -Reason 'ReadOnly'
$State.Tick = [long] 300999
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline } -Reason 'compile_clock_invalid'
$State.Tick = [long] 1801000
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline } -Reason 'compile_timeout'
Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Arguments } -Reason 'compile_timeout'
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds 2000) -eq 2000) -Message 'Cleanup grace is explicit and does not reset the useful-work budget.'
$State.Tick = [long] 1802999
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds 2000) -eq 1) -Message 'The last cleanup millisecond must remain bounded.'
$State.Tick = [long] 1803000
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds 2000 } -Reason 'compile_timeout'
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds -1 } -Reason 'compile_deadline_invalid'
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds 2001 } -Reason 'compile_deadline_invalid'
foreach ($Invalid in @(0, -1, 30.001, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
	$Bad = $Arguments.Clone(); $Bad.TimeoutMinutes = $Invalid
	Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Bad } -Reason 'compile_timeout_invalid'
}
$State.Tick = [long] 1000
foreach ($Invalid in @('', '2026-09-20', '2026-09-20T12:00:00+03:00', ('2026-09-20T12:00:00.0000000Z' + "`n"))) {
	$Bad = $Arguments.Clone(); $Bad.StartedUtc = $Invalid
	Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Bad } -Reason 'compile_deadline_invalid'
}
foreach ($Invalid in @([long] 0, [long] -1, [long] 1001)) {
	$Bad = $Arguments.Clone(); $Bad.StartedTimestamp = $Invalid
	Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Bad } -Reason 'compile_clock_invalid'
}
foreach ($Invalid in @($null, '1000', 1000.5, $true, @([long] 1000, [long] 1001))) {
	$State.Tick = $Invalid
	Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Arguments } -Reason 'compile_clock_invalid'
}
$State.Tick = [long] 1000
$State.Utc = [DateTime]::SpecifyKind([DateTime]::Now, [DateTimeKind]::Unspecified)
Assert-DeadlineFailure -Action { Get-RoutineCompileDeadlineUtc -Deadline $Child } -Reason 'compile_clock_invalid'
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline ([pscustomobject]@{}) } -Reason 'compile_deadline_invalid'
$State.Utc = [DateTime]::UtcNow
$Boundary = New-RoutineCompileDeadline @Arguments
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $Boundary) -eq 1800000) -Message 'Thirty minutes is the hard accepted ceiling.'
foreach ($Invalid in @([long] 0, [long] -1)) {
	$Bad = $Arguments.Clone(); $Bad.TimestampFrequency = $Invalid
	Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Bad } -Reason 'compile_clock_invalid'
}
$Bad = $Arguments.Clone(); $Bad.ReadTimestamp = { throw 'fixture_read_failed' }
Assert-DeadlineFailure -Action { New-RoutineCompileDeadline @Bad } -Reason 'compile_clock_invalid'
$State.Tick = [long] 1000
$Bad = $Arguments.Clone(); $Bad.TimestampFrequency = [long] 10000000; $Bad.TimeoutMinutes = 0.001
$SubMillisecond = New-RoutineCompileDeadline @Bad
$State.Tick = [long] 600999
Assert-DeadlineCondition -Condition ((Get-RoutineCompileRemainingMillisecondCount -Deadline $SubMillisecond) -eq 1) -Message 'A positive fractional remainder must round up to one millisecond, not become a false zero.'
$State.Tick = [long] 601000
Assert-DeadlineFailure -Action { Get-RoutineCompileRemainingMillisecondCount -Deadline $SubMillisecond } -Reason 'compile_timeout'
Write-Output "PASS: $script:Assertions routine compile deadline assertions."
