# Definition-only checkpoint policy. Called by the lease-owning provisioner and
# its supervised Windows PowerShell worker; it never launches a native build.
function Get-HostToolGeneratedPaths {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot)
	$Engine = Join-Path $EngineRoot 'Engine'
	$Roots = @(
		(Join-Path $Engine 'Binaries/Win64'),
		(Join-Path $Engine 'Intermediate/Build'),
		(Join-Path $Engine 'Binaries/DotNET/UnrealBuildTool'),
		(Join-Path $Engine 'Plugins'),
		(Join-Path $Engine 'Source/Programs')
	)
	$Paths = New-Object 'Collections.Generic.List[string]'
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Visited = 0
	foreach ($Root in $Roots) {
		if (-not (Test-Path -LiteralPath $Root)) { continue }
		Assert-InitialPreparationPlainPath -Path $Root -Reason 'checkpoint_path_invalid'
		$Stack = New-Object Collections.Stack
		$Stack.Push($Root)
		while ($Stack.Count -gt 0) {
			$Directory = [string] $Stack.Pop()
			foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
				$Visited++
				if ($Visited -gt 1000000) { throw 'checkpoint_entry_limit' }
				Assert-InitialPreparationPlainPath -Path $Item.FullName -Reason 'checkpoint_path_invalid'
				$Relative = $Item.FullName.Substring($EngineRoot.TrimEnd('\').Length + 1).Replace('\', '/')
				if ($Relative -match '(^|/)(\.env(?:\.[^/]*)?|[^/]+\.(?:pem|pfx|p12|p8|ppk|key|kdbx|jks|keystore|snk|gpg|asc)|id_(?:rsa|dsa|ecdsa|ed25519)(?:\.[^/]*)?|credentials(?:\.[^/]*)?|secrets?(?:\.[^/]*)?|kubeconfig(?:\.[^/]*)?)(?=/|$)') { throw 'checkpoint_protected_name' }
				if ($Item.PSIsContainer) { $Stack.Push($Item.FullName); continue }
				$Generated = $Relative -cmatch '^Engine/(Binaries/Win64|Intermediate/Build|Binaries/DotNET/UnrealBuildTool)/' -or
					$Relative -cmatch '^Engine/Plugins/.+/(Binaries/Win64|Intermediate/Build|bin|obj)/' -or
					$Relative -cmatch '^Engine/Source/Programs/.+/(bin|obj)/'
				if (-not $Generated) { continue }
				if (-not $Seen.Add($Relative)) { throw 'checkpoint_case_collision' }
				$Paths.Add($Relative)
				if ($Paths.Count -gt 1000000) { throw 'checkpoint_entry_limit' }
			}
		}
	}
	$Paths.Sort([StringComparer]::Ordinal)
	return $Paths.ToArray()
}

function Assert-HostToolCheckpointHeader {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Header, [Parameter(Mandatory)] $Expected, [ValidatePattern('^[A-Z]$')][string] $RequiredDrive = 'F')
	foreach ($Key in @('schemaVersion', 'engineRoot', 'engineRevision', 'controllerRevision', 'compilerSha256',
		'resourceCompilerSha256', 'volumeId', 'configurationSha256', 'attemptOrdinal', 'priorUsefulSeconds')) {
		if ($null -eq $Header.PSObject.Properties[$Key]) { throw 'checkpoint_header_invalid' }
	}
	if ($Header.schemaVersion -ne 2 -or $Header.attemptOrdinal -lt 1 -or $Header.attemptOrdinal -gt 2 -or
		$Header.priorUsefulSeconds -lt 0 -or $Header.priorUsefulSeconds -gt 86400 -or
		$Header.completedTargets -isnot [array] -or $Header.completedTargets.Count -gt 3) { throw 'checkpoint_header_invalid' }
	foreach ($Key in @('engineRoot', 'engineRevision', 'controllerRevision', 'compilerSha256',
		'resourceCompilerSha256', 'volumeId', 'configurationSha256')) {
		if ([string] $Header.$Key -cne [string] $Expected.$Key) { throw 'checkpoint_identity_mismatch' }
	}
	if ($Header.engineRoot -notmatch ('^' + $RequiredDrive + ':\\')) { throw 'checkpoint_engine_root_invalid' }
	$Names = @($Header.completedTargets | ForEach-Object { $_.target })
	if (($Names -join ',') -cne (($script:HostToolTargets | Select-Object -First $Names.Count) -join ',')) { throw 'checkpoint_targets_invalid' }
	return $true
}

