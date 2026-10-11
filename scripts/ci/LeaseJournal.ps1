# The one whole-journal check for the engine host lease journal. EngineRunnerHostLease.ps1 and
# InitialPreparation.Core.ps1 both write that file and both dot-source this definition, so what one
# writer refuses the other refuses too. Definitions only; nothing runs when dot-sourced.
function Assert-LeaseJournalText {
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Journal)
	try {
		if (-not $Journal.EndsWith("`n") -or $Journal.Contains('\')) { throw 'lease_owner_ambiguous' }
		$Held = $null
		$Seen = @{}
		foreach ($Line in @($Journal.Split([char] 10) | Where-Object { $_.Length -gt 0 })) {
			$Record = $Line | ConvertFrom-Json
			$Fields = @('schemaVersion', 'state', 'leaseId', 'attemptId', 'cleanupVerified')
			if ($Record.state -ceq 'held') { $Fields = @('schemaVersion', 'state', 'leaseId', 'attemptId', 'ownerPid', 'ownerStartUtc') }
			$Keys = [regex]::Matches($Line, '"([^"\\]+)"\s*:')
			if ($Keys.Count -ne $Fields.Count -or @($Record.PSObject.Properties).Count -ne $Fields.Count) { throw 'lease_owner_ambiguous' }
			foreach ($Field in $Fields) {
				if (@($Keys | Where-Object { $_.Groups[1].Value -ceq $Field }).Count -ne 1 -or $Record.PSObject.Properties.Name -cnotcontains $Field) { throw 'lease_owner_ambiguous' }
			}
			if ($Record.schemaVersion -isnot [int] -or $Record.schemaVersion -ne 1 -or
				$Record.leaseId -isnot [string] -or $Record.leaseId -cnotmatch '^[a-f0-9]{32}$' -or
				$Record.attemptId -isnot [string] -or $Record.attemptId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'lease_owner_ambiguous' }
			if ($Record.state -ceq 'held') {
				$Start = [DateTime]::MinValue
				if ($null -ne $Held -or $Seen.ContainsKey($Record.leaseId) -or $Record.ownerPid -isnot [int] -or $Record.ownerPid -le 0 -or
					$Record.ownerStartUtc -isnot [string] -or -not [DateTime]::TryParseExact($Record.ownerStartUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $Start) -or $Start.Kind -ne [DateTimeKind]::Utc) { throw 'lease_owner_ambiguous' }
				$Held = $Record
				$Seen[$Record.leaseId] = $true
			} elseif ($Record.state -ceq 'released') {
				if ($null -eq $Held -or $Record.leaseId -cne $Held.leaseId -or $Record.attemptId -cne $Held.attemptId -or
					$Record.cleanupVerified -isnot [bool] -or -not $Record.cleanupVerified) { throw 'lease_owner_ambiguous' }
				$Held = $null
			} else { throw 'lease_owner_ambiguous' }
		}
		if ($Seen.Count -eq 0 -or $null -ne $Held) { throw 'lease_owner_ambiguous' }
	} catch { throw 'lease_owner_ambiguous' }
}
