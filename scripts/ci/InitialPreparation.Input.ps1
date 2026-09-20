# Already-materialized build input proof. No checkout, hydration, configuration
# changes, status filters, cleanup/deletion, or engine/toolchain attestation.
function Invoke-InitialPreparationInputProgress {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][scriptblock] $OnProgress)
	if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
	& $OnProgress | Out-Null
}

function Assert-InitialPreparationInputLease {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$LeaseEntries = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })
	if ($LeaseEntries.Count -ne 1 -or $LeaseEntries[0].attemptId -cne $Attempt.attemptId -or $LeaseEntries[0].ownerPid -ne $PID -or
		$LeaseEntries[0].ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') -or -not $LeaseEntries[0].stream.CanWrite) { throw 'input_lease_invalid' }
}

function Invoke-InitialPreparationInputGit {
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Arguments,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][scriptblock] $OnProgress,
		[AllowNull()][string] $Body = $null)
	Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
	Initialize-PreparationGitHubTransport
	if (-not ('Aetheln.PreparationInputGitTask' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Threading.Tasks;
namespace Aetheln {
 public static class PreparationInputGitTask {
  public static Task<object> Start(Type transport, string exe, string arguments, string body) {
   return Task.Factory.StartNew<object>(() => transport.GetMethod("Run").Invoke(null, new object[]{exe,arguments,body,15000}));
  }
 }
}
'@
	}
	$Git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
	$Command = '--no-replace-objects --no-optional-locks -C "' + $Root + '" ' + $Arguments
	$Task = [Aetheln.PreparationInputGitTask]::Start([Aetheln.PreparationGitHubTransport], $Git, $Command, $Body)
	try {
		while (-not $Task.Wait(100)) { Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress }
		$Result = $Task.Result
		if ($Result.ExitCode -ne 0 -or [Text.Encoding]::UTF8.GetByteCount($Result.Output) -gt 1048576) { throw 'input_git_failed' }
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		return [string] $Result.Output
	} finally {
		# Existing transport owns native termination and its bounded cleanup. Never
		# leave its process running after this proof operation returns or fails.
		if (-not $Task.IsCompleted) {
			try { if (-not $Task.Wait(18000)) { throw 'input_git_cleanup_unproven' } }
			catch { if (-not $Task.IsCompleted) { throw 'input_git_cleanup_unproven' } }
		}
	}
}

function Test-InitialPreparationInputPath {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path)
	if ($Path.Length -gt 1024 -or $Path -match '[\\:\x00-\x1f\x7f"<>|?*\uFFFD]' -or $Path.StartsWith('/')) { throw 'input_path_invalid' }
	foreach ($Part in $Path.Split('/')) {
		if ($Part -in @('', '.', '..') -or $Part -match '[. ]$' -or $Part -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)' -or $Part -ieq '.git') { throw 'input_path_invalid' }
		if ($Part -match '^(?i:\.env.*|\.gitmodules|\.lfsconfig|\.ssh|\.aws|\.azure|\.kube|\.gnupg|\.npmrc|\.pypirc|\.netrc|auth\.json|tokens?\.json|credentials?(?:\..*)?|secrets?(?:\..*)?|id_rsa(?:\..*)?|id_ed25519(?:\..*)?|.*\.(?:pem|key|pfx|p12|keystore|jks))$') { throw 'input_sensitive_or_external_path' }
	}
	return ($Path -match '^(?i:Source|Config|Content|Plugins|Build|Platforms)/' -or $Path -imatch '^(AethelnOnline\.uproject|\.gitattributes)$')
}

