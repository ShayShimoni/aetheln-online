[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Invoke-PackagedSmokeTest.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnSmokeTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-Smoke([string] $Scenario, [string] $LogRoot, [int] $TimeoutSeconds = 8, [string] $ServerConnectionPattern = 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)') {
	& $Script `
		-ServerExecutable '/package/AethelnOnlineServer.sh' `
		-ServerLauncherExecutable $LauncherCommandName `
		-ServerLauncherArguments @('-NoProfile', '-File', $FakeLauncher, '-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput', '-Scenario', $Scenario) `
		-ClientExecutable $PowerShellExecutable `
		-ClientBaseArguments @('-NoProfile', '-File', $FakeClient, '{ClientId}', '{ServerEndpoint}', '{ServerMap}', $Scenario) `
		-ServerEndpoint '127.0.0.1:7777' `
		-ServerMap '/Game/Maps/StarterMap' `
		-LogRoot $LogRoot `
		-ServerReadyPattern 'Listening on {ServerEndpoint}.*{ServerMap}' `
		-ServerClientConnectedPattern $ServerConnectionPattern `
		-ClientConnectedPattern 'Connected {ClientId} to {ServerEndpoint}' `
		-ClientMapPattern 'Loaded {ServerMap}' `
		-TimeoutSeconds $TimeoutSeconds
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$PowerShellExecutable = (Get-Process -Id $PID).Path
	$LauncherCommandName = Split-Path -Leaf $PowerShellExecutable
	$FakeLauncher = Join-Path $FixtureRoot 'fake-launcher.ps1'
	$FakeClient = Join-Path $FixtureRoot 'fake-client.ps1'
	Set-Content -LiteralPath $FakeLauncher -Value @'
param([Alias('d')] [string] $Distribution, [Alias('u')] [string] $User, [Alias('exec')] [string] $ServerExecutable, [string] $Map, [string] $Scenario, [Parameter(ValueFromRemainingArguments)] [string[]] $Ignored)
Write-Output "Listening on 127.0.0.1:7777 map $Map"
if ($Scenario -ne 'missing-second') {
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden'
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51002, Name: overridden'
} else {
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden'
	Write-Output 'AddClientConnection: RemoteAddr: 127.0.0.1:51001, Name: overridden duplicate'
}
Start-Sleep -Seconds 20
'@ -Encoding UTF8
	Set-Content -LiteralPath $FakeClient -Value @'
param([string] $ClientId, [string] $Endpoint, [string] $Map, [string] $Scenario, [Parameter(ValueFromRemainingArguments)] [string[]] $Ignored)
if ($Scenario -eq 'early-exit' -and $ClientId -eq 'client-2') { exit 17 }
if ($Scenario -eq 'logged-error' -and $ClientId -eq 'client-1') { Write-Output 'Connection TIMED OUT while joining server' }
Write-Output "Connected $ClientId to $Endpoint"
Write-Output "Loaded $Map"
Start-Sleep -Seconds 20
'@ -Encoding UTF8

	$LogRoot = Join-Path $FixtureRoot 'success'
	Invoke-Smoke -Scenario success -LogRoot $LogRoot
	$Evidence = @(Get-Content -LiteralPath (Join-Path $LogRoot 'smoke-evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($Evidence.Count -ge 9) 'Evidence should include launch and correlated readiness observations.'
	Assert-True (-not @($Evidence | Where-Object { -not $_.schema -or -not $_.timestamp -or -not $_.process -or -not $_.role -or -not $_.event -or -not $_.source }).Count) 'Every evidence line should use the smoke evidence schema.'
	$ServerConnections = @($Evidence | Where-Object { $_.event -eq 'server_observed_connection' })
	Assert-True ($ServerConnections.Count -eq 2) 'Server evidence should contain exactly two unique observed connections.'
	Assert-True (@($ServerConnections.connection_id | Sort-Object -Unique).Count -eq 2) 'Server evidence should use distinct ConnectionId captures without mapping them to client names.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'client_map_confirmed' }).Count -eq 2) 'Both clients should confirm the requested map.'
	Assert-True (@($Evidence | Where-Object { $_.event -in @('client_connected', 'client_map_confirmed') -and $_.source -like '*client-*.stdout.log' }).Count -eq 4) 'Client evidence should come from redirected packaged-client stdout.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'server.log'))) 'WSL-style launch should not depend on a Windows server log path.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $LogRoot 'client-1.log'))) 'Client launch should not depend on Unreal accepting a Windows -log path.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'server_listening' -and $_.source -like '*server.stdout.log' }).Count -eq 1) 'Server readiness evidence should come from redirected WSL stdout.'
	Assert-True (@($Evidence | Where-Object { $_.event -eq 'process_started' -and $_.process -eq 'server' -and $_.source -eq $PowerShellExecutable }).Count -eq 1) 'PATH launcher resolution should produce one concrete executable string.'
	Write-Output 'PASS: correlated packaged connection evidence is emitted as JSONL'

	$EvidenceCountBeforeReuse = $Evidence.Count
	$Failure = $null
	try { Invoke-Smoke -Scenario success -LogRoot $LogRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'LogRoot.*must be absent or empty.*existing item.*unique clean directory') 'Reusing smoke evidence output should fail actionably.'
	$EvidenceAfterReuse = @(Get-Content -LiteralPath (Join-Path $LogRoot 'smoke-evidence.jsonl'))
	Assert-True ($EvidenceAfterReuse.Count -eq $EvidenceCountBeforeReuse) 'Rejected reuse must not append or overwrite run-specific evidence.'
	Write-Output 'PASS: non-empty LogRoot reuse is rejected before evidence is written'

	$Failure = $null
	try { Invoke-Smoke -Scenario missing-second -LogRoot (Join-Path $FixtureRoot 'missing') -TimeoutSeconds 3 } catch { $Failure = $_.Exception.Message }
	Write-Output "Observed missing-client failure: $Failure"
	Assert-True ($Failure -match 'two unique server connections.*only 1 unique.*server\.stdout\.log') 'A duplicate server connection line must not satisfy the two-connection requirement.'
	Write-Output 'PASS: duplicate server connection IDs do not count twice'

	$Failure = $null
	try { Invoke-Smoke -Scenario success -LogRoot (Join-Path $FixtureRoot 'invalid-pattern') -ServerConnectionPattern 'AddClientConnection:.*RemoteAddr: ([^,]+)' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must contain a named regex capture.*ConnectionId') 'The server connection contract should reject an unnamed identity capture.'
	Write-Output 'PASS: server connection pattern requires the ConnectionId capture'

	$Failure = $null
	try { Invoke-Smoke -Scenario early-exit -LogRoot (Join-Path $FixtureRoot 'exit') -TimeoutSeconds 10 } catch { $Failure = $_.Exception.Message }
	Write-Output "Observed early-exit failure: $Failure"
	Assert-True ($Failure -match 'client-2.*exited.*exit code.*client-2\.stdout\.log.*client-2\.stderr\.log') 'Early client exit should identify its role, exit-code field, and actionable redirected logs.'
	Write-Output 'PASS: early process exit fails actionably'

	$Failure = $null
	try { Invoke-Smoke -Scenario logged-error -LogRoot (Join-Path $FixtureRoot 'error') -TimeoutSeconds 10 } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'client-1 reported an error.*Connection TIMED OUT') 'A connection timeout log event should fail even when readiness text is present.'
	Write-Output 'PASS: connection-timeout source-log events fail the smoke'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
