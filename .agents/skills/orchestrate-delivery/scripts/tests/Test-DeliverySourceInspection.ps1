[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$ServerScript = Join-Path $ScriptRoot 'Invoke-DeliverySourceInspectionServer.ps1'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-source-inspection-tests-' + [guid]::NewGuid().ToString('N')
)

New-Item -ItemType Directory -Path $TestRoot | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter(Mandatory)]
		[bool]$Passed,

		[string]$Detail = ''
	)

	$Results.Add([pscustomobject]@{
		Name = $Name
		Passed = $Passed
		Detail = $Detail
	})
}

function Get-TestSha256 {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes
	)

	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function Test-TestByteArrayEqual {
	param(
		[AllowEmptyCollection()]
		[byte[]]$Left,

		[AllowEmptyCollection()]
		[byte[]]$Right
	)

	return [System.Linq.Enumerable]::SequenceEqual(
		[byte[]]$Left,
		[byte[]]$Right
	)
}

function Get-FixtureSnapshot {
	param(
		[Parameter(Mandatory)]
		[string]$Root
	)

	$Snapshot = [ordered]@{}
	$Files = @(
		Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
			Sort-Object -Property FullName
	)
	foreach ($File in $Files) {
		$RelativePath = $File.FullName.Substring($Root.Length).TrimStart('\', '/')
		$Snapshot[$RelativePath] = Get-TestSha256 `
			-Bytes ([System.IO.File]::ReadAllBytes($File.FullName))
	}
	return $Snapshot
}

$PowerShellHost = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $PowerShellHost) {
	$PowerShellHost = Get-Command powershell -ErrorAction Stop
}
$PowerShellHostCommand = [string]$PowerShellHost.Source

function Start-InspectionServer {
	param(
		[Parameter(Mandatory)]
		[string]$AttestationPath,

		[Parameter(Mandatory)]
		[string]$AttestationSha256,

		[Parameter(Mandatory)]
		[string]$WorkspaceRoot
	)

	$ArgumentValues = @(
		'-NoLogo',
		'-NoProfile',
		'-NonInteractive',
		'-File',
		$ServerScript,
		'-AttestationPath',
		$AttestationPath,
		'-AttestationSha256',
		$AttestationSha256,
		'-WorkspaceRoot',
		$WorkspaceRoot
	)
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $PowerShellHostCommand
	$StartInfo.Arguments = [string]::Join(' ', @(
		$ArgumentValues | ForEach-Object { '"' + $_ + '"' }
	))
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardInput = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
	$StartInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	if (-not $Process.Start()) {
		throw 'Could not start the source-inspection server.'
	}

	return [pscustomobject]@{
		Process = $Process
		StandardErrorTask = $Process.StandardError.ReadToEndAsync()
	}
}

function Send-InspectionRequest {
	param(
		[Parameter(Mandatory)]
		[object]$Session,

		[Parameter(Mandatory)]
		[string]$Json,

		[switch]$Notification,

		[int]$TimeoutMilliseconds = 30000
	)

	$Session.Process.StandardInput.WriteLine($Json)
	$Session.Process.StandardInput.Flush()
	if ($Notification) {
		return $null
	}

	$ReadTask = $Session.Process.StandardOutput.ReadLineAsync()
	if (-not $ReadTask.Wait($TimeoutMilliseconds)) {
		try { $Session.Process.Kill() } catch { }
		throw 'Source-inspection server response timed out.'
	}

	return $ReadTask.Result
}

$NextRequestId = 10
function Invoke-InspectionToolCall {
	param(
		[Parameter(Mandatory)]
		[object]$Session,

		[AllowNull()]
		[object]$Arguments
	)

	$Script:NextRequestId = $Script:NextRequestId + 1
	$Request = [pscustomobject][ordered]@{
		jsonrpc = '2.0'
		id = $Script:NextRequestId
		method = 'tools/call'
		params = [pscustomobject][ordered]@{
			name = 'read_allowed_source_file'
			arguments = $Arguments
		}
	} | ConvertTo-Json -Depth 6 -Compress
	$ResponseLine = Send-InspectionRequest -Session $Session -Json $Request
	if ($null -eq $ResponseLine) {
		throw 'Source-inspection server returned no tools/call response.'
	}

	return [pscustomobject]@{
		Line = $ResponseLine
		Response = ($ResponseLine | ConvertFrom-Json)
	}
}

function Invoke-InspectionPage {
	param(
		[Parameter(Mandatory)]
		[object]$Session,

		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Path,

		[Parameter(Mandatory)]
		[int64]$OffsetBytes
	)

	return Invoke-InspectionToolCall `
		-Session $Session `
		-Arguments ([pscustomobject][ordered]@{
			path = $Path
			offset_bytes = $OffsetBytes
		})
}

function Convert-InspectionContentToBytes {
	param(
		[Parameter(Mandatory)]
		[object]$Page
	)

	if ([string]$Page.encoding -ceq 'utf8') {
		$Bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes(
			[string]$Page.content
		)
		Write-Output -NoEnumerate $Bytes
		return
	}
	if ([string]$Page.encoding -ceq 'base64') {
		$Bytes = [System.Convert]::FromBase64String([string]$Page.content)
		Write-Output -NoEnumerate $Bytes
		return
	}
	throw "Unexpected source-inspection encoding '$($Page.encoding)'."
}

function Test-InspectionPageEnvelope {
	param(
		[Parameter(Mandatory)]
		[object]$Call
	)

	try {
		$Result = $Call.Response.result
		$ResultNames = @($Result.PSObject.Properties.Name)
		$ContentBlocks = @($Result.content)
		$Structured = $Result.structuredContent
		$StructuredNames = @($Structured.PSObject.Properties.Name)
		$ExpectedNames = @(
			'path',
			'encoding',
			'content',
			'base_sha256',
			'offset_bytes',
			'content_bytes',
			'end_offset_bytes',
			'file_size_bytes',
			'eof'
		)
		if ($Result.isError -ne $false -or
			$ResultNames -notcontains 'structuredContent' -or
			$ContentBlocks.Count -ne 1 -or
			[string]$ContentBlocks[0].type -cne 'text' -or
			$StructuredNames.Count -ne $ExpectedNames.Count) {
			return $false
		}
		for ($Index = 0; $Index -lt $ExpectedNames.Count; $Index++) {
			if ([string]$StructuredNames[$Index] -cne $ExpectedNames[$Index]) {
				return $false
			}
		}

		$Text = [string]$ContentBlocks[0].text
		$ParsedText = $Text | ConvertFrom-Json
		$CanonicalText = $ParsedText | ConvertTo-Json -Depth 6 -Compress
		$CanonicalStructured = $Structured | ConvertTo-Json -Depth 6 -Compress
		$PageBytes = Convert-InspectionContentToBytes -Page $Structured
		return (
			$Text -ceq $CanonicalText -and
			$CanonicalText -ceq $CanonicalStructured -and
			[int64]$Structured.offset_bytes -ge 0 -and
			[int64]$Structured.content_bytes -eq $PageBytes.LongLength -and
			[int64]$Structured.content_bytes -le 8192 -and
			[int64]$Structured.end_offset_bytes -eq
				([int64]$Structured.offset_bytes + [int64]$Structured.content_bytes) -and
			[int64]$Structured.end_offset_bytes -le
				[int64]$Structured.file_size_bytes -and
			[bool]$Structured.eof -eq (
				[int64]$Structured.end_offset_bytes -eq
				[int64]$Structured.file_size_bytes
			)
		)
	}
	catch {
		return $false
	}
}

function Get-InspectionPages {
	param(
		[Parameter(Mandatory)]
		[object]$Session,

		[Parameter(Mandatory)]
		[string]$Path
	)

	$Pages = [System.Collections.Generic.List[object]]::new()
	$OffsetBytes = [int64]0
	do {
		$Call = Invoke-InspectionPage `
			-Session $Session `
			-Path $Path `
			-OffsetBytes $OffsetBytes
		if (-not (Test-InspectionPageEnvelope -Call $Call)) {
			throw "Source-inspection page envelope for '$Path' is invalid."
		}
		$Page = $Call.Response.result.structuredContent
		$Pages.Add($Page)
		if (-not [bool]$Page.eof -and
			[int64]$Page.end_offset_bytes -le $OffsetBytes) {
			throw "Source-inspection paging for '$Path' did not advance."
		}
		$OffsetBytes = [int64]$Page.end_offset_bytes
	} while (-not [bool]$Page.eof)

	return @($Pages)
}

function Get-ReconstructedInspectionBytes {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[object[]]$Pages,

		[Parameter(Mandatory)]
		[string]$ExpectedPath,

		[Parameter(Mandatory)]
		[string]$ExpectedSha256
	)

	if ($Pages.Count -eq 0) {
		throw 'Source-inspection reconstruction requires at least one page.'
	}
	$ExpectedOffset = [int64]0
	$ExpectedSize = [int64]$Pages[0].file_size_bytes
	$ExpectedEncoding = [string]$Pages[0].encoding
	$Stream = [System.IO.MemoryStream]::new()
	try {
		for ($Index = 0; $Index -lt $Pages.Count; $Index++) {
			$Page = $Pages[$Index]
			if ([string]$Page.path -cne $ExpectedPath -or
				[string]$Page.base_sha256 -cne $ExpectedSha256 -or
				[string]$Page.encoding -cne $ExpectedEncoding -or
				[int64]$Page.file_size_bytes -ne $ExpectedSize -or
				[int64]$Page.offset_bytes -ne $ExpectedOffset) {
				throw "Source-inspection page sequence is inconsistent at index $Index."
			}
			$PageBytes = Convert-InspectionContentToBytes -Page $Page
			if ($PageBytes.LongLength -ne [int64]$Page.content_bytes -or
				[int64]$Page.content_bytes -gt 8192 -or
				[int64]$Page.end_offset_bytes -ne
					([int64]$Page.offset_bytes + $PageBytes.LongLength) -or
				([bool]$Page.eof -ne ($Index -eq ($Pages.Count - 1)))) {
				throw "Source-inspection page metadata is inconsistent at index $Index."
			}
			$Stream.Write($PageBytes, 0, $PageBytes.Length)
			$ExpectedOffset = [int64]$Page.end_offset_bytes
		}
		$Reconstructed = $Stream.ToArray()
	}
	finally {
		$Stream.Dispose()
	}

	if ($Reconstructed.LongLength -ne $ExpectedSize -or
		$ExpectedOffset -ne $ExpectedSize -or
		(Get-TestSha256 -Bytes $Reconstructed) -cne $ExpectedSha256) {
		throw 'Source-inspection reconstruction size or hash is invalid.'
	}
	return $Reconstructed
}