function Get-InitialPreparationInputInventory {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)][scriptblock] $OnProgress)
	$GitArgs = @{ Root = $Root; Attempt = $Attempt; OnProgress = $OnProgress }
	$Head = (Invoke-InitialPreparationInputGit @GitArgs -Arguments 'rev-parse --verify HEAD').Trim()
	$Top = (Invoke-InitialPreparationInputGit @GitArgs -Arguments 'rev-parse --show-toplevel').Trim()
	if ($Head -cne $Attempt.targetRevision -or -not [string]::Equals([IO.Path]::GetFullPath($Top).TrimEnd('\', '/'), $Root, [StringComparison]::OrdinalIgnoreCase)) { throw 'input_revision_mismatch' }
	$TreeText = Invoke-InitialPreparationInputGit @GitArgs -Arguments 'ls-tree -r -z HEAD'
	$IndexText = Invoke-InitialPreparationInputGit @GitArgs -Arguments 'ls-files --stage -z'
	$PathsText = Invoke-InitialPreparationInputGit @GitArgs -Arguments 'ls-files -z'
	$Tree = New-Object Collections.ArrayList
	$Unique = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Components = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
	$IndexExpected = New-Object Text.StringBuilder
	$PathsExpected = New-Object Text.StringBuilder
	if ($TreeText.Length -lt 1 -or -not $TreeText.EndsWith([string][char]0)) { throw 'input_tree_invalid' }
	foreach ($Line in $TreeText.TrimEnd([char]0).Split([char]0)) {
		Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
		if ($Tree.Count -ge 10000 -or $Line -cnotmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') { throw 'input_tree_invalid' }
		$Mode = $Matches[1]; $Blob = $Matches[2]; $Path = $Matches[3]
		$Selected = Test-InitialPreparationInputPath -Path $Path
		if (-not $Unique.Add($Path)) { throw 'input_path_collision' }
		$Prefix = ''
		foreach ($Part in $Path.Split('/')) {
			$Prefix = if ($Prefix.Length -eq 0) { $Part } else { $Prefix + '/' + $Part }
			if ($Components.ContainsKey($Prefix) -and $Components[$Prefix] -cne $Prefix) { throw 'input_path_collision' }
			$Components[$Prefix] = $Prefix
		}
		[void] $Tree.Add([pscustomobject]@{ path = $Path; mode = $Mode; gitBlob = $Blob; selected = $Selected })
		[void] $IndexExpected.Append($Mode + ' ' + $Blob + " 0`t" + $Path + [char]0)
		[void] $PathsExpected.Append($Path + [char]0)
	}
	if ($IndexText -cne $IndexExpected.ToString() -or $PathsText -cne $PathsExpected.ToString()) { throw 'input_index_mismatch' }
	$Others = Invoke-InitialPreparationInputGit @GitArgs -Arguments 'ls-files --others -z -- ":(icase)Source" ":(icase)Config" ":(icase)Content" ":(icase)Plugins" ":(icase)Build" ":(icase)Platforms" ":(icase)AethelnOnline.uproject" ":(icase).gitattributes" ":(icase).gitmodules" ":(icase).lfsconfig"'
	if ($Others.Length -ne 0) { throw 'input_untracked_build_input' }
	if (@($Tree | Where-Object { $_.path -ceq 'AethelnOnline.uproject' }).Count -ne 1) { throw 'input_project_missing' }
	return ,@($Tree | Where-Object { $_.selected })
}

function Get-InitialPreparationInputBlobSizeMap {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Root,
		[Parameter(Mandatory)][ValidateCount(1, 10000)][string[]] $BlobIds,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][scriptblock] $OnProgress)
	$Sizes = @{}
	$Expected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Id in $BlobIds) {
		if ($Id -cnotmatch '^[0-9a-f]{40}$' -or -not $Expected.Add($Id)) { throw 'input_blob_invalid' }
	}
	for ($Offset = 0; $Offset -lt $BlobIds.Count; $Offset += 128) {
		$Last = [Math]::Min($Offset + 127, $BlobIds.Count - 1)
		$Batch = @($BlobIds[$Offset..$Last])
		$Text = Invoke-InitialPreparationInputGit -Root $Root -Attempt $Attempt -OnProgress $OnProgress -Arguments 'cat-file --batch-check' -Body (($Batch -join "`n") + "`n")
		if ($Text.Length -gt 8192 -or -not $Text.EndsWith("`n")) { throw 'input_blob_invalid' }
		$Lines = $Text.Substring(0, $Text.Length - 1).Split([char]10)
		if ($Lines.Count -ne $Batch.Count) { throw 'input_blob_invalid' }
		for ($Index = 0; $Index -lt $Batch.Count; $Index++) {
			if ($Lines[$Index] -cnotmatch '^([0-9a-f]{40}) blob (0|[1-9][0-9]{0,11})$') { throw 'input_blob_invalid' }
			$Id = $Matches[1]; $Size = [long] $Matches[2]
			if ($Id -cne $Batch[$Index] -or $Sizes.ContainsKey($Id)) { throw 'input_blob_invalid' }
			$Sizes[$Id] = $Size
		}
	}
	if ($Sizes.Count -ne $BlobIds.Count) { throw 'input_blob_invalid' }
	return $Sizes
}

