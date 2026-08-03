---
name: coordinator-delivery
description: "Coordinate repository delivery from the GitHub project board with Claude Code: select ready issues, resolve dependencies, plan safe work waves, delegate bounded work to fresh-context stage subagents, independently verify outcomes, create objective follow-up issues, and synchronize issue and board state. Use when the user asks Claude to run, resume, coordinate, or monitor a delivery wave; work the board; choose the next ready ticket; delegate multi-ticket work; or manage delivery end to end. In this repository, also trigger for the shorthand commands next, next wave, resume, continue, audit, status, work #123, or issue #123."
---

# Coordinator Delivery

This is the Claude Code counterpart of the Codex skill
`.agents/skills/orchestrate-delivery`. Both skills implement the same
governance. The shared operating contract and the shared mechanical scripts are
the single source of truth; this file defines only what is Claude-specific.

Read
[.agents/skills/orchestrate-delivery/references/operating-contract.md](../../../.agents/skills/orchestrate-delivery/references/operating-contract.md)
before planning or delegating a work wave. Where that contract or the Codex
skill names a Codex-only mechanism, apply the Claude adaptation defined below.
Every other rule — sources of truth, board fields, status evidence, adaptive
route selection, ready-work ordering, parallelization, fresh-context handoff
allowlists, specialist contracts, incident handling, and budgets — applies
verbatim.

Keep the main agent as the control plane. The main agent owns authoritative
input collection, user communication, scheduling, board and issue mutations,
Git decisions, mechanical integration coordination, independence enforcement,
and faithful evidence routing. Require fresh stage agents to make substantive
readiness, dependency, scope, planning, implementation, verification, review,
fix, adjudication, and approval judgments. Never let the main agent rewrite a
stage judgment, make substantive artifact changes, or delegate board or Git
mutations to a stage agent.

## Run modes

Derive one mode from the request:

- **Next wave:** Inspect the board and choose the next objectively ready,
  actionable ticket or compatible set of tickets.
- **Targeted:** Deliver the exact issue or issues named by the user.
- **Resume:** Reconcile active board items, the current worktree, pull
  requests, and any available agent results before continuing.
- **Audit:** Inspect and recommend only. Do not mutate issues, the board, or
  the repository.

An alias grants only the corresponding run mode; it grants no additional Git or
publication authority. When the user asks to run, deliver, manage, or resume a
wave, treat scoped issue comments, status updates, `Blocked Reason` updates,
and objective follow-up issues as authorized coordination work. Never infer
authorization to commit, push, publish a pull request, merge, pull, change
branches, deploy, delete, or migrate.

## Ground truth

1. Read the root `AGENTS.md`, relevant repository documentation, and the exact
   issue bodies, acceptance criteria, links, parent/sub-issues, and board
   fields.
2. Inspect the branch, worktree status, diff, remotes, and upstream
   relationship before any repository mutation. Preserve unrelated user
   changes.
3. Inspect the live GitHub project with authenticated `gh`; never rely on
   remembered field or option IDs.
4. Inspect open pull requests, checks, review state, and existing verification
   evidence for active work.

If a ticket, dependency, acceptance criterion, product decision, or required
board field cannot be discovered and the choice would affect delivery, stop and
ask the user. Preserve explicit `TBD` decisions.

## Execution route

Classify every wave with the shared classifier before implementation. Build a
complete assessment JSON from raw ticket and repository evidence with
`current_route` initialized to `direct`, then run:

```
.agents/skills/orchestrate-delivery/scripts/Get-DeliveryExecutionRoute.ps1 -AssessmentPath <assessment.json>
```

Follow the contract's direct/planned rules exactly: `direct` only for a fully
evidenced one-file localized change with every hazard explicitly false;
everything else, and every classifier failure or malformed assessment, is
`planned`. Routes are monotonic within a wave. Retain the assessment and the
complete classifier result as wave evidence.

- **Direct:** worker → verifier → reviewer → approver.
- **Planned:** analyst → synthesizer → worker → verifier → reviewer → approver.

Both routes require a fresh integrator for substantive integration, a fresh
fixer per accepted finding set, fresh verifier and reviewer passes after every
integration or fix, a fresh adjudicator for material disagreement or
non-convergence, and fresh QA after merge when QA is authorized.

## Claude stage launch procedure

Claude Code has no ephemeral-process stage launcher. The equivalent mechanical
gates are enforced by the control plane around every stage spawn. This
procedure replaces `Invoke-DeliveryStage.ps1`; everything it cannot replicate
is listed under "Honest limits" and must not be claimed.

