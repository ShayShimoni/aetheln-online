---
name: orchestrate-delivery
description: "Orchestrate repository delivery from a GitHub project board by selecting ready issues, resolving dependencies, planning safe parallel work waves, delegating bounded work to specialist subagents, monitoring and steering them, independently verifying outcomes, creating objective follow-up issues, and synchronizing issue and board state. Use when the user asks Codex to run, resume, coordinate, or monitor a delivery wave; work the board; choose the next ready ticket; delegate multi-ticket work; or manage delivery end to end. In this repository, also trigger for the shorthand commands next, next wave, resume, continue, audit, status, work #123, or issue #123."
---

# Orchestrate Delivery

Read [references/operating-contract.md](references/operating-contract.md) before
planning or delegating a work wave.

Keep the main agent as the control plane. The main agent owns authoritative
input collection, user communication, scheduling, board and issue mutations,
Git decisions, mechanical integration coordination, independence enforcement,
and faithful evidence routing. Require fresh stage agents to make substantive
readiness, dependency, scope, planning, implementation, verification, review,
fix, adjudication, and approval judgments. Never let the main agent rewrite a
stage judgment, make substantive artifact changes, or delegate board or Git
mutations to a stage agent.

Use `$work-on-ticket` for each ticket lifecycle. Add `$implement-change` for
executable code or tests, `$manage-git-flow` for authorized branch operations,
`$create-commit` and `$create-pull-request` only when explicitly requested, and
`$review-pull-request` for review and merge-readiness work.

## Select the run mode

Derive one mode from the request:

- **Next wave:** Inspect the board and choose the next objectively ready,
  actionable ticket or compatible set of tickets.
- **Targeted:** Deliver the exact issue or issues named by the user.
- **Resume:** Reconcile active board items, the current worktree, pull requests,
  and any available agent results before continuing.
- **Audit:** Inspect and recommend only. Do not mutate issues, the board, or the
  repository.

Accept the repository shorthand aliases defined in `AGENTS.md`. An alias grants
only the corresponding run mode; it grants no additional Git or publication
authority.

When the user asks to run, deliver, manage, or resume a wave, treat scoped issue
comments, status updates, `Blocked Reason` updates, and objective follow-up
issues as authorized coordination work. A request to inspect, assess, plan, or
recommend is read-only. Never infer authorization to commit, push, publish a
pull request, merge, pull, change branches, deploy, delete, or migrate.

## Establish ground truth

1. Read the root `AGENTS.md`, relevant repository documentation, and the exact
   issue bodies, acceptance criteria, links, parent/sub-issues, and board fields.
2. Inspect the branch, worktree status, diff, remotes, and upstream relationship
   before any repository mutation. Preserve unrelated user changes.
3. Inspect the live GitHub project rather than relying on remembered field IDs
   or stale status. Prefer the GitHub connector for issues and pull requests.
   Use authenticated `gh` for GitHub Projects when connector coverage is
   insufficient.
4. Inspect open pull requests, checks, review state, and existing verification
   evidence for active work.
5. Do not pull or otherwise reconcile a stale local branch without the explicit
   Git permission required by `AGENTS.md`.

If a ticket, dependency, acceptance criterion, product decision, or required
board field cannot be discovered and the choice would affect delivery, stop and
ask the user. Preserve explicit `TBD` decisions.

## Select the execution route

After establishing ground truth and before planning the wave, create a
deterministic assessment from the evidenced ticket and repository state. Start
each new wave with `current_route` set to `direct`, then run:

`scripts/Get-DeliveryExecutionRoute.ps1 -AssessmentPath <assessment.json>`

Use `direct` only for a fully evidenced, one-file localized text edit, small
line change, or localized reproducible bug fix. Every required positive fact
must be known and every hazard must be false. Route multi-file,
calculation-heavy, ambiguous, cross-component, behavior-sensitive, security,
data, networking, schema, architecture or release, and canonical-meaning work
through `planned`.

Treat missing or malformed assessment evidence, validation failure, or
classifier failure as `planned`.

Build the worker handoff from the selected route:

