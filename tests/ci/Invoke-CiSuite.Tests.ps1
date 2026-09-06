[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Runner = Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiSuite.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnCiSuiteTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True {
	param(
		[Parameter(Mandatory)]
		[bool] $Condition,
		[Parameter(Mandatory)]
		[string] $Message
	)

	if (-not $Condition) {
		throw "Assertion failed: $Message"
	}
}

function Invoke-Runner {
	param(
		[Parameter(Mandatory)]
		[string] $ManifestPath,
		[Parameter(Mandatory)]
		[string] $ReportPath,
		[string] $StopAfterMarker
	)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
	$StartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`" -ChecksPath `"$ManifestPath`" -ReportPath `"$ReportPath`""
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) { throw 'Could not start the CI runner fixture.' }
		$StandardOutput = $Process.StandardOutput.ReadToEndAsync()
		$StandardError = $Process.StandardError.ReadToEndAsync()
		if ($StopAfterMarker) {
			$Deadline = [DateTime]::UtcNow.AddSeconds(15)
			while (-not (Test-Path -LiteralPath $StopAfterMarker) -and -not $Process.HasExited -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 20 }
			Assert-True -Condition (Test-Path -LiteralPath $StopAfterMarker) -Message 'The cancellation fixture must launch its descendant before the parent is stopped.'
			$Process.Kill()
		}
		Assert-True -Condition ($Process.WaitForExit(90000)) -Message 'The synthetic runner fixture exceeded its 90-second guard.'
		$Output = @(
			@($StandardOutput.GetAwaiter().GetResult() -split "`r?`n")
			@($StandardError.GetAwaiter().GetResult() -split "`r?`n")
		) | Where-Object { -not [string]::IsNullOrEmpty($_) }
		$ExitCode = $Process.ExitCode
	}
	finally {
		if (-not $Process.HasExited) { $Process.Kill(); [void] $Process.WaitForExit(5000) }
		$Process.Dispose()
		$ErrorActionPreference = $PreviousPreference
	}
	return @{ Output = $Output; ExitCode = $ExitCode }
}

