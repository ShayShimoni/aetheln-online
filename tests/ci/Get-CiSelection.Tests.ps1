[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts\ci\Get-CiSelection.ps1'
. $SourceScript

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	$Rejected = $false
	try { & $Action } catch { $Rejected = $_.Exception.Message.StartsWith($Reason, [StringComparison]::Ordinal) }
	Assert-True $Rejected "Expected rejection '$Reason'."
}

function ConvertTo-RawBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The fixture emits an exact byte stream for all supplied raw tokens.')]
	param([string[]] $Tokens, [switch] $Truncate)
	$Stream = New-Object IO.MemoryStream
	foreach ($Token in $Tokens) {
		$Bytes = [Text.Encoding]::UTF8.GetBytes($Token); $Stream.Write($Bytes, 0, $Bytes.Length)
		if (-not $Truncate) { $Stream.WriteByte(0) }
	}
	return ,$Stream.ToArray()
}

function New-RawRecord {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs in-memory fixture tokens and changes no external state.')]
	param([string] $Status, [string] $OldPath, [string] $NewPath = $OldPath)
	$Zero = '0' * 40; $One = '1' * 40; $Two = '2' * 40
	switch ($Status.Substring(0,1)) {
		'A' { return @("`:000000 100644 $Zero $Two $Status", $NewPath) }
		'D' { return @("`:100644 000000 $One $Zero $Status", $OldPath) }
		'R' { return @("`:100644 100644 $One $Two $Status", $OldPath, $NewPath) }
		'C' { return @("`:100644 100644 $One $Two $Status", $OldPath, $NewPath) }
		default { return @("`:100644 100644 $One $Two $Status", $OldPath) }
	}
}

# The four event variants are strict discriminated unions. Unknown properties,
# ambiguous caller identities, and an unaccepted PR controller are rejected.
$Base = '1' * 40; $Head = '2' * 40; $Merge = '3' * 40
$RunId = '35484524291'; $RunAttempt = [long] 2
foreach ($Context in @(
	[pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$Base;headRevision=$Head;workflowRevision=$Merge;controllerRevision=$Base},
	[pscustomobject][ordered]@{kind='push';runId=$RunId;runAttempt=$RunAttempt;beforeRevision=$Base;afterRevision=$Head;controllerRevision=$Head},
	[pscustomobject][ordered]@{kind='schedule';runId=$RunId;runAttempt=$RunAttempt;revision=$Head;controllerRevision=$Head},
	[pscustomobject][ordered]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='pull_request';baseRevision=$Base;headRevision=$Head;workflowRevision=$Merge;revision=$null;controllerRevision=$Base},
	[pscustomobject][ordered]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='push';baseRevision=$Base;headRevision=$Head;workflowRevision=$Head;revision=$null;controllerRevision=$Head},
	[pscustomobject][ordered]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='schedule';baseRevision=$null;headRevision=$null;workflowRevision=$Head;revision=$Head;controllerRevision=$Head}
)) { Assert-CiSelectionContext $Context | Out-Null }
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$Base;headRevision=$Head;workflowRevision=$Merge;controllerRevision=$Head}) } 'context_controller_not_accepted_base'
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='push';runId=$RunId;runAttempt=$RunAttempt;beforeRevision=$Base;afterRevision=$Head;controllerRevision=$Head;extra=$true}) } 'context_schema_invalid'
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='schedule';baseRevision=$Base;headRevision=$null;workflowRevision=$Head;revision=$Head;controllerRevision=$Head}) } 'context_revision_relationship_invalid'
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='pull_request';baseRevision=$Base;headRevision=$Head;workflowRevision=$null;revision=$null;controllerRevision=$Base}) } 'context_revision_relationship_invalid'
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='schedule';runAttempt=$RunAttempt;revision=$Head;controllerRevision=$Head}) } 'context_schema_invalid'
Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='schedule';runId=$RunId;revision=$Head;controllerRevision=$Head}) } 'context_schema_invalid'
foreach ($InvalidRunId in @('', '0', '01', 'abc', ('9' * 20), [long] 1)) {
	Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='schedule';runId=$InvalidRunId;runAttempt=$RunAttempt;revision=$Head;controllerRevision=$Head}) } 'context_run_identity_invalid'
}
foreach ($InvalidRunAttempt in @([long] 0, [long] -1, '1', 1.0)) {
	Assert-Rejected { Assert-CiSelectionContext ([pscustomobject]@{kind='schedule';runId=$RunId;runAttempt=$InvalidRunAttempt;revision=$Head;controllerRevision=$Head}) } 'context_run_identity_invalid'
}
Assert-UniqueJsonProperties '{"kind":"push","beforeRevision":null}'
Assert-Rejected { Assert-UniqueJsonProperties '{"kind":"push","\u006bind":"schedule"}' } 'context_schema_invalid'

