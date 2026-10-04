[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'BuildNumber', Justification = 'Consumed by a nested function.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DevelopRevision', Justification = 'Consumed by a nested function.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectId', Justification = 'Consumed by a nested function.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Repository', Justification = 'Consumed by a nested function.')]
param(
	[string] $Stage = 'Verify',
	[string] $Version,
	[string] $BranchName,
	[string] $BuildNumber,
	[string] $DevelopRevision,
	[string] $ReleaseRevision,
	[string] $ClientLogPath,
	[string] $ServerLogPath,
	[string] $ProvenancePath,
	[string] $FixturePath,
	[string] $ProjectId = 'PVT_kwHOBB63qs4Bedeu',
	[string] $Repository = 'ShayShimoni/aetheln-online',
	[switch] $Json,
	# Collects what PowerShell would reject as an unknown parameter, so it exits 2 like any usage error.
	[Parameter(ValueFromRemainingArguments)][string[]] $UnknownArguments
)

# Issue #225 release-cut verification. It only reads: the Cut and Tag stages are
# not implemented, so the release flow in docs/delivery-workflow.md stays manual.
#
# Verify proves a cut of -Version is safe. It reads git (nothing is fetched or
# written) and the project board, pull requests, and develop CI through the
# locally authenticated `gh`, or a normalized snapshot from -FixturePath for
# offline tests, and reports each violation as `<code> <subject> <detail>`.
# VerifyPackage reads the packaged client and server logs and the provenance
# JSON and compares them with -Version and the release head (-ReleaseRevision,
# default the tip of the release branch on origin). Exit 0 when clean, 1 on any
# violation, and 2 on a usage error or when the environment cannot be read; an
# exit-2 message is `Release cut error [usage|environment]: <detail>` on stderr
# and never carries a local path.
#
# Snapshot shape: { tags: [name], remoteBranches: [name], developRevision,
# developRun: { status, conclusion } or null, defaultGameIni, otherConfigIni:
# [text of every other tracked Config/**/*.ini at that revision], items: [{ number,
# type: Issue or PullRequest, status, release }], openPullRequests: [{ number,
# title, linkedIssues: [n] }], mergedPullRequests: [{ number, title,
# baseRefName, mergeCommit, linkedIssues: [n], inCut }], board: { items,
# pullRequests } }. `board` is handed to Test-BoardIntegrity.ps1 as its own
# snapshot; a live run lets that script read the board itself. `inCut` is
# `git merge-base --is-ancestor <mergeCommit> <develop revision>`. A PR links an
# issue through a closing reference or a `#<n>` in its title, as in
# Test-BoardIntegrity.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'build/ProjectVersion.ps1')

# Control characters and the Unicode line and paragraph separators.
$UnsafeCharacters = "[\u0000-\u001f\u007f-\u009f$([char] 0x2028)$([char] 0x2029)]"

$Branch = if ($BranchName) { $BranchName } else { "release/v$Version" }

# Details never echo raw control characters, which may come from a parameter.
function Format-Safe([string] $Text) {
	return [regex]::Replace($Text, $UnsafeCharacters, [Text.RegularExpressions.MatchEvaluator] { param($Match) '\u{0:x4}' -f [int] [char] $Match.Value })
}

