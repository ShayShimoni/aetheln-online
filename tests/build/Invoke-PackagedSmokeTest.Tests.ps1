[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Invoke-PackagedSmokeTest.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnSmokeTests-{0}" -f [guid]::NewGuid().ToString('N'))
$SuiteCompleted = $false

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

$ParseErrors = $null
$Tokens = $null
$ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref] $Tokens, [ref] $ParseErrors)
$IdentityFunction = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-IsPreexistingProcessIdentity' }, $true))
Assert-True ($ParseErrors.Count -eq 0 -and $IdentityFunction.Count -eq 1) 'The process-identity helper must be parseable and uniquely testable.'
Invoke-Expression $IdentityFunction[0].Extent.Text
$OriginalStart = [DateTime]::UtcNow.AddMinutes(-5)
$ReusedStart = $OriginalStart.AddMinutes(1)
$IdentityBaseline = @{ '4242' = [long] $OriginalStart.Ticks }
Assert-True (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4242; StartTime = $OriginalStart }) $IdentityBaseline) 'A matching PID and start time must remain preexisting.'
Assert-True (-not (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4242; StartTime = $ReusedStart }) $IdentityBaseline)) 'A reused PID with a different start time must be treated as a new process.'
Assert-True (-not (Test-IsPreexistingProcessIdentity ([pscustomobject]@{ Id = 4343; StartTime = $OriginalStart }) $IdentityBaseline)) 'An unknown PID must be treated as a new process.'

function Test-EvidenceWriter {
	$EvidenceFunction = @($ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Write-Evidence' }, $true))
	Assert-True ($EvidenceFunction.Count -eq 1) 'The production evidence writer must be uniquely testable.'
	Invoke-Expression $EvidenceFunction[0].Extent.Text
	$EvidencePath = Join-Path $FixtureRoot 'writer-evidence.jsonl'
	$UnicodeDetail = 'Detail ' + [char] 0x00e9 + [char] 0x05e9 + [char] 0x4e16 + [char]::ConvertFromUtf32(0x1f525) + "`nsecond line"
	Write-Evidence 'writer' 'fixture' 'record-0' 'fixture' $UnicodeDetail 'connection-0'
	# This live reader permits append but denies read access to the writer. The
	# Windows PowerShell Add-Content provider can fail its sharing open or fall
	# back to a write-only stream and throw "Stream was not readable".
	$Reader = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Write)
	try {
		foreach ($Index in 1..20) { Write-Evidence 'writer' 'fixture' "record-$Index" 'fixture' $UnicodeDetail "connection-$Index" }
	} finally { $Reader.Dispose() }
	$Bytes = [System.IO.File]::ReadAllBytes($EvidencePath)
	Assert-True ($Bytes.Length -gt 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) 'The writer must preserve the Windows PowerShell UTF-8 BOM contract.'
	$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
	$Text = $StrictUtf8.GetString($Bytes, 3, $Bytes.Length - 3)
	Assert-True (-not $Text.Contains([string] [char] 0xfeff)) 'Appending must never insert another BOM into JSONL records.'
	$Lines = @([System.IO.File]::ReadAllLines($EvidencePath, $StrictUtf8))
	Assert-True ($Lines.Count -eq 21) 'Concurrent readers must not cause missing, duplicate, or split records.'
	$Records = @($Lines | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True (@($Records.event | Sort-Object -Unique).Count -eq 21) 'Every evidence event must occur exactly once.'
	foreach ($Index in 0..20) {
		Assert-True ($Records[$Index].event -eq "record-$Index" -and $Records[$Index].connection_id -eq "connection-$Index" -and $Records[$Index].detail -ceq $UnicodeDetail) 'The writer must preserve event order, connection identity, Unicode, and escaped newlines.'
	}
	$Lock = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
	$Timer = [System.Diagnostics.Stopwatch]::StartNew()
	$Failure = $null
	try {
		try { Write-Evidence 'writer' 'fixture' 'locked-record' 'fixture' 'must not append' } catch { $Failure = $_ }
	} finally { $Timer.Stop(); $Lock.Dispose() }
	Assert-True ($null -ne $Failure) 'An exclusive evidence lock must fail closed.'
	Assert-True ($Timer.Elapsed.TotalSeconds -lt 5) 'Sharing retries must fail within a bounded interval.'
	Assert-True ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($EvidencePath)) -ceq [Convert]::ToBase64String($Bytes)) 'A failed append open must preserve every existing byte.'
	Write-Evidence 'writer' 'fixture' 'record-21' 'fixture' $UnicodeDetail 'connection-21'
	$AfterLock = @([System.IO.File]::ReadAllLines($EvidencePath, $StrictUtf8) | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($AfterLock.Count -eq 22 -and $AfterLock[-1].event -eq 'record-21') 'Releasing the lock must permit the next append without replaying the failed record.'
	Write-Output 'PASS: actual evidence writer preserves UTF-8 JSONL under concurrent readers and fails closed under a bounded exclusive lock'
}

