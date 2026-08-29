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

		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Path
	)

	$Script:NextRequestId = $Script:NextRequestId + 1
	$Request = [pscustomobject][ordered]@{
		jsonrpc = '2.0'
		id = $Script:NextRequestId
		method = 'tools/call'
		params = [pscustomobject][ordered]@{
			name = 'read_allowed_source_file'
			arguments = [pscustomobject]@{
				path = $Path
			}
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
	'config/service.pem' = Get-TestSha256 -Bytes $SensitiveBytes
	'drift.txt' = Get-TestSha256 -Bytes $DriftOriginalBytes
	'linked/escape.txt' = Get-TestSha256 -Bytes $EscapeBytes
	'notes/missing.txt' = Get-TestSha256 -Bytes $MissingBytes
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
		'src/sample.txt'
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
		-Name 'Exactly one read tool with one required string path parameter' `
		-Passed (
			$Tools.Count -eq 1 -and
			[string]$Tools[0].name -ceq 'read_allowed_source_file' -and
			[string]$ToolSchema.type -ceq 'object' -and
			@($ToolSchema.required).Count -eq 1 -and
			[string]@($ToolSchema.required)[0] -ceq 'path' -and
			$ToolPropertyNames.Count -eq 1 -and
			$ToolPropertyNames[0] -ceq 'path' -and
			[string]$ToolSchema.properties.path.type -ceq 'string' -and
			$ToolSchema.additionalProperties -eq $false
		)

	$SampleCall = Invoke-InspectionToolCall -Session $Session -Path 'src/sample.txt'
	$SampleResult = $SampleCall.Response.result
	$SampleStructured = $SampleResult.structuredContent
	Add-Result `
		-Name 'Attested UTF-8 file returns complete utf8 bytes and attested hash' `
		-Passed (
			$SampleResult.isError -eq $false -and
			[string]$SampleStructured.path -ceq 'src/sample.txt' -and
			[string]$SampleStructured.encoding -ceq 'utf8' -and
			(Test-TestByteArrayEqual `
				([System.Text.UTF8Encoding]::new($false).GetBytes(
					[string]$SampleStructured.content
				)) `
				$SampleTextBytes) -and
			[string]$SampleStructured.base_sha256 -ceq
				[string]$AttestedFiles['src/sample.txt']
		)

	$BinaryCall = Invoke-InspectionToolCall -Session $Session -Path 'assets/blob.bin'
	$BinaryResult = $BinaryCall.Response.result
	$BinaryStructured = $BinaryResult.structuredContent
	Add-Result `
		-Name 'Attested non-UTF-8 file returns complete base64 bytes and attested hash' `
		-Passed (
			$BinaryResult.isError -eq $false -and
			[string]$BinaryStructured.encoding -ceq 'base64' -and
			(Test-TestByteArrayEqual `
				([System.Convert]::FromBase64String(
					[string]$BinaryStructured.content
				)) `
				$BinaryBytes) -and
			[string]$BinaryStructured.base_sha256 -ceq
				[string]$AttestedFiles['assets/blob.bin']
		)

	$UnlistedCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path 'src/unlisted.txt'
	Add-Result `
		-Name 'Path outside the attested allowed map fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $UnlistedCall `
			-ExpectedCode 'source_path_not_attested' `
			-ForbiddenText 'DO-NOT-EXPOSE-UNLISTED')

	$SensitiveCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path 'config/service.pem'
	Add-Result `
		-Name 'Attested sensitive path still fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $SensitiveCall `
			-ExpectedCode 'source_path_sensitive' `
			-ForbiddenText 'DO-NOT-EXPOSE-SENSITIVE')

	$MissingCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path 'notes/missing.txt'
	Add-Result `
		-Name 'Attested missing file fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $MissingCall `
			-ExpectedCode 'source_file_missing')

	$DriftCall = Invoke-InspectionToolCall -Session $Session -Path 'drift.txt'
	Add-Result `
		-Name 'Post-attestation byte drift fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $DriftCall `
			-ExpectedCode 'source_snapshot_drift' `
			-ForbiddenText 'DO-NOT-EXPOSE-DRIFTED')

	$ReparsePassed = $false
	$ReparseDetail = ''
	if ($JunctionCreated) {
		$ReparseCall = Invoke-InspectionToolCall `
			-Session $Session `
			-Path 'linked/escape.txt'
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

	$AbsoluteCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path $SampleTextPath
	Add-Result `
		-Name 'Absolute path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $AbsoluteCall `
			-ExpectedCode 'source_path_unsafe')

	$TraversalCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path '../escape.txt'
	Add-Result `
		-Name 'Parent-traversal path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $TraversalCall `
			-ExpectedCode 'source_path_unsafe')

	$RootedCall = Invoke-InspectionToolCall `
		-Session $Session `
		-Path '/src/sample.txt'
	Add-Result `
		-Name 'Rooted path fails closed' `
		-Passed (Test-InspectionToolFailure `
			-Call $RootedCall `
			-ExpectedCode 'source_path_unsafe')

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
