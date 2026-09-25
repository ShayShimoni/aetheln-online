[CmdletBinding()]
param([ValidateSet('', 'add', 'fetch', 'hydrate')][string] $MaterializeNativeMode = '',
	[string] $MaterializeSource, [string] $MaterializeTarget, [string] $MaterializeRevision,
	[string] $MaterializePaths, [string] $MaterializeResult, [string] $MaterializeAttemptJson)

function Invoke-InitialPreparationMaterializeCommand {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $SourceRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)][ValidateSet('add', 'fetch', 'hydrate')][string] $Mode,
		[Parameter(Mandatory)][string] $ResultPath, [Parameter(Mandatory)][scriptblock] $OnProgress,
		[Parameter(Mandatory)] $ResourceRoots, [hashtable] $KnownAllocations = @{}, [string] $Paths = '')
	Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
	if (Test-Path -LiteralPath $ResultPath) { throw 'materialization_evidence_exists' }
	$Arguments = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-MaterializeNativeMode', $Mode,
		'-MaterializeSource', $SourceRoot, '-MaterializeTarget', $TargetRoot, '-MaterializeRevision', $Attempt.targetRevision,
		'-MaterializeResult', $ResultPath, '-MaterializeAttemptJson', ($Attempt | ConvertTo-Json -Compress))
	if ($Mode -cne 'add') { $Arguments += @('-MaterializePaths', $Paths) }
	$Owned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $Arguments -WorkingDirectory $SourceRoot
	try {
		$Producer = [pscustomobject]@{ process = $Owned.process; job = $Owned.supervision }
		$Producer | Add-Member -MemberType ScriptMethod -Name RequestStop -Value { $this.job.StopAndWait(5000) }
		$ProgressCallback = $OnProgress
		$Sample = { & $ProgressCallback | Out-Null }.GetNewClosure()
		$Watch = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots $ResourceRoots -KnownAllocations $KnownAllocations -OnSample $Sample -CompletionProbe { param($Item) return $Item.process.HasExited }
		if ($Watch.code -cne 'producer_completed') { throw 'materialization_monitor_failed' }
		$Owned.supervision.StopAndWait(5000)
		if ($Owned.process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 4096) { throw 'materialization_native_failed' }
		$Record = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
		if ($Record.mode -isnot [string] -or $Record.mode -cne $Mode -or $Record.revision -isnot [string] -or $Record.revision -cne $Attempt.targetRevision -or
			$Record.nativeExitCode -isnot [int] -or $Record.nativeExitCode -ne 0 -or $null -ne $Record.failure) { throw 'materialization_native_failed' }
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
	} finally { $Owned.supervision.StopAndWait(5000) }
}