# The current-attempt anchor is generated from exactly 32 random bytes, is
# closed and canonical, and cannot be replayed against another run attempt.
$AnchorContext = [pscustomobject][ordered]@{kind='schedule';runId=$RunId;runAttempt=$RunAttempt;revision=$Head;controllerRevision=$Head}
$Anchor = New-CiSelectionAttemptAnchor $AnchorContext { return ,([byte[]] (1..32)) }
Assert-True (($Anchor.PSObject.Properties.Name -join ',') -ceq 'schemaVersion,runId,runAttempt,nonce') 'Attempt-anchor schema should be exact and ordered.'
Assert-True ($Anchor.schemaVersion -ceq 'aetheln.current-attempt-anchor/v1' -and $Anchor.runId -ceq $RunId -and $Anchor.runAttempt -eq $RunAttempt) 'Attempt anchor should bind the canonical current run identity.'
Assert-True ($Anchor.nonce -ceq '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20') 'Injected focused-test bytes should produce the exact lowercase nonce.'
Assert-CiSelectionAttemptAnchor $Anchor $AnchorContext | Out-Null
Assert-Rejected { New-CiSelectionAttemptAnchor $AnchorContext { throw 'fixture_rng_failure' } } 'attempt_anchor_rng_failed'
Assert-Rejected { New-CiSelectionAttemptAnchor $AnchorContext { return ,([byte[]]::new(31)) } } 'attempt_anchor_rng_invalid'
Assert-Rejected { New-CiSelectionAttemptAnchor $AnchorContext { return ,([byte[]]::new(33)) } } 'attempt_anchor_rng_invalid'
Assert-Rejected { New-CiSelectionAttemptAnchor $AnchorContext { return ,([byte[]]::new(32)) } } 'attempt_anchor_nonce_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{runId=$RunId;runAttempt=$RunAttempt;nonce=$Anchor.nonce}) $AnchorContext } 'attempt_anchor_schema_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v2';runId=$RunId;runAttempt=$RunAttempt;nonce=$Anchor.nonce}) $AnchorContext } 'attempt_anchor_schema_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v1';runId=$RunId;runAttempt=$RunAttempt;nonce=('1' * 62)}) $AnchorContext } 'attempt_anchor_nonce_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v1';runId=$RunId;runAttempt=$RunAttempt;nonce=('0' * 64)}) $AnchorContext } 'attempt_anchor_nonce_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v1';runId=$RunId;runAttempt=$RunAttempt;nonce=$Anchor.nonce.ToUpperInvariant()}) $AnchorContext } 'attempt_anchor_nonce_invalid'
Assert-Rejected { Assert-CiSelectionAttemptAnchor ([pscustomobject][ordered]@{schemaVersion='aetheln.current-attempt-anchor/v1';runId=$RunId;runAttempt=$RunAttempt;nonce=(('g' * 63) + '1')}) $AnchorContext } 'attempt_anchor_nonce_invalid'
$ReplayContext = [pscustomobject][ordered]@{kind='schedule';runId=$RunId;runAttempt=([long] $RunAttempt + 1);revision=$Head;controllerRevision=$Head}
Assert-Rejected { Assert-CiSelectionAttemptAnchor $Anchor $ReplayContext } 'attempt_anchor_context_mismatch'
Assert-Rejected { New-CiSelectionReport $ReplayContext $RepositoryRoot -AttemptAnchor $Anchor } 'attempt_anchor_context_mismatch'

$RejectedContextRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-selector-context-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $RejectedContextRoot -Force
try {
	$RejectedContextPath = Join-Path $RejectedContextRoot 'context.json'
	$RejectedOutputPath = Join-Path $RejectedContextRoot 'report.json'
	[IO.File]::WriteAllText($RejectedContextPath, '{"kind":"schedule","runAttempt":2,"revision":"2222222222222222222222222222222222222222","controllerRevision":"2222222222222222222222222222222222222222"}', $script:Utf8NoBom)
	$PreviousErrorAction = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
	try { $RejectedOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SourceScript -ContextJson $RejectedContextPath -OutputPath $RejectedOutputPath -RepositoryRoot $RepositoryRoot 2>&1 | ForEach-Object { "$_" }); $RejectedExitCode = $LASTEXITCODE }
	finally { $ErrorActionPreference = $PreviousErrorAction }
	Assert-True ($RejectedExitCode -ne 0 -and -not (Test-Path -LiteralPath $RejectedOutputPath)) "A missing current-run identity must fail without publishing a conservative report: $($RejectedOutput -join ' ')"
} finally {
	if (Test-Path -LiteralPath $RejectedContextRoot) { Remove-Item -LiteralPath $RejectedContextRoot -Recurse -Force }
}

# Raw -z parsing never applies C-style quoting and therefore preserves every
# legal byte sequence exactly, including whitespace and leading dashes.
$Names = @("tab`tname.ps1", "line`nname.ps1", 'quote"name.ps1', 'slash\name.ps1', ('unicod' + [char]0xE9 + '.ps1'), '-leading.ps1')
$Tokens = New-Object System.Collections.Generic.List[string]
foreach ($Name in $Names) { foreach ($Token in (New-RawRecord 'M' $Name)) { $Tokens.Add($Token) } }
foreach ($Status in @('A','D','T','R100','C75','M25')) {
	$New = if ($Status.StartsWith('R') -or $Status.StartsWith('C')) { "new-$Status" } else { "old-$Status" }
	foreach ($Token in (New-RawRecord -Status $Status -OldPath "old-$Status" -NewPath $New)) { $Tokens.Add($Token) }
}
$Parsed = @(ConvertFrom-GitRawZ (ConvertTo-RawBytes $Tokens.ToArray()))
Assert-True ($Parsed.Count -eq ($Names.Count + 6)) 'Every raw entry should be preserved.'
foreach ($Name in $Names) { Assert-True ($Parsed.oldPath -ccontains $Name) "Raw path '$Name' should round-trip." }
Assert-True (($Parsed | Where-Object status -eq 'R').newPath -ceq 'new-R100') 'Rename destinations should be retained.'
Assert-True (($Parsed | Where-Object status -eq 'C').newPath -ceq 'new-C75') 'Copy destinations should be retained.'
Assert-True (($Parsed | Where-Object status -eq 'M').Count -ge 2) 'Optional modification dissimilarity should parse.'
Assert-Rejected { ConvertFrom-GitRawZ (ConvertTo-RawBytes (New-RawRecord 'M' 'truncated') -Truncate) } 'nul_stream_truncated'
$InvalidUtf8 = (ConvertTo-RawBytes @("`:100644 100644 $('1'*40) $('2'*40) M", 'x'))
$InvalidUtf8[$InvalidUtf8.Length - 2] = 0xFF
Assert-Rejected { ConvertFrom-GitRawZ $InvalidUtf8 } 'path_utf8_invalid'
Assert-Rejected { ConvertFrom-GitRawZ (ConvertTo-RawBytes @("`:000000 100644 $('1'*40) $('2'*40) A", 'bad')) } 'diff_sentinel_invalid'
$LongPath = 'a' * 4096
Assert-True ((@(ConvertFrom-GitRawZ (ConvertTo-RawBytes (New-RawRecord 'M' $LongPath))))[0].oldPath.Length -eq 4096) 'The exact UTF-8 path-byte bound should parse.'
Assert-Rejected { ConvertFrom-GitRawZ (ConvertTo-RawBytes (New-RawRecord 'M' ('a' * 4097))) } 'path_invalid'

