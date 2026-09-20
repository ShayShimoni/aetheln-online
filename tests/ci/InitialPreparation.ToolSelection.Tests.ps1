[CmdletBinding()]
param([string] $ActualLogPath = '', [string] $ActualLogSha256 = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.ToolSelection.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Tool selection parser missing' }
. $Module
function Assert-SelectionFixture {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnSelection-' + [guid]::NewGuid().ToString('N'))
$Compiler = 'C:/Program Files/VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
$Resource = 'C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/rc.exe'
$Marker = 'Using Visual Studio 2022 14.44.35207 toolchain (C:\Program Files\VS\VC\Tools\MSVC\14.44.35207) and Windows 10.0.26100.0 SDK (C:\Program Files (x86)\Windows Kits\10).'
$ObservedMarker = $Marker.Replace('2022 14.44.35207 toolchain', '2022 14.44.35228 toolchain')
$IspcMarker = 'Using ISPC compiler (D:\UnrealEngine\UE-5.8.1-source\Engine\Source\ThirdParty\Intel\ISPC\bin\Windows\ispc.exe)'
$Attempt = New-InitialPreparationAttempt -Repository 'ShayShimoni/aetheln-online' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ('selection-' + [guid]::NewGuid().ToString('N'))
$SelectionClock = @{ expired = $false; deadline = $Attempt.publicationDeadlineTicks }
function Get-InitialPreparationTick {
	if ($SelectionClock.expired) { return [long] $SelectionClock.deadline }
	return [Diagnostics.Stopwatch]::GetTimestamp()
}
foreach ($Mode in @('actual_product', 'auxiliary_ispc', 'observed', 'no_actions', 'utf8_boundary', 'missing', 'first_no_actions', 'duplicate', 'contradictory', 'other_compiler', 'wrong_directory', 'wrong_sdk', 'wrong_sdk_directory', 'unsupported_product', 'malformed_product', 'changed_repeat', 'malformed_ispc', 'other_auxiliary_path', 'ispc_only', 'ispc_with_other_compiler', 'mixed_no_actions', 'positive_actions', 'ten_digit_actions', 'max_int_actions', 'overflow_actions', 'long_actions', 'malformed_actions', 'negative_actions', 'native_failed', 'infrastructure_failed', 'cleanup_failed', 'source_changed', 'skipped', 'oversized_line', 'invalid_utf8', 'oversized_file', 'progress_failure', 'deadline', 'mid_parse_deadline')) {
	$SelectionClock.expired = $false
	$Root = Join-Path $FixtureRoot $Mode
	$Builds = @(for ($Index = 0; $Index -lt 6; $Index++) {
		[pscustomobject]@{ ordinal = $Index + 1; pair = [int][Math]::Floor($Index / 2) + 1;
			target = $(if ($Index % 2 -eq 0) { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' });
			platform = $(if ($Index % 2 -eq 0) { 'Win64' } else { 'Linux' }); configuration = 'Development';
			targetRevision = $Attempt.targetRevision; inputDigest = ('c' * 64); nativeExitCode = 0; cleanupVerified = $true }
	})
	if ($Mode -ceq 'native_failed') { $Builds[5].nativeExitCode = 7 }
	if ($Mode -ceq 'infrastructure_failed') { $Builds[0] | Add-Member -NotePropertyName infrastructureFailure -NotePropertyValue failed }
	if ($Mode -ceq 'cleanup_failed') { $Builds[0].cleanupVerified = $false }
	if ($Mode -ceq 'source_changed') { $Builds[2].inputDigest = 'd' * 64 }
	if ($Mode -ceq 'skipped') { $Builds[2] | Add-Member -NotePropertyName status -NotePropertyValue skipped }
	for ($Pair = 1; $Pair -le 3; $Pair++) {
		$Directory = Join-Path $Root ('builds/build-' + $Pair + '-Win64')
		$null = New-Item -ItemType Directory -Path $Directory -Force
		$Text = $ObservedMarker + "`r`n"
		if ($Mode -ceq 'auxiliary_ispc') { $Text = $IspcMarker + "`r`n" + $Text }
		if ($Mode -ceq 'changed_repeat' -and $Pair -eq 2) { $Text = $Marker + "`r`n" }
		if ($Mode -ceq 'no_actions' -and $Pair -gt 1) { $Text = "Target is up to date`r`n" }
		if ($Pair -eq 1) {
			switch ($Mode) {
				missing { $Text = "Completed without tool information`r`n" }
				first_no_actions { $Text = "Target is up to date`r`n" }
				duplicate { $Text += $ObservedMarker + "`r`n" }
				contradictory { $Text += $ObservedMarker.Replace('14.44.35228 toolchain', '14.43.00000 toolchain') + "`r`n" }
				other_compiler { $Text = $ObservedMarker.Replace('Visual Studio 2022', 'Clang') + "`r`n" }
				wrong_directory { $Text = $ObservedMarker.Replace('\VS\', '\OtherVS\') + "`r`n" }
				wrong_sdk { $Text = $ObservedMarker.Replace('10.0.26100.0 SDK', '10.0.22621.0 SDK') + "`r`n" }
				wrong_sdk_directory { $Text = $ObservedMarker.Replace('Windows Kits\10', 'Other Kits\10') + "`r`n" }
				unsupported_product { $Text = $Marker + "`r`n" }
				malformed_product { $Text = $ObservedMarker.Replace('14.44.35228 toolchain', '14.44.35228suffix toolchain') + "`r`n" }
				malformed_ispc { $Text = $IspcMarker + ' unexpected suffix' + "`r`n" + $Text }
				other_auxiliary_path { $Text = $IspcMarker.Replace('ispc.exe', 'clang.exe') + "`r`n" + $Text }
				ispc_only { $Text = $IspcMarker + "`r`n" }
				ispc_with_other_compiler { $Text = $IspcMarker + "`r`n" + $ObservedMarker.Replace('Visual Studio 2022', 'Clang') + "`r`n" }
				mixed_no_actions { $Text += "Target is up to date`r`n" }
				oversized_line { $Text = ('x' * 16385) + "`r`n" + $ObservedMarker }
			}
		}
		$ActionCases = @{ positive_actions = '1'; ten_digit_actions = '1000000000'; max_int_actions = '2147483647';
			overflow_actions = '2147483648'; long_actions = '10000000000'; malformed_actions = 'unknown'; negative_actions = '-1' }
		if ($ActionCases.ContainsKey($Mode) -and $Pair -eq 2) { $Text = "Target is up to date`r`nUsing Unreal Build Accelerator executor to run " + $ActionCases[$Mode] + " action(s)`r`n" }
		if ($Mode -ceq 'utf8_boundary') { $Text = (('x' * 1000) + "`r`n") * 65 + ('y' * 405) + [char]0x03b1 + "`r`n" + $Text }
		$Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
		if ($Mode -ceq 'invalid_utf8' -and $Pair -eq 1) { $Bytes = [byte[]]@(0xff, 0xff) }
		$Stream = [IO.File]::Open((Join-Path $Directory 'build.log'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
		try {
			$Stream.Write($Bytes, 0, $Bytes.Length)
			if ($Mode -ceq 'oversized_file' -and $Pair -eq 1) { $Stream.SetLength(16777217) }
		} finally { $Stream.Dispose() }
	}
	$Failure = $null; $Result = $null
	$SelectionProgressCalls = @{ n = 0 }
	$SelectionProgress = {
		$SelectionProgressCalls.n++
		if ($Mode -ceq 'progress_failure') { throw 'fixture_progress_failure' }
		if ($Mode -ceq 'mid_parse_deadline' -and $SelectionProgressCalls.n -eq 3) { $SelectionClock.expired = $true }
	}
	if ($Mode -ceq 'deadline') { $SelectionClock.expired = $true }
	try { $Result = Get-InitialPreparationToolSelection -Attempt $Attempt -Builds $Builds -EvidenceRoot $Root -CompilerPath $Compiler -ResourceCompilerPath $Resource -InputDigest ('c' * 64) -OnProgress $SelectionProgress } catch { $Failure = $_.Exception.Message }
	if ($Mode -in @('actual_product', 'auxiliary_ispc', 'observed', 'no_actions', 'utf8_boundary')) {
		Assert-SelectionFixture -Condition ($null -eq $Failure -and $Result.verified -is [bool] -and $Result.verified -and -not $Result.baselineVerified -and $Result.records.Count -eq 3 -and $Result.digest -cmatch '^[0-9a-f]{64}$') -Message ('Valid selection rejected: ' + $Failure)
		if ($Mode -ceq 'no_actions') {
			Assert-SelectionFixture -Condition ($Result.records[1].basis -ceq 'no_actions_same_input' -and $Result.records[1].anchorOrdinal -eq 1 -and -not $Result.records[1].toolchainObserved) -Message 'No-action repeat misrepresented'
			Assert-SelectionFixture -Condition ($null -eq $Result.records[1].compilerVersion -and $null -eq $Result.records[2].compilerVersion) -Message 'No-action repeat invented a compiler product observation'
		}
		Assert-SelectionFixture -Condition ($Result.scope -ceq 'windows_primary_tool_selection' -and $Result.records[0].selectionDirectoryVersion -ceq '14.44.35207' -and $Result.records[0].compilerVersion -ceq '14.44.35228') -Message 'Compiler selection-directory and observed product versions were conflated'
		$Hash = (Get-FileHash -LiteralPath (Join-Path $Root 'builds/build-1-Win64/build.log') -Algorithm SHA256).Hash.ToLowerInvariant()
		Assert-SelectionFixture -Condition ($Result.records[0].logSha256 -ceq $Hash) -Message 'Raw log digest mismatch'
	} else {
		Assert-SelectionFixture -Condition ($null -ne $Failure -and $null -eq $Result) -Message ('Unsafe selection accepted: ' + $Mode)
		$ExpectedFailure = switch ($Mode) {
			{ $_ -in @('wrong_directory', 'wrong_sdk_directory') } { 'tool_selection_mismatch' }
			'duplicate' { 'tool_selection_duplicate' }
			'ispc_only' { 'tool_selection_unproven' }
			{ $_ -in @('unsupported_product', 'malformed_product', 'changed_repeat', 'malformed_ispc', 'other_auxiliary_path', 'ispc_with_other_compiler', 'wrong_sdk', 'other_compiler', 'contradictory') } { 'tool_selection_contradictory' }
			default { $null }
		}
		if ($null -ne $ExpectedFailure) { Assert-SelectionFixture -Condition ($Failure.Contains($ExpectedFailure)) -Message ('Wrong rejection for ' + $Mode + ': ' + $Failure) }
	}
}
if ($ActualLogPath -or $ActualLogSha256) {
	if (-not $ActualLogPath -or $ActualLogSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Actual log replay requires an exact path and SHA256' }
	# Replay only the raw completed log parser: no manufactured real build records,
	# no six-invocation acceptance, and no engine/binary access or execution.
	$ActualStream = [IO.File]::Open($ActualLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try { $ActualParsed = [Aetheln.ToolSelectionLog]::Parse($ActualStream, [Action] {}) } finally { $ActualStream.Dispose() }
	Assert-SelectionFixture -Condition ($ActualParsed.Sha256 -ceq $ActualLogSha256 -and $ActualParsed.SelectionCount -eq 1 -and $ActualParsed.CompilerVersion -ceq '14.44.35228' -and $ActualParsed.PositiveActions -and $ActualParsed.NoActionsCount -eq 0) -Message 'Exact completed raw log replay did not prove one primary tool selection'
	Write-Output ('PASS: actual raw-log parser replay only; sha256=' + $ActualParsed.Sha256 + '; bytes=' + $ActualParsed.Bytes + '; no baseline claim')
}
Write-Output "PASS: Windows tool selection fixtures; retained $FixtureRoot"