Launch every substantive stage as follows:

1. **Build the handoff** according to the contract's stage allowlist. Give the
   stage only the minimum evidence for its role: raw artifacts, exact file
   paths, ticket text, commands, and logs. Never include earlier conclusions,
   verdicts, severity, confidence, resolution labels, expected answers, or
   another agent's narrative or reasoning.
2. **Snapshot before launch.** Run
   `.agents/skills/orchestrate-delivery/scripts/Get-DeliveryRepositorySnapshot.ps1
   -RepositoryRoot <repo>` and record the hash. Record the current `HEAD` and
   require the declared source commit to equal it.
3. **Spawn the stage** with the Agent tool using the matching project agent
   type (`delivery-analyst`, `delivery-synthesizer`, `delivery-worker`,
   `delivery-integrator`, `delivery-verifier`, `delivery-reviewer`,
   `delivery-fixer`, `delivery-adjudicator`, `delivery-approver`,
   `delivery-qa`). Each spawn is a fresh context with no inherited turns.
   Never reuse an agent for a later stage, a fix iteration, re-verification,
   re-review, or re-approval.
4. **Snapshot after return.** Rerun the snapshot script and compare hashes.
   If the repository changed during a stage, reject that stage's entire
   output, retain the evidence, and treat it as a failed attempt. A mutating
   stage may produce sealed failure evidence only.
5. **Convert and validate producer output.** Worker, integrator, and fixer
   agents return a `delivery_file_bundle_v1` artifact (closed object, full-file
   records with exactly `path`, `operation`, `base_sha256`, `encoding`,
   `content`; `create`/`replace` only). Only after zero-mutation attestation,
   mechanically convert it with
   `Convert-DeliveryFileBundleToPatch.ps1`, validate with
   `Validate-DeliveryPatch.ps1` (path scope, sensitive paths, strict
   `git apply --check`), and apply only with `Apply-DeliveryPatch.ps1`, and
   only when the user's request authorizes the repository change. Never
   hand-edit, infer, rewrite, or repair bundle or patch bytes. A rejected
   bundle or patch is audit evidence only and is never routable to a later
   substantive stage.
6. **Record evidence.** For each stage retain: the handoff content, the agent
   type, pre/post snapshot hashes, source commit, the returned artifact, and
   the accept/reject disposition. Keep evidence files outside the repository
   in the session scratchpad.

Retry rules follow the contract: one initial attempt plus one fresh
replacement for the same tool or execution failure, then escalate. Preflight
rejections consume no attempt. Apply the bounded transport-only recovery
exactly as the contract defines it.

## Stage capability boundaries

The project stage agents in `.claude/agents/` are restricted to read and
inspection tools; they have no Write, Edit, web, or MCP mutation surface.
Enforce in addition:

- Producer stages author changes only as `delivery_file_bundle_v1` output.
  They never edit the worktree; the pre/post snapshot comparison mechanically
  rejects any stage that does.
- Stage agents never mutate Git state, GitHub issues, project fields,
  comments, pull requests, branches, commits, deployments, or external
  systems. All such mutations are executed by the main agent only, under the
  user's authority.
- Give each stage a bounded prompt: exact issue URL and objective,
  authoritative documents, allowed paths or investigation scope, explicit
  non-goals, required checks, and a concise return contract.
- Use no more than three concurrent stage agents, and only for work that is
  independent, bounded, and independently verifiable per the contract's
  parallelization rules.

## Honest limits

State these plainly when reporting; never imply Codex-launcher-equivalent
guarantees:

- Stage isolation rests on restricted agent tool surfaces plus pre/post
  snapshot attestation, not on an OS-level read-only sandbox.
- Evidence records are retained files with recorded hashes, not read-only
  sealed manifests produced by an independent launcher process.
- Handoff discipline follows the contract's allowlists but is not enforced by
  a schema validator; the control plane must apply the allowlists manually
  and conservatively.

If a wave requires guarantees this surface cannot provide (for example a
user-mandated sealed audit chain), stop and recommend running that wave
through the Codex `orchestrate-delivery` skill instead.

## Wave execution, blockers, and finish

Follow the operating contract for wave presentation, board movement, blocker
handling, follow-up issue creation, and final reporting. Before ending a run:
reconcile worktree, issues, pull requests, checks, and board status; record
the classifier evidence, stages run, distinct fresh agents used, exact
verification performed, and remaining follow-ups or blockers; leave unfinished
work accurately active or blocked with a concrete continuation note.

Do not claim continuous background monitoring. This skill coordinates one
invoked wave; use a new invocation to resume.