function New-InitialPreparationMaterialization {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string] $SourceRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][scriptblock] $OnProgress, [Parameter(Mandatory)][scriptblock] $AssertSourceTrust,
		[Parameter(Mandatory)][string] $EvidenceRoot, [Parameter(Mandatory)] $ResourceRoots,
		[string] $LfsStorageRoot)
	Assert-InitialPreparationInputLease -Attempt $Attempt -Lease $Lease
	foreach ($Root in @($SourceRoot, $TargetRoot, $EvidenceRoot)) {
		if ($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Length -gt 4096 -or $Root -match '["\x00-\x1f]' -or $Root.Substring(2).Contains(':')) { throw 'materialization_root_invalid' }
	}
	$SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
	$TargetRoot = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')
	$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
	if ((Test-InitialPreparationWithin -Candidate $TargetRoot -Parent $SourceRoot) -or (Test-InitialPreparationWithin -Candidate $SourceRoot -Parent $TargetRoot) -or
		(Test-InitialPreparationWithin -Candidate $EvidenceRoot -Parent $TargetRoot) -or (Test-InitialPreparationWithin -Candidate $EvidenceRoot -Parent $SourceRoot)) { throw 'materialization_root_overlap' }
	if (Test-Path -LiteralPath $TargetRoot) { throw 'materialization_target_exists' }
	$Pins = New-Object Collections.ArrayList
	try {
		foreach ($Directory in @($SourceRoot, (Split-Path -Parent $TargetRoot), $EvidenceRoot)) {
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $Pins.Add($Pin) }
		}
		# Caller attests the approved SourceRoot/repository/revision and existing
		# endpoint/filter/hook trust. This is the trusted-owner procedural model,
		# not permission inferred from a candidate or a new endpoint selection.
		$Trusted = & $AssertSourceTrust $SourceRoot $Attempt.repository $Attempt.targetRevision $LfsStorageRoot
		if ($Trusted -isnot [bool] -or -not $Trusted) { throw 'materialization_source_trust_required' }
		$GitArgs = @{ Root = $SourceRoot; Attempt = $Attempt; OnProgress = $OnProgress }
		$Top = (Invoke-InitialPreparationInputGit @GitArgs -Arguments 'rev-parse --show-toplevel').Trim()
		if (-not [string]::Equals([IO.Path]::GetFullPath($Top).TrimEnd('\', '/'), $SourceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'materialization_source_invalid' }
		$Revision = (Invoke-InitialPreparationInputGit @GitArgs -Arguments ('rev-parse --verify ' + $Attempt.targetRevision + '^{commit}')).Trim()
		if ($Revision -cne $Attempt.targetRevision) { throw 'materialization_revision_mismatch' }
		$Tree = Invoke-InitialPreparationInputGit @GitArgs -Arguments ('ls-tree -r -z ' + $Revision)
		if ($Tree.Length -lt 1 -or -not $Tree.EndsWith([string][char]0)) { throw 'materialization_tree_invalid' }
		$Components = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
		$Paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		$Selected = New-Object Collections.ArrayList
		$AllFiles = New-Object Collections.ArrayList
		foreach ($Line in $Tree.TrimEnd([char]0).Split([char]0)) {
			Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
			if ($Paths.Count -ge 10000 -or $Line -cnotmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') { throw 'materialization_tree_invalid' }
			$Blob = $Matches[2]; $Path = $Matches[3]
			$IsSelected = Test-InitialPreparationInputPath -Path $Path
			if (-not $Paths.Add($Path)) { throw 'input_path_collision' }
			$Prefix = ''
			foreach ($Part in $Path.Split('/')) {
				$Prefix = if ($Prefix.Length -eq 0) { $Part } else { $Prefix + '/' + $Part }
				if ($Components.ContainsKey($Prefix) -and $Components[$Prefix] -cne $Prefix) { throw 'input_path_collision' }
				$Components[$Prefix] = $Prefix
			}
			if ($IsSelected) { [void] $Selected.Add([pscustomobject]@{ path = $Path; gitBlob = $Blob }) }
			[void] $AllFiles.Add([pscustomobject]@{ path = $Path; gitBlob = $Blob })
		}
		if (-not $Paths.Contains('AethelnOnline.uproject')) { throw 'input_project_missing' }
		$Sizes = Get-InitialPreparationInputBlobSizeMap @GitArgs -BlobIds @($AllFiles.gitBlob | Sort-Object -Unique)
		$LfsPaths = New-Object Collections.ArrayList
		$CheckoutBytes = 0L; $SelectedBytes = 0L; $LfsBytes = 0L
		foreach ($Item in $AllFiles) { $CheckoutBytes += $Sizes[$Item.gitBlob] }
		foreach ($Item in $Selected) {
			$ExpandedBytes = [long] $Sizes[$Item.gitBlob]
			if ($ExpandedBytes -gt 2GB) { throw 'materialization_input_limit' }
			if ($ExpandedBytes -gt 1024) { $SelectedBytes += $ExpandedBytes; continue }
			$Blob = Invoke-InitialPreparationInputGit @GitArgs -Arguments ('cat-file blob ' + $Item.gitBlob)
			if ($Blob.StartsWith('version https://git-lfs.github.com/spec/v1')) {
				if ($Blob -cnotmatch '\Aversion https://git-lfs.github.com/spec/v1\noid sha256:[0-9a-f]{64}\nsize (0|[1-9][0-9]{0,11})\n\z') { throw 'input_lfs_pointer_invalid' }
				$ExpandedBytes = [long] $Matches[1]
				if ($ExpandedBytes -gt 2GB) { throw 'materialization_input_limit' }
				$LfsBytes += $ExpandedBytes
				# Include/checkout use documented gitignore patterns. Restrict this
				# first implementation to unambiguous literal paths, not new globs.
				if ($Item.path -match '[,\[\]!*?]') { throw 'materialization_lfs_path_unsupported' }
				[void] $LfsPaths.Add($Item.path)
			}
			$SelectedBytes += $ExpandedBytes
		}
		if ($SelectedBytes -gt 8GB) { throw 'materialization_input_limit' }
		$CapacityRoots = @{}
		foreach ($Name in $ResourceRoots.Keys) { $CapacityRoots[$Name] = $ResourceRoots[$Name] }
		foreach ($Name in @('materializationTarget', 'materializationCache', 'materializationSource')) {
			if ($CapacityRoots.ContainsKey($Name)) { throw 'materialization_resource_root_collision' }
		}
		$CapacityRoots['materializationTarget'] = Split-Path -Parent $TargetRoot
		$CapacityRoots['materializationSource'] = $SourceRoot
		# Budget both pointer checkout and expanded working copy conservatively.
		# A fresh download also needs cache bytes; charge temporary plus final
		# cache copies rather than relying on unverified existing-object reuse.
		$Allocations = @{ materializationTarget = [long]($CheckoutBytes + $LfsBytes) }
		if ($LfsPaths.Count -gt 0) {
			if ([string]::IsNullOrWhiteSpace($LfsStorageRoot) -or $LfsStorageRoot -notmatch '^[A-Za-z]:[\\/]' -or -not (Test-Path -LiteralPath $LfsStorageRoot -PathType Container)) { throw 'materialization_lfs_storage_required' }
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $LfsStorageRoot)) { [void] $Pins.Add($Pin) }
			$CapacityRoots['materializationCache'] = $LfsStorageRoot
			$Allocations['materializationCache'] = [long](2 * $LfsBytes)
		}
		$Capacity = Get-InitialPreparationCapacity -Roots $CapacityRoots -Attempt $Attempt -KnownAllocations $Allocations
		$null = Get-InitialPreparationActionLimit -Capacity $Capacity
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		if (-not $PSCmdlet.ShouldProcess($TargetRoot, ('Create detached exact-revision worktree ' + $Revision + ' and hydrate selected LFS inputs from trusted origin'))) { throw 'materialization_declined' }
		# Reserve this new directory atomically; Git may populate this owned empty
		# reservation, but never adopts a directory that existed before the call.
		$null = New-Item -ItemType Directory -Path $TargetRoot -ErrorAction Stop
		foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $TargetRoot)) { [void] $Pins.Add($Pin) }
		$NativeArgs = @{ Attempt = $Attempt; Lease = $Lease; SourceRoot = $SourceRoot; TargetRoot = $TargetRoot; OnProgress = $OnProgress; ResourceRoots = $CapacityRoots; KnownAllocations = $Allocations }
		Invoke-InitialPreparationMaterializeCommand @NativeArgs -Mode add -ResultPath (Join-Path $EvidenceRoot 'worktree-add.json')
		$Offset = 0; $BatchNumber = 0
		while ($Offset -lt $LfsPaths.Count) {
			$Batch = New-Object Collections.ArrayList
			$Length = 0
			while ($Offset -lt $LfsPaths.Count -and $Batch.Count -lt 64 -and $Length + $LfsPaths[$Offset].Length + 1 -le 8192) {
				[void] $Batch.Add($LfsPaths[$Offset]); $Length += $LfsPaths[$Offset].Length + 1; $Offset++
			}
			$BatchNumber++
			$Csv = $Batch -join ','
			Invoke-InitialPreparationMaterializeCommand @NativeArgs -Mode fetch -Paths $Csv -ResultPath (Join-Path $EvidenceRoot ('lfs-fetch-{0:D3}.json' -f $BatchNumber))
			Invoke-InitialPreparationMaterializeCommand @NativeArgs -Mode hydrate -Paths $Csv -ResultPath (Join-Path $EvidenceRoot ('lfs-checkout-{0:D3}.json' -f $BatchNumber))
		}
		return Get-InitialPreparationInputProof -Attempt $Attempt -Lease $Lease -TargetRoot $TargetRoot -OnProgress $OnProgress
	} finally { foreach ($Pin in $Pins) { $Pin.Dispose() } }
}