function Invoke-HostToolCheckpointFile {
	[CmdletBinding()]
	param([Parameter(Mandatory)][ValidateSet('Create','Verify')][string] $Mode,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $ManifestPath,
		$Header, $ExpectedHeader, [string] $ExpectedManifestSha256,
		[ValidatePattern('^[A-Z]$')][string] $RequiredDrive = 'F')
	if ($EngineRoot -notmatch ('^' + $RequiredDrive + ':\\') -or $ManifestPath -notmatch ('^' + $RequiredDrive + ':\\') -or
		$ManifestPath -notmatch '\.jsonl$' -or
		(Test-InitialPreparationWithin -Candidate $ManifestPath -Parent $EngineRoot)) { throw 'checkpoint_path_invalid' }
	Assert-InitialPreparationPlainPath -Path $EngineRoot -Reason 'checkpoint_path_invalid'
	if ($Mode -ceq 'Create') {
		if ($null -eq $Header -or (Test-Path -LiteralPath $ManifestPath)) { throw 'checkpoint_path_invalid' }
		$null = Assert-HostToolCheckpointHeader -Header $Header -Expected $Header -RequiredDrive $RequiredDrive
	} else {
		if ($null -eq $ExpectedHeader -or $ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
			-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf) -or
			(Get-Item -LiteralPath $ManifestPath).Length -gt 512MB) { throw 'checkpoint_manifest_invalid' }
	}
	$Paths = @(Get-HostToolGeneratedPaths -EngineRoot $EngineRoot)
	$Utf8 = New-Object Text.UTF8Encoding($false)
	if ($Mode -ceq 'Create') {
		$Stream = [IO.File]::Open($ManifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		$Writer = New-Object IO.StreamWriter($Stream, $Utf8)
		try {
			$Writer.WriteLine(($Header | ConvertTo-Json -Depth 15 -Compress))
			foreach ($Relative in $Paths) {
				$Path = Join-Path $EngineRoot $Relative
				$Item = Get-Item -LiteralPath $Path -Force
				$Record = [ordered]@{ path = $Relative; sizeBytes = [long] $Item.Length;
					sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
				$Writer.WriteLine(($Record | ConvertTo-Json -Compress))
				if ($Stream.Position -gt 512MB) { throw 'checkpoint_manifest_limit' }
			}
			$Writer.Flush(); $Stream.Flush($true)
		} finally { $Writer.Dispose() }
		if ((Get-Item -LiteralPath $ManifestPath).Length -gt 512MB) { throw 'checkpoint_manifest_limit' }
		return [pscustomobject]@{ fileCount = $Paths.Count; manifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() }
	}
	Assert-InitialPreparationPlainPath -Path $ManifestPath -Reason 'checkpoint_manifest_invalid'
	# Keep this exact file object open while hashing and parsing. FileShare.Read
	# excludes writers and replacement/deletion until the verified parse completes.
	$ManifestStream = [IO.File]::Open($ManifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		if ($ManifestStream.Length -gt 512MB) { throw 'checkpoint_manifest_invalid' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $ActualSha256 = ([BitConverter]::ToString($Hasher.ComputeHash($ManifestStream))).Replace('-', '').ToLowerInvariant() }
		finally { $Hasher.Dispose() }
		if ($ActualSha256 -cne $ExpectedManifestSha256) { throw 'resume_checkpoint_hash_mismatch' }
		$ManifestStream.Position = 0
		$Reader = New-Object IO.StreamReader($ManifestStream, $Utf8, $true)
		try {
		$First = $Reader.ReadLine()
		if ([string]::IsNullOrWhiteSpace($First) -or $First.Length -gt 65536) { throw 'checkpoint_manifest_invalid' }
		try { $ParsedHeader = $First | ConvertFrom-Json } catch { throw 'checkpoint_manifest_invalid' }
		$null = Assert-HostToolCheckpointHeader -Header $ParsedHeader -Expected $ExpectedHeader -RequiredDrive $RequiredDrive
		for ($Index = 0; $Index -lt $Paths.Count; $Index++) {
			$Line = $Reader.ReadLine()
			if ($null -eq $Line) { throw 'checkpoint_manifest_mismatch' }
			if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -gt 4096) { throw 'checkpoint_manifest_invalid' }
			try { $Record = $Line | ConvertFrom-Json } catch { throw 'checkpoint_manifest_invalid' }
			$Relative = $Paths[$Index]
			if ($Record.path -cne $Relative -or $Record.sizeBytes -lt 0 -or
				$Record.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'checkpoint_manifest_mismatch' }
			$Path = Join-Path $EngineRoot $Relative
			$Item = Get-Item -LiteralPath $Path -Force
			if ($Item.Length -ne $Record.sizeBytes -or
				(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Record.sha256) { throw 'checkpoint_manifest_mismatch' }
		}
		if ($null -ne $Reader.ReadLine()) { throw 'checkpoint_manifest_mismatch' }
		return $ParsedHeader
		} finally { $Reader.Dispose() }
	} finally { $ManifestStream.Dispose() }
}

function Read-HostToolPublicationJson {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path, [string] $ExpectedSha256, [int] $MaxBytes = 65536)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'resume_publication_invalid' }
	Assert-InitialPreparationPlainPath -Path $Path -Reason 'resume_publication_invalid'
	try {
		$Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
		try {
			if ($MaxBytes -lt 1 -or $MaxBytes -gt 65536 -or $Stream.Length -lt 1 -or $Stream.Length -gt $MaxBytes) { throw 'resume_publication_invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
			if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $Sha256 -cne $ExpectedSha256) { throw 'resume_publication_invalid' }
			$Stream.Position = 0
			$Reader = New-Object IO.StreamReader($Stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
			try { $Text = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
		} finally { $Stream.Dispose() }
		return [pscustomobject]@{ sha256 = $Sha256; data = ($Text | ConvertFrom-Json) }
	} catch { throw 'resume_publication_invalid' }
}

function Get-HostToolResumeReceipt {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $ReceiptPath, [Parameter(Mandatory)][string] $ExpectedSha256,
		[Parameter(Mandatory)] $ExpectedHeader, [ValidatePattern('^[A-Z]$')][string] $RequiredReceiptDrive = 'D',
		[ValidatePattern('^[A-Z]$')][string] $RequiredExternalDrive = 'F')
	if ($ReceiptPath -notmatch ('^' + $RequiredReceiptDrive + ':\\') -or $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or
		-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'resume_receipt_invalid' }
	Assert-InitialPreparationPlainPath -Path $ReceiptPath -Reason 'resume_receipt_invalid'
	try {
		$ReceiptStream = [IO.File]::Open($ReceiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
		try {
			if ($ReceiptStream.Length -lt 1 -or $ReceiptStream.Length -gt 65536) { throw 'resume_receipt_invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $ActualSha256 = ([BitConverter]::ToString($Hasher.ComputeHash($ReceiptStream))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
			if ($ActualSha256 -cne $ExpectedSha256) { throw 'resume_receipt_invalid' }
			$ReceiptStream.Position = 0
			$Reader = New-Object IO.StreamReader($ReceiptStream, (New-Object Text.UTF8Encoding($false, $true)), $true)
			try { $ReceiptText = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
		} finally { $ReceiptStream.Dispose() }
		$Receipt = $ReceiptText | ConvertFrom-Json
	} catch { throw 'resume_receipt_invalid' }
	if ($Receipt.schemaVersion -ne 2 -or $Receipt.scope -cne 'bounded_host_tool_provisioning' -or
		$Receipt.success -ne $false -or $Receipt.failure -cne 'useful_work_deadline' -or
		$Receipt.leaseReleased -ne $true -or $Receipt.cleanupVerified -ne $true -or
		$Receipt.attemptOrdinal -ne 1 -or $Receipt.usefulDeadlineSeconds -ne 86400 -or
		$Receipt.checkpointSha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$Receipt.checkpointFileCount -lt 1 -or $Receipt.checkpointPath -notmatch ('^' + $RequiredExternalDrive + ':\\') -or
		(Test-InitialPreparationWithin -Candidate $Receipt.checkpointPath -Parent $ExpectedHeader.engineRoot)) { throw 'resume_receipt_invalid' }
	if ($null -eq $Receipt.PSObject.Properties['evidenceRoot'] -or $Receipt.evidenceRoot -isnot [string] -or
		$Receipt.evidenceRoot -cne (Split-Path -Parent $Receipt.checkpointPath) -or
		$Receipt.checkpointPath -cne (Join-Path $Receipt.evidenceRoot 'generated-output-checkpoint.jsonl')) { throw 'resume_receipt_invalid' }
	if ($null -eq $Receipt.PSObject.Properties['invocations'] -or
		@($Receipt.invocations | Where-Object { ($_.progressCount -is [int] -or $_.progressCount -is [long]) -and $_.progressCount -gt 0 }).Count -lt 1) {
		throw 'resume_no_native_progress'
	}
	foreach ($Name in @('engineRevision', 'controllerRevision', 'compilerSha256', 'resourceCompilerSha256',
		'configurationSha256', 'engineRoot', 'volumeId')) {
		if ([string] $Receipt.$Name -cne [string] $ExpectedHeader.$Name) { throw 'resume_identity_mismatch' }
	}
	if (-not (Test-Path -LiteralPath $Receipt.checkpointPath -PathType Leaf) -or
		(Get-Item -LiteralPath $Receipt.checkpointPath).Length -gt 512MB) { throw 'resume_checkpoint_hash_mismatch' }
	$SupervisorRoot = Split-Path -Parent $ReceiptPath
	if (Test-Path -LiteralPath (Join-Path $SupervisorRoot 'publication-failed.json')) { throw 'resume_publication_invalid' }
	$Complete = (Read-HostToolPublicationJson -Path (Join-Path $SupervisorRoot 'publication-complete.json')).data
	$FReceiptPath = Join-Path $Receipt.evidenceRoot 'host-tool-provisioning-receipt.json'
	if ($Complete.schemaVersion -ne 1 -or $Complete.scope -cne 'host_tool_receipt_publication' -or
		$Complete.complete -ne $true -or $Complete.dReceiptSha256 -cne $ExpectedSha256 -or
		$Complete.fReceiptPath -cne $FReceiptPath -or $Complete.fReceiptSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'resume_publication_invalid' }
	try {
		if ($Complete.resultPath -isnot [string] -or $Complete.deadlineTicks -isnot [long] -and
			$Complete.deadlineTicks -isnot [int]) { throw 'resume_publication_invalid' }
		$ResultLeaf = Split-Path -Leaf $Complete.resultPath
		if ($ResultLeaf -cnotmatch '^publication-result-[0-9a-f]{32}\.json$' -or
			$Complete.resultPath -cne (Join-Path $SupervisorRoot $ResultLeaf)) { throw 'resume_publication_invalid' }
		$PinnedPublicationResult = Read-HostToolPublicationJson -Path $Complete.resultPath -MaxBytes 4096
		$PublicationResult = $PinnedPublicationResult.data
		if ($PublicationResult.schemaVersion -ne 1 -or $PublicationResult.success -ne $true -or
			$PublicationResult.deadlineTicks -ne $Complete.deadlineTicks -or
			$PublicationResult.completedTicks -isnot [long] -and $PublicationResult.completedTicks -isnot [int] -or
			$PublicationResult.completedTicks -lt 1 -or $PublicationResult.completedTicks -ge $PublicationResult.deadlineTicks -or
			$PublicationResult.dReceiptSha256 -cne $ExpectedSha256 -or
			$PublicationResult.fReceiptSha256 -cne $Complete.fReceiptSha256) { throw 'resume_publication_invalid' }
		$Confirmation = (Read-HostToolPublicationJson -Path (Join-Path $SupervisorRoot 'publication-confirmed.json') -MaxBytes 4096).data
		if ($Confirmation.schemaVersion -ne 1 -or $Confirmation.scope -cne 'host_tool_supervisor_confirmation' -or
			$Confirmation.confirmed -ne $true -or $Confirmation.resultPath -cne $Complete.resultPath -or
			$Confirmation.resultSha256 -cne $PinnedPublicationResult.sha256 -or
			$Confirmation.dReceiptSha256 -cne $ExpectedSha256 -or
			$Confirmation.fReceiptSha256 -cne $Complete.fReceiptSha256 -or
			$Confirmation.deadlineTicks -ne $PublicationResult.deadlineTicks -or
			$Confirmation.confirmedTicks -isnot [long] -and $Confirmation.confirmedTicks -isnot [int] -or
			$Confirmation.confirmedTicks -lt $PublicationResult.completedTicks -or
			$Confirmation.confirmedTicks -ge $Confirmation.deadlineTicks) { throw 'resume_publication_invalid' }
	} catch { throw 'resume_publication_invalid' }
	$FReceipt = (Read-HostToolPublicationJson -Path $FReceiptPath -ExpectedSha256 $Complete.fReceiptSha256).data
	if ($FReceipt.dReceiptSha256 -cne $ExpectedSha256 -or $FReceipt.success -ne $false -or
		$FReceipt.failure -cne 'useful_work_deadline' -or $FReceipt.checkpointSha256 -cne $Receipt.checkpointSha256 -or
		$FReceipt.engineRevision -cne $Receipt.engineRevision -or $FReceipt.configurationSha256 -cne $Receipt.configurationSha256) {
		throw 'resume_publication_invalid'
	}
	return $Receipt
}