# Exit-2 text must carry no local path: this drops the roots the script itself
# touches and then any drive-letter, UNC, or rooted multi-segment path in it.
function Hide-LocalPath([string] $Text) {
	foreach ($Root in @($RepositoryRoot, [IO.Path]::GetTempPath(), $HOME)) {
		$Trimmed = ([string] $Root).TrimEnd('\', '/')
		if ($Trimmed) { $Text = [regex]::Replace($Text, [regex]::Escape($Trimmed) + '[^\s''"<>|]*', '<path>', 'IgnoreCase') }
	}
	return [regex]::Replace($Text, '(?:(?<![A-Za-z0-9])[A-Za-z]:[\\/]|\\\\|(?<![\w/.:-])/(?=[\w.-]+/))[^\s''"<>|]*', '<path>')
}

# A fixture or provenance file is parsed as JSON; the error names the file, not its folder.
function Read-JsonFile([string] $Path, [string] $Role) {
	try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
	catch { throw "cannot read the $Role '$(Split-Path -Leaf $Path)' as JSON" }
}

function Get-OptionalText($Object, [string] $Name) {
	$Property = $Object.PSObject.Properties[$Name]
	if ($null -eq $Property -or $null -eq $Property.Value) { return '' }
	return [string] $Property.Value
}

function Get-OptionalList($Object, [string] $Name) {
	$Property = $Object.PSObject.Properties[$Name]
	if ($null -eq $Property -or $null -eq $Property.Value) { return @() }
	return @($Property.Value | Where-Object { $null -ne $_ })
}

# SemVer 2.0.0 core plus optional pre-release; build metadata is not accepted.
$SemVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?\z'

function ConvertTo-SemVer([string] $Text) {
	$Match = [regex]::Match($Text, $SemVerPattern)
	if (-not $Match.Success) { return $null }
	$Pre = @(if ($Match.Groups[4].Success) { $Match.Groups[4].Value -split '\.' })
	return [pscustomobject]@{ Core = @($Match.Groups[1].Value, $Match.Groups[2].Value, $Match.Groups[3].Value); Pre = $Pre }
}

# Digit strings are numeric identifiers without leading zeros, so length then
# ordinal text order is numeric order without an integer width limit.
function Compare-Numeric([string] $Left, [string] $Right) {
	if ($Left.Length -ne $Right.Length) { return [Math]::Sign($Left.Length - $Right.Length) }
	return [Math]::Sign([string]::CompareOrdinal($Left, $Right))
}

# SemVer 2.0.0 precedence: -1, 0, or 1.
function Compare-SemVer($Left, $Right) {
	for ($Part = 0; $Part -lt 3; $Part++) {
		$Order = Compare-Numeric $Left.Core[$Part] $Right.Core[$Part]
		if ($Order -ne 0) { return $Order }
	}
	if ($Left.Pre.Count -eq 0 -and $Right.Pre.Count -eq 0) { return 0 }
	if ($Left.Pre.Count -eq 0) { return 1 }
	if ($Right.Pre.Count -eq 0) { return -1 }
	$Shared = [Math]::Min($Left.Pre.Count, $Right.Pre.Count)
	for ($Index = 0; $Index -lt $Shared; $Index++) {
		$A = $Left.Pre[$Index]
		$B = $Right.Pre[$Index]
		$ANumeric = $A -cmatch '^[0-9]+\z'
		$BNumeric = $B -cmatch '^[0-9]+\z'
		if ($ANumeric -and $BNumeric) { $Order = Compare-Numeric $A $B }
		elseif ($ANumeric) { $Order = -1 }
		elseif ($BNumeric) { $Order = 1 }
		else { $Order = [Math]::Sign([string]::CompareOrdinal($A, $B)) }
		if ($Order -ne 0) { return $Order }
	}
	return [Math]::Sign($Left.Pre.Count - $Right.Pre.Count)
}

function Get-LinkedIssue($Pull) {
	return @(@(Get-OptionalList $Pull 'linkedIssues') + @([regex]::Matches((Get-OptionalText $Pull 'title'), '#([0-9]{1,9})') | ForEach-Object { $_.Groups[1].Value }) |
		Where-Object { $null -ne $_ } | ForEach-Object { [int] $_ } | Sort-Object -Unique)
}

$BoardChecker = Join-Path $PSScriptRoot 'Test-BoardIntegrity.ps1'

# The board rules live in Test-BoardIntegrity.ps1; this runs it and returns its
# violations. A fixture run hands it the snapshot's `board`, a live run lets it
# read the board itself.
function Get-BoardIntegrityViolation($Snapshot) {
	$Arguments = @{ Json = $true }
	$Temporary = $null
	if ($FixturePath) {
		$Temporary = Join-Path ([IO.Path]::GetTempPath()) ('AethelnReleaseCutBoard-' + [guid]::NewGuid().ToString('N') + '.json')
		[IO.File]::WriteAllText($Temporary, (ConvertTo-Json -InputObject $Snapshot.board -Depth 8))
		$Arguments.FixturePath = $Temporary
	}
	else {
		$Arguments.ProjectId = $ProjectId
		$Arguments.Repository = $Repository
	}
	try {
		$Output = @(& $BoardChecker @Arguments | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		if ($Temporary) { Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue }
	}
	if ($ExitCode -notin 0, 1) { throw "Test-BoardIntegrity.ps1 exited $ExitCode." }
	return @(($Output -join "`n" | ConvertFrom-Json).violations)
}

function Test-Word16([string] $Text) {
	if ($Text -cnotmatch '^[0-9]+\z') { return $false }
	$Significant = $Text.TrimStart('0')
	return $Significant.Length -le 4 -or ($Significant.Length -eq 5 -and [int] $Significant -le 65535)
}

# Each consumer of ProjectVersion is checked against the stamped form
# <version>+<build number> (the build number is the largest 16-bit value when
# omitted) or its numeric form MAJOR.MINOR.PATCH.<build number>. Evidence paths
# are relative to the pinned Unreal Engine source tree or this repository.
function Get-ConsumerResult {
	$Build = if ($BuildNumber) { $BuildNumber } else { '65535' }
	$Stamped = "$Version+$Build"
	$Numeric = "$(($Version -split '-', 2)[0]).$Build"

	$Reason = ''
	if ($Stamped.Length -gt 96) { $Reason = "is $($Stamped.Length) characters; the limit is 96" }
	elseif ($Stamped -match $UnsafeCharacters) { $Reason = 'contains a control or line-separator character' }
	$Identity = [ordered]@{
		name = 'build-identity'; form = $Stamped; status = $(if ($Reason) { 'rejected' } else { 'accepted' })
		reason = $(if ($Reason) { "stamped form '$(Format-Safe $Stamped)' $Reason" } else { '' })
		evidence = 'Source/GameNet/Public/AethelnObservability.h: IsSafeIdentifier allows at most 96 UTF-16 code units and no U+0000-U+001F, U+007F-U+009F, U+2028, or U+2029.'
	}

	# The build number is the workflow run number, so digits only; anything else
	# (4.1, 1.2.3) would make the numeric form more than four parts.
	$Reason = ''
	$Parts = @($Numeric -split '\.')
	if ($Build -cnotmatch '^[1-9][0-9]{0,9}\z') { $Reason = "build number '$(Format-Safe $Build)' is not a whole number of 1 to 10 digits with no leading zero" }
	elseif ($Parts.Count -ne 4) { $Reason = "numeric form '$(Format-Safe $Numeric)' has $($Parts.Count) parts, not 4" }
	else {
		foreach ($Part in $Parts) {
			if (-not (Test-Word16 $Part)) { $Reason = "numeric form '$(Format-Safe $Numeric)' has part '$(Format-Safe $Part)', which is not a whole number from 0 to 65535"; break }
		}
	}
	$Windows = [ordered]@{
		name = 'windows-file-version'; form = $Numeric; status = $(if ($Reason) { 'rejected' } else { 'unverified' }); reason = $Reason
		evidence = 'The numeric form is the rule in docs/delivery-workflow.md: the Windows VERSIONINFO resource (FILEVERSION and PRODUCTVERSION) stores the version as four 16-bit words, so it has exactly four parts, each 0 to 65535. The pinned engine does not read ProjectVersion for the executable resource: Engine/Build/Windows/Resources/Default.rc2, the default resource file added by Engine/Source/Programs/UnrealBuildTool/Configuration/UEBuildBinary.cs, sets FILEVERSION from ENGINE_MAJOR_VERSION, ENGINE_MINOR_VERSION and ENGINE_PATCH_VERSION, and FileVersion and ProductVersion from BUILD_VERSION or ENGINE_VERSION_STRING (Engine/Source/Programs/UnrealBuildTool/Platform/Windows/VCToolChain.cs defines BUILD_VERSION only when bSetResourceVersions is on). Unverified on a packaged executable.'
	}

	return @(
		[ordered]@{
			name = 'network-version'; form = $Stamped; status = 'accepted'; reason = ''
			evidence = 'Engine/Source/Runtime/Core/Private/Misc/NetworkVersion.cpp: FNetworkVersion::SetProjectVersion accepts any non-empty string, and GetLocalNetworkVersion hashes the lowercased "<ProjectName> <ProjectVersion>, NetCL: ..." text with CRC32, so client and server must carry the identical string. Engine/Source/Runtime/Engine/Private/UnrealEngine.cpp passes the ProjectVersion project setting to SetProjectVersion.'
		},
		$Identity,
		$Windows,
		[ordered]@{
			name = 'appx-manifest'; form = $Stamped; status = 'not-applicable'; reason = ''
			evidence = 'Engine/Source/Programs/UnrealBuildTool/Platform/Windows/AppXManifestGeneratorBase.cs GetIdentityVersionNumber reads PackageVersion or ProjectVersion only when it writes a UWP or MSIX manifest, and ValidatePackageVersion does not reject: it strips everything but digits and dots and clamps each part to 65535, so 1.0.0-alpha.1+412 would silently become 1.0.0.1412. The Win64 desktop client and the Linux dedicated server are not AppX packages.'
		}
	)
}

function Get-VerifyViolation {
	param([Parameter(Mandatory)] $Snapshot)

	$Violations = New-Object Collections.Generic.List[object]
	function Add-Violation([string] $Code, [string] $Subject, [string] $Detail) {
		$Violations.Add([pscustomobject][ordered]@{ code = $Code; subject = $Subject; detail = $Detail })
	}

	# Version: grammar, then precedence against the existing v* tags.
	$Parsed = ConvertTo-SemVer $Version
	if ($null -eq $Parsed) {
		Add-Violation -Code 'release_version_invalid' -Subject 'version' -Detail "'$(Format-Safe $Version)' is not SemVer 2.0 MAJOR.MINOR.PATCH with an optional pre-release and no build metadata"
	}
	$Tag = "v$Version"
	$Tags = @(Get-OptionalList $Snapshot 'tags')
	if ($null -ne $Parsed) {
		# The exact tag is reported by release_tag_exists; any other tag at or above this version blocks it.
		$Highest = $null
		foreach ($Existing in $Tags) {
			if ($Existing -ceq $Tag -or $Existing -cnotmatch '^v') { continue }
			$ExistingVersion = ConvertTo-SemVer $Existing.Substring(1)
			if ($null -eq $ExistingVersion -or (Compare-SemVer $ExistingVersion $Parsed) -lt 0) { continue }
			if ($null -eq $Highest -or (Compare-SemVer $ExistingVersion $Highest.Parsed) -gt 0) { $Highest = [pscustomobject]@{ Name = $Existing; Parsed = $ExistingVersion } }
		}
		if ($null -ne $Highest) { Add-Violation -Code 'release_version_not_newer' -Subject 'version' -Detail "'$Version' is not newer than existing tag '$($Highest.Name)'" }
	}
	if ($Tags -ccontains $Tag) { Add-Violation -Code 'release_tag_exists' -Subject 'tag' -Detail "$Tag already exists on origin" }
	if (@(Get-OptionalList $Snapshot 'remoteBranches') -ccontains $Branch) { Add-Violation -Code 'release_branch_exists' -Subject 'branch' -Detail "$Branch already exists on origin" }

	# develop must be green at the exact revision being cut.
	$Run = $Snapshot.PSObject.Properties['developRun']
	if ($null -eq $Run -or $null -eq $Run.Value -or (Get-OptionalText $Run.Value 'status') -cne 'completed' -or (Get-OptionalText $Run.Value 'conclusion') -cne 'success') {
		Add-Violation -Code 'release_develop_not_green' -Subject 'develop' -Detail "no successful Prototype quality gates push run for $(Get-OptionalText $Snapshot 'developRevision')"
	}

	foreach ($Finding in (Get-BoardIntegrityViolation $Snapshot)) {
		Add-Violation -Code 'release_board_integrity_failed' -Subject "#$($Finding.issue)" -Detail "$($Finding.rule): $($Finding.detail)"
	}

	# The cut adds ProjectVersion, so it may be missing here, but only before the
	# cut: an existing value must be the planned one and must pass the same
	# shared reader as packaging, including the override scan of other Config ini.
	try {
		$Existing = Read-ProjectVersionConfig -DefaultGameContent (Get-OptionalText $Snapshot 'defaultGameIni') -OtherIniContents ([string[]] @(Get-OptionalList $Snapshot 'otherConfigIni')) -AllowMissing
		if ($null -ne $Existing -and $Existing -cne $Version) {
			Add-Violation -Code 'release_project_version_conflict' -Subject 'Config/DefaultGame.ini' -Detail "already holds ProjectVersion=$Existing, not $Version"
		}
	}
	catch {
		$Reason = ($_.Exception.Message -split ':')[0]
		if ($Reason -cnotin 'project_version_invalid', 'project_version_override') { throw }
		$Subject = if ($Reason -ceq 'project_version_override') { 'Config' } else { 'Config/DefaultGame.ini' }
		Add-Violation -Code 'release_project_version_conflict' -Subject $Subject -Detail $Reason
	}

	# Scope is exactly the issues in Done. A Done PR card is listed and left out of the move.
	$Done = @(Get-OptionalList $Snapshot 'items' | Where-Object { (Get-OptionalText $_ 'status') -ceq 'Done' })
	$Included = @($Done | Where-Object { (Get-OptionalText $_ 'type') -ceq 'Issue' } | ForEach-Object { [int] $_.number })
	if ($Included.Count -eq 0) { Add-Violation -Code 'release_scope_empty' -Subject 'scope' -Detail 'no issue is in Done, so the release has no content' }
	foreach ($Item in $Done) {
		$Number = [int] $Item.number
		if ((Get-OptionalText $Item 'type') -cne 'Issue') { Add-Violation -Code 'release_item_not_issue' -Subject "#$Number" -Detail 'is a pull request card in Done; it is left out of the release scope' }
		if (-not [string]::IsNullOrWhiteSpace((Get-OptionalText $Item 'release'))) { Add-Violation -Code 'release_item_release_field_set' -Subject "#$Number" -Detail "is in Done with Release already set to '$(Get-OptionalText $Item 'release')'" }
	}
	foreach ($Pull in @(Get-OptionalList $Snapshot 'openPullRequests')) {
		foreach ($Number in (Get-LinkedIssue $Pull)) {
			if ($Included -contains $Number) { Add-Violation -Code 'release_item_open_pr' -Subject "#$Number" -Detail "has open PR #$($Pull.number)" }
		}
	}
	foreach ($Pull in @(Get-OptionalList $Snapshot 'mergedPullRequests')) {
		if ((Get-OptionalText $Pull 'baseRefName') -cnotin @('develop', 'main') -or (Get-OptionalText $Pull 'inCut') -ceq 'True') { continue }
		foreach ($Number in (Get-LinkedIssue $Pull)) {
			if ($Included -contains $Number) { Add-Violation -Code 'release_item_work_not_in_cut' -Subject "#$Number" -Detail "merged PR #$($Pull.number) at $(Get-OptionalText $Pull 'mergeCommit') is not an ancestor of the cut revision" }
		}
	}

	$Consumers = @()
	if ($null -ne $Parsed) {
		$Consumers = @(Get-ConsumerResult)
		foreach ($Consumer in ($Consumers | Where-Object { $_.status -ceq 'rejected' })) { Add-Violation -Code 'release_version_consumer_rejects' -Subject $Consumer.name -Detail $Consumer.reason }
	}

	return [pscustomobject]@{ violations = $Violations.ToArray(); consumers = $Consumers }
}

# The last LogNetVersion line wins: the engine logs again whenever the checksum
# is recalculated, for example after SetProjectVersion.
function Get-NetVersion([string] $Path) {
	$Pattern = 'LogNetVersion:\s+\S+\s+(?<version>\S+),\s+NetCL:.*\(Checksum:\s*(?<checksum>[0-9]+)\)'
	$Last = $null
	try {
		foreach ($Line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path).Path)) {
			$Match = [regex]::Match($Line, $Pattern)
			if ($Match.Success) { $Last = [pscustomobject]@{ version = $Match.Groups['version'].Value; checksum = $Match.Groups['checksum'].Value } }
		}
	}
	catch { throw "cannot read the log '$(Split-Path -Leaf $Path)'" }
	return $Last
}

