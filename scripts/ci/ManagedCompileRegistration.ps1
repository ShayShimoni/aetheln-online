[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Dependency: reviewed native directory pins and non-writable source handles.
# Loading definitions creates no preparation attempt, process, lease or files.
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')

function ConvertTo-ManagedRegistrationPath {
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)][string] $Path)
	if ($Path.Length -gt 4096 -or $Path -notmatch '^[A-Za-z]:[\\/]' -or
		$Path.Substring(2) -match '[:<>"|?*\x00-\x1f]' -or $Path -match '[\\/]{2}') { throw 'managed_registration_invalid' }
	$Parts = $Path.Substring(3).TrimEnd([char[]]'\/').Split([char[]]'\/')
	foreach ($Part in $Parts) {
		if ([string]::IsNullOrEmpty($Part) -or $Part -match '(^\.{1,2}$|[. ]$)' -or
			$Part -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)' -or
			$Part -match '^(?i:\.env(?:\..*)?|\.ssh|\.aws|\.azure|\.credentials.*|\.git-credentials|credentials.*|secrets?(?:\..*)?|tokens?(?:\..*)?|auth(?:entication)?(?:\..*)?|private[-_]?keys?|id_rsa.*|id_ed25519.*|\.runner|\.credentials_rsaparams)$' -or
			$Part -match '(?i)\.(pem|pfx|p12|key)$') { throw 'managed_registration_invalid' }
	}
	$Full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
	if ($Full.Length -le 3) { throw 'managed_registration_invalid' }
	return $Full
}

function Close-ManagedCompileRegistration {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Registration)
	foreach ($Handle in $Registration.handles) { if ($null -ne $Handle) { $Handle.Dispose() } }
}

function Get-ManagedCompileRegistration {
	[CmdletBinding()]
	[OutputType([object])]
	param([Parameter(Mandatory)][string] $Path,
		[Parameter(Mandatory)][string] $ExpectedSha256,
		[Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string] $TargetRoot)
	$Handles = New-Object Collections.ArrayList
	$Stream = $null
	try {
		if ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
			$Repository -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}\z' -or
			$Repository.Split('/')[1] -in @('.', '..')) { throw 'managed_registration_invalid' }
		$Full = ConvertTo-ManagedRegistrationPath -Path $Path
		$Target = ConvertTo-ManagedRegistrationPath -Path $TargetRoot
		if ([IO.Path]::GetExtension($Full) -ine '.json' -or $Full -match '(?i)[\\/]\.git(?:[\\/]|$)') { throw 'managed_registration_invalid' }
		# All ancestors are pinned before the leaf is opened; no reparse traversal.
		foreach ($Handle in (Get-InitialPreparationDirectoryPin -Directory ([IO.Path]::GetDirectoryName($Full)))) { [void] $Handles.Add($Handle) }
		$Source = [Aetheln.PreparationDirectory]::OpenSource($Full)
		[void] $Handles.Add($Source)
		$Stream = New-Object IO.FileStream($Source, [IO.FileAccess]::Read)
		[void] $Handles.Add($Stream)
		if ($Stream.Length -lt 2 -or $Stream.Length -gt 8192) { throw 'managed_registration_invalid' }
		$Bytes = New-Object byte[] ([int] $Stream.Length)
		$Read = 0
		while ($Read -lt $Bytes.Length) {
			$Count = $Stream.Read($Bytes, $Read, $Bytes.Length - $Read)
			if ($Count -le 0) { throw 'managed_registration_invalid' }
			$Read += $Count
		}
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Digest = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		if ($Digest -cne $ExpectedSha256) { throw 'managed_registration_invalid' }
		$Json = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes)
		# Closed flat grammar: literal keys, integer schema 1, strings only elsewhere.
		# Reject duplicates before ConvertFrom-Json can collapse them, including escapes.
		$StringToken = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
		$Entry = '"(?<key>[A-Za-z0-9]+)"\s*:\s*(?<value>1|' + $StringToken + ')'
		$Pattern = '\A\s*\{\s*(?:' + $Entry + ')(?:\s*,\s*(?:' + $Entry + '))*\s*\}\s*\z'
		$Match = [regex]::Match($Json, $Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds(200))
		$Fields = @('schemaVersion', 'registrationId', 'repository', 'targetRoot', 'gitCommonDirectory', 'preparationReceiptSha256')
		if (-not $Match.Success -or $Match.Groups['key'].Captures.Count -ne $Fields.Count) { throw 'managed_registration_invalid' }
		$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Key in $Match.Groups['key'].Captures) {
			if ($Fields -cnotcontains $Key.Value -or -not $Seen.Add($Key.Value)) { throw 'managed_registration_invalid' }
		}
		$Record = $Json | ConvertFrom-Json
		if ($Record.schemaVersion -isnot [int] -or $Record.schemaVersion -ne 1) { throw 'managed_registration_invalid' }
		foreach ($Field in $Fields | Select-Object -Skip 1) { if ($Record.$Field -isnot [string]) { throw 'managed_registration_invalid' } }
		if ($Record.registrationId -cnotmatch '\A[0-9a-f]{32}\z' -or $Record.preparationReceiptSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
			$Record.repository -cne $Repository) { throw 'managed_registration_invalid' }
		$RegisteredTarget = ConvertTo-ManagedRegistrationPath -Path $Record.targetRoot
		$Common = ConvertTo-ManagedRegistrationPath -Path $Record.gitCommonDirectory
		if (-not [string]::Equals($RegisteredTarget, $Target, [StringComparison]::OrdinalIgnoreCase)) { throw 'managed_registration_invalid' }
		foreach ($Directory in @($Target, $Common)) {
			foreach ($Handle in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $Handles.Add($Handle) }
		}
		$Record.targetRoot = $RegisteredTarget
		$Record.gitCommonDirectory = $Common
		# Operator trust binding only: not a certificate of current output bytes,
		# Git endpoints/hooks/filters, or source revision. Caller owns those checks.
		return [pscustomobject]@{ record = $Record; proof = [pscustomobject]@{ path = $Full; sha256 = $Digest; retainedHandleCount = $Handles.Count }; handles = @($Handles) }
	} catch {
		foreach ($Handle in $Handles) { $Handle.Dispose() }
		throw 'managed_registration_invalid'
	}
}
