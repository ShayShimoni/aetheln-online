# Source Control for Unreal Assets

Aetheln Online uses Git for source and configuration files and Git LFS for
Unreal packages and reviewed binary source assets. The committed
[`.gitattributes`](../.gitattributes) and [`.gitignore`](../.gitignore) files are
the source of truth. This policy does not authorize rewriting existing objects,
resaving assets, or migrating history.

## Prerequisites

Install Git and Git LFS, then initialize Git LFS once for your user account:

```powershell
git --version
git lfs version
git lfs install
```

## Attribute Policy

The reviewed LFS matrix is:

| Category | Extensions | Policy |
| --- | --- | --- |
| Unreal packages | `.uasset`, `.umap` | LFS binary and lockable |
| Source art and DCC | `.psd`, `.psb`, `.blend`, `.fbx` | LFS binary and lockable |
| Textures and images | `.png`, `.jpg`, `.jpeg`, `.tga`, `.tif`, `.tiff`, `.exr`, `.hdr`, `.dds` | LFS binary and lockable |
| Audio | `.wav`, `.flac`, `.ogg`, `.mp3` | LFS binary and lockable |
| Video | `.mp4`, `.mov`, `.webm` | LFS binary and lockable |
| Fonts | `.ttf`, `.otf` | LFS binary and lockable |
| OFPA packages | `Content/**/__ExternalActors__/**/*.uasset`, `Content/**/__ExternalObjects__/**/*.uasset` | LFS binary, not lockable |

C/C++, Markdown, JSON, and Unreal configuration (`.h`, `.hpp`, `.c`, `.cpp`,
`.md`, `.json`, and `.ini`) remain normal Git text normalized to LF. Generated
Visual Studio `.sln` and `.slnx` files are ignored, but their explicit text
policy is CRLF so diagnostic or generated copies behave consistently.

The existing `docs/research/mmorpg-development-roadmap.png` predates the expanded
image policy and is grandfathered as a normal non-LFS Git binary without a
mandatory lock. Its exact-path exception prevents routine adds from migrating
that historical object. New PNG paths remain LFS binary and lockable.

Do not add another LFS pattern without reviewing expected sizes, edit
concurrency, merge behavior, remote storage and transfer cost, and recovery.
Revisit this matrix when representative repository measurements show material
storage or clone cost, repeated merge loss, repeated unnecessary lock waits, or
a new binary authoring format.

## Visual-Development Package

The repository-root [`visuals/`](../visuals/README.md) package is a preserved,
non-canonical source and review collection. Its PNG files use the repository's
normal LFS image policy. Importing the package does not authorize resaving,
recompressing, stripping metadata, moving files into Unreal `Content/`, or
marking concepts as approved.

Before editing a binary in this package, fetch its LFS object, verify that the
working copy is not an LFS pointer, and follow the locking workflow below. Keep
full-resolution sources separate from derived previews and record any approved
derivation in the package's
[provenance register](../visuals/asset-provenance.md).

## Locking Workflow

Pull the latest integration branch before beginning asset work. Lock a normal
Unreal package or reviewed binary source asset before editing it:

```powershell
git lfs lock Content/Path/Asset.uasset
git lfs locks
```

After the reviewed change is committed and pushed, release the lock:

```powershell
git lfs unlock Content/Path/Asset.uasset
```

Do not force-unlock another contributor's file. If a lock appears stale,
contact its owner, preserve their work, and have the owner release it or follow
an explicitly authorized repository-administration recovery process. Record the
asset, owner, related ticket, and recovery outcome.

OFPA external actor and external object packages are deliberately not lockable.
Their per-actor ownership policy is defined in
[World Runtime and Building](world-runtime-and-building.md). The containing map
remains lockable when it must be edited.

## Sensitive Material

Private keys, certificates, signing bundles, provisioning profiles, keystores,
signing-material directories, and service-account material stay outside source
control. Only narrowly named redacted examples may be committed. Never open or
print a suspected sensitive file to diagnose ignore behavior; test its path with
`git check-ignore`.

If sensitive material is staged, committed, or exposed, stop distribution,
notify the security owner, preserve safe metadata, rotate or revoke the affected
material, and follow the incident process in
[Security and Operations](security-and-operations.md). Removing a filename from
the latest tree is not credential recovery and does not erase history.

## Failure and Recovery

- If an LFS object is missing or a pointer is malformed, stop before editing or
  resaving the asset. Confirm Git LFS availability and retrieve the exact object
  through the approved remote workflow; do not replace it with a regenerated
  binary.
- `Content/Maps/StarterMap.umap` is a protected baseline. Its expected SHA-256 is
  `2a2b755b0feee3035b6c84fcd1eacebb67505d9344e66d0fb578b7804044b49a`, and
  `git lfs ls-files` must identify it with object prefix `2a2b755b0f`. A mismatch
  blocks delivery and requires investigation; do not resave or normalize it.
- For an accidental binary normalization or LFS ownership change, preserve the
  working copy, stop further writes, identify the last reviewed object, and
  coordinate a scoped recovery. Do not rewrite history without separate
  explicit authorization.

## Completed Delivery Branch Cleanup

Branch cleanup is part of completed ticket delivery only after verifying that a
short-lived ticket branch is merged into `develop`. The rule does not authorize
a deletion; follow repository operation-permission and Git-safety requirements.
Never infer a target from a wildcard or broad prune operation.

## Verification

Run the focused, provider-neutral check locally and in the CI execution path
(the required `source-control-policy` check in
`scripts/ci/Invoke-CiSuite.ps1`):

```powershell
pwsh -NoProfile -File scripts/tests/Test-SourceControlPolicy.ps1
```

It checks the LFS and EOL matrices, the grandfathered historical PNG, OFPA lock
exemption, generated and sensitive ignore paths without reading matched files,
prohibited tracked path names, and the StarterMap digest and LFS ownership. Also
run `git diff --check` and review the complete diff and status. CI provider and
runner selection remain owned by their dedicated delivery work.

Changes under `visuals/` also require the package-specific validator:

```powershell
powershell -NoProfile -File visuals/Test-VisualPackage.ps1
```

That validation is path-scoped so routine code-only work does not require
fetching the visual package's LFS objects. A missing LFS object, hash mismatch,
unexpected metadata change, broken internal reference, or incomplete provenance
entry blocks visual-package delivery; do not repair such failures by recreating
or resaving the affected binary.
