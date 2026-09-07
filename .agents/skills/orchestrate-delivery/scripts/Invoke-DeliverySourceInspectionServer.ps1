[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$AttestationPath,

	[Parameter(Mandatory)]
	[string]$AttestationSha256,

	[Parameter(Mandatory)]
	[string]$WorkspaceRoot
)

$ErrorActionPreference = 'Stop'

$SensitivePathScript = Join-Path $PSScriptRoot 'Test-DeliverySensitivePath.ps1'
$ReparseCheckScript = Join-Path $PSScriptRoot 'Assert-DeliveryPathNoReparse.ps1'
$MaximumPageBytes = 8192
$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Get-DeliverySourceSha256 {
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

function ConvertTo-DeliverySourceJsonString {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Value
	)

	$Builder = [System.Text.StringBuilder]::new()
	[void]$Builder.Append('"')
	foreach ($Character in $Value.ToCharArray()) {
		$Code = [int][char]$Character
		$Escaped = switch ($Code) {
			8 { '\b' }
			9 { '\t' }
			10 { '\n' }
			12 { '\f' }
			13 { '\r' }
			34 { '\"' }
			92 { '\\' }
			default {
				if ($Code -lt 32) { '\u{0:x4}' -f $Code }
				else { [string]$Character }
			}
		}
		[void]$Builder.Append([string]$Escaped)
	}
	[void]$Builder.Append('"')
	return $Builder.ToString()
}

function ConvertTo-DeliverySourcePageText {
	param([Parameter(Mandatory)][object]$Page)

	$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
	$Builder = [System.Text.StringBuilder]::new()
	[void]$Builder.Append('{"path":')
	[void]$Builder.Append((ConvertTo-DeliverySourceJsonString -Value ([string]$Page.path)))
	[void]$Builder.Append(',"encoding":')
	[void]$Builder.Append((ConvertTo-DeliverySourceJsonString -Value ([string]$Page.encoding)))
	[void]$Builder.Append(',"content":')
	[void]$Builder.Append((ConvertTo-DeliverySourceJsonString -Value ([string]$Page.content)))
	[void]$Builder.Append(',"base_sha256":')
	[void]$Builder.Append((ConvertTo-DeliverySourceJsonString -Value ([string]$Page.base_sha256)))
	[void]$Builder.Append(',"offset_bytes":')
	[void]$Builder.Append(([int64]$Page.offset_bytes).ToString($Invariant))
	[void]$Builder.Append(',"content_bytes":')
	[void]$Builder.Append(([int64]$Page.content_bytes).ToString($Invariant))
	[void]$Builder.Append(',"end_offset_bytes":')
	[void]$Builder.Append(([int64]$Page.end_offset_bytes).ToString($Invariant))
	[void]$Builder.Append(',"file_size_bytes":')
	[void]$Builder.Append(([int64]$Page.file_size_bytes).ToString($Invariant))
	[void]$Builder.Append(',"eof":')
	[void]$Builder.Append($(if ([bool]$Page.eof) { 'true' } else { 'false' }))
	[void]$Builder.Append('}')
	return $Builder.ToString()
}

$AttestedFiles = $null
try {
	if (-not (Test-Path -LiteralPath $SensitivePathScript -PathType Leaf) -or
		-not (Test-Path -LiteralPath $ReparseCheckScript -PathType Leaf)) {
		throw 'Source-inspection policy scripts are missing.'
	}

	if ($AttestationSha256 -cnotmatch '^[0-9a-f]{64}$') {
		throw 'Source attestation hash must be 64 lowercase hex characters.'
	}

	$AttestationBytes = [System.IO.File]::ReadAllBytes($AttestationPath)
	$ActualAttestationSha256 = Get-DeliverySourceSha256 -Bytes $AttestationBytes
	if ($ActualAttestationSha256 -cne $AttestationSha256) {
		throw (
			"Source attestation '$AttestationPath' does not match the " +
			'launcher-supplied SHA-256; refusing to serve source files.'
		)
	}

	$Attestation = $StrictUtf8.GetString($AttestationBytes) | ConvertFrom-Json
	if ($null -eq $Attestation.attested_files) {
		throw 'Source attestation does not declare an attested_files map.'
	}

	$AttestedFiles = [System.Collections.Generic.Dictionary[string, string]]::new(
		[System.StringComparer]::Ordinal
	)
	foreach ($AttestedProperty in $Attestation.attested_files.PSObject.Properties) {
		$AttestedHash = [string]$AttestedProperty.Value
		if ($AttestedHash -cnotmatch '^[0-9a-f]{64}$') {
			throw "Attested hash for '$($AttestedProperty.Name)' is malformed."
		}
		$AttestedFiles[[string]$AttestedProperty.Name] = $AttestedHash
	}

	$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
	if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
		throw "Workspace root '$WorkspaceRoot' is not a directory."
	}
}
catch {
	[System.Console]::Error.WriteLine(
		'Source-inspection server failed closed at startup: ' +
		$_.Exception.Message
	)
	exit 1
}