function Assert-CheckShape {
	param(
		[Parameter(Mandatory)] $Check
	)

	foreach ($Field in @('name', 'tier', 'status', 'durationSeconds', 'command', 'message')) {
		Assert-True -Condition ($null -ne $Check.PSObject.Properties[$Field]) -Message "Check '$($Check | ConvertTo-Json -Compress)' is missing field '$Field'."
	}
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$RunnerSource = Get-Content -LiteralPath $Runner -Raw
	# Drive the real completion boundary with deterministic job-accounting
	# samples. A signaled root handle need not mean its job is already empty.
	$RunnerAst = [Management.Automation.Language.Parser]::ParseInput($RunnerSource, [ref] $null, [ref] $null)
	foreach ($FunctionName in @('Get-OutputTail', 'Wait-CiJobQuiescence', 'Complete-CiCheck')) {
		$Definition = $RunnerAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $FunctionName }, $false)
		if ($null -ne $Definition) { . ([scriptblock]::Create($Definition.Extent.Text)) }
	}
	function Invoke-CompletionFixture {
		param([int] $ExitCode = 0, [bool] $HasResult = $true, [switch] $Persistent, [switch] $QueryFailure, [switch] $CleanupFailure)
		$Job = [pscustomobject]@{ Samples = 0; Disposals = 0; Persistent = $Persistent.IsPresent; QueryFailure = $QueryFailure.IsPresent; CleanupFailure = $CleanupFailure.IsPresent }
		$Job | Add-Member ScriptMethod ActiveProcesses {
			$this.Samples++
			if ($this.QueryFailure) { throw 'fixture job accounting failure' }
			if ($this.Persistent -or $this.Samples -le 2) { return 1 }
			return 0
		}
		$Job | Add-Member ScriptMethod Dispose {
			$this.Disposals++
			if ($this.CleanupFailure -and $this.Disposals -eq 1) { throw 'fixture job cleanup failure' }
		}
		$Process = [pscustomobject]@{ ExitCode = $ExitCode }
		$Process | Add-Member ScriptMethod WaitForExit {}
		$Process | Add-Member ScriptMethod Dispose {}
		$Output = [Threading.Tasks.TaskCompletionSource[string]]::new()
		$Output.SetResult('fixture completed output')
		$ErrorOutput = [Threading.Tasks.TaskCompletionSource[string]]::new()
		$ErrorOutput.SetResult('')
		$ResultGate = [Threading.EventWaitHandle]::new($HasResult, [Threading.EventResetMode]::ManualReset)
		$Gate = [Threading.EventWaitHandle]::new($true, [Threading.EventResetMode]::ManualReset)
		$script:Results = [object[]]::new(1)
		$script:InfrastructureFailed = $false
		$Elapsed = [Diagnostics.Stopwatch]::StartNew()
		Complete-CiCheck -Running @{
			Check = @{ Index = 0; Name = 'completion-fixture'; Tier = 'advisory'; CommandText = 'fixture' }
			Child = @{ Process = $Process; Job = $Job; StandardOutput = $Output.Task; StandardError = $ErrorOutput.Task; Gate = $Gate; ResultGate = $ResultGate }
			Stopwatch = $Elapsed
		} | Out-Null
		return @{ Result = $script:Results[0]; InfrastructureFailed = $script:InfrastructureFailed; Job = $Job; Elapsed = $Elapsed.Elapsed.TotalSeconds }
	}
	$Transient = Invoke-CompletionFixture
	Assert-True -Condition ($Transient.Result.status -eq 'passed' -and -not $Transient.InfrastructureFailed -and $Transient.Job.Samples -eq 3) -Message 'A completed check must allow transient owned-process accounting to reach zero before classifying a leak.'
	$Nonzero = Invoke-CompletionFixture -ExitCode 7
	Assert-True -Condition ($Nonzero.Result.status -eq 'failed' -and -not $Nonzero.InfrastructureFailed) -Message 'Quiescence must preserve the actual nonzero check exit without inventing an infrastructure failure.'
	$Missing = Invoke-CompletionFixture -HasResult $false
	Assert-True -Condition ($Missing.Result.status -eq 'failed' -and $Missing.InfrastructureFailed -and $Missing.Result.message -match 'did not return a complete check result') -Message 'Quiescence must not turn an incomplete bootstrap result into success.'
	$Persistent = Invoke-CompletionFixture -Persistent
	Assert-True -Condition ($Persistent.Result.status -eq 'failed' -and $Persistent.InfrastructureFailed -and $Persistent.Job.Disposals -gt 0 -and $Persistent.Elapsed -lt 10 -and $Persistent.Result.message -match 'owned process') -Message 'A persistent owned descendant must fail and be cleaned within the bounded quiescence grace.'
	$QueryFailure = Invoke-CompletionFixture -QueryFailure
	Assert-True -Condition ($QueryFailure.Result.status -eq 'failed' -and $QueryFailure.InfrastructureFailed -and $QueryFailure.Job.Disposals -gt 0 -and $QueryFailure.Result.message -match 'fixture job accounting failure') -Message 'Job-accounting failure must fail closed and still clean the owned tree.'
	$CleanupFailure = Invoke-CompletionFixture -CleanupFailure
	Assert-True -Condition ($CleanupFailure.Result.status -eq 'failed' -and $CleanupFailure.InfrastructureFailed -and $CleanupFailure.Result.message -match 'fixture job cleanup failure') -Message 'Job cleanup failure must never publish a passing result.'
	Write-Output 'PASS: bounded job quiescence separates transient termination from persistent leaks and preserves failures'
	Assert-True -Condition ($RunnerSource -match 'CreateNoWindow\s*=\s*\$true') -Message 'CI child PowerShell processes must be created without windows.'
	Assert-True -Condition ($RunnerSource -notmatch '&\s+powershell\.exe\s+@ArgumentList') -Message 'CI checks must not use direct visible powershell.exe child invocation.'
	$AnalyzerCommandMatch = [regex]::Match(
		$RunnerSource,
		"(?m)^\s*command\s*=\s*'(?<command>.*)'\s*$"
	)
	Assert-True -Condition $AnalyzerCommandMatch.Success -Message 'The default PSScriptAnalyzer command must be discoverable.'
	$AnalyzerCommand = $AnalyzerCommandMatch.Groups['command'].Value -replace "''", "'"
	Assert-True -Condition ($AnalyzerCommand -notmatch '-Path\s+scripts,\s*tests') -Message 'PSScriptAnalyzer must receive one path at a time.'

	$AnalyzerFixtureCommand = @"