- **Direct:** Set `execution_route` to `direct`. Supply the exact common ticket
  and acceptance criteria, canonical sources, `allowed_paths` containing
  exactly one nonblank path, `required_checks`, `non_goals`, `baseline_status`,
  and `baseline_diff`. Supply `classifier_evidence` as the exact retained,
  complete direct classifier result. Omit `work_package`; do not synthesize a
  package or planning narrative for a direct worker.
- **Planned:** Set `execution_route` to `planned` and supply the synthesized
  `work_package` produced by the planned stages, together with the required
  worker baseline, scope, non-goals, and checks. Omission of `execution_route`
  is accepted only for compatibility with legacy planned handoffs; it is not
  normal control-plane output.

If scope or risk expands during direct implementation, stop that direct work
package. Rerun classification with the prior route retained as `direct`,
promote the wave to `planned`, run the missing analyst and synthesizer stages,
and launch a new planned worker with their synthesized `work_package`. Never
retrofit a synthesized package into the direct handoff or continue the direct
worker after promotion. Once a wave is planned, keep it planned for the rest of
that wave; never downgrade it to direct.

Direct skips only the analyst and synthesizer. It still requires fresh worker,
verifier, reviewer, and approver stages. Run fresh integrator, fixer,
adjudicator, and QA stages whenever their existing conditions apply. Preserve
all stage-isolation, mutation-boundary, fix-loop, and final-reporting rules for
both routes.

Retain the original assessment, normalized classifier result, reason codes,
previous route, promotion state, selected route, skipped stages, required
downstream stages, and conditional fresh stages as wave evidence. Retain failed
assessment and classifier evidence before applying the planned fallback.

## Build the delivery wave

For planned work, have a fresh analyst create a small dependency graph from
explicit evidence, then have a fresh synthesizer select the bounded work wave:

- Issue relationships, linked pull requests, and issue-body sequencing.
- The canonical roadmap and documentation authority.
- Required artifacts, accepted decisions, and merged prerequisites.
- Current board and verification state.

Do not invent a dependency from intuition. Distinguish:

- **Ready:** Every material prerequisite has evidence and the work is actionable.
- **Follow-up:** Useful later work that is outside the current ticket.
- **Blocked:** Work cannot make meaningful progress because a required input,
  decision, permission, dependency, or environment is unavailable.

Require the synthesized wave to prefer the smallest coherent unit and never
choose an epic as an implementation unit when an actionable child issue exists.
When several ready candidates are otherwise equivalent, require it to apply the
repository roadmap first, then priority, delivery stage, and target version.
Ask the user when fresh stage evidence leaves these signals in material
conflict.

An active branch or `In Progress` item does not silently override a canonical
stage gate. Resume later-stage or off-roadmap work only when the current request
names it or a still-applicable approved exception is recorded and does not
conflict with canonical product or architecture rules. Otherwise present the
conflict and ask the user which governance signal controls.

Before starting downstream implementation, inspect `Dev Done` and `QA` items
that gate it. Reconcile existing evidence first. Perform or advance independent
QA only when the user explicitly authorizes it or the repository records the
required independent QA evidence.

## Enforce stage isolation

Do not rely on prompt instructions alone:

- Give every stage agent, including worker, integrator, and fixer, a read-only
  repository and a tool surface with no mutation-capable GitHub, board,
  deployment, or external-system tools.
- Require worker, integrator, and fixer agents to return a structured
  `delivery_file_bundle_v1` full-file artifact. They reason about and author the
  change, but do not edit the worktree or hand-author a patch.
- For worker, integrator, and fixer only, disable the default shell and expose
  exactly one required launcher-owned MCP tool, `read_allowed_source_file`.
  It may return only the complete attested bytes and launcher-owned base hash
  for one exact existing allowed source path. Keep web, apps, inherited MCP,
  directory listing, arbitrary filesystem access, producer hashing, and every
  write or command capability disabled. Non-producer stages receive no source
  inspection server.
- Capture the source commit, complete pre-existing worktree status and diff,
  allowed paths, and non-goals before launch.
