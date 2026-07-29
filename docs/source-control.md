# Source Control for Unreal Assets

Aetheln Online uses Git for source and configuration files and Git LFS for
Unreal binary assets. The repository rules make `.uasset` and `.umap` files
lockable because Git cannot merge those binary formats safely.

## Prerequisites

Install Git and Git LFS, then initialize Git LFS once for your user account:

```powershell
git --version
git lfs version
git lfs install
```

The committed [`.gitattributes`](../.gitattributes) file is the source of truth
for tracked file types:

- `.uasset` files use Git LFS and require a lock before editing.
- `.umap` files use Git LFS and require a lock before editing.
- C++, Markdown, and Unreal `.ini` configuration remain normal Git objects.

Do not add more LFS patterns without checking the expected file sizes,
collaboration workflow, and remote storage impact.

## Locking Workflow

Pull the latest integration branch before beginning asset work. Lock an Unreal
asset before opening it for edits:

```powershell
git lfs lock Content/Path/Asset.uasset
git lfs locks
```

After the reviewed asset change is committed and pushed, release the lock:

```powershell
git lfs unlock Content/Path/Asset.uasset
```

Use the same workflow for `.umap` files. Do not force-unlock another
contributor's file; coordinate with the lock owner instead.

## Completed Delivery Branch Cleanup

Branch cleanup is part of completed ticket delivery. After verifying that a
short-lived ticket branch is merged into `develop`, delete that exact local
branch and that exact branch on `origin`. Never delete an unmerged branch or a
long-lived branch such as `develop`, and never infer the target from a wildcard
or broad prune operation.

The cleanup rule does not itself authorize a deletion. Follow the repository's
operation-permission and Git-safety requirements before running the exact local
and remote deletion commands.

## Verification

Inspect the effective attributes without creating representative binary files:

```powershell
git check-attr filter diff merge text lockable -- `
  Content/TestAsset.uasset `
  Content/TestMap.umap `
  Source/GameCore/Test.cpp `
  Config/DefaultGame.ini
```

Expected results:

- The `.uasset` and `.umap` paths report `filter: lfs`, `diff: lfs`,
  `merge: lfs`, `text: unset`, and `lockable: set`.
- The `.cpp` and `.ini` paths report these attributes as `unspecified`.

After real Unreal assets are added, confirm that Git LFS owns them:

```powershell
git lfs ls-files
```

Generated Unreal directories such as `Binaries/`, `DerivedDataCache/`,
`Intermediate/`, and `Saved/` must remain untracked as defined by
[`.gitignore`](../.gitignore).
