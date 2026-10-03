<#
.SYNOPSIS
Guards and records Issue #226 release packaging runs (TA-022).
.DESCRIPTION
-Mode Guard runs first on the hosted release-gates job. It refuses, red,
anything but an owner dispatch of refs/heads/release/v<ProjectVersion> in this
repository on run attempt 1 with a valid run number, and it refuses a
ProjectVersion declared in any other Config ini. On success it writes the
version, build number, and build version to the job summary.

-Mode Evidence runs on the engine runner after the release smoke phase. It
proves that the provenance in the durable handoff store belongs to this run and
release, and that the packaged server and both clients logged the same network
version line, then writes one closed, path-free record to -OutputPath. The
record is create-only and is written for a failure too.

Both modes read only the default GitHub and runner environment. Whatever
happens, each prints exactly one reason code to stdout and nothing else, so no
local path or runtime text reaches the public job log.
.EXAMPLE
powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Guard
.EXAMPLE
powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Evidence -OutputPath TestResults/release-evidence.json
#>
[CmdletBinding()]
param(
	[string] $Mode,
	[string] $RepositoryRoot,
	[string] $OutputPath
)

try {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	. (Join-Path $PSScriptRoot '..\build\ProjectVersion.ps1')
	$ReleaseOwner = 'ShayShimoni'
	$ReleaseRepository = 'ShayShimoni/aetheln-online'
	$ReleaseRefPattern = '^refs/heads/release/v(?<Version>' + (Get-ProjectVersionPattern) + ')\z'
	$BuildNumberPattern = '^[1-9][0-9]{0,9}\z'
	# The pinned engine logs "<Project> <ProjectVersion>, NetCL: <n>" plus its two
	# network custom versions, in this order, and the checksum of that string.
	$NetVersionPattern = '^AethelnOnline (?<Version>' + (Get-ProjectVersionPattern) + '), NetCL: (?:0|[1-9][0-9]{0,9}), EngineNetworkVersion: (?:0|[1-9][0-9]{0,9}), GameNetworkVersion: (?:0|[1-9][0-9]{0,9}) \(Checksum: (?<Checksum>0|[1-9][0-9]{0,9})\)\z'
	$CodePattern = '^(?<Code>[a-z][a-z0-9_]{0,63})(?::|\z)'

	function Get-ContextValue([string] $Name) {
		$Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
		if ($null -eq $Value) { return '' }
		return $Value
	}

	function Assert-Condition([bool] $Condition, [string] $Reason) {
		if (-not $Condition) { throw $Reason }
	}

	function Get-ReasonCode($ErrorRecord, [string] $Fallback) {
		$Match = [regex]::Match([string] $ErrorRecord.Exception.Message, $CodePattern)
		if ($Match.Success) { return $Match.Groups['Code'].Value }
		return $Fallback
	}

	function Get-JsonValue($Object, [string] $Path) {
		$Current = $Object
		foreach ($Name in $Path.Split('.')) {
			if ($Current -isnot [Management.Automation.PSCustomObject]) { return $null }
			$Property = $Current.PSObject.Properties[$Name]
			if ($null -eq $Property) { return $null }
			$Current = $Property.Value
		}
		return $Current
	}

	function Test-JsonInteger($Value) {
		return ($Value -is [int] -or $Value -is [long])
	}

	function Get-FileSha256([string] $Path) {
		return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	}

	function Read-JsonFile([string] $Path, [string] $Reason) {
		try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { throw $Reason }
	}

	function Test-IsWithin([string] $Candidate, [string] $Parent) {
		$ParentPrefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + '\'
		return ([IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/') + '\').StartsWith($ParentPrefix, [StringComparison]::OrdinalIgnoreCase)
	}

	function Test-IsReparsePoint([string] $Path) {
		return (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
	}

	function Assert-PathChainSafe([string] $Root, [string] $Leaf, [string] $Reason) {
		# The gate's own rule: every existing component from the approved root
		# down to the leaf is contained and is not a reparse point.
		$RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
		$Current = [IO.Path]::GetFullPath($Leaf)
		Assert-Condition (Test-IsWithin $Current $RootFull) $Reason
		while ($true) {
			if ((Test-Path -LiteralPath $Current) -and (Test-IsReparsePoint $Current)) { throw $Reason }
			if ($Current.TrimEnd('\', '/').Equals($RootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
			$Current = [IO.Path]::GetDirectoryName($Current)
			if ([string]::IsNullOrEmpty($Current)) { throw $Reason }
		}
	}

	function Resolve-ApprovedRoot([string] $Value, [string] $UnsetReason, [string] $InvalidReason) {
		# A local fixed-drive directory: no UNC, network, relative, or reparse root.
		if ([string]::IsNullOrWhiteSpace($Value)) { throw $UnsetReason }
		if ($Value -match '^[\\/]{2}' -or -not [IO.Path]::IsPathRooted($Value) -or -not (Test-Path -LiteralPath $Value -PathType Container)) { throw $InvalidReason }
		$Full = (Resolve-Path -LiteralPath $Value).Path
		if ($Full -notmatch '^[A-Za-z]:\\.') { throw $InvalidReason }
		if ((New-Object IO.DriveInfo ($Full.Substring(0, 1))).DriveType -ne [IO.DriveType]::Fixed) { throw $InvalidReason }
		if (Test-IsReparsePoint $Full) { throw $InvalidReason }
		return $Full
	}

	function Invoke-ReleaseGuard([string] $RootOverride) {
		Assert-Condition ((Get-ContextValue 'GITHUB_EVENT_NAME') -ceq 'workflow_dispatch') 'release_event_invalid'
		Assert-Condition ((Get-ContextValue 'GITHUB_REPOSITORY') -ceq $ReleaseRepository -and (Get-ContextValue 'GITHUB_REPOSITORY_OWNER') -ceq $ReleaseOwner) 'release_repository_invalid'
		Assert-Condition ((Get-ContextValue 'GITHUB_ACTOR') -ceq $ReleaseOwner -and (Get-ContextValue 'GITHUB_TRIGGERING_ACTOR') -ceq $ReleaseOwner) 'release_actor_invalid'
		Assert-Condition ((Get-ContextValue 'GITHUB_RUN_ATTEMPT') -ceq '1') 'release_attempt_invalid'
		$RefMatch = [regex]::Match((Get-ContextValue 'GITHUB_REF'), $ReleaseRefPattern)
		Assert-Condition $RefMatch.Success 'release_ref_invalid'
		$BuildNumber = Get-ContextValue 'GITHUB_RUN_NUMBER'
		Assert-Condition ($BuildNumber -cmatch $BuildNumberPattern) 'build_number_invalid'
		# The ref is checked before the version, so a dispatch of any other branch
		# is refused as a wrong ref whatever its Config holds.
		$Root = if ([string]::IsNullOrEmpty($RootOverride)) { Join-Path $PSScriptRoot '..\..' } else { $RootOverride }
		$DefaultGame = [IO.Path]::GetFullPath((Join-Path $Root 'Config\DefaultGame.ini'))
		$ProjectVersion = Read-ProjectVersion $DefaultGame
		# A platform or other ini override would let the client and server differ.
		foreach ($Ini in @(Get-ChildItem -LiteralPath (Join-Path $Root 'Config') -Recurse -File -Force | Where-Object { $_.Extension -eq '.ini' -and $_.FullName -ne $DefaultGame })) {
			foreach ($Line in [IO.File]::ReadAllLines($Ini.FullName)) {
				if (Test-ProjectVersionDeclaration $Line) { throw 'project_version_override' }
			}
		}
		Assert-Condition ($ProjectVersion -ceq $RefMatch.Groups['Version'].Value) 'project_version_branch_mismatch'
		$SummaryPath = Get-ContextValue 'GITHUB_STEP_SUMMARY'
		if ($SummaryPath.Length -gt 0) {
			$Summary = @('### Release packaging guard', '', ('- ProjectVersion: `{0}`' -f $ProjectVersion), ('- Build number: `{0}`' -f $BuildNumber), ('- Build version: `{0}+{1}`' -f $ProjectVersion, $BuildNumber), '') -join "`n"
			[IO.File]::AppendAllText($SummaryPath, $Summary, (New-Object Text.UTF8Encoding($false)))
		}
		return 'release_guard_passed'
	}

	function Complete-ReleaseEvidence($Record) {
		$Repository = Get-ContextValue 'GITHUB_REPOSITORY'
		$Ref = Get-ContextValue 'GITHUB_REF'
		$Revision = Get-ContextValue 'GITHUB_SHA'
		$RunId = Get-ContextValue 'GITHUB_RUN_ID'
		$RunNumber = Get-ContextValue 'GITHUB_RUN_NUMBER'
		$Job = Get-ContextValue 'GITHUB_JOB'
		$RefMatch = [regex]::Match($Ref, $ReleaseRefPattern)
		Assert-Condition ($Repository -ceq $ReleaseRepository -and $RefMatch.Success -and $Revision -cmatch '^[0-9a-f]{40}\z' -and $RunId -cmatch '^[1-9][0-9]{0,18}\z' -and (Get-ContextValue 'GITHUB_RUN_ATTEMPT') -ceq '1' -and $RunNumber -cmatch $BuildNumberPattern -and $Job -cmatch '^[a-z][a-z0-9-]{0,99}\z') 'release_context_invalid'
		$Record.repository = $Repository
		$Record.ref = $Ref
		$Record.sourceRevision = $Revision
		$Record.runId = $RunId
		$Record.runAttempt = 1
		$Record.runNumber = [long] $RunNumber

		$HandoffRoot = Resolve-ApprovedRoot -Value (Get-ContextValue 'AETHELN_HANDOFF_ROOT') -UnsetReason 'handoff_root_unset' -InvalidReason 'handoff_root_invalid'
		$RunnerTemp = Resolve-ApprovedRoot -Value (Get-ContextValue 'RUNNER_TEMP') -UnsetReason 'release_context_invalid' -InvalidReason 'smoke_logs_invalid'
		foreach ($Other in @($RunnerTemp, (Get-ContextValue 'GITHUB_WORKSPACE'))) {
			if ([string]::IsNullOrWhiteSpace($Other)) { continue }
			Assert-Condition (-not (Test-IsWithin $HandoffRoot $Other) -and -not (Test-IsWithin $Other $HandoffRoot)) 'handoff_root_invalid'
		}

		# Provenance: the gate's manifest binds it to this run, and its release
		# block binds it to this release and build number.
		$RunDirectory = [IO.Path]::Combine($HandoffRoot, $Repository.Split('/')[0], $Repository.Split('/')[1], ('run-{0}-attempt-1' -f $RunId))
		Assert-PathChainSafe -Root $HandoffRoot -Leaf $RunDirectory -Reason 'handoff_root_invalid'
		Assert-Condition (Test-Path -LiteralPath $RunDirectory -PathType Container) 'handoff_missing'
		$ManifestPath = Join-Path $RunDirectory 'manifest-provenance.json'
		$ProvenancePath = Join-Path $RunDirectory 'provenance\build-provenance.json'
		foreach ($Path in @($ManifestPath, $ProvenancePath)) {
			Assert-PathChainSafe -Root $HandoffRoot -Leaf $Path -Reason 'handoff_root_invalid'
			Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) 'handoff_missing'
		}
		$Manifest = Read-JsonFile $ManifestPath 'provenance_manifest_invalid'
		$Entries = @(@(Get-JsonValue $Manifest 'files') | Where-Object { [string] (Get-JsonValue $_ 'path') -ceq 'build-provenance.json' })
		Assert-Condition ([string] (Get-JsonValue $Manifest 'repository') -ceq $Repository -and [string] (Get-JsonValue $Manifest 'sourceRevision') -ceq $Revision -and [string] (Get-JsonValue $Manifest 'runId') -ceq $RunId -and [string] (Get-JsonValue $Manifest 'runAttempt') -ceq '1' -and [string] (Get-JsonValue $Manifest 'producingPhase') -ceq 'provenance' -and $Entries.Count -eq 1 -and [string] (Get-JsonValue $Entries[0] 'sha256') -cmatch '^[0-9a-f]{64}\z') 'provenance_manifest_invalid'
		$ProvenanceDigest = Get-FileSha256 $ProvenancePath
		Assert-Condition ($ProvenanceDigest -ceq [string] (Get-JsonValue $Entries[0] 'sha256')) 'provenance_digest_mismatch'
		$Provenance = Read-JsonFile $ProvenancePath 'provenance_invalid'
		$SchemaVersion = Get-JsonValue $Provenance 'schemaVersion'
		Assert-Condition ((Test-JsonInteger $SchemaVersion) -and $SchemaVersion -eq 2) 'provenance_invalid'
		$Record.provenance = [ordered]@{ sha256 = $ProvenanceDigest; schemaVersion = 2 }
		Assert-Condition ([string] (Get-JsonValue $Provenance 'source.revision') -ceq $Revision) 'provenance_revision_mismatch'
		$Release = Get-JsonValue $Provenance 'release'
		Assert-Condition ($Release -is [Management.Automation.PSCustomObject] -and (@($Release.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,projectVersion,buildNumber,buildVersion') 'provenance_release_invalid'
		$ProjectVersion = [string] $Release.projectVersion
		Assert-Condition ((Test-JsonInteger $Release.schemaVersion) -and $Release.schemaVersion -eq 1 -and $ProjectVersion -cmatch ('^' + (Get-ProjectVersionPattern) + '\z') -and (Test-JsonInteger $Release.buildNumber) -and [string] $Release.buildVersion -ceq ('{0}+{1}' -f $ProjectVersion, $Release.buildNumber)) 'provenance_release_invalid'
		Assert-Condition ([long] $Release.buildNumber -eq [long] $RunNumber) 'provenance_build_number_mismatch'
		Assert-Condition ($ProjectVersion -ceq $RefMatch.Groups['Version'].Value) 'project_version_branch_mismatch'
		$Record.projectVersion = $ProjectVersion
		$Record.buildNumber = [long] $RunNumber
		$Record.buildVersion = '{0}+{1}' -f $ProjectVersion, $RunNumber

		$Inventory = @(Get-JsonValue $Provenance 'artifacts.inventory')
		$Archives = [ordered]@{}
		foreach ($Kind in @(@{ Name = 'client'; Main = '(?:^|/)Binaries/Win64/AethelnOnlineClient\.exe\z' }, @{ Name = 'server'; Main = '(?:^|/)Binaries/Linux/AethelnOnlineServer\z' })) {
			$KindEntries = @($Inventory | Where-Object { [string] (Get-JsonValue $_ 'kind') -ceq $Kind.Name })
			$TotalBytes = [long] 0
			foreach ($Entry in $KindEntries) {
				$Size = Get-JsonValue $Entry 'sizeBytes'
				Assert-Condition ((Test-JsonInteger $Size) -and $Size -ge 0) 'provenance_inventory_invalid'
				$TotalBytes += [long] $Size
			}
			$Main = @($KindEntries | Where-Object { [string] (Get-JsonValue $_ 'path') -cmatch $Kind.Main })
			Assert-Condition ($Main.Count -eq 1) 'provenance_inventory_invalid'
			$MainPath = [string] (Get-JsonValue $Main[0] 'path')
			$MainDigest = [string] (Get-JsonValue $Main[0] 'sha256')
			Assert-Condition ($MainPath.Length -le 260 -and $MainPath -cmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*\z' -and $MainDigest -cmatch '^[0-9a-f]{64}\z') 'provenance_inventory_invalid'
			$Archives[$Kind.Name] = [ordered]@{ fileCount = $KindEntries.Count; totalBytes = $TotalBytes; mainExecutable = [ordered]@{ path = $MainPath; sha256 = $MainDigest } }
		}
		$Record.archives = $Archives

		# Smoke logs: the gate writes them under the job's runner.temp run root.
		$SmokeRoot = [IO.Path]::Combine($RunnerTemp, ('aetheln-engine-{0}-1-{1}' -f $RunId, $Job), 'logs', 'phase', 'packaged-smoke')
		Assert-PathChainSafe -Root $RunnerTemp -Leaf $SmokeRoot -Reason 'smoke_logs_invalid'
		Assert-Condition (Test-Path -LiteralPath $SmokeRoot -PathType Container) 'smoke_logs_missing'
		$Lines = [ordered]@{}
		foreach ($Log in @(@{ Key = 'server'; File = 'server.stdout.log' }, @{ Key = 'client1'; File = 'client-1.stdout.log' }, @{ Key = 'client2'; File = 'client-2.stdout.log' })) {
			$LogPath = Join-Path $SmokeRoot $Log.File
			Assert-PathChainSafe -Root $RunnerTemp -Leaf $LogPath -Reason 'smoke_logs_invalid'
			Assert-Condition (Test-Path -LiteralPath $LogPath -PathType Leaf) 'smoke_logs_missing'
			$Found = $null
			foreach ($Line in [IO.File]::ReadLines($LogPath)) {
				# Only checksum lines are candidates. Each must match the closed
				# grammar, so no free runtime text can reach the public record.
				$Marker = $Line.IndexOf('LogNetVersion: ', [StringComparison]::Ordinal)
				if ($Marker -lt 0 -or $Line.IndexOf('(Checksum:', [StringComparison]::Ordinal) -lt 0) { continue }
				$Body = $Line.Substring($Marker + 15).TrimEnd()
				Assert-Condition ($Line.Substring(0, $Marker) -cmatch '^(?:\[[0-9.:-]{1,32}\]\[ {0,3}[0-9]{1,10}\])?\z' -and $Body.Length -le 512 -and $Body -cmatch $NetVersionPattern) 'net_version_line_invalid'
				if ($null -eq $Found) { $Found = $Body } else { Assert-Condition ($Body -ceq $Found) 'net_version_mismatch' }
			}
			Assert-Condition ($null -ne $Found) 'net_version_missing'
			$Lines[$Log.Key] = $Found
		}
		Assert-Condition ($Lines.server -ceq $Lines.client1 -and $Lines.server -ceq $Lines.client2) 'net_version_mismatch'
		$NetVersion = [regex]::Match($Lines.server, $NetVersionPattern)
		Assert-Condition ($NetVersion.Groups['Version'].Value -ceq $ProjectVersion) 'net_version_project_mismatch'
		$Record.netVersion = [ordered]@{ server = $Lines.server; client1 = $Lines.client1; client2 = $Lines.client2; checksum = [long] $NetVersion.Groups['Checksum'].Value }

		# Raw smoke evidence holds local paths and an address, so only its digest
		# is recorded, after it proves the smoke passed.
		$SmokeEvidencePath = Join-Path $SmokeRoot 'smoke-evidence.jsonl'
		Assert-PathChainSafe -Root $RunnerTemp -Leaf $SmokeEvidencePath -Reason 'smoke_logs_invalid'
		Assert-Condition (Test-Path -LiteralPath $SmokeEvidencePath -PathType Leaf) 'smoke_evidence_missing'
		$SmokePassed = $false
		foreach ($Line in [IO.File]::ReadLines($SmokeEvidencePath)) {
			$Text = $Line.Trim([char[]] @([char] 0xFEFF, [char] 32, [char] 9))
			if ($Text.Length -eq 0) { continue }
			try { $SmokeEvent = $Text | ConvertFrom-Json } catch { throw 'smoke_evidence_invalid' }
			if ([string] (Get-JsonValue $SmokeEvent 'schema') -ceq 'aetheln.packaged-smoke.evidence/v1' -and [string] (Get-JsonValue $SmokeEvent 'event') -ceq 'smoke_passed') { $SmokePassed = $true }
		}
		Assert-Condition $SmokePassed 'smoke_not_passed'
		$Record.smokeEvidenceSha256 = Get-FileSha256 $SmokeEvidencePath
	}

	function Invoke-ReleaseEvidence([string] $OutputFile) {
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($OutputFile)) 'release_output_invalid'
		$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
		Assert-Condition (-not (Test-Path -LiteralPath $Output)) 'release_evidence_exists'
		$Record = [ordered]@{
			schema = 'aetheln.release-evidence/v1'; passed = $false; reason = $null
			repository = $null; ref = $null; sourceRevision = $null; runId = $null; runAttempt = $null; runNumber = $null
			projectVersion = $null; buildNumber = $null; buildVersion = $null
			provenance = $null; archives = $null; netVersion = $null; smokeEvidenceSha256 = $null
		}
		try {
			Complete-ReleaseEvidence $Record
			$Record.passed = $true
			$Record.reason = 'release_evidence_passed'
		} catch {
			$Record.reason = Get-ReasonCode $_ 'release_evidence_failed'
		}
		$Parent = Split-Path -Parent $Output
		if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { [void] (New-Item -ItemType Directory -Path $Parent -Force) }
		$Bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Depth 6))
		$Stream = [IO.File]::Open($Output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
		Assert-Condition $Record.passed $Record.reason
		return $Record.reason
	}

	if ($Mode -ceq 'Guard') { $Outcome = Invoke-ReleaseGuard -RootOverride $RepositoryRoot }
	elseif ($Mode -ceq 'Evidence') { $Outcome = Invoke-ReleaseEvidence -OutputFile $OutputPath }
	else { throw 'release_mode_invalid' }
	Write-Output $Outcome
	exit 0
} catch {
	# Catch-all: only a fixed reason code ever leaves this script.
	$Code = 'release_packaging_failed'
	$CodeMatch = [regex]::Match([string] $_.Exception.Message, '^(?<Code>[a-z][a-z0-9_]{0,63})(?::|\z)')
	if ($CodeMatch.Success) { $Code = $CodeMatch.Groups['Code'].Value }
	Write-Output $Code
	exit 1
}
