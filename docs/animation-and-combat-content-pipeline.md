# Animation and Combat-Content Authoring Pipeline

## Document Status

This is the specification for
[Issue #84](https://github.com/ShayShimoni/aetheln-online/issues/84): how
attacks, defensive windows, telegraphs, authored volumes, and their
presentation are authored, imported, validated, and bound together while the
server-owned combat timeline stays the only gameplay truth. It is phase P1 of
the issue and contains no code. Later phases are listed in
[Phased Delivery](#phased-delivery).

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
TA-002, TA-003, TA-004, and TA-019 in
[Architecture Decisions](architecture-decisions.md), and the canonical product
documents, and it changes no product rule. It builds on the step data layout
that [Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md)
(#60) hands to this issue, and on the intake contract in
[Asset Intake and Content Validation](asset-intake-and-content-validation.md)
(#120). It records the owner's animation-sourcing decision of 2026-10-11
(see [Animation Sourcing](#animation-sourcing-retargeting-and-intake)).

Every timing, range, shape, damage, cost, cooldown, and readability value
stays `TBD`. #107 closed without timing values: phase timings and other tuning
stay `TBD` (`docs/characters-and-factions.md:324-327`), and
`design/combat-registry/registry.json` carries none. Values arrive only through an owner or tuning decision and the
#45 budgets. Oathscar, Gate Step, Sworn Rebuke, Hold the Line, Endurance, and
Guard are working names. C++ and asset names below are proposed names.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `d950ac92`.

## Decisions at a Glance

1. **Data first, animation fitted.** The authoritative attack definition is
   authored first. Animation is retimed to fit its windows, never the other
   way round. Replacing an animation never changes gameplay or the content
   version.
2. **Two assets, one direction.** An authoritative attack definition and a
   client-only presentation binding are separate. The binding refers to the
   definition by ability ID and content version; the definition never refers
   to presentation. Presentation therefore cannot reach the server cook or
   change a server result.
3. **No animation path into gameplay.** No montage, notify, socket, trail,
   sound, Niagara system, camera shake, or `GameplayCue` opens a window,
   creates a contact, applies damage or a cost, starts a cooldown, or writes
   persistence. This is already enforced in code and is pinned by tests (see
   [Presentation Cannot Create Truth](#presentation-cannot-create-truth)).
4. **Validation before runtime.** Each authoring error named by the issue has
   one gate that fails closed before a server uses the data (see
   [Authoring Validation](#authoring-validation)).
5. **Epic baseline, governed intake.** Prototype animation starts from Epic's
   mannequin and Game Animation Sample content, retargeted with the IK
   Retargeter, and enters through #120 intake. Generated motion belongs to
   Codex. The owner approves final feel.
6. **Existing source-control policy.** Animation sources and packages use the
   #14 LFS and locking matrix unchanged. A new binary format needs a
   reviewed matrix change first.

## Scope and Owners

#84 owns the authoring contract: the definition and binding split, the
authoring flow, the validation matrix, and the ownership boundaries. It does
not own the systems the content runs on.

| Owner | Provides to #84 | #84 does not do |
| --- | --- | --- |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | The step definition, grant validation, timeline driver, contact pipeline, `CombatActivation` record, and observer phase state | Change the timeline, contacts, or record |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | The dodge and block windows and the defense slot | Change defense rules |
| [#83](https://github.com/ShayShimoni/aetheln-online/issues/83) | The server-owned enemy controller, its `Telegraph` state before a step, and `FAethelnEnemyPresentationState`, which replicates that state and the step's timing to clients (`docs/enemy-ai-and-navigation.md`, landing with #83) | Enemy states, telegraph timing, or replication |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Enemy intent, enemy steps registered on the timeline, and the enemy telegraph content | Enemy behavior or target choice |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61), [#97](https://github.com/ShayShimoni/aetheln-online/issues/97) | HUD, `GameplayCue.*` tags, readable feedback, and the readability review | Visual language or UI timing |
| [#120](https://github.com/ShayShimoni/aetheln-online/issues/120) | Intake records, lifecycle, stable IDs, audiences, and the content validator families | Change the intake contract |
| [#14](https://github.com/ShayShimoni/aetheln-online/issues/14) | The LFS and locking matrix in [Source Control](source-control.md) | Add LFS patterns |
| [#106](https://github.com/ShayShimoni/aetheln-online/issues/106), [#107](https://github.com/ShayShimoni/aetheln-online/issues/107) | Stable semantic IDs and the Oathscar shard | Invent tuning |
| [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Network profiles and budgets | Choose latency, frame, or animation budgets |
| [#201](https://github.com/ShayShimoni/aetheln-online/issues/201) (TA-019) | The private `AethelnArt` plugin for licensed content | Change where licensed art lives |
| Codex (`owner: codex`) | Generated motion, if Codex has a suitable tool | Generate assets |
| Owner | Final animation feel and any third-party download or licence acceptance | Approve feel or accept terms |

## Pipeline Overview

Each stage has one owner and one output. A stage may not start until the
previous stage's output exists and is recorded.

| Stage | Owner and tool | Output | Gate |
| --- | --- | --- | --- |
| 1. Authoritative definition | Combat design, data files (see [Storage form](#storage-form)) | Step definitions with stable ID and content version; values `TBD` until decided | Grant validation and the definition validator |
| 2. Source | Owner download (Fab, Epic templates) or Codex generation | Source files outside `Content/` | Intake record started under #120 |
| 3. Intake | Lead or delegated lane, #120 records | Source, licence, modification, hash, reviewer, and lifecycle state | #120 lifecycle gate; no record, no import |
| 4. Rig and retarget | Unreal IK Rig and IK Retargeter; Blender MCP for rig help and cleanup only | `IK_` rigs, `RTG_` retargeters, retargeted sequences | `skeletal_animation` family |
| 5. Cleanup and trim | Blender MCP scripts (rerunnable, recorded) | Cleaned source and export preset | Same hash and preset recorded on reimport |
| 6. Import | Unreal Editor | Animation sequences on the target skeleton | Intake registry entry and content validator |
| 7. Montage and notifies | Animation author | `AM_` montages with step sections and presentation-only notifies | Presentation binding validator |
| 8. Binding | Animation author | Client-only presentation binding naming ability ID, content version, step, montage, sections, sockets, and effects | Presentation binding validator |
| 9. Review | Owner for feel; #97 for readability | Recorded approval or rejection | Not a gameplay gate: gameplay works without it |

Stages 2 to 9 never feed back into stage 1. If an animation does not fit the
authored windows, the animation is retimed or replaced. A change to the
windows is a design decision that bumps the content version and goes through
stage 1 again.

## Authoritative Attack Data Contract

### Fields

The authoritative contract is the #60 step definition
(`Source/GameCombat/Public/AethelnAttackTypes.h:102-127`) plus the
ability-level fields of the #19 base ability. #84 adds no field and no value.

| Concern (issue wording) | Owned by | Field or rule |
| --- | --- | --- |
| Phases | Step definition | `ActiveStart`, `ActiveEnd`, `BufferOpen`, `LinkOpen`, `LinkClose`, `RecoveryEnd`, `CancelOpen` as offsets from the authoritative start |
| Authored volumes | Step definition; ability | Step: `Shape`, `ShapeExtent`, `PathStart`, `PathEnd` in the combat frame, `MaxAimPitchDegrees`. Ability: the sampling budget (`ProvisionalMaxSampleAngleDegrees`, `ProvisionalMaxSampleDistance`, `Source/GameCombat/Public/AethelnBasicChainAbility.h:19-20`) |
| Already-hit state | Step definition and timeline | `MaxTargets`; one result per target per activation, fixed for the prototype chain |
| Ordering | Timeline | The canonical total order (contact time, activation ordinal, result slot, target id); not authored per attack |
| Costs | Ability | `ProvisionalEnduranceCost` |
| Cooldown links | Ability | `ProvisionalCooldownSeconds` and its `Cooldown.<Order>.<Name>` tag; zero for the chain by structure (#60, No cooldown on the chain) |
| Interruption policy | Step definition | `InterruptibleUntil`, `bInterruptsTarget`; the reset and blocking tags (`ActivationBlockedTags` and the authored reset tags) |
| Damage and defense inputs | Step definition | `WroughtDamage`, `GuardPressure` |
| Validation identifiers | Ability | `AbilityId` tag, its registry semantic ID (one-to-one, see Gameplay Tag and Content-Version Conventions in the combat document), and `ContentVersion` |

Every field above is authoritative: changing any of them bumps the content
version in the same change. Nothing in the presentation binding is
authoritative, and changing it bumps nothing.

### Storage form

Today the definitions are `Config` properties in `DefaultGame.ini`, validated
at grant time and failing closed when unset
(`Config/DefaultGame.ini:17-38`). The basic chain has no configured
`ContentVersion` or steps yet, so it cannot be granted. The combat document
says ability definitions live in ini until #106 generates them; #106 closed
with Markdown generators only.

The real #84 choice is the form designers author. It is open decision D1 in
[Open Decisions](#open-decisions). The options:

| Option | Shape | For | Against |
| --- | --- | --- | --- |
| A. Keep ini | Status quo | No code | No editor preview, no asset validation, no stable-ID binding to intake |
| B. One Shared data asset (recommended) | `UAethelnAttackDefinition`, derived from `UAethelnPrimaryAssetDefinition`, `DA_` prefix, audience `Shared`; the ability loads it on the server at grant | Stable ID and content version already exist on the base class; the #120 validator already scans it; observers need the windows on clients anyway (#60, Observers) | Shapes and damage values are in the client cook (they are not hidden information under canon) |
| C. ServerOnly definition plus a Shared mirror | Two assets, windows mirrored for clients | Damage and shapes stay out of the client cook | Two sources of one truth; a mirror can drift |

The recommendation is B. Under any option the server reads only the
authoritative form, its `StableContentId` equals the registry semantic ID,
and its `ContentVersion` is the one the request and the `CombatActivation`
record carry.

## Presentation Binding Contract

### The binding

A presentation binding is a client-only data asset (proposed
`UAethelnAttackPresentation`, `DA_` prefix, audience `ClientOnly`). It holds:

- the `AbilityId` and `ContentVersion` it was authored against;
- per step: a montage (`AM_`), section names for wind-up, active, and
  recovery, and optional trail, sound, Niagara, and camera feedback;
- sockets used for trails and effects, and the skeleton they belong to;
- for an enemy, the telegraph presentation (#20 supplies the content). It
  only visualizes the server-owned `Telegraph` state that #83 replicates in
  `FAethelnEnemyPresentationState` before the step, and then the step's phase
  once the step is registered. It never starts, times, or ends a telegraph.

It may hard-reference the Shared definition (`client_only` to `shared` is
allowed by the intake policy). The definition never references it. A Shared
or ServerOnly package that hard-references a binding fails the existing
`reference_boundary` audience check. A soft reference is denied unless the
intake policy declares a matching rule, and this pipeline declares none; adding
one would undo the one-direction rule and needs a reviewed change to this
document.

Licensed content follows TA-019 (the private `AethelnArt` plugin):

- A binding that names a licensed montage, sequence, or effect lives in the
  plugin, next to that content.
- No public package in `Content/`, `Config/`, `Source/`, or `Plugins/`, and
  not the `.uproject`, references the plugin. A public binding names only
  public content.
- The authoritative definition never moves into the plugin. It stays public
  and `Shared`, so the server, tests, and CI never depend on private art.

### What presentation may do

- Play a montage from the authoritative `StartServerTime` in the
  `CombatActivation` record (owner) or the replicated phase state
  (observers of the player chain), mapping montage sections onto the authored
  windows. If the record arrives late, presentation skips forward so the
  active section lines up with server time. On `develop` only the player chain
  writes that phase state; a step an enemy registers directly gives observers
  nothing to read. Enemy presentation reads `FAethelnEnemyPresentationState`
  instead (#83): the `Telegraph` state and its server start time before the
  step, then the step start time and windows.
- Play cosmetic anticipation at press, which a rejection cancels, a record
  realigns, and a chain end stops (#60, Prediction Policy).
- Play trails, sounds, Niagara, and camera feedback from notifies, and play
  result feedback from the result cue.
- Sample a pose for an authoring preview in the editor.

### What presentation may not do

- Open, close, move, or extend a window or volume.
- Create a contact, choose a target, or report a hit.
- Apply damage, Guard pressure, a cost, a cooldown, a tag, or an effect.
- Send a gameplay event, call an ability, or write persistence.
- Use root motion or motion warping in attack montages. Root motion and
  motion warping need separate network validation and may not move an attack
  volume (combat document, Server-Owned Attack Timeline). Attacks restrict no
  movement in #60 P3 to P6 (OQ4); authored restrictions come later with #17's
  predicted movement, and this rule is revisited then.

If the binding's content version does not match the record, the client plays
a neutral fallback and logs a presentation warning. Gameplay is unchanged.

### Presentation cannot create truth

These properties already hold in code:

| Path | Why it cannot create truth | Evidence |
| --- | --- | --- |
| Gameplay event from a notify | Grant validation refuses any ability with `AbilityTriggers` (`Source/GameCombat/Private/AethelnGameplayAbility.cpp:53-56`) and any spec with dynamic triggers (`Source/GameCombat/Private/AethelnPlayerState.cpp:67`); a matching gameplay event activates nothing | `Aetheln.GameCombat.ActivationSeam.StockRoutesRefused` (T13) and `Aetheln.GameCombat.ActivationSeam.GrantValidationFailsClosed` |
| Montage and montage RPCs | No window derives from a montage; the montage RPCs are presentation only (#19, Closing the Stock Routes) | T13 |
| Sockets, mesh, root motion | The combat frame is the capsule and accepted aim, fixed for the step (`Source/GameCombat/Private/AethelnCombatTimelineSubsystem.cpp:264`); contacts count only on the capsule through the combat query channel | `Aetheln.GameCombat.AttackTimeline.ContactOnCapsuleOnly` (A9) |
| Missing presentation | The driver needs no mesh, montage, or notify | `Aetheln.GameCombat.AttackTimeline.RunsWithoutPresentation` (A17), `Aetheln.GameCombat.Defense.RunsWithoutPresentation` (D16) |

What is not yet pinned: a test that presentation events delivered to the
server during an active step change nothing. P2 adds it (N1 in the
[Test Plan](#test-plan)).

## Server Evaluation Without Client Targets

The server evaluates authored melee volumes from its own state only. The
request carries intent, aim, and a time sample, and no target, hit, contact,
shape, range, or window field (#60 Request Contract, A1). The sweep runs from
the server capsule pose and the accepted aim (#60, Combat frame and sweeps).
Authoring adds nothing to this path: a definition supplies shapes and windows,
and a binding supplies none.

## Authoring Validation

Each authoring error named by the issue has one gate. "Exists" means the gate
is on `develop` now; "P2" and "P3" are later phases of this issue.

| Error | Gate | Status |
| --- | --- | --- |
| Missing definition or unset values | Grant validation refuses a zero `ContentVersion` (`Source/GameCombat/Private/AethelnGameplayAbility.cpp:41-44`) and a chain without exactly three valid steps (#60 A5) | Exists |
| Missing definition asset referenced by an ability | Definition validator at editor save and at grant | P2 (after D1) |
| Missing montage, section, or effect in a binding | Presentation binding validator | P3 |
| Invalid phase order | Grant validation ordering rules (#60, Step definition) | Exists; P2 runs the same rules at editor save |
| Unsafe volume data | Grant validation: positive extents, non-negative damage and pressure, `MaxTargets >= 1`, pitch clamp in `[0, 90]` | Exists. A maximum reach or shape size is a `TBD` budget (#45, #107); until it exists the validator reports `non_promotion`, not a pass |
| Incompatible skeleton | `skeletal_animation` family `rig_compatibility` for meshes, skeletons, and sequences; the binding validator checks each montage's skeleton against the binding's skeleton | Family exists; binding check P3 |
| Incompatible socket reference | `socket_ownership` counts invalid sockets per mesh; the binding validator checks each named socket exists on the binding's skeleton or mesh | Family exists; binding check P3 |
| Stale identifiers | `reference_boundary` (unique stable ID, compatible content version, redirectors); the binding validator refuses a binding whose ability ID has no definition or whose content version differs | Family exists; binding check P3 |
| Stale tag or semantic ID | The registry validator checks registry records; the tag-to-semantic-ID mapping is checked only for the three Oathscar actives by a hand-listed test (`Source/GameTests/Private/AethelnOathscarAbilityTests.cpp:31-37`) | Partly exists. Gap: nothing checks a new or stale ability tag against the registry; a check that every native `Ability.` tag maps to one registry ID is needed |
| Notify that could carry gameplay | Binding validator allowlists presentation notify classes; any other notify class fails | P3 |

All gates fail closed. A validation failure never falls back to another
definition, an older version, or a default value.

## Animation Sourcing, Retargeting, and Intake

### Owner decision of 2026-10-11

Recorded on #84 and approved by the owner:

1. Start from Epic's free UE5 animation content: the Manny and Quinn mannequin
   sets and the Game Animation Sample locomotion and motion-matching content,
   retargeted to our characters with the IK Retargeter. It enters through #120
   with source, licence, and modification records.
2. Claude, through the Blender MCP, may help with rigging (Rigify auto-rig and
   weight fixes), retargeting, cleanup, timing trims, and rerunnable export
   scripts. No hand-keyed production combat animation is expected from Claude.
3. Generated motion is asset generation and belongs to Codex, if Codex has a
   suitable tool.
4. Animation only visualizes the server-owned timeline; timing stays in the
   authoritative data and `TBD` until supplied.
5. The owner approves final animation feel. Third-party animation goes through
   #120 before it lands in `Content/` or the private art plugin.

### Where content lives

- **Epic template mannequins** are already in public `Content/Characters/Mannequins`
  as `temporary_prototype`, `client_only` packages from the #100 closure
  (`docs/movement-poc.md`). They are UE EULA template examples (TA-019). No
  IK Rig or IK Retargeter asset exists yet.
- **Game Animation Sample** content is a Fab download that is not in the
  repository. Its licence is not inferred here. Under TA-019, Fab content
  lives in the private `AethelnArt` plugin unless its #120 intake record shows
  that public distribution is allowed.
- **Generated motion** follows the #120 generated-content row and the art
  storage boundary in the [Art Style and Generation Guide](art-style-guide.md).

### Retargeting

Epic content authored on the UE5 mannequin skeleton plays on `SK_Mannequin`
without retargeting. The owner confirms the skeleton when the download is
recorded. The prototype presents on the mannequin skeleton. The IK Retargeter
is needed when Kell, Aurin, and Vesh rigs exist; those rigs are not in the
repository yet. Race and sex never change authoritative collision, reach, or
timing, so retargeting changes presentation only.

### Combat animation gap

As far as Epic's public descriptions show, neither the mannequin template set
nor the Game Animation Sample includes sword-and-shield attacks or enemy
attack telegraphs. Their locomotion is a baseline, not a combat source. The
source for attack and telegraph animation is open decision D2.

### Blender MCP boundary

Blender work is scripted and rerunnable: scale, pivot, axis, rig fixes,
retarget help, timing trims, and export presets. The script and its inputs are
recorded with the intake record. The Blender MCP never generates a model and
never imports third-party assets from its asset libraries into the
repository.

## Source Control, LFS, and Locking

#14 is done, and its matrix in [Source Control](source-control.md) already
covers every format this pipeline produces. No new LFS pattern is needed.

| Content | Placement | Policy |
| --- | --- | --- |
| `.fbx` animation source, `.blend` rig and cleanup files | Source only, never in `Content/`; the reserved `SourceAssets/` root needs an asset-owning ticket before use | LFS binary and lockable |
| Sequences, montages, IK rigs, retargeters, bindings (`.uasset`) | `Content/` (public) or `Plugins/AethelnArt` (licensed, under the TA-019 rules in [The binding](#the-binding)) | LFS binary and lockable |
| Definitions (`.uasset`) | `Content/` only, never the plugin | LFS binary and lockable |
| Blender export scripts and intake records | Text outside `Content/` | Normal Git text |

Expectations:

- Lock a package before editing it, and release the lock after the change is
  pushed. Do not force-unlock another contributor's file.
- One author edits a montage and its binding at a time; the binding and
  definition are separate packages so animation and design work do not
  contend for one lock.
- A format not in the matrix (for example `.glb`, `.gltf`, `.bvh`, `.usd`, or
  `.abc`) needs a reviewed matrix change under the rules in
  [Source Control](source-control.md#attribute-policy) before the first file
  lands.
- Naming: new packages use `AS_` (sequence), `AM_` (montage), `IK_` (IK rig),
  `RTG_` (retargeter), `AN_` and `ANS_` (notify and notify-state Blueprints),
  and `DA_` (definition and binding). Imported Epic packages keep their source
  names; the intake record names any exception.

## Representative Attack and Enemy Telegraph

The issue asks for one representative attack and one enemy telegraph that
stay readable under representative latency, without final tuning.

- **Attack.** The first step of the Oathscar basic chain, authored as a
  definition (values from decision D3) and a binding on the mannequin.
- **Enemy telegraph.** The telegraph is server-owned state: #83's controller
  enters `Telegraph` before it registers the #20 step and replicates it in
  `FAethelnEnemyPresentationState`. The binding's telegraph and wind-up
  presentation only visualize that replicated state, then the step's phase
  once the step is registered.
- **Readability under latency.** Observers learn a state or step from
  replicated state about half a round trip after it starts. Presentation
  starts at the authoritative start and skips forward, so a late observer sees
  a shorter tell. Proposed criterion for #97, which owns readability: a tell
  (the `Telegraph` state plus wind-up) is readable only if it lasts longer
  than the one-way latency of the representative profile plus a minimum
  visible duration. The criterion and both numbers are #97's and #45's to
  accept; the numbers are `TBD`. Until they exist, this criterion cannot
  close.
- **Evidence.** Two-client PIE runs under the #82 conditions C1 and C2, with
  the server-side result log and a capture of each client, reviewed by the
  owner for feel and by #97 for readability.

## Ownership Boundaries

| Area | Owns | Never owns |
| --- | --- | --- |
| Combat (#60, #18, #20, #83, #260) | Definitions, windows, volumes, contacts, results, costs, cooldowns, interruption, the record, the observer phase state, and the enemy `Telegraph` state and its presentation state | Montages, notifies, sockets, effects, HUD |
| Animation (#84 pipeline, owner feel approval, Codex generation) | Sources, rigs, retargeters, sequences, montages, presentation notifies, bindings, and their intake records | Any authoritative field or content-version bump |
| UI feedback (#61, #97) | HUD, `GameplayCue.*` tags, result and telegraph readability, correction presentation | Windows, hit decisions, resources |
| Automation (#120 validator, registry validator, this pipeline's validators, Blender scripts, CI) | Detecting and refusing invalid data, recording evidence | Approving content, downloading content, accepting terms, generating assets, or choosing tuning |

## Test Plan

Names follow the existing `Aetheln.<Area>.<Group>.<Case>` pattern. **H** is a
headless authority world in the `GameTests` module, **E** is an editor
validation test, and **P** is two-client PIE recorded in the PR.

| # | Test | Phase | Kind | What it proves |
| --- | --- | --- | --- | --- |
| N1 | `Aetheln.GameCombat.AttackTimeline.PresentationEventsGrantNothing` | P2 | H | During wind-up, active, and recovery of a registered step, gameplay events (any tag, including the ability and state tags), `GameplayCue` executions, and montage play and stop requests on the server change no window, contact, result, Health, Guard, cost, cooldown, tag, chain state, or record, compared with the same run without them. Any path that cannot run headless is listed in the PR with the reason. |
| N2 | `Aetheln.GameCombat.AttackContent.DefinitionValidation` | P2 | H | The definition validator refuses a missing asset, each phase-order violation, unsafe volume data, a stable ID that is not in the registry, and a content-version mismatch with the ability; an unset reach budget reports `non_promotion` |
| N3 | `Aetheln.GameCombat.AttackContent.PresentationBindingValidation` | P3 | E | The binding validator refuses a missing montage or section, a montage on another skeleton, an unknown socket, a non-allowlisted notify class, an unknown ability ID, and a stale content version; a valid binding passes |
| N4 | `Aetheln.GameCombat.AttackContent.BindingAudience` | P3 | E | A Shared or ServerOnly package that hard- or soft-references a binding fails `reference_boundary`, and the intake policy declares no soft-reference rule that targets a binding path |
| N5 | Representative lifecycle | P5 | P | One authored step runs from validated data through server resolution to presentation on both clients, under C1 and C2 |

Existing tests that already cover this pipeline: T13, A1, A5, A9, A17, D16,
the registry tests, and the four portable content-validation suites.

## Acceptance-Criteria Mapping

| Issue #84 criterion | Covered by | Status |
| --- | --- | --- |
| The authoritative attack asset/data contract owns phases, authored volumes, already-hit state, ordering, costs, cooldown links, interruption policy, and validation identifiers | [Fields](#fields); #60 step definition and grant validation; D1 for the asset form | Contract defined; asset form waits on D1 and P2 |
| Montages, animation notifies, sockets, trails, audio, and VFX are presentation or authoring aids and cannot create contact, damage, cooldown, or persistence truth | [Presentation Binding Contract](#presentation-binding-contract); T13, A9, A17, D16; N1 | Enforced in code; N1 pins it in P2 |
| The server can evaluate authored melee volumes without a client-selected target or client-claimed hit | [Server Evaluation Without Client Targets](#server-evaluation-without-client-targets); #60 A1, A9 | Met by #60 |
| Authoring validation detects missing assets, invalid phase order, unsafe volume data, incompatible skeleton/socket references, and stale identifiers before runtime | [Authoring Validation](#authoring-validation); N2 to N4 | Partly exists; P2 and P3 complete it |
| The pipeline defines source-control/LFS/locking expectations and coordinates with #14 before non-map binary assets land | [Source Control, LFS, and Locking](#source-control-lfs-and-locking) | Defined; no matrix change needed |
| A representative attack and enemy telegraph are authored and remain readable under representative latency without choosing final combat tuning | [Representative Attack and Enemy Telegraph](#representative-attack-and-enemy-telegraph); N5 | Waits on D2, D3, #83, #20, #61, #45, and owner actions |

| Definition of done | Covered by | Status |
| --- | --- | --- |
| One complete authored attack lifecycle runs from validated data through server resolution and client presentation | N5 | Waits on P2 to P5 |
| Focused tests prove animation events cannot grant gameplay outcomes | T13, A17, D16 now; N1 | N1 in P2 |
| Documentation names ownership boundaries for combat, animation, UI feedback, and automation | [Ownership Boundaries](#ownership-boundaries) | This document |

## Phased Delivery

Each PR targets `develop` and uses `Refs #84`.

| PR | Scope | Depends on |
| --- | --- | --- |
| **P1** | This document and the index entry. Docs only. | Lead review |
| **P2** Definition and focused tests | The authoritative definition in the form D1 selects, its validator at editor save and grant, N1 and N2. No values. | D1; engine time |
| **P3** Presentation binding | The client-only binding, its validator (skeleton, socket, section, notify allowlist, ability ID, content version), N3 and N4. Fixture assets only. | P2; engine time |
| **P4** Baseline intake | #120 intake of the downloaded Epic content, IK Rig and IK Retargeter assets, Blender cleanup scripts, and the first montage on the mannequin | Owner actions O1 and O2; D2; P3 |
| **P5** Representative lifecycle | The representative attack and enemy telegraph bindings and N5 evidence | D3; #83 enemy controller and presentation state; #20 enemy steps; #61 presentation; #45 profiles; owner feel review |

## Owner Actions

- **O1.** Download the Game Animation Sample from Fab and accept its terms, if
  the owner chooses to. Automation must not download content or accept terms.
- **O2.** Record where the download lives and its licence, so #120 intake can
  decide between public `Content/` and the private `AethelnArt` plugin.
- **O3.** Review final animation feel for the representative attack and
  telegraph (P5).

## Open Decisions

| # | Decision | Owner | Recommendation |
| --- | --- | --- | --- |
| D1 | Storage form of authoritative attack definitions: ini, one Shared data asset, or ServerOnly plus a Shared mirror ([Storage form](#storage-form)) | Lead (technical); may need an ADR entry | One Shared data asset (option B) |
| D2 | Source of sword-and-shield attack and enemy telegraph animation, which the Epic baseline does not appear to include: a third-party pack through #120 (private plugin under TA-019), Codex-generated motion, a human animator, or a placeholder presentation for P5 evidence | Owner | Placeholder presentation for P5, so evidence does not wait on art; replace later without changing gameplay |
| D3 | Timing, shape, damage, and readability values for the representative attack and telegraph. #107 closed without them. | Owner, with #45 and #97 | None; no value is proposed here |

## Residual Risks

1. **Licensed art and packaging.** Content in the private plugin is not in
   packaged builds yet (TA-019 follow-ups). A representative attack bound to
   licensed animation presents only in local editor sessions until that
   changes.
2. **Late observers.** Under latency, observers see a shortened tell.
   Readability depends on `TBD` budgets (#45, #97).
3. **Notify allowlist scope.** The allowlist (P3) checks notify classes, not
   their code. A presentation notify class that calls gameplay code would pass
   the allowlist; N1 and the existing refusals keep it from changing a result,
   and code review owns the rest.
4. **No reach budget.** Unsafe volume checks are structural until a maximum
   reach or shape budget exists.