function Get-InitialPreparationInputProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $TargetRoot, [Parameter(Mandatory)][scriptblock] $OnProgress)
	Assert-InitialPreparationInputLease -Attempt $Attempt -Lease $Lease
	if ($TargetRoot -notmatch '^[A-Za-z]:[\\/]' -or $TargetRoot.Length -gt 4096 -or $TargetRoot -match '[\x00-\x1f"]') { throw 'input_root_invalid' }
	$Root = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')
	$Proof = [pscustomobject]@{ attempt = $Attempt; lease = $Lease; root = $Root; files = (New-Object Collections.ArrayList);
		pins = (New-Object Collections.ArrayList); digest = $null; closed = $false; aggregateBytes = 0L }
	try {
		foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Root)) { [void] $Proof.pins.Add($Pin) }
		$Inventory = Get-InitialPreparationInputInventory -Root $Root -Attempt $Attempt -OnProgress $OnProgress
		$GitArgs = @{ Root = $Root; Attempt = $Attempt; OnProgress = $OnProgress }
		$BlobIds = @($Inventory.gitBlob | Sort-Object -Unique)
		$Sizes = Get-InitialPreparationInputBlobSizeMap @GitArgs -BlobIds $BlobIds
		$Directories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		$Manifest = New-Object Text.StringBuilder
		$Buffer = New-Object byte[] 65536
		foreach ($Item in $Inventory) {
			Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
			$Path = Join-Path $Root $Item.path
			$Directory = Split-Path -Parent $Path
			if ($Directories.Add($Directory)) {
				if ($Directories.Count -gt 4096) { throw 'input_limit' }
				foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory $Directory)) { [void] $Proof.pins.Add($Pin) }
			}
			try { $Handle = [Aetheln.PreparationDirectory]::OpenSource($Path) } catch { throw 'input_file_unavailable' }
			try { $Stream = New-Object IO.FileStream($Handle, [IO.FileAccess]::Read) } catch { $Handle.Dispose(); throw }
			$Entry = [pscustomobject]@{ path = $Item.path; mode = $Item.mode; gitBlob = $Item.gitBlob; stream = $Stream; materializedSha256 = $null; bytes = $Stream.Length }
			[void] $Proof.files.Add($Entry)
			$Proof.aggregateBytes += $Entry.bytes
			if ($Entry.bytes -gt 2GB -or $Proof.aggregateBytes -gt 8GB) { throw 'input_limit' }
			$Pointer = $null
			if ($Sizes[$Item.gitBlob] -le 1024) {
				$BlobText = Invoke-InitialPreparationInputGit @GitArgs -Arguments ('--no-replace-objects cat-file blob ' + $Item.gitBlob)
				if ($BlobText.StartsWith('version https://git-lfs.github.com/spec/v1')) {
					if ($BlobText -cnotmatch '\Aversion https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize (0|[1-9][0-9]{0,11})\n\z') { throw 'input_lfs_pointer_invalid' }
					$Pointer = @{ oid = $Matches[1]; size = [long] $Matches[2] }
				}
			}
			$Sha1 = [Security.Cryptography.SHA1]::Create()
			$Sha256 = [Security.Cryptography.SHA256]::Create()
			try {
				$Header = [Text.Encoding]::ASCII.GetBytes('blob ' + $Entry.bytes + [char]0)
				$null = $Sha1.TransformBlock($Header, 0, $Header.Length, $Header, 0)
				while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
					$null = $Sha1.TransformBlock($Buffer, 0, $Read, $Buffer, 0)
					$null = $Sha256.TransformBlock($Buffer, 0, $Read, $Buffer, 0)
					Invoke-InitialPreparationInputProgress -Attempt $Attempt -OnProgress $OnProgress
				}
				$null = $Sha1.TransformFinalBlock(@(), 0, 0); $null = $Sha256.TransformFinalBlock(@(), 0, 0)
				$ActualBlob = ([BitConverter]::ToString($Sha1.Hash)).Replace('-', '').ToLowerInvariant()
				$Entry.materializedSha256 = ([BitConverter]::ToString($Sha256.Hash)).Replace('-', '').ToLowerInvariant()
			} finally { $Sha1.Dispose(); $Sha256.Dispose() }
			if ($null -ne $Pointer) {
				if ($ActualBlob -ceq $Item.gitBlob) { throw 'input_lfs_unhydrated' }
				if ($Entry.bytes -ne $Pointer.size -or $Entry.materializedSha256 -cne $Pointer.oid) { throw 'input_content_mismatch' }
			} elseif ($ActualBlob -cne $Item.gitBlob) { throw 'input_content_mismatch' }
			if ($Item.path -imatch '\.u(?:project|plugin)$') {
				if ($Entry.bytes -gt 65536) { throw 'input_descriptor_limit' }
				$Stream.Position = 0
				$DescriptorBytes = New-Object byte[] ([int] $Entry.bytes)
				if ($Stream.Read($DescriptorBytes, 0, $DescriptorBytes.Length) -ne $DescriptorBytes.Length) { throw 'input_descriptor_invalid' }
				try {
					$DescriptorText = (New-Object Text.UTF8Encoding($false, $true)).GetString($DescriptorBytes)
					$Descriptor = $DescriptorText | ConvertFrom-Json
					if ($Descriptor -isnot [Management.Automation.PSCustomObject]) { throw 'invalid' }
				} catch { throw 'input_descriptor_invalid' }
				# Reject additional root declarations outright, including duplicate
				# keys whose earlier value ConvertFrom-Json could otherwise collapse.
				$Keys = [regex]::Matches($DescriptorText, '"(?<key>(?:[^"\\]|\\.)*)"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(50))
				foreach ($Key in $Keys) {
					$Name = $Key.Groups['key'].Value
					if ($Name.Contains('\')) { throw 'input_descriptor_invalid' }
					if ($Name -in @('AdditionalRootDirectories', 'AdditionalPluginDirectories')) { throw 'input_external_descriptor_root' }
				}
			}
			[void] $Manifest.Append(([ordered]@{ path = $Entry.path; mode = $Entry.mode; gitBlob = $Entry.gitBlob; materializedSha256 = $Entry.materializedSha256; bytes = $Entry.bytes } | ConvertTo-Json -Compress) + "`n")
			if ($Manifest.Length -gt 8388608) { throw 'input_limit' }
		}
		if ([Text.Encoding]::UTF8.GetByteCount($Manifest.ToString()) -gt 8388608) { throw 'input_limit' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Proof.digest = ([BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Manifest.ToString())))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		$null = Assert-InitialPreparationInputProof -Proof $Proof -OnProgress $OnProgress
		return $Proof
	} catch { Close-InitialPreparationInputProof -Proof $Proof; throw }
}