function Invoke-Smoke([string] $Scenario, [string] $LogRoot, [int] $TimeoutSeconds = 8, [string] $ServerConnectionPattern = 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)', [string] $ClientExecutable = '', [string[]] $ClientArguments = @()) {
	$SelectedClientExecutable = if ($ClientExecutable) { $ClientExecutable } else { $PackagedLauncher }
	$SelectedClientArguments = if ($ClientArguments.Count) { $ClientArguments } else { @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', $Scenario) }
	Assert-True ($SelectedClientExecutable.StartsWith($PackageRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) 'Every smoke fixture client must live inside its GUID-scoped package root before cleanup can run.'
	& $Script `
		-ServerExecutable '/package/AethelnOnlineServer.sh' `
		-ServerLauncherExecutable $LauncherCommandName `
		-ServerLauncherArguments @('-NoProfile', '-File', $FakeLauncher, '-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput', '-Scenario', $Scenario) `
		-ClientExecutable $SelectedClientExecutable `
		-ClientBaseArguments $SelectedClientArguments `
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
	Test-EvidenceWriter
	$PowerShellExecutable = (Get-Process -Id $PID).Path
	$LauncherCommandName = Split-Path -Leaf $PowerShellExecutable
	$FakeLauncher = Join-Path $FixtureRoot 'fake-launcher.ps1'
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
	$PackageRoot = Join-Path $FixtureRoot 'package'
	$RuntimeRoot = Join-Path $PackageRoot 'Binaries'
	New-Item -ItemType Directory -Path $RuntimeRoot | Out-Null
	$PackagedLauncher = Join-Path $PackageRoot 'ClientLauncher.exe'
	$PackagedRuntime = Join-Path $RuntimeRoot 'ClientRuntime.exe'
	$RuntimeClass = 'Runtime' + [guid]::NewGuid().ToString('N')
	$RuntimeSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class CLASS {
	private static bool ContainsCleanup(string path) {
		if (!File.Exists(path)) return false;
		using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
		using (StreamReader reader = new StreamReader(stream)) return reader.ReadToEnd().Contains("process_cleanup_started");
	}
	public static int Main(string[] args) {
		if (args.Length == 2) {
			File.WriteAllText(args[1] + ".ready", Process.GetCurrentProcess().Id.ToString());
			bool cleanupStarted = false;
			while (!cleanupStarted) {
				try { cleanupStarted = ContainsCleanup(args[0]); }
				catch (IOException) { }
				Thread.Sleep(25);
			}
			Thread.Sleep(500);
			Process delayed = Process.Start(Process.GetCurrentProcess().MainModule.FileName);
			File.WriteAllText(args[1], delayed.Id.ToString());
		}
		Thread.Sleep(60000);
		return 0;
	}
}
'@.Replace('CLASS', $RuntimeClass)
	Add-Type -TypeDefinition $RuntimeSource -OutputAssembly $PackagedRuntime -OutputType ConsoleApplication
	$LauncherClass = 'Launcher' + [guid]::NewGuid().ToString('N')
	$LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class CLASS {
	public static int Main(string[] args) {
		string clientId = args[0], endpoint = args[1], map = args[2], scenario = args[3];
		string root = AppDomain.CurrentDomain.BaseDirectory;
		if (scenario == "early-exit" && clientId == "client-2") return 17;
		if (scenario == "logged-error" && clientId == "client-1") Console.WriteLine("Connection TIMED OUT while joining server");
		if (scenario == "child-process" || scenario == "child-process-failure") {
			Process child = Process.Start(Path.Combine(root, "Binaries", "ClientRuntime.exe"));
			File.WriteAllText(Path.Combine(root, clientId + "-" + scenario + "-child.pid"), child.Id.ToString());
		}
		if (scenario != "child-process-failure") {
			Console.WriteLine("Connected " + clientId + " to " + endpoint);
			Console.WriteLine("Loaded " + map);
		}
		Thread.Sleep(20000);
		return 0;
	}
}
'@.Replace('CLASS', $LauncherClass)
	Add-Type -TypeDefinition $LauncherSource -OutputAssembly $PackagedLauncher -OutputType ConsoleApplication

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

	$ChildLogRoot = Join-Path $FixtureRoot 'child-process'
	$DelayedMarker = Join-Path $PackageRoot 'success-delayed-child.pid'
	$PreexistingRuntime = Start-Process -FilePath $PackagedRuntime -ArgumentList @((Join-Path $ChildLogRoot 'smoke-evidence.jsonl'), $DelayedMarker) -RedirectStandardOutput (Join-Path $FixtureRoot 'success-watcher.stdout.log') -RedirectStandardError (Join-Path $FixtureRoot 'success-watcher.stderr.log') -WindowStyle Hidden -PassThru
	try {
		$ReadyDeadline = [DateTime]::UtcNow.AddSeconds(5)
		while (-not (Test-Path -LiteralPath "$DelayedMarker.ready") -and [DateTime]::UtcNow -lt $ReadyDeadline) { Start-Sleep -Milliseconds 50 }
		Assert-True (Test-Path -LiteralPath "$DelayedMarker.ready") 'The preexisting watcher fixture must be ready before smoke process ownership is captured.'
		$ChildArguments = @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'child-process')
		Invoke-Smoke -Scenario child-process -LogRoot $ChildLogRoot -ClientExecutable $PackagedLauncher -ClientArguments $ChildArguments
		Assert-True (Test-Path -LiteralPath $DelayedMarker -PathType Leaf) "The success watcher must publish its delayed descendant PID before cleanup returns; retained evidence: $FixtureRoot."
		$ChildProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-child-process-child.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
		$DelayedProcessId = [int] (Get-Content -LiteralPath $DelayedMarker -Raw)
		Assert-True ($ChildProcessIds.Count -eq 2) 'The fixture must launch one differently named packaged runtime per client.'
		Assert-True (-not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $ChildProcessIds }).Count) 'Successful smoke cleanup must terminate differently named packaged client child processes.'
		Assert-True (-not (Get-Process -Id $DelayedProcessId -ErrorAction SilentlyContinue)) 'The bounded cleanup rescan must terminate a package process created during cleanup.'
		Assert-True (-not $PreexistingRuntime.HasExited) 'Smoke cleanup must preserve a preexisting process under the package root.'
	} finally {
		if (-not $PreexistingRuntime.HasExited) { Stop-Process -Id $PreexistingRuntime.Id -Force -ErrorAction SilentlyContinue }
		try { [void] $PreexistingRuntime.WaitForExit(5000) } catch { }
		$PreexistingRuntime.Dispose()
	}

	$FailureLogRoot = Join-Path $FixtureRoot 'child-process-failure'
	$FailureDelayedMarker = Join-Path $PackageRoot 'failure-delayed-child.pid'
	$PreexistingFailureRuntime = Start-Process -FilePath $PackagedRuntime -ArgumentList @((Join-Path $FailureLogRoot 'smoke-evidence.jsonl'), $FailureDelayedMarker) -RedirectStandardOutput (Join-Path $FixtureRoot 'failure-watcher.stdout.log') -RedirectStandardError (Join-Path $FixtureRoot 'failure-watcher.stderr.log') -WindowStyle Hidden -PassThru
	try {
		$ReadyDeadline = [DateTime]::UtcNow.AddSeconds(5)
		while (-not (Test-Path -LiteralPath "$FailureDelayedMarker.ready") -and [DateTime]::UtcNow -lt $ReadyDeadline) { Start-Sleep -Milliseconds 50 }
		Assert-True (Test-Path -LiteralPath "$FailureDelayedMarker.ready") 'The failure watcher fixture must be ready before smoke process ownership is captured.'
		$Failure = $null
		$FailureArguments = @('{ClientId}', '{ServerEndpoint}', '{ServerMap}', 'child-process-failure')
		try { Invoke-Smoke -Scenario child-process-failure -LogRoot $FailureLogRoot -TimeoutSeconds 3 -ClientExecutable $PackagedLauncher -ClientArguments $FailureArguments } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match 'Timed out.*client connection confirmation') "The failure fixture must reach client evidence timeout after spawning packaged runtimes. Actual failure: $Failure"
		Assert-True (Test-Path -LiteralPath $FailureDelayedMarker -PathType Leaf) "The failure watcher must publish its delayed descendant PID before cleanup returns; retained evidence: $FixtureRoot."
		$FailureChildProcessIds = @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'client-*-child-process-failure-child.pid' | ForEach-Object { [int] (Get-Content -LiteralPath $_.FullName -Raw) })
		$FailureDelayedProcessId = [int] (Get-Content -LiteralPath $FailureDelayedMarker -Raw)
		Assert-True ($FailureChildProcessIds.Count -eq 2 -and -not @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -in $FailureChildProcessIds }).Count) 'Failed smoke cleanup must terminate differently named packaged client child processes.'
		Assert-True (-not (Get-Process -Id $FailureDelayedProcessId -ErrorAction SilentlyContinue)) 'Failed smoke cleanup must rescan and terminate a package process created during cleanup.'
		Assert-True (-not $PreexistingFailureRuntime.HasExited) 'Failed smoke cleanup must preserve a preexisting process under the package root.'
		Write-Output 'PASS: bounded cleanup rescans remove delayed package processes without touching preexisting package processes'
	} finally {
		if (-not $PreexistingFailureRuntime.HasExited) { Stop-Process -Id $PreexistingFailureRuntime.Id -Force -ErrorAction SilentlyContinue }
		try { [void] $PreexistingFailureRuntime.WaitForExit(5000) } catch { }
		$PreexistingFailureRuntime.Dispose()
	}

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
	$ClientStarts = @(Get-ChildItem -LiteralPath $FixtureRoot -Filter 'smoke-evidence.jsonl' -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName | ForEach-Object { $_ | ConvertFrom-Json } } | Where-Object { $_.event -eq 'process_started' -and $_.role -eq 'client' })
	Assert-True ($ClientStarts.Count -ge 12) 'Isolation evidence must include client launches across success and failure scenarios.'
	Assert-True (-not @($ClientStarts | Where-Object { -not $_.source.StartsWith($PackageRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) }).Count) 'Every actual smoke client launch must remain inside this GUID-scoped package root.'
	Write-Output 'PASS: all smoke fixture client launches use an isolated package root'
	$SuiteCompleted = $true
}
finally {
	foreach ($FixtureProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
		try { $FixtureProcessPath = [string] $FixtureProcess.Path } catch { continue }
		if ($FixtureProcessPath -and $FixtureProcessPath.StartsWith($FixtureRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
			Stop-Process -Id $FixtureProcess.Id -Force -ErrorAction SilentlyContinue
			try { [void] $FixtureProcess.WaitForExit(5000) } catch { }
			$FixtureProcess.Dispose()
		}
	}
	if ($SuiteCompleted -and (Test-Path -LiteralPath $FixtureRoot)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
	elseif (Test-Path -LiteralPath $FixtureRoot) { Write-Output "Failed smoke fixture evidence retained: $FixtureRoot" }
}