function Invoke-ScriptAnalyzer {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string] `$Path,
		[switch] `$Recurse
	)
	if (`$Path -eq 'tests') {
		Write-Error 'fixture analyzer failure'
	}
}
$AnalyzerCommand
"@
	$AnalyzerManifest = Join-Path $FixtureRoot 'analyzer-manifest.json'
	$AnalyzerChecks = @(
		@{ name = 'fixture-analyzer'; tier = 'advisory'; command = $AnalyzerFixtureCommand }
	)
	[System.IO.File]::WriteAllText($AnalyzerManifest, (ConvertTo-Json -InputObject $AnalyzerChecks -Depth 4))
	$AnalyzerReport = Join-Path $FixtureRoot 'analyzer-report.json'
	$AnalyzerRun = Invoke-Runner -ManifestPath $AnalyzerManifest -ReportPath $AnalyzerReport
	Assert-True -Condition ($AnalyzerRun.ExitCode -eq 0) -Message 'An advisory analyzer failure must not fail the required CI suite.'
	$AnalyzerResult = (Get-Content -LiteralPath $AnalyzerReport -Raw | ConvertFrom-Json).checks[0]
	Assert-True -Condition ($AnalyzerResult.status -eq 'failed') -Message 'A PSScriptAnalyzer invocation error must not be reported as passed.'
	Assert-True -Condition ($AnalyzerResult.message -match 'fixture analyzer failure') -Message "The analyzer failure must remain actionable in the report: $($AnalyzerResult.message)"
	Write-Output 'PASS: PSScriptAnalyzer path and invocation failures fail closed'

	$PassScript = Join-Path $FixtureRoot 'pass.ps1'
	[System.IO.File]::WriteAllText($PassScript, "Write-Output 'fixture pass output'`nexit 0`n")
	$FailScript = Join-Path $FixtureRoot 'fail.ps1'
	[System.IO.File]::WriteAllText($FailScript, "throw 'fixture failure text'`n")
	$AdvisoryFailScript = Join-Path $FixtureRoot 'advisory-fail.ps1'
	[System.IO.File]::WriteAllText($AdvisoryFailScript, "throw 'advisory fixture failure'`n")

	$AdvisoryManifest = Join-Path $FixtureRoot 'advisory-manifest.json'
	$AdvisoryChecks = @(
		@{ name = 'fixture-pass'; tier = 'required'; script = $PassScript },
		@{ name = 'fixture-command-pass'; tier = 'advisory'; command = "Write-Output 'command fixture output'; exit 0" },
		@{ name = 'fixture-advisory-fail'; tier = 'advisory'; script = $AdvisoryFailScript },
		@{ name = 'fixture-advisory-skip'; tier = 'advisory'; script = $PassScript; requiredModule = 'AethelnNoSuchModuleFixture' }
	)
	[System.IO.File]::WriteAllText($AdvisoryManifest, (ConvertTo-Json -InputObject $AdvisoryChecks -Depth 4))
	$AdvisoryReport = Join-Path $FixtureRoot 'advisory-report.json'

	$AdvisoryRun = Invoke-Runner -ManifestPath $AdvisoryManifest -ReportPath $AdvisoryReport
	Assert-True -Condition ($AdvisoryRun.ExitCode -eq 0) -Message "Advisory-only failures must exit 0, got $($AdvisoryRun.ExitCode): $($AdvisoryRun.Output -join "`n")"
	Assert-True -Condition (Test-Path -LiteralPath $AdvisoryReport) -Message 'The machine-readable report must be written.'
	$Report = (Get-Content -LiteralPath $AdvisoryReport -Raw) | ConvertFrom-Json
	foreach ($Field in @('schemaVersion', 'revision', 'startedUtc', 'finishedUtc', 'checks', 'summary')) {
		Assert-True -Condition ($null -ne $Report.PSObject.Properties[$Field]) -Message "Report is missing field '$Field'."
	}
	Assert-True -Condition (@($Report.checks).Count -eq 4) -Message 'Report must contain one record per manifest check.'
	foreach ($Check in $Report.checks) {
		Assert-CheckShape -Check $Check
	}
	$PassCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-pass' })[0]
	Assert-True -Condition ($PassCheck.status -eq 'passed' -and $PassCheck.tier -eq 'required') -Message 'The passing required check must be reported as passed.'
	$CommandCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-command-pass' })[0]
	Assert-True -Condition ($CommandCheck.status -eq 'passed' -and $CommandCheck.tier -eq 'advisory') -Message 'The passing command check must capture exit code 0 and be reported as passed.'
	Assert-True -Condition ($CommandCheck.command -match '-Command') -Message 'The report must record the -Command invocation for command checks.'
	Assert-True -Condition ($CommandCheck.message -match 'command fixture output') -Message 'The command check message must carry the captured output.'
	$AdvisoryFail = @($Report.checks | Where-Object { $_.name -eq 'fixture-advisory-fail' })[0]
	Assert-True -Condition ($AdvisoryFail.status -eq 'failed' -and $AdvisoryFail.tier -eq 'advisory') -Message 'The advisory failure must be reported as failed with tier advisory.'
	Assert-True -Condition ($AdvisoryFail.message -match 'advisory fixture failure') -Message 'The advisory failure message must carry the captured error text.'
	$Skipped = @($Report.checks | Where-Object { $_.name -eq 'fixture-advisory-skip' })[0]
	Assert-True -Condition ($Skipped.status -eq 'skipped' -and $Skipped.message -match 'AethelnNoSuchModuleFixture') -Message 'The module-gated check must be reported as skipped with a reason.'
	Assert-True -Condition ($Report.summary.requiredFailed -eq 0) -Message 'Advisory failures must not count as required failures.'
	Write-Output 'PASS: advisory failures and skips report machine-readably and exit 0'
	Write-Output 'PASS: a command manifest entry runs via -Command with its exit code captured'

	$RequiredManifest = Join-Path $FixtureRoot 'required-manifest.json'
	$RequiredChecks = @(
		@{ name = 'fixture-pass'; tier = 'required'; script = $PassScript },
		@{ name = 'fixture-required-fail'; tier = 'required'; script = $FailScript }
	)
	[System.IO.File]::WriteAllText($RequiredManifest, (ConvertTo-Json -InputObject $RequiredChecks -Depth 4))
	$RequiredReport = Join-Path $FixtureRoot 'required-report.json'

	$RequiredRun = Invoke-Runner -ManifestPath $RequiredManifest -ReportPath $RequiredReport
	Assert-True -Condition ($RequiredRun.ExitCode -ne 0) -Message 'A required-check failure must exit nonzero.'
	Assert-True -Condition (Test-Path -LiteralPath $RequiredReport) -Message "A required-check failure must still write its report. Output: $($RequiredRun.Output -join "`n")"
	$Report = (Get-Content -LiteralPath $RequiredReport -Raw) | ConvertFrom-Json
	$FailCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-required-fail' })[0]
	Assert-True -Condition ($FailCheck.status -eq 'failed' -and $FailCheck.tier -eq 'required') -Message 'The required failure must be reported as failed.'
	Assert-True -Condition ($FailCheck.message -match 'fixture failure text') -Message 'The required failure message must carry the captured error text.'
	Assert-True -Condition ($FailCheck.command -match 'powershell\.exe') -Message 'The report must record the exact child command.'
	Assert-True -Condition ($Report.summary.requiredFailed -eq 1) -Message 'The summary must count the required failure.'
	Assert-True -Condition (($RequiredRun.Output -join "`n") -match 'fixture failure text') -Message 'The console output must include the actionable failure tail.'
	Write-Output 'PASS: a required-check failure exits nonzero with actionable output'

	# File handshakes prove overlap and barriers without treating elapsed time as proof.
	$SchedulerRoot = Join-Path $FixtureRoot 'scheduler'
	New-Item -ItemType Directory -Path $SchedulerRoot | Out-Null
	$SchedulerPrelude = @'
$ErrorActionPreference = 'Stop'
function Wait-Marker([string] $Name) {
	$Deadline = [DateTime]::UtcNow.AddSeconds(15)
	while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $Name))) {
		if ([DateTime]::UtcNow -gt $Deadline) { throw "Timed out waiting for $Name" }
		Start-Sleep -Milliseconds 20
	}
}
function Mark([string] $Name) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot $Name), 'observed') }
'@
	$SchedulerBodies = @(
		"Mark 'a.started'; Wait-Marker 'b.done'; Wait-Marker 'c.started'; Mark 'a.done'",
		"Mark 'b.started'; Wait-Marker 'a.started'; if (Test-Path (Join-Path `$PSScriptRoot 'c.started')) { throw 'Third check started before a slot was free' }; Mark 'b.done'",
		"if (-not (Test-Path (Join-Path `$PSScriptRoot 'b.done'))) { throw 'More than two checks started' }; Mark 'c.started'; Wait-Marker 'a.done'; Mark 'c.done'",
		"foreach (`$Name in @('a.done', 'b.done', 'c.done')) { if (-not (Test-Path (Join-Path `$PSScriptRoot `$Name))) { throw 'Serial barrier overlapped preceding checks' } }; Mark 'barrier.done'",
		"if (-not (Test-Path (Join-Path `$PSScriptRoot 'barrier.done'))) { throw 'Check crossed serial barrier' }; Mark 'd.started'; Mark 'd.done'"
	)
	# Smoke observes package-process quiescence and is deliberately not eligible
	# for overlap. Its observed concurrent failure must not be hidden by retries.
	$RunnerSource = Get-Content -LiteralPath $Runner -Raw
	$ConcurrentLine = @($RunnerSource -split "\r?\n" | Where-Object { $_ -match '^\$ConcurrentChecks = ' })
	Assert-True -Condition ($ConcurrentLine.Count -eq 1 -and $ConcurrentLine[0] -notmatch "'packaged-smoke-test-tests'") -Message 'Packaged smoke fixtures must remain a required serial barrier, not a concurrency experiment.'
	$SchedulerNames = @('build-packaged-artifacts-tests', 'network-authority-spike-tests', 'engine-runner-gate-tests', 'packaged-smoke-test-tests', 'unreal-automation-tests')
	$SchedulerChecks = @(for ($Index = 0; $Index -lt $SchedulerNames.Count; $Index++) {
		$FixtureScript = Join-Path $SchedulerRoot "$Index.ps1"
		[IO.File]::WriteAllText($FixtureScript, ($SchedulerPrelude + "`n" + $SchedulerBodies[$Index]))
		@{ name = $SchedulerNames[$Index]; tier = 'required'; script = $FixtureScript }
	})
	$SchedulerManifest = Join-Path $FixtureRoot 'scheduler-manifest.json'
	$SchedulerReport = Join-Path $FixtureRoot 'scheduler-report.json'
	[IO.File]::WriteAllText($SchedulerManifest, (ConvertTo-Json -InputObject $SchedulerChecks -Depth 4))
	$SchedulerRun = Invoke-Runner -ManifestPath $SchedulerManifest -ReportPath $SchedulerReport
	Assert-True -Condition ($SchedulerRun.ExitCode -eq 0) -Message "Allowlisted checks must overlap with two slots and serial barriers: $($SchedulerRun.Output -join "`n")"
	$Report = Get-Content -LiteralPath $SchedulerReport -Raw | ConvertFrom-Json
	Assert-True -Condition (($Report.checks.name -join ',') -ceq ($SchedulerNames -join ',')) -Message 'Completion order must not change manifest-order report records.'
	Assert-True -Condition ($Report.schemaVersion -eq 1 -and $Report.summary.passed -eq 5) -Message 'The scheduler must preserve report schema and one passing record per check.'
	foreach ($Check in $Report.checks) { Assert-CheckShape -Check $Check }
	Write-Output 'PASS: two-slot overlap, serial barriers, and manifest-order reports'

	$DuplicateMarker = Join-Path $FixtureRoot 'duplicate-launched.txt'
	$DuplicateManifest = Join-Path $FixtureRoot 'duplicate-manifest.json'
	$DuplicateChecks = @(
		@{ name = 'duplicate'; tier = 'required'; command = "[IO.File]::WriteAllText('$DuplicateMarker', 'must not run')" },
		@{ name = 'duplicate'; tier = 'required'; command = 'exit 0' }
	)
	[IO.File]::WriteAllText($DuplicateManifest, (ConvertTo-Json -InputObject $DuplicateChecks -Depth 4))
	$DuplicateRun = Invoke-Runner -ManifestPath $DuplicateManifest -ReportPath (Join-Path $FixtureRoot 'duplicate-report.json')
	Assert-True -Condition ($DuplicateRun.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $DuplicateMarker)) -Message 'Duplicate check names must fail before any child launches.'
	Assert-True -Condition (($DuplicateRun.Output -join "`n") -match 'Duplicate check name') -Message 'Duplicate names must have an actionable diagnostic.'
	Write-Output 'PASS: duplicate manifest identities rejected before launch'

	$MixedNames = @('build-packaged-artifacts-tests', 'engine-runner-gate-tests', 'network-authority-spike-tests', 'fixture-after-failure')
	$MixedChecks = @(
		@{ name = $MixedNames[0]; tier = 'required'; command = "Write-Output 'required parallel failure'; exit 7" },
		@{ name = $MixedNames[1]; tier = 'advisory'; command = "Write-Output 'advisory parallel failure'; exit 9" },
		@{ name = $MixedNames[2]; tier = 'required'; command = "1..5000 | ForEach-Object { [Console]::Out.WriteLine('stdout-' + `$_); [Console]::Error.WriteLine('stderr-' + `$_) }; exit 0" },
		@{ name = $MixedNames[3]; tier = 'required'; command = "Write-Output 'barrier ran after failure'; exit 0" }
	)
	$MixedManifest = Join-Path $FixtureRoot 'mixed-manifest.json'
	$MixedReport = Join-Path $FixtureRoot 'mixed-report.json'
	[IO.File]::WriteAllText($MixedManifest, (ConvertTo-Json -InputObject $MixedChecks -Depth 4))
	$MixedRun = Invoke-Runner -ManifestPath $MixedManifest -ReportPath $MixedReport
	$Report = Get-Content -LiteralPath $MixedReport -Raw | ConvertFrom-Json
	Assert-True -Condition ($MixedRun.ExitCode -ne 0 -and $Report.summary.requiredFailed -eq 1 -and $Report.summary.failed -eq 2 -and $Report.summary.passed -eq 2) -Message 'Parallel failures must preserve tier semantics and allow all other checks to finish.'
	Assert-True -Condition (($Report.checks.name -join ',') -ceq ($MixedNames -join ',')) -Message 'Mixed parallel outcomes must remain in manifest order.'
	Assert-True -Condition ($Report.checks[0].message -match 'required parallel failure' -and $Report.checks[1].message -match 'advisory parallel failure') -Message 'Concurrent failures must keep their own output.'
	Assert-True -Condition ($Report.checks[2].message -match 'stderr-5000' -and @($Report.checks[2].message -split "`n").Count -eq 41 -and $Report.checks[2].message.StartsWith("...`n")) -Message 'Both large redirected streams must drain and preserve the combined 40-line output tail.'
	Assert-True -Condition ($Report.checks[3].message -match 'barrier ran after failure') -Message 'A required failure must not cancel later serial checks.'
	Write-Output 'PASS: concurrent failures, sibling completion, and large-stream output tails'

	# A leaked child inherits the check's output handles. The bootstrap must time
	# out only its post-exit drain, retain the diagnostic, and fail even advisory.
	$LeakScript = Join-Path $FixtureRoot 'leak.ps1'
	$LeakSource = @'