function Assert-InitialPreparationInputProof {
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] $Proof, [Parameter(Mandatory)][scriptblock] $OnProgress)
	if ($Proof.closed -or $Proof.digest -cnotmatch '^[0-9a-f]{64}$') { throw 'input_proof_closed' }
	Assert-InitialPreparationInputLease -Attempt $Proof.attempt -Lease $Proof.lease
	$Inventory = Get-InitialPreparationInputInventory -Root $Proof.root -Attempt $Proof.attempt -OnProgress $OnProgress
	if ($Inventory.Count -ne $Proof.files.Count) { throw 'input_inventory_changed' }
	for ($Index = 0; $Index -lt $Inventory.Count; $Index++) {
		Invoke-InitialPreparationInputProgress -Attempt $Proof.attempt -OnProgress $OnProgress
		$Expected = $Inventory[$Index]; $Held = $Proof.files[$Index]
		if ($Held.path -cne $Expected.path -or $Held.mode -cne $Expected.mode -or $Held.gitBlob -cne $Expected.gitBlob -or
			-not $Held.stream.CanRead -or $Held.stream.Length -ne $Held.bytes) { throw 'input_inventory_changed' }
	}
	foreach ($Pin in $Proof.pins) { if ($Pin.IsClosed -or $Pin.IsInvalid) { throw 'input_proof_closed' } }
	return $Proof.digest
}

function Close-InitialPreparationInputProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Proof)
	foreach ($Entry in $Proof.files) { $Entry.stream.Dispose() }
	foreach ($Pin in $Proof.pins) { $Pin.Dispose() }
	$Proof.closed = $true
}
