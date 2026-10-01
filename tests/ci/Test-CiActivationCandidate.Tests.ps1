$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $ProjectRoot 'scripts\ci\Test-CiActivationCandidate.ps1')

$script:Assertions = 0
$Utf8 = New-Object Text.UTF8Encoding($false)
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-activation-' + [guid]::NewGuid().ToString('N'))
$FixtureRepository = Join-Path $FixtureRoot 'repository'
$PolicyRepositoryPath = 'scripts/ci/activation/ci-activation-policy.json'

function Assert-True {
	param([bool] $Condition, [string] $Message)
	$script:Assertions++
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
	param([scriptblock] $Operation, [string] $Reason)
	$script:Assertions++
	$Failure = $null
	try { & $Operation } catch { $Failure = $_.Exception.Message }
	if ($Failure -cne $Reason) { throw "Expected '$Reason' but observed '$Failure'." }
}

function Invoke-FixtureGit {
	param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
	& git -C $FixtureRepository @Arguments | Out-Null
	if ($LASTEXITCODE -ne 0) { throw ('Fixture Git failed: ' + ($Arguments -join ' ')) }
}

function Write-FixtureFile {
	param([string] $Path, [string] $Value)
	$Full = Join-Path $FixtureRepository $Path
	$Parent = Split-Path -Parent $Full
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { [void] (New-Item -ItemType Directory -Path $Parent -Force) }
	[IO.File]::WriteAllText($Full, $Value, $Utf8)
}