# VerifyPackage proves the packaged client and server accepted the version
# string, hashed it to the same network checksum, and came from the release head.
function Get-PackageViolation {
	$Head = if ($ReleaseRevision) { $ReleaseRevision } else { Get-RemoteRevision "refs/heads/$Branch" }
	if (-not $Head) { throw "$(Format-Safe $Branch) is not on origin; pass -ReleaseRevision." }

	$Violations = New-Object Collections.Generic.List[object]
	function Add-Violation([string] $Code, [string] $Subject, [string] $Detail) {
		$Violations.Add([pscustomobject][ordered]@{ code = $Code; subject = $Subject; detail = $Detail })
	}

	# The committed ProjectVersion carries no build metadata; a stamped package may add +<build number>.
	$Metadata = if ($BuildNumber) { [regex]::Escape($BuildNumber) } else { '[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*' }
	$Expected = '^' + [regex]::Escape($Version) + '(?:\+' + $Metadata + ')?\z'
	$Seen = @{}
	foreach ($Role in @(@{ Name = 'client'; Path = $ClientLogPath }, @{ Name = 'server'; Path = $ServerLogPath })) {
		$Found = Get-NetVersion $Role.Path
		if ($null -eq $Found) { Add-Violation -Code 'release_package_version_mismatch' -Subject $Role.Name -Detail "$(Split-Path -Leaf $Role.Path) has no LogNetVersion line with a checksum"; continue }
		if ($Found.version -cnotmatch $Expected) { Add-Violation -Code 'release_package_version_mismatch' -Subject $Role.Name -Detail "LogNetVersion shows '$(Format-Safe $Found.version)', not $(Format-Safe $Version)"; continue }
		$Seen[$Role.Name] = $Found
	}
	if ($Seen.Count -eq 2) {
		if ($Seen['client'].version -cne $Seen['server'].version) { Add-Violation -Code 'release_package_version_mismatch' -Subject 'client-server' -Detail "client shows '$($Seen['client'].version)' but server shows '$($Seen['server'].version)'" }
		elseif ($Seen['client'].checksum -cne $Seen['server'].checksum) { Add-Violation -Code 'release_package_version_mismatch' -Subject 'client-server' -Detail "client checksum $($Seen['client'].checksum) differs from server checksum $($Seen['server'].checksum)" }
	}

	# Today's build-provenance.json (schemaVersion 2) records source.revision; the packaging stage records use sourceRevision.
	$Provenance = Read-JsonFile $ProvenancePath 'provenance file'
	$Recorded = Get-OptionalText $Provenance 'sourceRevision'
	$Source = $Provenance.PSObject.Properties['source']
	if (-not $Recorded -and $Source -and $Source.Value) { $Recorded = Get-OptionalText $Source.Value 'revision' }
	if (-not $Recorded) { Add-Violation -Code 'release_package_revision_mismatch' -Subject 'provenance' -Detail 'records no sourceRevision or source.revision' }
	elseif (-not [string]::Equals($Recorded, $Head, [StringComparison]::OrdinalIgnoreCase)) { Add-Violation -Code 'release_package_revision_mismatch' -Subject 'provenance' -Detail "records '$(Format-Safe $Recorded)', not the release head $Head" }

	return $Violations.ToArray()
}

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Invoke-Native {
	param([Parameter(Mandatory)][string] $Command, [Parameter(Mandatory)][string[]] $Arguments)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& $Command @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	return [pscustomobject]@{ ExitCode = $ExitCode; Output = $Output }
}