- Require the declared source commit to resolve to the repository's current
  `HEAD` and require the handoff workspace to equal this skill's resolved
  repository root. Hash the complete tracked and non-ignored repository
  snapshot before and after every stage; reject any mutation before consuming its output. Fail
  closed before launch if that inventory contains a sensitive path or traverses
  any reparse-point ancestor; never open or hash secret material. Capture Git
  inventory from the process's raw output stream and use NUL delimiters so valid
  special-character filenames are preserved without a shell text pipeline.
- Do not consume a producer bundle or generate, persist, or validate its
  candidate patch until post-stage attestation succeeds and the changed-path
  set is empty. A mutating stage may produce sealed failure evidence only.
- Have the launcher validate each bundle record against the attested snapshot,
  mechanically generate a candidate patch, parse its proposed paths, reject
  unsafe or out-of-scope paths, and require strict `git apply --check` before
  returning it. Apply the exact validated patch mechanically only when the
  user's request authorizes the repository change.

The producer artifact is a closed object with `format` exactly
`delivery_file_bundle_v1` and a `files` array containing one full-result record
per changed file. Every record has exactly `path`, `operation`, `base_sha256`,
`encoding`, and `content`:

- `path` is the normalized repository-relative path and must be unique, safe,
  declared in `changed_paths`, and inside `allowed_paths`.
- `operation` is `create` or `replace`; delete, rename, copy, and partial-file
  operations are not supported.
- `create` requires a path absent from the source snapshot and
  `base_sha256: null`. `replace` requires an existing source-snapshot file and
  the exact lowercase SHA-256 of its original bytes.
- `encoding` is `utf8` for complete resulting text or `base64` for complete
  resulting binary bytes. `content` is always the complete resulting file, not
  a diff fragment.

The launcher validates the closed bundle, path set, operation preconditions,
base hashes, encoding, and complete content only after zero-mutation
attestation. It then generates the candidate patch mechanically and sends that
unchanged patch through the existing strict path, scope, sensitive-path, and
applicability gates. Base64 bundle records use Git binary patch records; UTF-8
records use Git's text patch route while still declaring complete resulting
bytes. Validation and application must use the provided scripts. Applicability
checking and application each use an isolated temporary repository whose
proposed paths neutralize text, EOL, filter, ident, and working-tree encoding
attributes. Application writes and verifies those exact bytes through
reparse-checked destinations. Neither step may change repository or global Git
configuration. The control plane must never infer, rewrite, or repair
bundle content or generated patch bytes. A rejected output, bundle, or
candidate patch remains sealed audit evidence only and is never routable to a
later substantive stage.

### Attested external-file ingest

`delivery_file_bundle_v1` remains restricted to agent-authored results. A
frozen user-provided file tree may enter the repository only through
`delivery_external_file_bundle_v1` and
`scripts/Invoke-DeliveryExternalFileIngest.ps1`. Version 1 is closed to the
literal absent target root `visuals`, 1-128 create-only records, and the
case-sensitive extensions `.png`, `.svg`, `.ps1`, `.md`, and `.json`. Each
record has exactly `path`, `operation`, `size`, and `sha256`; mapping, rename,
replace, delete, and partial import are unsupported. Paths are limited to 240
characters so every derived journal and evidence artifact remains bounded.
The published external schema selects the manifest, prepared journal, and
accepted evidence contracts at its root; validate schema artifacts with
`scripts/tests/Test-DeliveryArtifactSchemas.ps1`.
Manifest and composite writers require an explicit repository root and reject
repository-contained output paths before creating a file. Text-patch handoff,
evidence, and patch inputs to composite binding must also remain outside the
repository.

