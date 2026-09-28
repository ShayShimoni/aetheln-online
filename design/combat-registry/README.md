# Combat design registry, version 1

`schema.json` is the machine-readable vocabulary and policy for `registry.json`.
The PowerShell 5.1 compatible validator in
`scripts/design/Test-CombatRegistry.ps1` enforces its closed record shape and
cross-record invariants. A schema or registry format change must increment the
version and update the validator and tests together. `definitionVersion` is a
separate positive integer for each stable ID; references state an inclusive
compatible version interval. Changing a display name never changes an ID.
Each record has a short plain-text `summary`, a canonical `source` document,
and a checked `sourceAnchor` heading. The cited heading's own section body must
contain that record's exact stable ID; citing an unrelated or merely enclosing
heading fails. The summary is source-bound design description, not a second
authority or an approval to implement the rule.

This is design data subordinate to the canonical product and technical
documents named by each definition's `source`. Its maturity values are **not**
the Accepted/Candidate/Rejected status of an architecture decision. Maturity
means:

| Value | Meaning |
| --- | --- |
| Canonical Intent | The canonical behavior and compatibility boundary are stated; tuning and implementation evidence may still be open. |
| Prototype Candidate | The definition belongs to the explicitly approved, bounded prototype subset. This does not prove implementation or playtest results. |
| Evidence Validated | Owning evidence has validated the design for its declared scope; later work must attach that evidence before promoting a real record. |
| Implementation Ready | The definition has explicit finite root work and finite budgets, plus the required owning evidence and implementation review. |
| Superseded | A same-kind active definition replaces this ID. It cannot remain a dependency of active definitions. |

The registry contains the shared combat semantics, Oathscar, all four later
Order design shards, and the three learnable Heritage identities named in the
canonical documents. Only Health, Endurance, active Guard, Wrought, the
sword-and-shield discipline, its three-hit chain, and its three named active
abilities have Prototype Candidate maturity. The other 103 definitions remain
Canonical Intent. In particular, Oathbreak's spend, eligibility, grant
suppression, and refund behavior are not defined by this registry.
The nine approved Prototype Candidate IDs are pinned independently in the
validator. Editing the schema's allowlist alone cannot promote another record.
The validator requires syntactically bounded evidence declarations for promoted
records; it cannot independently establish that the linked evidence proves a
promotion. An independent reviewer must check that claim.

`references` are directed design dependencies with exact version bounds.
For `requiredReferenceKinds`, the listed kinds are **any-of**: at least one
reference must have one of the listed kinds. For example, an Oathscar Keystone
may reference a resource without also inventing an Order or ability dependency.
`emits` are directed possible proc descendants. Cycles in either relation fail
closed. Each `writes` claim names a semantic state slot and one authoritative
server owner; conflicting owners fail. For an executable proc chain, `work`
declares an upper bound per root activation for listener evaluations, proc
events, affected targets, and generated constructs, including delayed and
periodic descendants. The validator sums descendant upper bounds across every
branch and checks the root aggregate and maximum depth. Every emitted edge is
at most one occurrence per root under this format; a mechanic needing repeated
emissions must use a future versioned format and validator. These static caps
complement, but do not replace, server runtime counters and idempotency checks.

Executable combinations are manifest-only. A manifest's `composition` names
one root ability and every attached member, including Threads; its versioned
`references` must name exactly the same participants. Each attached Thread
declares at least one listener evaluation. The validator sums the root, every
member's full descendant work, and the manifest's own work under one root
budget; depth conservatively includes the root and the deepest member chain.
An Implementation Ready manifest requires an explicit composition with
Implementation Ready participants. Executable definitions with Implementation
Ready maturity must belong to at least one such manifest. Unlisted combinations
have no registry permission to execute, and a runtime consumer must enforce
that manifest identity rather than combining records ad hoc.

The initial budget limits are `TBD` with explicit owning issues. A definition
that declares nonzero root work cannot validate against an unresolved limit;
an emitted chain also requires a finite depth limit. Implementation Ready
requires all five finite limits and an explicit `work` declaration. No `TBD`
value is interpreted as a numeric limit or runtime permission. The initial
records make no executable budget claim.

Run the validator and focused tests from the repository root:

```powershell
powershell -NoProfile -File scripts/design/Test-CombatRegistry.ps1
powershell -NoProfile -File tests/design/Test-CombatRegistry.Tests.ps1
powershell -NoProfile -File tests/design/New-CombatRegistryAppendices.Tests.ps1
```

After reviewing a registry change, regenerate the two owned Markdown outputs:

```powershell
powershell -NoProfile -File scripts/design/New-CombatRegistryAppendices.ps1 -Write
```

That writes `docs/generated/combat-design-registry.md` and
`docs/generated/oathscar-codex-appendix.md`. The default invocation (or
`-Check`) is read-only and fails on byte drift:

```powershell
powershell -NoProfile -File scripts/design/New-CombatRegistryAppendices.ps1 -Check
```

`scripts/ci/Invoke-CiSuite.ps1` runs four required registry gates: the validator,
validator tests, generation tests, and generated drift check. These generated
documents remain subordinate to canonical sources. Nothing here is an Unreal
runtime asset, a tuning approval, or packaged evidence.
