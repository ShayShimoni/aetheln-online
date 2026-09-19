# Reviewed manifest identity plus retained executable dependency handles. This
# binds the full preparation controller, not just its Operation entry point.
function Get-InitialPreparationControllerPath {
	return @('Bootstrap', 'Build', 'BuildInvocation', 'Controller', 'Core', 'Execution', 'GitHub', 'Host', 'Input', 'Materialize', 'Monitor', 'MonitorWorker', 'Operation', 'Progress', 'Readiness', 'ReadinessInvocation', 'Recovery', 'Source', 'ToolSelection', 'Work' | ForEach-Object { 'scripts/ci/InitialPreparation.' + $_ + '.ps1' }) + @('scripts/ci/Invoke-InitialPreparation.ps1')
}

function Close-InitialPreparationControllerProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Proof)
	foreach ($Handle in $Proof.handles) { $Handle.Dispose() }
	$Proof.closed = $true
}

function Get-InitialPreparationControllerProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $ManifestPath,
		[Parameter(Mandatory)][string] $ManifestSha256, [Parameter(Mandatory)] $Attempt)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Handles = New-Object Collections.ArrayList
	try {
		if ($ManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid' }
		foreach ($Directory in @($Root, (Split-Path -Parent $ManifestPath), (Join-Path $Root 'scripts/ci'))) {
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $Handles.Add($Pin) }
		}
		$Handle = [Aetheln.PreparationDirectory]::OpenSource($ManifestPath)
		[void] $Handles.Add($Handle)
		$Stream = [IO.FileStream]::new($Handle, [IO.FileAccess]::Read)
		[void] $Handles.Add($Stream)
		if ($Stream.Length -lt 1 -or $Stream.Length -gt 65536) { throw 'invalid' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
		finally { $Hasher.Dispose() }
		if ($Digest -cne $ManifestSha256) { throw 'invalid' }
		$Stream.Position = 0
		$Bytes = New-Object byte[] ([int] $Stream.Length)
		$Offset = 0
		while ($Offset -lt $Bytes.Length) {
			$Count = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
			if ($Count -le 0) { throw 'invalid' }
			$Offset += $Count
		}
		$Utf8 = New-Object Text.UTF8Encoding($false, $true)
		$Json = $Utf8.GetString($Bytes)
		$Manifest = $Json | ConvertFrom-Json
		$Expected = @(Get-InitialPreparationControllerPath)
		$Fields = @('schemaVersion', 'repository', 'controllerRevision', 'files')
		if (@($Manifest.PSObject.Properties).Count -ne 4) { throw 'invalid' }
		foreach ($Name in $Manifest.PSObject.Properties.Name) { if ($Fields -cnotcontains $Name) { throw 'invalid' } }
		if ($Manifest.schemaVersion -isnot [int] -or $Manifest.schemaVersion -ne 1 -or
			$Manifest.repository -isnot [string] -or $Manifest.repository -cne $Attempt.repository -or
			$Manifest.controllerRevision -isnot [string] -or $Manifest.controllerRevision -cne $Attempt.controllerRevision -or
			$Manifest.files -isnot [array] -or $Manifest.files.Count -ne $Expected.Count) { throw 'invalid' }
		$Keys = [regex]::Matches($Json, '"(?:[^"\\]|\\.)*"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(100))
		if ($Keys.Count -ne (4 + 3 * $Expected.Count)) { throw 'invalid' }
		$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		$Total = 0L
		foreach ($File in $Manifest.files) {
			if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'invalid' }
			if (@($File.PSObject.Properties).Count -ne 3) { throw 'invalid' }
			foreach ($Name in $File.PSObject.Properties.Name) { if (@('path', 'sha256', 'bytes') -cnotcontains $Name) { throw 'invalid' } }
			if ($File.path -isnot [string] -or $Expected -cnotcontains $File.path -or -not $Seen.Add($File.path) -or
				$File.sha256 -isnot [string] -or $File.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
				($File.bytes -isnot [int] -and $File.bytes -isnot [long]) -or $File.bytes -lt 1 -or $File.bytes -gt 262144) { throw 'invalid' }
			$Total += $File.bytes
			if ($Total -gt 4194304) { throw 'invalid' }
			$Handle = [Aetheln.PreparationDirectory]::OpenSource((Join-Path $Root $File.path))
			[void] $Handles.Add($Handle)
			$Stream = [IO.FileStream]::new($Handle, [IO.FileAccess]::Read)
			[void] $Handles.Add($Stream)
			if ($Stream.Length -ne $File.bytes) { throw 'invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
			if ($Digest -cne $File.sha256) { throw 'invalid' }
		}
		if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'invalid' }
		return [pscustomobject]@{ manifestSha256 = $ManifestSha256; files = $Manifest.files; handles = @($Handles); closed = $false }
	} catch {
		foreach ($Handle in $Handles) { $Handle.Dispose() }
		throw 'controller_proof_invalid'
	}
}
