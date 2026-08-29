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

Before launching normal planned scaffold work, the synthesizer identifies
natural disjoint full-file ownership boundaries. When those boundaries are
independently verifiable, it declares the complete fixed package set and
integration order before producer launch so one producer artifact is not the
only transport path. It must not partition by file count, bundle size, or
another hidden threshold; coupled changes remain sequential.

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
- Read-only structured-bundle production with mechanically generated and
  validated candidate artifacts.
- Independent verification.
- A named integration order and conflict owner.

When branch and worktree creation is explicitly authorized, use
`$manage-git-flow` to create a dedicated ticket branch from `develop`. Create a
registered worktree for each independently applicable parallel ticket or work
package, and record its resolved path, source commit, file ownership, and
integration order. Invoke the restricted stage launcher from within the
corresponding worktree so its repository-root and snapshot attestations bind to
that isolated checkout. Apply validated candidate patches serially within each
worktree with `scripts/Apply-DeliveryPatch.ps1`; stage agents remain read-only
and the main control plane alone owns branch, worktree, index, and commit
mutations.

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
  - **External-file consumer:** Also set `consumes_external_files` to the JSON
    boolean `true` and include `external_ingest_evidence` with exactly
    `evidence_manifest_path`, `evidence_manifest_sha256`,
    `external_manifest_path`, `external_manifest_sha256`,
    `prepared_journal_path`, `prepared_journal_sha256`, `source_commit`, and
    `target_root`.
    The evidence source commit must equal the handoff source commit and
    `target_root` must be `visuals`. Marker and evidence must appear together;
    `false`, partial, or unmarked evidence is invalid. The launcher verifies
    the read-only accepted evidence, external manifest, and prepared journal
    against their independently retained hashes and cross-links, plus the
    destination and current inventory, before child launch. It repeats that
    verification after the launch snapshot and immediately before child
    execution; the post-stage snapshot rejects concurrent mutation. Omit both
    fields for unrelated text-only workers.

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

### Required neutral-evidence composition preflight

Every verifier and approver launch requires one independently authoritative,
out-of-band manifest. `delivery_authoritative_evidence_manifest_v1` is a closed
object with exactly `format`, `stage`, and `records`. `format` is the literal
`delivery_authoritative_evidence_manifest_v1`; `stage` is exactly `verifier` or
`approver` and must match the routed stage; and `records` is a nonempty array.
Each record is closed with exactly these six members: `field`, `kind`,
`provenance`, `encoding`, `source`, and `sha256`. `field` names a mapped neutral-
evidence handoff field, `kind` and `provenance` must be permitted by that field,
`encoding` is `utf8` or `base64`, `source` is nonblank, and `sha256` is lowercase
64-hex. The manifest intentionally contains no evidence content.

The manifest contains exactly one record for every neutral-evidence record the
stage requires. Every required raw Linux check log for a verifier or approver
is an independent manifest record with `field: raw_check_output`,
`kind: command_log`, and `provenance: launcher`. Its handoff declaration and
routed envelope must carry those same values. A repository-provenance record,
Windows output, the `commands` field, command text, combined output, or a
narrative cannot satisfy or replace that Linux source.

The only public path input is
`Invoke-DeliveryStage.ps1 -AuthoritativeEvidenceManifestPath <path>
-AuthoritativeEvidenceManifestSha256 <sha256>`. The control plane supplies both
arguments outside the handoff and retains the expected hash independently. The
launcher reads the manifest bytes exactly once, verifies the expected hash,
and freezes those exact bytes before it reads or validates the handoff. Its
validator call is
`Validate-DeliveryHandoff.ps1 -AuthoritativeEvidenceManifestBytes <bytes>
-ExpectedAuthoritativeEvidenceManifestSha256 <sha256>`. Only the launcher may
supply that validator input. The validator must not accept a manifest path,
reread the source, reconstruct authority from canonical stage schema, or use a
manifest, inventory, encoding, or hash copied from the handoff as authority.

Before ordinary object materialization, inspect the frozen JSON bytes for
member duplication. Reject any duplicate member in the manifest root or a
manifest record. In the handoff, reject any duplicate member that can affect
`stage`, `required_evidence_sources`, or a mapped neutral-evidence field,
including duplicate members inside a declaration or routed record. This check
must occur before a parser can collapse duplicate members with first- or last-
value semantics.

