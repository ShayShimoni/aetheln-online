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

	$Attestation = [System.Text.UTF8Encoding]::new($false, $true).GetString(
		$AttestationBytes
	) | ConvertFrom-Json
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

function Invoke-DeliveryReadAllowedSourceFile {
	param(
		[AllowNull()]
		[object]$Arguments
	)

	$RequestedPath = $null
	if ($null -ne $Arguments -and
		@($Arguments.PSObject.Properties.Name) -ccontains 'path') {
		$RequestedPath = $Arguments.path
	}

	if ($RequestedPath -isnot [string] -or
		[string]::IsNullOrWhiteSpace($RequestedPath)) {
		return New-DeliveryToolError `
			-Code 'source_path_unsafe' `
			-Message 'Tool argument path must be one non-empty string.'
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

	$Encoding = 'base64'
	$Content = $null
	try {
		$Content = [System.Text.UTF8Encoding]::new($false, $true).GetString(
			$FileBytes
		)
		$Encoding = 'utf8'
	}
	catch {
		$Content = [System.Convert]::ToBase64String($FileBytes)
		$Encoding = 'base64'
	}

	return [pscustomobject][ordered]@{
		content = @(
			[pscustomobject][ordered]@{
				type = 'text'
				text = 'read_allowed_source_file returned the attested file result.'
			}
		)
		structuredContent = [pscustomobject][ordered]@{
			path = $RequestedPath
			encoding = $Encoding
			content = $Content
			base_sha256 = $ActualSha256
		}
		isError = $false
	}
}

$ToolDefinition = [pscustomobject][ordered]@{
	name = 'read_allowed_source_file'
	description = (
		'Return the complete attested bytes and the launcher-owned base ' +
		'SHA-256 for one exact allowed repository-relative source path.'
	)
	inputSchema = [pscustomobject][ordered]@{
		type = 'object'
		properties = [pscustomobject][ordered]@{
			path = [pscustomobject][ordered]@{
				type = 'string'
				description = 'Exact repository-relative allowed source path.'
			}
		}
		required = @('path')
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
