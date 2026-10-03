[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WorkflowPath = Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml'
$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$CheckoutAction = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
$DownloadAction = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
$UploadAction = 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
$CheckoutActionPattern = [regex]::Escape($CheckoutAction)
$DownloadActionPattern = [regex]::Escape($DownloadAction)
$UploadActionPattern = [regex]::Escape($UploadAction)

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-MatchCount([string] $Text, [string] $Pattern, [int] $Expected, [string] $Message) {
	$Actual = [regex]::Matches($Text, $Pattern).Count
	Assert-True ($Actual -eq $Expected) "$Message Expected $Expected match(es), found $Actual."
}

function Get-JobBody([string] $JobName, [string] $NextJobName) {
	$Start = "  ${JobName}:"
	$End = "  ${NextJobName}:"
	$StartIndex = $Workflow.IndexOf($Start, [StringComparison]::Ordinal)
	$EndIndex = $Workflow.IndexOf($End, $StartIndex + $Start.Length, [StringComparison]::Ordinal)
	Assert-True ($StartIndex -ge 0 -and $EndIndex -gt $StartIndex) "Workflow job '$JobName' should exist before '$NextJobName'."
	return $Workflow.Substring($StartIndex, $EndIndex - $StartIndex)
}

$ShadowSelection = Get-JobBody 'ci-selection-shadow' 'quality-gates'
$QualityGates = Get-JobBody 'quality-gates' 'change-impact'
$ChangeImpact = Get-JobBody 'change-impact' 'trusted-candidate-compile'
$TrustedCompile = Get-JobBody 'trusted-candidate-compile' 'trusted-editor-automation'
$EditorAutomation = Get-JobBody 'trusted-editor-automation' 'scheduled-client-package'
$ScheduledSmokeStart = $Workflow.IndexOf('  scheduled-packaged-smoke:', [StringComparison]::Ordinal)
Assert-True ($ScheduledSmokeStart -ge 0) "Workflow job 'scheduled-packaged-smoke' should exist."
$ScheduledSmoke = Get-JobBody 'scheduled-packaged-smoke' 'visual-proof'
$VisualProof = Get-JobBody 'visual-proof' 'portable-receipt-shadow'
$PortableReceipt = Get-JobBody 'portable-receipt-shadow' 'native-receipt-shadow'
$NativeReceipt = Get-JobBody 'native-receipt-shadow' 'unreal-receipt-shadow'
$UnrealReceipt = Get-JobBody 'unreal-receipt-shadow' 'visual-receipt-shadow'
$VisualReceipt = Get-JobBody 'visual-receipt-shadow' 'ci-acceptance-shadow'
$AcceptanceShadow = Get-JobBody 'ci-acceptance-shadow' 'ci-acceptance-authority'
$AuthorityStart = $Workflow.IndexOf('  ci-acceptance-authority:', [StringComparison]::Ordinal)
Assert-True ($AuthorityStart -ge 0) "Workflow job 'ci-acceptance-authority' should exist."
$AcceptanceAuthority = $Workflow.Substring($AuthorityStart)

# Persistent DDC repository identity uses the root-commit set. Every milestone
# checkout needs complete ancestry so a shallow boundary cannot become a root.
foreach ($Job in @(
	@{ Name = 'scheduled-client-package'; Body = (Get-JobBody 'scheduled-client-package' 'scheduled-server-package') },
	@{ Name = 'scheduled-server-package'; Body = (Get-JobBody 'scheduled-server-package' 'scheduled-provenance-validation') },
	@{ Name = 'scheduled-provenance-validation'; Body = (Get-JobBody 'scheduled-provenance-validation' 'scheduled-packaged-smoke') },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke }
)) {
	$Checkout = [regex]::Match($Job.Body, "(?m)^      - uses: $CheckoutActionPattern\r?\n        with:\r?\n(?<Inputs>(?:          [^\r\n]+\r?\n)+)")
	Assert-True ($Checkout.Success) "$($Job.Name) must declare its checkout inputs."
	Assert-MatchCount -Text $Checkout.Groups['Inputs'].Value -Pattern '(?m)^          fetch-depth: 0\r?$' -Expected 1 -Message "$($Job.Name) must fetch complete ancestry for stable DDC repository identity."
}

# Issue #150: the only engine entry points are the trusted pull-request compile
# and the four bounded, schedule-only milestone phases. No manual entry point
# of any kind exists on this workflow identity, so an older branch that still
# carries the retired 1,440-minute PackagedSmoke job can never be selected.
$PhaseTrigger = "if: github\.event_name == 'schedule'\r?\n"

Assert-True ($Workflow -match '(?m)^permissions:\r?\n  contents: read\r?$') 'Workflow-global permissions must remain least-privilege contents read.'
Assert-True ($Workflow -notmatch '\$\{\{\s*secrets\.' -and $Workflow -notmatch '(?m)^\s*secrets\s*:') 'Workflow must not consume or declare secrets.'
Assert-True ($Workflow -notmatch 'workflow_dispatch') 'Workflow must not expose any manual workflow_dispatch entry point.'
Assert-True ($Workflow -notmatch 'cancelled\(\)' -and $Workflow -notmatch 'failure\(\)') 'Workflow must not use status functions that bypass a failed or skipped prerequisite.'
$ExpectedActionManifest = '[{"uses":"actions/checkout","revision":"3d3c42e5aac5ba805825da76410c181273ba90b1"},{"uses":"actions/download-artifact","revision":"d3f86a106a0bac45b974a628896c90dbdf5c8093"},{"uses":"actions/upload-artifact","revision":"043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"}]'
Assert-MatchCount -Text $Workflow -Pattern ([regex]::Escape($ExpectedActionManifest)) -Expected 1 -Message 'The aggregate identity manifest must exactly bind the reviewed checkout, download, and upload action revisions.'
Assert-MatchCount -Text $Workflow -Pattern ([regex]::Escape("uses: $DownloadAction")) -Expected 10 -Message 'Package 3C must contain exactly ten reviewed exact-ID artifact downloads.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^          merge-multiple: true\r?$' -Expected 10 -Message 'Every exact-ID artifact download must flatten its single archive into the validated destination root.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^    if: always\(\)(?: && github\.event_name == ''pull_request'' && false)?\r?$' -Expected 2 -Message 'Only the hosted aggregate and dormant fail-closed authority boundary may use job-level always().'
Assert-True ($AcceptanceShadow -match '(?m)^    if: always\(\)\r?$' -and $AcceptanceShadow -notmatch '(?m)^    continue-on-error:') 'The acceptance shadow must run after every dependency while unexpected reconciliation failures remain visible.'
Assert-True ($AcceptanceShadow -match "Write-Warning \('acceptance_producer_gap:' \+" -and $AcceptanceShadow -notmatch "throw \('acceptance_producer_gap:") 'A selected unsupported producer must publish a green no-acceptance diagnostic rather than fail an otherwise healthy pull request.'
Assert-True ($AcceptanceShadow -match '(?ms)^    permissions:\r?\n      actions: read\r?\n      contents: read\r?$' -and $AcceptanceShadow -notmatch '(?m)^      (?:checks|pull-requests|issues|statuses|workflows): write\r?$') 'Only the aggregate job may add read-only Actions API access; it must not gain mutation authority.'