After freezing both inputs, and before Codex command resolution or child
launch, validate the complete composition once. Treat the case-sensitive pair
`field` and `source` as the record identity. Require a bijection in which each
identity occurs exactly once in the frozen manifest, exactly once in the
handoff `required_evidence_sources` declarations, and exactly once in the
mapped routed records; reject missing and extra entries in every set. A routed
record's `field` is its containing mapped handoff field. Require `field`,
`kind`, `provenance`, `encoding`, `source`, and `sha256` to match the manifest
exactly, validate the mapped field's shape and cardinality, decode its content
according to the declared encoding, and recompute the routed content SHA-256.
Never infer, synthesize, merge, normalize, repair, or substitute evidence.
Changing a source, provenance, encoding, or hash is a mismatch, not a new valid
record.

The stable sanitized preflight codes are:

- `authoritative_evidence_manifest_required` for a missing, null, or empty path,
  expected hash, manifest, or record array.
- `authoritative_evidence_manifest_hash_mismatch` when the frozen bytes do not
  match the independently retained hash.
- `authoritative_evidence_manifest_malformed` for invalid JSON, root shape,
  stage, record shape, or record value.
- `required_evidence_json_member_duplicate` for any relevant duplicate JSON
  member described above.
- `authoritative_evidence_source_duplicate` for a repeated manifest identity.
- `required_evidence_declarations_malformed` or
  `required_evidence_declaration_duplicate` for missing, null, empty, malformed,
  extra, or duplicate handoff declarations.
- `required_evidence_routed_record_malformed` or
  `required_evidence_routed_record_duplicate` for missing, null, empty,
  malformed, extra, or duplicate mapped routed records. Existing typed-envelope
  shape, encoding, and content-hash codes remain valid members of this retry-
  neutral family.
- `required_evidence_composition_mismatch` for a missing, substituted, or
  mismatched identity or any disagreement in the six authoritative values,
  mapped cardinality, decoded encoding, or recomputed content hash.

Every code in this family is a retry-neutral preflight defect. Emit exactly one
closed sanitized result with only `phase`, `code`, `field`, `child_launched`,
and `attempt_consumed`. `phase` is `preflight`; `field` is only the affected
schema field (or `authoritative_evidence_manifest` for manifest-level defects);
and both booleans are `false`. Never return rejected content, paths, source
identities, encodings, hashes, duplicate values, or nested parser errors. The
rejection does not launch a child, consume an attempt, advance its ordinal, or
reduce the replacement budget.

Once the child has actually launched, process, output, attestation, mutation,
candidate, and applicability failures remain launched-stage execution failures.
Retain their sealed evidence and preserve the existing bound of the initial
attempt plus one fresh replacement.

### External-file ingest and composite candidates

The external-file path is a control-plane exception for frozen
user-provided artifacts; it does not widen `delivery_file_bundle_v1`.
`delivery_external_file_bundle_v1` is a closed object with exactly `format`,
`target_root`, and `files`. The target is the literal absent repository root
`visuals`. The array contains 1-128 records with exactly `path`, `operation`,
`size`, and `sha256`; operation is `create`, size is a nonnegative JSON
integer no greater than 9223372036854775807, and the hash is lowercase SHA-256.
Paths are slash-normalized and relative to both the standalone source root and
target root. V1 accepts only
the case-sensitive extensions `.png`, `.svg`, `.ps1`, `.md`, and `.json`, and
limits each path to 240 characters.
The external schema root uses `oneOf` to select the bundle, journal, or accepted
evidence contract; a definitions-only schema is not routable.

Use `scripts/New-DeliveryExternalFileBundle.ps1` with the explicit repository
root to produce deterministic compact UTF-8 manifest bytes. The writer rejects
repository- or source-contained output before file creation. The manifest has
no self digest; retain its exact-byte SHA-256 independently. Contract JSON is
limited to 1 MiB and 16 levels of nesting. Keep the external manifest outside
the source, staging, and repository roots. The importer rejects rooted or
traversing paths, unsafe or reserved names, trailing dots/spaces, colons and
alternate streams, case/Unicode-normalization collisions, reparse points,
unsupported extensions, unexpected files or directories, byte/hash drift, an
existing destination, overlapping roots, and cross-volume staging.

`scripts/Invoke-DeliveryExternalFileIngest.ps1` copies only declared regular
default streams into a new non-reparse staging payload outside the repository
and on its volume. It verifies source and staging, persists and flushes the
closed read-only `delivery_external_file_ingest_journal_v1`, revalidates
source/staging/target and repository `HEAD`, then uses one same-volume directory
move to create the absent destination. The caller-provided source commit must
equal `HEAD` before preparation, immediately before that move, immediately
after it, and before evidence publication. Prepare sealed evidence bytes at a
non-routable pending path, make the final `HEAD` decision, then atomically
revalidate the complete destination, and atomically publish the accepted
evidence as the commit point. Drift detected before publication returns
`ingest_evidence_incomplete` with no routable evidence. Accepted
`delivery_external_file_ingest_evidence_v1` binds the external manifest bytes,
journal hash, source commit, final inventory, changed paths, and file records.