# The same file is dot-source-safe with no native mode. Only this contained
# child sets LFS smudge behavior; parent environment and Git config stay intact.
if ($MaterializeNativeMode) {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$NativeExit = $null; $Failure = 'materialization_native_failed'; $ResultStream = $null
	try {
		. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
		. (Join-Path $PSScriptRoot 'InitialPreparation.GitHub.ps1')
		. (Join-Path $PSScriptRoot 'InitialPreparation.Input.ps1')
		foreach ($Root in @($MaterializeSource, $MaterializeTarget, (Split-Path -Parent $MaterializeResult))) {
			if ($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Length -gt 4096 -or $Root -match '["\x00-\x1f]') { throw 'materialization_root_invalid' }
			Assert-InitialPreparationPlainPath -Path $Root -Reason 'materialization_root_invalid'
		}
		if ($MaterializeRevision -cnotmatch '^[0-9a-f]{40}$' -or $MaterializeAttemptJson.Length -gt 16384) { throw 'materialization_native_input' }
		$ChildAttempt = $MaterializeAttemptJson | ConvertFrom-Json
		Assert-InitialPreparationAttempt -Attempt $ChildAttempt
		if ($ChildAttempt.targetRevision -cne $MaterializeRevision) { throw 'materialization_native_input' }
		$ResultStream = [IO.File]::Open($MaterializeResult, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		[Environment]::SetEnvironmentVariable('GIT_LFS_SKIP_SMUDGE', '1', 'Process')
		$Command = '--no-replace-objects --no-optional-locks -C "' + $MaterializeSource + '" -c core.autocrlf=false worktree add --detach "' + $MaterializeTarget + '" ' + $MaterializeRevision
		if ($MaterializeNativeMode -cne 'add') {
			if ($MaterializePaths.Length -lt 1 -or $MaterializePaths.Length -gt 8192) { throw 'materialization_native_input' }
			$LiteralPaths = $MaterializePaths.Split(',')
			if ($LiteralPaths.Count -gt 64) { throw 'materialization_native_input' }
			foreach ($Path in $LiteralPaths) {
				if (-not (Test-InitialPreparationInputPath -Path $Path) -or $Path -match '[\[\]!*?]') { throw 'materialization_native_input' }
			}
			$Prefix = '--no-replace-objects --no-optional-locks -C "' + $MaterializeTarget + '" '
			if ($MaterializeNativeMode -ceq 'fetch') {
				$Command = $Prefix + '-c lfs.fetchrecentalways=false lfs fetch --include="' + $MaterializePaths + '" --exclude="" origin ' + $MaterializeRevision
			} else { $Command = $Prefix + 'lfs checkout ' + (($LiteralPaths | ForEach-Object { '"' + $_ + '"' }) -join ' ') }
		}
		$Remaining = [int][Math]::Floor(($ChildAttempt.stopUsefulWorkTicks - (Get-InitialPreparationTick)) * 1000.0 / $ChildAttempt.monotonicFrequency)
		if ($Remaining -lt 1) { throw 'useful_work_deadline' }
		Initialize-PreparationGitHubTransport
		$Git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
		$Native = [Aetheln.PreparationGitHubTransport]::Run($Git, $Command, $null, $Remaining)
		$NativeExit = [int] $Native.ExitCode
		$Failure = $null
	} catch { $Failure = 'materialization_native_failed' }
	finally {
		if ($null -ne $ResultStream) {
			try {
				$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ mode = $MaterializeNativeMode; revision = $MaterializeRevision; nativeExitCode = $NativeExit; failure = $Failure } | ConvertTo-Json -Compress))
				$ResultStream.Write($Bytes, 0, $Bytes.Length); $ResultStream.Flush($true)
			} finally { $ResultStream.Dispose() }
		}
	}
	if ($null -ne $Failure) { exit 1 }
	exit $NativeExit
}
