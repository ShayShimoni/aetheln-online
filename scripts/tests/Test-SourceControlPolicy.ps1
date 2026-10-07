[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $RepositoryRoot

try {
	function Invoke-Git {
		param([Parameter(Mandatory)][string[]] $Arguments)

		$Output = & git @Arguments 2>&1
		if ($LASTEXITCODE -ne 0) {
			throw "git $($Arguments -join ' ') failed: $($Output -join [Environment]::NewLine)"
		}
		return @($Output)
	}

	function Get-AttributeTable {
		param([Parameter(Mandatory)][string] $Path)

		$Result = @{}
		$Lines = Invoke-Git -Arguments @('check-attr', 'filter', 'diff', 'merge', 'text', 'eol', 'lockable', '--', $Path)
		foreach ($Line in $Lines) {
			if ($Line -match '^.+?: ([^:]+): (.+)$') {
				$Result[$Matches[1]] = $Matches[2]
			}
		}
		return $Result
	}

	function Assert-Equal {
		param(
			[Parameter(Mandatory)] $Actual,
			[Parameter(Mandatory)] $Expected,
			[Parameter(Mandatory)][string] $Message
		)

		if ($Actual -ne $Expected) {
			throw "$Message Expected '$Expected', got '$Actual'."
		}
	}

	$LfsExtensions = @(
		'uasset', 'umap', 'psd', 'psb', 'blend', 'fbx', 'png', 'jpg', 'jpeg',
		'tga', 'tif', 'tiff', 'exr', 'hdr', 'dds', 'wav', 'flac', 'ogg', 'mp3',
		'mp4', 'mov', 'webm', 'ttf', 'otf'
	)

	foreach ($Extension in $LfsExtensions) {
		$Path = "PolicyProbe/asset.$Extension"
		$Attributes = Get-AttributeTable -Path $Path
		foreach ($Attribute in @('filter', 'diff', 'merge')) {
			Assert-Equal -Actual $Attributes[$Attribute] -Expected 'lfs' -Message "$Path $Attribute mismatch."
		}
		Assert-Equal -Actual $Attributes['text'] -Expected 'unset' -Message "$Path text mismatch."
		Assert-Equal -Actual $Attributes['lockable'] -Expected 'set' -Message "$Path lockable mismatch."
	}

	$HistoricalRoadmap = 'docs/research/mmorpg-development-roadmap.png'
	$ExpectedRoadmapHash = '359cabc4dbeda76ab251ac01e3936c011ed5a111169d0986b754e53ff4db42dd'
	$ActualRoadmapHash = (Get-FileHash -LiteralPath $HistoricalRoadmap -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-Equal -Actual $ActualRoadmapHash -Expected $ExpectedRoadmapHash -Message 'Historical roadmap PNG SHA-256 mismatch.'
	$HistoricalAttributes = Get-AttributeTable -Path $HistoricalRoadmap
	foreach ($Attribute in @('filter', 'diff', 'merge')) {
		Assert-Equal -Actual $HistoricalAttributes[$Attribute] -Expected 'unspecified' -Message "Historical roadmap PNG $Attribute must remain unspecified."
	}
	Assert-Equal -Actual $HistoricalAttributes['text'] -Expected 'unset' -Message 'Historical roadmap PNG text mismatch.'
	Assert-Equal -Actual $HistoricalAttributes['lockable'] -Expected 'unset' -Message 'Historical roadmap PNG must not be lockable.'

	$TextMatrix = @(
		@{ Path = 'Source/PolicyProbe.h'; Eol = 'lf' },
		@{ Path = 'Source/PolicyProbe.hpp'; Eol = 'lf' },
		@{ Path = 'Source/PolicyProbe.c'; Eol = 'lf' },
		@{ Path = 'Source/PolicyProbe.cpp'; Eol = 'lf' },
		@{ Path = 'docs/policy-probe.md'; Eol = 'lf' },
		@{ Path = 'Config/policy-probe.json'; Eol = 'lf' },
		@{ Path = 'Config/policy-probe.ini'; Eol = 'lf' },
		@{ Path = 'Generated/PolicyProbe.sln'; Eol = 'crlf' },
		@{ Path = 'Generated/PolicyProbe.slnx'; Eol = 'crlf' }
	)

	foreach ($Case in $TextMatrix) {
		$Attributes = Get-AttributeTable -Path $Case.Path
		Assert-Equal -Actual $Attributes['text'] -Expected 'set' -Message "$($Case.Path) text mismatch."
		Assert-Equal -Actual $Attributes['eol'] -Expected $Case.Eol -Message "$($Case.Path) EOL mismatch."
		Assert-Equal -Actual $Attributes['filter'] -Expected 'unspecified' -Message "$($Case.Path) must not use LFS."
		Assert-Equal -Actual $Attributes['lockable'] -Expected 'unspecified' -Message "$($Case.Path) must not be lockable."
	}

	foreach ($Path in @(
		'Content/Maps/__ExternalActors__/A/B/Actor.uasset',
		'Content/Maps/__ExternalObjects__/A/B/Object.uasset'
	)) {
		$Attributes = Get-AttributeTable -Path $Path
		foreach ($Attribute in @('filter', 'diff', 'merge')) {
			Assert-Equal -Actual $Attributes[$Attribute] -Expected 'lfs' -Message "$Path $Attribute mismatch."
		}
		Assert-Equal -Actual $Attributes['text'] -Expected 'unset' -Message "$Path text mismatch."
		Assert-Equal -Actual $Attributes['lockable'] -Expected 'unset' -Message "$Path must be exempt from mandatory locks."
	}

	$IgnoredPaths = @(
		'Binaries/PolicyProbe.dll',
		'Generated/PolicyProbe.sln',
		'Generated/PolicyProbe.slnx',
		'local/signing-material/release.pem',
		'local/signing-materials/release.key',
		'local/service-account/account.json',
		'local/service-accounts/account.json',
		'local/release.p12',
		'local/release.pfx',
		'local/release.jks',
		'local/release.keystore',
		'local/release.mobileprovision',
		'local/game-service-account.json',
		'local/game_service_account.json',
		'terraform.tfstate',
		'local/x.tfstate.backup',
		'.terraform/terraform.tfstate',
		'local/.terraform/providers/provider.bin'
	)

	foreach ($Path in $IgnoredPaths) {
		& git check-ignore --quiet --no-index -- $Path
		if ($LASTEXITCODE -ne 0) {
			throw "$Path must be ignored."
		}
	}

	foreach ($Path in @('service-account.redacted.example.json', 'service_account.redacted.example.json')) {
		& git check-ignore --quiet --no-index -- $Path
		if ($LASTEXITCODE -eq 0) {
			throw "$Path must remain eligible for source control."
		}
	}

	$ProhibitedTrackedPatterns = @(
		'*.pem', '*.key', '*.p12', '*.pfx', '*.jks', '*.keystore',
		'*.mobileprovision', '*service-account*.json', '*service_account*.json',
		'*.tfstate', '*.tfstate.*'
	)
	$TrackedViolations = @()
	foreach ($Pattern in $ProhibitedTrackedPatterns) {
		$TrackedViolations += @(Invoke-Git -Arguments @('ls-files', '--', $Pattern))
	}
	$TrackedViolations += @(Invoke-Git -Arguments @('ls-files', '--', ':(glob)**/signing-material/**', ':(glob)**/signing-materials/**', ':(glob)**/service-account/**', ':(glob)**/service-accounts/**', ':(glob)**/.terraform/**'))
	$TrackedViolations = @($TrackedViolations | Where-Object {
		$_ -and $_ -notmatch '(^|/)(service-account|service_account)\.redacted\.example\.json$'
	} | Sort-Object -Unique)
	if ($TrackedViolations.Count -gt 0) {
		throw "Prohibited sensitive-pattern paths are tracked: $($TrackedViolations -join ', ')"
	}

	$StarterMap = 'Content/Maps/StarterMap.umap'
	$ExpectedHash = '2a2b755b0feee3035b6c84fcd1eacebb67505d9344e66d0fb578b7804044b49a'
	$ActualHash = (Get-FileHash -LiteralPath $StarterMap -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-Equal -Actual $ActualHash -Expected $ExpectedHash -Message 'StarterMap SHA-256 mismatch.'

	$LfsVersion = & git lfs version 2>&1
	if ($LASTEXITCODE -ne 0) {
		throw "Git LFS is required for this policy check: $($LfsVersion -join [Environment]::NewLine)"
	}
	$StarterMapLfs = @(Invoke-Git -Arguments @('lfs', 'ls-files', "--include=$StarterMap"))
	if ($StarterMapLfs.Count -ne 1 -or $StarterMapLfs[0] -notmatch '^2a2b755b0f\s+\*\s+Content/Maps/StarterMap\.umap$') {
		throw 'StarterMap must remain an LFS-owned object with object prefix 2a2b755b0f.'
	}

	Write-Output 'Source-control policy checks passed.'
}
finally {
	Pop-Location
}