The source root is the declared standalone `visuals` directory itself. Never
enumerate its parent. The importer verifies exact source and staged
file-and-directory inventories, rejects contract JSON over 1 MiB or 16 levels
of nesting, and preflights those limits for deterministic output artifacts. It
uses a new non-reparse staging root outside the repository on the
repository volume, durably seals a prepared journal, and atomically moves the
complete staged payload into the absent destination. The external manifest
must remain outside the source, staging, and repository roots. The declared
source commit must equal repository `HEAD` before preparation and immediately
before the move. Recheck `HEAD` immediately after the move, prepare sealed
evidence at a non-routable pending path, and make the final `HEAD` decision
and destination-inventory check before atomically publishing accepted evidence.
Detected drift before publication returns an incomplete result with no routable
evidence. The same-principal check-to-rename instruction boundary is not
transactional; worker launch revalidates the full chain and destination. A failure before that
move leaves the repository unchanged. A failure after the move but before
accepted evidence is published returns
`ingest_evidence_incomplete` and leaves the imported tree and journal intact.
The directory rename is not a transaction with arbitrary processes running as
the same local principal: mutation after the last staging read is detected by
destination verification and can only yield the incomplete state, never
accepted evidence or a worker launch. Do not persist ACL changes or roll back
the retained tree to simulate a stronger cross-process transaction.
Only `scripts/Confirm-DeliveryExternalFileIngest.ps1`, supplied with the
independently retained journal hash, may reconcile that state; it verifies and
seals evidence but never repairs, rewrites, rolls back, or deletes files.
If the deterministic evidence file already exists because failure occurred
after its final rename, reconciliation accepts and seals it only when its exact
bytes match the reconstructed evidence; any differing file is rejected.

Every worker that consumes imported external files must set
`consumes_external_files: true` and include the closed
`external_ingest_evidence` object with the evidence-manifest, external-manifest,
and prepared-journal paths and independently retained SHA-256 values, plus
`source_commit` and `target_root`. The launcher opens all three read-only
artifacts, verifies their exact hashes and cross-field agreement, and checks the
source commit, literal target root, destination, and current inventory before
starting the child. Revalidate after the launch snapshot and again immediately
before child execution; the normal post-stage snapshot rejects any concurrent
mutation. Do not add these fields to unrelated text-only workers.

After accepted external ingest and accepted authored-text evidence both exist,
use `scripts/New-DeliveryCompositeCandidate.ps1` to create the closed
`delivery_composite_candidate_v1`. It binds the source commit, the exact
external- and text-evidence manifest hashes, the final inventory hash, and the
complete ordinal-sorted changed paths. It reopens the external evidence,
external manifest, and prepared journal against their retained hashes, validates
the text producer's exact handoff, requires the same source commit, and compares
the complete `changed_paths` artifact union before and after sealing. Its
validator uses two changed-path inventory passes and rereads the sealed
candidate. Unrelated worktree mutation remains the launcher's pre/post snapshot
responsibility. Route the exact sealed bytes as the single launcher-provenance
artifact for verifier and approver, and as reviewer artifact-state evidence
alongside the complete diff and inventory. Mechanical binding alone does not
require an integrator; substantive conflict resolution does.

Inspect the effective child permissions and tool surface, not only the custom
agent TOML. Parent-turn runtime overrides may broaden a child's sandbox or
tools. Use a separately restricted fresh Codex session or equivalent
environment. Never broaden a coding stage to workspace-write merely because the
current runtime cannot provide finer path controls; read-only structured-bundle
production is the required fallback.

Stage profiles disable apps, web search, and inherited MCP servers. If the
current surface ignores those restrictions or cannot remove external mutation
tools, do not spawn the stage through that surface. Launch it through a
mechanically restricted fresh session or stop and request the required
environment or authority. Do not weaken hooks or safety policy to obtain
isolation.

Use the bundled restricted launcher for every substantive stage:

1. Build a stage handoff JSON that matches
   [references/handoff-schemas.json](references/handoff-schemas.json).
2. Run `scripts/Validate-DeliveryHandoff.ps1` and reject extra or prohibited
   fields before launch. It reads the handoff bytes once and derives both the
   parsed object and SHA-256 from that buffer; route the frozen buffer to the
   child rather than rereading the file.
3. Run `scripts/Invoke-DeliveryStage.ps1`. It starts an ephemeral Codex process
   with user config ignored, apps and web search disabled, an empty MCP map, an
   explicit sandbox, no approvals, a structured output schema, and the declared
   workspace root. It confines immutable output, event, and audit files to a
   dedicated non-reparse artifact root outside the repository. The production
   launcher resolves the installed `codex` command itself and exposes no
   caller-selectable executable override.
