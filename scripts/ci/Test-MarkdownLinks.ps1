[CmdletBinding()]
param(
	[string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
	$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-Git {
	param([Parameter(Mandatory)][string[]] $Arguments)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = & git -C $RepositoryRoot @Arguments 2>&1
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	if ($ExitCode -ne 0) {
		throw "git $($Arguments -join ' ') failed: $($Output -join [Environment]::NewLine)"
	}
	return @($Output | ForEach-Object { "$_" })
}

function Get-AnchorSlug {
	param([Parameter(Mandatory)][string] $HeadingText)

	# GitHub-style slug: lowercase, drop characters outside [a-z0-9 _-], spaces to hyphens.
	$Slug = $HeadingText.Trim().ToLowerInvariant()
	$Slug = $Slug -replace '[^a-z0-9 _\-]', ''
	return ($Slug -replace ' ', '-')
}

function Get-HeadingSlugs {
	param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)

	$Slugs = @{}
	$InFence = $false
	foreach ($Line in $Lines) {
		if ($Line -match '^\s*(```|~~~)') {
			$InFence = -not $InFence
			continue
		}
		if ($InFence) {
			continue
		}
		if ($Line -match '^(#{1,6})\s+(.+?)\s*$') {
			$Slug = Get-AnchorSlug -HeadingText $Matches[2]
			if ($Slugs.ContainsKey($Slug)) {
				# GitHub disambiguates repeated headings with a numeric suffix.
				$Slugs[$Slug] = $Slugs[$Slug] + 1
				$Slugs["$Slug-$($Slugs[$Slug] - 1)"] = 1
			}
			else {
				$Slugs[$Slug] = 1
			}
		}
	}
	return $Slugs
}

$HeadingCache = @{}

function Get-HeadingSlugsForFile {
	param([Parameter(Mandatory)][string] $FullPath)

	if (-not $HeadingCache.ContainsKey($FullPath)) {
		$Lines = @(Get-Content -LiteralPath $FullPath -Encoding UTF8)
		$HeadingCache[$FullPath] = Get-HeadingSlugs -Lines $Lines
	}
	return $HeadingCache[$FullPath]
}

$LinkPattern = [regex]'\]\(<?([^)<>\s]+)>?\)'
$Violations = @()
$MarkdownFiles = @(Invoke-Git -Arguments @('ls-files', '--', '*.md'))

foreach ($RelativePath in $MarkdownFiles) {
	$FullPath = Join-Path $RepositoryRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $FullPath)) {
		$Violations += "${RelativePath}: tracked markdown file is missing from the working tree."
		continue
	}
	$Lines = @(Get-Content -LiteralPath $FullPath -Encoding UTF8)
	$Directory = Split-Path -Parent $FullPath
	$InFence = $false
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		$Line = $Lines[$Index]
		$LineNumber = $Index + 1
		if ($Line -match '^\s*(```|~~~)') {
			$InFence = -not $InFence
			continue
		}
		if ($InFence) {
			continue
		}
		foreach ($Match in $LinkPattern.Matches($Line)) {
			$Target = $Match.Groups[1].Value
			if ($Target -match '^(https?:|mailto:)') {
				continue
			}
			$PathPart = $Target
			$Anchor = $null
			$HashIndex = $Target.IndexOf('#')
			if ($HashIndex -ge 0) {
				$PathPart = $Target.Substring(0, $HashIndex)
				$Anchor = $Target.Substring($HashIndex + 1)
			}
			if ($PathPart -eq '') {
				$TargetFullPath = $FullPath
			}
			else {
				$DecodedPath = [uri]::UnescapeDataString($PathPart)
				$TargetFullPath = [IO.Path]::GetFullPath((Join-Path $Directory ($DecodedPath -replace '/', [IO.Path]::DirectorySeparatorChar)))
				if (-not (Test-Path -LiteralPath $TargetFullPath)) {
					$Violations += "${RelativePath}:$LineNumber -> $Target (target path does not exist)"
					continue
				}
			}
			if ($null -ne $Anchor -and $TargetFullPath -like '*.md') {
				$Slugs = Get-HeadingSlugsForFile -FullPath $TargetFullPath
				if (-not $Slugs.ContainsKey($Anchor.ToLowerInvariant())) {
					$Violations += "${RelativePath}:$LineNumber -> $Target (no heading produces anchor '$Anchor')"
				}
			}
		}
	}
}

if ($Violations.Count -gt 0) {
	throw "Markdown link violations:`n$($Violations -join "`n")"
}

Write-Output 'Markdown link checks passed.'
