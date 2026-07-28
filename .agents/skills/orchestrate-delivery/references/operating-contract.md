# Aetheln Online Delivery Operating Contract

## Contents

- [Sources of truth](#sources-of-truth)
- [Board fields](#board-fields)
- [Status evidence](#status-evidence)
- [Adaptive route selection](#adaptive-route-selection)
- [Ready-work ordering](#ready-work-ordering)
- [Parallelization rules](#parallelization-rules)
- [Fresh-context handoff](#fresh-context-handoff)
- [Specialist contracts](#specialist-contracts)
- [Incident handling](#incident-handling)

## Sources of truth

- Repository: `ShayShimoni/aetheln-online`
- Integration branch: `develop`
- GitHub Project: owner `ShayShimoni`, project `1`
- Work status, priority, ownership, and target version: GitHub Issues and the
  live project board
- Delivery order: `README.md` and `docs/next-steps-mmorpg-prototype.md`
- Product and technical authority: the reading order in `AGENTS.md` and
  `docs/documentation-index.md`

Resolve live field and option identifiers at execution time. Never embed a
remembered GitHub node or option ID in a mutation.

## Board fields

The project currently uses:

- `Status`
- `Blocked Reason`
- `Priority`
- `Target Version`
- `Delivery Stage`
- `Assignees`
- `Parent issue`
- `Sub-issues progress`
- `Linked pull requests`

If a required field is absent or renamed, stop before mutation and report the
schema mismatch.

## Status evidence

Follow this sequence:

`Backlog -> Open -> In Progress -> Code Review -> Dev Done -> QA -> Done`

Use `Blocked` only for an actual inability to progress.

- **Backlog:** Valid tracked work, but not yet selected or not ready.
- **Open:** Selected and ready; prerequisites and acceptance criteria are
  actionable.
- **In Progress:** A named work wave has started and repository or evidence work
  is actively underway.
- **Code Review:** Implementation and developer verification are complete and a
  reviewable artifact exists. If commit or pull-request publication is not
  authorized, keep the ticket `In Progress` and report that it is ready for the
  publication decision.
- **Dev Done:** The reviewed and verified pull request is merged.
- **QA:** Independent QA is authorized and has started, or repository evidence
  explicitly permits this transition.
- **Done:** Required QA or acceptance evidence is recorded and no required work
  remains.
- **Blocked:** A specific prerequisite, decision, permission, dependency, or
  environment prevents meaningful progress. Populate `Blocked Reason`.

When unblocking, clear `Blocked Reason` and restore the status justified by
current evidence. Do not skip intermediate states merely to make the board look
current.

## Adaptive route selection

Classify every new work wave before implementation. Create a complete assessment
from raw ticket and repository evidence, initialize its `current_route` to
`direct`, and invoke:

`scripts/Get-DeliveryExecutionRoute.ps1 -AssessmentPath <assessment.json>`

Select `direct` only when every positive fact is explicitly evidenced:

- The change category is `text_edit`, `small_line_change`, or
  `localized_reproducible_bug_fix`.
- Exactly one file is expected, the scope is localized, the criteria are clear,
  dependencies are resolved, the change is defined, verification is known, and
  rollback is known.
- A localized bug fix also has explicit reproducible-bug evidence.

Every hazard must be explicitly false. Route to `planned` when work is
multi-file, calculation-heavy, ambiguous, cross-component, behavior-sensitive,
security- or permissions-related, data-, persistence-, or migration-related,
networking- or concurrency-related, public-contract- or schema-related,
architecture-, build-, or release-related, or changes canonical meaning. Route
any unsupported change category to `planned` as well.

The classifier is fail-closed. Missing, null, or otherwise unconfirmed positive
evidence prevents a direct route. A true or unknown hazard prevents a direct
route. If the assessment is absent or malformed, the classifier rejects it; the
control plane must retain that failure evidence and use `planned`. Never infer a
direct route from an incomplete assessment or a classifier failure.

The route determines only whether the planning prefix runs:

- **Direct:** `worker -> verifier -> reviewer -> approver`.
- **Planned:** `analyst -> synthesizer -> worker -> verifier -> reviewer ->
  approver`.

Direct therefore skips only the analyst and synthesizer. It never skips the
fresh worker, verifier, reviewer, or approver. Both routes still require a fresh
integrator when substantive integration is needed, a fresh fixer for each
accepted finding set, a fresh adjudicator for material disagreement or
non-convergence, and fresh QA after merge when QA is authorized. Every
integration or fix is followed by new verifier and reviewer stages, and the
final candidate receives a fresh approver.

Route transitions are monotonic within a wave. Reassess a direct route whenever
scope, evidence, or risk changes; if any direct condition stops holding, promote
it to `planned` and run the missing planned stages before implementation
continues. A `planned` route is absorbing and must never downgrade to `direct`
within that wave.

Retain the original classifier assessment and the complete classifier result as
delivery evidence. The retained result includes the selected `route`, ordered
`reason_codes`, `normalized_evidence`, `previous_route`, `promotion_state`,
`direct_skipped_stages`, `required_downstream_stages`, and
`conditional_fresh_stages`. Route this evidence with the wave so later stages
can establish the route state without reconstructing or weakening it.

Adaptive routing changes no quality, isolation, evidence-integrity, publication,
or authority gate. Use the restricted launcher, snapshot and path attestations,
validated patches, fresh-context rules, independent verification and review,
approval, and QA requirements exactly as specified elsewhere in this contract.

## Ready-work ordering

Choose work using this order:

1. Exact tickets named by the user.
2. Reconciliation of active work that remains inside the current delivery gate
   or has a still-applicable recorded exception.
3. Readiness and evidence review of `Dev Done` or `QA` items that gate the next
   roadmap task. Actual QA transitions still require explicit authorization or
   recorded independent QA evidence.
4. `Open` actionable child issues whose prerequisites are evidenced.
5. `Backlog` child issues made ready by completed prerequisites.
6. Repository roadmap order.
7. Priority, then delivery stage and target version.

Epics coordinate outcomes; child issues deliver work. Do not start a later
stage because it is parallelizable when the roadmap gate forbids it.

An active branch or board item outside the current delivery gate is a
governance conflict, not automatic precedence. Continue it only when the
current request names it or a recorded exception is both still applicable and
compatible with canonical product and architecture rules. Otherwise ask the
user to choose between resumption and strict roadmap order.

## Parallelization rules

Safe by default:

- Multiple read-only analyses of different tickets.
- Repository exploration alongside live-board inspection.
- Independent review categories after a diff exists.
- Log or test-result analysis that does not mutate the shared environment.

Sequential by default:

- All issue and project-board mutations.
- Implementation in the shared worktree.
- Changes to shared configuration, canonical documentation, build graphs, or
  generated assets.
- A ticket and any ticket that depends on its result.
- Integration, final verification, Git publication, and status reconciliation.

Multiple implementation agents require all of:

- Disjoint file and system ownership.
- Read-only patch production with mechanically validated candidate artifacts.
- Independent verification.
- A named integration order and conflict owner.

When branch and worktree creation is explicitly authorized, use
`$manage-git-flow` to create a dedicated ticket branch from `develop`. Create a
registered worktree for each independently applicable parallel ticket or work
package, and record its resolved path, source commit, file ownership, and
integration order. Invoke the restricted stage launcher from within the
corresponding worktree so its repository-root and snapshot attestations bind to
that isolated checkout. Apply validated candidate patches serially within each
worktree; stage agents remain read-only and the main control plane alone owns
branch, worktree, index, and commit mutations.

Use a fresh integrator in the designated integration worktree when substantive
combination is required, followed by fresh verification and review. Do not
create an extra worktree for one shared-worktree package or a read-only audit.
Never remove a worktree or branch without explicit permission for the exact
resolved target.

## Fresh-context handoff

Use a new thread with no inherited conversation turns for every stage and every
loop iteration. Use only the allowlist for the receiving stage:

- **Analyst:** Exact ticket, board fields, repository state, canonical sources,
  and required output contract.
- **Synthesizer:** Canonical index paths, raw repository tree, and raw live-board
  export needed to independently discover and validate the complete source
  inventory. Include no analyst citations, source selection, omissions,
  verdicts, confidence, or recommendations.
- **Worker:** Every worker receives the exact common ticket and acceptance
  criteria, canonical sources, allowed paths, required checks, non-goals,
  baseline status, and baseline diff. The route then determines the remaining
  fields:
  - **Direct:** Set `execution_route` to `direct`, include exactly one nonblank
    `allowed_paths` entry, and include `classifier_evidence` as the exact
    retained, complete classifier result. Omit `work_package`; do not add a
    synthesized package or planning narrative.
  - **Planned:** Set `execution_route` to `planned` and include the synthesized
    `work_package`. Omission of `execution_route` is accepted only for legacy
    planned-handoff compatibility and is not normal control-plane output.

  If direct work expands beyond its classified scope or risk, stop the direct
  worker, reclassify from the retained `direct` route, run the missing analyst
  and synthesizer stages, and launch a new planned worker with their synthesized
  `work_package`. Do not continue the direct worker or retrofit that package
  into its handoff.
- **Integrator:** Candidate artifacts, neutral integration order, raw conflict
  locations, canonical sources, and allowed file scope.
- **Verifier:** Ticket, acceptance criteria, canonical sources, final candidate,
  test environment, commands, and raw launcher-produced command and test logs
  as normative neutral evidence. Include no prior findings, stage verdicts, or
  another stage's narrative.
- **Reviewer:** Ticket, acceptance criteria, canonical sources, source commit,
  complete pre-stage worktree status/diff, allowed paths, non-goals, final diff,
  artifact state, and raw command/log output. Include no verifier verdict,
  findings, or narrative conclusion.
- **Fixer:** Ticket, canonical sources, current candidate, allowed file scope,
  and the exact accepted artifact findings with raw evidence.
- **Approver:** Ticket, acceptance criteria, canonical sources, source commit,
  complete pre-stage worktree status/diff, allowed paths, non-goals, final
  artifact, and raw command/log output only. Include no prior findings,
  corrections, verdicts, confidence, severity, or resolution labels.
- **Adjudicator:** A neutral disputed question and raw governing evidence only.
  Include no agent identities, claims, verdicts, or preferred outcome.
- **QA:** Merged commit, acceptance criteria, canonical sources, target
  environment, QA procedure, and raw runtime evidence. Include no development
  verdicts or expected outcome.

Do not include hidden reasoning, persuasive summaries, the expected conclusion,
or another agent's confidence statement.

### Typed neutral-evidence records

Every field named by a blind stage's `neutral_evidence_fields` mapping is a
typed evidence envelope. Each record is a closed object with exactly these six
keys, with no extra or missing keys: `kind`, `provenance`, `encoding`, `source`,
`sha256`, and `content`. `kind` is exactly one of `text`, `command_log`,
`artifact`, `diff`, `status`, or `path_list`; `provenance` is exactly one of
`control_plane`, `repository`, `launcher`, `stage`, or `external`; and
`encoding` is exactly `utf8` or `base64`. A `single` mapping requires one
record, while an `array` mapping requires a nonempty array of records. `source`
must be a nonblank string, `sha256` must be lowercase 64-hex, and `content`
must be a string. The hash covers the strict UTF-8 bytes of `utf8` content or
the decoded bytes of canonical `base64` content.

Mapping values use `cardinality:kinds:provenances`, with alternatives separated
by `|`. The implemented blind-stage mappings are exactly:

- **Synthesizer:** `board_export` =
  `single:text:external|control_plane`; `repository_tree` =
  `single:text:repository`; `repository_state` =
  `single:status:repository|launcher`.
- **Integrator:** `candidate_artifacts` = `array:artifact:launcher`;
  `conflict_locations` = `single:text:control_plane`; `baseline_status` =
  `single:status:launcher`; `baseline_diff` = `single:diff:launcher`.
- **Verifier:** `candidate_artifact` = `single:artifact:launcher`;
  `raw_check_output` = `array:command_log:launcher`.
- **Reviewer:** `baseline_status` = `single:status:launcher`;
  `baseline_diff` = `single:diff:launcher`; `final_diff` =
  `single:diff:launcher`; `artifact_state` = `single:status:launcher`;
  `raw_check_output` = `array:command_log:launcher`.
- **Adjudicator:** `raw_evidence` =
  `array:text|command_log|artifact|diff|status:repository|launcher|control_plane|external`;
  optional `artifact_change_summary` = `single:status:launcher`.
- **Approver:** `baseline_status` = `single:status:launcher`; `baseline_diff` =
  `single:diff:launcher`; `final_artifact` = `single:artifact:launcher`;
  `raw_check_output` = `array:command_log:launcher`.
- **QA:** `raw_runtime_evidence` = `array:command_log:launcher|external`.

The handoff validator performs structural envelope validation before scanning
for prohibited blind-stage markers; the marker scan remains defense in depth.
After a record and its hash validate successfully, the recursive marker scan
skips only the `content` property of that exact mapped record, regardless of
whether its encoding is `utf8` or `base64`. It continues scanning the record's
metadata, including `source`, as well as ordinary handoff strings and every
non-record field. Opaque-content trust therefore rests on truthful provenance,
the stage-specific kind and provenance allowlists, the hash binding between the
record and its evidence, and treating the payload as data. This boundary does
not perform or claim semantic filtering of the payload.
Validation errors identify only the field and stable code and must not reveal
content or rejected values. The stable codes are
`neutral_evidence_record_required`, `neutral_evidence_array_required`,
`neutral_evidence_keys_invalid`, `neutral_evidence_kind_invalid`,
`neutral_evidence_provenance_invalid`, `neutral_evidence_encoding_invalid`,
`neutral_evidence_source_invalid`, `neutral_evidence_sha256_invalid`,
`neutral_evidence_content_invalid`, `neutral_evidence_base64_invalid`,
`neutral_evidence_hash_mismatch`, and
`neutral_evidence_field_contract_invalid`.

For local Git-state comparison only, the launcher decodes mapped
`baseline_status` and `baseline_diff` records. It preserves the original typed
envelopes in the validated handoff JSON supplied to the stage prompt.

Mechanically enforce the Worker handoff contract with:

- `references/handoff-schemas.json` for the stage allowlist and common required
  fields.
- `scripts/Validate-DeliveryWorkerHandoff.ps1` for route-specific Worker rules.
- `scripts/Validate-DeliveryHandoff.ps1` as the main validator that invokes the
  Worker helper.
- `scripts/tests/Test-DeliveryHandoffValidation.ps1` as the focused validation
  suite.

The main agent may reject incomplete evidence but must not substitute its own
implementation, verification, review, fix, or approval for a required fresh
stage. If a stage agent stalls or fails, spawn a different fresh agent with a
narrower handoff.

## Stage capability boundaries

Before spawning a stage:

- Remove mutation-capable GitHub, board, deployment, and external-system tools
  from every stage-agent tool surface.
- Make the repository read-only for analyst, synthesizer, verifier, reviewer,
  approver, adjudicator, and QA roles.
- Keep worker, integrator, and fixer roles read-only. Require each to return a
  complete unified diff as its structured artifact.
- Resolve the declared source commit and require it to equal the repository's
  current `HEAD`. Require the handoff workspace to equal the launcher's resolved
  repository root. Hash all tracked and non-ignored files before and after the
  stage and reject any mutation. If the inventory contains a sensitive path or
  traverses any reparse-point ancestor, fail closed without opening or hashing
  it. Capture Git inventory from the process's raw output stream and use
  NUL-delimited enumeration so tabs, newlines, quotes, and backslashes cannot
  disappear from the attested inventory.
- Record the raw baseline, parse proposed paths, reject unsafe or out-of-scope
  paths, and require `git apply --check` without modifying the worktree.
- Consume stage output only after the post-stage snapshot succeeds and confirms
  zero repository changes. A mutating stage may produce sealed failure evidence
  but no candidate patch.

If the current surface cannot enforce these capabilities, do not spawn the
stage with broader tools or permissions. Stop and request a restricted
environment or the explicit Git/file authority needed to create one.

Check effective runtime permissions because parent-turn overrides can supersede
custom-agent defaults. The project stage profiles disable apps, web search, and
inherited MCP servers, but those declarations are not sufficient when the
runtime surface ignores or overrides them. In that case, use a separately
restricted fresh Codex session rooted at the isolated snapshot or fail closed.

Use `scripts/Validate-DeliveryHandoff.ps1` and
`scripts/Invoke-DeliveryStage.ps1` as the default enforcement path. The launcher
must run ephemerally with user config ignored, apps/web/MCP disabled, explicit
sandbox and workspace root, schema-constrained output, and no approval
escalation. It must resolve the installed `codex` command itself and expose no
caller-selectable executable override. Retain its handoff hash, session ID when emitted, event log, output
artifact, resolved source commit, pre/post repository snapshot hashes, and path
audit as delivery evidence. Once child launch begins, the audit is failure-safe:
the launcher persists it before surfacing process errors, nonzero exits,
post-stage attestation errors, repository mutations, or out-of-scope changes,
so replacement stages never erase the failed attempt's scope evidence.
Rejected handoffs, source commits, workspace roots, profiles, or artifact
destinations are preflight validation results rather than stage attempts. Return
their exact error directly and do not consume the stage retry budget.

The handoff validator must read the handoff bytes once, parse and hash that same
buffer, and return the frozen JSON buffer to the launcher. Never reread the
handoff path when constructing the child prompt.

The launcher must keep output, event, and audit files in a dedicated artifact
root under the system temporary directory and outside the repository. Reject
filesystem or shared temporary roots, repository-contained roots, reparse-point
traversal, nested or escaping artifact targets, unsafe run identifiers, and any
target that already exists.

Before returning from a launched stage, create a separate evidence manifest
that binds the output JSON, event log, audit, and candidate patch by SHA-256 and
records the launcher-controlled `accepted` or `rejected` disposition. Mark every
bound artifact and the manifest read-only. Integrity sealing proves
authenticity, not acceptance. Use
`scripts/Test-DeliveryEvidence.ps1 -IntegrityOnly` only to inspect retained
failed-attempt evidence. Pre-disposition manifests may verify only in that mode
and report `legacy-unknown`; they are never routable. Later stages must run the
script without that switch, using independently retained expected manifest and
handoff hashes, before trusting or forwarding any artifact; normal verification
accepts only an `accepted` manifest.

For worker, integrator, and fixer outputs, persist the unified diff separately,
use Git's patch parser to enumerate proposed paths, reject traversal, absolute,
or out-of-scope paths, and require `git apply --check` against the attested
read-only snapshot. The control plane may then apply that exact validated patch as a
mechanical step when the user's request authorizes the change. A fresh verifier
and reviewer must judge the applied result; the control plane must not rewrite
the patch.

## Specialist contracts

### `delivery_analyst`

Return:

- Candidate issue and readiness decision.
- Explicit prerequisite evidence.
- Canonical documents consulted.
- Acceptance criteria and unresolved questions.
- Parallelization opportunities and conflicts.
- Recommended board action.

Do not change files or external state.

### `delivery_synthesizer`

Independently construct:

- A bounded objective and acceptance-criteria map.
- Explicit dependencies and non-goals.
- File or system ownership.
- Sequential and parallel boundaries.
- A test-first implementation plan and final verification plan.

Independently validate the source inventory from canonical indexes, the raw
repository tree, and the raw live-board export. Resolve no product decision by
assumption. Do not change files or external state.

### `delivery_worker`

Return:

- Outcome against each assigned acceptance criterion.
- Files changed.
- Exact checks run and results.
- Remaining risks, failures, or uncertainties.
- Suggested follow-up work.

Change only assigned repository scope. Do not mutate Git or GitHub state.

### `delivery_integrator`

Receive the independently produced artifacts, exact integration order,
canonical sources, and allowed file scope. Perform only substantive combination,
adaptation, or conflict resolution needed to produce one integrated candidate.
Return every integration decision and file changed.

Do not perform Git-state operations or external mutations. End after producing
the candidate so fresh verification and review can judge the integrated result.

### `delivery_verifier`

Independently reproduce the required behavior and execute applicable checks
when permitted. Independently judge raw launcher-produced command and test logs
as normative neutral evidence; never rely on another stage's narrative or
claimed result. A sandbox denial prevents the affected check from being rerun
in that stage, but does not erase valid raw evidence from an external launcher
execution.
Return:

- Each acceptance criterion as passed, failed, or not verifiable.
- Exact commands, environments, and results.
- Reproduction evidence for every failure.
- Missing or unreliable test coverage.

Do not rely on the implementer's claimed result or reasoning. Do not fix the
work or mutate Git or GitHub state.

### `delivery_reviewer`

Return findings ordered by severity, with file references and reproduction or
reasoning. Map findings to acceptance criteria and name missing verification.
State explicitly when no actionable finding is present.

Do not change files or external state.

### `delivery_fixer`

Receive one accepted finding set and the current repository artifact. Return:

- The root cause of each finding.
- The smallest coherent correction.
- Files changed and focused checks run.
- Any finding that remains unresolved and why.

Do not broaden scope, reuse the prior worker's conclusions, or mutate GitHub
state. End after one fix iteration so new independent gates can run.

### `delivery_approver`

Independently evaluate only the ticket, acceptance criteria, canonical sources,
final artifact, and raw command/log evidence. Return exactly one readiness
recommendation:

- **Approved:** Every required criterion and check has credible evidence and no
  actionable finding remains.
- **Rejected:** Name each unresolved criterion, failed check, or actionable
  finding with evidence.
- **Blocked:** Name the external decision, authority, dependency, or environment
  required.

Do not accept another agent's confidence as evidence. Do not edit files or
mutate external state.

### `delivery_adjudicator`

Independently resolve one material disagreement between stage evidence or
confirm whether a fix loop is objectively non-converging. Receive a neutral
disputed question plus raw sources, artifacts, commands, and logs without agent
claims, identities, verdicts, or preferred framing. Return the governing
evidence, decision, and next stage.

Do not edit files or mutate external state.

### `delivery_qa`

Independently validate the merged commit in the authorized target QA
environment. Return:

- QA procedure, environment, build/commit identifier, and raw evidence.
- Each QA criterion as passed, failed, or not verifiable.
- Reproduction evidence for every failure.
- Exactly what would be required before `Done`.

Do not rely on development-stage verdicts. Do not mutate Git, board state,
deployment configuration, target data, or external systems.

## Incident handling

Classify an occurrence before acting:

- **Transient tool call in a healthy stage:** Retry safely inside that stage.
- **Stalled or failed stage:** Abandon the attempt and spawn a different fresh
  agent with `fork_turns="none"`; never reuse the failed stage agent. After one
  same-cause replacement failure, escalate with evidence.
- **Invalid stage output:** Retain its rejected evidence and classify launcher
  `output_invalid` as an execution failure. Permit at most the one fresh
  replacement; never route the rejected candidate to a fixer or substantive
  patch-repair loop.
- **Implementation defect in scope:** Spawn a fresh `delivery_fixer`, then fresh
  verifier and reviewer agents. Never return it to the original worker or main
  agent for substantive correction.
- **Out-of-scope defect:** Record evidence and create a linked follow-up only
  when the scope is objective.
- **Product or architecture decision:** Stop and request the accountable user
  decision; preserve `TBD`.
- **Missing authority:** Stop the prohibited operation and report the exact
  permission needed.
- **External dependency unavailable:** Record evidence and block only when no
  meaningful in-scope work remains.
- **Non-converging wave:** Escalate when two consecutive fix/adjudication cycles
  do not reduce material findings, or an explicit session/user budget is
  exhausted. Never approve incomplete work because a budget ended.

Never expose secrets, credential output, private keys, `.env` contents, or
authentication material in issue comments, agent prompts, logs, or summaries.

## Efficiency, budgets, and model routing

Treat sealed stage telemetry as observation, not estimation. Each launched
stage records observed timing, session, and token values and uses explicit
nulls when a value is unavailable. The control plane aggregates these records
per stage for the wave and never fills missing usage with an estimate.

Optional limits belong in `execution_policy` only with explicit user-approved
provenance and approval time. Leave every unspecified limit null. Preflight
rejection does not consume an execution attempt. When an observed limit is
exceeded, persist the evidence before escalating. A budget may halt unfinished
work, but it cannot turn incomplete or failing work into approval.

Use capability labels as follows, without assigning model identifiers:

- **economy:** Deterministic control-plane validation or bounded extraction.
- **standard:** Routine substantive stages.
- **elevated:** Material security or correctness work, adjudication, or an
  evidenced failure of the standard route.

Independent verification, review, and approval may not be downgraded solely to
save tokens. Keep concrete model mappings unset until supported configuration
and representative evaluations justify them.

Parallelize independent read-heavy discovery and disjoint-path work. Serialize
tightly coupled code, schema, and test changes, integration, final gates,
publication, and board reconciliation. Use the fewest agents that provide real
independence because additional agents incur token and coordination costs.

For efficiency evaluations, first establish a representative baseline with the
quality-capable route. Optimize prompts, context, and routing, then compare the
same corpus in the same environment. Use quality criteria version
`issue-70-quality-v1` and run:

`scripts/Compare-DeliveryEfficiency.ps1 -BaselinePath <baseline.json> -CandidatePath <candidate.json>`

An `improved` result requires the same criteria version and environment,
measured tokens in both records, both records passing quality, and strictly
fewer candidate tokens. Quality passes only when mandatory checks,
attestations, acceptance evidence, and approval pass and unresolved material
findings equal zero. Otherwise report `quality_regression`, `not_measurable`,
or `not_improved` exactly as the comparator classifies the records. Adopt a
cheaper route only for `improved` and only when no independent gate is weakened.
Use references, hashes, and continuation artifacts instead of repeatedly
copying large narratives.
