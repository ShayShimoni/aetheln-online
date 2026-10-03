[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $ManagedWorkspaceRoot,
	[Parameter(Mandatory)][string] $RegistrationPath,
	[Parameter(Mandatory)][string] $RegistrationSha256,
	[Parameter(Mandatory)][string] $Repository,
	[Parameter(Mandatory)][string] $SourceRevision,
	[Parameter(Mandatory)][string] $DeadlineUtc,
	[Parameter(Mandatory)][string] $ResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Owned child of the trusted-editor-automation editor step (TA-020, issue #236).
# That step holds the engine host lease, runs this script from its fresh
# exact-revision control checkout inside a kill-on-close Job Object, and
# releases the lease only after that job is proven empty. Like the compile
# gate, this re-syncs the registered managed workspace to the tested revision;
# the revision and clean checks stay as post-sync assertions. The only output
# is one fixed code in ResultPath: none, a managed_registration_* or
# managed_workspace_* reason, or an editor_workspace_* assertion reason.
function Get-WorkspaceGitText([string] $Git, [string] $Root, [string] $Arguments) {
	# Same git resolution and flags as the managed sync.
	$Info = New-Object Diagnostics.ProcessStartInfo $Git, ('--no-replace-objects --no-optional-locks -C "' + $Root + '" ' + $Arguments)
	$Info.UseShellExecute = $false
	$Info.CreateNoWindow = $true
	$Info.RedirectStandardOutput = $true
	$Info.RedirectStandardError = $true
	$Info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false, $true)
	$Process = [Diagnostics.Process]::Start($Info)
	$ErrorText = $Process.StandardError.ReadToEndAsync()
	$Text = $Process.StandardOutput.ReadToEnd()
	$Process.WaitForExit()
	$null = $ErrorText.Result
	if ($Process.ExitCode -ne 0) { throw 'editor_workspace_query_failed' }
	return $Text
}

$Result = 'managed_workspace_failed'
try {
	. (Join-Path $PSScriptRoot 'ManagedCompileRegistration.ps1')
	. (Join-Path $PSScriptRoot 'ManagedCompileWorkspace.ps1')
	$TrustedControl = [IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot))).TrimEnd('\', '/')
	$Deadline = [DateTime]::ParseExact($DeadlineUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
	$Registration = Get-ManagedCompileRegistration -Path $RegistrationPath -ExpectedSha256 $RegistrationSha256 -Repository $Repository -TargetRoot $ManagedWorkspaceRoot
	try {
		$Registered = $Registration.record
		# Authorization comes from the separately registered operator tuple, as
		# in the gate. The closure binds this script's values, so the sync's own
		# parameters can never stand in for them.
		$TrustRegisteredWorkspace = {
			param($ProposedControl, $ProposedTarget, $ProposedRepository, $ProposedRevision)
			return ($ProposedControl -ceq $TrustedControl -and
				[string]::Equals([IO.Path]::GetFullPath($ProposedTarget).TrimEnd('\', '/'), [IO.Path]::GetFullPath($Registered.targetRoot).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -and
				$ProposedRepository -ceq $Registered.repository -and $ProposedRevision -ceq $SourceRevision)
		}.GetNewClosure()
		$null = Sync-ManagedCompileWorkspace -ControlRoot $TrustedControl -TargetRoot $ManagedWorkspaceRoot -SourceRevision $SourceRevision -Repository $Repository -ExpectedGitCommonDirectory $Registered.gitCommonDirectory -DeadlineUtc $Deadline -AssertRepositoryTrust $TrustRegisteredWorkspace
	} finally { Close-ManagedCompileRegistration -Registration $Registration }
	$Result = 'editor_workspace_query_failed'
	$Root = [IO.Path]::GetFullPath($ManagedWorkspaceRoot).TrimEnd('\', '/')
	$Git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	if ((Get-WorkspaceGitText -Git $Git -Root $Root -Arguments 'rev-parse HEAD').Trim() -cne $SourceRevision) { $Result = 'editor_workspace_revision_changed' }
	elseif ((Get-WorkspaceGitText -Git $Git -Root $Root -Arguments 'status --porcelain --untracked-files=all').Trim().Length -ne 0) { $Result = 'editor_workspace_dirty' }
	else { $Result = 'none' }
} catch {
	$Message = [string] $_.Exception.Message
	if ($Message -cmatch '\Amanaged_(registration|workspace)_[a-z_]{1,48}\z') { $Result = $Message }
}
[IO.File]::WriteAllText($ResultPath, $Result, (New-Object Text.UTF8Encoding $false))