# Exact entry limits accept 4,096 and reject the next complete entry.
$BoundaryTokens = New-Object System.Collections.Generic.List[string]
for ($Index=0; $Index -lt 4096; $Index++) { foreach ($Token in (New-RawRecord 'M' ("f{0:D4}" -f $Index))) { $BoundaryTokens.Add($Token) } }
Assert-True (@(ConvertFrom-GitRawZ (ConvertTo-RawBytes $BoundaryTokens.ToArray())).Count -eq 4096) 'The exact raw-entry bound should pass.'
foreach ($Token in (New-RawRecord 'M' 'overflow')) { $BoundaryTokens.Add($Token) }
Assert-Rejected { ConvertFrom-GitRawZ (ConvertTo-RawBytes $BoundaryTokens.ToArray()) } 'diff_entry_limit'

# Windows safety is checked against the complete head tree, not only changes.
foreach ($Unsafe in @('CON.txt','aux','.git/config','git~1/x','trail.','trail ','a:b','a\b',"control$([char]1)",'../escape','C:/absolute',('COM' + [char]0xB9 + '.txt'),('LPT' + [char]0xB2),('com' + [char]0xB3 + '.log'))) {
	Assert-True (-not (Test-WindowsCheckoutPath $Unsafe)) "Unsafe Windows path '$Unsafe' should reject."
}
foreach ($Safe in @('Source/Foo.cpp',('Content/' + [char]0xC9 + 'lan.uasset'),'regular.exe.txt')) { Assert-True (Test-WindowsCheckoutPath $Safe) "Safe path '$Safe' should pass." }
Assert-Rejected { Test-WindowsCheckoutTree @([pscustomobject]@{type='blob';mode='100644';path='A.txt'},[pscustomobject]@{type='blob';mode='100644';path='a.txt'}) } 'checkout_case_collision'
$ComposedCafe = 'caf' + [char]0xE9
Assert-Rejected { Test-WindowsCheckoutTree @([pscustomobject]@{type='blob';mode='100644';path=$ComposedCafe},[pscustomobject]@{type='blob';mode='100644';path="cafe$([char]0x301)"}) } 'checkout_unicode_collision'
Assert-Rejected { Test-WindowsCheckoutTree @([pscustomobject]@{type='blob';mode='120000';path='link'}) } 'checkout_unsupported_entry'
Assert-Rejected { Test-WindowsCheckoutTree @([pscustomobject]@{type='commit';mode='160000';path='submodule'}) } 'checkout_unsupported_entry'
Assert-True (Test-WindowsCheckoutTree @([pscustomobject]@{type='blob';mode='100755';path='tool.exe'})) 'Executable regular blobs should remain supported.'
$TreeBoundary = @(for ($Index=0; $Index -lt 4096; $Index++) { [pscustomobject]@{type='blob';mode='100644';path=("tree/{0:D4}.txt" -f $Index)} })
Assert-True (Test-WindowsCheckoutTree $TreeBoundary) 'The exact tracked-tree entry bound should pass.'
Assert-Rejected { Test-WindowsCheckoutTree @($TreeBoundary + [pscustomobject]@{type='blob';mode='100644';path='tree/overflow.txt'}) } 'tree_entry_limit'