Every pre-move failure leaves the repository unchanged. Every post-move
verification or evidence-sealing failure returns
`ingest_evidence_incomplete`; it must not roll back, repair, rewrite, or delete
the imported tree. Reconcile only with
`scripts/Confirm-DeliveryExternalFileIngest.ps1`, the immutable prepared
journal, and its independently retained expected hash. Reconciliation is
repository-read-only and may only create accepted evidence outside the
repository when the destination is exact. If failure left the deterministic
evidence bytes at the final evidence path before read-only sealing completed,
reconciliation may seal that exact file in place; it rejects any differing
pre-existing file.

The atomic boundary is the same-volume directory rename, not a transaction
with every process running as the same local Windows principal. Revalidate the
complete staging inventory after all planned pre-move work and verify the
destination immediately after the rename. A same-principal concurrent mutation
that lands after the last staging read may therefore create only an
`ingest_evidence_incomplete` destination; it must never seal accepted evidence
or allow an external-consuming worker to launch. Persistent ACL changes or
rollback are not permitted as substitutes because they would make the retained
tree non-exact or violate non-repairing recovery.

Normal ingest and reconciliation both prepare evidence at a non-routable path,
then recheck `HEAD` and the complete destination immediately before atomic
publication. The remaining same-principal check-to-rename instruction boundary
is not claimed to be transactional; every external-consuming worker reopens
the manifest, journal, evidence, `HEAD`, and destination inventory immediately
before launch, and the launcher rejects concurrent repository mutation.

Inventory hashes cover ordinal-sorted records encoded as normalized path,
NUL, invariant decimal byte length, NUL, lowercase SHA-256, and LF, all in
UTF-8. New journal, evidence, and composite JSON use deterministic compact
UTF-8 without BOM or trailing newline, are create-only, and must pass the same
1 MiB and 16-level limits before any file is created. Prospective accepted
evidence is serialized and checked before staging or repository mutation.

After accepted external ingest and accepted text-patch evidence are present,
`scripts/New-DeliveryCompositeCandidate.ps1` creates exactly:
`format`, `source_commit`, `external_ingest_evidence_sha256`,
`text_patch_evidence_sha256`, `final_inventory_sha256`, and `changed_paths`.
The format is `delivery_composite_candidate_v1`; both evidence hashes bind
exact accepted evidence-manifest bytes, and changed paths are the complete
unique ordinal-sorted artifact union. The composite contains no binary content
or stage judgment. Extract text-patch paths with Git's NUL-delimited patch
parser so quoted or Unicode paths cannot be misread, and revalidate both
accepted evidence sets immediately before sealing. External revalidation opens
the accepted evidence, frozen external manifest, and prepared journal using
their independently retained hashes. Validate the exact text-patch handoff and
require its source commit to equal the composite source commit. Reject
repository-contained handoff, evidence, patch, and composite output paths.
Hash the complete candidate inventory—the exact union named by
`changed_paths`—initially, again immediately before sealing, and again after
sealing; any difference fails without returning an accepted candidate.
Composite validation likewise compares two complete changed-path inventory
passes and rereads the sealed candidate before returning success. Unrelated
repository paths are intentionally outside this artifact hash; the launcher's
whole-repository pre/post snapshots reject their concurrent mutation.
Supply the sealed composite bytes in the verifier
`candidate_artifact`, approver `final_artifact`, and reviewer artifact-state
evidence with the complete diff and inventory. Binding two accepted mechanical
artifacts does not require an integrator unless substantive conflicts exist.

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
  complete `delivery_file_bundle_v1` full-file structured artifact.
- For worker, integrator, and fixer only, disable the default shell and expose
  exactly one required launcher-owned MCP tool named
  `read_allowed_source_file`. It accepts one exact allowed repository-relative
  path and returns complete attested source bytes plus the launcher-owned base
  hash. Disable web, apps, inherited MCP, directory listing, arbitrary reads,
  producer hashing, commands, and writes. Non-producer stages receive no source
  inspection server.
- Resolve the declared source commit and require it to equal the repository's
  current `HEAD`. Require the handoff workspace to equal the launcher's resolved
  repository root. Hash all tracked and non-ignored files before and after the
  stage and reject any mutation. If the inventory contains a sensitive path or
  traverses any reparse-point ancestor, fail closed without opening or hashing
  it. Capture Git inventory from the process's raw output stream and use
  NUL-delimited enumeration so tabs, newlines, quotes, and backslashes cannot
  disappear from the attested inventory.