4. Record the returned session ID, handoff SHA-256, event log, output artifact,
   source commit, pre/post snapshot hashes, audit, and validated candidate patch
   when produced. Once child launch begins, the launcher persists the audit
   before reporting a process error, nonzero exit, post-stage attestation error,
   repository mutation, malformed patch, out-of-scope path, or non-applying
   patch; retain failed-attempt evidence too. A rejected handoff, source,
   workspace, profile, or artifact destination is a preflight validation result,
   not a stage attempt, and must never consume the retry budget.
5. Retain the launcher-generated evidence manifest. It binds the output, event
   log, audit, and candidate patch by SHA-256, records the launcher-controlled
   `accepted` or `rejected` disposition, and marks those files plus the manifest
   read-only. Integrity sealing proves authenticity, not acceptance. Use
   `scripts/Test-DeliveryEvidence.ps1 -IntegrityOnly` only to inspect retained
   failed-attempt evidence. Pre-disposition manifests may verify only in that
   mode and report `legacy-unknown`; they are never routable. Run the script
   without that switch, with the independently retained expected manifest and
   handoff hashes, before routing any bound artifact to a later stage; normal
   verification accepts only an `accepted` manifest.

Before reading a verifier or approver handoff, the launcher alone must ingest
one out-of-band `delivery_authoritative_evidence_manifest_v1` through
`Invoke-DeliveryStage.ps1 -AuthoritativeEvidenceManifestPath <path>
-AuthoritativeEvidenceManifestSha256 <sha256>`. Neither input belongs to or may
be derived from the routed handoff. The launcher reads the manifest once,
verifies its independently retained hash, and freezes its exact bytes before
reading the handoff. It passes only those frozen bytes and that hash to
`Validate-DeliveryHandoff.ps1 -AuthoritativeEvidenceManifestBytes <bytes>
-ExpectedAuthoritativeEvidenceManifestSha256 <sha256>`; the validator must not
reopen a manifest path or accept a handoff-controlled substitute.

The manifest is a closed object with exactly `format`, `stage`, and a nonempty
`records` array. Every record is closed with exactly `field`, `kind`,
`provenance`, `encoding`, `source`, and `sha256`. Every required verifier or
approver Linux check log is a distinct `raw_check_output` record with
`kind: command_log` and `provenance: launcher`; repository narrative, Windows
output, command text, or aggregate output cannot substitute for it.

Complete evidence preflight before resolving or invoking Codex. Detect relevant
duplicate JSON members in the frozen raw manifest and handoff bytes before
ordinary parsing can collapse them. Compare the frozen manifest, handoff
`required_evidence_sources` declarations, and mapped routed records as a
case-sensitive exact-once correspondence keyed by `field` and `source`, then
require all six authoritative values, routed encoding, and recomputed content
SHA-256 to agree. No set may contain a missing, extra, duplicate, synthesized,
merged, normalized, or substituted entry.

Reject every missing, null, empty, malformed, duplicate, substituted, or
mismatched manifest, declaration, mapped field, or routed record with the
stable retry-neutral codes defined in the operating contract. Emit exactly one
sanitized closed result containing only `phase`, `code`, `field`,
`child_launched: false`, and `attempt_consumed: false`; never expose rejected
values. Such preflight defects do not consume or increment a stage attempt.
After a child actually launches, execution failures remain bounded to the
initial attempt plus one fresh replacement.

Do not replace the launcher with a normal shared-context spawn unless the
current surface can mechanically attest equivalent tool, sandbox, workspace,
freshness, schema, and audit controls.

## Enforce fresh-context stages

Run every substantive stage in a newly spawned agent thread with no inherited
conversation turns. Use `fork_turns="none"` when the collaboration tool
supports it. Never reuse an agent for a later stage, a fix iteration,
re-verification, re-review, or re-approval.

Execute this stage sequence:

1. **Analyze planned work:** For the planned route, spawn `delivery_analyst` to
   inspect raw tickets, board state, repository state, canonical sources,
   dependencies, and acceptance criteria. Skip this stage only for direct.
2. **Synthesize planned work:** For the planned route, spawn a fresh
   `delivery_synthesizer` to independently discover and validate the
   authoritative source inventory from canonical indexes and the raw live-board
   export, then produce a bounded work package and verification plan. Do not
   provide the analyst's citations, selection, or conclusions. Skip this stage
   only for direct.