# Classification is closed and conservative at cross-class boundaries.
$Visual = @(Get-PathCheckSelection 'visuals/a.png' @{filter='lfs'})
Assert-True ($Visual -ccontains 'portable' -and $Visual -ccontains 'visual-package') 'Visual LFS should select portable and visual validation.'
$Content = @(Get-PathCheckSelection 'Content/a.uasset' @{filter='lfs'})
Assert-True ($Content -ccontains 'native-client-server-compile' -and $Content -ccontains 'unreal-editor-automation' -and $Content -ccontains 'content-reference-validation' -and $Content -cnotcontains 'clean-package-provenance-smoke') 'Content LFS should select applicable engine/content checks without turning an ordinary change into a clean milestone.'
$Source = @(Get-PathCheckSelection 'Source/GameCore/Foo.cpp' @{})
Assert-True ($Source -ccontains 'native-client-server-compile' -and $Source -ccontains 'unreal-editor-automation' -and $Source -cnotcontains 'content-reference-validation' -and $Source -cnotcontains 'clean-package-provenance-smoke') 'Ordinary source should select native and Editor checks, but not content or clean-milestone work.'
$PluginSource = @(Get-PathCheckSelection 'Plugins/Foo/Source/Foo.cpp' @{})
Assert-True ($PluginSource -ccontains 'native-client-server-compile' -and $PluginSource -ccontains 'unreal-editor-automation' -and $PluginSource -cnotcontains 'content-reference-validation' -and $PluginSource -cnotcontains 'clean-package-provenance-smoke') 'Plugin source should select native and Editor checks without a clean milestone.'
$Config = @(Get-PathCheckSelection 'Config/DefaultGame.ini' @{})
Assert-True ($Config -ccontains 'native-client-server-compile' -and $Config -ccontains 'unreal-editor-automation' -and $Config -ccontains 'content-reference-validation' -and $Config -cnotcontains 'clean-package-provenance-smoke') 'Runtime configuration should add content-reference validation without a clean milestone.'
$Project = @(Get-PathCheckSelection 'AethelnOnline.uproject' @{})
Assert-True ($Project -ccontains 'native-client-server-compile' -and $Project -ccontains 'unreal-editor-automation' -and $Project -cnotcontains 'clean-package-provenance-smoke') 'The project descriptor should select native and Editor checks without a clean milestone.'
$Controller = @(Get-PathCheckSelection 'scripts/ci/Get-CiSelection.ps1' @{})
Assert-True ($Controller -ccontains 'controller-contract' -and $Controller -ccontains 'controller-operational-proof') 'Production controller changes should select contract and operational proof.'
$VisualController = @(Get-PathCheckSelection 'scripts/ci/Invoke-VisualPackageValidation.ps1' @{})
Assert-True ($VisualController -ccontains 'visual-package' -and $VisualController -ccontains 'controller-contract' -and $VisualController -ccontains 'controller-operational-proof') 'The production visual controller must select real visual execution plus contract and operational proof.'
$VisualControllerLookalike = @(Get-PathCheckSelection 'scripts/ci/Invoke-VisualPackageValidation.ps1.bak' @{})
Assert-True ($VisualControllerLookalike -cnotcontains 'visual-package' -and $VisualControllerLookalike -ccontains 'controller-contract' -and $VisualControllerLookalike -ccontains 'controller-operational-proof') 'A visual-controller lookalike must not inherit the exact production visual obligation.'
$WorkflowController = @(Get-PathCheckSelection '.github/workflows/prototype-quality-gates.yml' @{})
Assert-True ($WorkflowController -ccontains 'controller-contract' -and $WorkflowController -ccontains 'controller-operational-proof') 'Workflow controller changes should select contract and operational proof.'
$ControllerTest = @(Get-PathCheckSelection 'tests/ci/Get-CiSelection.Tests.ps1' @{})
Assert-True ($ControllerTest -ccontains 'controller-contract' -and $ControllerTest -cnotcontains 'controller-operational-proof') 'Controller tests should select contract proof without pretending to change production operations.'
foreach ($ScriptTestPath in @('scripts/tests/Test-ObservabilityContract.ps1', 'scripts/tests/Test-SourceControlPolicy.ps1')) {
	$ScriptTest = @(Get-PathCheckSelection $ScriptTestPath @{})
	Assert-True (($ScriptTest -join ',') -ceq 'portable') "Tracked PowerShell script test '$ScriptTestPath' should select only portable proof."
}
foreach ($ScriptTestLookalike in @('scripts/tests/NewUnwiredTest.ps1', 'scripts/tests/Test-SourceControlPolicy.ps1.bak', 'scripts/tests/Test-SourceControlPolicy.md', 'Scripts/tests/Test-SourceControlPolicy.ps1', 'scripts/test/Test-SourceControlPolicy.ps1')) {
	Assert-Rejected { Get-PathCheckSelection $ScriptTestLookalike @{} } 'path_unclassified'
}
$AttributesPolicy = @(Get-PathCheckSelection '.gitattributes' @{})
Assert-True ($AttributesPolicy -ccontains 'controller-contract' -and $AttributesPolicy -ccontains 'controller-operational-proof') 'Attribute policy changes should remain classifiable while triggering global attribute evaluation.'
Assert-Rejected { Get-PathCheckSelection 'Setup.ps1' @{} } 'path_unclassified'
$BuildHarness = @(Get-PathCheckSelection 'scripts/build/Build-PackagedArtifacts.ps1' @{})
Assert-True ($BuildHarness -cnotcontains 'delivery-harness' -and $BuildHarness -ccontains 'controller-operational-proof' -and $BuildHarness -ccontains 'clean-package-provenance-smoke') 'Build paths should retain operational and clean-package proof without the retired delivery harness.'
$BuildTest = @(Get-PathCheckSelection 'tests/build/X.Tests.ps1' @{})
Assert-True ($BuildTest -cnotcontains 'delivery-harness' -and $BuildTest -ccontains 'portable') 'Build tests should retain portable proof without the retired delivery harness.'
$RetiredSkill = @(Get-PathCheckSelection '.agents/skills/orchestrate-delivery/SKILL.md' @{})
Assert-True ($RetiredSkill -cnotcontains 'delivery-harness' -and $RetiredSkill -ccontains 'portable') 'Retired skill paths should remain classified without selecting a nonexistent harness.'
$PluginContent = @(Get-PathCheckSelection 'Plugins/Foo/Content/A.uasset' @{filter='lfs'})
Assert-True ($PluginContent -ccontains 'content-reference-validation' -and $PluginContent -ccontains 'native-client-server-compile' -and $PluginContent -ccontains 'unreal-editor-automation' -and $PluginContent -cnotcontains 'clean-package-provenance-smoke') 'Plugin content and LFS materialization should select content, native, and Editor checks without a clean milestone.'