function Test-InspectionSequenceRejected {
	param(
		[Parameter(Mandatory)]
		[object[]]$Pages,

		[Parameter(Mandatory)]
		[string]$ExpectedPath,

		[Parameter(Mandatory)]
		[string]$ExpectedSha256
	)

	try {
		$null = Get-ReconstructedInspectionBytes `
			-Pages $Pages `
			-ExpectedPath $ExpectedPath `
			-ExpectedSha256 $ExpectedSha256
		return $false
	}
	catch {
		return $true
	}
}

function Copy-TestObject {
	param(
		[Parameter(Mandatory)]
		[object]$Value
	)

	return ($Value | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json
}

function Test-InspectionToolFailure {
	param(
		[Parameter(Mandatory)]
		[object]$Call,

		[Parameter(Mandatory)]
		[string]$ExpectedCode,

		[string]$ForbiddenText = ''
	)

	$Result = $Call.Response.result
	$ResultNames = @($Result.PSObject.Properties.Name)
	$ErrorText = [string]$Result.content[0].text
	$ForbiddenAbsent = $true
	if (-not [string]::IsNullOrEmpty($ForbiddenText)) {
		$ForbiddenAbsent = (
			$Call.Line.IndexOf(
				$ForbiddenText,
				[System.StringComparison]::Ordinal
			) -lt 0
		)
	}

	return (
		$Result.isError -eq $true -and
		$ResultNames -notcontains 'structuredContent' -and
		$ErrorText.StartsWith(
			"[$ExpectedCode]",
			[System.StringComparison]::Ordinal
		) -and
		$ForbiddenAbsent
	)
}

$WorkspaceRoot = Join-Path $TestRoot 'workspace'
foreach ($FixtureDirectory in @(
	$WorkspaceRoot,
	(Join-Path $WorkspaceRoot 'src'),
	(Join-Path $WorkspaceRoot 'assets'),
	(Join-Path $WorkspaceRoot 'config')
)) {
	New-Item -ItemType Directory -Path $FixtureDirectory | Out-Null
}

$SampleTextBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"line one`ncaf" + [char]0x00E9 + "`nline three`n"
)
$SampleTextPath = Join-Path $WorkspaceRoot 'src\sample.txt'
[System.IO.File]::WriteAllBytes($SampleTextPath, $SampleTextBytes)

$BinaryBytes = [byte[]]@(0, 1, 2, 0xC3, 0x28, 0xFF, 0xFE, 13, 10, 0)
$BinaryPath = Join-Path $WorkspaceRoot 'assets\blob.bin'
[System.IO.File]::WriteAllBytes($BinaryPath, $BinaryBytes)

$EmptyBytes = [byte[]]::new(0)
$EmptyPath = Join-Path $WorkspaceRoot 'src\empty.txt'
[System.IO.File]::WriteAllBytes($EmptyPath, $EmptyBytes)

$CeilingBytes = [byte[]]::new(8192)
for ($CeilingIndex = 0; $CeilingIndex -lt $CeilingBytes.Length; $CeilingIndex++) {
	$CeilingBytes[$CeilingIndex] = [byte][char]'c'
}
$CeilingPath = Join-Path $WorkspaceRoot 'src\ceiling.txt'
[System.IO.File]::WriteAllBytes($CeilingPath, $CeilingBytes)

$CeilingPlusOneBytes = [byte[]]::new(8193)
for (
	$CeilingPlusOneIndex = 0;
	$CeilingPlusOneIndex -lt $CeilingPlusOneBytes.Length;
	$CeilingPlusOneIndex++
) {
	$CeilingPlusOneBytes[$CeilingPlusOneIndex] = [byte][char]'d'
}
$CeilingPlusOnePath = Join-Path $WorkspaceRoot 'src\ceiling-plus-one.txt'
[System.IO.File]::WriteAllBytes($CeilingPlusOnePath, $CeilingPlusOneBytes)

$Utf8Prefix = 'a' * 8191
$LargeUtf8Text = $Utf8Prefix + [char]0x20AC + ('b' * 8200)
$LargeUtf8Bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($LargeUtf8Text)
$LargeUtf8Path = Join-Path $WorkspaceRoot 'src\large-utf8.txt'
[System.IO.File]::WriteAllBytes($LargeUtf8Path, $LargeUtf8Bytes)

$LargeBinaryBytes = [byte[]]::new(17001)
for ($BinaryIndex = 0; $BinaryIndex -lt $LargeBinaryBytes.Length; $BinaryIndex++) {
	$LargeBinaryBytes[$BinaryIndex] = [byte](0x80 + ($BinaryIndex % 0x80))
}
$LargeBinaryPath = Join-Path $WorkspaceRoot 'assets\large-invalid-utf8.bin'
[System.IO.File]::WriteAllBytes($LargeBinaryPath, $LargeBinaryBytes)

$UnlistedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"DO-NOT-EXPOSE-UNLISTED`n"
)
[System.IO.File]::WriteAllBytes(
	(Join-Path $WorkspaceRoot 'src\unlisted.txt'),
	$UnlistedBytes
)

$SensitiveBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"DO-NOT-EXPOSE-SENSITIVE`n"
)
$SensitivePath = Join-Path $WorkspaceRoot 'config\service.pem'
[System.IO.File]::WriteAllBytes($SensitivePath, $SensitiveBytes)

$MissingBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"missing fixture content`n"
)

$DriftOriginalBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"original drift content`n"
)
$DriftPath = Join-Path $WorkspaceRoot 'drift.txt'
[System.IO.File]::WriteAllBytes($DriftPath, $DriftOriginalBytes)

$JunctionTargetRoot = Join-Path $TestRoot 'junction-target'
New-Item -ItemType Directory -Path $JunctionTargetRoot | Out-Null
$EscapeBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"DO-NOT-EXPOSE-ESCAPE`n"
)
[System.IO.File]::WriteAllBytes(
	(Join-Path $JunctionTargetRoot 'escape.txt'),
	$EscapeBytes
)
$JunctionPath = Join-Path $WorkspaceRoot 'linked'
$JunctionCreated = $true
try {
	New-Item -ItemType Junction -Path $JunctionPath -Target $JunctionTargetRoot |
		Out-Null
}
catch {
	$JunctionCreated = $false
}

$AttestedFiles = [ordered]@{
	'assets/blob.bin' = Get-TestSha256 -Bytes $BinaryBytes
	'assets/large-invalid-utf8.bin' = Get-TestSha256 -Bytes $LargeBinaryBytes
	'config/service.pem' = Get-TestSha256 -Bytes $SensitiveBytes
	'drift.txt' = Get-TestSha256 -Bytes $DriftOriginalBytes
	'linked/escape.txt' = Get-TestSha256 -Bytes $EscapeBytes
	'notes/missing.txt' = Get-TestSha256 -Bytes $MissingBytes
	'src/ceiling-plus-one.txt' = Get-TestSha256 -Bytes $CeilingPlusOneBytes
	'src/ceiling.txt' = Get-TestSha256 -Bytes $CeilingBytes
	'src/empty.txt' = Get-TestSha256 -Bytes $EmptyBytes
	'src/large-utf8.txt' = Get-TestSha256 -Bytes $LargeUtf8Bytes
	'src/sample.txt' = Get-TestSha256 -Bytes $SampleTextBytes
}
$AttestationJson = [pscustomobject][ordered]@{
	workspace_root = $WorkspaceRoot
	allowed_paths = @(
		'assets/**',
		'config/**',
		'drift.txt',
		'linked/**',
		'notes/**',
		'src/**'
	)
	attested_files = [pscustomobject]$AttestedFiles
} | ConvertTo-Json -Depth 4
$AttestationBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	$AttestationJson
)
$AttestationPath = Join-Path $TestRoot 'source-attestation.json'
[System.IO.File]::WriteAllBytes($AttestationPath, $AttestationBytes)
$AttestationSha256 = Get-TestSha256 -Bytes $AttestationBytes

$DriftedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
	"DO-NOT-EXPOSE-DRIFTED content`n"
)
[System.IO.File]::WriteAllBytes($DriftPath, $DriftedBytes)

$TamperedAttestationPath = Join-Path $TestRoot 'tampered-attestation.json'
$TamperedBytes = [byte[]]@($AttestationBytes + [byte[]]@(0x20))
[System.IO.File]::WriteAllBytes($TamperedAttestationPath, $TamperedBytes)

$FixtureSnapshotBefore = Get-FixtureSnapshot -Root $WorkspaceRoot

$TamperedSession = $null
try {
	$TamperedSession = Start-InspectionServer `
		-AttestationPath $TamperedAttestationPath `
		-AttestationSha256 $AttestationSha256 `
		-WorkspaceRoot $WorkspaceRoot
	if (-not $TamperedSession.Process.WaitForExit(30000)) {
		$TamperedSession.Process.Kill()
		throw 'Tampered-attestation server did not exit.'
	}
	$TamperedStandardError = [string]$TamperedSession.StandardErrorTask.Result
	Add-Result `
		-Name 'Tampered attestation refuses startup' `
		-Passed (
			$TamperedSession.Process.ExitCode -ne 0 -and
			$TamperedStandardError -match 'failed closed at startup'
		)
}
catch {
	Add-Result `
		-Name 'Tampered attestation refuses startup' `
		-Passed $false `
		-Detail $_.Exception.Message
}

