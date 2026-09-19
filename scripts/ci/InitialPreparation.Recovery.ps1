# Parent-side interruption recovery. The caller owns the verified outer Job
# cleanup and frozen expected identities. This is trusted-owner procedural
# evidence, not cryptographic authentication of a candidate-controlled writer.
function Assert-InitialPreparationRecoveryIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Runner,
		[Parameter(Mandatory)][string] $RequestSha256)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if ($RequestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Runner.repository -isnot [string] -or
		$Runner.repository -cne $Attempt.repository -or ($Runner.id -isnot [int] -and $Runner.id -isnot [long]) -or $Runner.id -lt 1 -or
		$Runner.name -isnot [string] -or $Runner.name.Length -lt 1 -or $Runner.name.Length -gt 100 -or $Runner.name -match '[\x00-\x1f\x7f]') { throw 'recovery_identity_invalid' }
}

function Assert-InitialPreparationRecoveryRecord {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][string] $RequestSha256,
		[Parameter(Mandatory)][long] $NowTicks)
	$Fields = @('schemaVersion', 'repository', 'controllerRevision', 'targetRevision', 'attemptId', 'requestSha256', 'runnerId', 'runnerName', 'originalLabels', 'intendedAtTicks')
	if (@($Record.PSObject.Properties).Count -ne $Fields.Count) { throw 'recovery_intent_invalid' }
	foreach ($Field in $Record.PSObject.Properties.Name) { if ($Fields -cnotcontains $Field) { throw 'recovery_intent_invalid' } }
	foreach ($Field in @('schemaVersion', 'runnerId', 'intendedAtTicks')) {
		if ($Record.$Field -isnot [int] -and $Record.$Field -isnot [long]) { throw 'recovery_intent_invalid' }
	}
	foreach ($Field in @('repository', 'controllerRevision', 'targetRevision', 'attemptId', 'requestSha256', 'runnerName')) {
		if ($Record.$Field -isnot [string]) { throw 'recovery_intent_invalid' }
	}
	if ($Record.schemaVersion -ne 1 -or $Record.repository -cne $Attempt.repository -or $Record.controllerRevision -cne $Attempt.controllerRevision -or
		$Record.targetRevision -cne $Attempt.targetRevision -or $Record.attemptId -cne $Attempt.attemptId -or $Record.requestSha256 -cne $RequestSha256 -or
		$Record.runnerId -ne $Runner.id -or $Record.runnerName -cne $Runner.name -or
		$Record.intendedAtTicks -lt $Attempt.monotonicStartTicks -or $Record.intendedAtTicks -ge $Attempt.admissionDeadlineTicks -or $Record.intendedAtTicks -gt $NowTicks) { throw 'recovery_intent_invalid' }
	if ($Record.originalLabels -isnot [array] -or $Record.originalLabels.Count -lt 1 -or $Record.originalLabels.Count -gt 100) { throw 'recovery_intent_invalid' }
	$Labels = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Label in $Record.originalLabels) {
		if ($Label -isnot [string] -or [string]::IsNullOrWhiteSpace($Label) -or $Label.Length -gt 100 -or $Label -match '[\x00-\x1f\x7f]' -or -not $Labels.Add($Label)) { throw 'recovery_intent_invalid' }
	}
	if ($Record.originalLabels -cnotcontains 'aetheln-engine') { throw 'recovery_intent_invalid' }
	if ($null -ne $Runner.PSObject.Properties['originalLabels'] -and -not (Test-PreparationLabelSet -Actual $Record.originalLabels -Expected $Runner.originalLabels)) { throw 'recovery_intent_invalid' }
}

function Write-InitialPreparationRecoveryIntent {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([bool])]
	param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][string] $RequestSha256,
		[scriptblock] $ReadTicks = { Get-InitialPreparationTick })
	Assert-InitialPreparationRecoveryIdentity -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256
	$Now = & $ReadTicks
	$Record = [pscustomobject][ordered]@{ schemaVersion = 1; repository = $Attempt.repository; controllerRevision = $Attempt.controllerRevision;
		targetRevision = $Attempt.targetRevision; attemptId = $Attempt.attemptId; requestSha256 = $RequestSha256;
		runnerId = $Runner.id; runnerName = $Runner.name; originalLabels = $Runner.originalLabels; intendedAtTicks = $Now }
	Assert-InitialPreparationRecoveryRecord -Record $Record -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256 -NowTicks $Now
	Assert-InitialPreparationPlainPath -Path $Path -Reason 'recovery_path_invalid'
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 4 -Compress))
	if ($Bytes.Length -gt 16384) { throw 'recovery_intent_invalid' }
	$Pins = Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $Path)
	$Stream = $null
	try {
		if (-not $PSCmdlet.ShouldProcess($Path, 'Persist new quarantine recovery intent')) { throw 'recovery_write_declined' }
		try { $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) } catch { throw 'recovery_evidence_exists' }
		$Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true)
	} finally {
		if ($null -ne $Stream) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
	}
	return $true
}

