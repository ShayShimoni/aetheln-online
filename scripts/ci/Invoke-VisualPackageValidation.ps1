[CmdletBinding()]
param(
	[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $EvidenceRoot,
	[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Repository,
	[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Revision,
	[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $RunId,
	[Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $RunAttempt,
	[string] $VisualValidatorPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'visuals\Test-VisualPackage.ps1'),
	[string] $RegressionValidatorPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'visuals\tests\Test-VisualPackageValidation.ps1'),
	[ValidateRange(1, 1000)][int] $MaxCapturedLinesPerValidator = 200,
	[ValidateRange(1, 16384)][int] $MaxCapturedLineUtf8Bytes = 4096,
	[ValidateRange(1, 1048576)][int] $MaxCapturedUtf8BytesPerValidator = 131072,
	[ValidateRange(32768, 16777216)][int] $MaxReportUtf8Bytes = 4194304
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Utf8 = [Text.UTF8Encoding]::new($false)
$ReportPath = Join-Path $EvidenceRoot 'visual-package-report.json'
$ValidatorCount = 2
$JsonFixedOverheadBytes = 32768
$JsonPerLineOverheadBytes = 128

function Get-BoundedUtf8Text {
	param(
		[AllowEmptyString()][Parameter(Mandatory)][string] $Text,
		[Parameter(Mandatory)][int] $MaximumBytes
	)

	if ($Utf8.GetByteCount($Text) -le $MaximumBytes) { return $Text }
	$Low = 0
	$High = [Math]::Min($Text.Length, $MaximumBytes)
	while ($Low -lt $High) {
		$Middle = [int] [Math]::Ceiling(($Low + $High) / 2.0)
		if ($Utf8.GetByteCount($Text.Substring(0, $Middle)) -le $MaximumBytes) { $Low = $Middle }
		else { $High = $Middle - 1 }
	}
	if ($Low -gt 0 -and $Low -lt $Text.Length -and [char]::IsHighSurrogate($Text[$Low - 1]) -and [char]::IsLowSurrogate($Text[$Low])) {
		$Low--
	}
	return $Text.Substring(0, $Low)
}

function ConvertTo-NativeArgument {
	param(
		[AllowEmptyString()][Parameter(Mandatory)][string] $Value
	)

	if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
	$Builder = [Text.StringBuilder]::new()
	[void] $Builder.Append('"')
	$BackslashCount = 0
	foreach ($Character in $Value.ToCharArray()) {
		if ($Character -eq '\') {
			$BackslashCount++
			continue
		}
		if ($Character -eq '"') {
			[void] $Builder.Append(('\' * (($BackslashCount * 2) + 1)))
			[void] $Builder.Append('"')
			$BackslashCount = 0
			continue
		}
		if ($BackslashCount -gt 0) {
			[void] $Builder.Append(('\' * $BackslashCount))
			$BackslashCount = 0
		}
		[void] $Builder.Append($Character)
	}
	if ($BackslashCount -gt 0) { [void] $Builder.Append(('\' * ($BackslashCount * 2))) }
	[void] $Builder.Append('"')
	return $Builder.ToString()
}

function Initialize-CapturedLine {
	param(
		[Parameter(Mandatory)] $Capture,
		[Parameter(Mandatory)] $StreamState
	)

	if ($StreamState.lineActive) { return }
	$StreamState.lineActive = $true
	$StreamState.lineTruncated = $false
	$StreamState.pendingCarriageReturn = $false
	$StreamState.builder.Clear() | Out-Null
	$StreamState.builderUtf8Bytes = 0
	$StreamState.reservedUtf8Bytes = 0
	$StreamState.willCapture = (
		($Capture.capturedLineCount + $Capture.reservedLineCount) -lt $MaxCapturedLinesPerValidator -and
		($Capture.capturedUtf8Bytes + $Capture.reservedUtf8Bytes) -lt $MaxCapturedUtf8BytesPerValidator
	)
	if (-not $StreamState.willCapture) { return }

	$RemainingAggregateBytes = $MaxCapturedUtf8BytesPerValidator - $Capture.capturedUtf8Bytes - $Capture.reservedUtf8Bytes
	$StreamState.reservedUtf8Bytes = [Math]::Min($MaxCapturedLineUtf8Bytes, $RemainingAggregateBytes)
	$Capture.reservedLineCount++
	$Capture.reservedUtf8Bytes += $StreamState.reservedUtf8Bytes
	Add-CapturedText -StreamState $StreamState -Text ($StreamState.name + ': ')
}

function Add-CapturedText {
	param(
		[Parameter(Mandatory)] $StreamState,
		[AllowEmptyString()][Parameter(Mandatory)][string] $Text
	)

	if (-not $StreamState.willCapture -or $Text.Length -eq 0) { return }
	$RemainingLineBytes = $StreamState.reservedUtf8Bytes - $StreamState.builderUtf8Bytes
	if ($RemainingLineBytes -le 0) {
		$StreamState.lineTruncated = $true
		return
	}
	$BoundedText = Get-BoundedUtf8Text -Text $Text -MaximumBytes $RemainingLineBytes
	if ($BoundedText.Length -lt $Text.Length) { $StreamState.lineTruncated = $true }
	if ($BoundedText.Length -eq 0) { return }
	[void] $StreamState.builder.Append($BoundedText)
	$StreamState.builderUtf8Bytes += $Utf8.GetByteCount($BoundedText)
}

function Complete-CapturedLine {
	param(
		[Parameter(Mandatory)] $Capture,
		[Parameter(Mandatory)] $StreamState
	)

	if (-not $StreamState.lineActive) { Initialize-CapturedLine -Capture $Capture -StreamState $StreamState }
	$Capture.observedLineCount++
	if ($StreamState.willCapture) {
		[void] $Capture.output.Add($StreamState.builder.ToString())
		$Capture.capturedLineCount++
		$Capture.capturedUtf8Bytes += $StreamState.builderUtf8Bytes
		if ($StreamState.lineTruncated) { $Capture.truncatedLineCount++ }
		$Capture.reservedLineCount--
		$Capture.reservedUtf8Bytes -= $StreamState.reservedUtf8Bytes
	}
	else { $Capture.droppedLineCount++ }

	$StreamState.lineActive = $false
	$StreamState.lineTruncated = $false
	$StreamState.pendingCarriageReturn = $false
	$StreamState.builder.Clear() | Out-Null
	$StreamState.builderUtf8Bytes = 0
	$StreamState.reservedUtf8Bytes = 0
	$StreamState.willCapture = $false
}

function Add-DecodedText {
	param(
		[Parameter(Mandatory)] $Capture,
		[Parameter(Mandatory)] $StreamState,
		[Parameter(Mandatory)][char[]] $Characters,
		[Parameter(Mandatory)][int] $Count
	)

	$DecodedText = [string]::new($Characters, 0, $Count)
	$Offset = 0
	while ($Offset -lt $DecodedText.Length) {
		$NewlineIndex = $DecodedText.IndexOf("`n", $Offset, [StringComparison]::Ordinal)
		$EndsWithNewline = $NewlineIndex -ge 0
		$SegmentEnd = $(if ($EndsWithNewline) { $NewlineIndex } else { $DecodedText.Length })
		$SegmentLength = $SegmentEnd - $Offset
		if ($SegmentLength -gt 0) {
			if (-not $StreamState.lineActive) { Initialize-CapturedLine -Capture $Capture -StreamState $StreamState }
			if ($StreamState.pendingCarriageReturn) {
				Add-CapturedText -StreamState $StreamState -Text "`r"
				$StreamState.pendingCarriageReturn = $false
			}
			$Segment = $DecodedText.Substring($Offset, $SegmentLength)
			if ($Segment.EndsWith("`r", [StringComparison]::Ordinal)) {
				$Segment = $Segment.Substring(0, $Segment.Length - 1)
				$StreamState.pendingCarriageReturn = $true
			}
			Add-CapturedText -StreamState $StreamState -Text $Segment
		}
		if (-not $EndsWithNewline) { break }
		if (-not $StreamState.lineActive) { Initialize-CapturedLine -Capture $Capture -StreamState $StreamState }
		$StreamState.pendingCarriageReturn = $false
		Complete-CapturedLine -Capture $Capture -StreamState $StreamState
		$Offset = $NewlineIndex + 1
	}
}

function Add-RawCaptureChunk {
	param(
		[Parameter(Mandatory)] $Capture,
		[Parameter(Mandatory)] $StreamState,
		[Parameter(Mandatory)][int] $Count
	)

	$CharacterCount = $StreamState.decoder.GetChars($StreamState.readBuffer, 0, $Count, $StreamState.characterBuffer, 0, $false)
	Add-DecodedText -Capture $Capture -StreamState $StreamState -Characters $StreamState.characterBuffer -Count $CharacterCount
}

function Complete-RawCaptureStream {
	param(
		[Parameter(Mandatory)] $Capture,
		[Parameter(Mandatory)] $StreamState
	)

	$CharacterCount = $StreamState.decoder.GetChars([byte[]]::new(0), 0, 0, $StreamState.characterBuffer, 0, $true)
	if ($CharacterCount -gt 0) {
		Add-DecodedText -Capture $Capture -StreamState $StreamState -Characters $StreamState.characterBuffer -Count $CharacterCount
	}
	if ($StreamState.pendingCarriageReturn) {
		Add-CapturedText -StreamState $StreamState -Text "`r"
		$StreamState.pendingCarriageReturn = $false
	}
	if ($StreamState.lineActive) { Complete-CapturedLine -Capture $Capture -StreamState $StreamState }
	$StreamState.complete = $true
}

function Get-RawCaptureStreamState {
	param(
		[Parameter(Mandatory)][ValidateSet('stdout', 'stderr')][string] $Name,
		[Parameter(Mandatory)][IO.Stream] $Stream
	)

	return [ordered]@{
		name = $Name
		stream = $Stream
		decoder = $Utf8.GetDecoder()
		readBuffer = [byte[]]::new(4096)
		characterBuffer = [char[]]::new(4096)
		readTask = $null
		complete = $false
		lineActive = $false
		pendingCarriageReturn = $false
		willCapture = $false
		lineTruncated = $false
		reservedUtf8Bytes = 0
		builderUtf8Bytes = 0
		builder = [Text.StringBuilder]::new()
	}
}

function Invoke-RawCapturedProcess {
	param(
		[Parameter(Mandatory)][string] $FilePath,
		[Parameter(Mandatory)][string[]] $ArgumentList,
		[Parameter(Mandatory)] $Capture
	)

	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $FilePath
	$StartInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' ')
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) { throw 'process_start_returned_false' }
		$Streams = @(
			(Get-RawCaptureStreamState -Name 'stdout' -Stream $Process.StandardOutput.BaseStream),
			(Get-RawCaptureStreamState -Name 'stderr' -Stream $Process.StandardError.BaseStream)
		)
		foreach ($StreamState in $Streams) {
			$StreamState.readTask = $StreamState.stream.ReadAsync($StreamState.readBuffer, 0, $StreamState.readBuffer.Length)
		}
		while (@($Streams | Where-Object { -not $_.complete }).Count -gt 0) {
			$MadeProgress = $false
			foreach ($StreamState in $Streams) {
				if ($StreamState.complete -or -not $StreamState.readTask.IsCompleted) { continue }
				$MadeProgress = $true
				$ReadCount = $StreamState.readTask.GetAwaiter().GetResult()
				if ($ReadCount -eq 0) {
					Complete-RawCaptureStream -Capture $Capture -StreamState $StreamState
					continue
				}
				Add-RawCaptureChunk -Capture $Capture -StreamState $StreamState -Count $ReadCount
				$StreamState.readTask = $StreamState.stream.ReadAsync($StreamState.readBuffer, 0, $StreamState.readBuffer.Length)
			}
			if (-not $MadeProgress) { [Threading.Thread]::Sleep(1) }
		}
		$Process.WaitForExit()
		return [int] $Process.ExitCode
	}
	finally {
		if (-not $Process.HasExited) {
			$Process.Kill()
			$Process.WaitForExit()
		}
		$Process.Dispose()
	}
}

foreach ($Identity in @(
	@{ Name = 'repository'; Value = $Repository; Maximum = 512 },
	@{ Name = 'revision'; Value = $Revision; Maximum = 128 },
	@{ Name = 'run_id'; Value = $RunId; Maximum = 64 },
	@{ Name = 'visual_validator_path'; Value = $VisualValidatorPath; Maximum = 4096 },
	@{ Name = 'regression_validator_path'; Value = $RegressionValidatorPath; Maximum = 4096 }
)) {
	if ([string]::IsNullOrWhiteSpace([string] $Identity.Value) -or ([string] $Identity.Value).Length -gt [int] $Identity.Maximum) {
		throw "visual_report_identity_invalid:$($Identity.Name)"
	}
}

# JSON escaping can expand one captured UTF-8 byte to at most six bytes. Reject
# an unsafe configuration before starting either validator or serializing any
# potentially large object.
$ConfiguredMaximum = [long] $JsonFixedOverheadBytes +
	([long] $ValidatorCount * $MaxCapturedUtf8BytesPerValidator * 6) +
	([long] $ValidatorCount * $MaxCapturedLinesPerValidator * $JsonPerLineOverheadBytes) +
	([long] ($Repository.Length + $Revision.Length + $RunId.Length + $VisualValidatorPath.Length + $RegressionValidatorPath.Length) * 6)
if ($ConfiguredMaximum -gt $MaxReportUtf8Bytes) {
	throw "visual_report_configuration_exceeds_limit:$ConfiguredMaximum>$MaxReportUtf8Bytes"
}

[void] [IO.Directory]::CreateDirectory($EvidenceRoot)
if (Test-Path -LiteralPath $ReportPath) { throw 'visual_report_already_exists' }

$Validators = @(
	[ordered]@{ id = 'visual-package'; path = $VisualValidatorPath },
	[ordered]@{ id = 'visual-package-regressions'; path = $RegressionValidatorPath }
)
foreach ($Validator in $Validators) {
	if (-not (Test-Path -LiteralPath $Validator.path -PathType Leaf)) {
		throw "visual_validator_missing:$($Validator.id)"
	}
}

$Results = [Collections.Generic.List[object]]::new()
$Failure = $null
$PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
foreach ($Validator in $Validators) {
	$StartedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
	$Capture = [ordered]@{
		maxLineUtf8Bytes = $MaxCapturedLineUtf8Bytes
		maxLines = $MaxCapturedLinesPerValidator
		maxAggregateUtf8Bytes = $MaxCapturedUtf8BytesPerValidator
		observedLineCount = 0
		capturedLineCount = 0
		capturedUtf8Bytes = 0
		truncatedLineCount = 0
		droppedLineCount = 0
		reservedLineCount = 0
		reservedUtf8Bytes = 0
		output = [Collections.Generic.List[string]]::new()
	}
	$ExitCode = -1
	$InvocationArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string] $Validator.path)
	if ($Validator.id -eq 'visual-package') {
		# Test-VisualPackage.ps1 exposes Root as a supported fixture seam. Bind it
		# explicitly because Windows PowerShell evaluates a parameter default that
		# references PSScriptRoot before establishing the script root under -File.
		$InvocationArguments += @('-Root', (Split-Path -Parent ([string] $Validator.path)))
	}
	try {
		$ExitCode = Invoke-RawCapturedProcess -FilePath $PowerShell -ArgumentList $InvocationArguments -Capture $Capture
	}
	catch {
		$InvocationFailureState = Get-RawCaptureStreamState -Name 'stderr' -Stream ([IO.Stream]::Null)
		Initialize-CapturedLine -Capture $Capture -StreamState $InvocationFailureState
		Add-CapturedText -StreamState $InvocationFailureState -Text ("validator_invocation_failed: " + $_.Exception.Message)
		Complete-CapturedLine -Capture $Capture -StreamState $InvocationFailureState
	}

	$Results.Add([ordered]@{
		id = $Validator.id
		path = $Validator.path
		startedUtc = $StartedUtc
		finishedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
		nativeExitCode = [int] $ExitCode
		conclusion = $(if ($ExitCode -eq 0) { 'success' } else { 'failure' })
		capture = [ordered]@{
			maxLineUtf8Bytes = $Capture.maxLineUtf8Bytes
			maxLines = $Capture.maxLines
			maxAggregateUtf8Bytes = $Capture.maxAggregateUtf8Bytes
			observedLineCount = $Capture.observedLineCount
			capturedLineCount = $Capture.capturedLineCount
			capturedUtf8Bytes = $Capture.capturedUtf8Bytes
			truncatedLineCount = $Capture.truncatedLineCount
			droppedLineCount = $Capture.droppedLineCount
		}
		output = $Capture.output.ToArray()
	})
	if ($ExitCode -ne 0 -and $null -eq $Failure) { $Failure = "visual_validator_failed:$($Validator.id):$ExitCode" }
}

$Report = [ordered]@{
	schemaVersion = 'aetheln.visual-package-report/v1'
	repository = $Repository
	revision = $Revision
	run = [ordered]@{ id = $RunId; attempt = $RunAttempt }
	results = $Results.ToArray()
	conclusion = $(if ($null -eq $Failure) { 'success' } else { 'failure' })
}

# Bound the actual object before ConvertTo-Json. The estimate intentionally
# assumes worst-case six-byte JSON escaping for every character.
$ReportCharacters = $Repository.Length + $Revision.Length + $RunId.Length
$CapturedLineCount = 0
foreach ($Result in $Results) {
	$ReportCharacters += ([string] $Result.id).Length + ([string] $Result.path).Length + ([string] $Result.startedUtc).Length + ([string] $Result.finishedUtc).Length
	foreach ($Line in @($Result.output)) { $ReportCharacters += ([string] $Line).Length; $CapturedLineCount++ }
}
$EstimatedReportBytes = [long] $JsonFixedOverheadBytes + ([long] $ReportCharacters * 6) + ([long] $CapturedLineCount * $JsonPerLineOverheadBytes)
if ($EstimatedReportBytes -gt $MaxReportUtf8Bytes) {
	throw "visual_report_pre_serialization_limit:$EstimatedReportBytes>$MaxReportUtf8Bytes"
}

$ReportJson = ConvertTo-Json -InputObject $Report -Depth 8 -Compress
$ReportBytes = $Utf8.GetBytes($ReportJson)
if ($ReportBytes.Length -gt $MaxReportUtf8Bytes) {
	throw "visual_report_size_limit:$($ReportBytes.Length)>$MaxReportUtf8Bytes"
}
$ReportStream = [IO.File]::Open($ReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
	$ReportStream.Write($ReportBytes, 0, $ReportBytes.Length)
	$ReportStream.Flush()
}
finally { $ReportStream.Dispose() }

if ($null -ne $Failure) { throw $Failure }
Write-Output "Visual package validation evidence passed: $ReportPath"