3. **Implement:** Spawn a fresh `delivery_worker`. A planned worker executes
   only the synthesized `work_package`. A direct worker receives only the exact
   raw direct handoff and retained classifier evidence defined under execution-
   route selection; it receives no `work_package` or planning narrative.
4. **Integrate when needed:** Spawn a fresh `delivery_integrator` for any
   substantive combination, adaptation, or conflict resolution across worker
   artifacts. Skip this stage only when no material integration change exists.
5. **Verify:** Spawn a fresh `delivery_verifier` to reproduce the behavior,
   execute applicable checks when permitted, and judge acceptance criteria.
   Give it raw launcher-produced command and test logs as normative neutral
   evidence, never another stage's narrative. Require it to judge those logs
   independently without receiving or relying on the implementer's reasoning
   or claimed result. A sandbox denial prevents the affected check from being
   rerun in that stage, but does not erase valid raw evidence from an external
   launcher execution.
6. **Review:** Spawn a separate fresh `delivery_reviewer` to inspect the actual
   diff for correctness, regressions, security, canonical-rule conflicts, and
   missing tests.
7. **Fix:** If verification or review produces an actionable finding, spawn a
   fresh `delivery_fixer` for that iteration. Give it the raw ticket, current
   artifact, and accepted findings, not the prior worker's private reasoning.
8. **Repeat:** After every integration or fix, spawn new verifier and reviewer
   agents. Continue
   the fix, verify, and review loop until both independent stages pass or an
   objective blocker, unresolved decision, or missing authority prevents
   progress.
9. **Approve:** Spawn a fresh `delivery_approver` with only the ticket,
   acceptance criteria, canonical sources, raw pre-stage baseline, allowed
   scope, non-goals, final artifact, and raw command/log evidence. Do not provide
   prior findings, corrections, verdicts, confidence, severity, or expected
   outcomes. Treat approval as a readiness recommendation; the main agent still
   enforces user authority and performs board reconciliation.
10. **QA after merge:** When QA is authorized, spawn a fresh `delivery_qa`
    against the merged commit and target QA environment. Keep this independent
    from implementation verification and review. Require QA evidence before the
    main agent advances `Dev Done -> QA -> Done`.

Give fresh agents only the minimum evidence needed for their stage. Prefer raw
artifacts, exact file paths, ticket text, commands, logs, and cited findings.
Do not leak earlier conclusions, verdicts, severity, confidence, resolution
labels, expected answers, hidden reasoning, or praise that could anchor an
independent verifier, reviewer, approver, or adjudicator. Follow the
stage-specific handoff allowlists in the operating contract. When the main agent
would materially change a stage's readiness, dependency, scope, or plan
judgment, spawn a new analyst, synthesizer, or adjudicator instead.

Route every material disagreement between analysis, synthesis, verification,
review, or approval through a fresh `delivery_adjudicator`. Give it a neutral
question and raw evidence without prior agent claims or preferred framing. Send
an approver rejection to a fresh fixer only when the rejection identifies a
concrete artifact defect with raw evidence. Adjudicate interpretive conflicts
or disagreement with otherwise passing gates before authorizing another fix.

Detect non-converging fix loops. If the same material finding recurs unchanged
after two fresh fixer passes, or a fixer produces no relevant artifact change,
spawn a fresh adjudicator to confirm the stall. If confirmed, record an
objective blocker and ask the user for direction. Do not stop merely because an
arbitrary iteration count was reached.

Bound failed attempts without approving incomplete work. Permit one initial
stage attempt and one newly spawned replacement for the same tool or execution
failure. Treat launcher `output_invalid` as an execution failure: retain its
rejected evidence, permit at most the fresh replacement, and never send its
artifact into a fixer or substantive patch-repair loop. Escalate a repeated
same-cause stage failure, except for the one bounded transport-only recovery
defined below. Escalate a wave when two consecutive
fix/adjudication cycles produce no net reduction in material findings, or when
an explicit session time, token, concurrency, or user-approved budget is
exhausted. Leave the ticket accurately active or blocked with evidence; never
convert budget exhaustion into approval.

