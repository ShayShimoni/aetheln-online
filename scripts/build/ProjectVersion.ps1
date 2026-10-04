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

function Get-ProjectVersionIniLine([string] $IniPath) {
	# ParseLineExtended accepts CRLF, lone CR, and LF as line boundaries.
	return ([IO.File]::ReadAllText($IniPath, [Text.Encoding]::UTF8) -split '\r\n|\r|\n')
}

function Assert-NoProjectVersionOverride([string] $DefaultGame) {
	$DefaultGame = [IO.Path]::GetFullPath($DefaultGame)
	foreach ($Ini in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($DefaultGame)) -Recurse -File -Force | Where-Object { $_.Extension -eq '.ini' -and $_.FullName -ne $DefaultGame })) {
		foreach ($Line in (Get-ProjectVersionIniLine $Ini.FullName)) {
			# ParseLineExtended strips unquoted braces, including braces inside a
			# key. Do not approximate that grammar when excluding other ini files.
			if ($Line.Contains('{') -or $Line.Contains('}') -or (Test-ProjectVersionDeclaration $Line)) { throw 'project_version_override' }
		}
	}
}

function Read-ProjectVersion([string] $IniPath) {
	# The one ProjectVersion the engine bakes into both packages. This is a
	# line-oriented approximation of the engine's ini parser, so it errs on the
	# closed side: headers are matched after trailing whitespace is trimmed, as
	# the engine does, and anything it cannot place the way the engine would
	# (case variants, an array operator, a second line, another section, or a
	# line the engine joins through a trailing backslash or a {...} block, or
	# // comment syntax that changes header parsing) fails
	# closed. The release smoke evidence checks the version the packages log.
	if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw 'project_version_missing: Config/DefaultGame.ini does not exist.' }
	$Section = $null
	$Declarations = @()
	$HasUnsupportedSyntax = $false
	foreach ($Line in (Get-ProjectVersionIniLine $IniPath)) {
		$Trimmed = $Line.TrimEnd()
		if ($Trimmed.EndsWith('\') -or $Trimmed.Contains('{') -or $Trimmed.Contains('}') -or $Trimmed.Contains('//')) { $HasUnsupportedSyntax = $true }
		if ($Trimmed -cmatch '^\[(?<Name>.*)\]\z') { $Section = $Matches.Name; continue }
		if (Test-ProjectVersionDeclaration $Line) { $Declarations += [pscustomobject]@{ Section = $Section; Text = $Line } }
	}
	if ($Declarations.Count -eq 0) { throw 'project_version_missing: Config/DefaultGame.ini declares no ProjectVersion.' }
	if ($HasUnsupportedSyntax -or $Declarations.Count -ne 1 -or $Declarations[0].Section -cne '/Script/EngineSettings.GeneralProjectSettings' -or $Declarations[0].Text -cnotmatch ('^ProjectVersion=(?<Value>' + (Get-ProjectVersionPattern) + ')\z')) {
		throw 'project_version_invalid: Config/DefaultGame.ini must declare exactly one ProjectVersion=<SemVer without build metadata> in [/Script/EngineSettings.GeneralProjectSettings], with no joined lines or // syntax.'
	}
	$Value = $Matches.Value
	Assert-NoProjectVersionOverride $IniPath
	return $Value
}
