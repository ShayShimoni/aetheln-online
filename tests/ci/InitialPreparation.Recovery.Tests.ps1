[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
$RecoveryModule = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Recovery.ps1'
if (-not (Test-Path -LiteralPath $RecoveryModule)) { throw 'Recovery implementation missing' }
. $RecoveryModule
function Assert-RecoveryTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-RecoveryFailure {
	param([scriptblock] $Action, [string] $Code)
	$Failure = ''
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.GetBaseException().Message }
	Assert-RecoveryTest -Condition ($Failure -ceq $Code) -Message "Expected $Code; got $Failure"
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnRecovery-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$Attempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ('recovery-' + [guid]::NewGuid().ToString('N'))
$Runner = [pscustomobject]@{ repository = 'owner/repository'; id = 21; name = 'aetheln-engine-pc'; originalLabels = @('self-hosted', 'Windows', 'X64', 'aetheln-engine', 'unrelated') }
$ExpectedRunner = [pscustomobject]@{ repository = $Runner.repository; id = $Runner.id; name = $Runner.name }
$RequestHash = 'c' * 64
$Clock = @{ ticks = $Attempt.monotonicStartTicks + 1 }
$ReadClock = { return $Clock.ticks }
$IntentPath = Join-Path $FixtureRoot 'quarantine-intent.json'
$Written = Write-InitialPreparationRecoveryIntent -Path $IntentPath -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestHash -ReadTicks $ReadClock
Assert-RecoveryTest -Condition ($Written -is [bool] -and $Written) -Message 'Durable intent writer must return scalar true'
$OriginalBytes = [IO.File]::ReadAllBytes($IntentPath)
Assert-RecoveryFailure -Action { Write-InitialPreparationRecoveryIntent -Path $IntentPath -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestHash -ReadTicks $ReadClock } -Code 'recovery_evidence_exists'
Assert-RecoveryTest -Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($IntentPath)) -ceq [Convert]::ToBase64String($OriginalBytes)) -Message 'Existing intent overwritten'
$Intent = Read-InitialPreparationRecoveryIntent -Path $IntentPath -Attempt $Attempt -Runner $ExpectedRunner -RequestSha256 $RequestHash -ReadTicks $ReadClock
Assert-RecoveryTest -Condition ($Intent.runnerId -eq 21 -and $Intent.originalLabels.Count -eq 5 -and $Intent.intendedAtTicks -eq $Clock.ticks) -Message 'Intent identity lost'
$Fixture = @{ labels = @(); requests = (New-Object Collections.ArrayList); mode = ''; resultPath = '' }
$Transport = {
	param($Request)
	Assert-RecoveryTest -Condition (Test-Path -LiteralPath $Fixture.resultPath -PathType Leaf) -Message 'Network called before result reservation'
	[void] $Fixture.requests.Add($Request)
	if ($Fixture.mode -ceq 'budget_after_read' -and $Fixture.requests.Count -eq 1) { $Clock.ticks = $Attempt.publicationDeadlineTicks - (10L * $Attempt.monotonicFrequency) }
	if ($Request.method -ceq 'POST') {
		Assert-RecoveryTest -Condition ($Request.body.labels.Count -eq 1 -and $Request.body.labels[0] -ceq 'aetheln-engine') -Message 'Unexpected label edit'
		if ($Fixture.mode -ceq 'api_failure') { throw 'fixture_api_failure' }
		$Fixture.labels = @($Fixture.labels) + @('aetheln-engine')
		if ($Fixture.mode -ceq 'response_lost') { throw 'fixture_response_lost' }
	} elseif ($Request.method -cne 'GET') { throw 'Unexpected recovery mutation' }
	$Labels = @($Fixture.labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
	if ($Request.path -match '/labels(?:\?|$)') {
		return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ total_count = $Labels.Count; labels = $Labels } }
	}
	return [pscustomobject]@{ statusCode = 200; headers = @{}; data = [pscustomobject]@{ id = 21; name = 'aetheln-engine-pc'; status = 'online'; busy = $false; labels = $Labels } }
}
foreach ($Mode in @('after_delete', 'during_work', 'already_restored', 'cleanup_false', 'cleanup_string', 'missing', 'partial', 'wrong_request', 'expired', 'budget_short', 'budget_after_read', 'api_failure', 'response_lost', 'changed_labels')) {
	$Fixture.mode = $Mode; $Fixture.requests.Clear()
	$Fixture.labels = @($Runner.originalLabels | Where-Object { $_ -cne 'aetheln-engine' })
	$Fixture.resultPath = Join-Path $FixtureRoot ($Mode + '-result.json')
	$CaseIntent = $IntentPath; $CaseHash = $RequestHash; $Cleanup = $true
	$Clock.ticks = $Attempt.monotonicStartTicks + 1
	if ($Mode -ceq 'already_restored') { $Fixture.labels = @($Runner.originalLabels) }
	if ($Mode -ceq 'cleanup_false') { $Cleanup = $false }
	if ($Mode -ceq 'cleanup_string') { $Cleanup = 'true' }
	if ($Mode -ceq 'missing') { $CaseIntent = Join-Path $FixtureRoot 'absent.json' }
	if ($Mode -ceq 'partial') {
		$CaseIntent = Join-Path $FixtureRoot 'partial.json'
		[IO.File]::WriteAllText($CaseIntent, '{', (New-Object Text.UTF8Encoding($false)))
	}
	if ($Mode -ceq 'wrong_request') { $CaseHash = 'd' * 64 }
	if ($Mode -ceq 'expired') { $Clock.ticks = $Attempt.publicationDeadlineTicks }
	if ($Mode -ceq 'budget_short') { $Clock.ticks = $Attempt.publicationDeadlineTicks - (33L * $Attempt.monotonicFrequency) + 1 }
	if ($Mode -ceq 'changed_labels') { $Fixture.labels += 'new-unrelated' }
	$Result = Invoke-InitialPreparationRecovery -IntentPath $CaseIntent -ResultPath $Fixture.resultPath -Attempt $Attempt -Runner $ExpectedRunner -RequestSha256 $CaseHash -OwnedCleanupVerified $Cleanup -Transport $Transport -ReadTicks $ReadClock
	$Saved = Get-Content -LiteralPath $Fixture.resultPath -Raw | ConvertFrom-Json
	Assert-RecoveryTest -Condition ($Saved.state -ceq $Result.state -and -not $Saved.baselineVerified -and (Get-Item -LiteralPath $Fixture.resultPath).Length -le 4096) -Message 'Recovery result missing or oversized'
	$Mutations = @($Fixture.requests | Where-Object { $_.method -cne 'GET' })
	if ($Mode -in @('after_delete', 'during_work', 'already_restored')) {
		$ExpectedMutations = if ($Mode -ceq 'already_restored') { 0 } else { 1 }
		Assert-RecoveryTest -Condition ($Result.state -ceq 'routing_restored' -and $Result.routingRestored -and -not $Result.recoveryRequired -and $Mutations.Count -eq $ExpectedMutations) -Message ('Valid recovery failed: ' + $Mode)
	} else {
		Assert-RecoveryTest -Condition (-not $Result.routingRestored -and $Result.recoveryRequired -and $Result.failureCode -is [string]) -Message ('Unsafe recovery accepted: ' + $Mode)
		if ($Mode -notin @('api_failure', 'response_lost')) { Assert-RecoveryTest -Condition ($Mutations.Count -eq 0) -Message ('Unsafe mutation: ' + $Mode) }
		if ($Mode -in @('cleanup_false', 'cleanup_string', 'missing', 'partial', 'wrong_request', 'expired', 'budget_short')) { Assert-RecoveryTest -Condition ($Fixture.requests.Count -eq 0) -Message ('Unproven recovery made network call: ' + $Mode) }
		if ($Mode -in @('expired', 'budget_short', 'budget_after_read')) { Assert-RecoveryTest -Condition ($Result.failureCode -ceq 'recovery_publication_deadline') -Message 'Recovery deadline reason lost' }
	}
	$RequestsBefore = $Fixture.requests.Count
	Assert-RecoveryFailure -Action { Invoke-InitialPreparationRecovery -IntentPath $IntentPath -ResultPath $Fixture.resultPath -Attempt $Attempt -Runner $ExpectedRunner -RequestSha256 $RequestHash -OwnedCleanupVerified $true -Transport $Transport -ReadTicks $ReadClock } -Code 'recovery_evidence_exists'
	Assert-RecoveryTest -Condition ($Fixture.requests.Count -eq $RequestsBefore) -Message 'Repeated result path mutated routing'
}
$Clock.ticks = $Attempt.monotonicStartTicks + 1
foreach ($Malformed in @('duplicate_key', 'array_schema', 'duplicate_label', 'no_routing', 'wrong_runner', 'future_time', 'oversized', 'unknown_key')) {
	$Record = [Text.Encoding]::UTF8.GetString($OriginalBytes) | ConvertFrom-Json
	switch ($Malformed) {
		'array_schema' { $Record.schemaVersion = @(1) }
		'duplicate_label' { $Record.originalLabels += 'WINDOWS' }
		'no_routing' { $Record.originalLabels = @('Windows') }
		'wrong_runner' { $Record.runnerId = 22 }
		'future_time' { $Record.intendedAtTicks = $Clock.ticks + 1 }
		'unknown_key' { $Record | Add-Member -NotePropertyName unknown -NotePropertyValue 1 }
	}
	$Json = $Record | ConvertTo-Json -Depth 5 -Compress
	if ($Malformed -ceq 'duplicate_key') { $Json = $Json.Replace('{', '{"schemaVersion":1,') }
	if ($Malformed -ceq 'oversized') { $Json += (' ' * 16385) }
	$BadPath = Join-Path $FixtureRoot ($Malformed + '.json')
	[IO.File]::WriteAllText($BadPath, $Json, (New-Object Text.UTF8Encoding($false)))
	Assert-RecoveryFailure -Action { Read-InitialPreparationRecoveryIntent -Path $BadPath -Attempt $Attempt -Runner $ExpectedRunner -RequestSha256 $RequestHash -ReadTicks $ReadClock } -Code 'recovery_intent_invalid'
}
Write-Output "PASS: interruption recovery fixtures; retained $FixtureRoot"