function Get-FixtureSha256 {
	param([string] $Path)
	return (Get-FileHash -LiteralPath (Join-Path $FixtureRepository $Path) -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FixturePolicy {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory policy fixture.')]
	param([string] $SelectorSha256 = (Get-FixtureSha256 'scripts/ci/Get-CiSelection.ps1'))
	$Pinned = @(
		[ordered]@{path='scripts/ci/Get-CiSelection.ps1';sha256=$SelectorSha256},
		[ordered]@{path='scripts/ci/Invoke-CiAcceptanceAggregate.ps1';sha256=(Get-FixtureSha256 'scripts/ci/Invoke-CiAcceptanceAggregate.ps1')},
		[ordered]@{path='scripts/ci/New-CiAcceptanceReceipt.ps1';sha256=(Get-FixtureSha256 'scripts/ci/New-CiAcceptanceReceipt.ps1')},
		[ordered]@{path='scripts/ci/activation/prototype-quality-gates.yml';sha256=(Get-FixtureSha256 'scripts/ci/activation/prototype-quality-gates.yml')},
		[ordered]@{path='scripts/ci/ci-acceptance-requirements.json';sha256=(Get-FixtureSha256 'scripts/ci/ci-acceptance-requirements.json')}
	)
	return [ordered]@{
		schemaVersion='aetheln.ci-activation-policy/v1'
		repository='ShayShimoni/aetheln-online'
		policyPath=$PolicyRepositoryPath
		workflowPath='.github/workflows/prototype-quality-gates.yml'
		templatePath='scripts/ci/activation/prototype-quality-gates.yml'
		pinnedFiles=$Pinned
	}
}

function Invoke-FixtureCandidateCommit {
	param([string] $WorkflowText, [switch] $WithExtraPath)
	Invoke-FixtureGit -Arguments @('checkout','--detach',$script:BaseRevision)
	Write-FixtureFile '.github/workflows/prototype-quality-gates.yml' $WorkflowText
	if ($WithExtraPath) { Write-FixtureFile 'unexpected.txt' 'unexpected' }
	Invoke-FixtureGit -Arguments @('add','--all')
	Invoke-FixtureGit -Arguments @('commit','-m','candidate')
	return (& git -C $FixtureRepository rev-parse HEAD).Trim()
}

function Invoke-FixtureTestedMergeCommit {
	param([string] $Base, [string] $Head, [switch] $ReverseParents, [string] $TreeRevision = $Head)
	$Tree = (& git -C $FixtureRepository rev-parse ($TreeRevision + '^{tree}')).Trim()
	if ($LASTEXITCODE -ne 0) { throw 'Fixture tree resolution failed.' }
	$Parents = if ($ReverseParents) { @('-p',$Head,'-p',$Base) } else { @('-p',$Base,'-p',$Head) }
	$Commit = ('synthetic' | & git -C $FixtureRepository commit-tree $Tree @Parents).Trim()
	if ($LASTEXITCODE -ne 0 -or $Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Fixture merge creation failed.' }
	return $Commit
}

function Invoke-FixtureActivationCheck {
	param(
		[string] $Base,
		[string] $Head,
		[string] $Tested,
		[string] $ExpectedBase = $script:BaseRevision,
		[string] $ExpectedPolicySha256 = $script:AcceptedPolicySha256
	)
	return Test-CiActivationCandidate -RepositoryRoot $FixtureRepository -BaseRevision $Base -HeadRevision $Head -TestedRevision $Tested -ExpectedAcceptedBaseRevision $ExpectedBase -ExpectedPolicySha256 $ExpectedPolicySha256
}

try {
	[void] (New-Item -ItemType Directory -Path $FixtureRepository -Force)
	& git -C $FixtureRepository init --quiet
	if ($LASTEXITCODE -ne 0) { throw 'Fixture repository initialization failed.' }
	Invoke-FixtureGit -Arguments @('config','user.name','Activation Fixture')
	Invoke-FixtureGit -Arguments @('config','user.email','activation@example.invalid')
	Invoke-FixtureGit -Arguments @('config','core.autocrlf','false')
	Invoke-FixtureGit -Arguments @('config','advice.detachedHead','false')
	Write-FixtureFile '.github/workflows/prototype-quality-gates.yml' "name: Shadow`njobs: {}`n"
	Write-FixtureFile 'scripts/ci/activation/prototype-quality-gates.yml' "name: Active`njobs: {}`n"
	Write-FixtureFile 'scripts/ci/Invoke-CiAcceptanceAggregate.ps1' "'aggregate'`n"
	Write-FixtureFile 'scripts/ci/New-CiAcceptanceReceipt.ps1' "'receipt'`n"
	Write-FixtureFile 'scripts/ci/ci-acceptance-requirements.json' "{`"schemaVersion`":`"fixture`"}`n"
	Write-FixtureFile 'scripts/ci/Get-CiSelection.ps1' "'selector'`n"
	Write-FixtureFile $PolicyRepositoryPath ((New-FixturePolicy | ConvertTo-Json -Depth 6) + "`n")
	Invoke-FixtureGit -Arguments @('add','--all')
	Invoke-FixtureGit -Arguments @('commit','-m','base')
	$script:BaseRevision = (& git -C $FixtureRepository rev-parse HEAD).Trim()
	$script:AcceptedPolicySha256 = Get-FixtureSha256 $PolicyRepositoryPath
	$TemplateText = [IO.File]::ReadAllText((Join-Path $FixtureRepository 'scripts/ci/activation/prototype-quality-gates.yml'))

	$ValidHead = Invoke-FixtureCandidateCommit -WorkflowText $TemplateText
	$ValidTested = Invoke-FixtureTestedMergeCommit -Base $script:BaseRevision -Head $ValidHead
	$Report = Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $ValidTested
	Assert-True ($Report.decision.approved -and $Report.decision.complete -and $Report.decision.reason -ceq 'exact_accepted_template') 'Exact accepted template should pass.'
	Assert-True ($Report.changedPaths.Count -eq 1 -and $Report.changedPaths[0] -ceq '.github/workflows/prototype-quality-gates.yml') 'Activation scope should contain only the live workflow.'
	Assert-True ($Report.workflow.headSha256 -ceq $Report.workflow.templateSha256 -and $Report.workflow.baseSha256 -cne $Report.workflow.headSha256) 'Workflow bytes must move from shadow to the exact accepted template.'
	Assert-True ($Report.pinnedFiles.Count -eq 5) 'Every immutable activation input should be proven.'
	Assert-True ($Report.expectedAcceptedBaseRevision -ceq $script:BaseRevision -and $Report.policySha256 -ceq $script:AcceptedPolicySha256) 'The report should bind the independently supplied accepted-base and policy identities.'
	Assert-True ([IO.Path]::IsPathRooted($Report.executables.gitPath) -and [IO.Path]::IsPathRooted($Report.executables.taskkillPath) -and $Report.executables.gitSha256 -cmatch '^[0-9a-f]{64}$' -and $Report.executables.taskkillSha256 -cmatch '^[0-9a-f]{64}$') 'The report should bind absolute trusted executable identities.'

	$PreviousErrorAction = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
	try {
		$CliOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'scripts\ci\Test-CiActivationCandidate.ps1') -RepositoryRoot $FixtureRepository -BaseRevision $script:BaseRevision -HeadRevision $ValidHead -TestedRevision $ValidTested -ExpectedAcceptedBaseRevision $script:BaseRevision -ExpectedPolicySha256 $script:AcceptedPolicySha256 2>&1 | ForEach-Object { "$_" })
		$CliExitCode = $LASTEXITCODE
	} finally { $ErrorActionPreference = $PreviousErrorAction }
	Assert-True ($CliExitCode -eq 0) "The checker CLI should emit one stdout report without a filesystem output: $($CliOutput -join ' ')"
	$Written = ($CliOutput -join "`n") | ConvertFrom-Json
	Assert-True ($Written.headRevision -ceq $ValidHead -and $Written.testedRevision -ceq $ValidTested -and $Written.decision.approved) 'Stdout report should preserve the verified identity.'

	$WrongTemplateHead = Invoke-FixtureCandidateCommit -WorkflowText "name: Candidate-controlled`njobs: {}`n"
	$WrongTemplateTested = Invoke-FixtureTestedMergeCommit -Base $script:BaseRevision -Head $WrongTemplateHead
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $WrongTemplateHead -Tested $WrongTemplateTested } 'activation_template_mismatch'

	$ExtraPathHead = Invoke-FixtureCandidateCommit -WorkflowText $TemplateText -WithExtraPath
	$ExtraPathTested = Invoke-FixtureTestedMergeCommit -Base $script:BaseRevision -Head $ExtraPathHead
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ExtraPathHead -Tested $ExtraPathTested } 'activation_scope_invalid'

	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $script:BaseRevision -Tested $ValidTested } 'activation_revision_invalid'

	$PolicyBytes = [IO.File]::ReadAllBytes((Join-Path $FixtureRepository $PolicyRepositoryPath))
	$PolicyRaw = $Utf8.GetString($PolicyBytes).Replace('"repository":', '"repository":"evil/repo","repository":')
	Assert-Rejected { ConvertFrom-CiActivationPolicyBytes -Bytes $Utf8.GetBytes($PolicyRaw) } 'activation_policy_duplicate_property'
	$WrongPathRaw = $Utf8.GetString($PolicyBytes).Replace($PolicyRepositoryPath, 'attacker/policy.json')
	Assert-Rejected { ConvertFrom-CiActivationPolicyBytes -Bytes $Utf8.GetBytes($WrongPathRaw) } 'activation_policy_schema_invalid'
	$NewlineRepositoryRaw = $Utf8.GetString($PolicyBytes).Replace('ShayShimoni/aetheln-online', "ShayShimoni/aetheln-online`n")
	Assert-Rejected { ConvertFrom-CiActivationPolicyBytes -Bytes $Utf8.GetBytes($NewlineRepositoryRaw) } 'activation_policy_schema_invalid'
	Assert-True (-not (Test-ActivationRevision (('a' * 40) + "`n")) -and -not (Test-ActivationSha256 (('a' * 64) + "`n"))) 'Revision and SHA validators must reject trailing-newline bypasses.'

	$WrongParentTested = Invoke-FixtureTestedMergeCommit -Base $script:BaseRevision -Head $ValidHead -ReverseParents
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $WrongParentTested } 'activation_tested_parents_mismatch'
	$WrongTreeTested = Invoke-FixtureTestedMergeCommit -Base $script:BaseRevision -Head $ValidHead -TreeRevision $script:BaseRevision
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $WrongTreeTested } 'activation_tested_tree_mismatch'
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $ValidHead -Head $script:BaseRevision -Tested $ValidTested -ExpectedBase $ValidHead } 'activation_base_mismatch'
	Assert-Rejected { Invoke-FixtureActivationCheck -Base ('0' * 40) -Head $ValidHead -Tested $ValidTested -ExpectedBase ('0' * 40) } 'activation_revision_missing'
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $ValidTested -ExpectedPolicySha256 ('0' * 64) } 'activation_policy_identity_mismatch'

	# A different repository history cannot self-issue its own accepted policy:
	# caller-supplied trusted pins are checked before any policy field is parsed.
	Invoke-FixtureGit -Arguments @('checkout','--detach',$script:BaseRevision)
	$HostilePolicyPath = Join-Path $FixtureRepository ($PolicyRepositoryPath -replace '/','\')
	$HostilePolicy = [IO.File]::ReadAllText($HostilePolicyPath).Replace('ShayShimoni/aetheln-online', 'attacker/self-issued')
	[IO.File]::WriteAllText($HostilePolicyPath, $HostilePolicy, $Utf8)
	Invoke-FixtureGit -Arguments @('add','--all')
	Invoke-FixtureGit -Arguments @('commit','-m','hostile-base-policy')
	$HostileBase = (& git -C $FixtureRepository rev-parse HEAD).Trim()
	Write-FixtureFile '.github/workflows/prototype-quality-gates.yml' $TemplateText
	Invoke-FixtureGit -Arguments @('add','--all')
	Invoke-FixtureGit -Arguments @('commit','-m','hostile-activation')
	$HostileHead = (& git -C $FixtureRepository rev-parse HEAD).Trim()
	$HostileTested = Invoke-FixtureTestedMergeCommit -Base $HostileBase -Head $HostileHead
	Assert-Rejected { Invoke-FixtureActivationCheck -Base $HostileBase -Head $HostileHead -Tested $HostileTested } 'activation_accepted_base_mismatch'

	# Executable discovery is machine-rooted and signed; PATH fakes must not run.
	$FakeExecutableDirectory = Join-Path $FixtureRoot 'fake-path'
	[void] (New-Item -ItemType Directory -Path $FakeExecutableDirectory -Force)
	$FakeMarker = Join-Path $FixtureRoot 'fake-executable-marker.txt'
	$FakeGitPath = Join-Path $FakeExecutableDirectory 'git.exe'
	$FakeSource = @'
using System;
using System.IO;
namespace AethelnPathFixture {
 public static class Program {
  public static int Main(string[] args) {
   var marker = Environment.GetEnvironmentVariable("AETHELN_FAKE_EXEC_MARKER");
   if (!String.IsNullOrEmpty(marker)) File.AppendAllText(marker, "fake-executed\n");
   return 97;
  }
 }
}
'@
	Add-Type -TypeDefinition $FakeSource -OutputAssembly $FakeGitPath -OutputType ConsoleApplication
	Copy-Item -LiteralPath $FakeGitPath -Destination (Join-Path $FakeExecutableDirectory 'taskkill.exe')
	$OriginalPath = [Environment]::GetEnvironmentVariable('PATH', [EnvironmentVariableTarget]::Process)
	$OriginalFakeMarker = [Environment]::GetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', [EnvironmentVariableTarget]::Process)
	try {
		[Environment]::SetEnvironmentVariable('PATH', ($FakeExecutableDirectory + ';' + $OriginalPath), [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', $FakeMarker, [EnvironmentVariableTarget]::Process)
		$script:ActivationTrustedExecutables = $null
		$HostilePathProof = Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $ValidTested
		Assert-True ($HostilePathProof.decision.approved -and -not $HostilePathProof.executables.gitPath.StartsWith($FakeExecutableDirectory, [StringComparison]::OrdinalIgnoreCase)) 'A PATH fake must not supply the Git executable.'
	} finally {
		[Environment]::SetEnvironmentVariable('PATH', $OriginalPath, [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', $OriginalFakeMarker, [EnvironmentVariableTarget]::Process)
	}
	Assert-True (-not (Test-Path -LiteralPath $FakeMarker)) 'The hostile PATH Git executable must never execute.'

	# Replacement refs in the hostile repository must not alter commit topology
	# or any blob bytes observed by the accepted-base checker.
	$TemplateOid = (& git -C $FixtureRepository rev-parse ($script:BaseRevision + ':scripts/ci/activation/prototype-quality-gates.yml')).Trim()
	$ReplacementPath = Join-Path $FixtureRoot 'replacement-template.yml'
	[IO.File]::WriteAllText($ReplacementPath, "name: Replaced`njobs: {}`n", $Utf8)
	$ReplacementOid = [string] (@(& git -C $FixtureRepository hash-object -w $ReplacementPath)[0])
	Assert-True ($ReplacementOid -cmatch '^[0-9a-f]{40}$') 'Replacement blob fixture should have an exact object ID.'
	Invoke-FixtureGit -Arguments @('replace',$TemplateOid,$ReplacementOid)
	Invoke-FixtureGit -Arguments @('replace',$ValidTested,$ValidHead)
	$GitEnvironmentNames = @('GIT_DIR','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0','GIT_NO_REPLACE_OBJECTS')
	$GitEnvironmentBefore = @{}; foreach ($Name in $GitEnvironmentNames) { $GitEnvironmentBefore[$Name] = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process) }
	try {
		[Environment]::SetEnvironmentVariable('GIT_DIR', (Join-Path $FixtureRoot 'redirected-git-dir'), [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1', [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', 'core.useReplaceRefs', [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', 'true', [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('GIT_NO_REPLACE_OBJECTS', '0', [EnvironmentVariableTarget]::Process)
		$ReplacementProof = Invoke-FixtureActivationCheck -Base $script:BaseRevision -Head $ValidHead -Tested $ValidTested
		Assert-True ($ReplacementProof.decision.approved) 'Replacement refs and inherited Git redirection/configuration must be ignored.'
	} finally {
		foreach ($Name in $GitEnvironmentNames) { [Environment]::SetEnvironmentVariable($Name, $GitEnvironmentBefore[$Name], [EnvironmentVariableTarget]::Process) }
		Invoke-FixtureGit -Arguments @('replace','-d',$TemplateOid)
		Invoke-FixtureGit -Arguments @('replace','-d',$ValidTested)
	}

	# The transport enforces stdout and stderr bounds while the process is live,
	# and timeout cleanup must terminate descendants rather than leaving work.
	$ExactBlobPath = Join-Path $FixtureRoot 'exact-output.bin'
	[IO.File]::WriteAllBytes($ExactBlobPath, [byte[]]::new(4096))
	$ExactBlobOid = [string] (@(& git -C $FixtureRepository hash-object -w $ExactBlobPath)[0])
	$ExactBytes = Invoke-ActivationGitBytes -Root $FixtureRepository -Arguments @('cat-file','blob',$ExactBlobOid) -MaximumBytes 4096 -MaximumErrorBytes 1024
	Assert-True ($ExactBytes.Length -eq 4096) 'Exact stdout limit should pass.'
	Assert-Rejected { Invoke-ActivationGitBytes -Root $FixtureRepository -Arguments @('cat-file','blob',$ExactBlobOid) -MaximumBytes 4095 -MaximumErrorBytes 1024 } 'activation_git_output_limit'
	$StderrScript = Join-Path $FixtureRoot 'stderr.cmd'
	[IO.File]::WriteAllText($StderrScript, "@echo off`r`npowershell.exe -NoProfile -Command `"[Console]::Error.Write('x' * 4096)`"`r`nexit /b 1`r`n", $Utf8)
	Invoke-FixtureGit -Arguments @('config','alias.aetheln-stderr',('!' + $StderrScript.Replace('\','/')))
	Assert-Rejected { Invoke-ActivationGitBytes -Root $FixtureRepository -Arguments @('aetheln-stderr') -MaximumBytes 1024 -MaximumErrorBytes 1024 } 'activation_git_output_limit'
	$TimeoutMarker = Join-Path $FixtureRoot 'timeout-marker.txt'
	$TimeoutScript = Join-Path $FixtureRoot 'timeout.cmd'
	$TimeoutCommand = "Start-Sleep -Seconds 3; [IO.File]::WriteAllText('$($TimeoutMarker.Replace("'","''"))','leaked')"
	[IO.File]::WriteAllText($TimeoutScript, "@echo off`r`npowershell.exe -NoProfile -Command `"$TimeoutCommand`"`r`n", $Utf8)
	Invoke-FixtureGit -Arguments @('config','alias.aetheln-timeout',('!' + $TimeoutScript.Replace('\','/')))
	$OriginalPath = [Environment]::GetEnvironmentVariable('PATH', [EnvironmentVariableTarget]::Process)
	$OriginalFakeMarker = [Environment]::GetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', [EnvironmentVariableTarget]::Process)
	try {
		[Environment]::SetEnvironmentVariable('PATH', ($FakeExecutableDirectory + ';' + $OriginalPath), [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', $FakeMarker, [EnvironmentVariableTarget]::Process)
		Assert-Rejected { Invoke-ActivationGitBytes -Root $FixtureRepository -Arguments @('aetheln-timeout') -TimeoutSeconds 1 -MaximumBytes 1024 -MaximumErrorBytes 1024 } 'activation_git_timeout'
	} finally {
		[Environment]::SetEnvironmentVariable('PATH', $OriginalPath, [EnvironmentVariableTarget]::Process)
		[Environment]::SetEnvironmentVariable('AETHELN_FAKE_EXEC_MARKER', $OriginalFakeMarker, [EnvironmentVariableTarget]::Process)
	}
	Start-Sleep -Seconds 4
	Assert-True (-not (Test-Path -LiteralPath $TimeoutMarker)) 'Timeout cleanup must terminate the full Git descendant tree.'
	Assert-True (-not (Test-Path -LiteralPath $FakeMarker)) 'The hostile PATH taskkill executable must never execute.'

	Write-Output "CI activation candidate tests passed ($script:Assertions assertions)."
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
