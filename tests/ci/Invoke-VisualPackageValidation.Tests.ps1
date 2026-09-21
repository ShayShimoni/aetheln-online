[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Runner = Join-Path $RepositoryRoot 'scripts\ci\Invoke-VisualPackageValidation.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnVisualEvidenceTests-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
	param(
		[Parameter(Mandatory)][bool] $Condition,
		[Parameter(Mandatory)][string] $Message
	)
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throw {
	param(
		[Parameter(Mandatory)][scriptblock] $Action,
		[Parameter(Mandatory)][string] $Pattern
	)
	try { & $Action }
	catch {
		if ($_.Exception.Message -notmatch $Pattern) {
			throw "Expected failure matching '$Pattern', got: $($_.Exception.Message)"
		}
		return
	}
	throw "Expected failure matching '$Pattern', but the action succeeded."
}

try {
	[void] [IO.Directory]::CreateDirectory($FixtureRoot)
	$RunnerSource = [IO.File]::ReadAllText($Runner)
	Assert-True ($RunnerSource -match 'StandardOutput\.BaseStream' -and $RunnerSource -match 'StandardError\.BaseStream' -and $RunnerSource -match '\.stream\.ReadAsync\(') 'Native validator capture must read both redirected raw streams incrementally.'
	Assert-True ($RunnerSource -notmatch '(?i)ReadLine|ReadToEnd|BeginOutputReadLine|OutputDataReceived') 'Native validator capture must not use APIs that materialize complete output lines or streams.'

	$LargeValidator = Join-Path $FixtureRoot 'large-validator.ps1'
	$UnterminatedValidator = Join-Path $FixtureRoot 'unterminated-validator.ps1'
	$PassingValidator = Join-Path $FixtureRoot 'passing-validator.ps1'
	[IO.File]::WriteAllText($LargeValidator, @'
[CmdletBinding()]
param([string] $Root)
if ([string]::IsNullOrEmpty($Root)) { exit 29 }
1..500 | ForEach-Object { Write-Output (('x' * 8192) + $_) }
exit 17
'@, [Text.UTF8Encoding]::new($false))
	[IO.File]::WriteAllText($UnterminatedValidator, @'
[CmdletBinding()]
param([string] $Root)
if ([string]::IsNullOrEmpty($Root)) { exit 29 }
$Chunk = [Text.Encoding]::UTF8.GetBytes(('u' * 4096))
$Stdout = [Console]::OpenStandardOutput()
$Stderr = [Console]::OpenStandardError()
1..2048 | ForEach-Object { $Stdout.Write($Chunk, 0, $Chunk.Length) }
1..2048 | ForEach-Object { $Stderr.Write($Chunk, 0, $Chunk.Length) }
$Stdout.Flush()
$Stderr.Flush()
exit 23
'@, [Text.UTF8Encoding]::new($false))
	[IO.File]::WriteAllText($PassingValidator, @'
[CmdletBinding()]
param([string] $Root = $PSScriptRoot)
if ([string]::IsNullOrEmpty($Root)) { exit 29 }
Write-Output 'fixture pass'
exit 0
'@, [Text.UTF8Encoding]::new($false))

	$EvidenceRoot = Join-Path $FixtureRoot 'evidence'
	Assert-Throw -Pattern 'visual_validator_failed:visual-package:17' -Action {
		& $Runner `
			-EvidenceRoot $EvidenceRoot `
			-Repository 'owner/repository' `
			-Revision ('a' * 40) `
			-RunId '1234' `
			-RunAttempt 2 `
			-VisualValidatorPath $LargeValidator `
			-RegressionValidatorPath $PassingValidator `
			-MaxCapturedLinesPerValidator 3 `
			-MaxCapturedLineUtf8Bytes 64 `
			-MaxCapturedUtf8BytesPerValidator 128 `
			-MaxReportUtf8Bytes 65536
	}

	$ReportPath = Join-Path $EvidenceRoot 'visual-package-report.json'
	Assert-True (Test-Path -LiteralPath $ReportPath -PathType Leaf) 'A failing validator must still publish its bounded report before propagating the failure.'
	$ReportLength = (Get-Item -LiteralPath $ReportPath).Length
	Assert-True ($ReportLength -le 65536) 'The serialized report must stay within the declared byte ceiling.'
	$Report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
	$LargeResult = @($Report.results | Where-Object id -eq 'visual-package')[0]
	Assert-True ($Report.conclusion -eq 'failure' -and $LargeResult.nativeExitCode -eq 17) 'The report must preserve the oversized validator failure.'
	Assert-True ($LargeResult.capture.observedLineCount -eq 500) 'Streaming capture must observe every emitted fixture line without materializing the full stream.'
	Assert-True ($LargeResult.capture.capturedLineCount -le 3) 'Streaming capture must enforce the per-validator line-count ceiling.'
	Assert-True ($LargeResult.capture.capturedUtf8Bytes -le 128) 'Streaming capture must enforce the aggregate captured-byte ceiling.'
	Assert-True ($LargeResult.capture.truncatedLineCount -gt 0 -and $LargeResult.capture.droppedLineCount -gt 0) 'Oversized output must be represented by truncation and dropped-line counters.'
	foreach ($Line in @($LargeResult.output)) {
		Assert-True ([Text.Encoding]::UTF8.GetByteCount([string] $Line) -le 64) 'Every captured line must respect the UTF-8 byte ceiling.'
	}
	Write-Output 'PASS: oversized failing output is captured incrementally within line, count, aggregate and report bounds'

	$UnterminatedEvidenceRoot = Join-Path $FixtureRoot 'unterminated-evidence'
	Assert-Throw -Pattern 'visual_validator_failed:visual-package:23' -Action {
		& $Runner `
			-EvidenceRoot $UnterminatedEvidenceRoot `
			-Repository 'owner/repository' `
			-Revision ('b' * 40) `
			-RunId '5678' `
			-RunAttempt 1 `
			-VisualValidatorPath $UnterminatedValidator `
			-RegressionValidatorPath $PassingValidator `
			-MaxCapturedLinesPerValidator 4 `
			-MaxCapturedLineUtf8Bytes 64 `
			-MaxCapturedUtf8BytesPerValidator 128 `
			-MaxReportUtf8Bytes 65536
	}
	$UnterminatedReportPath = Join-Path $UnterminatedEvidenceRoot 'visual-package-report.json'
	Assert-True (Test-Path -LiteralPath $UnterminatedReportPath -PathType Leaf) 'A failing unterminated-stream validator must publish its bounded report.'
	Assert-True ((Get-Item -LiteralPath $UnterminatedReportPath).Length -le 65536) 'The unterminated-stream report must stay within the declared byte ceiling.'
	$UnterminatedReport = Get-Content -LiteralPath $UnterminatedReportPath -Raw | ConvertFrom-Json
	$UnterminatedResult = @($UnterminatedReport.results | Where-Object id -eq 'visual-package')[0]
	Assert-True ($UnterminatedResult.nativeExitCode -eq 23 -and $UnterminatedResult.conclusion -eq 'failure') 'The unterminated-stream fixture must preserve native failure semantics.'
	Assert-True ($UnterminatedResult.capture.observedLineCount -eq 2) 'EOF must finalize one unterminated logical line from each redirected stream.'
	Assert-True ($UnterminatedResult.capture.capturedLineCount -eq 2) 'Both unterminated native streams must be represented in bounded output.'
	Assert-True ($UnterminatedResult.capture.capturedUtf8Bytes -le 128) 'Unterminated native output must honor the aggregate captured-byte ceiling.'
	Assert-True ($UnterminatedResult.capture.truncatedLineCount -eq 2) 'Both multi-megabyte unterminated stream lines must be recorded as truncated.'
	Assert-True (@($UnterminatedResult.output | Where-Object { $_ -like 'stdout:*' }).Count -eq 1) 'Bounded evidence must retain the stdout stream identity.'
	Assert-True (@($UnterminatedResult.output | Where-Object { $_ -like 'stderr:*' }).Count -eq 1) 'Bounded evidence must retain the stderr stream identity.'
	foreach ($Line in @($UnterminatedResult.output)) {
		Assert-True ([Text.Encoding]::UTF8.GetByteCount([string] $Line) -le 64) 'Each unterminated captured line must respect the per-line UTF-8 ceiling.'
	}
	Write-Output 'PASS: multi-megabyte unterminated stdout and stderr are captured with fixed memory and bounded evidence'

	$OriginalReport = Get-Content -LiteralPath $ReportPath -Raw
	Assert-Throw -Pattern 'visual_report_already_exists' -Action {
		& $Runner -EvidenceRoot $EvidenceRoot -Repository 'owner/repository' -Revision ('a' * 40) -RunId '1234' -RunAttempt 2 -VisualValidatorPath $PassingValidator -RegressionValidatorPath $PassingValidator
	}
	Assert-True ((Get-Content -LiteralPath $ReportPath -Raw) -ceq $OriginalReport) 'A second invocation must fail closed without overwriting existing evidence.'
	Write-Output 'PASS: evidence publication is create-only and preserves the first report bytes'

	$UnsafeRoot = Join-Path $FixtureRoot 'unsafe-evidence'
	Assert-Throw -Pattern 'visual_report_configuration_exceeds_limit' -Action {
		& $Runner `
			-EvidenceRoot $UnsafeRoot `
			-Repository 'owner/repository' `
			-Revision ('a' * 40) `
			-RunId '1234' `
			-RunAttempt 2 `
			-VisualValidatorPath $PassingValidator `
			-RegressionValidatorPath $PassingValidator `
			-MaxCapturedLinesPerValidator 200 `
			-MaxCapturedLineUtf8Bytes 4096 `
			-MaxCapturedUtf8BytesPerValidator 131072 `
			-MaxReportUtf8Bytes 32768
	}
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $UnsafeRoot 'visual-package-report.json'))) 'An unsafe serialization budget must fail before creating a report.'
	Write-Output 'PASS: an unsafe pre-serialization budget is rejected before validators or report publication'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}

Write-Output 'Visual package evidence regression checks passed.'
