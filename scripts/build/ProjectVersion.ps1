# Issue #226: the shared ProjectVersion rules used by build provenance and the
# release-packaging guard. Dot-source this file; it only defines functions.

function Get-ProjectVersionPattern {
	# SemVer 2.0 core plus an optional pre-release, with no build metadata.
	$Identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
	return '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-' + $Identifier + '(?:\.' + $Identifier + ')*)?'
}

function Test-ProjectVersionDeclaration([string] $Line) {
	# Any spelling the engine's case-insensitive ini reader could take as a
	# ProjectVersion key, including case variants and array operators.
	return ($Line -match '^\s*~?\s*[-+.!@*^]?\s*ProjectVersion\s*=')
}

function Get-ProjectVersionConfigLine([string] $Content) {
	# ParseLineExtended accepts CRLF, lone CR, and LF as line boundaries.
	return ($Content -split '\r\n|\r|\n')
}

function Assert-NoProjectVersionConfigOverride([string[]] $Contents) {
	foreach ($Content in $Contents) {
		if ($Content.IndexOf([char]0) -ge 0) { throw 'project_version_override' }
		foreach ($Line in (Get-ProjectVersionConfigLine $Content)) {
			# ParseLineExtended strips unquoted braces, including braces inside a
			# key, and joins escaped newlines with spaces. A split key/equals pair
			# can become ProjectVersion =... after joining. Refuse unsupported
			# continuation syntax rather than overlooking an alternate declaration.
			if ($Line.Contains('{') -or $Line.Contains('}') -or $Line.TrimEnd().EndsWith('\') -or (Test-ProjectVersionDeclaration $Line)) { throw 'project_version_override' }
		}
	}
}

function Read-ProjectVersionConfig([string] $DefaultGameContent, [string[]] $OtherIniContents = @(), [switch] $AllowMissing) {
	# Pure text entry point for callers holding a nominated Git revision. Only
	# the pre-cut verifier may opt into absence; overrides are still refused.
	# FParse::LineExtended stops at NUL; never accept a later declaration that
	# the engine would not read, or silently treat truncated text as pre-cut.
	if ($DefaultGameContent.IndexOf([char]0) -ge 0) { throw 'project_version_invalid: Config/DefaultGame.ini contains NUL.' }
	Assert-NoProjectVersionConfigOverride $OtherIniContents
	# The one ProjectVersion the engine bakes into both packages. This is a
	# line-oriented approximation of the engine's ini parser, so it errs on the
	# closed side: headers are matched after trailing whitespace is trimmed, as
	# the engine does, and anything it cannot place the way the engine would
	# (case variants, an array operator, a second line, another section, or a
	# line the engine joins through a trailing backslash or a {...} block, or
	# // comment syntax that changes header parsing) fails
	# closed. The release smoke evidence checks the version the packages log.
	$Section = $null
	$Declarations = @()
	$HasUnsupportedSyntax = $false
	foreach ($Line in (Get-ProjectVersionConfigLine $DefaultGameContent)) {
		$Trimmed = $Line.TrimEnd()
		if ($Trimmed.EndsWith('\') -or $Trimmed.Contains('{') -or $Trimmed.Contains('}') -or $Trimmed.Contains('//')) { $HasUnsupportedSyntax = $true }
		if ($Trimmed -cmatch '^\[(?<Name>.*)\]\z') { $Section = $Matches.Name; continue }
		if (Test-ProjectVersionDeclaration $Line) { $Declarations += [pscustomobject]@{ Section = $Section; Text = $Line } }
	}
	if ($HasUnsupportedSyntax) { throw 'project_version_invalid: Config/DefaultGame.ini contains unsupported joined lines, braces or // syntax.' }
	if ($Declarations.Count -eq 0) {
		if ($AllowMissing) { return $null }
		throw 'project_version_missing: Config/DefaultGame.ini declares no ProjectVersion.'
	}
	if ($Declarations.Count -ne 1 -or $Declarations[0].Section -cne '/Script/EngineSettings.GeneralProjectSettings' -or $Declarations[0].Text -cnotmatch ('^ProjectVersion=(?<Value>' + (Get-ProjectVersionPattern) + ')\z')) {
		throw 'project_version_invalid: Config/DefaultGame.ini must declare exactly one ProjectVersion=<SemVer without build metadata> in [/Script/EngineSettings.GeneralProjectSettings], with no joined lines or // syntax.'
	}
	return $Matches.Value
}

function Get-ProjectVersionGitConfig([string] $RepositoryRoot, [string] $Revision) {
	# The Config ini text tracked at one commit, read from Git objects only: the
	# worktree, Saved, user and engine config are never consulted. Any failed
	# enumeration or blob read throws; messages carry no local path.
	function Invoke-ConfigGit([string[]] $Arguments) {
		$PreviousPreference = $ErrorActionPreference
		$ErrorActionPreference = 'Continue'
		try {
			$Output = @(& git -C $RepositoryRoot @Arguments 2>$null)
			$ExitCode = $LASTEXITCODE
		}
		finally {
			$ErrorActionPreference = $PreviousPreference
		}
		if ($ExitCode -ne 0) { throw "git $($Arguments[0]) failed reading Config at $Revision." }
		return ($Output -join "`n")
	}
	$Paths = @((Invoke-ConfigGit @('ls-tree', '-r', '-z', '--name-only', $Revision, '--', 'Config')) -split [char]0 | Where-Object { $_ -match '\.ini\z' -and $_ -cne 'Config/DefaultGame.ini' })
	return [pscustomobject]@{
		defaultGameIni = Invoke-ConfigGit @('show', "${Revision}:Config/DefaultGame.ini")
		otherConfigIni = [string[]] @(foreach ($Path in $Paths) { Invoke-ConfigGit @('show', "${Revision}:$Path") })
	}
}

function Read-ProjectVersion([string] $IniPath) {
	# Packaging and provenance remain strict disk callers. They cannot opt into
	# a missing version; both use exactly the same text/override rules as Git.
	if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw 'project_version_missing: Config/DefaultGame.ini does not exist.' }
	$DefaultGame = [IO.Path]::GetFullPath($IniPath)
	$OtherContents = [string[]] @(foreach ($Ini in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($DefaultGame)) -Recurse -File -Force | Where-Object { $_.Extension -eq '.ini' -and $_.FullName -ne $DefaultGame })) {
		[IO.File]::ReadAllText($Ini.FullName, [Text.Encoding]::UTF8)
	})
	return (Read-ProjectVersionConfig -DefaultGameContent ([IO.File]::ReadAllText($DefaultGame, [Text.Encoding]::UTF8)) -OtherIniContents $OtherContents)
}
