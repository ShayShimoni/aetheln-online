# Shared, fail-closed contracts for the explicitly selected split recipe.
# Dot-sourcing this file performs no native work and creates no attestation.
function Stop-PackageRecipe {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a refusal exception only; it does not stop a process or change external state.')]
	param([string] $Reason = 'invalid')
	$Codes = @{ source_pins_invalid = 'pins_invalid'; clean_owned_retained = 'clean_retained'; receipt_origin_invalid = 'origin_invalid'; product_origin_invalid = 'origin_invalid'; compile_tool_unproven = 'tool_unproven'; compile_log_bound = 'log_bound'; clean_scope_invalid = 'clean_scope'; clean_receipt_unproven = 'clean_receipt'; provisioning_invalid = 'provision_invalid'; program_targets_changed = 'programs_changed'; supplement_changed = 'supp_changed'; unsupported_branch = 'branch_invalid'; timestamp_invalid = 'time_invalid' }
	if ($Codes.ContainsKey($Reason)) { $Reason = $Codes[$Reason] }
	$Code = 'package_recipe_' + $Reason
	if ($Code.Length -ge 32) { $Code = 'package_recipe_invalid' }
	throw ($Code + ': packaging recipe failed.')
}
function Get-PackageProofMember($Value, [string] $Name) {
	if ($null -eq $Value) { return $null }
	if ($Value -is [Collections.IDictionary]) { if ($Value.Contains($Name)) { return $Value[$Name] }; return $null }
	$Property = $Value.PSObject.Properties[$Name]
	if ($null -ne $Property) { return $Property.Value }; return $null
}
function Assert-PackageProofFields {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates one complete closed property set; existing PackagingRecipeProof callers depend on this exported contract.')]
	param($Value, [string[]] $Fields)
	if ($null -eq $Value -or $Value -is [array] -or $Value -is [string]) { Stop-PackageRecipe 'fields_invalid' }
	$Names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
	if (($Names | Sort-Object) -join ',' -cne (($Fields | Sort-Object) -join ',')) { Stop-PackageRecipe 'fields_invalid' }
}
function Assert-PackageProofHash($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { Stop-PackageRecipe 'hash_invalid' }
}
function Assert-PackageProofInteger($Value, [long] $Minimum, [long] $Maximum) {
	if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) { Stop-PackageRecipe 'bound_invalid' }
}
function ConvertFrom-PackageProofJson([string] $Raw, [int] $MaximumBytes = 8388608) {
	if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt $MaximumBytes) { Stop-PackageRecipe 'json_bound' }
	# Scope-aware duplicate scanner: compare decoded names before the PowerShell
	# JSON converter can silently discard duplicates, including escaped aliases.
	$Scopes = New-Object Collections.Stack
	$PendingName = $null
	for ($Index = 0; $Index -lt $Raw.Length; $Index++) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index]); $Index++
					if ($Index -ge $Raw.Length) { Stop-PackageRecipe 'json_invalid' }
				}
				[void] $Builder.Append($Raw[$Index]); $Index++
			}
			if ($Index -ge $Raw.Length) { Stop-PackageRecipe 'json_invalid' }
			try { $PendingName = [string] (('"' + $Builder.ToString() + '"') | ConvertFrom-Json) } catch { Stop-PackageRecipe 'json_invalid' }
		} elseif ($Character -eq '{') {
			if ($Scopes.Count -ge 64) { Stop-PackageRecipe 'json_bound' }
			$Scopes.Push((New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))); $PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { Stop-PackageRecipe 'json_invalid' }; [void] $Scopes.Pop(); $PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) { Stop-PackageRecipe 'json_duplicate' }; $PendingName = $null
		} elseif ($Character -in @(',', '[', ']')) { $PendingName = $null }
	}
	if ($Scopes.Count -ne 0) { Stop-PackageRecipe 'json_invalid' }
	try {
		$Command = Get-Command ConvertFrom-Json -CommandType Cmdlet
		if ($Command.Parameters.ContainsKey('DateKind')) { return ($Raw | ConvertFrom-Json -DateKind String) }
		return ($Raw | ConvertFrom-Json)
	} catch { Stop-PackageRecipe 'json_invalid' }
}
function Get-PackageProofBytesHash([byte[]] $Bytes) {
	$Algorithm = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $Algorithm.Dispose() }
}
function Resolve-PackageProofPath([string] $Root, [string] $Relative) {
	if ($Relative -cnotmatch '^[^\\/:*?"<>|\x00-\x1f]+(?:/[^\\/:*?"<>|\x00-\x1f]+)*$' -or @($Relative.Split('/') | Where-Object { $_ -in @('.', '..') -or $_.EndsWith('.') -or $_.EndsWith(' ') }).Count) { Stop-PackageRecipe 'path_invalid' }
	$RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	$Full = [IO.Path]::GetFullPath((Join-Path $RootFull $Relative))
	if (-not $Full.StartsWith($RootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Stop-PackageRecipe 'path_invalid' }
	$Probe = $Full
	while ($Probe.Length -ge $RootFull.Length) {
		if (Test-Path -LiteralPath $Probe) {
			if (((Get-Item -LiteralPath $Probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PackageRecipe 'path_invalid' }
		}
		$Next = Split-Path -Parent $Probe
		if (-not $Next -or $Next -eq $Probe) { break }; $Probe = $Next
	}
	return $Full
}
function Get-PackageProofFile([string] $Root, [string] $Relative) {
	$Full = Resolve-PackageProofPath $Root $Relative
	if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { Stop-PackageRecipe 'file_missing' }
	$Item = Get-Item -LiteralPath $Full -Force
	if ($Item.Length -le 0 -or $Item.Length -gt 4294967296) { Stop-PackageRecipe 'file_bound' }
	return [ordered]@{ sizeBytes = [long] $Item.Length; sha256 = (Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Assert-PackageProofFile($Entry, [string] $Root, [string] $Relative) {
	Assert-PackageProofHash $Entry.sha256; Assert-PackageProofInteger -Value $Entry.sizeBytes -Minimum 1 -Maximum 4294967296
	$Actual = Get-PackageProofFile $Root $Relative
	if ($Actual.sizeBytes -ne $Entry.sizeBytes -or $Actual.sha256 -cne $Entry.sha256) { Stop-PackageRecipe 'file_changed' }
}
function ConvertFrom-PackageProofTimestamp($Value) {
	$Date = [DateTime]::MinValue
	if ($Value -isnot [string] -or -not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $Date) -or $Date.Kind -ne [DateTimeKind]::Utc) { Stop-PackageRecipe 'timestamp_invalid' }
	return $Date
}
function Test-PackageCleanProductName([string] $Name, [string] $Phase, [string] $Platform, [string] $Configuration) {
	# UEBuildPlatform.IsBuildProductName uses OrdinalIgnoreCase and at most one
	# hyphen-delimited module token; no culture comparison or normalization.
	$Target = if ($Phase -ceq 'Client') { 'AethelnOnlineClient' } elseif ($Phase -ceq 'Server') { 'AethelnOnlineServer' } else { Stop-PackageRecipe 'target_invalid' }
	$Application = if ($Phase -ceq 'Client') { 'UnrealClient' } else { 'UnrealServer' }
	# Both pinned x64 platforms use architecture-less filenames. A new
	# architecture selection requires a reviewed extension of this fixed recipe.
	$Suffixes = @("-$Platform-$Configuration")
	if ($Configuration -ceq 'Development') { $Suffixes += '' }
	$Extensions = @('.target', '.modules', '.version')
	if ($Platform -ceq 'Win64') {
		$Extensions += @('.exe', '.dll', '.dll.response', '.dll.rsp', '.lib', '.pdb', '.full.pdb', '.exp', '.obj', '.map', '.objpaths', '.natvis', '.natstepfilter', '.natjmc')
		$Extensions += @($Extensions | Where-Object { $_ -notin @('.target', '.modules', '.version') } | ForEach-Object { '.alt' + $_ })
	} elseif ($Platform -ceq 'Linux') {
		$Extensions += @('', '.so', '.a', '.sym', '.debug')
		if ($Name.StartsWith('lib', [StringComparison]::Ordinal)) { $Name = $Name.Substring(3); $Extensions = @('.so', '.a', '.sym', '.debug') }
	} else { Stop-PackageRecipe 'target_invalid' }
	foreach ($Extension in $Extensions) {
		if ($Name.Length -le $Extension.Length -or -not $Name.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { continue }
		$Stem = $Name.Substring(0, $Name.Length - $Extension.Length)
		foreach ($Prefix in @($Target, $Application)) {
			if (-not $Stem.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
			foreach ($Suffix in $Suffixes) {
				if (-not $Stem.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
				$End = $Stem.Length - $Suffix.Length
				if ($End -lt $Prefix.Length) { continue }
				$Middle = $Stem.Substring($Prefix.Length, $End - $Prefix.Length)
				if ($Middle -ceq '' -or $Middle -cmatch '^-[^.-]*$') { return $true }
			}
		}
	}
	return $false
}
function Assert-PackageRecipeArguments {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the complete ordered argument vector of one recipe invocation; existing controller callers retain this exported contract.')]
	param([string[]] $Arguments, [string] $Phase, [string] $Configuration)
	if ($Arguments.Count -lt 15 -or $Arguments[0] -cne 'BuildCookRun') { Stop-PackageRecipe 'command_invalid' }
	$Expected = @('-nop4', '-utf8output', '-unattended', '-skipbuild', '-cook', '-clean', '-stage', '-pak', '-archive', '-nocompileeditor')
	$Expected += if ($Phase -ceq 'client') { @('-target=AethelnOnlineClient', '-platform=Win64', "-clientconfig=$Configuration", '-client') } elseif ($Phase -ceq 'server') { @('-target=AethelnOnlineServer', '-server', '-noclient', '-serverplatform=Linux', "-serverconfig=$Configuration") } else { Stop-PackageRecipe 'target_invalid' }
	foreach ($Token in $Expected) { if (@($Arguments | Where-Object { $_ -ceq $Token }).Count -ne 1) { Stop-PackageRecipe 'command_invalid' } }
	$Dynamic = @('-project=', '-map=', '-archivedirectory=')
	if ($Phase -ceq 'server') { $Dynamic += '-AdditionalCookerOptions=' }
	foreach ($Prefix in $Dynamic) {
		$Values = @($Arguments | Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) -and $_.Length -gt $Prefix.Length })
		if ($Values.Count -ne 1) { Stop-PackageRecipe 'command_invalid' }
		if ($Prefix -ceq '-AdditionalCookerOptions=' -and ($Values[0] -cnotmatch 'DefaultVirtualPointerClass=None' -or @([regex]::Matches($Values[0], '-NeverCookDir=')).Count -ne 3 -or $Values[0] -cnotmatch '/?CommonUI[/\\]Content' -or $Values[0] -cnotmatch 'EnhancedInput[/\\]Content' -or $Values[0] -cnotmatch 'Interchange[/\\]Runtime[/\\]Content')) { Stop-PackageRecipe 'command_invalid' }
	}
	if ($Arguments.Count -ne (1 + $Expected.Count + $Dynamic.Count)) { Stop-PackageRecipe 'command_invalid' }
}
function ConvertTo-PackageProofProjectPath($Path) {
	# Portable evidence compares the originating command paths, without requiring
	# that a relocated consumer has the original workspace mounted.
	if ($Path -isnot [string] -or $Path -cnotmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2) -match '[:*?"<>|\x00-\x1f]' -or [IO.Path]::GetExtension($Path) -cne '.uproject') { Stop-PackageRecipe 'project_invalid' }
	foreach ($Part in $Path.Substring(3).Split([char[]] '\/')) {
		if (-not $Part -or $Part -in @('.', '..') -or $Part.EndsWith('.') -or $Part.EndsWith(' ')) { Stop-PackageRecipe 'project_invalid' }
	}
	try { return [IO.Path]::GetFullPath($Path.Replace('/', '\')) } catch { Stop-PackageRecipe 'project_invalid' }
}
function Assert-PackageRecipeProvenance($Provenance) {
	# Stock documents stay byte/shape compatible. Any skipbuild declaration must
	# carry the closed split block; an unrecognized block is never ignored.
	$Build = Get-PackageProofMember $Provenance 'build'
	$Recipe = Get-PackageProofMember $Build 'packageRecipe'
	$HasBlock = $null -ne $Recipe
	$Invocations = Get-PackageProofMember $Build 'uatInvocations'
	$ClientArguments = @(Get-PackageProofMember (Get-PackageProofMember $Invocations 'client') 'arguments')
	$ServerArguments = @(Get-PackageProofMember (Get-PackageProofMember $Invocations 'server') 'arguments')
	$Skip = @($ClientArguments + $ServerArguments | Where-Object { $_ -is [string] -and $_ -imatch '^-skipbuild(?:=|$)' }).Count -gt 0
	if (-not $HasBlock) { if ($Skip) { Stop-PackageRecipe 'proof_missing' }; return }
	Assert-PackageProofFields $Recipe @('schemaVersion', 'id', 'baseAttestationSha256', 'supplementSha256', 'client', 'server')
	Assert-PackageProofInteger -Value $Recipe.schemaVersion -Minimum 1 -Maximum 1
	if ($Recipe.schemaVersion -ne 1 -or $Recipe.id -cne 'clean-targets-prebuilt-programs-v1' -or -not $Skip) { Stop-PackageRecipe 'proof_invalid' }
	Assert-PackageProofHash $Recipe.baseAttestationSha256; Assert-PackageProofHash $Recipe.supplementSha256
	if ($Recipe.baseAttestationSha256 -cne 'a457da4e14808b85d5cc1439a920abfce114ec961e313c2684fdd57ba9385d95') { Stop-PackageRecipe 'base_invalid' }
	foreach ($Kind in @('client', 'server')) {
		Assert-PackageRecipeArguments -Arguments @($Build.uatInvocations.$Kind.arguments) -Phase $Kind -Configuration $Build.configuration
		Assert-PackageCleanPhaseProof -Proof $Recipe.$Kind -Kind $Kind -Revision $Provenance.source.revision -BaseHash $Recipe.baseAttestationSha256 -SupplementHash $Recipe.supplementSha256
		$UatProject = @($Build.uatInvocations.$Kind.arguments | Where-Object { $_.StartsWith('-project=', [StringComparison]::Ordinal) })[0].Substring(9)
		$NativeProject = ConvertTo-PackageProofProjectPath $Recipe.$Kind.clean.arguments[3]
		if (-not [string]::Equals((ConvertTo-PackageProofProjectPath $UatProject), $NativeProject, [StringComparison]::OrdinalIgnoreCase)) { Stop-PackageRecipe 'project_changed' }
		if ($Recipe.$Kind.sourceIdentity.projectDescriptorSha256 -cne $Provenance.source.projectSha256 -or $Recipe.$Kind.engineIdentity.buildVersionSha256 -cne $Provenance.tools.unreal.buildVersionSha256 -or $Recipe.$Kind.engineIdentity.revision -cne $Provenance.tools.unreal.repositoryRevision) { Stop-PackageRecipe 'context_changed' }
	}
	if (($Recipe.client.runIdentity | ConvertTo-Json -Compress) -cne ($Recipe.server.runIdentity | ConvertTo-Json -Compress) -or $Recipe.client.sourceIdentity.projectDescriptorSha256 -cne $Recipe.server.sourceIdentity.projectDescriptorSha256 -or $Recipe.client.engineIdentity.revision -cne $Recipe.server.engineIdentity.revision) { Stop-PackageRecipe 'pair_mismatch' }
	if (($Recipe.client.sourceIdentity.targetRulePins | ConvertTo-Json -Compress) -cne ($Recipe.server.sourceIdentity.targetRulePins | ConvertTo-Json -Compress)) { Stop-PackageRecipe 'pair_mismatch' }
	$ClientTools = $Recipe.client.engineIdentity.selectedTools; $ServerTools = $Recipe.server.engineIdentity.selectedTools
	if ($ClientTools.compiler.sha256 -cne $Provenance.tools.compiler.sha256 -or $ClientTools.resourceCompiler.sha256 -cne $Provenance.tools.windowsSdk.resourceCompilerSha256 -or $ServerTools.linuxCompiler.sha256 -cne $Provenance.tools.linuxCrossToolchain.compilerSha256) { Stop-PackageRecipe 'tool_changed' }
}

function Assert-PackageBuildInputProof($Proof) {
	$Absent = Get-PackageProofMember $Proof 'ubtExtraArgsAbsent'
	if ($Absent -isnot [bool] -or -not $Absent) { Stop-PackageRecipe 'build_inputs_invalid' }
	Assert-PackageProofFields $Proof @('ubtExtraArgsAbsent')
}
function Get-PackageBuildInputProof {
	# Public named build input only. Never print, parse, or change its value.
	if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('UBT_EXTRA_ARGS', 'Process'))) { Stop-PackageRecipe 'build_inputs_set' }
	return [ordered]@{ ubtExtraArgsAbsent = $true }
}
function Assert-PackageNativeProof($Step, [string[]] $Arguments, [bool] $Clean = $false) {
	$Fields = @('executableSha256', 'arguments', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure', 'buildInputs', 'captureSha256', 'logSha256')
	if ($Clean) { $Fields += @('ownedRemoval', 'discovery') }
	Assert-PackageProofFields $Step $Fields
	Assert-PackageBuildInputProof $Step.buildInputs
	foreach ($Field in @('executableSha256', 'captureSha256', 'logSha256')) { Assert-PackageProofHash $Step.$Field }
	$Start = ConvertFrom-PackageProofTimestamp $Step.startedUtc
	$End = ConvertFrom-PackageProofTimestamp $Step.finishedUtc
	if ($End -lt $Start -or ($End - $Start).TotalMinutes -gt 30 -or $Step.nativeExitCode -isnot [int] -or $Step.nativeExitCode -ne 0 -or $null -ne $Step.infrastructureFailure -or $Step.arguments -isnot [array] -or ($Step.arguments -join "`n") -cne ($Arguments -join "`n")) { Stop-PackageRecipe 'native_failed' }
}
function Get-PackageResourceActionLimit($Sample) {
	Assert-PackageProofFields $Sample @('observedUtc', 'physicalCores', 'availablePhysicalRamGiB', 'commitHeadroomGiB', 'volumes', 'buildInputs')
	Assert-PackageBuildInputProof $Sample.buildInputs
	$null = ConvertFrom-PackageProofTimestamp $Sample.observedUtc
	Assert-PackageProofInteger -Value $Sample.physicalCores -Minimum 1 -Maximum 65536
	foreach ($Name in @('availablePhysicalRamGiB', 'commitHeadroomGiB')) {
		$Value = $Sample.$Name
		if (($Value -isnot [double] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [decimal]) -or [double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 0 -or $Value -gt 1048576) { Stop-PackageRecipe 'resources_invalid' }
	}
	if ($Sample.volumes -isnot [array] -or $Sample.volumes.Count -lt 1 -or $Sample.volumes.Count -gt 16) { Stop-PackageRecipe 'resources_invalid' }
	foreach ($Volume in $Sample.volumes) {
		Assert-PackageProofFields $Volume @('availableBytes', 'knownAllocationBytes', 'recoveryFloorBytes')
		foreach ($Name in @('availableBytes', 'knownAllocationBytes', 'recoveryFloorBytes')) { Assert-PackageProofInteger -Value $Volume.$Name -Minimum 0 -Maximum ([long]::MaxValue) }
	}
	# Definitions only: this neither creates an attempt nor acquires a host lease.
	. (Join-Path $PSScriptRoot '../ci/InitialPreparation.Core.ps1')
	try { return (Get-InitialPreparationActionLimit -Capacity $Sample) } catch { Stop-PackageRecipe 'resources_invalid' }
}
function Get-PackageResourceSample([Collections.IDictionary] $Roots) {
	# A synchronous preflight, not a continuous resource/owned-stop monitor.
	$BuildInputs = Get-PackageBuildInputProof
	. (Join-Path $PSScriptRoot '../ci/RoutineCompileResources.ps1')
	try {
		$Monitor = New-RoutineCompileResourceMonitor -Roots $Roots
		$Capacity = Read-RoutineResourceCapacity -Monitor $Monitor
		return [ordered]@{ observedUtc = [DateTime]::UtcNow.ToString('o'); physicalCores = $Capacity.physicalCores; availablePhysicalRamGiB = $Capacity.availablePhysicalRamGiB; commitHeadroomGiB = $Capacity.commitHeadroomGiB; volumes = @($Capacity.volumes); buildInputs = $BuildInputs }
	} catch { Stop-PackageRecipe 'resources_invalid' }
}
function New-PackageCompileResources {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Constructs one paired admission and recheck capacity record; existing packaging and Program producer callers retain this exported contract.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory capacity proof from supplied samples and changes no external state.')]
	param($Sample, $RequestedActionLimit = $null)
	if ($null -ne $RequestedActionLimit) { Assert-PackageProofInteger -Value $RequestedActionLimit -Minimum 1 -Maximum 4 }
	$Limit = Get-PackageResourceActionLimit $Sample
	if ($null -ne $RequestedActionLimit) { $Limit = [Math]::Min($Limit, $RequestedActionLimit) }
	return [ordered]@{ requestedActionLimit = $RequestedActionLimit; effectiveActionLimit = [int] $Limit; admission = $Sample; recheck = $null }
}
function Assert-PackageCompileResources {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates one paired admission and recheck capacity record; existing packaging and Program producer callers retain this exported contract.')]
	param($Resources, [bool] $RequireRecheck = $true)
	Assert-PackageProofFields $Resources @('requestedActionLimit', 'effectiveActionLimit', 'admission', 'recheck')
	Assert-PackageProofInteger -Value $Resources.effectiveActionLimit -Minimum 1 -Maximum 4
	$Expected = New-PackageCompileResources $Resources.admission $Resources.requestedActionLimit
	if ($Expected.effectiveActionLimit -ne $Resources.effectiveActionLimit) { Stop-PackageRecipe 'resources_invalid' }
	if ($RequireRecheck) {
		if ((Get-PackageResourceActionLimit $Resources.recheck) -lt $Resources.effectiveActionLimit -or (ConvertFrom-PackageProofTimestamp $Resources.recheck.observedUtc) -lt (ConvertFrom-PackageProofTimestamp $Resources.admission.observedUtc)) { Stop-PackageRecipe 'resources_invalid' }
	} elseif ($null -ne $Resources.recheck) { Stop-PackageRecipe 'resources_invalid' }
}
function Assert-PackageNativeArgumentBoundaries {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates every token boundary in one native argument vector; existing native and Program producer callers retain this exported contract.')]
	param([string[]] $Arguments)
	# This recipe invokes one fixed target through canonical Clean/Build.bat.
	# TargetDescriptor expands nested Target/TargetList arguments; GlobalOptions
	# can select another mode, and EpicGames.Core stops parsing options at --.
	$AlternateEntry = '^-(?:Target|TargetList|Mode|Clean|Rebuild|ProjectFiles|ProjectFileFormat|Makefile|CMakefile|QMakefile|KDevelopfile|CodeliteFiles|XCodeProjectFiles|EddieProjectFiles|VSCode|VSMac|CLion|Rider|AndroidStudio|VProject)(?:[=:]|$)'
	if (@($Arguments | Where-Object { $_ -ceq '--' -or $_ -imatch $AlternateEntry }).Count -ne 0) { Stop-PackageRecipe 'argument_boundary' }
}
function Get-PackageCompileArgumentLimit([string[]] $Arguments) {
	Assert-PackageNativeArgumentBoundaries $Arguments
	$Flags = @($Arguments | Where-Object { $_ -imatch '^-MaxParallelActions(?:[=:]|$)' })
	if ($Flags.Count -ne 1 -or $Flags[0] -cnotmatch '^-MaxParallelActions=[1-4]$') { Stop-PackageRecipe 'action_limit_invalid' }
	return [int] $Flags[0].Substring(20)
}
function Assert-PackageCleanPhaseProof($Proof, [string] $Kind, [string] $Revision, [string] $BaseHash, [string] $SupplementHash) {
	Assert-PackageProofFields $Proof @('schemaId', 'schemaVersion', 'runIdentity', 'sourceIdentity', 'engineIdentity', 'hostProof', 'phase', 'target', 'platform', 'configuration', 'compileResources', 'clean', 'compile', 'targetReceipt', 'products', 'stability', 'cleanupProof')
	Assert-PackageCompileResources $Proof.compileResources
	Assert-PackageProofInteger -Value $Proof.schemaVersion -Minimum 1 -Maximum 1
	$Target = if ($Kind -ceq 'client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
	$Platform = if ($Kind -ceq 'client') { 'Win64' } else { 'Linux' }
	if ($Proof.schemaId -cne 'aetheln.clean-target-phase/v1' -or $Proof.schemaVersion -ne 1 -or $Proof.phase -cne $Kind -or $Proof.target -cne $Target -or $Proof.platform -cne $Platform -or $Proof.configuration -cne 'Development') { Stop-PackageRecipe 'phase_invalid' }
	Assert-PackageProofFields $Proof.runIdentity @('repository', 'runId', 'runAttempt', 'runnerName')
	if ($Proof.runIdentity.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Proof.runIdentity.runId -cnotmatch '^[1-9][0-9]{0,19}$' -or $Proof.runIdentity.runAttempt -cnotmatch '^[1-9][0-9]{0,5}$' -or $Proof.runIdentity.runnerName -cnotmatch '^[^\\/:*?"<>|\x00-\x1f]{1,128}$') { Stop-PackageRecipe 'identity_invalid' }
	Assert-PackageProofFields $Proof.sourceIdentity @('revision', 'projectDescriptorSha256', 'targetRulePins')
	if ($Proof.sourceIdentity.revision -cne $Revision -or $Revision -cnotmatch '^[0-9a-f]{40}$') { Stop-PackageRecipe 'source_changed' }
	Assert-PackageProofHash $Proof.sourceIdentity.projectDescriptorSha256
	$RuleNames = @('Source/AethelnOnline.Target.cs', 'Source/AethelnOnlineClient.Target.cs', 'Source/AethelnOnlineEditor.Target.cs', 'Source/AethelnOnlineServer.Target.cs')
	if ($Proof.sourceIdentity.targetRulePins -isnot [array] -or $Proof.sourceIdentity.targetRulePins.Count -ne 4) { Stop-PackageRecipe 'source_pins_invalid' }
	foreach ($Pin in $Proof.sourceIdentity.targetRulePins) { Assert-PackageProofFields $Pin @('root', 'path', 'sha256'); Assert-PackageProofHash $Pin.sha256; if ($Pin.root -cne 'project' -or $RuleNames -cnotcontains $Pin.path -or @($Proof.sourceIdentity.targetRulePins | Where-Object { $_.path -ieq $Pin.path }).Count -ne 1) { Stop-PackageRecipe 'source_pins_invalid' } }
	Assert-PackageProofFields $Proof.engineIdentity @('revision', 'buildVersionSha256', 'selectedTools')
	if ($Proof.engineIdentity.revision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43') { Stop-PackageRecipe 'engine_changed' }
	Assert-PackageProofHash $Proof.engineIdentity.buildVersionSha256
	Assert-PackageProofFields $Proof.engineIdentity.selectedTools @('compiler', 'resourceCompiler', 'linuxCompiler')
	foreach ($Name in @('compiler', 'resourceCompiler', 'linuxCompiler')) {
		$Tool = $Proof.engineIdentity.selectedTools.$Name
		$Required = if ($Kind -ceq 'client') { $Name -cne 'linuxCompiler' } else { $Name -ceq 'linuxCompiler' }
		if (-not $Required) { if ($null -ne $Tool) { Stop-PackageRecipe 'tool_invalid' }; continue }
		Assert-PackageProofFields $Tool @('path', 'sizeBytes', 'sha256')
		Assert-PackageProofHash $Tool.sha256; Assert-PackageProofInteger -Value $Tool.sizeBytes -Minimum 1 -Maximum 4294967296
		$Extension = if ($Name -ceq 'compiler') { 'cl.exe' } elseif ($Name -ceq 'resourceCompiler') { 'rc.exe' } else { 'clang++.exe' }
		if ([IO.Path]::GetFileName($Tool.path) -cne $Extension) { Stop-PackageRecipe 'tool_invalid' }
	}
	Assert-PackageProofFields $Proof.hostProof @('baseAttestationSha256', 'supplementSha256')
	if ($Proof.hostProof.baseAttestationSha256 -cne $BaseHash -or $Proof.hostProof.supplementSha256 -cne $SupplementHash) { Stop-PackageRecipe 'host_changed' }
	Assert-PackageProofFields $Proof.stability @('sourceUnchanged', 'baseUnchanged', 'supplementUnchanged')
	foreach ($Name in @('sourceUnchanged', 'baseUnchanged', 'supplementUnchanged')) { if ($Proof.stability.$Name -isnot [bool] -or -not $Proof.stability.$Name) { Stop-PackageRecipe 'stability_failed' } }
	Assert-PackageProofFields $Proof.cleanupProof @('supervisor', 'verified')
	if ($Proof.cleanupProof.supervisor -cne 'windows-job' -or $Proof.cleanupProof.verified -isnot [bool] -or -not $Proof.cleanupProof.verified) { Stop-PackageRecipe 'cleanup_failed' }
	$CleanArgs = @($Target, $Platform, 'Development', $Proof.clean.arguments[3], '-WaitMutex')
	$null = ConvertTo-PackageProofProjectPath $CleanArgs[3]
	Assert-PackageNativeProof -Step $Proof.clean -Arguments $CleanArgs -Clean $true
	Assert-PackageProofFields $Proof.clean.discovery @('nativeStep', 'planSha256')
	Assert-PackageProofHash $Proof.clean.discovery.planSha256
	Assert-PackageNativeProof $Proof.clean.discovery.nativeStep ($CleanArgs + '-DryRun')
	if ((ConvertFrom-PackageProofTimestamp $Proof.clean.startedUtc) -lt (ConvertFrom-PackageProofTimestamp $Proof.clean.discovery.nativeStep.finishedUtc)) { Stop-PackageRecipe 'order_invalid' }
	$ActionLimit = Get-PackageCompileArgumentLimit $Proof.compile.arguments
	if ($ActionLimit -ne $Proof.compileResources.effectiveActionLimit -or (ConvertFrom-PackageProofTimestamp $Proof.compileResources.admission.observedUtc) -gt (ConvertFrom-PackageProofTimestamp $Proof.clean.discovery.nativeStep.startedUtc) -or (ConvertFrom-PackageProofTimestamp $Proof.compileResources.recheck.observedUtc) -lt (ConvertFrom-PackageProofTimestamp $Proof.clean.finishedUtc) -or (ConvertFrom-PackageProofTimestamp $Proof.compileResources.recheck.observedUtc) -gt (ConvertFrom-PackageProofTimestamp $Proof.compile.startedUtc)) { Stop-PackageRecipe 'resources_invalid' }
	Assert-PackageNativeProof $Proof.compile (@($Target, $Platform, 'Development', $CleanArgs[3], '-WaitMutex', '-NoHotReloadFromIDE', '-NoEngineChanges', '-Verbose', "-MaxParallelActions=$ActionLimit"))
	$ExecutablePins = @(Get-PackageRecipeReviewedPins)
	$CleanPin = @($ExecutablePins | Where-Object { $_.root -ceq 'engine' -and $_.path -ceq 'Engine/Build/BatchFiles/Clean.bat' })
	$BuildPin = @($ExecutablePins | Where-Object { $_.root -ceq 'engine' -and $_.path -ceq 'Engine/Build/BatchFiles/Build.bat' })
	if ($CleanPin.Count -ne 1 -or $BuildPin.Count -ne 1 -or $Proof.clean.discovery.nativeStep.executableSha256 -cne $CleanPin[0].sha256 -or $Proof.clean.executableSha256 -cne $CleanPin[0].sha256 -or $Proof.compile.executableSha256 -cne $BuildPin[0].sha256) { Stop-PackageRecipe 'executable_changed' }
	if ((ConvertFrom-PackageProofTimestamp $Proof.compile.startedUtc) -lt (ConvertFrom-PackageProofTimestamp $Proof.clean.finishedUtc)) { Stop-PackageRecipe 'order_invalid' }
	$Removal = $Proof.clean.ownedRemoval
	Assert-PackageProofFields $Removal @('predicatePins', 'prefixes', 'suffixes', 'roots', 'filesBefore', 'filesAfter', 'directoriesBefore', 'directoriesAfter')
	if (($Removal.prefixes -join ',') -cne ($(if ($Kind -ceq 'client') { 'UnrealClient,AethelnOnlineClient' } else { 'UnrealServer,AethelnOnlineServer' })) -or @($Removal.predicatePins).Count -lt 6 -or @($Removal.roots).Count -lt 2) { Stop-PackageRecipe 'clean_invalid' }
	if (($Removal.suffixes -join ',') -cne (',-' + $Platform + '-Development') -or $Removal.predicatePins -isnot [array] -or $Removal.predicatePins.Count -ne 6 -or $Removal.roots -isnot [array] -or $Removal.roots.Count -ne 2) { Stop-PackageRecipe 'clean_invalid' }
	$PredicatePins = @(Get-PackageRecipeReviewedPins | Where-Object { $_.path -match 'CleanMode|UEBuildPlatform|UEBuildTarget|UEBuildWindows|UEBuildLinux|TargetRules' })
	foreach ($Pin in $Removal.predicatePins) {
		Assert-PackageProofFields $Pin @('root', 'path', 'sha256')
		if (@($PredicatePins | Where-Object { $_.root -ceq $Pin.root -and $_.path -ceq $Pin.path -and $_.sha256 -ceq $Pin.sha256 }).Count -ne 1 -or @($Removal.predicatePins | Where-Object { $_.path -ieq $Pin.path }).Count -ne 1) { Stop-PackageRecipe 'clean_invalid' }
	}
	foreach ($Scope in $Removal.roots) { Assert-PackageProofFields $Scope @('root', 'path'); if (($Scope.root -ceq 'engine' -and $Scope.path -cne 'Engine') -or ($Scope.root -ceq 'project' -and $Scope.path -cne '.') -or $Scope.root -cnotin @('engine', 'project') -or @($Removal.roots | Where-Object { $_.root -ieq $Scope.root }).Count -ne 1) { Stop-PackageRecipe 'clean_invalid' } }
	foreach ($Set in @('filesBefore', 'filesAfter', 'directoriesBefore', 'directoriesAfter')) {
		if ($Removal.$Set -isnot [array] -or $Removal.$Set.Count -gt 8192) { Stop-PackageRecipe 'clean_invalid' }
		foreach ($Entry in $Removal.$Set) {
			Assert-PackageProofFields $Entry @('root', 'path', 'type', 'exists')
			if ($Entry.root -cnotin @('engine', 'project') -or $Entry.exists -isnot [bool] -or $Entry.type -cnotin @('file', 'directory')) { Stop-PackageRecipe 'clean_invalid' }
			$null = Resolve-PackageProofPath ([IO.Path]::GetTempPath()) $Entry.path
			if ($Set.EndsWith('After', [StringComparison]::Ordinal) -and $Entry.exists) { Stop-PackageRecipe 'clean_owned_retained' }
		}
	}
	foreach ($Type in @('files', 'directories')) {
		$Before = @((Get-PackageProofMember -Value $Removal -Name ($Type + 'Before')) | ForEach-Object { $_.root + '/' + $_.path + '/' + $_.type } | Sort-Object)
		$After = @((Get-PackageProofMember -Value $Removal -Name ($Type + 'After')) | ForEach-Object { $_.root + '/' + $_.path + '/' + $_.type } | Sort-Object)
		if (($Before -join "`n") -cne ($After -join "`n") -or @($Before | Select-Object -Unique).Count -ne $Before.Count) { Stop-PackageRecipe 'clean_invalid' }
	}
	$ExpectedReceipt = "Binaries/$Platform/$Target.target"
	$ReceiptObservation = @($Removal.filesAfter | Where-Object { $_.root -ceq 'project' -and $_.path -ceq $ExpectedReceipt -and -not $_.exists })
	if ($ReceiptObservation.Count -ne 1) { Stop-PackageRecipe 'clean_receipt_unproven' }
	Assert-PackageProofFields $Proof.targetReceipt @('relativePath', 'sizeBytes', 'sha256', 'payloadBase64')
	if ($Proof.targetReceipt.relativePath -cne $ExpectedReceipt) { Stop-PackageRecipe 'receipt_invalid' }
	$Receipt = Read-PackageSealedReceipt $Proof.targetReceipt
	if ($Receipt.TargetName -cne $Target -or $Receipt.Platform -cne $Platform -or $Receipt.Configuration -cne 'Development' -or $Receipt.TargetType -cne ($(if ($Kind -ceq 'client') { 'Client' } else { 'Server' }))) { Stop-PackageRecipe 'receipt_invalid' }
	if ($Proof.products -isnot [array] -or $Proof.products.Count -ne @($Receipt.BuildProducts).Count -or $Proof.products.Count -lt 1 -or $Proof.products.Count -gt 8192) { Stop-PackageRecipe 'products_invalid' }
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$PayloadSeen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Product in $Proof.products) {
		Assert-PackageProofFields $Product @('receiptPath', 'type', 'payloadPath', 'sizeBytes', 'sha256')
		Assert-PackageProofHash $Product.sha256; Assert-PackageProofInteger -Value $Product.sizeBytes -Minimum 1 -Maximum 4294967296
		if (-not $Seen.Add($Product.receiptPath) -or -not $PayloadSeen.Add($Product.payloadPath) -or $Product.payloadPath -cnotmatch '^Proof/products/[0-9]{4}\.product$' -or $Product.receiptPath -cnotmatch '^\$\((?:Engine|Project)Dir\)/' -or $Product.type -cnotin @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package', 'SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary') -or @($Receipt.BuildProducts | Where-Object { $_.Path -ceq $Product.receiptPath -and $_.Type -ceq $Product.type }).Count -ne 1) { Stop-PackageRecipe 'products_invalid' }
		$null = Resolve-PackageProofPath ([IO.Path]::GetTempPath()) $Product.payloadPath
	}
	$ExpectedLaunch = '$(ProjectDir)/Binaries/' + $Platform + '/' + $Target + $(if ($Kind -ceq 'client') { '.exe' } else { '' })
	if ($Receipt.Architecture -cne 'x64' -or $Receipt.Launch -cne $ExpectedLaunch -or @($Proof.products | Where-Object { $_.receiptPath -ceq $ExpectedLaunch -and $_.type -ceq 'Executable' }).Count -ne 1) { Stop-PackageRecipe 'launch_missing' }
}
function Read-PackageSealedReceipt($Seal) {
	Assert-PackageProofHash $Seal.sha256; Assert-PackageProofInteger -Value $Seal.sizeBytes -Minimum 1 -Maximum 16777216
	if ($Seal.payloadBase64 -isnot [string] -or $Seal.payloadBase64.Length -gt 22369624) { Stop-PackageRecipe 'receipt_bound' }
	try { $Bytes = [Convert]::FromBase64String($Seal.payloadBase64) } catch { Stop-PackageRecipe 'receipt_invalid' }
	if ($Bytes.Length -ne $Seal.sizeBytes -or (Get-PackageProofBytesHash $Bytes) -cne $Seal.sha256) { Stop-PackageRecipe 'receipt_changed' }
	$Reader = New-Object IO.StreamReader ([IO.MemoryStream]::new($Bytes)), ([Text.UTF8Encoding]::new($false, $true)), $true
	try { $Raw = $Reader.ReadToEnd() } catch { Stop-PackageRecipe 'receipt_invalid' } finally { $Reader.Dispose() }
	$Receipt = ConvertFrom-PackageProofJson $Raw 16777216
	foreach ($Field in @('TargetName', 'Platform', 'Configuration', 'TargetType', 'Architecture', 'Version', 'Launch', 'BuildProducts', 'RuntimeDependencies')) { if ($null -eq $Receipt.PSObject.Properties[$Field]) { Stop-PackageRecipe 'receipt_invalid' } }
	if ($Receipt.BuildProducts -isnot [array] -or $Receipt.BuildProducts.Count -lt 1 -or $Receipt.BuildProducts.Count -gt 8192 -or $Receipt.RuntimeDependencies -isnot [array] -or $Receipt.RuntimeDependencies.Count -gt 8192) { Stop-PackageRecipe 'receipt_invalid' }
	return $Receipt
}
function Get-PackageReceiptSeal([string] $Root, [string] $Relative) {
	$Metadata = Get-PackageProofFile $Root $Relative
	if ($Metadata.sizeBytes -gt 16777216) { Stop-PackageRecipe 'receipt_bound' }
	$Bytes = [IO.File]::ReadAllBytes((Resolve-PackageProofPath $Root $Relative))
	if ((Get-PackageProofBytesHash $Bytes) -cne $Metadata.sha256) { Stop-PackageRecipe 'receipt_changed' }
	return [ordered]@{ relativePath = $Relative; sizeBytes = $Metadata.sizeBytes; sha256 = $Metadata.sha256; payloadBase64 = [Convert]::ToBase64String($Bytes) }
}
function Assert-PackageTargetProductsCurrent($Proof, [string] $EngineRoot, [string] $ProjectRoot) {
	Assert-PackageProofFile -Entry $Proof.targetReceipt -Root $ProjectRoot -Relative $Proof.targetReceipt.relativePath
	foreach ($Product in $Proof.products) {
		if ($Product.receiptPath.StartsWith('$(ProjectDir)/', [StringComparison]::Ordinal)) { $Root = $ProjectRoot; $Relative = $Product.receiptPath.Substring(14) }
		elseif ($Product.receiptPath.StartsWith('$(EngineDir)/', [StringComparison]::Ordinal)) { $Root = $EngineRoot; $Relative = 'Engine/' + $Product.receiptPath.Substring(13) }
		else { Stop-PackageRecipe 'product_origin_invalid' }
		Assert-PackageProofFile -Entry $Product -Root $Root -Relative $Relative
	}
}

function Get-PackageRecipeReviewedPins {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the complete reviewed source pin set; existing recipe constructor and fixture override require this exported name.')]
	param()
    @(
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/AutomationUtils/ProjectParams.cs'; sha256 = '18503d50c19a46350803e7b18d8afafaec1f3ecc4dac6e5469b5eaf63f99fb4e' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Scripts/BuildProjectCommand.Automation.cs'; sha256 = '78198ec64a8a19ab3bd1e2c2b75fb34d9d53abffdf80832e400bf721f00be04b' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Scripts/BuildCookRun.Automation.cs'; sha256 = '8b2cbaa85eaed36bf405fb8c3edba7778ba8a84cb1a2d50d97c7eebb6e3679b8' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Scripts/CookCommand.Automation.cs'; sha256 = 'abd08f3ece7b28bf18ba6bdb5e8d61af6bd823331e71531a3d860bb4fe376a65' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Scripts/CopyBuildToStagingDirectory.Automation.cs'; sha256 = '499037482975f7961e6bb1b3a3eda0f3d2e8f57f1329352cdc12384260ead7db' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Win/WinPlatform.Automation.cs'; sha256 = '73e652acf3d7a6b84e136eeda4b4bb8257dd119f3b99214275ae1ad9393f83e1' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/Linux/LinuxPlatform.Automation.cs'; sha256 = 'd06e234590c1996d192fc39598ab23d23c5428650e4829216f68130ee1c657b5' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/AutomationTool/AutomationUtils/Platform.cs'; sha256 = '8149a0e149db32947f94da001a508ce99fe9a8bda38a6f1481af8d2e6e7c6743' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Configuration/UEBuildTarget.cs'; sha256 = '8872859bfd0c28e997de33d69ef49da929d71461f1b871298273f804d3d09b9a' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/System/TargetReceipt.cs'; sha256 = '5620be237694b7da5e84722805486455c95fbca6096695789e2c06029711012f' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealPak/UnrealPak.Target.cs'; sha256 = '7984fd6d24b40d242c5ecc2134c31adf6d8af1d8f6d62e59f6b397e5ff8250cc' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/Windows/BootstrapPackagedGame/BootstrapPackagedGame.Target.cs'; sha256 = '29366e3d2843da6cb35b975810172fcf0e4642d2754aabe645d25764f7a4c716' },
        [ordered]@{ root = 'engine'; path = 'Engine/Build/BatchFiles/Build.bat'; sha256 = '4f71b08ebc3fe2ba7918a5be7a0b3f22cf7ce5530049873e9eca8df946bc1cb3' },
        [ordered]@{ root = 'engine'; path = 'Engine/Build/BatchFiles/Clean.bat'; sha256 = 'f8286338d9e674ca56921a1e35a7a4669dfd7d65405a1a2c83b34320630ed5cb' },
        [ordered]@{ root = 'engine'; path = 'Engine/Build/BatchFiles/RunUAT.bat'; sha256 = 'e2df422b26722a960a0726713336619e65b1013548671cd6cec6d010f993eabb' },
        [ordered]@{ root = 'engine'; path = 'Engine/Build/Build.version'; sha256 = '29f7a3e61c24327147037ee15928d1bd1603fb65bcd19058e8381e26a12d38bd' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/System/SourceFileMetadataCache.cs'; sha256 = '310740adf77a4d93b3a96c28779355851daf0b692784d6a3e6d29097efa3ca8f' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/System/TargetMakefile.cs'; sha256 = 'f46fdb3d704da93c54ddcd752e7095893ad6b459f8112b9b82df10916f717a89' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Platform/Windows/VCToolChain.cs'; sha256 = 'f1f72f3bec80b4cb370d1503f832dc24cbf96329fda2b911185e08ffc4b7239c' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Platform/Linux/LinuxToolChain.cs'; sha256 = '4b39246cdcb809e183b7b72bb57b6f6a5a97e022a0d1ebfb949a689a3baa6cde' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Platform/Clang/ClangToolChain.cs'; sha256 = '4873e46045567b6261431396c56c4ff6dd754d56dc96b6b285da335087abb11b' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Modes/CleanMode.cs'; sha256 = 'b95e3b0be31561b1901b923b705ec8826d0a868c568d88047f245a08f496038d' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Configuration/UEBuildPlatform.cs'; sha256 = '95761e0c85d62aeb9f96a04747df8395acc0195e05a66a3a94a406a3671100a6' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Platform/Windows/UEBuildWindows.cs'; sha256 = 'bd1b1c1fbba691f4c46818b4f825f0b0d1a45e1e867187517f6fcd87bb4d07c3' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Platform/Linux/UEBuildLinux.cs'; sha256 = '21454b6227e7917774fb9e78ec66d4b7fc33a6f3dcaadb9571fdd9b9b7ca00e9' },
        [ordered]@{ root = 'engine'; path = 'Engine/Source/Programs/UnrealBuildTool/Configuration/Rules/TargetRules.cs'; sha256 = 'e135c4552ce0949516a7a699d2a26cd0424b52d05cd13a7c0289beeccab44beb' }
    )
}

function Get-PackageTargetRulePins {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the complete target-rule pin set for one project; existing recipe constructor and readback callers retain this exported name.')]
	param([string] $ProjectRoot)
	$Names = @('AethelnOnline', 'AethelnOnlineClient', 'AethelnOnlineEditor', 'AethelnOnlineServer')
	$ActualNames = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Source') -Filter '*.Target.cs' -Recurse -File | ForEach-Object { $_.BaseName.Replace('.Target', '') } | Sort-Object)
	if (($ActualNames -join ',') -cne (($Names | Sort-Object) -join ',')) { Stop-PackageRecipe 'program_targets_changed' }
	foreach ($Name in $Names) {
		$Relative = "Source/$Name.Target.cs"
		$File = Get-PackageProofFile $ProjectRoot $Relative
		[ordered]@{ root = 'project'; path = $Relative; sha256 = $File.sha256 }
	}
}
function Assert-PackageSourcePins {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the entire source pin set against one expected set; existing recipe readers and constructors retain this exported contract.')]
	param($Pins, $Expected, [string] $EngineRoot, [string] $ProjectRoot)
	if ($Pins -isnot [array] -or @($Pins).Count -ne @($Expected).Count) { Stop-PackageRecipe 'source_pins_invalid' }
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Pin in $Pins) {
		Assert-PackageProofFields $Pin @('root', 'path', 'sha256'); Assert-PackageProofHash $Pin.sha256
		if (-not $Seen.Add($Pin.root + '/' + $Pin.path)) { Stop-PackageRecipe 'source_pins_invalid' }
		$Match = @($Expected | Where-Object { $_.root -ceq $Pin.root -and $_.path -ceq $Pin.path -and $_.sha256 -ceq $Pin.sha256 })
		if ($Match.Count -ne 1) { Stop-PackageRecipe 'source_changed' }
		$Root = if ($Pin.root -ceq 'engine') { $EngineRoot } elseif ($Pin.root -ceq 'project') { $ProjectRoot } else { Stop-PackageRecipe 'source_pins_invalid' }
		$Actual = Get-PackageProofFile $Root $Pin.path
		if ($Actual.sha256 -cne $Pin.sha256) { Stop-PackageRecipe 'source_changed' }
	}
}
function Get-PackageProgramClosure($Programs, [string] $ProjectDescriptorSha256) {
	if ($Programs -isnot [array] -or $Programs.Count -ne 2) { Stop-PackageRecipe 'programs_invalid' }
	$Closure = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Tuple in @(@{ target = 'UnrealPak'; configuration = 'Development'; receiptRoot = 'project'; receiptPath = 'Binaries/Win64/UnrealPak.target'; launch = '$(EngineDir)/Binaries/Win64/UnrealPak.exe' }, @{ target = 'BootstrapPackagedGame'; configuration = 'Shipping'; receiptRoot = 'engine'; receiptPath = 'Engine/Binaries/Win64/BootstrapPackagedGame-Win64-Shipping.target'; launch = '$(EngineDir)/Binaries/Win64/BootstrapPackagedGame-Win64-Shipping.exe' })) {
		$ProgramMatches = @($Programs | Where-Object { $_.target -ceq $Tuple.target })
		if ($ProgramMatches.Count -ne 1) { Stop-PackageRecipe 'programs_invalid' }
		$Program = $ProgramMatches[0]
		Assert-PackageProofFields $Program @('target', 'platform', 'configuration', 'architecture', 'receipt', 'version', 'launch', 'products', 'runtimeDependencies')
		if ($Program.platform -cne 'Win64' -or $Program.configuration -cne $Tuple.configuration -or $Program.architecture -cne 'x64' -or $Program.launch -cne $Tuple.launch) { Stop-PackageRecipe 'programs_invalid' }
		Assert-PackageProofFields $Program.receipt @('originRoot', 'relativePath', 'sizeBytes', 'sha256', 'payloadBase64')
		if ($Program.receipt.originRoot -cne $Tuple.receiptRoot -or $Program.receipt.relativePath -cne $Tuple.receiptPath) { Stop-PackageRecipe 'receipt_origin_invalid' }
		$Receipt = Read-PackageSealedReceipt $Program.receipt
		if ($Receipt.TargetName -cne $Tuple.target -or $Receipt.Platform -cne 'Win64' -or $Receipt.Configuration -cne $Tuple.configuration -or $Receipt.TargetType -cne 'Program' -or $Receipt.Architecture -cne 'x64' -or $Receipt.Launch -cne $Tuple.launch -or ($Receipt.Version | ConvertTo-Json -Depth 10 -Compress) -cne ($Program.version | ConvertTo-Json -Depth 10 -Compress) -or ($Receipt.BuildProducts | ConvertTo-Json -Depth 10 -Compress) -cne ($Program.products | ConvertTo-Json -Depth 10 -Compress) -or ($Receipt.RuntimeDependencies | ConvertTo-Json -Depth 10 -Compress) -cne ($Program.runtimeDependencies | ConvertTo-Json -Depth 10 -Compress)) { Stop-PackageRecipe 'receipt_invalid' }
		$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		foreach ($Product in $Receipt.BuildProducts) {
			Assert-PackageProofFields $Product @('Path', 'Type')
			if (-not $Seen.Add($Product.Path) -or $Product.Type -cnotin @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package', 'SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary')) { Stop-PackageRecipe 'products_invalid' }
			if ($Product.Path -cnotmatch '^\$\(EngineDir\)/') { Stop-PackageRecipe 'product_origin_invalid' }
			$Relative = 'Engine/' + $Product.Path.Substring(13)
			$null = Resolve-PackageProofPath ([IO.Path]::GetTempPath()) $Relative
			if ($Product.Type -cin @('SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary')) { continue }
			if (-not $Closure.ContainsKey($Relative)) { $Closure.Add($Relative, [Collections.Generic.List[string]]::new()) }
			elseif (@($Closure.Keys | Where-Object { $_ -ceq $Relative }).Count -ne 1) { Stop-PackageRecipe 'path_alias' }
			$Closure[$Relative].Add($Tuple.target + ':product')
		}
		$Seen.Clear()
		foreach ($Dependency in $Receipt.RuntimeDependencies) {
			Assert-PackageProofFields $Dependency @('Path', 'Type')
			if (-not $Seen.Add($Dependency.Path) -or $Dependency.Type -cnotin @('NonUFS', 'UFS', 'SystemNonUFS', 'DebugNonUFS')) { Stop-PackageRecipe 'runtime_invalid' }
			if ($Dependency.Path -ceq '$(ProjectDir)/AethelnOnline.uproject') {
				if ($Dependency.Type -cne 'UFS') { Stop-PackageRecipe 'runtime_invalid' }; Assert-PackageProofHash $ProjectDescriptorSha256; continue
			}
			if ($Dependency.Path -cnotmatch '^\$\(EngineDir\)/') { Stop-PackageRecipe 'runtime_invalid' }
			$Relative = 'Engine/' + $Dependency.Path.Substring(13)
			$null = Resolve-PackageProofPath ([IO.Path]::GetTempPath()) $Relative
			if ($Dependency.Type -ceq 'DebugNonUFS') { continue }
			if (-not $Closure.ContainsKey($Relative)) { $Closure.Add($Relative, [Collections.Generic.List[string]]::new()) }
			elseif (@($Closure.Keys | Where-Object { $_ -ceq $Relative }).Count -ne 1) { Stop-PackageRecipe 'path_alias' }
			$Closure[$Relative].Add($Tuple.target + ':runtime')
		}
		$LaunchRelative = 'Engine/' + $Tuple.launch.Substring(13)
		if (-not $Closure.ContainsKey($LaunchRelative) -or @($Receipt.BuildProducts | Where-Object { $_.Path -ceq $Tuple.launch -and $_.Type -ceq 'Executable' }).Count -ne 1) { Stop-PackageRecipe 'launch_missing' }
	}
	return ,$Closure
}
function Assert-PackageProgramFiles {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the complete two-Program file closure; existing supplement readers and constructors retain this exported contract.')]
	param($Files, $Closure, $BaseEntries, [string] $EngineRoot)
	if ($Files -isnot [array] -or $Files.Count -ne $Closure.Count -or $Files.Count -gt 8192) { Stop-PackageRecipe 'closure_invalid' }
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Previous = $null; $Total = [long] 0
	foreach ($File in $Files) {
		Assert-PackageProofFields $File @('engineRelativePath', 'sizeBytes', 'sha256', 'origins')
		if ($File.origins -isnot [array] -or $File.origins.Count -lt 1 -or $File.origins.Count -gt 4) { Stop-PackageRecipe 'closure_invalid' }
		if (-not $Seen.Add($File.engineRelativePath) -or -not $Closure.ContainsKey($File.engineRelativePath) -or @($Closure.Keys | Where-Object { $_ -ceq $File.engineRelativePath }).Count -ne 1 -or ($null -ne $Previous -and [StringComparer]::Ordinal.Compare($Previous, $File.engineRelativePath) -ge 0)) { Stop-PackageRecipe 'closure_invalid' }
		$Previous = $File.engineRelativePath
		if (($File.origins | Sort-Object) -join ',' -cne (($Closure[$File.engineRelativePath] | Sort-Object) -join ',')) { Stop-PackageRecipe 'closure_invalid' }
		Assert-PackageProofFile -Entry $File -Root $EngineRoot -Relative $File.engineRelativePath
		$Total += [long] $File.sizeBytes
		if ($Total -gt 137438953472) { Stop-PackageRecipe 'aggregate_bound' }
		$Overlap = @($BaseEntries | Where-Object { $_.path.Equals($File.engineRelativePath, [StringComparison]::OrdinalIgnoreCase) })
		if ($Overlap.Count -gt 1 -or ($Overlap.Count -eq 1 -and ($Overlap[0].path -cne $File.engineRelativePath -or $Overlap[0].sha256 -cne $File.sha256 -or $Overlap[0].sizeBytes -ne $File.sizeBytes))) { Stop-PackageRecipe 'base_overlap_invalid' }
	}
}
function Assert-PackageProgramManifests {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the complete loader-visible module manifest set; existing supplement readers and constructors retain this exported contract.')]
	param($Programs, $Closure, [string] $EngineRoot)
	$Required = @($Closure.Keys | Where-Object { $_.EndsWith('/UnrealPak.modules', [StringComparison]::Ordinal) })
	$Actual = [Collections.Generic.List[string]]::new()
	foreach ($Root in @('Engine/Binaries/Win64', 'Engine/Plugins', 'Engine/Platforms', 'Engine/Restricted')) {
		$Full = Resolve-PackageProofPath $EngineRoot $Root
		if (-not (Test-Path -LiteralPath $Full -PathType Container)) { continue }
		$Stack = New-Object Collections.Stack; $Stack.Push($Full)
		while ($Stack.Count) {
			foreach ($Item in Get-ChildItem -LiteralPath ($Stack.Pop()) -Force) {
				if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PackageRecipe 'manifest_invalid' }
				if ($Item.PSIsContainer) { $Stack.Push($Item.FullName) } elseif ($Item.Name.Equals('UnrealPak.modules', [StringComparison]::OrdinalIgnoreCase)) {
					$Relative = $Item.FullName.Substring($EngineRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
					if ($Required -cnotcontains $Relative) { Stop-PackageRecipe 'manifest_invalid' }
					$Actual.Add($Relative)
					$Manifest = ConvertFrom-PackageProofJson ([IO.File]::ReadAllText($Item.FullName)) 16777216
					$Program = @($Programs | Where-Object { $_.target -ceq 'UnrealPak' })[0]
					if ($Manifest.BuildId -cne $Program.version.BuildId) { Stop-PackageRecipe 'manifest_invalid' }
					foreach ($Module in $Manifest.Modules.PSObject.Properties) {
						if ($Module.Value -isnot [string] -or $Module.Value -match '[/\\:]') { Stop-PackageRecipe 'manifest_invalid' }
						$ModuleRelative = ($Relative.Substring(0, $Relative.LastIndexOf('/') + 1)) + $Module.Value
						if (-not $Closure.ContainsKey($ModuleRelative) -or @($Closure.Keys | Where-Object { $_ -ceq $ModuleRelative }).Count -ne 1) { Stop-PackageRecipe 'manifest_invalid' }
					}
				}
			}
		}
	}
	if ($Actual.Count -ne $Required.Count) { Stop-PackageRecipe 'manifest_invalid' }
}
function Read-PackageProgramSupplement([string] $Path, [string] $ExpectedHash, $Base, [string] $EngineRoot, [string] $ProjectRoot) {
	Assert-PackageProofHash $ExpectedHash
	if ([IO.Path]::GetExtension($Path) -cne '.json') { Stop-PackageRecipe 'path_invalid' }
	if (Test-Path -LiteralPath (Join-Path $EngineRoot 'Engine/Build/InstalledBuild.txt')) { Stop-PackageRecipe 'engine_changed' }
	$Size = (Get-Item -LiteralPath $Path -Force).Length
	if ($Size -le 0 -or $Size -gt 8388608) { Stop-PackageRecipe 'supplement_bound' }
	$Bytes = [IO.File]::ReadAllBytes($Path)
	if ($Bytes.Length -ne $Size -or (Get-PackageProofBytesHash $Bytes) -cne $ExpectedHash) { Stop-PackageRecipe 'supplement_changed' }
	$Reader = [IO.StreamReader]::new([IO.MemoryStream]::new($Bytes), [Text.UTF8Encoding]::new($false, $true), $true)
	try { $Raw = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
	$Record = ConvertFrom-PackageProofJson $Raw
	Assert-PackageProofFields $Record @('schemaId', 'schemaVersion', 'createdUtc', 'engineRevision', 'engineBuildVersionSha256', 'baseAttestation', 'recipe', 'provisioning', 'programs', 'files')
	Assert-PackageProofInteger -Value $Record.schemaVersion -Minimum 1 -Maximum 1
	if ($Record.schemaId -cne 'aetheln.host-program-supplement/v1' -or $Record.schemaVersion -ne 1 -or $Record.engineRevision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43') { Stop-PackageRecipe 'supplement_invalid' }
	$null = ConvertFrom-PackageProofTimestamp $Record.createdUtc
	Assert-PackageProofFields $Record.baseAttestation @('sha256', 'sizeBytes', 'fileCount')
	Assert-PackageProofInteger -Value $Record.baseAttestation.sizeBytes -Minimum 390169 -Maximum 390169; Assert-PackageProofInteger -Value $Record.baseAttestation.fileCount -Minimum 1322 -Maximum 1322
	if ($Record.baseAttestation.sha256 -cne 'a457da4e14808b85d5cc1439a920abfce114ec961e313c2684fdd57ba9385d95' -or $Record.baseAttestation.sizeBytes -ne 390169 -or $Record.baseAttestation.fileCount -ne 1322 -or $Base.sha256 -cne $Record.baseAttestation.sha256 -or @($Base.entries).Count -ne 1322) { Stop-PackageRecipe 'base_invalid' }
	Assert-PackageProofFields $Record.recipe @('id', 'programTargets', 'effectiveFlags', 'sourcePins')
	$Tuples = @('UnrealPak:Win64:Development:x64', 'BootstrapPackagedGame:Win64:Shipping:x64')
	if ($Record.recipe.programTargets -isnot [array]) { Stop-PackageRecipe 'recipe_invalid' }
	if ($Record.recipe.id -cne 'clean-targets-prebuilt-programs-v1' -or ($Record.recipe.programTargets -join ',') -cne ($Tuples -join ',')) { Stop-PackageRecipe 'recipe_invalid' }
	Assert-PackageProofFields $Record.recipe.effectiveFlags @('applyIoStoreOnDemand', 'fileServer', 'crashReporter', 'programTargets', 'bootstrap', 'zenStore', 'preBuildAgenda', 'preBuildTargets')
	foreach ($Name in @('applyIoStoreOnDemand', 'fileServer', 'crashReporter', 'zenStore')) { if ($Record.recipe.effectiveFlags.$Name -isnot [bool] -or $Record.recipe.effectiveFlags.$Name) { Stop-PackageRecipe 'unsupported_branch' } }
	if ($Record.recipe.effectiveFlags.bootstrap -isnot [bool] -or -not $Record.recipe.effectiveFlags.bootstrap) { Stop-PackageRecipe 'unsupported_branch' }
	foreach ($Name in @('programTargets', 'preBuildAgenda', 'preBuildTargets')) { if ($Record.recipe.effectiveFlags.$Name -isnot [array] -or $Record.recipe.effectiveFlags.$Name.Count -ne 0) { Stop-PackageRecipe 'unsupported_branch' } }
	Assert-PackageSourcePins -Pins $Record.recipe.sourcePins -Expected @(Get-PackageRecipeReviewedPins) -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot
	$Version = Get-PackageProofFile $EngineRoot 'Engine/Build/Build.version'
	if ($Record.engineBuildVersionSha256 -cne $Version.sha256) { Stop-PackageRecipe 'engine_changed' }
	Assert-PackageProofFields $Record.provisioning @('sourceRevision', 'projectDescriptorSha256', 'targetRulePins', 'nativeSteps', 'cleanupProof')
	if ($Record.provisioning.sourceRevision -cnotmatch '^[0-9a-f]{40}$') { Stop-PackageRecipe 'provisioning_invalid' }
	$Descriptor = Get-PackageProofFile $ProjectRoot 'AethelnOnline.uproject'
	if ($Record.provisioning.projectDescriptorSha256 -cne $Descriptor.sha256) { Stop-PackageRecipe 'context_changed' }
	Assert-PackageSourcePins -Pins $Record.provisioning.targetRulePins -Expected @(Get-PackageTargetRulePins $ProjectRoot) -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot
	Assert-PackageProofFields $Record.provisioning.cleanupProof @('supervisor', 'verified')
	if ($Record.provisioning.cleanupProof.supervisor -cne 'windows-job' -or $Record.provisioning.cleanupProof.verified -isnot [bool] -or -not $Record.provisioning.cleanupProof.verified) { Stop-PackageRecipe 'cleanup_failed' }
	Assert-PackageProvisioningSteps $Record.provisioning.nativeSteps
	$Closure = Get-PackageProgramClosure $Record.programs $Descriptor.sha256
	Assert-PackageProgramFiles -Files $Record.files -Closure $Closure -BaseEntries $Base.entries -EngineRoot $EngineRoot
	Assert-PackageProgramManifests -Programs $Record.programs -Closure $Closure -EngineRoot $EngineRoot
	return [ordered]@{ path = $Path; sha256 = $ExpectedHash; record = $Record; closure = $Closure }
}

function Initialize-PackageNativeJob {
	if ($null -ne ('Aetheln.EngineGateJob' -as [type])) { return }
	# Reuse the reviewed job primitive, never execute the gate's controlled body.
	$Path = Join-Path $PSScriptRoot '../ci/Invoke-EngineRunnerGate.ps1'
	$Tokens = $null; $Errors = $null
	$Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $Tokens, [ref] $Errors)
	$Assignments = @($Ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.AssignmentStatementAst] -and $Node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $Node.Left.VariablePath.UserPath -ceq 'EngineGateJobSource' }, $false))
	if ($Errors.Count -or $Assignments.Count -ne 1) { Stop-PackageRecipe 'supervisor_invalid' }
	$Strings = @($Assignments[0].Right.FindAll({ param($Node) $Node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $Node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true))
	if ($Strings.Count -ne 1 -or ($Strings[0] -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $Strings[0].NestedExpressions.Count -ne 0)) { Stop-PackageRecipe 'supervisor_invalid' }
	$Source = $Strings[0].Value
	if ($Source -isnot [string]) { Stop-PackageRecipe 'supervisor_invalid' }
	Add-Type -TypeDefinition $Source -Language CSharp
}
function Invoke-PackageNativeStep([string] $Executable, [string[]] $Arguments, [string] $Root, [DateTime] $DeadlineUtc) {
	$BuildInputs = Get-PackageBuildInputProof
	if ([DateTime]::UtcNow -ge $DeadlineUtc -or ($DeadlineUtc - [DateTime]::UtcNow).TotalMinutes -gt 30) { Stop-PackageRecipe 'deadline_invalid' }
	if (Test-Path -LiteralPath $Root) { Stop-PackageRecipe 'capture_exists' }
	New-Item -ItemType Directory -Path $Root | Out-Null
	$LogPath = Join-Path $Root 'build.log'; $CapturePath = Join-Path $Root 'native-result.json'; $DriverPath = Join-Path $Root 'driver.ps1'
	$ExecutableHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
	$LiteralExecutable = "'" + $Executable.Replace("'", "''") + "'"
	$LiteralArguments = '@(' + ((@($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })) -join ',') + ')'
	$LiteralLog = "'" + $LogPath.Replace("'", "''") + "'"
	$LiteralCapture = "'" + $CapturePath.Replace("'", "''") + "'"
	$Body = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$Started = [DateTime]::UtcNow.ToString('o')
`$Arguments = $LiteralArguments
`$Failure = `$null; `$NativeExit = -1
`$BuildInputs = [ordered]@{ ubtExtraArgsAbsent = [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('UBT_EXTRA_ARGS', 'Process')) }
if (-not `$BuildInputs.ubtExtraArgsAbsent) { `$Failure = 'build_inputs_set' }
else { try { & $LiteralExecutable @Arguments *> $LiteralLog; `$NativeExit = [int] `$LASTEXITCODE } catch { `$Failure = 'native_capture_failed' } }
[ordered]@{ executableSha256 = '$ExecutableHash'; arguments = `$Arguments; startedUtc = `$Started; finishedUtc = [DateTime]::UtcNow.ToString('o'); nativeExitCode = `$NativeExit; infrastructureFailure = `$Failure; buildInputs = `$BuildInputs } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LiteralCapture -Encoding UTF8
if (`$Failure -or `$NativeExit -ne 0) { exit 1 }; exit 0
"@
	[IO.File]::WriteAllText($DriverPath, $Body, [Text.UTF8Encoding]::new($false))
	Initialize-PackageNativeJob
	$Job = New-Object Aetheln.EngineGateJob; $Process = $null
	try {
		$PowerShell = (Get-Command powershell.exe -CommandType Application).Source
		$CommandLine = '"' + $PowerShell + '" -NoProfile -NonInteractive -File "' + $DriverPath + '"'
		$BuildInputs = Get-PackageBuildInputProof
		$Process = $Job.StartSuspended($PowerShell, $CommandLine, $Root)
		$Remaining = [int] [Math]::Max(0, [Math]::Min([int]::MaxValue, ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
		if (-not $Process.WaitForExit($Remaining)) { Stop-PackageRecipe 'native_timeout' }
		$Job.TerminateAndWait(5000)
		if ($Process.ExitCode -ne 0 -or [DateTime]::UtcNow -ge $DeadlineUtc) { Stop-PackageRecipe 'native_failed' }
		$Capture = ConvertFrom-PackageProofJson ([IO.File]::ReadAllText($CapturePath)) 65536
		Assert-PackageProofFields $Capture @('executableSha256', 'arguments', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure', 'buildInputs')
		Assert-PackageBuildInputProof $Capture.buildInputs
		if ($Capture.buildInputs.ubtExtraArgsAbsent -cne $BuildInputs.ubtExtraArgsAbsent) { Stop-PackageRecipe 'capture_changed' }
		if ($Capture.executableSha256 -cne $ExecutableHash -or (Get-Item -LiteralPath $LogPath).Length -gt 16777216) { Stop-PackageRecipe 'capture_changed' }
		$Step = [ordered]@{ executableSha256 = $Capture.executableSha256; arguments = @($Capture.arguments); startedUtc = $Capture.startedUtc; finishedUtc = $Capture.finishedUtc; nativeExitCode = $Capture.nativeExitCode; infrastructureFailure = $Capture.infrastructureFailure; buildInputs = $Capture.buildInputs; captureSha256 = (Get-PackageProofFile $Root 'native-result.json').sha256; logSha256 = (Get-PackageProofFile $Root 'build.log').sha256 }
		Assert-PackageNativeProof $Step $Arguments
		if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExecutableHash) { Stop-PackageRecipe 'native_changed' }
		return $Step
	} finally {
		try { $Job.TerminateAndWait(5000) } catch { Stop-PackageRecipe 'cleanup_failed' } finally { if ($null -ne $Process) { $Process.Dispose() }; $Job.Dispose() }
	}
}
function Get-PackageCleanObservation([string] $Full, [string] $EngineRoot, [string] $ProjectRoot, [string] $Type) {
	foreach ($Scope in @(@{ name = 'engine'; root = $EngineRoot }, @{ name = 'project'; root = $ProjectRoot })) {
		$Prefix = [IO.Path]::GetFullPath($Scope.root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
		if ($Full.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
			$Relative = $Full.Substring($Prefix.Length).Replace('\', '/')
			$Resolved = Resolve-PackageProofPath $Scope.root $Relative
			return [ordered]@{ root = $Scope.name; path = $Relative; type = $Type; exists = [bool] (Test-Path -LiteralPath $Resolved) }
		}
	}
	Stop-PackageRecipe 'clean_scope_invalid'
}
function Get-PackageCleanPlan([string] $LogPath, [string] $Kind, [string] $Platform, [string] $EngineRoot, [string] $ProjectRoot, $HostPaths) {
	if ((Get-Item -LiteralPath $LogPath).Length -gt 16MB) { Stop-PackageRecipe 'plan_bound' }
	$Items = [Collections.Generic.List[object]]::new(); $Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	foreach ($Line in [IO.File]::ReadLines($LogPath)) {
		if ($Line -cmatch '^    Deleting (?<path>.+)\.\.\.$') {
			$Full = $Matches.path.TrimEnd('\', '/')
			$Type = if (Test-Path -LiteralPath $Full -PathType Container) { 'directory' } else { 'file' }
			$Observation = Get-PackageCleanObservation -Full $Full -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot -Type $Type
			if (-not $Observation.exists -or -not $Seen.Add($Observation.root + '/' + $Observation.path)) { Stop-PackageRecipe 'plan_invalid' }
			$Relative = $Observation.path
			$Target = if ($Kind -ceq 'Client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
			$Application = if ($Kind -ceq 'Client') { 'UnrealClient' } else { 'UnrealServer' }
			$BinariesMatch = $Relative -cmatch ('(?:^|/)Binaries/' + [regex]::Escape($Platform) + '/[^/]+(?:/[^/]+)*$')
			$OwnedBinary = $BinariesMatch -and (Test-PackageCleanProductName -Name (Split-Path -Leaf $Full) -Phase $Kind -Platform $Platform -Configuration 'Development')
			$Intermediate = $Relative -cmatch ('(?:^|/)Intermediate/Build/' + [regex]::Escape($Platform) + '/[^/]+/(?:' + $Target + '|' + $Application + ')/(?:Development|Inc)(?:/Makefile\.bin)?$')
			$Metadata = $Relative -cin @('Intermediate/Build/SourceFileCache.bin', 'Engine/Intermediate/Build/SourceFileCache.bin') -and $Type -ceq 'file'
			if (-not ($OwnedBinary -or $Intermediate -or $Metadata)) { Stop-PackageRecipe 'clean_scope_invalid' }
			if ($Observation.root -ceq 'engine') {
				foreach ($HostPath in $HostPaths) { if ($HostPath.Equals($Relative, [StringComparison]::OrdinalIgnoreCase) -or ($Type -ceq 'directory' -and $HostPath.StartsWith($Relative + '/', [StringComparison]::OrdinalIgnoreCase))) { Stop-PackageRecipe 'clean_host_overlap' } }
			}
			$Items.Add($Observation)
			if ($Items.Count -gt 8192) { Stop-PackageRecipe 'plan_bound' }
		}
	}
	return ,@($Items)
}
function Assert-PackageCleanAbsence($Before, [string] $EngineRoot, [string] $ProjectRoot) {
	$After = foreach ($Entry in $Before) {
		$Root = if ($Entry.root -ceq 'engine') { $EngineRoot } else { $ProjectRoot }
		$Full = Resolve-PackageProofPath $Root $Entry.path
		$Observation = Get-PackageCleanObservation -Full $Full -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot -Type $Entry.type
		if ($Observation.exists) { Stop-PackageRecipe 'clean_owned_retained' }; $Observation
	}
	return ,@($After)
}
function Get-PackageCleanOwnedBinaries {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns all canonical owned binary observations for one Clean; existing packaging callers retain this exported name.')]
	param([string] $Kind, [string] $Platform, [string] $EngineRoot, [string] $ProjectRoot)
	$Results = [Collections.Generic.List[object]]::new()
	foreach ($Scope in @(@{ root = $EngineRoot; trees = @('Engine/Binaries', 'Engine/Plugins', 'Engine/Platforms', 'Engine/Restricted') }, @{ root = $ProjectRoot; trees = @('Binaries', 'Plugins', 'Platforms', 'Restricted') })) {
		foreach ($Tree in $Scope.trees) {
			$Full = Resolve-PackageProofPath $Scope.root $Tree
			if (-not (Test-Path -LiteralPath $Full -PathType Container)) { continue }
			$Stack = New-Object Collections.Stack; $Stack.Push($Full)
			while ($Stack.Count) {
				$Directory = $Stack.Pop()
				foreach ($Item in Get-ChildItem -LiteralPath $Directory -Force) {
					if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PackageRecipe 'clean_scope_invalid' }
					$InBinaries = $Item.FullName.Replace('\', '/') -cmatch ('(?:^|/)Binaries/' + [regex]::Escape($Platform) + '/')
					if ($InBinaries -and (Test-PackageCleanProductName -Name $Item.Name -Phase $Kind -Platform $Platform -Configuration 'Development')) {
						$Type = if ($Item.PSIsContainer) { 'directory' } else { 'file' }
						$Results.Add((Get-PackageCleanObservation -Full $Item.FullName -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot -Type $Type))
						if ($Results.Count -gt 8192) { Stop-PackageRecipe 'plan_bound' }
					}
					if ($Item.PSIsContainer) { $Stack.Push($Item.FullName) }
				}
			}
		}
	}
	return ,@($Results)
}
function Assert-PackageRecipePayloads {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates both client and server payload sets in one provenance record; existing gate and packaging callers retain this exported contract.')]
	param($Provenance, [string] $ClientRoot, [string] $ServerRoot)
	Assert-PackageRecipeProvenance $Provenance
	$Recipe = Get-PackageProofMember (Get-PackageProofMember $Provenance 'build') 'packageRecipe'
	if ($null -eq $Recipe) { Stop-PackageRecipe 'proof_missing' }
	foreach ($Kind in @('client', 'server')) {
		$Root = if ($Kind -ceq 'client') { $ClientRoot } else { $ServerRoot }
		$Proof = $Recipe.$Kind
		foreach ($Name in @('discovery', 'clean', 'compile')) {
			$Step = if ($Name -ceq 'discovery') { $Proof.clean.discovery.nativeStep } else { $Proof.$Name }
			$Capture = Get-PackageProofFile $Root "Proof/$Name/native-result.json"
			$Log = Get-PackageProofFile $Root "Proof/$Name/build.log"
			if ($Capture.sha256 -cne $Step.captureSha256 -or $Log.sha256 -cne $Step.logSha256) { Stop-PackageRecipe 'capture_changed' }
			$Actual = ConvertFrom-PackageProofJson ([IO.File]::ReadAllText((Resolve-PackageProofPath $Root "Proof/$Name/native-result.json"))) 65536
			Assert-PackageProofFields $Actual @('executableSha256', 'arguments', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure', 'buildInputs')
			Assert-PackageBuildInputProof $Actual.buildInputs
			if ($Actual.buildInputs.ubtExtraArgsAbsent -cne $Step.buildInputs.ubtExtraArgsAbsent) { Stop-PackageRecipe 'capture_changed' }
			foreach ($Field in @('executableSha256', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure')) { if ($Actual.$Field -cne $Step.$Field) { Stop-PackageRecipe 'capture_changed' } }
			if (($Actual.arguments -join "`n") -cne ($Step.arguments -join "`n")) { Stop-PackageRecipe 'capture_changed' }
		}
		$Plan = Get-PackageProofFile $Root 'Proof/discovery/clean-plan.json'
		if ($Plan.sha256 -cne $Proof.clean.discovery.planSha256) { Stop-PackageRecipe 'plan_changed' }
		$Planned = @(ConvertFrom-PackageProofJson ([IO.File]::ReadAllText((Resolve-PackageProofPath $Root 'Proof/discovery/clean-plan.json'))))
		$Before = @($Proof.clean.ownedRemoval.filesBefore) + @($Proof.clean.ownedRemoval.directoriesBefore)
		if (($Planned | Sort-Object root, path, type | ConvertTo-Json -Depth 4 -Compress) -cne ($Before | Sort-Object root, path, type | ConvertTo-Json -Depth 4 -Compress)) { Stop-PackageRecipe 'plan_changed' }
		foreach ($Product in $Proof.products) { Assert-PackageProofFile -Entry $Product -Root $Root -Relative $Product.payloadPath }
		Assert-PackageProofFile -Entry $Proof.targetReceipt -Root $Root -Relative 'Proof/target.target'
		$Tools = $Proof.engineIdentity.selectedTools
		$CompileLog = Resolve-PackageProofPath $Root 'Proof/compile/build.log'
		foreach ($Name in @('compiler', 'resourceCompiler', 'linuxCompiler')) {
			$Tool = $Tools.$Name
			if ($null -eq $Tool) { continue }
			$Label = if ($Name -ceq 'compiler') { 'Compiler' } elseif ($Name -ceq 'resourceCompiler') { 'Resource Compiler' } else { 'Clang Compiler' }
			$SelectedPath = Resolve-PackageCompileTool -LogPath $CompileLog -Label $Label -ExecutableName ([IO.Path]::GetFileName($Tool.path))
			if ($SelectedPath -cne $Tool.path) { Stop-PackageRecipe 'tool_changed' }
			Assert-PackageProofFile -Entry $Tool -Root (Split-Path -Parent $SelectedPath) -Relative (Split-Path -Leaf $SelectedPath)
		}
	}
}

function Assert-PackageProvisioningSteps {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the exact four real Clean and Compile steps for two Programs; existing producer and supplement callers retain this exported contract.')]
	param($Steps)
	if ($Steps -isnot [array] -or $Steps.Count -ne 4) { Stop-PackageRecipe 'provisioning_invalid' }
	foreach ($Target in @('UnrealPak', 'BootstrapPackagedGame')) {
		$Previous = [DateTime]::MinValue
		foreach ($Operation in @('clean', 'compile')) {
			$Entries = @($Steps | Where-Object { $_.target -ceq $Target -and $_.operation -ceq $Operation })
			if ($Entries.Count -ne 1) { Stop-PackageRecipe 'provisioning_invalid' }
			$Entry = $Entries[0]
			Assert-PackageProofFields $Entry @('target', 'operation', 'nativeStep', 'capture', 'log')
			$Step = $Entry.nativeStep
			Assert-PackageProofFields $Step @('executableSha256', 'arguments', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure', 'buildInputs', 'captureSha256', 'logSha256')
			Assert-PackageBuildInputProof $Step.buildInputs
			Assert-PackageNativeArgumentBoundaries $Step.arguments
			foreach ($Name in @('executableSha256', 'captureSha256', 'logSha256')) { Assert-PackageProofHash $Step.$Name }
			$ExecutableRelative = if ($Operation -ceq 'clean') { 'Engine/Build/BatchFiles/Clean.bat' } else { 'Engine/Build/BatchFiles/Build.bat' }
			$ExecutablePin = @(Get-PackageRecipeReviewedPins | Where-Object { $_.path -ceq $ExecutableRelative })[0]
			if ($Step.executableSha256 -cne $ExecutablePin.sha256 -or @($Step.arguments | Where-Object { $_ -imatch '^-(?:dryrun|skipbuild|nobuild|skipprebuildtargets|skiprulescompile)(?:=|$)' }).Count -ne 0) { Stop-PackageRecipe 'provisioning_invalid' }
			if ($Operation -ceq 'compile') { $null = Get-PackageCompileArgumentLimit $Step.arguments }
			$Start = ConvertFrom-PackageProofTimestamp $Step.startedUtc; $Finish = ConvertFrom-PackageProofTimestamp $Step.finishedUtc
			if ($Start -lt $Previous -or $Finish -lt $Start -or $Step.nativeExitCode -isnot [int] -or $Step.nativeExitCode -ne 0 -or $null -ne $Step.infrastructureFailure -or $Step.arguments -isnot [array] -or $Step.arguments.Count -lt 3 -or $Step.arguments[0] -cne $Target -or $Step.arguments[1] -cne 'Win64' -or $Step.arguments[2] -cne ($(if ($Target -ceq 'UnrealPak') { 'Development' } else { 'Shipping' }))) { Stop-PackageRecipe 'provisioning_invalid' }
			$Previous = $Finish
			foreach ($Name in @('capture', 'log')) {
				$Seal = $Entry.$Name
				Assert-PackageProofFields $Seal @('sizeBytes', 'sha256', 'payloadBase64')
				Assert-PackageProofInteger -Value $Seal.sizeBytes -Minimum 1 -Maximum 8388608; Assert-PackageProofHash $Seal.sha256
				if ($Seal.payloadBase64 -isnot [string] -or $Seal.payloadBase64.Length -gt 11184812) { Stop-PackageRecipe 'provisioning_invalid' }
				try { $Bytes = [Convert]::FromBase64String($Seal.payloadBase64) } catch { Stop-PackageRecipe 'provisioning_invalid' }
				$ExpectedHash = if ($Name -ceq 'capture') { $Step.captureSha256 } else { $Step.logSha256 }
				if ($Bytes.Length -ne $Seal.sizeBytes -or $Seal.sha256 -cne $ExpectedHash -or (Get-PackageProofBytesHash $Bytes) -cne $ExpectedHash) { Stop-PackageRecipe 'provisioning_invalid' }
				if ($Name -ceq 'capture') {
					$Raw = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes).TrimStart([char] 0xfeff)
					$Capture = ConvertFrom-PackageProofJson $Raw 65536
					Assert-PackageProofFields $Capture @('executableSha256', 'arguments', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure', 'buildInputs')
					Assert-PackageBuildInputProof $Capture.buildInputs
					if ($Capture.buildInputs.ubtExtraArgsAbsent -cne $Step.buildInputs.ubtExtraArgsAbsent) { Stop-PackageRecipe 'provisioning_invalid' }
					foreach ($Field in @('executableSha256', 'startedUtc', 'finishedUtc', 'nativeExitCode', 'infrastructureFailure')) { if ($Capture.$Field -cne $Step.$Field) { Stop-PackageRecipe 'provisioning_invalid' } }
					if (($Capture.arguments -join "`n") -cne ($Step.arguments -join "`n")) { Stop-PackageRecipe 'provisioning_invalid' }
				}
			}
		}
	}
}
function Resolve-PackageCompileTool([string] $LogPath, [string] $Label, [string] $ExecutableName) {
	if ((Get-Item -LiteralPath $LogPath).Length -gt 16MB) { Stop-PackageRecipe 'compile_log_bound' }
	$Pattern = if ($Label -ceq 'Clang Compiler') { '^\s*Using Clang compiler [^(]+\((?<path>.+' + [regex]::Escape($ExecutableName) + ')\)\s*$' } else { '^\s*' + [regex]::Escape($Label) + ':\s+(?<path>.+' + [regex]::Escape($ExecutableName) + ')\s*$' }
	$Candidates = @([IO.File]::ReadLines($LogPath) | ForEach-Object { if ($_ -match $Pattern) { $Matches.path.Trim() } } | Sort-Object -Unique)
	if ($Candidates.Count -ne 1 -or $Candidates[0] -cnotmatch '^[A-Za-z]:\\[^\x00-\x1f]+$' -or $Candidates[0].Substring(2).Contains(':') -or @($Candidates[0].Substring(3).Split('\') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0 -or -not (Test-Path -LiteralPath $Candidates[0] -PathType Leaf)) { Stop-PackageRecipe 'compile_tool_unproven' }
	$Drive = New-Object IO.DriveInfo ($Candidates[0].Substring(0, 3))
	if ($Drive.DriveType -ne [IO.DriveType]::Fixed) { Stop-PackageRecipe 'compile_tool_unproven' }
	$Probe = $Candidates[0]
	while ($Probe) {
		if ((Get-Item -LiteralPath $Probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-PackageRecipe 'compile_tool_unproven' }
		$Next = Split-Path -Parent $Probe
		if (-not $Next -or $Next -eq $Probe) { break }; $Probe = $Next
	}
	return (Resolve-Path -LiteralPath $Candidates[0]).Path
}
function New-PackageCleanPhase {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs mandatory fixed native steps only inside the already admitted owned phase; optional skipping would invalidate required Clean and cleanup evidence.')]
	param([string] $Kind, [string] $EngineRoot, [string] $ProjectRoot, [string] $ArchiveRoot, [string] $Revision, $RunIdentity, [DateTime] $DeadlineUtc, $Base, $Supplement, [scriptblock] $AssertStable, $CompileResources)
	Assert-PackageCompileResources $CompileResources $false
	$Target = if ($Kind -ceq 'Client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
	$Platform = if ($Kind -ceq 'Client') { 'Win64' } else { 'Linux' }
	$Project = Resolve-PackageProofPath $ProjectRoot 'AethelnOnline.uproject'
	$CleanExecutable = Resolve-PackageProofPath $EngineRoot 'Engine/Build/BatchFiles/Clean.bat'
	$CompileExecutable = Resolve-PackageProofPath $EngineRoot 'Engine/Build/BatchFiles/Build.bat'
	$CleanArguments = @($Target, $Platform, 'Development', $Project, '-WaitMutex')
	$DiscoveryRoot = Join-Path $ArchiveRoot 'Proof/discovery'
	& $AssertStable
	$Discovery = Invoke-PackageNativeStep -Executable $CleanExecutable -Arguments ($CleanArguments + '-DryRun') -Root $DiscoveryRoot -DeadlineUtc $DeadlineUtc
	& $AssertStable
	$HostPaths = @($Base.entries | ForEach-Object { $_.path }) + @($Supplement.closure.Keys)
	$Plan = Get-PackageCleanPlan -LogPath (Join-Path $DiscoveryRoot 'build.log') -Kind $Kind -Platform $Platform -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot -HostPaths $HostPaths
	foreach ($Entry in (Get-PackageCleanOwnedBinaries -Kind $Kind -Platform $Platform -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot)) {
		if (@($Plan | Where-Object { $_.root -ceq $Entry.root -and $_.path -ceq $Entry.path }).Count -eq 0) { $Plan += $Entry }
	}
	$ExpectedReceipt = "Binaries/$Platform/$Target.target"
	if (@($Plan | Where-Object { $_.root -ceq 'project' -and $_.path -ceq $ExpectedReceipt }).Count -eq 0) {
		$Plan += Get-PackageCleanObservation -Full (Resolve-PackageProofPath $ProjectRoot $ExpectedReceipt) -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot -Type 'file'
	}
	$PlanPath = Join-Path $DiscoveryRoot 'clean-plan.json'
	ConvertTo-Json -InputObject @($Plan) -Depth 4 | Set-Content -LiteralPath $PlanPath -Encoding UTF8
	$Clean = Invoke-PackageNativeStep -Executable $CleanExecutable -Arguments $CleanArguments -Root (Join-Path $ArchiveRoot 'Proof/clean') -DeadlineUtc $DeadlineUtc
	$After = Assert-PackageCleanAbsence -Before $Plan -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot
	$RemainingOwned = Get-PackageCleanOwnedBinaries -Kind $Kind -Platform $Platform -EngineRoot $EngineRoot -ProjectRoot $ProjectRoot
	if ($RemainingOwned.Count -ne 0) { Stop-PackageRecipe 'clean_owned_retained' }
	& $AssertStable
	$Roots = @([ordered]@{ root = 'engine'; path = 'Engine' }, [ordered]@{ root = 'project'; path = '.' })
	$Clean['ownedRemoval'] = [ordered]@{ predicatePins = @($Supplement.record.recipe.sourcePins | Where-Object { $_.path -match 'CleanMode|UEBuildPlatform|UEBuildTarget|UEBuildWindows|UEBuildLinux|TargetRules' }); prefixes = @($(if ($Kind -ceq 'Client') { 'UnrealClient' } else { 'UnrealServer' }), $Target); suffixes = @('', "-$Platform-Development"); roots = $Roots; filesBefore = @($Plan | Where-Object { $_.type -ceq 'file' }); filesAfter = @($After | Where-Object { $_.type -ceq 'file' }); directoriesBefore = @($Plan | Where-Object { $_.type -ceq 'directory' }); directoriesAfter = @($After | Where-Object { $_.type -ceq 'directory' }) }
	$Clean['discovery'] = [ordered]@{ nativeStep = $Discovery; planSha256 = (Get-PackageProofFile $DiscoveryRoot 'clean-plan.json').sha256 }
	$CompileResources.recheck = Get-PackageResourceSample @{ engine = $EngineRoot; project = $ProjectRoot; archive = $ArchiveRoot }
	Assert-PackageCompileResources $CompileResources
	$CompileArguments = @($Target, $Platform, 'Development', $Project, '-WaitMutex', '-NoHotReloadFromIDE', '-NoEngineChanges', '-Verbose', "-MaxParallelActions=$($CompileResources.effectiveActionLimit)")
	$Compile = Invoke-PackageNativeStep -Executable $CompileExecutable -Arguments $CompileArguments -Root (Join-Path $ArchiveRoot 'Proof/compile') -DeadlineUtc $DeadlineUtc
	& $AssertStable
	$SelectedTools = [ordered]@{ compiler = $null; resourceCompiler = $null; linuxCompiler = $null }
	$CompileLog = Join-Path $ArchiveRoot 'Proof/compile/build.log'
	foreach ($Name in $(if ($Kind -ceq 'Client') { @('compiler', 'resourceCompiler') } else { @('linuxCompiler') })) {
		$Label = if ($Name -ceq 'compiler') { 'Compiler' } elseif ($Name -ceq 'resourceCompiler') { 'Resource Compiler' } else { 'Clang Compiler' }
		$ExecutableName = if ($Name -ceq 'compiler') { 'cl.exe' } elseif ($Name -ceq 'resourceCompiler') { 'rc.exe' } else { 'clang++.exe' }
		$Path = Resolve-PackageCompileTool -LogPath $CompileLog -Label $Label -ExecutableName $ExecutableName
		$File = Get-PackageProofFile (Split-Path -Parent $Path) (Split-Path -Leaf $Path)
		$SelectedTools[$Name] = [ordered]@{ path = $Path; sizeBytes = $File.sizeBytes; sha256 = $File.sha256 }
	}
	$Seal = Get-PackageReceiptSeal $ProjectRoot $ExpectedReceipt
	$Receipt = Read-PackageSealedReceipt $Seal
	$Products = [Collections.Generic.List[object]]::new(); $Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); $Total = [long] 0
	New-Item -ItemType Directory -Path (Join-Path $ArchiveRoot 'Proof/products') | Out-Null
	foreach ($Product in $Receipt.BuildProducts) {
		Assert-PackageProofFields $Product @('Path', 'Type')
		if (-not $Seen.Add($Product.Path) -or $Product.Type -cnotin @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package', 'SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary')) { Stop-PackageRecipe 'products_invalid' }
		if ($Product.Path.StartsWith('$(ProjectDir)/', [StringComparison]::Ordinal)) { $Root = $ProjectRoot; $Relative = $Product.Path.Substring(14) }
		elseif ($Product.Path.StartsWith('$(EngineDir)/', [StringComparison]::Ordinal)) { $Root = $EngineRoot; $Relative = 'Engine/' + $Product.Path.Substring(13) }
		else { Stop-PackageRecipe 'product_origin_invalid' }
		$Metadata = Get-PackageProofFile $Root $Relative
		$Total += $Metadata.sizeBytes; if ($Total -gt 137438953472 -or $Products.Count -ge 8192) { Stop-PackageRecipe 'aggregate_bound' }
		$PayloadPath = 'Proof/products/{0:D4}.product' -f $Products.Count
		Copy-Item -LiteralPath (Resolve-PackageProofPath $Root $Relative) -Destination (Resolve-PackageProofPath $ArchiveRoot $PayloadPath)
		Assert-PackageProofFile -Entry $Metadata -Root $ArchiveRoot -Relative $PayloadPath
		$Products.Add([ordered]@{ receiptPath = $Product.Path; type = $Product.Type; payloadPath = $PayloadPath; sizeBytes = $Metadata.sizeBytes; sha256 = $Metadata.sha256 })
	}
	Copy-Item -LiteralPath (Resolve-PackageProofPath $ProjectRoot $ExpectedReceipt) -Destination (Join-Path $ArchiveRoot 'Proof/target.target')
	$Proof = [ordered]@{ schemaId = 'aetheln.clean-target-phase/v1'; schemaVersion = 1; runIdentity = $RunIdentity; sourceIdentity = [ordered]@{ revision = $Revision; projectDescriptorSha256 = (Get-PackageProofFile $ProjectRoot 'AethelnOnline.uproject').sha256; targetRulePins = @(Get-PackageTargetRulePins $ProjectRoot) }; engineIdentity = [ordered]@{ revision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'; buildVersionSha256 = (Get-PackageProofFile $EngineRoot 'Engine/Build/Build.version').sha256; selectedTools = $SelectedTools }; hostProof = [ordered]@{ baseAttestationSha256 = $Base.sha256; supplementSha256 = $Supplement.sha256 }; phase = $Kind.ToLowerInvariant(); target = $Target; platform = $Platform; configuration = 'Development'; clean = $Clean; compile = $Compile; targetReceipt = $Seal; products = @($Products); stability = [ordered]@{ sourceUnchanged = $true; baseUnchanged = $true; supplementUnchanged = $true }; cleanupProof = [ordered]@{ supervisor = 'windows-job'; verified = $true } }
	$Proof['compileResources'] = $CompileResources
	$Parsed = ConvertFrom-PackageProofJson ($Proof | ConvertTo-Json -Depth 32 -Compress)
	Assert-PackageCleanPhaseProof -Proof $Parsed -Kind $Kind.ToLowerInvariant() -Revision $Revision -BaseHash $Base.sha256 -SupplementHash $Supplement.sha256
	return $Parsed
}

function New-PackageProgramSupplementRecord {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory record from separately owned native evidence and read-only revalidation; it does not provision, adopt or publish.')]
	param([string] $EngineRoot, [string] $ProvisioningProjectRoot, [string] $SourceRevision, $Base, $NativeSteps, $CleanupProof, [scriptblock] $AssertBase)
	# This constructor does not provision, attest, adopt or publish anything.
	# The separately authorised operator supplies actual sealed native captures;
	# packaging only reads an explicitly selected external record/hash.
	if ($SourceRevision -cnotmatch '^[0-9a-f]{40}$' -or $Base.sha256 -cne 'a457da4e14808b85d5cc1439a920abfce114ec961e313c2684fdd57ba9385d95' -or @($Base.entries).Count -ne 1322) { Stop-PackageRecipe 'base_invalid' }
	Assert-PackageProofFields $CleanupProof @('supervisor', 'verified')
	if ($CleanupProof.supervisor -cne 'windows-job' -or $CleanupProof.verified -isnot [bool] -or -not $CleanupProof.verified -or $null -eq $AssertBase) { Stop-PackageRecipe 'cleanup_failed' }
	& $AssertBase
	Assert-PackageProvisioningSteps $NativeSteps
	$Pins = @(Get-PackageRecipeReviewedPins)
	Assert-PackageSourcePins -Pins $Pins -Expected $Pins -EngineRoot $EngineRoot -ProjectRoot $ProvisioningProjectRoot
	$Programs = foreach ($Tuple in @(@{ target = 'UnrealPak'; configuration = 'Development'; root = 'project'; path = 'Binaries/Win64/UnrealPak.target' }, @{ target = 'BootstrapPackagedGame'; configuration = 'Shipping'; root = 'engine'; path = 'Engine/Binaries/Win64/BootstrapPackagedGame-Win64-Shipping.target' })) {
		$Root = if ($Tuple.root -ceq 'project') { $ProvisioningProjectRoot } else { $EngineRoot }
		$Seal = Get-PackageReceiptSeal $Root $Tuple.path
		$Seal['originRoot'] = $Tuple.root
		$Receipt = Read-PackageSealedReceipt $Seal
		$Compile = @($NativeSteps | Where-Object { $_.target -ceq $Tuple.target -and $_.operation -ceq 'compile' })[0]
		$WriteTime = (Get-Item -LiteralPath (Resolve-PackageProofPath $Root $Tuple.path)).LastWriteTimeUtc
		if ($WriteTime -lt (ConvertFrom-PackageProofTimestamp $Compile.nativeStep.startedUtc) -or $WriteTime -gt (ConvertFrom-PackageProofTimestamp $Compile.nativeStep.finishedUtc)) { Stop-PackageRecipe 'receipt_invalid' }
		[ordered]@{ target = $Tuple.target; platform = 'Win64'; configuration = $Tuple.configuration; architecture = 'x64'; receipt = $Seal; version = $Receipt.Version; launch = $Receipt.Launch; products = @($Receipt.BuildProducts); runtimeDependencies = @($Receipt.RuntimeDependencies) }
	}
	$Descriptor = Get-PackageProofFile $ProvisioningProjectRoot 'AethelnOnline.uproject'
	$ParsedPrograms = ConvertFrom-PackageProofJson (ConvertTo-Json -InputObject @($Programs) -Depth 16 -Compress)
	$Closure = Get-PackageProgramClosure $ParsedPrograms $Descriptor.sha256
	$Sorted = [string[]] @($Closure.Keys); [Array]::Sort($Sorted, [StringComparer]::Ordinal)
	$Files = foreach ($Relative in $Sorted) { $File = Get-PackageProofFile $EngineRoot $Relative; [ordered]@{ engineRelativePath = $Relative; sizeBytes = $File.sizeBytes; sha256 = $File.sha256; origins = @($Closure[$Relative] | Sort-Object) } }
	$ParsedFiles = ConvertFrom-PackageProofJson (ConvertTo-Json -InputObject @($Files) -Depth 8 -Compress)
	Assert-PackageProgramFiles -Files $ParsedFiles -Closure $Closure -BaseEntries $Base.entries -EngineRoot $EngineRoot
	Assert-PackageProgramManifests -Programs $ParsedPrograms -Closure $Closure -EngineRoot $EngineRoot
	& $AssertBase
	return [ordered]@{
		schemaId = 'aetheln.host-program-supplement/v1'; schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); engineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'; engineBuildVersionSha256 = (Get-PackageProofFile $EngineRoot 'Engine/Build/Build.version').sha256
		baseAttestation = [ordered]@{ sha256 = $Base.sha256; sizeBytes = 390169; fileCount = 1322 }
		recipe = [ordered]@{ id = 'clean-targets-prebuilt-programs-v1'; programTargets = @('UnrealPak:Win64:Development:x64', 'BootstrapPackagedGame:Win64:Shipping:x64'); effectiveFlags = [ordered]@{ applyIoStoreOnDemand = $false; fileServer = $false; crashReporter = $false; programTargets = @(); bootstrap = $true; zenStore = $false; preBuildAgenda = @(); preBuildTargets = @() }; sourcePins = $Pins }
		provisioning = [ordered]@{ sourceRevision = $SourceRevision; projectDescriptorSha256 = $Descriptor.sha256; targetRulePins = @(Get-PackageTargetRulePins $ProvisioningProjectRoot); nativeSteps = @($NativeSteps); cleanupProof = $CleanupProof }
		programs = $ParsedPrograms; files = $ParsedFiles
	}
}