# A failure names only the command and its subcommand: the arguments can carry
# the repository root (`git -C <root>`) or a long query.
function Invoke-Checked([string] $Command, [string[]] $Arguments, [string] $Subcommand = $Arguments[0]) {
	$Result = Invoke-Native -Command $Command -Arguments $Arguments
	if ($Result.ExitCode -ne 0) { throw "$Command $Subcommand failed: $($Result.Output -join ' ')" }
	return $Result.Output
}

function Invoke-Git([string[]] $Arguments) { return Invoke-Checked -Command 'git' -Arguments (@('-C', $RepositoryRoot) + $Arguments) -Subcommand $Arguments[0] }

# Windows PowerShell 5.1 emits a parsed JSON array as one pipeline object, so
# the array is assigned before it is enumerated.
function Get-GhJsonList([string[]] $Arguments) {
	$Parsed = (Invoke-Checked 'gh' $Arguments) -join "`n" | ConvertFrom-Json
	return @($Parsed | Where-Object { $null -ne $_ })
}

function Invoke-GhGraphQl {
	param(
		[Parameter(Mandatory)][string] $Query,
		[Parameter(Mandatory)][hashtable] $Variables
	)

	$Arguments = @('api', 'graphql', '-f', ('query=' + $Query))
	foreach ($Name in $Variables.Keys) {
		if ($null -ne $Variables[$Name]) { $Arguments += @('-f', ($Name + '=' + $Variables[$Name])) }
	}
	return ((Invoke-Checked 'gh' $Arguments) -join "`n" | ConvertFrom-Json)
}