function New-DeliveryToolError {
	param(
		[Parameter(Mandatory)]
		[string]$Code,

		[Parameter(Mandatory)]
		[string]$Message
	)

	return [pscustomobject][ordered]@{
		content = @(
			[pscustomobject][ordered]@{
				type = 'text'
				text = "[$Code] $Message"
			}
		)
		isError = $true
	}
}

function Test-DeliveryOffsetInteger {
	param(
		[AllowNull()]
		[object]$Value
	)

	return $Value -is [byte] -or
		$Value -is [sbyte] -or
		$Value -is [int16] -or
		$Value -is [uint16] -or
		$Value -is [int32] -or
		$Value -is [uint32] -or
		$Value -is [int64] -or
		$Value -is [uint64]
}

function Test-DeliveryUtf8Range {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[int64]$Offset,

		[Parameter(Mandatory)]
		[int64]$Count
	)

	try {
		$null = $StrictUtf8.GetString($Bytes, [int]$Offset, [int]$Count)
		return $true
	}
	catch [System.Text.DecoderFallbackException] {
		return $false
	}
}

function Invoke-DeliveryReadAllowedSourceFile {
	param(
		[AllowNull()]
		[object]$Arguments
	)

	$RequestedPath = $null
	$OffsetValue = $null
	$ArgumentNames = @()
	if ($null -ne $Arguments) {
		$ArgumentNames = @($Arguments.PSObject.Properties.Name)
		if ($ArgumentNames -ccontains 'path') {
			$RequestedPath = $Arguments.path
		}
		if ($ArgumentNames -ccontains 'offset_bytes') {
			$OffsetValue = $Arguments.offset_bytes
		}
	}
	$UnsupportedArgumentNames = @($ArgumentNames | Where-Object {
		@('path', 'offset_bytes') -cnotcontains [string]$_
	})
	if ($ArgumentNames.Count -gt 2 -or $UnsupportedArgumentNames.Count -gt 0) {
		return New-DeliveryToolError `
			-Code 'source_argument_keys_invalid' `
			-Message 'Tool arguments must contain exactly path and offset_bytes.'
	}

	if ($RequestedPath -isnot [string] -or
		[string]::IsNullOrWhiteSpace($RequestedPath)) {
		return New-DeliveryToolError `
			-Code 'source_path_unsafe' `
			-Message 'Tool argument path must be one non-empty string.'
	}

	if ($ArgumentNames -cnotcontains 'offset_bytes' -or
		-not (Test-DeliveryOffsetInteger -Value $OffsetValue)) {
		return New-DeliveryToolError `
			-Code 'source_offset_invalid' `
			-Message 'Tool argument offset_bytes must be one non-negative integer.'
	}

	try {
		$OffsetBytes = [int64]$OffsetValue
	}
	catch {
		return New-DeliveryToolError `
			-Code 'source_offset_invalid' `
			-Message 'Tool argument offset_bytes must be one non-negative integer.'
	}
	if ($OffsetBytes -lt 0) {
		return New-DeliveryToolError `
			-Code 'source_offset_invalid' `
			-Message 'Tool argument offset_bytes must be one non-negative integer.'
	}

	$PathSegments = @($RequestedPath -split '[\/]')
	if ([System.IO.Path]::IsPathRooted($RequestedPath) -or
		$RequestedPath.StartsWith('/') -or
		$RequestedPath.StartsWith('\') -or
		$RequestedPath.Contains(':') -or
		$PathSegments -ccontains '..') {
		return New-DeliveryToolError `
			-Code 'source_path_unsafe' `
			-Message 'Path must be an exact relative repository path without traversal.'
	}

	if (-not $AttestedFiles.ContainsKey($RequestedPath)) {
		return New-DeliveryToolError `
			-Code 'source_path_not_attested' `
			-Message 'Path is not in the attested allowed source-file map.'
	}

	if (& $SensitivePathScript -RelativePath $RequestedPath) {
		return New-DeliveryToolError `
			-Code 'source_path_sensitive' `
			-Message 'Path matches the sensitive-path policy and cannot be read.'
	}

	$FullPath = [System.IO.Path]::GetFullPath(
		(Join-Path $WorkspaceRoot $RequestedPath)
	)
	try {
		& $ReparseCheckScript -Path $FullPath -Root $WorkspaceRoot
	}
	catch {
		return New-DeliveryToolError `
			-Code 'source_path_reparse' `
			-Message 'Path traverses a reparse point or escapes the workspace root.'
	}

	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
		return New-DeliveryToolError `
			-Code 'source_file_missing' `
			-Message 'Attested source file does not exist in the workspace.'
	}

	try {
		$FileBytes = [System.IO.File]::ReadAllBytes($FullPath)
	}
	catch {
		return New-DeliveryToolError `
			-Code 'source_file_missing' `
			-Message 'Attested source file could not be read.'
	}

	$ActualSha256 = Get-DeliverySourceSha256 -Bytes $FileBytes
	if ($ActualSha256 -cne $AttestedFiles[$RequestedPath]) {
		return New-DeliveryToolError `
			-Code 'source_snapshot_drift' `
			-Message 'Source file bytes no longer match the attested snapshot hash.'
	}

	$FileSizeBytes = [int64]$FileBytes.LongLength
	if ($OffsetBytes -gt $FileSizeBytes) {
		return New-DeliveryToolError `
			-Code 'source_offset_out_of_range' `
			-Message 'Tool argument offset_bytes exceeds the attested file size.'
	}

	$IsUtf8 = Test-DeliveryUtf8Range `
		-Bytes $FileBytes `
		-Offset 0 `
		-Count $FileSizeBytes
	if ($IsUtf8 -and -not (Test-DeliveryUtf8Range `
			-Bytes $FileBytes `
			-Offset 0 `
			-Count $OffsetBytes)) {
		return New-DeliveryToolError `
			-Code 'source_offset_utf8_boundary' `
			-Message 'Tool argument offset_bytes splits a UTF-8 code point.'
	}

	$ContentBytes = [Math]::Min(
		[int64]$MaximumPageBytes,
		$FileSizeBytes - $OffsetBytes
	)
	if ($IsUtf8) {
		while ($ContentBytes -gt 0 -and
			-not (Test-DeliveryUtf8Range `
				-Bytes $FileBytes `
				-Offset $OffsetBytes `
				-Count $ContentBytes)) {
			$ContentBytes--
		}
	}

	$Encoding = 'base64'
	if ($IsUtf8) {
		$Encoding = 'utf8'
		$Content = $StrictUtf8.GetString(
			$FileBytes,
			[int]$OffsetBytes,
			[int]$ContentBytes
		)
	}
	else {
		$PageBytes = [byte[]]::new([int]$ContentBytes)
		if ($ContentBytes -gt 0) {
			[System.Buffer]::BlockCopy(
				$FileBytes,
				[int]$OffsetBytes,
				$PageBytes,
				0,
				[int]$ContentBytes
			)
		}
		$Content = [System.Convert]::ToBase64String($PageBytes)
	}

	$EndOffsetBytes = $OffsetBytes + $ContentBytes
	$PageResult = [pscustomobject][ordered]@{
		path = $RequestedPath
		encoding = $Encoding
		content = $Content
		base_sha256 = $ActualSha256
		offset_bytes = $OffsetBytes
		content_bytes = $ContentBytes
		end_offset_bytes = $EndOffsetBytes
		file_size_bytes = $FileSizeBytes
		eof = ($EndOffsetBytes -eq $FileSizeBytes)
	}
	$PageText = ConvertTo-DeliverySourcePageText -Page $PageResult

	return [pscustomobject][ordered]@{
		content = @(
			[pscustomobject][ordered]@{
				type = 'text'
				text = $PageText
			}
		)
		structuredContent = $PageResult
		isError = $false
	}
}

$ToolDefinition = [pscustomobject][ordered]@{
	name = 'read_allowed_source_file'
	description = (
		'Return one bounded page of complete attested bytes and the launcher-owned ' +
		'base SHA-256 for one exact allowed repository-relative source path.'
	)
	inputSchema = [pscustomobject][ordered]@{
		type = 'object'
		properties = [pscustomobject][ordered]@{
			path = [pscustomobject][ordered]@{
				type = 'string'
				description = 'Exact repository-relative allowed source path.'
			}
			offset_bytes = [pscustomobject][ordered]@{
				type = 'integer'
				minimum = 0
				description = 'Zero-based page offset measured in original file bytes.'
			}
		}
		required = @('path', 'offset_bytes')
		additionalProperties = $false
	}
}

$StdIn = [System.IO.StreamReader]::new(
	[System.Console]::OpenStandardInput(),
	[System.Text.UTF8Encoding]::new($false)
)
$StdOut = [System.IO.StreamWriter]::new(
	[System.Console]::OpenStandardOutput(),
	[System.Text.UTF8Encoding]::new($false)
)
$StdOut.AutoFlush = $true
$StdOut.NewLine = "`n"

function Send-DeliveryRpcMessage {
	param(
		[Parameter(Mandatory)]
		[object]$Message
	)

	$StdOut.WriteLine(($Message | ConvertTo-Json -Depth 16 -Compress))
}

function Send-DeliveryRpcResult {
	param(
		[AllowNull()]
		[object]$Id,

		[Parameter(Mandatory)]
		[object]$Result
	)

	Send-DeliveryRpcMessage -Message ([pscustomobject][ordered]@{
		jsonrpc = '2.0'
		id = $Id
		result = $Result
	})
}

function Send-DeliveryRpcError {
	param(
		[AllowNull()]
		[object]$Id,

		[Parameter(Mandatory)]
		[int]$Code,

		[Parameter(Mandatory)]
		[string]$Message
	)

	Send-DeliveryRpcMessage -Message ([pscustomobject][ordered]@{
		jsonrpc = '2.0'
		id = $Id
		error = [pscustomobject][ordered]@{
			code = $Code
			message = $Message
		}
	})
}

while ($true) {
	$Line = $StdIn.ReadLine()
	if ($null -eq $Line) {
		break
	}
	if ([string]::IsNullOrWhiteSpace($Line)) {
		continue
	}

	$Request = $null
	try {
		$Request = $Line | ConvertFrom-Json
	}
	catch {
		Send-DeliveryRpcError -Id $null -Code -32700 -Message 'Parse error.'
		continue
	}

	$RequestId = $null
	$HasRequestId = @($Request.PSObject.Properties.Name) -ccontains 'id'
	if ($HasRequestId) {
		$RequestId = $Request.id
	}
	$Method = [string]$Request.method

	if ($Method -ceq 'initialize') {
		$ProtocolVersion = '2025-03-26'
		if ($null -ne $Request.params -and
			@($Request.params.PSObject.Properties.Name) -ccontains
				'protocolVersion' -and
			$Request.params.protocolVersion -is [string] -and
			-not [string]::IsNullOrWhiteSpace($Request.params.protocolVersion)) {
			$ProtocolVersion = [string]$Request.params.protocolVersion
		}
		Send-DeliveryRpcResult -Id $RequestId -Result ([pscustomobject][ordered]@{
			protocolVersion = $ProtocolVersion
			capabilities = [pscustomobject][ordered]@{
				tools = [pscustomobject]@{}
			}
			serverInfo = [pscustomobject][ordered]@{
				name = 'delivery-source-inspection'
				version = '1.0.0'
			}
		})
		continue
	}

	if (-not $HasRequestId) {
		continue
	}

	if ($Method -ceq 'tools/list') {
		Send-DeliveryRpcResult -Id $RequestId -Result ([pscustomobject][ordered]@{
			tools = @($ToolDefinition)
		})
		continue
	}

	if ($Method -ceq 'tools/call') {
		$ToolName = $null
		$ToolArguments = $null
		if ($null -ne $Request.params) {
			$ToolName = [string]$Request.params.name
			if (@($Request.params.PSObject.Properties.Name) -ccontains
				'arguments') {
				$ToolArguments = $Request.params.arguments
			}
		}

		if ($ToolName -cne 'read_allowed_source_file') {
			Send-DeliveryRpcError `
				-Id $RequestId `
				-Code -32602 `
				-Message 'Unknown tool.'
			continue
		}

		Send-DeliveryRpcResult `
			-Id $RequestId `
			-Result (
				Invoke-DeliveryReadAllowedSourceFile -Arguments $ToolArguments
			)
		continue
	}

	Send-DeliveryRpcError -Id $RequestId -Code -32601 -Message 'Method not found.'
}
