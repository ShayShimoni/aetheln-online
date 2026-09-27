[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$RunnerPath = Join-Path $ScriptsRoot 'Invoke-DeliveryHarness.ps1'
$CanonicalTests = @(
	'Test-DeliveryAdaptiveRouting.ps1',
	'Test-DeliveryArtifactSchemas.ps1',
	'Test-DeliveryCompositeCandidate.ps1',
	'Test-DeliveryExternalFileIngest.ps1',
	'Test-DeliveryHandoffValidation.ps1',
	'Test-DeliverySourceInspection.ps1',
	'Test-DeliveryStageLauncher.ps1',
	'Test-DeliveryStagePreflight.ps1',
	'Test-DeliveryVerifierProfileContract.ps1'
)
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
	'aetheln-delivery-harness-tests-' + [guid]::NewGuid().ToString('N')
)
$Assertions = 0

function Assert-True([bool] $Condition, [string] $Message) {
	$script:Assertions++
	if (-not $Condition) { throw $Message }
}

function Invoke-Native([string] $Executable, [string[]] $Arguments, [string] $WorkingDirectory) {
	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $Executable
	$StartInfo.Arguments = @($Arguments | ForEach-Object {
		if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
	}) -join ' '
	$StartInfo.WorkingDirectory = $WorkingDirectory
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) { throw "Could not start $Executable." }
		$StdOut = $Process.StandardOutput.ReadToEndAsync()
		$StdErr = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		return [pscustomobject]@{
			exitCode = $Process.ExitCode
			stdout = $StdOut.GetAwaiter().GetResult()
			stderr = $StdErr.GetAwaiter().GetResult()
		}
	} finally { $Process.Dispose() }
}

function New-FixtureRepository {
	param(
		[string] $Name,
		[hashtable] $Overrides = @{},
		[string[]] $Omitted = @(),
		[string[]] $ExtraPaths = @()
	)
	$Root = Join-Path $TestRoot $Name
	$FixtureScripts = Join-Path $Root '.agents\skills\orchestrate-delivery\scripts'
	$FixtureTests = Join-Path $FixtureScripts 'tests'
	$null = New-Item -ItemType Directory -Path $FixtureTests -Force
	Copy-Item -LiteralPath $RunnerPath -Destination $FixtureScripts
	foreach ($TestName in $CanonicalTests) {
		if ($Omitted -contains $TestName) { continue }
		$Body = if ($Overrides.ContainsKey($TestName)) {
			[string] $Overrides[$TestName]
		} else {
			"[Console]::Out.Write('stdout-$TestName'); [Console]::Error.Write('stderr-$TestName'); exit 0"
		}
		[IO.File]::WriteAllText((Join-Path $FixtureTests $TestName), $Body, [Text.UTF8Encoding]::new($false))
	}
	foreach ($ExtraPath in $ExtraPaths) {
		$FullPath = Join-Path $FixtureTests $ExtraPath
		$null = New-Item -ItemType Directory -Path (Split-Path -Parent $FullPath) -Force
		[IO.File]::WriteAllText($FullPath, 'exit 0', [Text.UTF8Encoding]::new($false))
	}
	$null = Invoke-Native 'git.exe' @('init', '--quiet') $Root
	$null = Invoke-Native 'git.exe' @('config', 'user.name', 'Aetheln Fixture') $Root
	$null = Invoke-Native 'git.exe' @('config', 'user.email', 'fixture@example.invalid') $Root
	$null = Invoke-Native 'git.exe' @('add', '--all') $Root
	$Commit = Invoke-Native 'git.exe' @('commit', '--quiet', '-m', 'fixture') $Root
	if ($Commit.exitCode -ne 0) { throw "Fixture commit failed: $($Commit.stderr)" }
	$Revision = (Invoke-Native 'git.exe' @('rev-parse', 'HEAD') $Root).stdout.Trim()
	return [pscustomobject]@{ root = $Root; revision = $Revision }
}

function Invoke-FixtureHarness {
	param(
		$Fixture,
		[string] $Revision = $Fixture.revision,
		[int] $PerTestTimeoutSeconds = 10,
		[int] $MaximumChildOutputBytes = 262144,
		[int] $CleanupGraceMilliseconds = 100
	)
	$ReportPath = Join-Path $Fixture.root ('report-' + [guid]::NewGuid().ToString('N') + '.json')
	$Arguments = @(
		'-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
		(Join-Path $Fixture.root '.agents\skills\orchestrate-delivery\scripts\Invoke-DeliveryHarness.ps1'),
		'-RepositoryRoot', $Fixture.root,
		'-Repository', 'ShayShimoni/aetheln-online',
		'-SourceRevision', $Revision,
		'-RunId', '9001',
		'-RunAttempt', '2',
		'-OutputPath', $ReportPath,
		'-PerTestTimeoutSeconds', [string] $PerTestTimeoutSeconds,
		'-OverallTimeoutSeconds', '120',
		'-MaximumChildOutputBytes', [string] $MaximumChildOutputBytes,
		'-CleanupGraceMilliseconds', [string] $CleanupGraceMilliseconds
	)
	$Result = Invoke-Native 'powershell.exe' $Arguments $Fixture.root
	$Report = if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
		Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
	} else { $null }
	return [pscustomobject]@{ process = $Result; report = $Report; reportPath = $ReportPath }
}