$Session = $null
try {
	$Session = Start-InspectionServer `
		-AttestationPath $AttestationPath `
		-AttestationSha256 $AttestationSha256 `
		-WorkspaceRoot $WorkspaceRoot

	$InitializeLine = Send-InspectionRequest -Session $Session -Json (
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
		'{"protocolVersion":"2025-03-26","capabilities":{},' +
		'"clientInfo":{"name":"delivery-source-inspection-tests",' +
		'"version":"1.0.0"}}}'
	)
	$Initialize = $InitializeLine | ConvertFrom-Json
	Add-Result `
		-Name 'Server completes the initialize handshake' `
		-Passed (
			[string]$Initialize.result.protocolVersion -ceq '2025-03-26' -and
			[string]$Initialize.result.serverInfo.name -ceq
				'delivery-source-inspection' -and
			$null -ne $Initialize.result.capabilities.tools
		)
	$null = Send-InspectionRequest -Session $Session -Notification -Json (
		'{"jsonrpc":"2.0","method":"notifications/initialized"}'
	)

	$ToolsLine = Send-InspectionRequest -Session $Session -Json (
		'{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
	)
	$Tools = @(($ToolsLine | ConvertFrom-Json).result.tools)
	$ToolSchema = $Tools[0].inputSchema
	$ToolPropertyNames = @($ToolSchema.properties.PSObject.Properties.Name)
	Add-Result `
		-Name 'Exactly one read tool requires path and non-negative integer offset' `
		-Passed (
			$Tools.Count -eq 1 -and
			[string]$Tools[0].name -ceq 'read_allowed_source_file' -and
			[string]$ToolSchema.type -ceq 'object' -and
			@($ToolSchema.required).Count -eq 2 -and
			[string]@($ToolSchema.required)[0] -ceq 'path' -and
			[string]@($ToolSchema.required)[1] -ceq 'offset_bytes' -and
			$ToolPropertyNames.Count -eq 2 -and
			$ToolPropertyNames[0] -ceq 'path' -and
			$ToolPropertyNames[1] -ceq 'offset_bytes' -and
			[string]$ToolSchema.properties.path.type -ceq 'string' -and
			[string]$ToolSchema.properties.offset_bytes.type -ceq 'integer' -and
			[int64]$ToolSchema.properties.offset_bytes.minimum -eq 0 -and
			$ToolSchema.additionalProperties -eq $false
		)

	$SampleCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'src/sample.txt' `
		-OffsetBytes 0
	$SamplePage = $SampleCall.Response.result.structuredContent
	Add-Result `
		-Name 'One-page UTF-8 response is canonical in text and structured content' `
		-Passed (
			(Test-InspectionPageEnvelope -Call $SampleCall) -and
			[string]$SamplePage.path -ceq 'src/sample.txt' -and
			[string]$SamplePage.encoding -ceq 'utf8' -and
			[int64]$SamplePage.offset_bytes -eq 0 -and
			[int64]$SamplePage.content_bytes -eq $SampleTextBytes.LongLength -and
			[int64]$SamplePage.end_offset_bytes -eq $SampleTextBytes.LongLength -and
			[int64]$SamplePage.file_size_bytes -eq $SampleTextBytes.LongLength -and
			[bool]$SamplePage.eof -and
			(Test-TestByteArrayEqual `
				(Convert-InspectionContentToBytes -Page $SamplePage) `
				$SampleTextBytes) -and
			[string]$SamplePage.base_sha256 -ceq
				[string]$AttestedFiles['src/sample.txt']
		)

	$SamplePages = @(Get-InspectionPages -Session $Session -Path 'src/sample.txt')
	$SampleReconstructed = Get-ReconstructedInspectionBytes `
		-Pages $SamplePages `
		-ExpectedPath 'src/sample.txt' `
		-ExpectedSha256 ([string]$AttestedFiles['src/sample.txt'])
	Add-Result `
		-Name 'One-page compatibility reconstructs the exact original UTF-8 file' `
		-Passed (
			$SamplePages.Count -eq 1 -and
			(Test-TestByteArrayEqual $SampleReconstructed $SampleTextBytes)
		)

	$BinaryCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'assets/blob.bin' `
		-OffsetBytes 0
	$BinaryPage = $BinaryCall.Response.result.structuredContent
	Add-Result `
		-Name 'One-page invalid UTF-8 response uses base64 and exact bytes' `
		-Passed (
			(Test-InspectionPageEnvelope -Call $BinaryCall) -and
			[string]$BinaryPage.encoding -ceq 'base64' -and
			(Test-TestByteArrayEqual `
				(Convert-InspectionContentToBytes -Page $BinaryPage) `
				$BinaryBytes) -and
			[string]$BinaryPage.base_sha256 -ceq
				[string]$AttestedFiles['assets/blob.bin']
		)

	$LargeUtf8Pages = @(Get-InspectionPages `
		-Session $Session `
		-Path 'src/large-utf8.txt')
	$LargeUtf8Reconstructed = Get-ReconstructedInspectionBytes `
		-Pages $LargeUtf8Pages `
		-ExpectedPath 'src/large-utf8.txt' `
		-ExpectedSha256 ([string]$AttestedFiles['src/large-utf8.txt'])
	Add-Result `
		-Name 'Multi-page non-ASCII UTF-8 stops only at code-point boundaries' `
		-Passed (
			$LargeUtf8Pages.Count -eq 3 -and
			@($LargeUtf8Pages | Where-Object {
				[string]$_.encoding -cne 'utf8'
			}).Count -eq 0 -and
			[int64]$LargeUtf8Pages[0].content_bytes -eq 8191 -and
			[int64]$LargeUtf8Pages[0].end_offset_bytes -eq 8191 -and
			(Test-TestByteArrayEqual $LargeUtf8Reconstructed $LargeUtf8Bytes)
		)

	$LargeBinaryPages = @(Get-InspectionPages `
		-Session $Session `
		-Path 'assets/large-invalid-utf8.bin')
	$LargeBinaryReconstructed = Get-ReconstructedInspectionBytes `
		-Pages $LargeBinaryPages `
		-ExpectedPath 'assets/large-invalid-utf8.bin' `
		-ExpectedSha256 ([string]$AttestedFiles['assets/large-invalid-utf8.bin'])
	Add-Result `
		-Name 'Multi-page invalid UTF-8 uses bounded base64 pages and reconstructs' `
		-Passed (
			$LargeBinaryPages.Count -eq 3 -and
			@($LargeBinaryPages | Where-Object {
				[string]$_.encoding -cne 'base64'
			}).Count -eq 0 -and
			[int64]$LargeBinaryPages[0].content_bytes -eq 8192 -and
			[int64]$LargeBinaryPages[1].content_bytes -eq 8192 -and
			(Test-TestByteArrayEqual $LargeBinaryReconstructed $LargeBinaryBytes)
		)

	$CeilingPages = @(Get-InspectionPages -Session $Session -Path 'src/ceiling.txt')
	$CeilingPlusOnePages = @(Get-InspectionPages `
		-Session $Session `
		-Path 'src/ceiling-plus-one.txt')
	Add-Result `
		-Name 'Page ceiling is exactly 8192 original bytes' `
		-Passed (
			$CeilingPages.Count -eq 1 -and
			[int64]$CeilingPages[0].content_bytes -eq 8192 -and
			[bool]$CeilingPages[0].eof -and
			$CeilingPlusOnePages.Count -eq 2 -and
			[int64]$CeilingPlusOnePages[0].content_bytes -eq 8192 -and
			-not [bool]$CeilingPlusOnePages[0].eof -and
			[int64]$CeilingPlusOnePages[1].content_bytes -eq 1 -and
			[bool]$CeilingPlusOnePages[1].eof
		)

	$EmptyCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'src/empty.txt' `
		-OffsetBytes 0
	$EmptyPage = $EmptyCall.Response.result.structuredContent
	$EofCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'src/sample.txt' `
		-OffsetBytes $SampleTextBytes.LongLength
	$EofPage = $EofCall.Response.result.structuredContent
	Add-Result `
		-Name 'Empty file and exact EOF offsets return canonical empty EOF pages' `
		-Passed (
			(Test-InspectionPageEnvelope -Call $EmptyCall) -and
			[int64]$EmptyPage.file_size_bytes -eq 0 -and
			[int64]$EmptyPage.content_bytes -eq 0 -and
			[bool]$EmptyPage.eof -and
			(Test-InspectionPageEnvelope -Call $EofCall) -and
			[int64]$EofPage.offset_bytes -eq $SampleTextBytes.LongLength -and
			[int64]$EofPage.content_bytes -eq 0 -and
			[bool]$EofPage.eof
		)

	$RepeatedUtf8Pages = @(Get-InspectionPages `
		-Session $Session `
		-Path 'src/large-utf8.txt')
	$FirstSequenceJson = $LargeUtf8Pages | ConvertTo-Json -Depth 6 -Compress
	$RepeatedSequenceJson = $RepeatedUtf8Pages | ConvertTo-Json -Depth 6 -Compress
	Add-Result `
		-Name 'Successive end offsets produce the same deterministic page sequence' `
		-Passed ($FirstSequenceJson -ceq $RepeatedSequenceJson)

	$GapPages = @(
		$LargeUtf8Pages | ForEach-Object { Copy-TestObject -Value $_ }
	)
	$GapPages[1].offset_bytes = [int64]$GapPages[1].offset_bytes + 1
	$OverlapPages = @(
		$LargeUtf8Pages | ForEach-Object { Copy-TestObject -Value $_ }
	)
	$OverlapPages[1].offset_bytes = [int64]$OverlapPages[1].offset_bytes - 1
	$ReorderedPages = @(
		$LargeUtf8Pages | ForEach-Object { Copy-TestObject -Value $_ }
	)
	$ReorderedFirst = $ReorderedPages[0]
	$ReorderedPages[0] = $ReorderedPages[1]
	$ReorderedPages[1] = $ReorderedFirst
	$DuplicatedPages = @(
		(Copy-TestObject -Value $LargeUtf8Pages[0]),
		(Copy-TestObject -Value $LargeUtf8Pages[0]),
		(Copy-TestObject -Value $LargeUtf8Pages[1]),
		(Copy-TestObject -Value $LargeUtf8Pages[2])
	)
	Add-Result `
		-Name 'Reconstruction rejects deliberate gap overlap reorder and duplicate' `
		-Passed (
			(Test-InspectionSequenceRejected `
				-Pages $GapPages `
				-ExpectedPath 'src/large-utf8.txt' `
				-ExpectedSha256 ([string]$AttestedFiles['src/large-utf8.txt'])) -and
			(Test-InspectionSequenceRejected `
				-Pages $OverlapPages `
				-ExpectedPath 'src/large-utf8.txt' `
				-ExpectedSha256 ([string]$AttestedFiles['src/large-utf8.txt'])) -and
			(Test-InspectionSequenceRejected `
				-Pages $ReorderedPages `
				-ExpectedPath 'src/large-utf8.txt' `
				-ExpectedSha256 ([string]$AttestedFiles['src/large-utf8.txt'])) -and
			(Test-InspectionSequenceRejected `
				-Pages $DuplicatedPages `
				-ExpectedPath 'src/large-utf8.txt' `
				-ExpectedSha256 ([string]$AttestedFiles['src/large-utf8.txt']))
		)

	$InvalidOffsetCases = @(
		[pscustomobject]@{
			Name = 'Missing offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt' }
		},
		[pscustomobject]@{
			Name = 'Null offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt'; offset_bytes = $null }
		},
		[pscustomobject]@{
			Name = 'Boolean offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt'; offset_bytes = $true }
		},
		[pscustomobject]@{
			Name = 'String offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt'; offset_bytes = '0' }
		},
		[pscustomobject]@{
			Name = 'Fractional offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt'; offset_bytes = 0.5 }
		},
		[pscustomobject]@{
			Name = 'Negative offset fails closed'
			Arguments = [pscustomobject]@{ path = 'src/sample.txt'; offset_bytes = -1 }
		}
	)
	foreach ($InvalidOffsetCase in $InvalidOffsetCases) {
		$InvalidOffsetCall = Invoke-InspectionToolCall `
			-Session $Session `
			-Arguments $InvalidOffsetCase.Arguments
		Add-Result `
			-Name $InvalidOffsetCase.Name `
			-Passed (Test-InspectionToolFailure `
				-Call $InvalidOffsetCall `
				-ExpectedCode 'source_offset_invalid')
	}

	$BeyondEofCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'src/sample.txt' `
		-OffsetBytes ($SampleTextBytes.LongLength + 1)
	Add-Result `
		-Name 'Offset beyond EOF fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $BeyondEofCall `
			-ExpectedCode 'source_offset_out_of_range')

	$MidCodePointCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'src/large-utf8.txt' `
		-OffsetBytes 8192
	Add-Result `
		-Name 'Offset inside a UTF-8 code point fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $MidCodePointCall `
			-ExpectedCode 'source_offset_utf8_boundary')

	$UnlistedCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Arguments ([pscustomobject]@{
			path = 'src/unlisted.txt'
			offset_bytes = 0
		})
	Add-Result `
		-Name 'Path outside the attested allowed map fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $UnlistedCall `
			-ExpectedCode 'source_path_not_attested' `
			-ForbiddenText 'DO-NOT-EXPOSE-UNLISTED')

	$SensitiveCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'config/service.pem' `
		-OffsetBytes 0
	Add-Result `
		-Name 'Attested sensitive path still fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $SensitiveCall `
			-ExpectedCode 'source_path_sensitive' `
			-ForbiddenText 'DO-NOT-EXPOSE-SENSITIVE')

	$MissingCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'notes/missing.txt' `
		-OffsetBytes 0
	Add-Result `
		-Name 'Attested missing file fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $MissingCall `
			-ExpectedCode 'source_file_missing')

	$DriftCall = Invoke-InspectionPage `
		-Session $Session `
		-Path 'drift.txt' `
		-OffsetBytes 0
	Add-Result `
		-Name 'Post-attestation byte drift fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $DriftCall `
			-ExpectedCode 'source_snapshot_drift' `
			-ForbiddenText 'DO-NOT-EXPOSE-DRIFTED')

	$ReparsePassed = $false
	$ReparseDetail = ''
	if ($JunctionCreated) {
		$ReparseCall = Invoke-InspectionPage `
			-Session $Session `
			-Path 'linked/escape.txt' `
			-OffsetBytes 0
		$ReparsePassed = Test-InspectionToolFailure `
			-Call $ReparseCall `
			-ExpectedCode 'source_path_reparse' `
			-ForbiddenText 'DO-NOT-EXPOSE-ESCAPE'
	}
	else {
		$ReparseDetail = 'Could not create test junction.'
	}
	Add-Result `
		-Name 'Reparse-point escape fails closed' `
		-Passed $ReparsePassed `
		-Detail $ReparseDetail

	$AbsoluteCall = Invoke-InspectionPage `
		-Session $Session `
		-Path $SampleTextPath `
		-OffsetBytes 0
	Add-Result `
		-Name 'Absolute path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $AbsoluteCall `
			-ExpectedCode 'source_path_unsafe')

	$TraversalCall = Invoke-InspectionPage `
		-Session $Session `
		-Path '../escape.txt' `
		-OffsetBytes 0
	Add-Result `
		-Name 'Parent-traversal path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $TraversalCall `
			-ExpectedCode 'source_path_unsafe')

	$RootedCall = Invoke-InspectionPage `
		-Session $Session `
		-Path '/src/sample.txt' `
		-OffsetBytes 0
	Add-Result `
		-Name 'Rooted path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $RootedCall `
			-ExpectedCode 'source_path_unsafe')

	$UnknownToolLine = Send-InspectionRequest -Session $Session -Json (
		'{"jsonrpc":"2.0","id":999,"method":"tools/call","params":' +
		'{"name":"unknown_source_tool","arguments":{}}}'
	)
	$UnknownToolResponse = $UnknownToolLine | ConvertFrom-Json
	Add-Result `
		-Name 'Unknown tool fails as a JSON-RPC invalid-params error' `
		-Passed (
			[int]$UnknownToolResponse.error.code -eq -32602 -and
			[string]$UnknownToolResponse.error.message -ceq 'Unknown tool.' -and
			$null -eq $UnknownToolResponse.result
		)

	$Session.Process.StandardInput.Close()
	if (-not $Session.Process.WaitForExit(30000)) {
		$Session.Process.Kill()
		throw 'Source-inspection server did not exit after stdin closed.'
	}
	Add-Result `
		-Name 'Server exits cleanly when the client disconnects' `
		-Passed ($Session.Process.ExitCode -eq 0)
}
catch {
	Add-Result `
		-Name 'Source-inspection protocol session completes' `
		-Passed $false `
		-Detail $_.Exception.Message
	if ($null -ne $Session -and -not $Session.Process.HasExited) {
		try { $Session.Process.Kill() } catch { }
	}
}

$FixtureSnapshotAfter = Get-FixtureSnapshot -Root $WorkspaceRoot
$FixtureUnchanged = $FixtureSnapshotBefore.Count -eq $FixtureSnapshotAfter.Count
foreach ($SnapshotKey in $FixtureSnapshotBefore.Keys) {
	if (-not $FixtureSnapshotAfter.Contains($SnapshotKey) -or
		[string]$FixtureSnapshotAfter[$SnapshotKey] -cne
			[string]$FixtureSnapshotBefore[$SnapshotKey]) {
		$FixtureUnchanged = $false
	}
}
Add-Result `
	-Name 'Server performs no fixture writes' `
	-Passed $FixtureUnchanged

$Results | Format-Table -AutoSize

$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) delivery source-inspection test(s) failed. Test artifacts: $TestRoot"
}

Write-Host "All delivery source-inspection tests passed. Test artifacts: $TestRoot"