function Read-InitialPreparationRecoveryIntent {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][string] $RequestSha256,
		[scriptblock] $ReadTicks = { Get-InitialPreparationTick })
	Assert-InitialPreparationRecoveryIdentity -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256
	$Pins = @(); $Stream = $null
	try {
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'recovery_intent_invalid'
		$Pins = Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $Path)
		$Stream = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($Path), [IO.FileAccess]::Read)
		if ($Stream.Length -lt 1 -or $Stream.Length -gt 16384) { throw 'recovery_intent_invalid' }
		$Reader = New-Object IO.StreamReader($Stream, (New-Object Text.UTF8Encoding($false, $true)), $false)
		try { $Json = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
		$Keys = [regex]::Matches($Json, '"(?<key>(?:[^"\\]|\\.)*)"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(50))
		$Unique = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		if ($Keys.Count -ne 10) { throw 'recovery_intent_invalid' }
		foreach ($Key in $Keys) { if (-not $Unique.Add($Key.Groups['key'].Value)) { throw 'recovery_intent_invalid' } }
		$Record = $Json | ConvertFrom-Json
		Assert-InitialPreparationRecoveryRecord -Record $Record -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256 -NowTicks (& $ReadTicks)
		return $Record
	} catch { throw 'recovery_intent_invalid' } finally {
		if ($null -ne $Stream) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
	}
}

function Invoke-InitialPreparationRecovery {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string] $IntentPath, [Parameter(Mandatory)][string] $ResultPath,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Runner,
		[Parameter(Mandatory)][string] $RequestSha256, [Parameter(Mandatory)][AllowNull()] $OwnedCleanupVerified,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request },
		[scriptblock] $ReadTicks = { Get-InitialPreparationTick })
	Assert-InitialPreparationRecoveryIdentity -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256
	Assert-InitialPreparationPlainPath -Path $ResultPath -Reason 'recovery_path_invalid'
	$Pins = Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $ResultPath)
	$Stream = $null
	$RecoveryBudgetState = @{ expired = $false }
	$Result = [ordered]@{ schemaVersion = 1; repository = $Attempt.repository; controllerRevision = $Attempt.controllerRevision;
		targetRevision = $Attempt.targetRevision; attemptId = $Attempt.attemptId; requestSha256 = $RequestSha256; runnerId = $Runner.id; runnerName = $Runner.name;
		state = 'recovery_required'; intentVerified = $false; ownedCleanupVerified = ($OwnedCleanupVerified -is [bool] -and $OwnedCleanupVerified);
		routingRestored = $false; recoveryRequired = $true; baselineVerified = $false; failureCode = 'recovery_incomplete'; finishedTicks = $null }
	try {
		if (-not $PSCmdlet.ShouldProcess($ResultPath, 'Reserve recovery evidence and restore routing only after proven owned cleanup')) { throw 'recovery_write_declined' }
		try { $Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) } catch { throw 'recovery_evidence_exists' }
		try {
			if (-not (Test-Path -LiteralPath $IntentPath)) { $Result.state = 'no_intent'; throw 'recovery_intent_missing' }
			$Intent = Read-InitialPreparationRecoveryIntent -Path $IntentPath -Attempt $Attempt -Runner $Runner -RequestSha256 $RequestSha256 -ReadTicks $ReadTicks
			$Result.intentVerified = $true
			if (-not $Result.ownedCleanupVerified) { throw 'recovery_cleanup_unproven' }
			$RecoveryRunner = [pscustomobject]@{ repository = $Intent.repository; id = $Intent.runnerId; name = $Intent.runnerName; originalLabels = $Intent.originalLabels }
			$RecoveryTransport = $Transport; $RecoveryClock = $ReadTicks; $RecoveryAttempt = $Attempt
			# Production transport has a 30-second timeout plus at most 2 seconds
			# native cleanup. Reserve those bounds and one second for the receipt
			# before EACH request; never reset the original publication deadline.
			$BudgetedTransport = {
				param($Request)
				$Remaining = ($RecoveryAttempt.publicationDeadlineTicks - (& $RecoveryClock)) / [double] $RecoveryAttempt.monotonicFrequency
				if ($Remaining -lt 33.0) { $RecoveryBudgetState.expired = $true; throw 'recovery_publication_deadline' }
				return & $RecoveryTransport $Request
			}
			if (($Attempt.publicationDeadlineTicks - (& $ReadTicks)) / [double] $Attempt.monotonicFrequency -lt 33.0) { throw 'recovery_publication_deadline' }
			$null = Restore-InitialPreparationRouting -Runner $RecoveryRunner -Transport $BudgetedTransport
			if ((& $ReadTicks) -ge $Attempt.publicationDeadlineTicks) { throw 'recovery_publication_deadline' }
			$Result.state = 'routing_restored'; $Result.routingRestored = $true; $Result.recoveryRequired = $false; $Result.failureCode = $null
		} catch {
			$Result.failureCode = if ($RecoveryBudgetState.expired) { 'recovery_publication_deadline' }
				elseif ($_.Exception.Message -cmatch '^[a-z_]{1,80}$') { $_.Exception.Message } else { 'recovery_failed' }
		} finally {
			$Result.finishedTicks = & $ReadTicks
			$Bytes = [Text.Encoding]::UTF8.GetBytes(($Result | ConvertTo-Json -Depth 4 -Compress))
			if ($Bytes.Length -gt 4096) { throw 'recovery_evidence_limit' }
			$Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true)
		}
	} finally {
		if ($null -ne $Stream) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
	}
	return [pscustomobject] $Result
}