After an unchanged planned work package exhausts its initial producer attempt
and one fresh replacement solely because the launcher rejects a malformed or
non-applying candidate patch, the control plane may run one transport-only
recovery generation. This exception applies only when both children reported
`passed`, source and post-stage snapshots are identical, allowed scope and
authority are unchanged, no unsafe or out-of-scope path or tamper signal
exists, and no product or architecture decision changed. A fresh adjudicator
must confirm `ArtifactFailureKind` was only `patch_malformed` or
`patch_nonapplying` and confirm the other facts from raw governing evidence,
then a fresh planned
synthesizer may partition the original allowed path set into a fixed set of
nonempty, pairwise-disjoint packages whose union is an exact cover of that
original set. Launch fresh producers for those packages.

Do not give the adjudicator, synthesizer, or replacement producers any rejected
bundle bytes, generated patch bytes, producer narrative, or attempted repair;
those remain audit-only. The recovery may create only that one fixed
decomposition and may not repartition or recur. Any failure in the recovery
generation escalates with evidence. This is not a third adaptive execution
route, and it must never be selected by size, file-count, or another heuristic;
the wave remains `planned` throughout.

## Decide what can run in parallel

During normal planned synthesis, identify natural disjoint full-file ownership
boundaries for a multi-file scaffold before launching producers. When such
boundaries are independently verifiable, declare the complete fixed package set
and integration order up front so no single producer artifact is the only
transport path. Do not partition by file count, bundle size, or another hidden
threshold, and keep coupled changes sequential when a safe disjoint boundary
does not exist.

Parallelize only work that is independent, bounded, and independently
verifiable. Default to:

- Parallel read-only ticket analysis, documentation research, log inspection,
  or review.
- One mechanical patch application in the shared worktree at a time.
- Parallel read-only worker agents only for disjoint path ownership with a
  named integration plan.

When the user authorizes branch and worktree creation for implementation,
prepare isolation through `$manage-git-flow` before applying candidate patches:

- Create a dedicated ticket-named branch from the governed integration branch.
- For multiple independently applicable tickets or work packages, create one
  registered Git worktree per dedicated ticket branch. Resolve and record every
  worktree path, source commit, path owner, and integration order.
- Run each restricted launcher from its own worktree so the launcher's resolved
  repository root and snapshot bind the stage to that worktree.
- Apply validated patches serially inside each worktree with
  `scripts/Apply-DeliveryPatch.ps1`. Keep stage agents read-only and keep all
  branch, worktree, index, and commit operations in the main control plane.
- Use a fresh integrator in the designated integration worktree when artifacts
  need substantive combination, then repeat fresh verification and review.

Do not create an extra worktree for a single shared-worktree package or a
read-only audit. Never remove a worktree or branch without explicit permission
for the exact resolved target.

Do not parallelize tickets that share prerequisite decisions, files, generated
artifacts, mutable services, board fields, or verification environments. Never
let subagents mutate GitHub issues, project fields, branches, commits, pull
requests, or deployments.

Use no more than three child agents at once. Prefer the project agents:

- `delivery_analyst` for evidence, dependency, and readiness analysis.
- `delivery_synthesizer` for an independent executable work package.
- `delivery_worker` for one exact implementation scope.
- `delivery_integrator` for substantive artifact integration.
- `delivery_verifier` for independent behavioral and acceptance verification.
- `delivery_reviewer` for independent diff and regression review.
- `delivery_fixer` for one accepted finding set and one fix iteration.
- `delivery_adjudicator` for material stage disagreements or non-convergence.
- `delivery_approver` for the final independent readiness gate.
- `delivery_qa` for independent post-merge target-environment QA.

Give every subagent a bounded prompt containing:

- Exact issue URL or number and objective.
- Authoritative documents to read.
- Allowed files or investigation scope.
- Explicit non-goals and prohibited external mutations.
- Required checks or evidence.
- A concise return contract: result, files/evidence, checks, risks, blockers,
  and recommended next action.

## Run and monitor the wave

1. Present the selected wave, dependencies, agent assignments, and any
   assumption that affects execution.