$Info = [Diagnostics.ProcessStartInfo]::new()
$Info.FileName = (Get-Command powershell.exe).Source
$Info.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60"'
$Info.UseShellExecute = $false
[void] [Diagnostics.Process]::Start($Info)
[Console]::Out.WriteLine('original stdout before leaked descendant')
[Console]::Error.WriteLine('original stderr before leaked descendant')
exit 17
'@
	[IO.File]::WriteAllText($LeakScript, $LeakSource)
	$LeakManifest = Join-Path $FixtureRoot 'leak-manifest.json'
	$LeakReport = Join-Path $FixtureRoot 'leak-report.json'
	[IO.File]::WriteAllText($LeakManifest, (ConvertTo-Json -InputObject @(@{ name = 'fixture-advisory-leak'; tier = 'advisory'; script = $LeakScript }) -Depth 4))
	$LeakRun = Invoke-Runner -ManifestPath $LeakManifest -ReportPath $LeakReport
	$Report = Get-Content -LiteralPath $LeakReport -Raw | ConvertFrom-Json
	Assert-True -Condition ($LeakRun.ExitCode -ne 0 -and $Report.summary.requiredFailed -eq 0 -and $Report.checks[0].status -eq 'failed') -Message 'Advisory infrastructure failure must fail the suite without inventing a required failure.'
	Assert-True -Condition ($Report.checks[0].message -match 'original stdout before leaked descendant' -and $Report.checks[0].message -match 'original stderr before leaked descendant') -Message 'Post-exit pipe failure must preserve the original stdout and stderr diagnostics.'
	Assert-True -Condition ($Report.checks[0].message -match 'CI bootstrap did not return a complete check result' -and $Report.checks[0].message -match 'terminated its process tree') -Message 'Leaked-pipe failure must report infrastructure and owned-tree cleanup evidence.'
	Write-Output 'PASS: advisory infrastructure failure preserves original output and fails closed'

	$DescendantScript = Join-Path $FixtureRoot 'descendant.ps1'
	$DescendantMarker = Join-Path $FixtureRoot 'descendant.json'
	$DescendantCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
	$DescendantBody = @"
