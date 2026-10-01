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
| `Backlog` | Valid tracked work not selected or not ready. | Select only after scope, acceptance criteria, and prerequisites are actionable; then `Open`. |
| `Open` | Selected, ready work with evidenced prerequisites. | Name the owner/work lane and start work; then `In Progress`. If readiness is lost before work starts, return to `Backlog`. |
| `In Progress` | Work started on an identified branch, worktree, or evidence task. | Complete developer verification and publish a reviewable artifact; then `Code Review`. Keep this state if publication is not authorized or a recoverable attempt fails. |
| `Code Review` | Reviewable PR, exact head, scope, and developer checks recorded. | Record the applicable current-head CI, independent-agent review, any explicitly required human review, and owner merge authorization; merge into `develop` before `Dev Done`. |
| `Dev Done` | Reviewed, verified implementation merged; record PR, merge SHA, review, and checks. | Start separately authorized post-merge QA (`QA`), or record an explicit QA-not-applicable decision and distinct acceptance verification before `Done`. |
| `QA` | Independent post-merge QA has started on the merged revision with procedure and environment recorded. | Record raw result, revision, limitations, and disposition; only passing required QA permits `Done`. A defect starts a linked fix cycle. |
| `Done` | Required QA or explicitly substituted acceptance verification is recorded on the issue, acceptance criteria are satisfied, and no required work remains. | No routine transition; new work uses a new or deliberately reopened ticket. |
| `Blocked` | A named prerequisite, decision, permission, dependency, or external condition prevents meaningful safe progress after viable alternatives are exhausted; record `Blocked Reason`. | Once resolved, clear the reason and return to the state supported by current evidence. |

`Dev Done` never implies QA passed. Development tests, self-review, PR merge,
and a board move cannot be reused as independent post-merge QA. If QA is not
applicable, the decision must identify the governing ticket or policy and the
distinct acceptance evidence; it is not a shortcut for missing verification.

## Issue, PR, and dependency synchronization

- Keep issue acceptance and definition-of-done checkboxes unchecked until
  their own evidence exists. Record links and exact revisions on the issue.
- Use native blocked-by/blocking and parent/sub-issue relationships where
  available, and link the PR to its issue. A dependency is satisfied only at
  the evidence level required by its consumer: `Dev Done` suffices for reviewed
  merged implementation; `Done` is required for QA or completed acceptance.
  A closed issue or board label alone does not prove either. If the consumer
  does not specify the level, the lead must record it from authoritative scope
  before declaring readiness.
- This repository integrates ordinary work through `develop`; its default
  branch is `main`. For a `develop` PR, include a plain `#<issue>` reference
  and link the issue through GitHub's Development sidebar. GitHub ignores
  closing keywords in PR descriptions targeting a non-default branch: a
  `Closes #<issue>` line does not link or close that issue on this path.
  Record the merge SHA and move the board to `Dev Done`, but normally leave
  the issue open until its required QA/acceptance evidence permits `Done`.
- Use a closing keyword in a PR targeting default-branch `main` only when
  closing that specific issue is intended and its required evidence already
  exists. A manually linked PR merged to `main` can also close an issue;
  review linked issues before merging. If GitHub has already closed an issue
  before later QA/Done board evidence is recorded, add the evidence to the
  closed issue and update the board directly; do not reopen solely to traverse
  columns. Closure never counts as QA or acceptance proof.

[GitHub's issue-linking documentation](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)
defines the default-branch keyword and manual-link behavior.

## Checks, protection, and merge

Run the applicable, attainable [Issue #16 CI baseline](continuous-integration.md)
on the exact candidate head. Distinguish required from advisory checks and
hosted portable results from selected trusted engine compile, packaged smoke,
or deferred tests; a skipped or zero-step failure is not a pass. For a merge
into `develop`, record independent-agent technical review, any separately
required human review, applicable checks, and explicit owner authorization.
The PR author records a final self-review as `COMMENTED`, never as a fabricated
`APPROVED` state. No single gate implies another.

Branch-protection enforcement is deferred while the private repository's
`develop` protection API reports HTTP 403 and requests GitHub Pro or public
visibility. The documented process gate above remains mandatory even without
enforced protection. If protection later becomes available, configure required
checks only from the then-current attainable #16 baseline; do not select a
check that never reports for the relevant event/trust path. Recheck capability
and check names before configuration rather than treating this deferral as a
permanent platform fact.

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