function Get-RemoteRevision([string] $Ref) {
	$Line = @(Invoke-Git @('ls-remote', 'origin', $Ref)) | Select-Object -First 1
	if (-not $Line) { return $null }
	return ($Line -split '\s+')[0]
}

# Reads everything Verify needs through git and the locally authenticated `gh`.
# Nothing is written, and nothing is fetched: a revision missing from this clone
# is an environment error.
function Get-LiveSnapshot {
	# Queries contain no string literals so native argument passing stays safe.
	$ItemQuery = 'query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { content { __typename ... on Issue { number repository { nameWithOwner } } ... on PullRequest { number repository { nameWithOwner } } } fieldValues(first: 30) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } } ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } } } } } } } } }'

	$Develop = if ($DevelopRevision) { $DevelopRevision.ToLowerInvariant() } else { Get-RemoteRevision 'refs/heads/develop' }
	if ($Develop -cnotmatch '^[0-9a-f]{40}\z') { throw 'The develop revision must be a 40-character commit SHA.' }
	if ((Invoke-Native -Command 'git' -Arguments @('-C', $RepositoryRoot, 'cat-file', '-e', ($Develop + '^{commit}'))).ExitCode -ne 0) { throw "Revision $Develop is not in this clone; run git fetch origin first." }

	$Tags = @(Invoke-Git @('ls-remote', '--tags', 'origin', 'refs/tags/v*') | ForEach-Object { if ($_ -match 'refs/tags/(\S+?)(?:\^\{\})?$') { $Matches[1] } } | Sort-Object -Unique -CaseSensitive)
	$RemoteBranches = if (@(Invoke-Git @('ls-remote', '--heads', 'origin', "refs/heads/$Branch")).Count -gt 0) { @($Branch) } else { @() }
	$Runs = @(Get-GhJsonList @('run', 'list', '-R', $Repository, '--workflow', 'prototype-quality-gates.yml', '--branch', 'develop', '--event', 'push', '--commit', $Develop, '--limit', '20', '--json', 'status,conclusion'))
	$Run = $Runs | Where-Object { $_.conclusion -ceq 'success' } | Select-Object -First 1
	if (-not $Run) { $Run = $Runs | Select-Object -First 1 }
	$Config = Get-ProjectVersionGitConfig -RepositoryRoot $RepositoryRoot -Revision $Develop

	$Items = New-Object Collections.Generic.List[object]
	$Cursor = $null
	do {
		$Page = (Invoke-GhGraphQl -Query $ItemQuery -Variables @{ id = $ProjectId; after = $Cursor }).data.node.items
		foreach ($Node in $Page.nodes) {
			if ($null -eq $Node.content -or $Node.content.__typename -cnotin @('Issue', 'PullRequest') -or $Node.content.repository.nameWithOwner -cne $Repository) { continue }
			$Fields = @{}
			foreach ($Value in $Node.fieldValues.nodes) {
				$FieldProperty = $Value.PSObject.Properties['field']
				if ($null -eq $FieldProperty -or $null -eq $FieldProperty.Value) { continue }
				$Fields[$FieldProperty.Value.name] = if ($Value.PSObject.Properties['name']) { $Value.name } else { $Value.text }
			}
			$Items.Add([pscustomobject][ordered]@{ number = $Node.content.number; type = $Node.content.__typename; status = $Fields['Status']; release = $Fields['Release'] })
		}
		$Cursor = $Page.pageInfo.endCursor
	} while ($Page.pageInfo.hasNextPage)

	$Open = @(Get-GhJsonList @('pr', 'list', '-R', $Repository, '--state', 'open', '--limit', '200', '--json', 'number,title,closingIssuesReferences') | ForEach-Object {
		[pscustomobject][ordered]@{ number = $_.number; title = $_.title; linkedIssues = @($_.closingIssuesReferences | ForEach-Object { $_.number }) }
	})

	# Ancestry is resolved only for merged PRs that link a Done issue on a branch that feeds a release.
	$DoneIssues = @($Items | Where-Object { $_.type -ceq 'Issue' -and $_.status -ceq 'Done' } | ForEach-Object { [int] $_.number })
	$Merged = New-Object Collections.Generic.List[object]
	foreach ($Pull in @(Get-GhJsonList @('pr', 'list', '-R', $Repository, '--state', 'merged', '--limit', '1000', '--json', 'number,title,baseRefName,mergeCommit,closingIssuesReferences'))) {
		$Commit = if ($null -ne $Pull.mergeCommit) { [string] $Pull.mergeCommit.oid } else { '' }
		$Entry = [pscustomobject][ordered]@{
			number = $Pull.number; title = $Pull.title; baseRefName = $Pull.baseRefName; mergeCommit = $Commit
			linkedIssues = @($Pull.closingIssuesReferences | ForEach-Object { $_.number }); inCut = $null
		}
		if ($Commit -and $Pull.baseRefName -cin @('develop', 'main') -and @(Get-LinkedIssue $Entry | Where-Object { $DoneIssues -contains $_ }).Count -gt 0) {
			$Ancestry = Invoke-Native -Command 'git' -Arguments @('-C', $RepositoryRoot, 'merge-base', '--is-ancestor', $Commit, $Develop)
			if ($Ancestry.ExitCode -notin 0, 1) { throw "git merge-base failed for PR #$($Pull.number) at $Commit; run git fetch origin first: $($Ancestry.Output -join ' ')" }
			$Entry.inCut = ($Ancestry.ExitCode -eq 0)
		}
		$Merged.Add($Entry)
	}

	return [pscustomobject]@{
		tags = $Tags; remoteBranches = $RemoteBranches; developRevision = $Develop; developRun = $Run; defaultGameIni = $Config.defaultGameIni; otherConfigIni = $Config.otherConfigIni
		items = $Items.ToArray(); openPullRequests = $Open; mergedPullRequests = $Merged.ToArray()
	}
}