`$Child = Start-Process -FilePath '$((Get-Command powershell.exe).Source)' -ArgumentList '-NoProfile -EncodedCommand $DescendantCommand' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText('$DescendantMarker', (ConvertTo-Json @{ id = `$Child.Id; startTicks = `$Child.StartTime.ToUniversalTime().Ticks }))
Start-Sleep -Seconds 60
"@
	[IO.File]::WriteAllText($DescendantScript, $DescendantBody)
	$CancellationManifest = Join-Path $FixtureRoot 'cancellation-manifest.json'
	[IO.File]::WriteAllText($CancellationManifest, (ConvertTo-Json -InputObject @(@{ name = 'build-packaged-artifacts-tests'; tier = 'required'; script = $DescendantScript }) -Depth 4))
	$Unrelated = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList "-NoProfile -EncodedCommand $DescendantCommand" -WindowStyle Hidden -PassThru
	try {
		$CancellationRun = Invoke-Runner -ManifestPath $CancellationManifest -ReportPath (Join-Path $FixtureRoot 'cancellation-report.json') -StopAfterMarker $DescendantMarker
		Assert-True -Condition ($CancellationRun.ExitCode -ne 0) -Message 'A cancelled parent must not report success.'
		$Identity = Get-Content -LiteralPath $DescendantMarker -Raw | ConvertFrom-Json
		$CleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
		do {
			$Remaining = Get-Process -Id $Identity.id -ErrorAction SilentlyContinue
			if ($null -eq $Remaining -or $Remaining.StartTime.ToUniversalTime().Ticks -ne $Identity.startTicks) { break }
			Start-Sleep -Milliseconds 20
		} while ([DateTime]::UtcNow -lt $CleanupDeadline)
		Assert-True -Condition ($null -eq $Remaining -or $Remaining.StartTime.ToUniversalTime().Ticks -ne $Identity.startTicks) -Message 'Parent termination must stop its exact owned descendant.'
		Assert-True -Condition (-not $Unrelated.HasExited) -Message 'Parent termination must preserve unrelated PowerShell processes.'
	}
	finally {
		if (-not $Unrelated.HasExited) { $Unrelated.Kill(); [void] $Unrelated.WaitForExit(5000) }
		$Unrelated.Dispose()
	}
	Write-Output 'PASS: parent termination cleans owned descendants and preserves unrelated processes'

	Write-Output 'All CI suite runner tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