2. Move an actionable ticket through the board only as far as current evidence
   permits. Add a concise start note when useful.
3. Spawn a new agent for every stage in the fresh-context sequence. While an
   agent runs, continue only control-plane work that cannot bias or conflict
   with that stage.
4. Inspect agent status at natural milestones. Steer an agent whose scope is
   drifting; interrupt it before it makes unsafe or conflicting changes.
5. Treat a subagent failure as an orchestration problem first. Retry a transient
   tool call only inside a still-running, healthy stage. Abandon a stalled or
   failed stage attempt and rerun it in a newly spawned agent with
   `fork_turns="none"` and a narrower handoff. Never reuse the failed agent or
   complete a required substantive stage in the main thread. Do not mark the
   ticket `Blocked` merely because one agent failed.
6. Inspect every returned artifact and the actual final diff. Never accept a
   stage summary as verification by itself.
7. Require fresh verifier and reviewer passes after implementation, every
   integration, and every fix. Require a fresh approver after the final passes
   and fresh QA after merge when authorized.
8. Reconcile the issue and board only from the integrated artifacts, exact
   check evidence, independent findings, and final approval recommendation.

## Handle blockers and newly discovered work

When work is genuinely blocked:

1. Record the specific unavailable prerequisite or decision.
2. Record what was attempted, safe evidence, and the smallest concrete action
   that unblocks progress.
3. Set `Blocked` and populate `Blocked Reason` only from the main agent.
4. Do not hide partial completion or mark downstream work ready.

For objective out-of-scope work, create a follow-up issue only when its problem,
scope, acceptance criteria, evidence, and relationship to the source ticket are
clear. Add it to `Backlog` unless it is an immediate prerequisite. Ask the user
before creating work that embeds a new product decision, priority change, or
material scope expansion.

## Finish the run

Before ending:

- Reconcile the actual worktree, issue, pull request, checks, review state, and
  board status.
- Record the retained classifier assessment, result, reason codes, route state,
  promotions, and stages skipped or required.
- Record exact verification performed and its result.
- Record the distinct fresh agents used for analysis, synthesis, implementation,
  each fix iteration, verification, review, and approval.
- Leave unfinished work in an accurate active or blocked state with a concrete
  continuation note.
- Report the delivered outcome, agent assignments, board changes, verification,
  follow-ups, blockers, and any action still requiring user authority.

Do not claim continuous background monitoring. This skill coordinates one
invoked wave. Use a new invocation to resume it, or a separately configured
Codex automation for scheduled board audits.

## Optimize without weakening quality

Every launched stage emits sealed telemetry containing observed timing,
session, and token values, with explicit nulls for unavailable observations.
Never estimate missing usage. Aggregate per-stage telemetry for the wave in the
control plane. Apply `execution_policy` limits only when their provenance and
approval time show explicit user approval; unspecified limits remain null. A
preflight rejection consumes no execution attempt. Persist evidence before
escalating an observed limit breach. A budget may stop incomplete work, but it
can never approve it or weaken an independent gate.

Route by capability label, without assuming a concrete model mapping:

- **economy:** Deterministic control-plane validation or bounded extraction
  only.
- **standard:** Routine substantive stages.
- **elevated:** Material security or correctness work, adjudication, or an
  evidenced standard-route failure only.

Do not downgrade independent verification, review, or approval merely to save
tokens. Leave concrete model mapping unset until supported configuration and
representative evaluations justify it.

Parallelize independent read-heavy discovery and work with disjoint path
ownership. Keep tightly coupled code, schema, and test changes, integration,
final gates, publication, and board reconciliation serialized. Prefer the
smallest number of agents that provides real independence; every extra agent
adds token and coordination cost.

Establish a representative baseline with the quality-capable route, optimize
prompts, context, and routing, then compare on the same corpus and environment.
Adopt a cheaper route only when the comparator classification is `improved` and
no independent gate is weakened. Prefer references, hashes, and continuation
artifacts over repeatedly copying large narratives.

Use quality criteria version `issue-70-quality-v1` and compare records with:

`scripts/Compare-DeliveryEfficiency.ps1 -BaselinePath <baseline.json> -CandidatePath <candidate.json>`
