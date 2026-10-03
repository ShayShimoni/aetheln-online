# Delivery Workflow

## Scope and authority

This is the repository-facing work-status contract for
[Project 1](https://github.com/users/ShayShimoni/projects/1). GitHub Issues
record scope and acceptance criteria; the project board records delivery state.
The [roadmap](../README.md) sets delivery order, while
[Continuous Integration](continuous-integration.md) defines the attainable
Issue #16 checks. Neither a column nor a closed issue substitutes for evidence.

One maintainer may author and merge a PR, but cannot approve that same PR on
GitHub. A fresh restricted independent-agent technical review is the ordinary
independent review gate, recorded as **agent review**, not human approval.
Review by another person is additionally required only when the ticket,
policy, or risk boundary explicitly requires it; it replaces another gate
only if that governing requirement explicitly says so. Automated CI checks
and the repository owner's explicit merge authorization remain separate gates.
Unavailability of an otherwise optional human reviewer does not prevent
delivery; an explicitly required human review remains a real prerequisite.

## Evidence-based project states

Each move records the evidence that justifies its entry. Do not advance a
column solely to make the board look current.

| Status | Entry evidence | Exit rule |
| --- | --- | --- |
| `Backlog` | Valid tracked work not selected or not ready. | Select only after scope, acceptance criteria, and prerequisites are actionable and the issue is in the current roadmap stage; then `Open`. The lead tops up `Open` from here in roadmap order (owner priorities first) when it falls below 3, keeping about 8 at most. |
| `Open` | Selected, ready work with evidenced prerequisites. | Name the owner/work lane and start work; then `In Progress`. If readiness is lost before work starts, return to `Backlog`. |
| `In Progress` | Work started on an identified branch, worktree, or evidence task. | Complete developer verification and publish a reviewable artifact; then `Code Review`. Keep this state if publication is not authorized or a recoverable attempt fails. |
| `Code Review` | Reviewable PR, exact head, scope, and developer checks recorded. | Record the applicable current-head CI, independent-agent review, any explicitly required human review, and owner merge authorization; merge into `develop` before `Dev Done`. After a partial merge of a multi-PR issue, return to `In Progress`. |
| `Dev Done` | Reviewed, verified implementation merged; record PR, merge SHA, review, and checks. | Start separately authorized post-merge QA (`QA`), or record an explicit QA-not-applicable decision and distinct acceptance verification before `Done`. |
| `QA` | Independent post-merge QA has started on the merged revision with procedure and environment recorded. | Record raw result, revision, limitations, and disposition; only passing required QA permits `Done`. Stay in `QA` only while the round runs. At round end: every box checked goes to `Done`; a failed criterion that needs a fix returns to `Open` with a comment naming the failed criterion and the `develop` commit and giving the expected and actual result and exact steps to reproduce or simulate the failure; criteria that wait only for a later QA round return to `Dev Done`; a criterion waiting on a decision or dependency goes to `Blocked`. |
| `Done` | Required QA or explicitly substituted acceptance verification is recorded on the issue, acceptance criteria are satisfied, and no required work remains. | When a release branch that contains the work is cut, move to `Release Candidate`; otherwise no routine transition. New work uses a new or deliberately reopened ticket. |
| `Release Candidate` | The work is in a cut `release/vX.Y.Z` branch, which carries an internal pre-release tag; the board `Release` field records the tag. | Move to `Released` when that release is distributed to players. If the work is pulled from the release, return to `Done` and clear `Release`. |
| `Released` | The release that contains the work was distributed to players, merged to `main`, tagged, published as a GitHub Release, and back-merged into `develop`. | No routine transition. A defect in a released build starts a `hotfix/*` cycle with its own ticket. |
| `Blocked` | A named prerequisite, decision, permission, dependency, or external condition prevents meaningful safe progress after viable alternatives are exhausted; record `Blocked Reason`. | When implementation or blocker-removal work starts, clear the reason and move it to `In Progress` (or to `QA` when a QA round resumes); return it to `Blocked` if the reason still holds when that work stops. When a separate issue tracks the blocker, that separate issue moves to `In Progress` instead. Once resolved, return to the state supported by current evidence. A `Blocked` issue has no open PR of its own. When another issue's PR also carries its fix, it gets no `Code Review` card: its `Blocked Reason` names the carrying PR, the PR body lists it with `Refs #<issue>`, and after the merge it moves to `Dev Done` or `QA` as its evidence supports. |

`Dev Done` never implies QA passed. Development tests, self-review, PR merge,
and a board move cannot be reused as independent post-merge QA. If QA is not
applicable, the decision must identify the governing ticket or policy and the
distinct acceptance evidence; it is not a shortcut for missing verification.

## Issue, PR, and dependency synchronization

- Keep issue acceptance and definition-of-done checkboxes unchecked until
  their own evidence exists. Record links and exact revisions on the issue.
- Use native blocked-by/blocking and parent/sub-issue relationships where
  available, and reference the issue in its PR with `Refs #<issue>`. A
  dependency is satisfied only at the evidence level required by its consumer:
  `Dev Done` suffices for reviewed merged implementation; `Done` is required
  for QA or completed acceptance.
  A closed issue or board label alone does not prove either. If the consumer
  does not specify the level, the lead must record it from authoritative scope
  before declaring readiness.
- This repository integrates ordinary work through `develop`, which has been
  the default branch since 2026-10-03 (owner decision recorded on
  [Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16)).
  GitHub honours closing keywords in PRs into the default branch, so a
  `Closes #<issue>` line in a `develop` PR would close the issue at merge,
  before QA. A manually linked PR merged into the default branch also closes
  the issue, so review a PR's linked issues before merging. Do not add a
  Development-sidebar link on PRs into `develop`: `Refs #<issue>` is the only
  reference. Record the merge SHA, move the board to `Dev Done`, and leave the
  issue open until its required QA/acceptance evidence permits `Done`.
- PRs into `main` (`release/*` and `hotfix/*` only) also use `Refs`; the
  issues they ship are already `Done`. If GitHub closes an issue before its
  QA/Done board evidence is recorded, add the evidence to the closed issue and
  update the board directly; do not reopen solely to traverse columns. Closure
  never counts as QA or acceptance proof.

[GitHub's issue-linking documentation](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)
defines the default-branch keyword and manual-link behavior.

## Parallel work

One lead retains board state, integration, PR publication, and merge
authority. Parallel agents, whether subagents or separate sessions, each own
one bounded lane and never move the board, merge, or edit another lane.

- Before a lane starts, record its issue, exact base revision, branch and
  isolated worktree, owned paths, prohibited paths, dependencies with the
  evidence level each requires, and the shared resources it will use.
- Run lanes concurrently only when their owned paths are disjoint and their
  dependencies are satisfied or explicitly stacked on an exact revision.
  Overlapping paths are serialized or integrated by the lead.
- Treat shared resources as gates: an engine checkout, host lease, runner,
  derived-data cache, full CI slot, or worktree has one owner at a time. Use
  the existing lease or lock where one exists; otherwise the lead names the
  owner. Mutation-sensitive suites run serially per worktree.
- Size parallelism to available capacity, not a fixed agent count. Start
  another lane only when a bounded, independent, ready lane exists and the
  machine, shared resources, and review capacity can serve it without delaying
  a gate; run fewer lanes when those are contended.
- When a ready independent lane is deferred, record the specific limiting
  resource, dependency, or review-capacity gate and the condition for starting it.
- A lane hands back its exact head, changed paths, raw check results, and
  limitations. The lead verifies them independently before integrating; a
  lane's own report is not review evidence for its own work.

## Rule enforcement

`scripts/delivery/Test-BoardIntegrity.ps1` reads the board and open PRs
through the locally authenticated `gh` and reports each violation as
`<rule-id> #<number> <detail>`. It exits 1 on any violation; `-Json` emits
the same result for tooling. It reports:

- `done-unchecked-acceptance`: a `Done` issue with an unchecked box.
- `closed-issue-status`: a closed issue outside `Done`, `Release Candidate`,
  or `Released`.
- `open-issue-final-status`: an open issue in `Done` or `Released`.
- `release-field-empty`: a `Release Candidate` or `Released` item without
  `Release`.
- `blocked-reason-empty`: a `Blocked` item without `Blocked Reason`.
- `draft-pr-open`: an open draft PR, reported by its PR number.
- `open-pr-issue-status`: an open PR whose issue is not in `Code Review`, or
  is not on the board.
- `code-review-without-pr`: a `Code Review` issue that no open PR links.
- `duplicate-pr-issue`: an issue that more than one open PR links.

A PR links an issue through a `#<issue>` in its title or a GitHub closing
reference. The body's `Refs #<issue>` lines are not links, so the second
issue of a carried fix can sit in `Blocked` as that rule requires. The last
three rules skip `release/*`, `hotfix/*`, and `main`-into-`develop`
back-merge PRs, which ship work already tracked on its own tickets.

Run it at session start, after every merge, and before every release cut. A
violation is fixed, or ticketed when it cannot be fixed at once, before other
work continues.

The hosted `pull-request-policy` check (`.github/workflows/delivery-policy.yml`)
needs no project access. It fails a PR whose base is `main` and whose head is
not `release/*` or `hotfix/*`, whose head branch does not start with
`feature/`, `fix/`, `docs/`, `chore/`, `release/`, `hotfix/`, or `codex/`
(head `main` is allowed only as a back-merge into `develop`), or whose title
lacks `#<issue>`. A `release/*` PR, into `main` or merging release fixes back
into `develop`, and the `main`-into-`develop` back-merge may omit the issue,
because they carry several tickets rather than one. A `hotfix/*` PR has its
own ticket, so its title still needs it.

## Checks, protection, and merge

Run the applicable, attainable [Issue #16 CI baseline](continuous-integration.md)
on the exact candidate head. Distinguish required from advisory checks and
hosted portable results from selected trusted engine compile, packaged smoke,
or deferred tests; a skipped or zero-step failure is not a pass. For a merge
into `develop`, record independent-agent technical review, any separately
required human review, applicable checks, and explicit owner authorization.
The PR author records a final self-review as `COMMENTED`, never as a fabricated
`APPROVED` state. No single gate implies another.

The repository became public on 2026-10-02, and branch protection was set on
`develop` and `main` on 2026-10-03 with the owner's approval: changes only
through PRs with 0 required approvals, required checks `quality-gates` and
`change-impact` (non-strict), `enforce_admins` on, and no force-push or
deletion. The process gate above still applies, since protection does not
check review or owner authorization. Add `pull-request-policy` to both
branches' required checks once it has reported on a `develop` PR and a `main`
PR; never require a check that does not report for the relevant event.

## Releases and versioning

Releases follow Gitflow and Semantic Versioning. A version becomes official
only when a build is distributed to players, as with a mobile app store
release. By the owner's delegation on 2026-10-03
([Issue #212](https://github.com/ShayShimoni/aetheln-online/issues/212)), the
lead decides when to cut each release and runs the whole flow, including the
merge to `main`. The owner may veto or stop any release.

**Version numbers.** Versions follow `MAJOR.MINOR.PATCH` and align with the
roadmap `Target Version` lines (1.0.0 MVP, 1.1.0, 1.2.0, 2.0.0, 2.1.0).

| Bump | When |
| --- | --- |
| MAJOR | A roadmap stage change, a rebrand, or an incompatible change to saves, the network protocol, or world rules. |
| MINOR | A backward-compatible roadmap milestone or feature set. |
| PATCH | Fixes only, shipped from a `hotfix/*` branch. |
| `-alpha.N` | Internal build while the milestone is still in progress. |
| `-beta.N` | Internal build once the milestone is feature-complete and in testing. |
| `-rc.N` | Final internal candidate; only fixes enter the release branch. |

The first internal pre-release is `v1.0.0-alpha.1`. Plain `v1.0.0` exists only
when the MVP acceptance criteria pass release QA.

**Build numbers.** Every package, internal or player-facing, carries the
version in `ProjectVersion` (`Config/DefaultGame.ini`, set when the release
branch is cut) plus the CI build number as SemVer build metadata, for example
`1.0.0-alpha.1+412`. Build metadata never changes version precedence, so
day-to-day internal builds are told apart by build number alone and never
consume a version. Pre-release tags mark only named internal milestones, not
every build. The build number is the packaging workflow's GitHub Actions
`run_number`, which the packaging step stamps into the package. Where a
platform field accepts only numbers (for example a Windows file version), use
`MAJOR.MINOR.PATCH.<build number>`. The first release-cut script must verify
that each consumer of `ProjectVersion` accepts the full string, before relying
on it.

**When the lead cuts a release.**

- Cut an internal pre-release when a playable milestone lands on `develop`,
  or when about two weeks have passed with `Done` work waiting.
- Never include work that is not `Done`.

**Internal release flow.**

1. Cut `release/vX.Y.Z` from `develop`. Set `ProjectVersion`, move the included
   tickets to `Release Candidate`, and fill their `Release` field.
2. Build the internal packages and run release QA on the release branch. Fix
   defects only on the release branch, and merge each fix back into `develop`.
3. Place an annotated pre-release tag (`vX.Y.Z-alpha.N`, `-beta.N`, `-rc.N`)
   on the tested release-branch commit. Internal builds never merge to `main`.

**Player distribution.** Player distribution means an external playtest on
`staging`, Early Access, or a store launch on `production`; an external
playtest counts.

1. Merge the release branch into `main` through a PR, and place the annotated
   tag on the merge commit. A beta playtest may ship a pre-release version.
2. Publish a GitHub Release that lists the included tickets.
3. Back-merge `main` into `develop`, then move the tickets to `Released`.

`main` receives only `release/*` and `hotfix/*` PRs, never other branches and
never direct pushes. Until the first player distribution, `main` stays
unchanged.

**Hotfixes.**

1. Branch `hotfix/vX.Y.Z` from `main` for a defect in a distributed build, and
   bump PATCH.
2. Merge it into `main` and tag it.
3. Merge it back into `develop`, and into an open release branch if one exists.

## Representative trace and limitation

[Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14) and
[PR #66](https://github.com/ShayShimoni/aetheln-online/pull/66) show a
historical `In Progress` to `Code Review` to `Dev Done` lifecycle: the PR
published development work, then merged as
`3d6151a344dc07db7c4c272057b79323560c7be8`. Both recorded reviews
were by the author and `COMMENTED`; no separate pre-merge human or
independent-agent review is recorded. This predates the reconciled pre-merge
gate and must **not** be presented as satisfying it. Fresh independent
post-merge QA was recorded later on #14 before `Done`. A new ticket using
this workflow must additionally record independent technical review and the
applicable exact-head checks before owner-authorized merge.