# Issue #167 Package 2: an independent pull-request-only shadow computes the
# future selection record without controlling any existing job. It fetches the
# exact immutable graph before the only checkout, and that checkout is the
# accepted base sparse control path rather than candidate executable bytes.
Assert-True ($ShadowSelection -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'The shadow selector must run only for pull requests.'
Assert-True ($ShadowSelection -match '(?m)^\s+continue-on-error: true\r?$') 'The selector itself remains observational and cannot control legacy job selection; dependent Package 3C evidence validation may still fail red.'
Assert-True ($ShadowSelection -match '(?m)^\s+runs-on: windows-latest\r?$' -and $ShadowSelection -match '(?m)^\s+timeout-minutes: 10\r?$') 'The shadow selector must be a bounded GitHub-hosted job.'
Assert-True ($ShadowSelection -notmatch '(?m)^\s+needs:') 'The accepted-base shadow selector must remain dependency-free.'
$ExpectedSelectorOutputs = @(
	'accepted_base_sha','attempt_nonce','aggregate_ready','clean_package_provenance_smoke_required','content_reference_validation_required',
	'controller_contract_required','controller_operational_proof_required',
	'native_client_server_compile_required','portable_required','unreal_editor_automation_required','visual_package_required',
	'selector_artifact_id','selector_artifact_name','selector_artifact_digest'
)
foreach ($OutputName in $ExpectedSelectorOutputs) {
	Assert-True ($ShadowSelection -match "(?m)^      ${OutputName}: ") "The selector must expose exact Package 3C output '$OutputName'."
}
Assert-MatchCount -Text $ShadowSelection -Pattern '(?m)^      [a-z_]+: ' -Expected $ExpectedSelectorOutputs.Count -Message 'The selector must expose only the reviewed Package 3C decisions and artifact bindings.'
Assert-True ($ShadowSelection -match '(?m)^      accepted_base_sha: \$\{\{ steps\.comparison\.outputs\.accepted_base_sha \}\}\r?$') 'The selector must expose the verified synthetic-merge first parent so consumers bind the same base the selector compared.'
Assert-True ($ShadowSelection -notmatch 'self-hosted|aetheln-engine-runner|needs\.') 'The shadow selector must not admit or influence engine work.'
Assert-MatchCount -Text $ShadowSelection -Pattern "(?m)^\s+- uses: $CheckoutActionPattern\r?$" -Expected 1 -Message 'The shadow selector must perform exactly one pinned checkout.'
Assert-True ($ShadowSelection -match 'ref: \$\{\{ steps\.comparison\.outputs\.accepted_base_sha \}\}' -and $ShadowSelection -match 'sparse-checkout: scripts/ci/Get-CiSelection\.ps1' -and $ShadowSelection -match 'persist-credentials: false') 'The only shadow checkout must sparsely materialize the verified synthetic-merge first-parent selector without credentials.'
$FetchPosition = $ShadowSelection.IndexOf('name: Fetch immutable comparison objects', [StringComparison]::Ordinal)
$CheckoutPosition = $ShadowSelection.IndexOf("uses: $CheckoutAction", [StringComparison]::Ordinal)
Assert-True ($FetchPosition -ge 0 -and $CheckoutPosition -gt $FetchPosition) 'Base, head and workflow objects must enter the bare control repository before any checkout.'
Assert-True ($ShadowSelection -match '(?m)^        id: comparison\r?$' -and $ShadowSelection -match 'git --git-dir=\$env:AETHELN_CONTROL_REPO show -s --format=%P \$WorkflowSha' -and $ShadowSelection -match '\$Parents\[1\] -cne \$HeadSha' -and $ShadowSelection -match 'git --git-dir=\$env:AETHELN_CONTROL_REPO merge-base --is-ancestor \$BaseSha \$AcceptedSha' -and $ShadowSelection -match 'accepted_base_sha=\$AcceptedSha') 'The workflow must derive the accepted controller from the immutable merge first parent, verify the exact second parent and event-base ancestry, and publish only that verified revision.'
Assert-True ($ShadowSelection -notmatch 'fetch --no-tags --depth=' -and $ShadowSelection -match 'comparison_ancestry_incomplete') 'The control repository must have complete ancestry before accepting a stale event base.'
foreach ($Binding in @('github.event.pull_request.base.sha', 'github.event.pull_request.head.sha', 'github.sha')) {
	Assert-True ($ShadowSelection.Contains($Binding)) "Shadow selection must bind exact immutable identity $Binding."
}
$SelectionContext = [regex]::Match($ShadowSelection, '(?ms)^          \$Context = \[ordered\]@\{\r?\n(?<body>.*?)^          \}\r?$')
Assert-True ($SelectionContext.Success) 'The shadow selection run block must construct one closed context object.'
Assert-MatchCount -Text $SelectionContext.Groups['body'].Value -Pattern '(?m)^            baseRevision = \$AcceptedSha\r?$' -Expected 1 -Message 'The live context must use the verified first parent as its comparison base so the previously accepted closed selector can run during this transition.'
Assert-True ($SelectionContext.Groups['body'].Value -notmatch '(?m)^            baseRevision = \$BaseSha\r?$') 'The stale event base must remain an independent workflow ancestry witness, not an incompatible selector-context base.'
Assert-True ($ShadowSelection -match 'AETHELN_ACCEPTED_BASE_SHA: \$\{\{ steps\.comparison\.outputs\.accepted_base_sha \}\}' -and $SelectionContext.Groups['body'].Value -match '(?m)^            controllerRevision = \$AcceptedSha\r?$' -and $ShadowSelection -match '\$BlobQuery = "\$\{AcceptedSha\}:scripts/ci/Get-CiSelection.ps1"') 'Selection context and controller object lookup must use the same verified first parent, never the stale event base or candidate head.'
Assert-MatchCount -Text $SelectionContext.Groups['body'].Value -Pattern '(?m)^            runId = ''\$\{\{ github\.run_id \}\}''\r?$' -Expected 1 -Message 'The accepted-base selector context must bind the current GitHub run ID.'
Assert-MatchCount -Text $SelectionContext.Groups['body'].Value -Pattern '(?m)^            runAttempt = \[int\] ''\$\{\{ github\.run_attempt \}\}''\r?$' -Expected 1 -Message 'The accepted-base selector context must bind the current GitHub run attempt as an integer.'
Assert-True ($ShadowSelection -match 'git init --bare' -and $ShadowSelection -match 'accepted_controller_unavailable') 'Bootstrap must use a bare control repository and explicitly diagnose an unavailable accepted controller.'
Assert-True ($ShadowSelection -match 'attempt_anchor_rng_failed' -and $ShadowSelection -match "attemptAnchor = \[ordered\]@\{ schemaVersion = 'aetheln.current-attempt-anchor/v1'" -and $ShadowSelection -match 'source = \[ordered\]@\{ kind = ''pull_request''; callerKind = \$null; baseRevision = \$AcceptedSha' -and $ShadowSelection -match 'controllerRevision = \$AcceptedSha') 'Missing accepted controller must publish a closed, attempt-bound, fully selected first-parent diagnostic.'
Assert-True ($ShadowSelection -match 'function Assert-CurrentAttemptAnchor' -and $ShadowSelection -match '\$Parsed\.attemptAnchor' -and $ShadowSelection -match 'shadow_report_attempt_anchor_invalid') 'The selector output must validate the exact current run and attempt anchor before exposing nonce-based routing metadata.'
Assert-True ($ShadowSelection -match 'AETHELN_GITHUB_TOKEN: \$\{\{ github\.token \}\}' -and $ShadowSelection -match "GIT_CONFIG_KEY_0 = 'http\.extraheader'" -and $ShadowSelection -match 'GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic \$Authorization"' -and $ShadowSelection -match '::add-mask::\$Authorization') 'Private-repository object fetches must use the ephemeral GitHub token through a masked environment-backed authorization header.'
Assert-True ($ShadowSelection -notmatch 'persist-credentials: true' -and $ShadowSelection -notmatch 'https://x-access-token:') 'Shadow bootstrap credentials must not persist in the checkout or remote URL.'
Assert-True ($ShadowSelection -match 'Get-CiSelection\.ps1' -and $ShadowSelection -match '-ContextJson' -and $ShadowSelection -match '-OutputPath' -and $ShadowSelection -match '-RepositoryRoot') 'Only the accepted-base selector entry point may produce a live shadow record.'
Assert-True ($ShadowSelection -match 'cat-file blob \$ControllerBlobOid' -and $ShadowSelection -match 'StandardOutput\.BaseStream\.CopyToAsync\(\$OutputStream\)' -and $ShadowSelection -match 'StandardError\.ReadToEndAsync\(\)' -and $ShadowSelection -match 'WaitForExit\(\$TimeoutMilliseconds\)' -and $ShadowSelection -match 'bounded_process_timeout' -and $ShadowSelection -match 'hash-object --no-filters') 'The accepted selector must be rematerialized from the verified Git blob with concurrent drains and a bounded process before its raw identity check and execution.'
Assert-True ($ShadowSelection -match 'controllerBlobOid' -and $ShadowSelection -match 'controllerSha256') 'Shadow evidence must record the accepted controller blob OID and SHA-256 when available.'
$CanonicalObligationOrder = @(
	'portable',
	'visual-package',
	'native-client-server-compile',
	'unreal-editor-automation',
	'content-reference-validation',
	'controller-contract',
	'controller-operational-proof',
	'clean-package-provenance-smoke'
)
$PreviousObligationPosition = -1
foreach ($ObligationId in $CanonicalObligationOrder) {
	$CurrentObligationPosition = $ShadowSelection.IndexOf("'$ObligationId' =", [StringComparison]::Ordinal)
	Assert-True ($CurrentObligationPosition -gt $PreviousObligationPosition) "The selector validation map must preserve canonical obligation order at '$ObligationId'."
	$PreviousObligationPosition = $CurrentObligationPosition
}
Assert-True ($ShadowSelection -match 'selection\.shadow|shadow = \$true' -and $ShadowSelection -match 'authoritative = \$false' -and $ShadowSelection -match 'checkoutAllowed = \$false') 'Bootstrap evidence must be explicitly shadow-only, non-authoritative, and unable to authorize checkout.'
Assert-True ($ShadowSelection -match 'Assert-CurrentAttemptAnchor -Anchor \$Parsed\.attemptAnchor' -and $ShadowSelection -match 'attempt_nonce=\$AttemptNonce') 'The workflow must validate the accepted selector current-attempt anchor before exposing its nonce.'
Assert-True ($ShadowSelection -match '(?m)^          exit 0\r?$') 'A handled unavailable base controller must clear its expected native Git failure before the runner wrapper exits.'
Assert-MatchCount -Text $ShadowSelection -Pattern "(?m)^\s+uses: $UploadActionPattern\r?$" -Expected 1 -Message 'The shadow job must have one pinned artifact producer.'
Assert-True ($ShadowSelection -match '(?m)^        id: selector_artifact\r?$' -and $ShadowSelection -match 'name: \$\{\{ steps\.selection\.outputs\.selector_artifact_name \}\}' -and $ShadowSelection -match 'path: \$\{\{ runner\.temp \}\}/ci-selection-shadow\.json') 'The shadow artifact must expose its direct upload binding and contain the exact report path.'
Assert-True ($ShadowSelection -notmatch '(?m)^\s+if: always\(\)\r?$') 'A failed selector or anchor validator must not publish an invalid nonce-less selector artifact.'
Assert-True ($ShadowSelection -notmatch 'retention-days:' -and $ShadowSelection -notmatch '(?m)^\s+path: .*\*') 'The shadow artifact must use default retention and an exact single-file path.'
$ShadowRunBlocks = @([regex]::Matches($ShadowSelection, '(?ms)^        run: \|\r?\n(?<body>.*?)(?=^      - |\z)'))
Assert-True ($ShadowRunBlocks.Count -eq 2) 'Shadow selection must keep exactly two repository-owned PowerShell run blocks.'
foreach ($RunBlock in $ShadowRunBlocks) {
	$Body = (($RunBlock.Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_ } }) -join "`n"
	$ShadowParseErrors = $null
	$null = [Management.Automation.Language.Parser]::ParseInput($Body, [ref] $null, [ref] $ShadowParseErrors)
	Assert-True ($ShadowParseErrors.Count -eq 0) "Shadow PowerShell must parse under Windows PowerShell 5.1: $($ShadowParseErrors | Select-Object -First 1 | ForEach-Object Message)"
}
$FetchRunBody = (($ShadowRunBlocks[0].Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_ } }) -join "`n"
$PreflightStart = $FetchRunBody.IndexOf('$Shallow = @(', [StringComparison]::Ordinal)
$PreflightEnd = $FetchRunBody.IndexOf("`n", $FetchRunBody.IndexOf('[IO.File]::AppendAllText($env:GITHUB_OUTPUT', $PreflightStart, [StringComparison]::Ordinal))
Assert-True ($PreflightStart -ge 0 -and $PreflightEnd -gt $PreflightStart) 'The actual workflow preflight must be extractable for graph fixtures.'
$GraphPreflight = [scriptblock]::Create($FetchRunBody.Substring($PreflightStart, $PreflightEnd - $PreflightStart))
$GraphFixture = Join-Path ([IO.Path]::GetTempPath()) ('AethelnWorkflowGraph-' + [guid]::NewGuid().ToString('N'))
$GraphRepo = Join-Path $GraphFixture 'repo'
[void][IO.Directory]::CreateDirectory($GraphRepo)
function Invoke-GraphGit([string[]] $Arguments) {
	$Output = @(& git -C $GraphRepo @Arguments 2>&1 | ForEach-Object { "$_" })
	Assert-True ($LASTEXITCODE -eq 0) "Workflow graph fixture Git failed: git $($Arguments -join ' '): $($Output -join ' ')"
	return ,$Output
}
try {
	$null = Invoke-GraphGit @('init','-q')
	$null = Invoke-GraphGit @('config','user.name','fixture')
	$null = Invoke-GraphGit @('config','user.email','fixture@example.invalid')
	[IO.File]::WriteAllText((Join-Path $GraphRepo 'base.txt'), 'base', (New-Object Text.UTF8Encoding($false)))
	$null = Invoke-GraphGit @('add','-A'); $null = Invoke-GraphGit @('commit','-qm','base'); $EventBase=[string]@(Invoke-GraphGit @('rev-parse','HEAD'))[0]
	[IO.File]::WriteAllText((Join-Path $GraphRepo 'accepted.txt'), 'accepted', (New-Object Text.UTF8Encoding($false)))
	$null = Invoke-GraphGit @('add','-A'); $null = Invoke-GraphGit @('commit','-qm','accepted'); $AdvancedBase=[string]@(Invoke-GraphGit @('rev-parse','HEAD'))[0]
	$null = Invoke-GraphGit @('checkout','-q','--detach',$EventBase)
	[IO.File]::WriteAllText((Join-Path $GraphRepo 'head.txt'), 'head', (New-Object Text.UTF8Encoding($false)))
	$null = Invoke-GraphGit @('add','-A'); $null = Invoke-GraphGit @('commit','-qm','head'); $EventHead=[string]@(Invoke-GraphGit @('rev-parse','HEAD'))[0]
	$HeadTree=[string]@(Invoke-GraphGit @('rev-parse',"$EventHead`^{tree}"))[0]
	$ValidMerge=(@('merge' | & git -C $GraphRepo commit-tree $HeadTree -p $AdvancedBase -p $EventHead) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Valid workflow merge fixture must exist.'
	$WrongHeadMerge=(@('wrong head' | & git -C $GraphRepo commit-tree $HeadTree -p $AdvancedBase -p $EventBase) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Wrong-head workflow merge fixture must exist.'
	$ForeignRoot=(@('foreign root' | & git -C $GraphRepo commit-tree $HeadTree) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Foreign-root workflow fixture must exist.'
	$ForeignMerge=(@('foreign merge' | & git -C $GraphRepo commit-tree $HeadTree -p $ForeignRoot -p $EventHead) -join '').Trim(); Assert-True ($LASTEXITCODE -eq 0) 'Foreign workflow merge fixture must exist.'
	$env:AETHELN_CONTROL_REPO = Join-Path $GraphRepo '.git'
	$env:GITHUB_OUTPUT = Join-Path $GraphFixture 'output.txt'
	$BaseSha=$EventBase; $HeadSha=$EventHead; $WorkflowSha=$ValidMerge
	[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
	. $GraphPreflight
	Assert-True ($WorkflowSha -ceq $ValidMerge -and $AcceptedSha -ceq $AdvancedBase -and ([IO.File]::ReadAllText($env:GITHUB_OUTPUT)).Trim() -ceq "accepted_base_sha=$AdvancedBase") 'The real workflow preflight must accept stale event base and output only the verified newer first parent.'
	foreach ($Invalid in @(
		@{ Name='foreign first parent'; Base=$EventBase; Merge=$ForeignMerge; Reason='event_base_not_accepted_ancestor' },
		@{ Name='divergent event base'; Base=$ForeignRoot; Merge=$ValidMerge; Reason='event_base_not_accepted_ancestor' },
		@{ Name='wrong second parent'; Base=$EventBase; Merge=$WrongHeadMerge; Reason='workflow_revision_parents_invalid' }
	)) {
		$BaseSha=$Invalid.Base; $WorkflowSha=$Invalid.Merge
		[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
		$Failure=$null
		try { . $GraphPreflight } catch { $Failure=$_.Exception.Message }
		Assert-True ($WorkflowSha -ceq $Invalid.Merge -and $Failure -ceq $Invalid.Reason -and ([IO.File]::ReadAllText($env:GITHUB_OUTPUT)).Length -eq 0) "$($Invalid.Name) must fail closed before publishing an accepted revision (got '$Failure')."
	}
}
finally {
	Remove-Item Env:AETHELN_CONTROL_REPO -ErrorAction SilentlyContinue
	Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
	if (Test-Path -LiteralPath $GraphFixture) { Remove-Item -LiteralPath $GraphFixture -Recurse -Force }
}
$SelectionRunBody = (($ShadowRunBlocks[1].Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_ } }) -join "`n"
$SelectionTokens = $null
$SelectionErrors = $null
$SelectionAst = [Management.Automation.Language.Parser]::ParseInput($SelectionRunBody, [ref] $SelectionTokens, [ref] $SelectionErrors)
$BoundedProcessFunction = $SelectionAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Invoke-BoundedProcessToFile' }, $true)
Assert-True ($null -ne $BoundedProcessFunction) 'The accepted-controller run block must define the bounded binary materializer.'
. ([scriptblock]::Create($BoundedProcessFunction.Extent.Text))
$AnchorValidatorFunction = $SelectionAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Assert-CurrentAttemptAnchor' }, $true)
Assert-True ($null -ne $AnchorValidatorFunction) 'The accepted-controller run block must define an exact current-attempt anchor validator.'
. ([scriptblock]::Create($AnchorValidatorFunction.Extent.Text))
$ValidAnchor = [pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='36290000000'; runAttempt=[long]2; nonce=('a' * 64) }
Assert-True ((Assert-CurrentAttemptAnchor -Anchor $ValidAnchor -ExpectedRunId '36290000000' -ExpectedRunAttempt 2) -ceq ('a' * 64)) 'The current-attempt anchor validator must return only the exact validated nonce.'
foreach ($InvalidAnchor in @(
	[pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId=36290000000; runAttempt=[long]2; nonce=('a' * 64) },
	[pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='36290000000'; runAttempt='2'; nonce=('a' * 64) },
	[pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='36290000000'; runAttempt=$true; nonce=('a' * 64) },
	[pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='36290000000'; runAttempt=[long]2; nonce=(('a' * 64) + "`n") },
	[pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='36290000000'; runAttempt=[long]2; nonce=('a' * 64); extra=$true }
)) {
	$AnchorFailure = $null
	try { Assert-CurrentAttemptAnchor -Anchor $InvalidAnchor -ExpectedRunId '36290000000' -ExpectedRunAttempt 2 | Out-Null }
	catch { $AnchorFailure = $_.Exception.Message }
	Assert-True ($AnchorFailure -ceq 'shadow_report_attempt_anchor_invalid') 'The validator must reject noncanonical types, trailing data, and open anchor schemas.'
}
$MaterializeFixture = Join-Path ([IO.Path]::GetTempPath()) ('AethelnBlobMaterialize-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($MaterializeFixture)
try {
	$SuccessScript = Join-Path $MaterializeFixture 'success.ps1'
	$TimeoutScript = Join-Path $MaterializeFixture 'timeout.ps1'
	$OutputFile = Join-Path $MaterializeFixture 'output.bin'
	$TimeoutOutput = Join-Path $MaterializeFixture 'timeout.bin'
	$ExpectedBytes = [byte[]](0, 10, 13, 26, 127, 128, 255)
	$EncodedBytes = [Convert]::ToBase64String($ExpectedBytes)
	$SuccessSource = "[Console]::Error.WriteLine(('e' * 131072)); [byte[]]`$Bytes=[Convert]::FromBase64String('$EncodedBytes'); [Console]::OpenStandardOutput().Write(`$Bytes,0,`$Bytes.Length)"
	[IO.File]::WriteAllText($SuccessScript, $SuccessSource, (New-Object Text.UTF8Encoding($false)))
	[IO.File]::WriteAllText($TimeoutScript, 'Start-Sleep -Seconds 5', (New-Object Text.UTF8Encoding($false)))
	Invoke-BoundedProcessToFile -FileName 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$SuccessScript`"" -OutputPath $OutputFile -TimeoutMilliseconds 5000
	$ActualBytes = [IO.File]::ReadAllBytes($OutputFile)
	Assert-True ([Convert]::ToBase64String($ExpectedBytes) -ceq [Convert]::ToBase64String($ActualBytes)) 'The bounded materializer must preserve exact binary stdout while concurrently draining large stderr.'
	$TimeoutFailure = $null
	try { Invoke-BoundedProcessToFile -FileName 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$TimeoutScript`"" -OutputPath $TimeoutOutput -TimeoutMilliseconds 100 }
	catch { $TimeoutFailure = $_.Exception.Message }
	Assert-True ($TimeoutFailure -ceq 'bounded_process_timeout' -and -not (Test-Path -LiteralPath $TimeoutOutput)) 'The bounded materializer must terminate a timed-out child and publish no output.'
} finally {
	if (Test-Path -LiteralPath $MaterializeFixture) { Remove-Item -LiteralPath $MaterializeFixture -Recurse -Force }
}

$VisualWorkflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\visual-package-validation.yml') -Raw
$VisualEvidenceRunner = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\Invoke-VisualPackageValidation.ps1') -Raw
foreach ($WorkflowSource in @($Workflow, $VisualWorkflow)) {
	$ActionUses = @([regex]::Matches($WorkflowSource, '(?m)^\s+(?:- )?uses: (?<action>actions/[^@\s]+@[^\s]+)\r?$'))
	Assert-True ($ActionUses.Count -gt 0) 'Each workflow must declare at least one approved remote action.'
	foreach ($ActionUse in $ActionUses) {
		$ActionIdentity = [string] $ActionUse.Groups['action'].Value
		Assert-True ($ActionIdentity -cin @($CheckoutAction, $DownloadAction, $UploadAction)) "Remote action '$ActionIdentity' must be in the exact reviewed SHA manifest."
		Assert-True ($ActionIdentity -cmatch '^actions/[a-z0-9-]+@[0-9a-f]{40}$') "Remote action '$ActionIdentity' must use one full lowercase commit SHA."
	}
}
Assert-MatchCount -Text $Workflow -Pattern "(?m)^\s+uses: $DownloadActionPattern\r?$" -Expected 10 -Message 'Package 3C must use the reviewed downloader exactly for two direct bindings per receipt, the aggregate selector binding, and the hard-disabled authority boundary.'

function Assert-AllPowerShellRunBlocksParse([string] $Text, [string] $Name, [int] $ExpectedCount) {
	$Lines = $Text -split "\r?\n"
	$ParsedCount = 0
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -notmatch '^(\s+)run: \|\s*$') { continue }
		$RunIndent = $Matches[1].Length
		$Body = @()
		for ($BodyIndex = $Index + 1; $BodyIndex -lt $Lines.Count; $BodyIndex++) {
			$Line = $Lines[$BodyIndex]
			if ($Line -eq '') { $Body += ''; continue }
			$Indent = [regex]::Match($Line, '^\s*').Length
			if ($Indent -le $RunIndent) { break }
			$Body += $Line
		}
		$NonEmpty = @($Body | Where-Object { $_ -ne '' })
		Assert-True ($NonEmpty.Count -gt 0) "$Name literal run block at line $($Index + 1) must not be empty."
		$BodyIndent = ($NonEmpty | ForEach-Object { [regex]::Match($_, '^\s*').Length } | Measure-Object -Minimum).Minimum
		$Script = (($Body | ForEach-Object { if ($_ -eq '') { '' } else { $_.Substring($BodyIndent) } }) -join "`n")
		# GitHub resolves expressions before the selected shell parses the script.
		# A neutral scalar exercises the resulting PowerShell 5.1 grammar without
		# pretending the expression syntax itself is PowerShell.
		$ResolvedScript = [regex]::Replace($Script, '\$\{\{[^\r\n}]+\}\}', '0')
		$ParseErrors = $null
		$null = [Management.Automation.Language.Parser]::ParseInput($ResolvedScript, [ref] $null, [ref] $ParseErrors)
		Assert-True ($ParseErrors.Count -eq 0) "$Name literal run block at line $($Index + 1) must parse under Windows PowerShell 5.1 after expression resolution: $($ParseErrors | Select-Object -First 1 | ForEach-Object Message)"
		$ParsedCount++
	}
	Assert-True ($ParsedCount -eq $ExpectedCount) "$Name must contain exactly $ExpectedCount reviewed literal PowerShell run blocks; found $ParsedCount."
}
Assert-AllPowerShellRunBlocksParse -Text $Workflow -Name 'Prototype workflow' -ExpectedCount 23
Assert-AllPowerShellRunBlocksParse -Text $VisualWorkflow -Name 'Visual workflow' -ExpectedCount 2

Assert-True ($VisualWorkflow -match '(?m)^  workflow_call:\r?$') 'Visual validation must expose an additive reusable workflow entry point.'
Assert-True ($VisualWorkflow -match '(?ms)^  pull_request:\r?\n    paths:.*?^  push:\r?\n    branches:\r?\n      - develop\r?\n    paths:') 'Visual validation must preserve its path-filtered pull-request and develop-push triggers.'
Assert-MatchCount -Text $VisualWorkflow -Pattern "(?m)^      - 'scripts/ci/Invoke-VisualPackageValidation\.ps1'\r?$" -Expected 2 -Message 'The production visual controller must trigger both direct pull-request and develop-push visual validation.'
Assert-True ($VisualWorkflow -match '(?ms)^      non_authoritative:\r?\n        description:.*?\r?\n        required: false\r?\n        type: boolean\r?\n        default: false\r?$') 'Direct visual triggers must remain authoritative while the reusable caller can request shadow behavior explicitly.'
Assert-True ($VisualWorkflow -match '(?m)^    continue-on-error: \$\{\{ inputs\.non_authoritative == true \}\}\r?$') 'Only an explicit reusable shadow call may neutralize the visual job conclusion.'
foreach ($OutputName in @('report_artifact_id','report_artifact_name','report_artifact_digest','report_sha256','report_size_bytes')) {
	$WorkflowCallBinding = [regex]::Escape('${{ jobs.validate.outputs.' + $OutputName + ' }}')
	Assert-True ($VisualWorkflow -match "(?ms)^      ${OutputName}:\r?\n        description:.*?\r?\n        value: $WorkflowCallBinding\r?$" -and [regex]::Matches($VisualWorkflow, "(?m)^      ${OutputName}: ").Count -eq 1) "Visual validation must expose direct report binding output '$OutputName' through workflow_call and validate-job output layers."
}
Assert-True ($VisualWorkflow -match [regex]::Escape('report_artifact_digest: sha256:${{ steps.report_artifact.outputs.artifact-digest }}')) 'Visual validation must normalize the upload action digest to the API-compatible sha256-prefixed form.'
Assert-True ($VisualWorkflow -match '(?m)^        id: report_artifact\r?$' -and $VisualWorkflow -match '(?m)^        id: report_identity\r?$') 'Visual validation must bind both the uploaded archive and exact raw evidence bytes.'
foreach ($Validator in @('.\visuals\Test-VisualPackage.ps1', '.\visuals\tests\Test-VisualPackageValidation.ps1')) {
	Assert-MatchCount -Text $VisualWorkflow -Pattern ([regex]::Escape($Validator)) -Expected 1 -Message "Visual workflow must preserve validator $Validator exactly once."
}
Assert-True ($VisualProof -match '(?m)^    needs: ci-selection-shadow\r?$' -and $VisualProof -match "needs\.ci-selection-shadow\.outputs\.visual_package_required == 'true'") 'The called visual proof may run only from the accepted-base shadow selection output.'
Assert-True ($VisualProof -match '(?m)^    uses: \./\.github/workflows/visual-package-validation\.yml\r?$') 'The additive visual proof must call the repository-owned reusable validator.'
Assert-True ($VisualProof -match '(?ms)^    with:\r?\n      non_authoritative: true\r?$') 'The selector-called visual proof must be explicitly non-authoritative.'
Assert-True ($VisualProof -notmatch 'self-hosted|aetheln-engine-runner|runs-on:') 'The called visual proof must not acquire engine-runner authority.'
Assert-True ($VisualWorkflow -match '(?m)^    timeout-minutes: 20\r?$') 'Visual validation must have an explicit hosted-runner bound.'
Assert-True ($VisualWorkflow -match 'Invoke-VisualPackageValidation\.ps1' -and $VisualEvidenceRunner -match 'aetheln\.visual-package-report/v1' -and $VisualWorkflow -match 'visual-package-report-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}') 'Visual validation must preserve attempt-specific machine-readable raw evidence.'
Assert-True ($VisualWorkflow -match 'path: \$\{\{ runner\.temp \}\}/aetheln-visual-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/visual-package-report\.json') 'Visual evidence upload must name one exact bounded report file.'
foreach ($Bound in @(
	'-MaxCapturedLinesPerValidator 200',
	'-MaxCapturedLineUtf8Bytes 4096',
	'-MaxCapturedUtf8BytesPerValidator 131072',
	'-MaxReportUtf8Bytes 4194304'
)) {
	Assert-True ($VisualWorkflow.Contains($Bound)) "Visual evidence invocation must explicitly bind $Bound."
}
Assert-True ($VisualEvidenceRunner -match '\| ForEach-Object \{' -and $VisualEvidenceRunner -notmatch '\$Output\s*=\s*@\(') 'Validator output must be reduced incrementally instead of being fully materialized before truncation.'
Assert-True ($VisualEvidenceRunner -match 'visual_report_configuration_exceeds_limit' -and $VisualEvidenceRunner -match 'visual_report_pre_serialization_limit') 'Visual evidence must reject unsafe configured and actual object bounds before JSON serialization.'
Assert-True ($VisualEvidenceRunner -match '\[IO\.FileMode\]::CreateNew' -and $VisualEvidenceRunner -notmatch '\[IO\.File\]::WriteAllText\(\$ReportPath') 'The final evidence report must be published create-only and never overwritten.'

foreach ($RawProducer in @(
	@{ Name='quality-gates'; Body=$QualityGates; ArtifactName='ci-report' },
	@{ Name='trusted-candidate-compile'; Body=$TrustedCompile; ArtifactName='engine-runner-compile-report' }
)) {
	$Body = [string] $RawProducer.Body
	foreach ($Binding in @(
		'report_artifact_id: ${{ steps.report_artifact.outputs.artifact-id }}',
		'report_artifact_name: ${{ steps.report_identity.outputs.artifact_name }}',
		'report_artifact_digest: sha256:${{ steps.report_artifact.outputs.artifact-digest }}',
		'report_sha256: ${{ steps.report_identity.outputs.evidence_sha256 }}',
		'report_size_bytes: ${{ steps.report_identity.outputs.evidence_size_bytes }}'
	)) {
		Assert-True ($Body.Contains($Binding)) "$($RawProducer.Name) must expose exact raw artifact/file binding '$Binding'."
	}
	Assert-True ($Body -match '(?m)^        id: report_identity\r?$' -and $Body -match '(?m)^        id: report_artifact\r?$' -and $Body -match [regex]::Escape('artifact_name=' + $RawProducer.ArtifactName)) "$($RawProducer.Name) must bind the exact raw file before exposing the upload action outputs."
}
Assert-True ($TrustedCompile -notmatch 'Get-FileHash' -and $TrustedCompile -match '\[Security\.Cryptography\.SHA256\]::Create\(\)' -and $TrustedCompile -match '\.ComputeHash\(\$ReportStream\)' -and $TrustedCompile -match '(?m)^          name: engine-runner-compile-report\r?$') 'The self-hosted compile report must use the portable .NET SHA-256 implementation and preserve its static artifact name even if binding fails.'

# TA-020: a separate owner-only engine job builds the editor target in the
# managed workspace through the bounded build wrapper and runs the frozen
# two-test harness from that workspace after a successful compile. The compile
# job keeps its pre-producer shape, so nothing here can fail it or skip the
# native receipt. Nothing Unreal prints reaches the public log: the harness
# streams go to runner-local files and only a path-free summary is printed.
Assert-True (((($TrustedCompile -split '\r?\n') | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") -notmatch '(?i)automation|AethelnOnlineEditor|editor_build') 'The compile job must carry no editor automation.'
Assert-True ($EditorAutomation -match "(?m)^    needs: trusted-candidate-compile\r?\n    if: >-\r?\n      github\.event_name == 'pull_request' &&\r?\n      github\.event\.pull_request\.head\.repo\.full_name == github\.repository &&\r?\n      github\.event\.pull_request\.user\.login == github\.repository_owner &&\r?\n      github\.triggering_actor == github\.repository_owner\r?\n    runs-on: \[self-hosted, Windows, X64, aetheln-engine\]\r?$") 'Editor automation must run only after a successful compile under the same owner and same-repository trust.'
Assert-True ($EditorAutomation -match '(?m)^    timeout-minutes: 35\r?$' -and $EditorAutomation -match '(?ms)^    concurrency:\r?\n      group: aetheln-engine-runner\r?\n      queue: max\r?\n      cancel-in-progress: false\r?$' -and $EditorAutomation -notmatch 'needs\.[a-z-]+\.result|always\(\)|actions/checkout') 'Editor automation must have its own 35-minute ceiling, join the FIFO engine queue, and add no status bypass or checkout.'
foreach ($Binding in @(
	'automation_artifact_id: ${{ steps.automation_artifact.outputs.artifact-id }}',
	'automation_artifact_name: ${{ steps.automation_identity.outputs.artifact_name }}',
	'automation_artifact_digest: sha256:${{ steps.automation_artifact.outputs.artifact-digest }}',
	'automation_sha256: ${{ steps.automation_identity.outputs.evidence_sha256 }}',
	'automation_size_bytes: ${{ steps.automation_identity.outputs.evidence_size_bytes }}',
	'automation_reason: ${{ steps.automation_outcome.outputs.reason }}'
)) {
	Assert-True ($EditorAutomation.Contains($Binding)) "trusted-editor-automation must expose exact automation artifact/file binding '$Binding'."
}
$EditorBuild = [regex]::Match($EditorAutomation, '(?ms)^      - name: Build editor target for Unreal automation\r?\n.*?(?=^      - )').Value
$AutomationRun = [regex]::Match($EditorAutomation, '(?ms)^      - name: Run frozen Unreal automation filter\r?\n.*?(?=^      - )').Value
$AutomationResidue = [regex]::Match($EditorAutomation, '(?ms)^      - name: Clear editor-written input residue\r?\n.*?(?=^      - )').Value
$AutomationBind = [regex]::Match($EditorAutomation, '(?ms)^      - name: Bind Unreal automation report\r?\n.*?(?=^      - )').Value
$AutomationUpload = [regex]::Match($EditorAutomation, '(?ms)^      - name: Upload Unreal automation report\r?\n.*?(?=^      - )').Value
$AutomationOutcome = [regex]::Match($EditorAutomation, '(?ms)^      - name: Report Unreal automation outcome\r?\n.*?(?=\r?\n\r?\n|\z)').Value
Assert-True ($EditorBuild -and $AutomationRun -and $AutomationResidue -and $AutomationBind -and $AutomationUpload -and $AutomationOutcome) 'Editor automation must declare every reviewed step.'
# Unreal failures stay on the unreal side: every automation step that can fail
# continues on error, so the compile job and native receipt survive, while
# binding and upload require every automation step to have succeeded. A
# missing automation artifact then fails unreal-receipt-shadow at its raw
# binding check instead of passing silently.
$AutomationSuccess = "if: steps.editor_build.outcome == 'success' && steps.automation_run.outcome == 'success' && steps.automation_residue.outcome == 'success'"
foreach ($Step in @(
	@{ Name='editor build'; Body=$EditorBuild; Id='editor_build'; If=$null; Timeout='15'; Continue=$true },
	@{ Name='harness'; Body=$AutomationRun; Id='automation_run'; If="if: steps.editor_build.outcome == 'success'"; Timeout='12'; Continue=$true },
	@{ Name='residue cleanup'; Body=$AutomationResidue; Id='automation_residue'; If=$null; Timeout='2'; Continue=$true },
	@{ Name='bind'; Body=$AutomationBind; Id='automation_identity'; If=$AutomationSuccess; Timeout='1'; Continue=$true },
	@{ Name='upload'; Body=$AutomationUpload; Id='automation_artifact'; If=($AutomationSuccess + " && steps.automation_identity.outcome == 'success'"); Timeout='1'; Continue=$true },
	@{ Name='outcome report'; Body=$AutomationOutcome; Id='automation_outcome'; If=$null; Timeout='1'; Continue=$true }
)) {
	$Body = [string] $Step.Body
	Assert-True ($Body -match ('(?m)^        id: ' + $Step.Id + '\r?$')) "The automation $($Step.Name) step must carry id '$($Step.Id)'."
	if ($null -eq $Step.If) { Assert-True ($Body -notmatch '(?m)^        if:') "The automation $($Step.Name) step must not carry its own condition." }
	else { Assert-True ($Body -match ('(?m)^        ' + [regex]::Escape($Step.If) + '\r?$') -and [regex]::Matches($Body, '(?m)^        if:').Count -eq 1) "The automation $($Step.Name) step must use exactly the reviewed condition." }
	if ($null -eq $Step.Timeout) { Assert-True ($Body -notmatch '(?m)^        timeout-minutes:') "The automation $($Step.Name) step needs no separate bound." }
	else { Assert-True ($Body -match ('(?m)^        timeout-minutes: ' + $Step.Timeout + '\r?$')) "The automation $($Step.Name) step must be bounded to $($Step.Timeout) minutes." }
	if ($Step.Continue) { Assert-True ($Body -match '(?m)^        continue-on-error: true\r?$') "The automation $($Step.Name) step must not fail the compile job." }
	else { Assert-True ($Body -notmatch 'continue-on-error') "The automation $($Step.Name) step must fail red once every automation step succeeded." }
}
Assert-True ($UnrealReceipt -match "(?ms)^      - name: Download exact unreal evidence\r?\n        if: needs\.trusted-editor-automation\.outputs\.automation_artifact_id != ''\r?\n") 'A missing automation artifact must skip the unreal download so the publisher fails at its raw binding check rather than downloading every run artifact.'
# The editor build builds only the exact clean revision the compile used:
# another engine job may have synchronized the workspace in between.
Assert-True ($EditorBuild.Contains("(Get-WorkspaceGitText 'rev-parse HEAD').Trim() -cne `$env:GITHUB_SHA") -and $EditorBuild.Contains("Exit-Automation 'editor_workspace_revision_changed'") -and $EditorBuild.Contains("Exit-Automation 'editor_workspace_dirty'") -and $EditorBuild.IndexOf('editor_workspace_dirty') -lt $EditorBuild.IndexOf('InitialPreparation.BuildInvocation.ps1') -and $EditorBuild -notmatch 'AETHELN_COMPILE_STARTED|RequiredSeconds|budget') 'The editor build must verify the exact clean workspace revision before it starts and carry no budget gate.'
Assert-True ([regex]::Matches($AutomationRun, 'Write-Output').Count -eq 1 -and $AutomationRun.Contains("Write-Output ('unreal_automation result={0} reason={1} total={2} passed={3} requiredFailed={4} exit={5}' -f")) 'The harness step may print only the fixed path-free summary line.'
# The editor build prints only the two masks and the
# wrapper's native-result.json (target, platform, exit code, failure class).
Assert-True ([regex]::Matches($EditorBuild, 'Write-Output').Count -eq 3 -and $EditorBuild.Contains('Write-Output $ResultText') -and $EditorBuild.Contains('$ResultText = [IO.File]::ReadAllText($ResultPath)') -and $EditorBuild.Contains("`$ResultPath = Join-Path `$EvidenceRoot 'native-result.json'")) 'The editor build may print only the masks and the bounded native result record.'
# UBT exit 5 (-NoEngineChanges, deferred by TA-020) keeps its own fixed reason, checked before the generic failure.
Assert-True ($EditorBuild.Contains("elseif (`$BuildExit -eq 5) { Exit-Automation 'editor_build_engine_changes_required' }") -and $EditorBuild.IndexOf('editor_build_engine_changes_required') -lt $EditorBuild.IndexOf("'editor_build_failed'")) 'The editor build must map UBT exit 5 to editor_build_engine_changes_required before editor_build_failed.'
$ManagedWorkspaceSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\ManagedCompileWorkspace.ps1') -Raw
$UntrackedInputQuery = [regex]::Matches($ManagedWorkspaceSource, "'(ls-files --others -z -- [^']+)'")
Assert-True ($AutomationResidue.Contains("(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source") -and $AutomationResidue.Contains('''--no-replace-objects --no-optional-locks -C "'' + $Root + ''" '' + $Query')) 'Residue cleanup must resolve and invoke git exactly as the managed sync does.'
# A red unreal receipt must say why: every automation step records a fixed
# failure reason, the outcome step exposes the first one as a job output, and
# the unreal publisher prints it as one fixed-vocabulary line.
$StopAutomation = 'function Exit-Automation([string] $Reason) { [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "reason=$Reason`n", (New-Object Text.UTF8Encoding $false)); throw $Reason }'
foreach ($Step in @($EditorBuild, $AutomationRun, $AutomationResidue, $AutomationBind)) {
	Assert-True ($Step.Contains($StopAutomation) -and $Step -notmatch "\bthrow '") 'Every automation failure must record its fixed reason before it stops.'
}
Assert-True ($AutomationOutcome.Contains('AETHELN_UPLOAD_OUTCOME: ${{ steps.automation_artifact.outcome }}') -and $AutomationOutcome.Contains("'automation_report_upload_failed'") -and $AutomationOutcome.Contains('Write-Output (''unreal_automation_outcome reason='' + $Reason)') -and [regex]::Matches($AutomationOutcome, 'Write-Output').Count -eq 1) 'The outcome step must expose the first automation failure as one fixed line.'
Assert-True ($UnrealReceipt.Contains('AETHELN_AUTOMATION_REASON: ${{ needs.trusted-editor-automation.outputs.automation_reason }}') -and $UnrealReceipt.Contains('Write-Output (''unreal_automation_outcome reason='' + $AutomationReason)') -and $UnrealReceipt.IndexOf('unreal_automation_outcome reason=') -lt $UnrealReceipt.IndexOf("throw 'unreal_raw_artifact_binding_invalid'")) 'The unreal publisher must print the fixed automation reason before its binding check.'
Assert-True ($UntrackedInputQuery.Count -eq 1 -and $AutomationResidue.Contains("'" + $UntrackedInputQuery[0].Groups[1].Value + "'")) 'Residue cleanup must use exactly the untracked-input query that the next managed sync enforces.'

function Get-WorkflowStepScript([string] $Step) {
	$Run = [regex]::Match($Step, '(?ms)^        run: \|\r?\n(?<body>.*)\z')
	Assert-True $Run.Success 'Automation step must have a literal run block.'
	# The literal block ends at the first nonblank line indented less than its body.
	$Lines = New-Object Collections.Generic.List[string]
	foreach ($Line in ($Run.Groups['body'].Value -split '\r?\n')) {
		if ($Line.Trim().Length -ne 0 -and -not $Line.StartsWith(' ' * 10)) { break }
		$Lines.Add($(if ($Line.Length -ge 10) { $Line.Substring(10) } else { '' }))
	}
	$Script = $Lines -join "`n"
	return $Script.Replace('${{ runner.temp }}', $script:AutomationFixtureTemp).Replace('${{ github.run_id }}', '1').Replace('${{ github.run_attempt }}', '1').Replace('${{ github.job }}', 'job')
}
function Invoke-AutomationStepFixture([string] $Step) {
	$Previous = $ErrorActionPreference
	# Output stays collected when the step stops, so failures can be checked for leaks too.
	$Output = New-Object Collections.Generic.List[string]
	try {
		& ([scriptblock]::Create((Get-WorkflowStepScript $Step))) 2>&1 | ForEach-Object { $Output.Add([string] $_) }
		return [pscustomobject]@{ failure = $null; output = @($Output) }
	} catch { return [pscustomobject]@{ failure = $_.Exception.Message; output = @($Output) } }
	finally { $ErrorActionPreference = $Previous }
}
function Invoke-AutomationFixtureGit([string] $Root, [string[]] $Arguments) {
	$Previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try { $null = & git -C $Root @Arguments 2>&1; $Exit = $LASTEXITCODE } finally { $ErrorActionPreference = $Previous }
	Assert-True ($Exit -eq 0) "Fixture git $($Arguments[0]) failed."
}
$AutomationFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-automation-steps-' + [guid]::NewGuid().ToString('N'))
$script:AutomationFixtureTemp = Join-Path $AutomationFixtureRoot 'temp'
$null = New-Item -ItemType Directory -Path (Join-Path $script:AutomationFixtureTemp 'aetheln-engine-1-1-job')
$PreviousAutomationEnvironment = @{}
foreach ($Name in @('GITHUB_SHA', 'AETHELN_MANAGED_COMPILE_ROOT', 'AETHELN_ENGINE_ROOT', 'AETHELN_LINUX_TOOLCHAIN_ROOT', 'GITHUB_OUTPUT')) { $PreviousAutomationEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name) }
try {
	$env:AETHELN_ENGINE_ROOT = Join-Path $AutomationFixtureRoot 'engine'
	$env:GITHUB_OUTPUT = Join-Path $AutomationFixtureRoot 'github-output.txt'
	# Workspace gate: a moved, dirty, or unreadable workspace stops before any build input is touched.
	$WorkspaceRepo = Join-Path $AutomationFixtureRoot 'workspace'
	$null = New-Item -ItemType Directory -Path $WorkspaceRepo
	[IO.File]::WriteAllText((Join-Path $WorkspaceRepo 'tracked.txt'), "tracked`n")
	Invoke-AutomationFixtureGit $WorkspaceRepo @('init', '-q')
	Invoke-AutomationFixtureGit $WorkspaceRepo @('add', '-A')
	Invoke-AutomationFixtureGit $WorkspaceRepo @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '-m', 'fixture')
	$WorkspaceHead = ([string] (& git -C $WorkspaceRepo rev-parse HEAD)).Trim()
	$NotRepository = Join-Path $AutomationFixtureRoot 'not-a-repository'
	$null = New-Item -ItemType Directory -Path $NotRepository
	foreach ($WorkspaceCase in @(
		@{ root=$WorkspaceRepo; sha=('f' * 40); dirty=$false; reason='editor_workspace_revision_changed' },
		@{ root=$WorkspaceRepo; sha=$WorkspaceHead; dirty=$true; reason='editor_workspace_dirty' },
		@{ root=$NotRepository; sha=$WorkspaceHead; dirty=$false; reason='editor_workspace_query_failed' }
	)) {
		if ($WorkspaceCase.dirty) { [IO.File]::WriteAllText((Join-Path $WorkspaceRepo 'untracked.txt'), 'editor output') }
		$env:AETHELN_MANAGED_COMPILE_ROOT = $WorkspaceCase.root
		$env:GITHUB_SHA = $WorkspaceCase.sha
		[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
		$Gated = Invoke-AutomationStepFixture $EditorBuild
		Assert-True ($Gated.failure -ceq $WorkspaceCase.reason -and [IO.File]::ReadAllText($env:GITHUB_OUTPUT) -ceq ('reason=' + $WorkspaceCase.reason + "`n") -and -not (Test-Path -LiteralPath (Join-Path $script:AutomationFixtureTemp 'aetheln-engine-1-1-job/editor-build'))) "A workspace that fails '$($WorkspaceCase.reason)' must stop before the editor build."
	}
	# Editor build exit mapping (TA-020): through the workspace copy of the
	# wrapper, UBT exit 5 (a deferred -NoEngineChanges refusal) records
	# editor_build_engine_changes_required, any other exit editor_build_failed,
	# and the refused engine file list stays in the runner-local build.log.
	$EditorWorkspace = Join-Path $AutomationFixtureRoot 'editor-workspace'
	$null = New-Item -ItemType Directory -Path (Join-Path $EditorWorkspace 'scripts\ci')
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\InitialPreparation.BuildInvocation.ps1') -Destination (Join-Path $EditorWorkspace 'scripts\ci')
	[IO.File]::WriteAllText((Join-Path $EditorWorkspace 'AethelnOnline.uproject'), '{}')
	Invoke-AutomationFixtureGit $EditorWorkspace @('init', '-q')
	Invoke-AutomationFixtureGit $EditorWorkspace @('add', '-A')
	Invoke-AutomationFixtureGit $EditorWorkspace @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '-m', 'fixture')
	$null = New-Item -ItemType Directory -Path (Join-Path $env:AETHELN_ENGINE_ROOT 'Engine/Build/BatchFiles'), (Join-Path $env:AETHELN_ENGINE_ROOT 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64')
	[IO.File]::WriteAllText((Join-Path $env:AETHELN_ENGINE_ROOT 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe'), 'fixture')
	[IO.File]::WriteAllText((Join-Path $env:AETHELN_ENGINE_ROOT 'Engine/Build/BatchFiles/Build.bat'), "@echo off`r`necho Building would modify the following existing engine files:`r`necho %~dp0UnrealEditor-Fixture.dll`r`nexit /b %AETHELN_FIXTURE_NATIVE_EXIT%`r`n")
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $AutomationFixtureRoot
	$env:AETHELN_MANAGED_COMPILE_ROOT = $EditorWorkspace
	$env:GITHUB_SHA = ([string] (& git -C $EditorWorkspace rev-parse HEAD)).Trim()
	$EditorBuildEvidence = Join-Path $script:AutomationFixtureTemp 'aetheln-engine-1-1-job/editor-build'
	try {
		foreach ($ExitCase in @(@{ exit = '5'; reason = 'editor_build_engine_changes_required' }, @{ exit = '7'; reason = 'editor_build_failed' }, @{ exit = '0'; reason = $null })) {
			$env:AETHELN_FIXTURE_NATIVE_EXIT = $ExitCase.exit
			[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
			$Built = Invoke-AutomationStepFixture $EditorBuild
			$ExpectedOutput = if ($null -eq $ExitCase.reason) { '' } else { 'reason=' + $ExitCase.reason + "`n" }
			$Visible = (@($Built.output | Where-Object { -not $_.StartsWith('::add-mask::') }) -join "`n")
			Assert-True ($Built.failure -ceq $ExitCase.reason -and [IO.File]::ReadAllText($env:GITHUB_OUTPUT) -ceq $ExpectedOutput) "Editor build exit $($ExitCase.exit) must record '$($ExitCase.reason)'."
			Assert-True ($Visible.Contains('"nativeExitCode":' + $ExitCase.exit) -and -not $Visible.Contains($env:AETHELN_ENGINE_ROOT) -and -not $Visible.Contains('Building would modify') -and [IO.File]::ReadAllText((Join-Path $EditorBuildEvidence 'build.log')).Contains('Building would modify')) "Editor build exit $($ExitCase.exit) must print only the native result record, never engine paths."
			Remove-Item -LiteralPath $EditorBuildEvidence -Recurse -Force
		}
	} finally { Remove-Item Env:AETHELN_FIXTURE_NATIVE_EXIT -ErrorAction SilentlyContinue }
	$env:AETHELN_MANAGED_COMPILE_ROOT = Join-Path $AutomationFixtureRoot 'managed'
	[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')

	# The harness step summarizes a well-formed report and records
	# unreal_automation_report_invalid for a malformed one.
	$HarnessManaged = Join-Path $AutomationFixtureRoot 'harness-managed'
	$null = New-Item -ItemType Directory -Path (Join-Path $HarnessManaged 'scripts\ci'), (Join-Path $HarnessManaged 'TestResults')
	[IO.File]::WriteAllText((Join-Path $HarnessManaged 'scripts\ci\Invoke-UnrealAutomationTests.ps1'), "param([string] `$EngineRoot, [int] `$TimeoutSeconds)`n[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '..\..\TestResults\unreal-automation-report.json'), `$env:AETHELN_FIXTURE_REPORT)`nexit [int] `$env:AETHELN_FIXTURE_EXIT`n")
	$PreviousHarnessManaged = $env:AETHELN_MANAGED_COMPILE_ROOT
	$env:AETHELN_MANAGED_COMPILE_ROOT = $HarnessManaged
	try {
		foreach ($HarnessCase in @(
			@{ report='{"result":"passed","failureReason":"none","summary":{"total":2,"passed":2,"requiredFailed":0}}'; exit='0'; failure=$null; output='unreal_automation result=passed reason=none total=2 passed=2 requiredFailed=0 exit=0' },
			@{ report='{"result":"passed","failureReason":"none","summary":{"total":"2","passed":2}}'; exit='0'; failure='unreal_automation_report_invalid'; output='' },
			@{ report='{"result":"failed","failureReason":"test-failure","summary":{"total":2,"passed":1,"requiredFailed":1}}'; exit='1'; failure='unreal_automation_test_failure'; output='unreal_automation result=failed reason=test-failure total=2 passed=1 requiredFailed=1 exit=1' }
		)) {
			$env:AETHELN_FIXTURE_REPORT = $HarnessCase.report
			$env:AETHELN_FIXTURE_EXIT = $HarnessCase.exit
			[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
			$Harnessed = Invoke-AutomationStepFixture $AutomationRun
			$ExpectedOutput = if ($null -eq $HarnessCase.failure) { '' } else { 'reason=' + $HarnessCase.failure + "`n" }
			Assert-True ($Harnessed.failure -ceq $HarnessCase.failure -and [IO.File]::ReadAllText($env:GITHUB_OUTPUT) -ceq $ExpectedOutput -and ($null -ne $HarnessCase.failure -or (@($Harnessed.output) -join "`n") -ceq $HarnessCase.output)) "The harness step must handle report case '$($HarnessCase.exit)/$($HarnessCase.failure)'."
		}
	} finally {
		$env:AETHELN_MANAGED_COMPILE_ROOT = $PreviousHarnessManaged
		Remove-Item Env:AETHELN_FIXTURE_REPORT, Env:AETHELN_FIXTURE_EXIT -ErrorAction SilentlyContinue
	}

	# The outcome step reports the first failed step's fixed reason, a fixed
	# fallback for an unrecorded or malformed one, and 'none' after success.
	foreach ($OutcomeCase in @(
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='failure'; AETHELN_EDITOR_BUILD_REASON='editor_build_budget_exhausted'; AETHELN_RUN_OUTCOME='skipped'; AETHELN_RESIDUE_OUTCOME='success'; AETHELN_BIND_OUTCOME='skipped'; AETHELN_UPLOAD_OUTCOME='skipped' }; expected='editor_build_budget_exhausted' },
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='failure'; AETHELN_EDITOR_BUILD_REASON='editor_build_engine_changes_required'; AETHELN_RUN_OUTCOME='skipped'; AETHELN_RESIDUE_OUTCOME='success'; AETHELN_BIND_OUTCOME='skipped'; AETHELN_UPLOAD_OUTCOME='skipped' }; expected='editor_build_engine_changes_required' },
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='success'; AETHELN_RUN_OUTCOME='failure'; AETHELN_RUN_REASON='C:\leak path'; AETHELN_RESIDUE_OUTCOME='success'; AETHELN_BIND_OUTCOME='skipped'; AETHELN_UPLOAD_OUTCOME='skipped' }; expected='unreal_automation_interrupted' },
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='success'; AETHELN_RUN_OUTCOME='failure'; AETHELN_RUN_REASON='unreal_automation_test_failure'; AETHELN_RESIDUE_OUTCOME='failure'; AETHELN_RESIDUE_REASON='automation_input_residue_remaining'; AETHELN_BIND_OUTCOME='skipped'; AETHELN_UPLOAD_OUTCOME='skipped' }; expected='unreal_automation_test_failure' },
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='success'; AETHELN_RUN_OUTCOME='success'; AETHELN_RESIDUE_OUTCOME='success'; AETHELN_BIND_OUTCOME='success'; AETHELN_UPLOAD_OUTCOME='failure' }; expected='automation_report_upload_failed' },
		@{ env=@{ AETHELN_EDITOR_BUILD_OUTCOME='success'; AETHELN_RUN_OUTCOME='success'; AETHELN_RESIDUE_OUTCOME='success'; AETHELN_BIND_OUTCOME='success'; AETHELN_UPLOAD_OUTCOME='success' }; expected='none' }
	)) {
		$OutcomeNames = @('AETHELN_EDITOR_BUILD_OUTCOME', 'AETHELN_EDITOR_BUILD_REASON', 'AETHELN_RUN_OUTCOME', 'AETHELN_RUN_REASON', 'AETHELN_RESIDUE_OUTCOME', 'AETHELN_RESIDUE_REASON', 'AETHELN_BIND_OUTCOME', 'AETHELN_BIND_REASON', 'AETHELN_UPLOAD_OUTCOME')
		foreach ($Name in $OutcomeNames) { [Environment]::SetEnvironmentVariable($Name, [string] $OutcomeCase.env[$Name]) }
		[IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
		$Outcome = Invoke-AutomationStepFixture $AutomationOutcome
		foreach ($Name in $OutcomeNames) { [Environment]::SetEnvironmentVariable($Name, $null) }
		Assert-True ($null -eq $Outcome.failure -and (@($Outcome.output) -join "`n") -ceq ('unreal_automation_outcome reason=' + $OutcomeCase.expected) -and [IO.File]::ReadAllText($env:GITHUB_OUTPUT) -ceq ('reason=' + $OutcomeCase.expected + "`n")) "The automation outcome must be '$($OutcomeCase.expected)'."
	}

	# Residue cleanup removes exactly the untracked compile-input files the next
	# managed sync would reject and leaves retained and unrelated outputs alone.
	$ResidueRepo = Join-Path $AutomationFixtureRoot 'managed'
	$null = New-Item -ItemType Directory -Path (Join-Path $ResidueRepo 'Source')
	[IO.File]::WriteAllText((Join-Path $ResidueRepo '.gitignore'), "Generated/`n*.gen`nBinaries/`nIntermediate/`nSaved/`n")
	[IO.File]::WriteAllText((Join-Path $ResidueRepo 'Source/Keep.cpp'), "tracked`n")
	Invoke-AutomationFixtureGit $ResidueRepo @('init', '-q')
	Invoke-AutomationFixtureGit $ResidueRepo @('add', '-A')
	Invoke-AutomationFixtureGit $ResidueRepo @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '-m', 'fixture')
	$Residue = @('Source/Generated/Editor.h', 'Config/Editor.gen', 'Content/Unexpected.uasset')
	$Retained = @('Source/Keep.cpp', 'Binaries/Win64/Editor.dll', 'Plugins/Fixture/Intermediate/Build.obj', 'Saved/Logs/Editor.log')
	foreach ($Relative in ($Residue + $Retained | Where-Object { $_ -cne 'Source/Keep.cpp' })) {
		$Path = Join-Path $ResidueRepo $Relative
		$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
		[IO.File]::WriteAllText($Path, 'editor output')
	}
	$Cleared = Invoke-AutomationStepFixture $AutomationResidue
	Assert-True ($null -eq $Cleared.failure -and (@($Cleared.output) -join "`n") -ceq 'automation_input_residue removed=3') 'Residue cleanup must report only the removed count.'
	Assert-True (@($Residue | Where-Object { Test-Path -LiteralPath (Join-Path $ResidueRepo $_) }).Count -eq 0 -and @($Retained | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ResidueRepo $_)) }).Count -eq 0) 'Residue cleanup must remove only untracked compile-input files.'
	$Repeated = Invoke-AutomationStepFixture $AutomationResidue
	Assert-True ($null -eq $Repeated.failure -and (@($Repeated.output) -join "`n") -ceq 'automation_input_residue removed=0') 'Residue cleanup must be idempotent.'

	# The editor target reaches Build.bat only as a Win64 build through the
	# bounded wrapper; Linux stays server-only.
	$EditorRoot = Join-Path $AutomationFixtureRoot 'editor-target'
	$EditorBatch = Join-Path $EditorRoot 'Engine/Build/BatchFiles'
	$null = New-Item -ItemType Directory -Path $EditorBatch
	$EditorDotnet = Join-Path $EditorRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64'
	$null = New-Item -ItemType Directory -Path $EditorDotnet
	[IO.File]::WriteAllText((Join-Path $EditorDotnet 'dotnet.exe'), 'fixture')
	[IO.File]::WriteAllText((Join-Path $EditorBatch 'Build.bat'), "@echo off`r`necho build-args %1 %2`r`nexit /b 0`r`n")
	[IO.File]::WriteAllText((Join-Path $EditorRoot 'AethelnOnline.uproject'), '{}')
	foreach ($EditorCase in @(@{ platform = 'Win64'; exit = 0 }, @{ platform = 'Linux'; exit = 1 })) {
		$EditorEvidence = Join-Path $EditorRoot ('evidence-' + $EditorCase.platform)
		$null = New-Item -ItemType Directory -Path $EditorEvidence
		& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $RepositoryRoot 'scripts/ci/InitialPreparation.BuildInvocation.ps1') `
			-Target AethelnOnlineEditor -Platform $EditorCase.platform -ActionLimit 1 -EngineRoot $EditorRoot -TargetRoot $EditorRoot -LinuxToolchainRoot $EditorRoot -EvidenceRoot $EditorEvidence 2>&1 | Out-Null
		Assert-True ($LASTEXITCODE -eq $EditorCase.exit) "Editor target on $($EditorCase.platform) must exit $($EditorCase.exit)."
		$EditorResultPath = Join-Path $EditorEvidence 'native-result.json'
		if ($EditorCase.exit -eq 0) {
			$EditorRecord = Get-Content -LiteralPath $EditorResultPath -Raw | ConvertFrom-Json
			Assert-True ($EditorRecord.target -ceq 'AethelnOnlineEditor' -and $EditorRecord.platform -ceq 'Win64' -and $EditorRecord.nativeExitCode -eq 0 -and $null -eq $EditorRecord.infrastructureFailure -and [IO.File]::ReadAllText((Join-Path $EditorEvidence 'build.log')).Contains('build-args AethelnOnlineEditor Win64')) 'Editor target must reach Build.bat as a Win64 build.'
		} else {
			Assert-True (-not (Test-Path -LiteralPath $EditorResultPath) -and -not (Test-Path -LiteralPath (Join-Path $EditorEvidence 'build.log'))) 'Editor target must be rejected on Linux before Build.bat runs.'
		}
	}
} finally {
	foreach ($Name in $PreviousAutomationEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $PreviousAutomationEnvironment[$Name]) }
	Remove-Item -LiteralPath $AutomationFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ($EditorBuild.Contains('powershell -NoProfile -File (Join-Path $Root ''scripts\ci\InitialPreparation.BuildInvocation.ps1'') `') -and $EditorBuild -match '(?m)^\s+-Target AethelnOnlineEditor `\r?$' -and $EditorBuild -match '(?m)^\s+-Platform Win64 `\r?$' -and $EditorBuild -match '(?m)^\s+-TargetRoot \$env:AETHELN_MANAGED_COMPILE_ROOT `\r?$' -and $EditorBuild -match '(?m)^\s+-EngineRoot \$env:AETHELN_ENGINE_ROOT `\r?$' -and $EditorBuild -notmatch 'Build\.bat') 'The editor target must be built in the managed workspace only through the bounded capture wrapper.'
Assert-True ($EditorBuild.Contains('::add-mask::$env:AETHELN_ENGINE_ROOT') -and $EditorBuild.Contains('::add-mask::$env:AETHELN_MANAGED_COMPILE_ROOT')) 'Runner-local engine and workspace roots must be masked before any automation step runs.'
Assert-True ($AutomationRun -match [regex]::Escape("Join-Path `$env:AETHELN_MANAGED_COMPILE_ROOT 'scripts\ci\Invoke-UnrealAutomationTests.ps1'") -and $AutomationRun -match '-EngineRoot' -and $AutomationRun.Contains('$env:AETHELN_ENGINE_ROOT') -and $AutomationRun -match "'-TimeoutSeconds', '600'" -and $AutomationRun -match '(?m)^        timeout-minutes: \d+\r?$') 'The frozen harness must run from the managed workspace against the runner engine root with its bounded timeout.'
Assert-True ($AutomationRun -match '-RedirectStandardOutput' -and $AutomationRun -match '-RedirectStandardError' -and $AutomationRun -notmatch 'Get-Content[^\r\n]*\.log' -and $AutomationRun -notmatch 'Write-Output \$Report\b') 'Unreal and harness output must stay in runner-local files; only a bounded summary may reach the log.'
Assert-True ($AutomationBind -match '(?m)^        id: automation_identity\r?$' -and $AutomationBind -match '\[Security\.Cryptography\.SHA256\]::Create\(\)' -and $AutomationBind.Contains('artifact_name=unreal-automation-report') -and $AutomationBind -notmatch 'if: always\(\)') 'The automation report must be bound with the portable SHA-256 implementation and only after a passing harness.'
Assert-True ($EditorAutomation -match '(?m)^        id: automation_artifact\r?$' -and $EditorAutomation -match '(?m)^          name: unreal-automation-report\r?$' -and $EditorAutomation.Contains('path: ${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/unreal-automation-report.json')) 'The automation report upload must be one exact run/attempt/job-scoped file.'

# Package 3C receipt publishers are additive PR-only hosted jobs. Each consumes
# the selector and exactly one raw producer through immutable artifact IDs,
# publishes one nonce-bound receipt directory, and exposes only the upload
# action's direct artifact binding. They never acquire engine-runner authority.
$ReceiptContracts = @(
	@{ Name='portable-receipt-shadow'; Body=$PortableReceipt; Predicate="needs\.ci-selection-shadow\.outputs\.portable_required == 'true'"; Producer='quality-gates'; ArtifactOutput='report_artifact_id'; Key='portable'; RawName="'ci-report'"; Evidence='portable' },
	# The native publisher proves native-client-server-compile and controller-operational-proof from one compile report, so either selection runs it.
	@{ Name='native-receipt-shadow'; Body=$NativeReceipt; Predicate="\(needs\.ci-selection-shadow\.outputs\.native_client_server_compile_required == 'true' \|\| needs\.ci-selection-shadow\.outputs\.controller_operational_proof_required == 'true'\)"; Producer='trusted-candidate-compile'; ArtifactOutput='report_artifact_id'; Key='native'; RawName="'engine-runner-compile-report'"; Evidence='native' },
	# The unreal publisher consumes the raw report of the separate editor automation job.
	@{ Name='unreal-receipt-shadow'; Body=$UnrealReceipt; Predicate="needs\.ci-selection-shadow\.outputs\.unreal_editor_automation_required == 'true'"; Producer='trusted-editor-automation'; ArtifactOutput='automation_artifact_id'; Key='unreal'; RawName="'unreal-automation-report'"; Evidence='unreal' },
	@{ Name='visual-receipt-shadow'; Body=$VisualReceipt; Predicate="needs\.ci-selection-shadow\.outputs\.visual_package_required == 'true'"; Producer='visual-proof'; ArtifactOutput='report_artifact_id'; Key='visual'; RawName="'visual-package-report-'"; Evidence='visual' }
)
# aggregate_ready and the context builder's gap computation must agree on the
# exact set of obligations that have a live receipt producer. Publish-CiAcceptanceReceipt.Tests.ps1 ties both lists to the
# publisher contracts.
$ContextBuilderSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\New-CiAcceptanceAggregateContext.ps1') -Raw
$WorkflowLiveChecks = [regex]::Matches($ShadowSelection, '(?m)^\s*\$LiveProducerChecks = @\((?<list>[^)]*)\)\r?$')
$BuilderLiveChecks = [regex]::Matches($ContextBuilderSource, '(?m)^\s*\$LiveChecks=@\((?<list>[^)]*)\)\r?$')
Assert-True ($WorkflowLiveChecks.Count -eq 1 -and $BuilderLiveChecks.Count -eq 1) 'The workflow and context builder must each declare exactly one live producer check list.'
$WorkflowLiveList = @([regex]::Matches($WorkflowLiveChecks[0].Groups['list'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) -join ','
$BuilderLiveList = @([regex]::Matches($BuilderLiveChecks[0].Groups['list'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) -join ','
Assert-True ($WorkflowLiveList -ceq $BuilderLiveList) 'Workflow aggregate readiness and the context builder gap mode must use the same live producer checks.'
# The aggregate binds the native receipt when either native obligation is selected; any other selector output pair must still fail closed.
Assert-True ($AcceptanceShadow -match '(?m)^          AETHELN_OPERATIONAL_REQUIRED: \$\{\{ needs\.ci-selection-shadow\.outputs\.controller_operational_proof_required \}\}\r?$' -and $AcceptanceShadow -match "Add-ProducerBinding \`$NativeProducerRequired \`$env:AETHELN_NATIVE_RESULT 'native' 'native-receipt-shadow'" -and $AcceptanceShadow -match "\`$NativeProducerRequired = if \(\`$env:AETHELN_NATIVE_REQUIRED -ceq 'true' -or \`$env:AETHELN_OPERATIONAL_REQUIRED -ceq 'true'\) \{ 'true' \} elseif \(\`$env:AETHELN_NATIVE_REQUIRED -ceq 'false' -and \`$env:AETHELN_OPERATIONAL_REQUIRED -ceq 'false'\) \{ 'false' \} else \{ 'invalid' \}") 'The aggregate must bind the native receipt for either native obligation and reject any other selector output pair.'
Assert-True ($AcceptanceShadow -match '(?m)^          AETHELN_UNREAL_REQUIRED: \$\{\{ needs\.ci-selection-shadow\.outputs\.unreal_editor_automation_required \}\}\r?$' -and $AcceptanceShadow -match "Add-ProducerBinding \`$env:AETHELN_UNREAL_REQUIRED \`$env:AETHELN_UNREAL_RESULT 'unreal' 'unreal-receipt-shadow'" -and $AcceptanceShadow.IndexOf("'portable' 'portable-receipt-shadow'") -lt $AcceptanceShadow.IndexOf("'unreal' 'unreal-receipt-shadow'") -and $AcceptanceShadow.IndexOf("'unreal' 'unreal-receipt-shadow'") -lt $AcceptanceShadow.IndexOf("'visual' 'visual-receipt-shadow'")) 'The aggregate must bind the unreal receipt from its own selector output in key order.'

foreach ($Receipt in $ReceiptContracts) {
	$Body = [string] $Receipt.Body
	Assert-True ($Body -match "(?m)^    needs:\r?\n      - ci-selection-shadow\r?\n      - $([regex]::Escape($Receipt.Producer))\r?\n(?=    if: )" -and $Body -match "(?m)^    if: github\.event_name == 'pull_request' && $($Receipt.Predicate)\r?$") "$($Receipt.Name) must be PR-only and selected solely through the accepted selector output after its raw producer."
	Assert-True ($Body -match '(?m)^    runs-on: windows-latest\r?$' -and $Body -match '(?m)^    timeout-minutes: 10\r?$' -and $Body -notmatch 'self-hosted|aetheln-engine-runner|concurrency:') "$($Receipt.Name) must be a bounded hosted publisher without engine admission."
	foreach ($Output in @('artifact_id: \$\{\{ steps\.receipt_artifact\.outputs\.artifact-id \}\}', 'artifact_name: \$\{\{ steps\.receipt_identity\.outputs\.artifact_name \}\}', 'artifact_digest: sha256:\$\{\{ steps\.receipt_artifact\.outputs\.artifact-digest \}\}')) {
		Assert-True ($Body -match "(?m)^      $Output\r?$") "$($Receipt.Name) must expose the reviewed direct receipt upload binding."
	}
	Assert-MatchCount -Text $Body -Pattern "(?m)^        uses: $DownloadActionPattern\r?$" -Expected 2 -Message "$($Receipt.Name) must download exactly the selector and its raw evidence by ID."
	$ProducerArtifactId = [regex]::Escape('${{ needs.' + $Receipt.Producer + '.outputs.' + $Receipt.ArtifactOutput + ' }}')
	Assert-True ($Body -match 'artifact-ids: \$\{\{ needs\.ci-selection-shadow\.outputs\.selector_artifact_id \}\}' -and $Body -match ("artifact-ids: " + $ProducerArtifactId)) "$($Receipt.Name) must bind both downloads directly to needs upload IDs, never artifact-name discovery."
	Assert-True ($Body -match 'scripts/ci/New-CiAcceptanceAggregateContext\.ps1' -and $Body -match '-Mode Identity' -and $Body -match 'scripts/ci/Publish-CiAcceptanceReceipt\.ps1') "$($Receipt.Name) must use the reviewed identity builder and receipt publisher."
	Assert-True ($Body -match '(?m)^          \$ContextBuilder = \(Resolve-Path -LiteralPath ''scripts/ci/New-CiAcceptanceAggregateContext\.ps1''\)\.Path\r?$' -and $Body -match '(?m)^          & \$ContextBuilder `\r?$' -and $Body -notmatch 'powershell\.exe[^\r\n]*New-CiAcceptanceAggregateContext\.ps1') "$($Receipt.Name) must pass JSON to the context builder in-process so Windows PowerShell cannot strip native command-line quotes."
	Assert-True ($Body -match ("-ProducerKey " + [regex]::Escape($Receipt.Key) + ' `') -and $Body -notmatch '-CheckId ' -and $Body -match ("-JobName " + [regex]::Escape($Receipt.Name) + ' `')) "$($Receipt.Name) must bind its exact producer key and publisher job identity."
	$ReceiptPrefix = [regex]::Escape("'ci-receipt-$($Receipt.Key)-' + `$env:AETHELN_RUN_ID + '-' + `$env:AETHELN_RUN_ATTEMPT + '-")
	Assert-True ($Body -match $ReceiptPrefix -and $Body -match '\$\{\{ needs\.ci-selection-shadow\.outputs\.attempt_nonce \}\}') "$($Receipt.Name) output must be run/attempt/selector-nonce bound."
	$ArchiveDigestValidation = [regex]::Escape("`$env:AETHELN_RAW_ARTIFACT_DIGEST -cnotmatch '\Asha256:[0-9a-f]{64}\z'")
	Assert-True ($Body -match [regex]::Escape($Receipt.RawName) -and $Body -match $ArchiveDigestValidation) "$($Receipt.Name) must validate the expected raw artifact name and archive digest before publication."
	Assert-True ($Body -match '(?m)^        id: receipt_artifact\r?$' -and $Body -match 'name: \$\{\{ steps\.receipt_identity\.outputs\.artifact_name \}\}' -and $Body -match 'path: \$\{\{ runner\.temp \}\}/\$\{\{ steps\.receipt_identity\.outputs\.artifact_name \}\}') "$($Receipt.Name) must upload only its exact dynamically named receipt directory."
	Assert-True ($Body -notmatch '(?m)^\s+if: always\(\)\r?$' -and $Body -notmatch '(?m)^\s+continue-on-error:') "$($Receipt.Name) must fail red on any unexpected binding, receipt, or upload failure."
	# GitHub never refreshes the event base after the target branch moves, so a
	# receipt bound to it contradicts the selector for every PR behind its base.
	Assert-True ($Body -match '(?m)^          AETHELN_BASE_REVISION: \$\{\{ needs\.ci-selection-shadow\.outputs\.accepted_base_sha \}\}\r?$' -and $Body -notmatch 'github\.event\.pull_request\.base\.sha' -and $Body -match "\`$env:AETHELN_BASE_REVISION -cnotmatch '\\A\[0-9a-f\]\{40\}\\z'" -and $Body -match "throw 'accepted_base_invalid'") "$($Receipt.Name) must bind and validate the selector's verified first parent, never the stale event base."
}
# The aggregate binds the same verified first parent. Its guard runs only after
# the non-PR early exit, where the skipped selector leaves the output empty.
$AggregateBaseGuard = $AcceptanceShadow.IndexOf("if (`$env:AETHELN_BASE_REVISION -cnotmatch '\A[0-9a-f]{40}\z') { throw 'accepted_base_invalid' }", [StringComparison]::Ordinal)
Assert-True ($AcceptanceShadow -match '(?m)^          AETHELN_BASE_REVISION: \$\{\{ needs\.ci-selection-shadow\.outputs\.accepted_base_sha \}\}\r?$' -and $AcceptanceShadow -notmatch 'github\.event\.pull_request\.base\.sha' -and $AggregateBaseGuard -gt $AcceptanceShadow.IndexOf("Write-AcceptanceGap -Reason 'event_not_applicable'", [StringComparison]::Ordinal) -and $AggregateBaseGuard -lt $AcceptanceShadow.IndexOf('$ContextBuilder = ', [StringComparison]::Ordinal)) 'The aggregate must bind and validate the selector''s verified first parent after the non-PR exit and before building any context.'

# The aggregate directly waits for every raw and receipt job so it can explain
# skips without granting authority. It may produce a real shadow aggregate only
# when the selector says the supported subset is complete; unsupported selected
# obligations produce one explicit green gap, while every contradiction fails.
$AggregateNeeds = [regex]::Match($AcceptanceShadow, '(?ms)^    needs:\r?\n(?<needs>(?:      - [a-z0-9-]+\r?\n)+)')
Assert-True $AggregateNeeds.Success 'Acceptance aggregation must declare an exact direct-needs list.'
$ActualAggregateNeeds = @([regex]::Matches($AggregateNeeds.Groups['needs'].Value, '(?m)^      - (?<job>[a-z0-9-]+)\r?$') | ForEach-Object { [string] $_.Groups['job'].Value })
$ExpectedAggregateNeeds = @('ci-selection-shadow','quality-gates','change-impact','trusted-candidate-compile','trusted-editor-automation','scheduled-client-package','scheduled-server-package','scheduled-provenance-validation','scheduled-packaged-smoke','visual-proof','portable-receipt-shadow','native-receipt-shadow','unreal-receipt-shadow','visual-receipt-shadow')
Assert-True (($ActualAggregateNeeds -join ',') -ceq ($ExpectedAggregateNeeds -join ',')) 'Acceptance aggregation must directly need every reviewed producer and receipt publisher exactly once.'
foreach ($Output in @(
	'complete: ${{ steps.reconcile.outputs.complete }}',
	'attempt_nonce: ${{ steps.reconcile.outputs.attempt_nonce }}',
	'artifact_id: ${{ steps.acceptance_artifact.outputs.artifact-id }}',
	'artifact_name: ${{ steps.reconcile.outputs.artifact_name }}',
	'artifact_digest: sha256:${{ steps.acceptance_artifact.outputs.artifact-digest }}',
	'report_sha256: ${{ steps.reconcile.outputs.report_sha256 }}',
	'report_size_bytes: ${{ steps.reconcile.outputs.report_size_bytes }}'
)) {
	Assert-True ($AcceptanceShadow.Contains($Output)) "Acceptance aggregation must expose exact directly bound output '$Output'."
}
Assert-True ($AcceptanceShadow -match "(?m)^        uses: $DownloadActionPattern\r?$" -and $AcceptanceShadow -match 'artifact-ids: \$\{\{ needs\.ci-selection-shadow\.outputs\.selector_artifact_id \}\}') 'Acceptance aggregation must download the exact directly-bound selector artifact ID.'
foreach ($Script in @('scripts/ci/New-CiAcceptanceAggregateContext.ps1','scripts/ci/ci-acceptance-requirements.json','scripts/ci/Invoke-CiAcceptanceAggregate.ps1')) {
	Assert-True ($AcceptanceShadow -match [regex]::Escape($Script)) "Acceptance aggregation must invoke exact reviewed input '$Script'."
}
foreach ($Publisher in @('portable-receipt-shadow','native-receipt-shadow','unreal-receipt-shadow','visual-receipt-shadow')) {
	Assert-True ($AcceptanceShadow -match [regex]::Escape($Publisher)) "Acceptance aggregation must bind direct output and job identity for '$Publisher'."
}
Assert-True ($AcceptanceShadow -match 'if \(\$env:AETHELN_SELECTOR_READY -ceq ''false''\)' -and $AcceptanceShadow -match 'elseif \(\$env:AETHELN_SELECTOR_READY -ceq ''true''\)' -and $AcceptanceShadow -match "throw 'aggregate_ready_invalid'") 'Acceptance reconciliation must distinguish exact unsupported-gap, supported-aggregate, and invalid selector readiness states.'
Assert-True ($AcceptanceShadow -match '\$Gap = & \$ContextBuilder -Mode Gap @ContextArguments' -and $AcceptanceShadow -match '\$Gap\.attemptAnchor\.nonce -cne \$env:AETHELN_SELECTOR_NONCE' -and $AcceptanceShadow -match '\$SelectedUnsupported = @\(\$Gap\.selectedUnsupported\)') 'A missing accepted controller must pass strict current-attempt gap validation before a non-authoritative producer-gap report is published.'
Assert-True ($AcceptanceShadow -match "producer_contract_incomplete" -and $AcceptanceShadow -match "throw 'aggregate_ready_contradiction'" -and $AcceptanceShadow -match 'acceptance_producer_gap:') 'Only a selected unsupported obligation may become the explicit green producer gap.'
Assert-True ($AcceptanceShadow -match 'Invoke-CiAcceptanceAggregateMain' -and $AcceptanceShadow -match "throw 'aggregate_shadow_decision_invalid'") 'The supported subset must execute the real aggregate and reject any authority-bearing or incomplete decision.'
Assert-True ($AcceptanceShadow -match 'complete = \$false' -and $AcceptanceShadow -match 'shadow = \$true' -and $AcceptanceShadow -match 'authoritative = \$false' -and $AcceptanceShadow -match 'grantsAcceptance = \$false') 'The unsupported path must remain an explicit non-authoritative no-acceptance result.'
Assert-True ($AcceptanceShadow -notmatch 'acceptanceGranted|grantsAcceptance = \$true|authoritative = \$true' -and $AcceptanceShadow -notmatch '(?m)^\s+continue-on-error:') 'Package 3C must neither advertise nor grant authority and unexpected failures must remain red.'
Assert-True ($AcceptanceShadow -match '(?m)^        id: acceptance_artifact\r?$' -and $AcceptanceShadow -notmatch '(?ms)^      - name: Upload shadow acceptance diagnostic\r?\n        id: acceptance_artifact\r?\n        if: always\(\)') 'The shadow aggregate must upload only a successfully reconciled report, never mask a failed reconciliation with always().'
Assert-True ($AcceptanceAuthority -match "(?m)^    needs: ci-acceptance-shadow\r?\n    if: always\(\) && github\.event_name == 'pull_request' && false\r?$" -and $AcceptanceAuthority -match '(?m)^    runs-on: windows-latest\r?$' -and $AcceptanceAuthority -match '(?m)^    timeout-minutes: 5\r?$') 'The future authority boundary must remain literally unreachable, evaluate dependency failures when activated, and stay bounded on a hosted runner.'
Assert-True ($AcceptanceAuthority -match '(?ms)^    permissions:\r?\n      actions: read\r?\n      contents: read\r?$' -and $AcceptanceAuthority -notmatch '(?m)^      [a-z-]+: write\r?$') 'The dormant authority boundary must remain read-only even while unreachable.'
Assert-True ($AcceptanceAuthority -match 'AETHELN_AGGREGATE_RESULT: \$\{\{ needs\.ci-acceptance-shadow\.result \}\}' -and $AcceptanceAuthority -match "throw 'acceptance_authority_dependency_invalid'" -and $AcceptanceAuthority -match 'artifact-ids: \$\{\{ needs\.ci-acceptance-shadow\.outputs\.artifact_id \}\}' -and $AcceptanceAuthority -match 'AETHELN_AGGREGATE_COMPLETE: \$\{\{ needs\.ci-acceptance-shadow\.outputs\.complete \}\}' -and $AcceptanceAuthority -match 'AETHELN_AGGREGATE_REPORT_SHA256: \$\{\{ needs\.ci-acceptance-shadow\.outputs\.report_sha256 \}\}' -and $AcceptanceAuthority -match 'AETHELN_AGGREGATE_REPORT_SIZE_BYTES: \$\{\{ needs\.ci-acceptance-shadow\.outputs\.report_size_bytes \}\}' -and $AcceptanceAuthority -match "throw 'acceptance_authority_evidence_mismatch'") 'The dormant boundary must fail on a failed or cancelled aggregate and may consume only directly bound complete evidence whose exact report bytes match upstream SHA-256 and length outputs.'
$AuthorityGuardMatch = [regex]::Match($AcceptanceAuthority, '(?ms)^      - name: Require successful reconciled aggregate dependency\r?\n.*?^        run: \|\r?\n(?<script>(?:^          [^\r\n]*\r?\n?)+)')
Assert-True $AuthorityGuardMatch.Success 'The dormant authority boundary must contain an executable aggregate-result guard before any download.'
$AuthorityGuardScript = (($AuthorityGuardMatch.Groups['script'].Value -split "`r?`n" | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(10) }) -join "`n")
$OriginalAggregateResult = $env:AETHELN_AGGREGATE_RESULT
try {
	foreach ($DependencyResult in @('failure', 'cancelled', 'skipped')) {
		$env:AETHELN_AGGREGATE_RESULT = $DependencyResult
		$DependencyRejected = $false
		try { & ([scriptblock]::Create($AuthorityGuardScript)) }
		catch { $DependencyRejected = $_.Exception.Message -match 'acceptance_authority_dependency_invalid' }
		Assert-True $DependencyRejected "An activated authority boundary must run and fail for aggregate result '$DependencyResult'."
	}
	$env:AETHELN_AGGREGATE_RESULT = 'success'
	& ([scriptblock]::Create($AuthorityGuardScript))
}
finally {
	$env:AETHELN_AGGREGATE_RESULT = $OriginalAggregateResult
}
Assert-True ($Workflow.Substring(0, $AuthorityStart) -notmatch 'ci-acceptance-authority' -and $Workflow.IndexOf('  ci-acceptance-authority:', $AuthorityStart + 1, [StringComparison]::Ordinal) -lt 0) 'No live job may depend on or otherwise reference the hard-disabled authority boundary.'

# Portable job: GitHub-hosted, explicitly bounded, StarterMap-only LFS.
Assert-True ($QualityGates -match '(?m)^\s+runs-on: windows-latest\r?$') 'The portable job must stay on the GitHub-hosted Windows runner.'
Assert-True ($QualityGates -match '(?m)^\s+timeout-minutes: 30\r?$') 'The portable job must declare an explicit conservative bound.'
Assert-True ($QualityGates -notmatch '(?m)^\s+needs:') 'The portable job must not depend on any engine or classifier job.'
Assert-True ($QualityGates -match 'git lfs pull --include "Content/Maps/StarterMap\.umap"') 'The portable job must materialize the StarterMap LFS fixture.'

# Change-impact classifier: GitHub-hosted, pull requests only, checkout plus
# repository-owned PowerShell, exact SHAs passed through env (no expression
# injection into the script body), stable engine_required output.
Assert-True ($ChangeImpact -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'The classifier must run only for pull requests.'
Assert-True ($ChangeImpact -match '(?m)^\s+runs-on: windows-latest\r?$') 'The classifier must run on the GitHub-hosted Windows runner, never the engine runner.'
Assert-True ($ChangeImpact -match '(?m)^\s+timeout-minutes: 10\r?$') 'The classifier must declare an explicit short bound.'
Assert-True ($ChangeImpact -notmatch 'self-hosted' -and $ChangeImpact -notmatch 'aetheln-engine') 'The classifier must never touch the engine runner or its concurrency group.'
Assert-MatchCount -Text $ChangeImpact -Pattern '(?m)^\s+-?\s*uses: ' -Expected 1 -Message 'The classifier must use exactly one action.'
Assert-True ($ChangeImpact -match "(?m)^\s+- uses: $CheckoutActionPattern\r?$") 'The classifier''s only action must be the reviewed checkout SHA.'
Assert-True ($ChangeImpact -match '(?m)^\s+engine_required: \$\{\{ steps\.classify\.outputs\.engine_required \}\}\r?$') 'The classifier must publish engine_required as a job output.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}\r?$') 'The classifier must receive the exact pull-request base SHA through env.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}\r?$') 'The classifier must receive the exact pull-request head SHA through env.'
Assert-True ($ChangeImpact -notmatch 'upload-artifact' -and $ChangeImpact -notmatch '-Mode ') 'The classifier must not upload artifacts or invoke the engine gate.'
$NormalizedWorkflow = $Workflow.Replace("`r`n", "`n")
$LegacyStart = $NormalizedWorkflow.IndexOf('  change-impact:', [StringComparison]::Ordinal)
$LegacyEnd = $NormalizedWorkflow.IndexOf('  trusted-candidate-compile:', $LegacyStart, [StringComparison]::Ordinal)
Assert-True ($LegacyStart -ge 0 -and $LegacyEnd -gt $LegacyStart) 'The authoritative legacy classifier block must remain addressable by exact job markers.'
$LegacyBytes = [Text.Encoding]::UTF8.GetBytes($NormalizedWorkflow.Substring($LegacyStart, $LegacyEnd - $LegacyStart))
$LegacyHasher = [Security.Cryptography.SHA256]::Create()
try { $LegacyDigest = ([BitConverter]::ToString($LegacyHasher.ComputeHash($LegacyBytes)) -replace '-', '').ToLowerInvariant() }
finally { $LegacyHasher.Dispose() }
# TA-018 (2026-10-02) removed the six controller paths from the portable-only set; this is the reviewed block identity after that change.
Assert-True ($LegacyBytes.Length -eq 5395 -and $LegacyDigest -ceq 'e4a7bc5968f066178d1b78cb26d15df06f60af50696cda51b8e758ca8a38c805') 'The change-impact block must match the reviewed TA-018 identity after LF normalization.'

function Get-ClassifierScript {
	$Lines = $Workflow -split "\r?\n"
	$IdIndex = -1
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match '^\s+id: classify$') { $IdIndex = $Index; break }
	}
	Assert-True ($IdIndex -ge 0) 'The classifier step must carry id: classify.'
	$RunIndex = -1
	$RunIndent = 0
	for ($Index = $IdIndex; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match '^(\s+)run: \|$') { $RunIndex = $Index; $RunIndent = $Matches[1].Length; break }
	}
	Assert-True ($RunIndex -ge 0) 'The classifier step must contain a literal run block.'
	$Body = @()
	for ($Index = $RunIndex + 1; $Index -lt $Lines.Count; $Index++) {
		$Line = $Lines[$Index]
		if ($Line -eq '') { $Body += ''; continue }
		if ($Line -match '^(\s+)\S' -and $Matches[1].Length -gt $RunIndent) { $Body += $Line; continue }
		break
	}
	$BodyIndent = ($Body | Where-Object { $_ -ne '' } | ForEach-Object { $null = $_ -match '^(\s+)'; $Matches[1].Length } | Measure-Object -Minimum).Minimum
	return (($Body | ForEach-Object { if ($_ -eq '') { '' } else { $_.Substring($BodyIndent) } }) -join "`n")
}

$ClassifierScript = Get-ClassifierScript
Assert-True ($ClassifierScript -notmatch '\$\{\{') 'The classifier script body must not interpolate workflow expressions.'
Assert-True ($ClassifierScript -match '--no-renames') 'The classifier must diff without rename or copy detection so every entry is A/M/D/T.'
$ParseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($ClassifierScript, [ref] $null, [ref] $ParseErrors)
Assert-True ($ParseErrors.Count -eq 0) "The classifier script must parse under Windows PowerShell 5.1: $($ParseErrors | ForEach-Object { $_.Message } | Select-Object -First 1)"

# Trusted compile: pull requests only, owner/same-repo trust, and it may start
# only after the portable gates passed and the classifier demanded the engine.
Assert-True ($TrustedCompile -match '(?m)^\s+needs:\r?\n\s+- quality-gates\r?\n\s+- change-impact\r?$') 'Trusted compile must depend on both the portable gates and the classifier.'
Assert-True ($TrustedCompile -match "needs\.change-impact\.outputs\.engine_required == 'true'") 'Trusted compile must run only when the classifier requires the engine.'
Assert-True ($TrustedCompile -match "github\.event_name == 'pull_request'") 'Trusted compile must remain limited to pull requests.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository') 'Trusted compile must require the head repository to match this repository.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.user\.login == github\.repository_owner') 'Trusted compile must require the pull request author to be the repository owner.'
Assert-True ($TrustedCompile -match 'github\.triggering_actor == github\.repository_owner') 'Trusted compile must require the triggering actor to be the repository owner.'
Assert-MatchCount -Text $TrustedCompile -Pattern '(?m)^        if: always\(\)\r?$' -Expected 2 -Message 'Trusted compile may use always() only for raw-report binding and upload steps, never at job scope.'
Assert-True ($TrustedCompile -notmatch '(?m)^    if: always\(\)\r?$') 'Trusted compile must never bypass failed, cancelled, or skipped prerequisites at job scope.'
Assert-MatchCount -Text $TrustedCompile -Pattern '(?m)^\s+-Mode Compile `\r?$' -Expected 1 -Message 'Trusted owner pull-request validation must select Compile exactly once.'
Assert-True ($TrustedCompile -notmatch '(?m)^\s+-Mode PackagedSmoke `\r?$') 'Trusted owner pull-request validation must not select PackagedSmoke.'
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Routine trusted compile must not be configured as a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '(?i)clean[^\r\n]*packag|packag[^\r\n]*clean') 'Routine trusted compile must not be described as a clean package gate.'

# The monolithic manual milestone is retired: no job, no PackagedSmoke mode, no
# 24-hour bound anywhere in the workflow.
Assert-True ($Workflow -notmatch 'manual-packaged-smoke') 'Workflow must not define the retired manual-packaged-smoke job.'
Assert-True ($Workflow -notmatch 'engine-runner-manual-smoke-report') 'Workflow must not publish the retired manual smoke artifact.'
Assert-True ($Workflow -notmatch '-Mode PackagedSmoke') 'Workflow must not select the monolithic PackagedSmoke gate anywhere.'
Assert-True ($Workflow -notmatch 'timeout-minutes:\s*1440') 'Workflow must not contain a 24-hour job bound.'

Assert-True ($ScheduledSmoke -match $PhaseTrigger) 'scheduled-packaged-smoke must accept only the schedule event.'
Assert-True ($ScheduledSmoke -notmatch 'pull_request' -and $ScheduledSmoke -notmatch "'push'") 'scheduled-packaged-smoke must not be selectable by pull requests or pushes.'
Assert-MatchCount -Text $ScheduledSmoke -Pattern '(?m)^\s+-Mode SmokePhase `\r?$' -Expected 1 -Message 'scheduled-packaged-smoke must select the SmokePhase gate exactly once.'
Assert-True ($ScheduledSmoke -notmatch '(?m)^\s+-Mode (Compile|PackagedSmoke) `\r?$') 'scheduled-packaged-smoke must not select Compile or the single-job PackagedSmoke gate.'
Assert-True ($ScheduledSmoke -match 'timeout-minutes:\s*20') 'scheduled-packaged-smoke must be bounded by its recorded phase limit.'

foreach ($Job in @(
	@{ Name = 'trusted-candidate-compile'; Body = $TrustedCompile; RequiresContentLfs = $false },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke; RequiresContentLfs = $false }
)) {
	if ($Job.Name -eq 'trusted-candidate-compile') {
		Assert-True ($Job.Body -match '-ManagedWorkspaceRoot' -and $Job.Body -match '-HostLeasePath') 'Compile must validate selected materialized inputs inside the owned managed workspace operation.'
		Assert-True ($Job.Body -notmatch 'git lfs pull') 'Compile must not hydrate retained inputs outside supervised ownership.'
		Assert-True ($Job.Body.IndexOf('name: Capture routine compile deadline') -ge 0 -and $Job.Body.IndexOf('name: Capture routine compile deadline') -lt $Job.Body.IndexOf("uses: $CheckoutAction")) 'Compile must start its controlled budget before checkout.'
		Assert-True ($Job.Body.Contains('-CompileStartedUtc $env:AETHELN_COMPILE_STARTED_UTC') -and $Job.Body.Contains('-CompileStartedTimestamp $env:AETHELN_COMPILE_STARTED_TIMESTAMP')) 'Compile must pass the original UTC and monotonic anchors into the gate.'
	}
	if ($Job.RequiresContentLfs) {
		Assert-True ($Job.Body -match 'git lfs pull --include "Content/\*\*"') "$($Job.Name) must materialize every Unreal Content LFS object before build or cook."
	}
	Assert-True ($Job.Body -notmatch 'git lfs pull --include "Content/Maps/StarterMap\.umap"') "$($Job.Name) must not fetch only StarterMap."
	Assert-True ($Job.Body -match '(?m)^\s+group: aetheln-engine-runner\r?$') "$($Job.Name) must use the shared engine-runner concurrency group."
	Assert-True ($Job.Body -match '(?m)^\s+cancel-in-progress: false\r?$') "$($Job.Name) must serialize without cancelling an active engine job."
	Assert-True ($Job.Body -match '(?m)^\s+path: .*engine-runner-report\.json\r?$') "$($Job.Name) must upload only its machine-readable engine report."
}

$ReportUploads = @([regex]::Matches($Workflow, '(?m)^          path: (.+(?:ci-report|engine-runner-report)\.json)\r?$'))
Assert-True ($ReportUploads.Count -eq 6) 'Exactly six report uploads remain.'
Assert-True ($TrustedCompile.Contains('path: ${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/engine-runner-report.json')) 'Compile artifact is unique to this run, attempt and job.'
Assert-True ($TrustedCompile -match 'timeout-minutes: 40' -and $TrustedCompile -match '-CompileTimeoutMinutes 30') 'Routine compile has a whole-job and controlled-work limit.'
Assert-True ($Workflow -notmatch '(?m)^          path: .*\*') 'Uploads cannot contain wildcard payload paths.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s*uses: actions/upload-artifact@' -Expected 14 -Message 'Only seven raw reports, the selector, four nonce-bound receipts, the acceptance shadow diagnostic, and the hard-disabled authority receipt may be uploaded.'
Assert-True ($Workflow -notmatch '(?m)^\s+path:\s*.*(?:archives?|logs?|Saved|StagedBuilds)') 'Generated payload directories must never be uploaded.'

# Classifier behavior matrix: run the extracted script against fixture commits.
# Every uncertainty (bad SHA, unreachable commit, empty or unparsable diff)
# must fail closed to engine_required=true while the step still exits 0.
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-change-impact-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$ScriptPath = Join-Path $FixtureRoot 'classify.ps1'
[IO.File]::WriteAllText($ScriptPath, $ClassifierScript + "`n", (New-Object System.Text.UTF8Encoding $false))
$RepoRoot = Join-Path $FixtureRoot 'repo'

function Invoke-FixtureGit([string[]] $Arguments) {
	$Previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& git -C $RepoRoot @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $Previous
	}
	Assert-True ($ExitCode -eq 0) "fixture git $($Arguments -join ' ') failed: $($Output -join ' ')"
	return ,$Output
}

function Write-FixtureFile([string] $RelativePath, [string] $Content) {
	$FullPath = Join-Path $RepoRoot ($RelativePath -replace '/', '\')
	$Directory = Split-Path -Parent $FullPath
	if (-not (Test-Path -LiteralPath $Directory)) { $null = New-Item -ItemType Directory -Path $Directory -Force }
	[IO.File]::WriteAllText($FullPath, $Content + "`n")
}

function Add-FixtureCommit([string[]] $Write, [string[]] $Delete, [string] $Message, [string[]] $IndexOnly = @()) {
	$Stamp = [guid]::NewGuid().ToString('N')
	foreach ($Path in @($Write)) { if ($Path) { Write-FixtureFile $Path "$Message $Stamp" } }
	foreach ($Path in @($Delete)) { if ($Path) { Remove-Item -LiteralPath (Join-Path $RepoRoot ($Path -replace '/', '\')) -Force } }
	$null = Invoke-FixtureGit @('add', '-A', '--', '.')
	foreach ($Path in @($IndexOnly)) {
		# Case-variant paths cannot be materialized beside their lowercase twin
		# on a case-insensitive filesystem, so they enter the index directly.
		if (-not $Path) { continue }
		$BlobPath = Join-Path $FixtureRoot ('blob-' + $Stamp + '.txt')
		[IO.File]::WriteAllText($BlobPath, "$Message $Stamp $Path`n")
		$Blob = [string] @(Invoke-FixtureGit @('hash-object', '-w', '--', $BlobPath))[0]
		$null = Invoke-FixtureGit @('update-index', '--add', '--cacheinfo', "100644,$Blob,$Path")
	}
	$null = Invoke-FixtureGit @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', $Message)
	return [string] @(Invoke-FixtureGit @('rev-parse', 'HEAD'))[0]
}

function Invoke-Classifier([string] $BaseSha, [string] $HeadSha, [switch] $OmitBase, [string] $WorkingDirectory = $RepoRoot) {
	$OutputFile = Join-Path $FixtureRoot ('output-' + [guid]::NewGuid().ToString('N') + '.txt')
	$SummaryFile = Join-Path $FixtureRoot ('summary-' + [guid]::NewGuid().ToString('N') + '.md')
	[IO.File]::WriteAllText($OutputFile, '')
	[IO.File]::WriteAllText($SummaryFile, '')
	$env:GITHUB_OUTPUT = $OutputFile
	$env:GITHUB_STEP_SUMMARY = $SummaryFile
	if ($OmitBase) { Remove-Item Env:AETHELN_PR_BASE_SHA -ErrorAction SilentlyContinue } else { $env:AETHELN_PR_BASE_SHA = $BaseSha }
	$env:AETHELN_PR_HEAD_SHA = $HeadSha
	Push-Location -LiteralPath $WorkingDirectory
	try {
		$StdOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		Pop-Location
		foreach ($Name in @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'AETHELN_PR_BASE_SHA', 'AETHELN_PR_HEAD_SHA')) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
	}
	$Outputs = @{}
	foreach ($Line in @(Get-Content -LiteralPath $OutputFile)) {
		if ($Line -match '^([a-z_]+)=(.*)$') { $Outputs[$Matches[1]] = $Matches[2] }
	}
	return @{ ExitCode = $ExitCode; Outputs = $Outputs; Summary = [string] (Get-Content -LiteralPath $SummaryFile -Raw); StdOut = $StdOut }
}

function Assert-Classification([string] $Case, [hashtable] $Result, [string] $EngineRequired, [string] $Reason) {
	Assert-True ($Result.ExitCode -eq 0) "[$Case] classifier step must exit 0 so the compile decision is always published (stdout: $($Result.StdOut -join ' '))."
	Assert-True ($Result.Outputs.ContainsKey('engine_required') -and $Result.Outputs['engine_required'] -ceq $EngineRequired) "[$Case] expected engine_required=$EngineRequired, got '$($Result.Outputs['engine_required'])' (reason '$($Result.Outputs['reason'])')."
	Assert-True ($Result.Outputs.ContainsKey('reason') -and $Result.Outputs['reason'] -ceq $Reason) "[$Case] expected reason=$Reason, got '$($Result.Outputs['reason'])'."
	Assert-True ($Result.Summary -match ('engine_required=' + $EngineRequired) -and $Result.Summary -match [regex]::Escape($Reason)) "[$Case] step summary must state the decision and reason."
	Assert-True (([regex]::Matches($Result.Summary, "`n")).Count -le 2) "[$Case] step summary must stay concise."
}

try {
	$null = New-Item -ItemType Directory -Path $RepoRoot
	$null = Invoke-FixtureGit @('init', '-q')
	$null = Invoke-FixtureGit @('config', 'core.autocrlf', 'false')
	$null = Invoke-FixtureGit @('config', 'core.quotePath', 'true')
	# The exact CI paths are added per case, not seeded: their index-only case
	# variants must not collide with a tracked twin on Windows.
	$Seed = @(
		'AethelnOnline.uproject', 'Source/AethelnOnline/A.cpp', 'Source/AethelnOnline/README.md', 'Config/DefaultEngine.ini',
		'Content/Maps/Seed.txt', 'Plugins/Seed/Seed.uplugin', 'scripts/ci/Seed.ps1',
		'.github/ISSUE_TEMPLATE/bug-report.md', 'docs/a.md', 'docs/sub/b.md', 'visuals/a.svg', 'output/pdf/a.pdf',
		'tests/ci/Seed.Tests.ps1', 'tests/ci/fixture.json', 'README.md', 'AGENTS.md'
	)
	$BaseSha = Add-FixtureCommit -Write $Seed -Delete @() -Message 'base'

	$Matrix = @(
		@{ Case = 'exact packaging orchestration'; Write = @('scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		# TA-018: controller scripts and the live workflow compile again so the native producer can publish controller-operational-proof.
		@{ Case = 'exact engine wrapper'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact retention helper'; Write = @('scripts/ci/Initialize-CompileWorkspace.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact smoke evidence runner'; Write = @('scripts/build/Invoke-PackagedSmokeTest.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'smoke runner lookalike'; Write = @('scripts/build/Invoke-PackagedSmokeTestHelper.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different smoke runner'; Write = @(); IndexOnly = @('scripts/build/invoke-PackagedSmokeTest.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'smoke runner mixed with C++'; Write = @('scripts/build/Invoke-PackagedSmokeTest.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'orchestration mixed with C++'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'retention helper lookalike'; Write = @('scripts/ci/Initialize-CompileWorkspace.psm1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different wrapper'; Write = @(); IndexOnly = @('scripts/ci/invoke-EngineRunnerGate.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different packaging'; Write = @(); IndexOnly = @('Scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different retention'; Write = @(); IndexOnly = @('scripts/ci/initialize-CompileWorkspace.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact portable CI suite'; Write = @('scripts/ci/Invoke-CiSuite.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact portable formatting policy'; Write = @('scripts/ci/Test-FormattingPolicy.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact portable markdown links'; Write = @('scripts/ci/Test-MarkdownLinks.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'exact tested prototype workflow'; Write = @('.github/workflows/prototype-quality-gates.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'controller CI workflow plus fixtures'; Write = @('scripts/ci/Invoke-CiSuite.ps1', '.github/workflows/prototype-quality-gates.yml', 'tests/ci/Seed.Tests.ps1', 'docs/a.md'); Expect = 'true'; Reason = 'engine_paths_changed' },
		# Portable-only set: no Unreal compile.
		@{ Case = 'docs markdown'; Write = @('docs/a.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'docs nested any extension'; Write = @('docs/sub/new.png', 'docs/sub/b.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'visuals'; Write = @('visuals/a.svg', 'visuals/new/b.png'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'output pdf'; Write = @('output/pdf/a.pdf'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'tests ps1 and md only'; Write = @('tests/ci/Seed.Tests.ps1', 'tests/build/New.Tests.ps1', 'tests/README.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'top-level markdown'; Write = @('README.md', 'AGENTS.md', 'CHANGELOG.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'issue templates markdown and yaml'; Write = @('.github/ISSUE_TEMPLATE/bug-report.md', '.github/ISSUE_TEMPLATE/config.yml', '.github/ISSUE_TEMPLATE/feature.yaml'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'pull request template'; Write = @('.github/PULL_REQUEST_TEMPLATE.md', '.github/PULL_REQUEST_TEMPLATE/default.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable deletion'; Write = @(); Delete = @('docs/sub/b.md', 'visuals/a.svg'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable rename appears as delete plus add'; Write = @('docs/renamed.md'); Delete = @('docs/a.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable combination'; Write = @('docs/a.md', 'README.md', 'tests/ci/Seed.Tests.ps1', 'visuals/a.svg', '.github/ISSUE_TEMPLATE/bug-report.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		# Engine-impact set: compile required.
		@{ Case = 'Source'; Write = @('Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Config'; Write = @('Config/DefaultEngine.ini'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Content'; Write = @('Content/Maps/Seed.txt'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Plugins'; Write = @('Plugins/Seed/Seed.uplugin'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'scripts'; Write = @('scripts/ci/Seed.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'CI suite lookalike'; Write = @('scripts/ci/Invoke-CiSuite.ps1.bak'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'formatting policy lookalike'; Write = @('scripts/ci/Test-FormattingPolicyExtra.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'markdown links lookalike'; Write = @('scripts/ci/sub/Test-MarkdownLinks.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'workflow lookalike'; Write = @('.github/workflows/prototype-quality-gates.yaml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different CI suite'; Write = @(); IndexOnly = @('scripts/ci/invoke-CiSuite.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different formatting directory'; Write = @(); IndexOnly = @('Scripts/ci/Test-FormattingPolicy.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different markdown checker extension'; Write = @(); IndexOnly = @('scripts/ci/Test-MarkdownLinks.PS1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different workflow'; Write = @(); IndexOnly = @('.github/workflows/Prototype-quality-gates.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'engine gate script'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'real Unreal automation script'; Write = @('scripts/ci/Invoke-UnrealAutomationTests.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'packaging script'; Write = @('scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'mixed portable CI and Source'; Write = @('scripts/ci/Invoke-CiSuite.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed tested workflow and engine gate'; Write = @('.github/workflows/prototype-quality-gates.yml', 'scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'new workflow file'; Write = @('.github/workflows/new.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'other .github yaml'; Write = @('.github/dependabot.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'template directory non-markdown'; Write = @('.github/ISSUE_TEMPLATE/script.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'uproject'; Write = @('AethelnOnline.uproject'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'tests non-ps1 non-md'; Write = @('tests/ci/fixture.json'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'tests ps1 plus fixture'; Write = @('tests/ci/Seed.Tests.ps1', 'tests/ci/fixture.json'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different docs directory'; Write = @(); IndexOnly = @('Docs/x.md'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different markdown extension'; Write = @(); IndexOnly = @('docs/x.MD', 'CHANGELOG.MD'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different tests directory'; Write = @(); IndexOnly = @('Tests/ci/x.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'nested markdown outside portable roots'; Write = @('Source/AethelnOnline/README.md'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'top-level non-markdown'; Write = @('Setup.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'engine deletion'; Write = @(); Delete = @('Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed docs and Source'; Write = @('docs/a.md', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed portable set plus scripts'; Write = @('README.md', 'visuals/a.svg', 'scripts/ci/Seed.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' }
	)
	foreach ($Entry in $Matrix) {
		$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
		$Delete = if ($Entry.ContainsKey('Delete')) { $Entry.Delete } else { @() }
		$IndexOnly = if ($Entry.ContainsKey('IndexOnly')) { $Entry.IndexOnly } else { @() }
		$HeadSha = Add-FixtureCommit -Write $Entry.Write -Delete $Delete -Message $Entry.Case -IndexOnly $IndexOnly
		Assert-Classification -Case $Entry.Case -Result (Invoke-Classifier $BaseSha $HeadSha) -EngineRequired $Entry.Expect -Reason $Entry.Reason
	}

	# Fail-closed uncertainty cases.
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$DocsHead = Add-FixtureCommit -Write @('docs/a.md') -Delete @() -Message 'docs for uncertainty cases'
	Assert-Classification -Case 'short base sha' -Result (Invoke-Classifier $BaseSha.Substring(0, 12) $DocsHead) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'uppercase head sha' -Result (Invoke-Classifier $BaseSha $DocsHead.ToUpperInvariant()) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'missing base sha' -Result (Invoke-Classifier '' $DocsHead -OmitBase) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'identical shas' -Result (Invoke-Classifier $DocsHead $DocsHead) -EngineRequired 'true' -Reason 'identical_shas'
	Assert-Classification -Case 'unreachable base sha' -Result (Invoke-Classifier ('0' * 40) $DocsHead) -EngineRequired 'true' -Reason 'commit_unavailable'
	Assert-Classification -Case 'unreachable head sha' -Result (Invoke-Classifier $BaseSha ('f' * 40)) -EngineRequired 'true' -Reason 'commit_unavailable'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$EmptyHead = Add-FixtureCommit -Write @() -Delete @() -Message 'empty'
	Assert-Classification -Case 'empty diff' -Result (Invoke-Classifier $BaseSha $EmptyHead) -EngineRequired 'true' -Reason 'empty_diff'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$QuotedHead = Add-FixtureCommit -Write @([string]::Concat('docs/', [char] 0x00FC, 'ber.md')) -Delete @() -Message 'quoted path'
	Assert-Classification -Case 'quoted non-ascii path' -Result (Invoke-Classifier $BaseSha $QuotedHead) -EngineRequired 'true' -Reason 'unexpected_diff_entry'

	# Production path: actions/checkout on pull_request materializes only the
	# depth-1 merge commit, so both SHAs are absent locally and must be fetched
	# by SHA from origin before the diff. Exercise fetch-then-classify from a
	# shallow clone whose origin allows SHA fetches, as GitHub does.
	$null = Invoke-FixtureGit @('branch', '-f', 'fixture-other', $EmptyHead)
	$BareRoot = Join-Path $FixtureRoot 'origin.git'
	$ShallowRoot = Join-Path $FixtureRoot 'shallow'
	$null = Invoke-FixtureGit @('clone', '-q', '--bare', $RepoRoot, $BareRoot)
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
	# A plain local path ignores --depth; the file:// transport honors it and
	# routes later SHA fetches through upload-pack like a remote origin.
	$BareUrl = 'file:///' + ($BareRoot -replace '\\', '/')
	$null = Invoke-FixtureGit @('clone', '-q', '--depth', '1', '--no-tags', '--branch', 'fixture-other', $BareUrl, $ShallowRoot)
	foreach ($Revision in @($BaseSha, $DocsHead)) {
		$Missing = Invoke-FixtureGit @('-C', $ShallowRoot, 'rev-list', '--all')
		Assert-True ($Missing -notcontains $Revision) "shallow fixture must not already contain $Revision."
	}
	Assert-Classification -Case 'shallow clone fetches both shas then classifies portable' -Result (Invoke-Classifier $BaseSha $DocsHead -WorkingDirectory $ShallowRoot) -EngineRequired 'false' -Reason 'portable_paths_only'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$SourceHead = Add-FixtureCommit -Write @('Source/AethelnOnline/A.cpp') -Delete @() -Message 'source for shallow case'
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'fetch', '-q', $RepoRoot, "${SourceHead}:refs/heads/fixture-source")
	Assert-Classification -Case 'shallow clone fetches both shas then classifies engine' -Result (Invoke-Classifier $BaseSha $SourceHead -WorkingDirectory $ShallowRoot) -EngineRequired 'true' -Reason 'engine_paths_changed'

	# Reproduce DDC identity drift across consecutive shallow checkouts, then
	# prove that complete ancestry restores the same root set at both revisions.
	$NextSourceHead = Add-FixtureCommit -Write @('Source/AethelnOnline/A.cpp') -Delete @() -Message 'next source for DDC ancestry'
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'fetch', '-q', $RepoRoot, "${NextSourceHead}:refs/heads/fixture-next-source")
	$DdcShallowRoot = Join-Path $FixtureRoot 'ddc-shallow'
	$null = Invoke-FixtureGit @('clone', '-q', '--depth', '1', '--no-tags', '--branch', 'fixture-source', $BareUrl, $DdcShallowRoot)
	$FirstShallowRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', 'HEAD'))
	Assert-True ($FirstShallowRoots.Count -eq 1 -and $FirstShallowRoots[0] -ceq $SourceHead) 'The first shallow checkout incorrectly identifies its tip as the repository root.'
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'fetch', '-q', '--depth', '1', 'origin', $NextSourceHead)
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'checkout', '-q', '--detach', $NextSourceHead)
	$NextShallowRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', 'HEAD'))
	Assert-True ($NextShallowRoots.Count -eq 1 -and $NextShallowRoots[0] -ceq $NextSourceHead -and $NextShallowRoots[0] -cne $FirstShallowRoots[0]) 'The next depth-1 checkout changes the apparent repository root and invalidates DDC identity.'
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'fetch', '-q', '--unshallow', 'origin')
	Assert-True (([string] @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-parse', '--is-shallow-repository'))[0]) -ceq 'false') 'Complete ancestry must remove the shallow boundary.'
	foreach ($Revision in @($SourceHead, $NextSourceHead)) {
		$FullRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', $Revision))
		Assert-True ($FullRoots.Count -eq 1 -and $FullRoots[0] -ceq $BaseSha) 'Complete ancestry must preserve the actual DDC repository root across consecutive revisions.'
	}
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: workflow exposes no manual entry point, gates trusted compile behind portable success and the change-impact classifier, and retires the monolithic packaged-smoke job'
Write-Output 'PASS: classifier skips compile only for the closed portable set and fails closed on every uncertainty'
Write-Output 'PASS: milestone checkouts fetch complete ancestry; fixture proves shallow DDC root drift and full-ancestry stability across consecutive revisions'
Write-Output 'PASS: workflow preserves LFS, serialization, report-only upload, and no-secret policy'
Write-Output 'PASS: Package 3C selector, direct artifact bindings, receipt publishers, shadow aggregate, and hard-disabled authority boundary remain hosted, bounded, pinned, and non-authoritative'
exit 0