# Build an object-only fixture with accepted controller bytes, a nested
# attribute rule, an unchanged copy source, a cross-root rename, and an exact
# two-parent synthetic workflow merge.
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-selector-' + [guid]::NewGuid().ToString('N'))
$FixtureRepo = Join-Path $FixtureRoot 'repo'
$null = New-Item -ItemType Directory -Path $FixtureRepo -Force
function Invoke-FixtureGit([string[]] $Arguments) {
	$PreviousErrorAction=$ErrorActionPreference; $ErrorActionPreference='Continue'
	try { $Output = @(& git -C $FixtureRepo @Arguments 2>&1 | ForEach-Object { "$_" }); $Code=$LASTEXITCODE }
	finally { $ErrorActionPreference=$PreviousErrorAction }
	Assert-True ($Code -eq 0) "Fixture git failed: git $($Arguments -join ' '): $($Output -join ' ')"
	return ,$Output
}
function Write-Fixture([string] $RelativePath, [string] $Value) {
	$Path=Join-Path $FixtureRepo ($RelativePath -replace '/','\'); $Parent=Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $Parent)) {[void](New-Item -ItemType Directory -Path $Parent -Force)}
	[IO.File]::WriteAllText($Path,$Value,(New-Object Text.UTF8Encoding($false)))
}
try {
	$null=Invoke-FixtureGit @('init','-q'); $null=Invoke-FixtureGit @('config','user.name','fixture'); $null=Invoke-FixtureGit @('config','user.email','fixture@example.invalid')
	$StallScript=Join-Path $FixtureRoot 'stall.cmd'
	[IO.File]::WriteAllText($StallScript,"@echo off`r`npowershell.exe -NoProfile -Command `"Start-Sleep -Seconds 30`"`r`n",$script:Utf8NoBom)
	$StallCommand='!' + $StallScript.Replace('\','/')
	$null=Invoke-FixtureGit @('config','alias.aetheln-stall',$StallCommand)
	$StallWatch=[Diagnostics.Stopwatch]::StartNew()
	Assert-Rejected { Invoke-BoundedGitBytes $FixtureRepo @('aetheln-stall') -InputBytes ([byte[]]::new(1MB)) -TimeoutSeconds 1 } 'git_timeout'
	$StallWatch.Stop()
	Assert-True ($StallWatch.Elapsed.TotalSeconds -lt 10) 'The Git-operation deadline must include blocked stdin delivery and descendant cleanup.'
	$ControllerPath='scripts/ci/Get-CiSelection.ps1'; $TargetController=Join-Path $FixtureRepo ($ControllerPath -replace '/','\'); [void](New-Item -ItemType Directory -Path (Split-Path -Parent $TargetController) -Force); [IO.File]::Copy($SourceScript,$TargetController)
	Write-Fixture '.gitattributes' "*.bin filter=lfs diff=lfs merge=lfs -text`n"
	Write-Fixture 'Content/source.bin' (('unchanged-copy-source-' * 32) + "`n")
	Write-Fixture 'visuals/unchanged.png' "unchanged attribute target`n"
	Write-Fixture 'docs/rename.md' "rename source`n"
	Write-Fixture 'docs/readme.md' "base`n"
	$null=Invoke-FixtureGit @('add','-A'); $null=Invoke-FixtureGit @('commit','-qm','base'); $BaseRevision=[string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]
	$BaseControllerOid=[string]@(Invoke-FixtureGit @('rev-parse',"$BaseRevision`:$ControllerPath"))[0]
	[IO.File]::AppendAllText($TargetController,"`n# candidate selector bytes must never execute`n",(New-Object Text.UTF8Encoding($false)))
	Write-Fixture '.gitattributes' "*.bin filter=lfs diff=lfs merge=lfs -text`nvisuals/*.png filter=lfs diff=lfs merge=lfs -text`n"
	[IO.File]::Copy((Join-Path $FixtureRepo 'Content\source.bin'),(Join-Path $FixtureRepo 'Content\copy.bin'))
	[void](New-Item -ItemType Directory -Path (Join-Path $FixtureRepo 'visuals') -Force)
	[IO.File]::Move((Join-Path $FixtureRepo 'docs\rename.md'),(Join-Path $FixtureRepo 'visuals\renamed.md'))
	Write-Fixture 'scripts/tests/Test-ObservabilityContract.ps1' "Write-Output 'observability fixture'`n"
	Write-Fixture 'scripts/tests/Test-SourceControlPolicy.ps1' "Write-Output 'source policy fixture'`n"
	Write-Fixture 'Source/GameCore/SelectorFixture.cpp' "// native source fixture`n"
	Write-Fixture 'docs/readme.md' "head`n"; $null=Invoke-FixtureGit @('add','-A'); $null=Invoke-FixtureGit @('commit','-qm','head'); $HeadRevision=[string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]
	$Tree=[string]@(Invoke-FixtureGit @('rev-parse',"$HeadRevision`^{tree}"))[0]
	$MergeRevision=(@("synthetic merge" | & git -C $FixtureRepo commit-tree $Tree -p $BaseRevision -p $HeadRevision) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Synthetic merge creation should succeed.'
	$Context=[pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$BaseRevision;headRevision=$HeadRevision;workflowRevision=$MergeRevision;controllerRevision=$BaseRevision}
	# GitHub can keep the event base while its synthetic merge uses a newer
	# target tip. Only that verified first parent may supply controller bytes.
	$null=Invoke-FixtureGit @('checkout','-q','--detach',$BaseRevision)
	Write-Fixture 'docs/accepted.md' "advanced target tip`n"
	[IO.File]::AppendAllText($TargetController,"`n# accepted target controller bytes`n",(New-Object Text.UTF8Encoding($false)))
	$null=Invoke-FixtureGit @('add','-A'); $null=Invoke-FixtureGit @('commit','-qm','accepted target advances'); $AcceptedRevision=[string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]
	$AcceptedControllerOid=[string]@(Invoke-FixtureGit @('rev-parse',"$AcceptedRevision`:$ControllerPath"))[0]
	$StaleMerge=(@('stale event base merge' | & git -C $FixtureRepo commit-tree $Tree -p $AcceptedRevision -p $HeadRevision) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Stale-base synthetic merge creation should succeed.'
	# The live workflow passes the verified first parent as baseRevision so the
	# previously accepted closed selector (which requires base == controller and
	# ordered base/head parents) can produce this transition PR's shadow report.
	$LiveContext=[pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$AcceptedRevision;headRevision=$HeadRevision;workflowRevision=$StaleMerge;controllerRevision=$AcceptedRevision}
	$LiveParents=([string]@(Invoke-FixtureGit @('show','-s','--format=%P',$StaleMerge))[0]).Split(' ')
	Assert-True ($LiveContext.baseRevision -ceq $LiveContext.controllerRevision -and $LiveParents.Count -eq 2 -and $LiveParents[0] -ceq $LiveContext.baseRevision -and $LiveParents[1] -ceq $LiveContext.headRevision) 'Live context must satisfy the previously accepted selector relationship and workflow-parent checks despite a stale event base.'
	$LiveReport=New-CiSelectionReport $LiveContext $FixtureRepo
	Assert-True ($LiveReport.source.baseRevision -ceq $AcceptedRevision -and $LiveReport.execution.controllerBlobOid -ceq $AcceptedControllerOid -and $AcceptedControllerOid -cne $BaseControllerOid -and $LiveReport.execution.reason -ceq 'classified') 'Compatible live context must retain accepted first-parent comparison and controller bytes.'
	$CalledStaleContext=[pscustomobject][ordered]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='pull_request';baseRevision=$AcceptedRevision;headRevision=$HeadRevision;workflowRevision=$StaleMerge;revision=$null;controllerRevision=$AcceptedRevision}
	Assert-True ((New-CiSelectionReport $CalledStaleContext $FixtureRepo).source.baseRevision -ceq $AcceptedRevision) 'Called pull requests must use the same accepted first parent.'
	$WrongHeadMerge=(@('wrong head merge' | & git -C $FixtureRepo commit-tree $Tree -p $AcceptedRevision -p $BaseRevision) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Wrong-head merge fixture creation should succeed.'
	$WrongHeadContext=[pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$AcceptedRevision;headRevision=$HeadRevision;workflowRevision=$WrongHeadMerge;controllerRevision=$AcceptedRevision}
	Assert-Rejected { New-CiSelectionReport $WrongHeadContext $FixtureRepo } 'workflow_revision_parents_invalid'
	$WrongControllerContext=[pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$BaseRevision;headRevision=$HeadRevision;workflowRevision=$StaleMerge;controllerRevision=$BaseRevision}
	Assert-Rejected { New-CiSelectionReport $WrongControllerContext $FixtureRepo } 'workflow_revision_parents_invalid'
	$null=Invoke-FixtureGit @('checkout','-q','--detach',$HeadRevision)
	$Report=New-CiSelectionReport $Context $FixtureRepo
	$ScheduleReport=New-CiSelectionReport ([pscustomobject][ordered]@{kind='schedule';runId=$RunId;runAttempt=$RunAttempt;revision=$HeadRevision;controllerRevision=$HeadRevision}) $FixtureRepo
	$ScheduledClean=@($ScheduleReport.selection.obligations | Where-Object id -eq 'clean-package-provenance-smoke')[0]
	Assert-True ($ScheduledClean.selected -and $ScheduledClean.reasons -ccontains 'scheduled_event') 'Scheduled runs must retain the clean milestone after ordinary source/content changes stop selecting it.'
	Assert-True ($Report.execution.checkoutAllowed -eq $false -and $Report.selection.shadow -and -not $Report.selection.authoritative) 'Selector should remain no-checkout, shadow-only, and non-authoritative.'
	Assert-True ($null -eq $Report.legacyAuthority.engineRequired -and $Report.legacyAuthority.reason -ceq 'not_observed' -and $Report.comparison.status -ceq 'unavailable' -and $Report.comparison.differences -ccontains 'legacy_authority_not_observed') 'An independent shadow job must not claim it observed or compared a legacy classifier result.'
	$CalledReport=New-CiSelectionReport ([pscustomobject][ordered]@{kind='workflow_call';runId=$RunId;runAttempt=$RunAttempt;callerKind='pull_request';baseRevision=$BaseRevision;headRevision=$HeadRevision;workflowRevision=$MergeRevision;revision=$null;controllerRevision=$BaseRevision}) $FixtureRepo
	Assert-True ($CalledReport.source.kind -ceq 'workflow_call' -and $CalledReport.source.callerKind -ceq 'pull_request' -and $CalledReport.source.workflowRevision -ceq $MergeRevision) 'Reusable invocation reports must preserve caller kind and bind the caller workflow revision.'
	$HeadControllerOid=[string]@(Invoke-FixtureGit @('rev-parse',"$HeadRevision`:$ControllerPath"))[0]
	Assert-True ($Report.execution.controllerRevision -ceq $BaseRevision -and $Report.execution.controllerBlobOid -ceq $BaseControllerOid -and $Report.execution.controllerBlobOid -cne $HeadControllerOid -and $Report.execution.controllerSha256 -cmatch '^[0-9a-f]{64}$') 'Accepted controller identity should remain bound to base bytes when head modifies the selector.'
	Assert-True ($Report.execution.reason -ceq 'classified' -and @($Report.classification.uncertainties).Count -eq 0) 'Known script tests and native source should produce a classified report without conservative uncertainty.'
	foreach ($ScriptTestPath in @('scripts/tests/Test-ObservabilityContract.ps1', 'scripts/tests/Test-SourceControlPolicy.ps1')) {
		Assert-True ($Report.classification.changedPaths -ccontains $ScriptTestPath) "Changed script test '$ScriptTestPath' should remain visible in the report."
		$PortableObligation=@($Report.selection.obligations | Where-Object id -eq 'portable')[0]
		Assert-True ($PortableObligation.selected -and $PortableObligation.reasons -ccontains "path:$ScriptTestPath") "Changed script test '$ScriptTestPath' should select portable proof."
	}
	$NativeObligation=@($Report.selection.obligations | Where-Object id -eq 'native-client-server-compile')[0]
	$EditorObligation=@($Report.selection.obligations | Where-Object id -eq 'unreal-editor-automation')[0]
	Assert-True ($NativeObligation.reasons -ccontains 'path:Source/GameCore/SelectorFixture.cpp' -and $EditorObligation.reasons -ccontains 'path:Source/GameCore/SelectorFixture.cpp') 'Mixed script-test and source changes should retain native and Editor obligations.'
	Assert-True ($Report.policy.digest -ceq (Get-PolicyDigest)) 'Each report should bind the complete normalized selector policy source.'
	$PolicyMutationPath=Join-Path $FixtureRoot 'selector-policy-mutation.ps1'
	$PolicySource=[IO.File]::ReadAllText($SourceScript,$script:StrictUtf8)
	$MutatedPolicy=$PolicySource.Replace('rawBytes = 8MB','rawBytes = 7MB')
	Assert-True ($MutatedPolicy -cne $PolicySource) 'Policy mutation fixture must change one enforced limit.'
	[IO.File]::WriteAllText($PolicyMutationPath,$MutatedPolicy,$script:Utf8NoBom)
	$AcceptedPolicyPath=$script:CiSelectionSourcePath
	try { $script:CiSelectionSourcePath=$PolicyMutationPath; $MutatedPolicyDigest=Get-PolicyDigest }
	finally { $script:CiSelectionSourcePath=$AcceptedPolicyPath }
	Assert-True ($MutatedPolicyDigest -cne $Report.policy.digest) 'Changing an enforced policy limit must change the full policy digest.'
	Assert-True ($Report.classification.entries.status -ccontains 'C') 'An unchanged-source copy should be detected.'
	Assert-True ($Report.classification.entries.status -ccontains 'R') 'A cross-root rename should retain both sides.'
	$ContentObligation=@($Report.selection.obligations | Where-Object id -eq 'content-reference-validation')[0]
	$VisualObligation=@($Report.selection.obligations | Where-Object id -eq 'visual-package')[0]
	Assert-True ($ContentObligation.selected -and $VisualObligation.selected) 'Cross-class copy/rename should select both applicable checks.'
	Assert-True ($VisualObligation.reasons -ccontains 'attribute:visuals/unchanged.png') 'A root attribute-policy change should reclassify an unchanged tracked blob.'
	$JsonPath=Join-Path $FixtureRoot 'report.json'; $Length=Write-BoundedUtf8Json $Report $JsonPath
	$JsonBytes=[IO.File]::ReadAllBytes($JsonPath); Assert-True ($JsonBytes[0] -ne 0xEF -and $JsonBytes[1] -ne 0xBB -and $JsonBytes[2] -ne 0xBF) 'Report should be UTF-8 without BOM.'
	$ParsedReport=([Text.Encoding]::UTF8.GetString($JsonBytes) | ConvertFrom-Json)
	Assert-True ((@($ParsedReport.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,attemptAnchor,policy,source,execution,classification,selection,legacyAuthority,comparison') 'Root schema should be exact and ordered.'
	Assert-CiSelectionAttemptAnchor $ParsedReport.attemptAnchor $Context | Out-Null
	Assert-True (($ParsedReport.source.PSObject.Properties.Name -join ',') -ceq 'kind,callerKind,baseRevision,headRevision,workflowRevision,revision') 'Source schema should preserve the closed caller discriminant and revisions.'
	Assert-True (($ParsedReport.execution.PSObject.Properties.Name -join ',') -ceq 'mode,controllerRevision,controllerBlobOid,controllerSha256,checkoutAllowed,complete,reason') 'Execution schema should be exact and ordered.'
	Assert-True (($ParsedReport.selection.obligations[0].PSObject.Properties.Name -join ',') -ceq 'id,selected,reasons') 'Obligation schema should be exact and ordered.'
	Assert-Rejected { Assert-UniqueJsonProperties '{"execution":{"mode":"accepted-base","\u006dode":"candidate"}}' } 'context_schema_invalid'
	Assert-True ($Length -le 4MB) 'Normal report should respect its byte bound.'
	$JsonPath2=Join-Path $FixtureRoot 'report-2.json'; [void](Write-BoundedUtf8Json $Report $JsonPath2)
	Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($JsonPath)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($JsonPath2))) 'Report bytes should be deterministic.'
	Assert-Rejected { Write-BoundedUtf8Json $Report (Join-Path $FixtureRoot 'too-small.json') ($Length-1) } 'report_size_limit'
	Write-Fixture 'scripts/tests/NewUnwiredTest.ps1' "Write-Output 'not wired into CI'`n"
	$null=Invoke-FixtureGit @('add','-A'); $null=Invoke-FixtureGit @('commit','-qm','unwired script test'); $UnwiredHead=[string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]
	$UnwiredTree=[string]@(Invoke-FixtureGit @('rev-parse',"$UnwiredHead`^{tree}"))[0]
	$UnwiredMerge=(@('synthetic unwired merge' | & git -C $FixtureRepo commit-tree $UnwiredTree -p $HeadRevision -p $UnwiredHead) -join '').Trim()
	Assert-True ($LASTEXITCODE -eq 0) 'Unwired-test synthetic merge creation should succeed.'
	Assert-Rejected { New-CiSelectionReport ([pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$HeadRevision;headRevision=$UnwiredHead;workflowRevision=$UnwiredMerge;controllerRevision=$HeadRevision}) $FixtureRepo } 'path_unclassified'

	# Revision-specific attributes: deleted/source reads base; new/destination
	# reads head. A changed root/nested policy forces whole-tree re-evaluation.
	$BaseAttributes=Get-RevisionAttributes $FixtureRepo $BaseRevision @('Content/source.bin')
	$HeadAttributes=Get-RevisionAttributes $FixtureRepo $HeadRevision @('Content/copy.bin')
	Assert-True ($BaseAttributes['Content/source.bin'].filter -ceq 'lfs' -and $HeadAttributes['Content/copy.bin'].filter -ceq 'lfs') 'Revision attributes should preserve LFS classification on both sides.'
	Write-Fixture '.lfsconfig' "[lfs]`nurl = https://invalid.example`n"; $null=Invoke-FixtureGit @('add','.lfsconfig'); $null=Invoke-FixtureGit @('commit','-qm','lfsconfig unsupported'); $LfsHead=[string]@(Invoke-FixtureGit @('rev-parse','HEAD'))[0]; $LfsTree=[string]@(Invoke-FixtureGit @('rev-parse',"$LfsHead`^{tree}"))[0]
	$LfsMerge=(@("merge" | & git -C $FixtureRepo commit-tree $LfsTree -p $HeadRevision -p $LfsHead) -join '').Trim()
	Assert-Rejected { New-CiSelectionReport ([pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$HeadRevision;headRevision=$LfsHead;workflowRevision=$LfsMerge;controllerRevision=$HeadRevision}) $FixtureRepo } 'lfsconfig_changed'
	$Bootstrap=New-ConservativeSelection 'accepted_controller_unavailable' ([pscustomobject][ordered]@{kind='pull_request';runId=$RunId;runAttempt=$RunAttempt;baseRevision=$BaseRevision;headRevision=$HeadRevision;workflowRevision=$MergeRevision;controllerRevision=$BaseRevision})
	$BootstrapClean=@($Bootstrap.selection.obligations | Where-Object id -eq 'clean-package-provenance-smoke')[0]
	Assert-CiSelectionAttemptAnchor $Bootstrap.attemptAnchor $Context | Out-Null
	Assert-True ($null -eq $Bootstrap.execution.controllerBlobOid -and $Bootstrap.execution.checkoutAllowed -eq $false -and $Bootstrap.source.baseRevision -ceq $BaseRevision -and @($Bootstrap.selection.obligations | Where-Object {-not $_.selected}).Count -eq 0 -and $BootstrapClean.selected) 'Bootstrap fallback should preserve known revisions and select every obligation, including the clean milestone, without checkout.'

	# Binary stdout is accepted exactly at the limit and rejected at +1. This
	# also proves no line-oriented or text decoding path touches object bytes.
	$BlobPath=Join-Path $FixtureRoot 'blob.raw'; [IO.File]::WriteAllBytes($BlobPath,[byte[]]::new(1MB))
	$BlobOid=([string]@(& git -C $FixtureRepo hash-object -w -- $BlobPath)).Trim()
	Assert-True ((Get-Item -LiteralPath $BlobPath).Length -eq 1MB -and $BlobOid -cmatch '^[0-9a-f]{40}$') "Binary fixture should be exactly 1 MiB with one valid blob OID (length=$((Get-Item -LiteralPath $BlobPath).Length), oid=$BlobOid)."
	$Exact=(Invoke-BoundedGitBytes $FixtureRepo @('cat-file','blob',$BlobOid) -StdoutLimit 1MB).Stdout
	Assert-True ($Exact.Length -eq 1MB) "Exact binary stdout limit should pass (type=$($Exact.GetType().FullName), length=$($Exact.Length))."
	Assert-Rejected { Invoke-BoundedGitBytes $FixtureRepo @('cat-file','blob',$BlobOid) -StdoutLimit (1MB-1) } 'git_output_limit'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}

Write-Output 'PASS: CI selector contexts, binary Git parsing, checkout safety, attributes, classification, bounds, and deterministic report contracts'