function Get-Base64Text($Value) {
	return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string] $Value))
}

try {
	Assert-True (Test-Path -LiteralPath $RunnerPath -PathType Leaf) 'Delivery harness runner is missing.'

	$SuccessFixture = New-FixtureRepository -Name 'success'
	$Success = Invoke-FixtureHarness $SuccessFixture
	$SuccessFailures = if ($null -ne $Success.report) { @($Success.report.tests | Where-Object status -eq 'failed' | ForEach-Object { "$($_.name):$($_.failureReason):$($_.exitCode):signal=$($_.resultSignaled):out=$($_.stdoutBytes):err=$($_.stderrBytes)" }) -join ',' } else { 'no-report' }
	Assert-True ($Success.process.exitCode -eq 0) "Successful harness exited $($Success.process.exitCode): stdout=$($Success.process.stdout) stderr=$($Success.process.stderr) failures=$SuccessFailures"
	Assert-True ($null -ne $Success.report) 'Successful harness did not publish a report.'
	Assert-True (@($Success.report.PSObject.Properties.Name).Count -eq 18) 'Report root is not closed.'
	foreach ($Name in @('schemaVersion','reportType','repository','revision','actualRevision','runId','runAttempt','startedUtc','finishedUtc','terminal','complete','succeeded','cleanupVerified','infrastructureFailure','failureReason','inventory','tests','summary')) {
		Assert-True (@($Success.report.PSObject.Properties.Name) -ccontains $Name) "Report root is missing $Name."
	}
	Assert-True ($Success.report.schemaVersion -eq 1) 'Schema version is wrong.'
	Assert-True ($Success.report.reportType -ceq 'delivery-harness-v1') 'Report type is wrong.'
	Assert-True ($Success.report.revision -ceq $SuccessFixture.revision) 'Expected revision was not preserved.'
	Assert-True ($Success.report.actualRevision -ceq $SuccessFixture.revision) 'Actual revision was not preserved.'
	Assert-True ($Success.report.runId -ceq '9001' -and $Success.report.runAttempt -eq 2) 'Run identity was not preserved.'
	Assert-True ($Success.report.terminal -eq $true -and $Success.report.complete -eq $true -and $Success.report.succeeded -eq $true) 'Successful terminal state is wrong.'
	Assert-True ($Success.report.cleanupVerified -eq $true -and $Success.report.infrastructureFailure -eq $false) 'Successful cleanup state is wrong.'
	Assert-True ($Success.report.inventory.valid -eq $true -and @($Success.report.tests).Count -eq 9) 'Canonical inventory was not executed exactly once.'
	Assert-True ((@($Success.report.tests.name) -join ',') -ceq ($CanonicalTests -join ',')) 'Test result order is not canonical.'
	foreach ($Child in @($Success.report.tests)) {
		Assert-True (@($Child.PSObject.Properties.Name).Count -eq 20) "Child result $($Child.name) is not closed."
		Assert-True ($Child.status -ceq 'passed' -and $Child.exitCode -eq 0) "Child result $($Child.name) did not pass."
		Assert-True ($Child.outputCaptured -eq $true -and $Child.cleanupVerified -eq $true) "Child result $($Child.name) did not preserve output/cleanup."
		Assert-True ((Get-Base64Text $Child.stdoutBase64) -ceq "stdout-$($Child.name)") "Child stdout $($Child.name) was not exact."
		Assert-True ((Get-Base64Text $Child.stderrBase64) -ceq "stderr-$($Child.name)") "Child stderr $($Child.name) was not exact."
	}

	$NonzeroFixture = New-FixtureRepository -Name 'nonzero' -Overrides @{
		'Test-DeliveryArtifactSchemas.ps1' = "[Console]::Out.Write('exact-out'); [Console]::Error.Write('exact-error'); exit 7"
	}
	Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $NonzeroFixture.root '.agents\skills\orchestrate-delivery\scripts\tests\Test-DeliveryArtifactSchemas.ps1')) -match 'exit 7') 'Nonzero fixture override was not materialized.'
	$Nonzero = Invoke-FixtureHarness $NonzeroFixture
	$NonzeroChild = @($Nonzero.report.tests | Where-Object name -ceq 'Test-DeliveryArtifactSchemas.ps1')[0]
	Assert-True ($Nonzero.process.exitCode -eq 1 -and $Nonzero.report.succeeded -eq $false) "A nonzero child did not fail the harness (exit=$($Nonzero.process.exitCode), succeeded=$($Nonzero.report.succeeded), childExit=$($NonzeroChild.exitCode), reason=$($NonzeroChild.failureReason))."
	Assert-True ($NonzeroChild.exitCode -eq 7 -and $NonzeroChild.failureReason -ceq 'nonzero_exit') 'A nonzero child result was not preserved.'
	Assert-True ((Get-Base64Text $NonzeroChild.stdoutBase64) -ceq 'exact-out') 'Nonzero stdout was not exact.'
	Assert-True ((Get-Base64Text $NonzeroChild.stderrBase64) -ceq 'exact-error') 'Nonzero stderr was not exact.'

	$MissingFixture = New-FixtureRepository -Name 'missing' -Omitted @('Test-DeliveryStagePreflight.ps1')
	$Missing = Invoke-FixtureHarness $MissingFixture
	Assert-True ($Missing.process.exitCode -eq 1 -and $Missing.report.failureReason -ceq 'inventory_invalid') 'A missing canonical test did not fail closed.'
	Assert-True (@($Missing.report.inventory.missing) -contains 'Test-DeliveryStagePreflight.ps1') 'Missing identity was not reported.'
	Assert-True (@($Missing.report.tests).Count -eq 0) 'Invalid inventory executed tests.'

	$DuplicateFixture = New-FixtureRepository -Name 'duplicate' -ExtraPaths @('nested\Test-DeliveryAdaptiveRouting.ps1')
	$Duplicate = Invoke-FixtureHarness $DuplicateFixture
	Assert-True ($Duplicate.process.exitCode -eq 1 -and $Duplicate.report.failureReason -ceq 'inventory_invalid') 'A duplicate canonical identity did not fail closed.'
	Assert-True (@($Duplicate.report.inventory.duplicates) -contains 'Test-DeliveryAdaptiveRouting.ps1') 'Duplicate identity was not reported.'

	$UnexpectedFixture = New-FixtureRepository -Name 'unexpected' -ExtraPaths @('Test-DeliveryUnexpected.ps1')
	$Unexpected = Invoke-FixtureHarness $UnexpectedFixture
	Assert-True ($Unexpected.process.exitCode -eq 1 -and @($Unexpected.report.inventory.unexpected) -contains 'Test-DeliveryUnexpected.ps1') 'An unexpected delivery test did not fail closed.'

	$TimeoutFixture = New-FixtureRepository -Name 'timeout' -Overrides @{
		'Test-DeliveryAdaptiveRouting.ps1' = 'Start-Sleep -Seconds 10; exit 0'
	}
	$Timeout = Invoke-FixtureHarness -Fixture $TimeoutFixture -PerTestTimeoutSeconds 1
	$TimeoutChild = @($Timeout.report.tests | Where-Object name -ceq 'Test-DeliveryAdaptiveRouting.ps1')[0]
	Assert-True ($Timeout.process.exitCode -eq 1 -and $TimeoutChild.timedOut -eq $true) 'A timed-out child did not fail closed.'
	Assert-True ($TimeoutChild.cleanupVerified -eq $true) 'Timed-out child cleanup was not proven.'

	$LeakFixture = New-FixtureRepository -Name 'leak' -Overrides @{
		'Test-DeliveryAdaptiveRouting.ps1' = '$null = Start-Process powershell.exe -ArgumentList ''-NoProfile -Command Start-Sleep -Seconds 30'' -WindowStyle Hidden -PassThru; exit 0'
	}
	$Leak = Invoke-FixtureHarness -Fixture $LeakFixture -CleanupGraceMilliseconds 50
	$LeakChild = @($Leak.report.tests | Where-Object name -ceq 'Test-DeliveryAdaptiveRouting.ps1')[0]
	Assert-True ($Leak.process.exitCode -eq 1 -and $LeakChild.failureReason -ceq 'leaked_child') 'A leaked child did not fail closed.'
	Assert-True ($LeakChild.cleanupVerified -eq $true) 'Leaked child termination was not proven.'

	$OversizeFixture = New-FixtureRepository -Name 'oversize' -Overrides @{
		'Test-DeliveryAdaptiveRouting.ps1' = '[Console]::Out.Write((''x'' * 4096)); exit 0'
	}
	$Oversize = Invoke-FixtureHarness -Fixture $OversizeFixture -MaximumChildOutputBytes 1024
	$OversizeChild = @($Oversize.report.tests | Where-Object name -ceq 'Test-DeliveryAdaptiveRouting.ps1')[0]
	Assert-True ($Oversize.process.exitCode -eq 1 -and $OversizeChild.outputLimitExceeded -eq $true) 'Oversized output did not fail closed.'
	Assert-True ($OversizeChild.outputCaptured -eq $false -and $null -eq $OversizeChild.stdoutBase64) 'Oversized output was silently truncated/published.'

	$WrongIdentity = Invoke-FixtureHarness -Fixture $SuccessFixture -Revision ('f' * 40)
	Assert-True ($WrongIdentity.process.exitCode -eq 1 -and $WrongIdentity.report.failureReason -ceq 'identity_mismatch') 'A wrong source identity did not fail closed.'
	Assert-True (@($WrongIdentity.report.tests).Count -eq 0) 'Wrong source identity executed tests.'

	Write-Output "PASS: $Assertions delivery harness runner assertions"
} finally {
	if (Test-Path -LiteralPath $TestRoot -PathType Container) {
		Remove-Item -LiteralPath $TestRoot -Recurse -Force
	}
}