$ErrorKind = 'usage'
try {
	# Usage errors exit 2 too: exit 1 is reserved for violations, and PowerShell
	# itself exits 1 on a parameter binding error, so the checks live here.
	if ($UnknownArguments) { throw "unknown argument '$(Format-Safe ($UnknownArguments -join ' '))'" }
	if ($Stage -cnotin 'Verify', 'VerifyPackage') { throw "-Stage must be Verify or VerifyPackage, not '$(Format-Safe $Stage)'" }
	if ([string]::IsNullOrWhiteSpace($Version)) { throw '-Version is required' }
	if ($ReleaseRevision) {
		$ReleaseRevision = $ReleaseRevision.ToLowerInvariant()
		if ($ReleaseRevision -cnotmatch '^[0-9a-f]{40}\z') { throw '-ReleaseRevision must be a 40-character commit SHA' }
	}
	if ($Stage -ceq 'VerifyPackage' -and -not ($ClientLogPath -and $ServerLogPath -and $ProvenancePath)) { throw 'VerifyPackage needs -ClientLogPath, -ServerLogPath, and -ProvenancePath' }
	$ErrorKind = 'environment'

	if ($Stage -ceq 'Verify') {
		$Snapshot = if ($FixturePath) { Read-JsonFile $FixturePath 'fixture' } else { Get-LiveSnapshot }
		$Result = Get-VerifyViolation -Snapshot $Snapshot
		$Violations = @($Result.violations)
		$Consumers = @($Result.consumers)
	}
	else {
		$Violations = @(Get-PackageViolation)
		$Consumers = @()
	}
}
catch {
	[Console]::Error.WriteLine("Release cut error [$ErrorKind]: $(Format-Safe (Hide-LocalPath $_.Exception.Message))")
	exit 2
}

if ($Json) {
	Write-Output (ConvertTo-Json -InputObject ([ordered]@{ stage = $Stage; version = $Version; count = $Violations.Count; violations = $Violations; consumers = $Consumers }) -Depth 5)
}
else {
	foreach ($Violation in $Violations) { Write-Output "$($Violation.code) $($Violation.subject) $($Violation.detail)" }
	Write-Output "Release cut ${Stage}: $($Violations.Count) violation(s)."
}
if ($Violations.Count -gt 0) { exit 1 }
exit 0