- Record the raw baseline, validate the producer bundle against it,
  mechanically generate the candidate patch, parse proposed paths, reject
  unsafe or out-of-scope paths, and require strict `git apply --check` without
  modifying the worktree.
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

For worker, integrator, and fixer outputs, the structured artifact is a closed
object with `format` exactly `delivery_file_bundle_v1` and a `files` array with
one complete resulting-file record per changed path. Each record has exactly
`path`, `operation`, `base_sha256`, `encoding`, and `content`. The normalized
repository-relative `path` must be unique, match the stage's declared
`changed_paths`, and remain inside `allowed_paths`. `operation` is only
`create` or `replace`: a create requires an absent source-snapshot path and
null `base_sha256`; a replace requires an existing source-snapshot file and
the exact lowercase SHA-256 of its original bytes. `encoding` is `utf8` for
complete resulting text or `base64` for complete resulting binary bytes, and
`content` always contains the full result. Delete, rename, copy, partial-file,
and hand-authored patch operations are prohibited.

Consume the bundle only after post-stage zero-mutation attestation. Validate
its closed shape, paths, operation preconditions, base hashes, encodings, and
complete contents against the attested snapshot. Then have the launcher
mechanically generate the candidate patch as a separately bound artifact. Use
Git's strict patch parser to enumerate proposed paths, reject traversal,
absolute, sensitive, or out-of-scope paths, and require strict
`git apply --check` against that same snapshot. Emit `base64` bundle records as
Git binary patch records and `utf8` records through Git's text patch route;
both declare complete resulting bytes. Validation and application must use the
provided scripts. Applicability checking and `scripts/Apply-DeliveryPatch.ps1`
each use a unique isolated temporary repository whose proposed paths neutralize
text, EOL, filter, ident, and working-tree encoding attributes. Application
writes and verifies those exact bytes through reparse-checked destinations.
Neither step may change repository or global Git configuration. The control
plane may apply
only that exact validated patch with this script when the user's request
authorizes the change. A fresh verifier and reviewer must judge the applied
result; the control plane must not infer, rewrite, or repair bundle content or
generated patch bytes. Any rejected output, bundle, or candidate patch is
sealed audit evidence only and is never routable to a substantive stage.

### Verified Codex configuration facts (2026-08-29)

A fresh official manual check verified the exact Codex configuration keys this
producer boundary relies on:

- `features.shell_tool = false` disables the child's default shell tool.
- A stdio `mcp_servers.<id>` entry supports `command`, `args`,
  `required = true`, and `enabled_tools`.
- `web_search = "disabled"` disables web search.
- `--strict-config` rejects unknown configuration keys.

Sources: <https://learn.chatgpt.com/docs/config-file/config-reference> and
<https://learn.chatgpt.com/docs/mcp>.

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
  patch-repair loop. Only the bounded transport-only recovery below may follow
  two purely malformed or non-applying patch-transport failures.
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

### Bounded transport-only recovery

An unchanged planned work package normally closes after its initial producer
attempt and one fresh replacement. The control plane may open exactly one
transport-only recovery generation only when both attempts:

- returned child status `passed`;
- were rejected solely because the launcher found malformed or non-applying
  candidate-patch transport, recorded as `ArtifactFailureKind`
  `patch_malformed` or `patch_nonapplying`;
- left the source and post-stage repository snapshots identical;
- preserved the original allowed scope, authority, and product or architecture
  decisions; and
- produced no unsafe-path, out-of-scope, mutation, tamper, or other
  non-transport signal.

A fresh adjudicator must confirm every prerequisite from raw governing
evidence. If confirmed, run a fresh planned synthesis from the original raw
ticket, canonical sources, source snapshot, allowed path set, and normative
producer contract. That synthesis fixes a finite set of nonempty packages whose
path sets are pairwise disjoint and whose union is an exact cover of the
original allowed path set; then launch fresh producers for those packages.

Rejected output bytes, bundle bytes, generated patch bytes, producer
narratives, and proposed repairs remain sealed audit-only evidence and must not
be passed to the adjudicator, synthesizer, or replacement producers. The fixed
decomposition cannot be repartitioned, retried as another recovery generation,
or used to repair a rejected artifact. Any recovery-generation failure
escalates with evidence.

This recovery is a one-time subroute inside the existing `planned` route. It is
not a third adaptive execution route, does not change route classification, and
must never be chosen from file count, bundle size, estimated complexity, or any
other heuristic.

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
