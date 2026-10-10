# Combat and Networking Architecture

## Document Status

This document is the canonical technical specification for movement, abilities,
free-aim combat, replication, prediction, correction, and latency validation.
Player-facing combat goals remain governed by the
[Game Design Bible](game-design-bible.md).
Player-facing body, rig, and animation-presentation rules remain governed by
[Playable Peoples](playable-peoples.md).

Technology selections that require measurement remain candidates in
[Architecture Decisions](architecture-decisions.md).

## Combat Invariants

- Combat uses pure free aim. The client never selects an authoritative target.
- The server never accepts a client-claimed hit, damage value, defensive
  outcome, resource result, death, or reward.
- Movement validity is owned by the authoritative
  `UCharacterMovementComponent` simulation.
- Ability state is owned by the Gameplay Ability System and the server-owned
  combat timeline.
- Authored gameplay windows and volumes determine attacks. Animation, sockets,
  Niagara, audio, and camera feedback visualize the result but do not create it.
- Appearance, race, sex, cosmetics, and client visual scale never change
  authoritative collision, reach, timing, or damage.
- Kell crown and mantle bones and Vesh back-veil bones are visual-only
  auxiliaries. They never drive combat collision, authoritative traces, shared
  weapon-presentation sockets, root motion, authored contact timing, or
  gameplay state.
- Presentation sockets and camera or aim-presentation anchors never establish
  gameplay windows, volumes, contacts, trace origins, or selected targets.
- Territory policy is checked both when a hostile action activates and when an
  effect would apply.

## Shared Combat Semantic Contract

The five shared combat resources have stable semantic identities. They are
server-owned GAS attributes or server-owned state derived from those
attributes; a display label, Order, item, or Skein choice cannot change their
meaning.

| Resource | Stable semantic ID | Required invariant |
| --- | --- | --- |
| Health | `combat.resource.health` | Remaining life. Health reaching zero schedules the authoritative death transition. Any future deliberate Health cost requires an explicit authored and readable rule. |
| Endurance | `combat.resource.endurance` | Shared exertion spent only by an authored action cost. A client may predict presentation of an eligible spend but cannot claim the spend, refund, or recovery. |
| Guard | `combat.resource.guard` | Stability for an active directional defense. Guard pressure matters only while an eligible defense is active; Guard is not an always-on damage shield. |
| Ward | `combat.resource.ward` | Explicit absorb capacity supplied by an authored effect. Each Ward definition declares eligible damage families, stacking, lifetime, and depletion behavior. |
| OrderResource | `combat.resource.order` | One typed slot whose compatible definition is selected by authoritative Order ID: Grudge, Proof, Tempo, Cadence, or Tension. It never aliases another shared resource. |

Each resource has an authoritative current value, authored bound, content
version, and mutation reason. Every mutation clamps or rejects according to its
versioned definition and emits at most one committed result for an idempotent
activation/effect identity. Exact bounds, costs, recovery rates, delays, and
reset values remain tuning `TBD`.

Recovery uses four semantic paths:

- **Passive or delayed recovery** advances from the server clock under explicit
  tags and combat-state conditions.
- **Event-driven recovery** is granted by a validated authoritative combat
  event, never by a client assertion that the event occurred.
- **Effect-supplied restoration** is an immediate or periodic Gameplay Effect
  with the same stacking, deduplication, and policy checks as other effects.
- **Lifecycle restoration** applies an explicit respawn or encounter-reset
  allowlist; it never means restore every attribute or clear every effect.

An action's recovery window, its cooldown, and resource recovery are separate
states. Their ordering at the same server timestamp is declared by the combat
timeline/content version rather than inherited from actor tick order.

## Damage Families and Deterministic Defense

Every damage component names exactly one stable family:

| Family | Stable semantic ID | Semantic scope |
| --- | --- | --- |
| Wrought | `combat.damage.wrought` | Material force, including weapons, impacts, and physical trauma. |
| Cinder | `combat.damage.cinder` | Destructive Ember-light, heat, or burning transformation. |
| Wake | `combat.damage.wake` | Deepwake pressure against continuity, memory, or realized form. |

A family is not itself a status effect, armor bypass, critical rule, proc, or
control category. Those behaviors require separate authored data. One ability
may emit multiple family components, but each component is a separate,
ordered, readable result packet with its own family and mitigation record; a
mixed label may not obscure which component produced a result. No family is
unmitigated "true damage," and no authored alias may skip this resolution order.

For each authoritative contact, the server performs this order:

1. Revalidate source authority, source and target life state under the
   result's authored source-survival rule, current relation, most-specific
   territory/sanctuary policy, content version, and effect eligibility. This
   occurs again when a projectile arrives or a periodic or delayed effect
   ticks; activation-time permission does not survive a policy change
   automatically. A dead source is not implicitly eligible or ineligible:
   only an explicitly permitted surviving result may continue.
2. Validate authored contact from the server-owned volume or simulation and
   reject any duplicate activation/contact identity. Each permitted result has
   a server-authored contact/result slot; a periodic effect also identifies its
   effect instance, schedule generation, and scheduled tick ordinal so distinct
   ticks cannot alias one another or replay the same tick. Enforce the versioned
   definition's per-target result allowance: a one-result-per-activation rule
   rejects an actor already in the activation's bounded already-hit set, while
   authored repeat-result rules, including eligible periodic ticks, use bounded
   actor/result-slot identities and per-target counts to reject duplicate
   deliveries or results beyond the authored allowance. A committed component
   result is keyed by activation or effect instance, stable target identity,
   authored result slot, periodic schedule generation and tick ordinal when
   applicable, and authored component ordinal. If the applicable record is
   full, reject new results for that activation; do not evict or clear recorded
   identities while any result from it can still apply or be replayed.
3. Resolve avoidance and explicit immunity, including the server-owned dodge
   window. An avoided contact cannot be reintroduced by later presentation.
4. Resolve directional block from authoritative facing and contact geometry,
   then apply the authored Guard pressure once. A Guard break does not re-score
   the same contact. Whether a later component of that contact sees the broken
   state must be explicit in the content definition; the default contact-level
   defense snapshot does not change halfway through the contact.
5. Resolve each family component in stable content order through its explicit
   family modifiers and mitigation.
6. Consume eligible Ward capacity from the post-mitigation component in its
   stable authored Ward order. Depletion affects the next eligible component;
   a Ward cannot consume damage twice or become negative.
7. Apply remaining damage to Health and record the component result. Health
   reaching zero latches the contact's death transition before secondary
   effects. After all declared components for the contact resolve, apply
   eligible secondary effects, interruption, and control. Ordinary secondary
   Health restoration or control is ineligible for a target whose Health made
   the contact lethal. An explicitly authored on-death lifecycle effect may
   still run under its declared rule but does not cancel the latched death;
   death prevention must resolve before the zero-Health result.
8. Commit death and cancellation once, then emit authoritative presentation,
   audit, threat, engagement, and proc events from the committed result.

Contacts sharing one timestamp use a documented total order over authoritative
timeline time, a unique server-issued activation sequence within the ordered
timeline, stable effect-instance identity when applicable, server-authored
contact/result slot, periodic schedule generation and tick ordinal when
applicable, and stable target actor identity. All authored components for one
ordered contact and target resolve atomically in component order before the
next contact/target begins. A remaining identical contact/target key is a
duplicate, not an actor-iteration tie. Guard break, Ward depletion, Health
zero, and control therefore cannot depend on packet arrival, actor iteration,
or animation-notify order.
Duplicate or reordered requests and effect deliveries converge on the recorded
result; they never repeat damage, restoration, recovery, control, threat, or a
proc.

## Effects, Cleanses, Resolve, and Proc Safety

An immediate effect commits one bounded result. A duration effect is a closed,
versioned definition that declares:

- stable effect and stacking-key identities;
- beneficial, harmful, control, or lifecycle classification;
- source scope and authoritative source identity;
- duration, periodic schedule, and expiry behavior;
- bounded stack limit and add, refresh, replace, or independent-instance rule;
- removal behavior when its source disappears, its owner is destroyed, its
  target dies, or territory/life-state policy changes;
- cleanse categories plus explicit cleanse immunity when applicable; and
- whether it may emit or listen for procs.

Missing or incompatible lifecycle data fails closed rather than choosing an
implicit refresh, persistence, or cleanup rule. Refresh and replacement update
one recorded effect identity; they do not leave a second hidden timer. A
schedule generation changes when authored refresh or replacement restarts the
periodic schedule; its server-issued tick ordinals distinguish permitted
results and reject duplicate delivery of one tick. Periodic ticks revalidate
target existence, life state, relation, territory policy, and effect version
before resolution. Source removal, actor destruction, death, unpossession, and
respawn cannot leave a dangling timer or stale actor pointer.

A cleanse is a server-owned effect. It selects only effects within its authored
cleanse categories and relation/policy scope, then removes them in a stable
order. Ineligible, uncleanseable, lifecycle, already-expired, or foreign-scope
effects remain unchanged. A sanctuary or lifecycle transition may invoke a
separate authored server cleanse, but a client cannot claim that crossing a
boundary removed an effect or choose a concealed effect by identifier.

**Resolve** is the common server-owned protection against repeated eligible
control. Each control definition declares whether it participates, how its
attempt is evaluated against current Resolve, and what authoritative Resolve
mutation follows. Resolve is neither damage mitigation nor a general immunity;
displacement, interruption, and non-control effects remain distinct unless
their definitions explicitly participate. Gain, decay, consumption,
thresholds, immunity windows, and control-family details remain tuning `TBD`.

Every triggered effect carries a root activation/event identity, parent event,
source identity, definition version, and bounded ancestry. The server rejects
recursive self-triggering, repeated ancestry, and any proc beyond the authored
chain bound. Each root also carries fail-closed aggregate budgets for listener
evaluations, emitted proc events, affected targets, and generated constructs
across every immediate, delayed, and periodic descendant. An acyclic fan-out
cannot reset or evade those budgets. Overflow rejects the excess work in a
deterministic order and records bounded safe telemetry without partially
authorizing a client-selected result.

Echoes, mutual listeners, reflected events, periodic effects, and
server-generated constructs preserve the original chain identity instead of
starting a fresh chain to evade the bounds. Generated constructs may have a
distinct authoritative actor identity, but never a new client-controlled
authority. Exact depth and aggregate budget values remain tuning `TBD`; finite
fail-closed depth, listener, event, target, and construct bounds are invariants.

## Relation, Collision, Engagement, Threat, and Taunt

The server evaluates relation for the current source, target, and world-policy
context as self, friendly, neutral, hostile, or protected/non-interactable.
Party, ownership, faction, duel/encounter state where one is later approved,
and territory policy are inputs. A relation is not trusted from the client,
cached across a policy transition without revalidation, or inferred only from
visual appearance. Projectiles, areas, summons, pets, and other proxies carry
their authoritative originating identity and policy context; they do not
become neutral or self-authorizing when ownership changes or the source
disconnects, and they revalidate current source/target policy when applying a
result. Before the 2.0 faction stage, `Faction = Unassigned`; this contract does
not decide future cross-faction grouping.

The following collision domains remain separate:

- movement/world collision owned by the server-authoritative movement
  simulation;
- authored combat query volumes and target eligibility owned by the combat
  timeline;
- observer visibility and detection queries owned by server policy; and
- presentation meshes, weapon geometry, sockets, camera offsets, and effects,
  which never become gameplay collision.

Exact Unreal collision channels, body-blocking rules, shapes, dimensions, and
sampling budgets remain implementation/tuning data. An overlap in a rendered
mesh cannot create a contact, and hiding a mesh cannot remove authoritative
collision.

Engagement is server-owned state derived from accepted hostile activations and
committed damage, control, healing, shielding, or protection involving an
engaged participant. A rejected request does not engage anyone. Support can
therefore enter engagement without inventing a hostile hit, but only from the
server-observed committed support result. Engagement ends through explicit
encounter completion, death/lifecycle rules, or a server-clock policy; a client
disconnect or local UI state never clears it by itself. Exact timeouts and
recovery restrictions remain tuning `TBD`.

PvE threat is an authoritative per-AI prioritization input derived from
eligible committed actions. Its formulas, caps, decay, tie-breaking weights,
and visibility remain tuning `TBD`. A taunt is an authored temporary priority
rule for eligible AI and still requires server relation, life-state, immunity,
  and any authored range or line-of-sight validation. It does not make a
  client-selected target authoritative. Taunt never overrides another player's
  input or agency in PvP; player-facing pressure must use ordinary readable
  combat verbs instead.

## Death, Logout, and Recovery Safety

Health reaching zero enters one server-owned death transition. The transition
invalidates new movement and activation, closes or cancels pawn-bound timelines,
releases or updates threat/engagement references, and removes, preserves, or
transfers effects only through their declared lifecycle rule. A server-owned
projectile, area, or construct may survive its source only when its versioned
definition explicitly permits that behavior. Its activation identity,
already-hit/result-slot records, and proc-chain budgets remain server-owned
through the last permitted result and replay window; death or pawn destruction
cannot reset them to grant a second hit. Records are retired only after no
surviving result can apply and its replay allowance has expired.

Respawn creates or reassigns the authoritative avatar and restores only the
declared lifecycle allowlist. It cannot revive stale activation, control,
invulnerability, stealth, threat, Ward, proc ancestry, or a reference to the
destroyed pawn. Death during a periodic tick, control transition, recovery
grant, or attack resolves once under the deterministic order above.

A clean logout is a server-approved state transition subject to engagement,
world, encounter, and persistence policy. A disconnect during an attack,
control, stealth, death, or recovery interval only removes the connection; the
server continues or cancels gameplay state according to its authored lifecycle
rules. Reconnect creates a new authenticated connection and resolves to one
current authoritative state. Exact safe-logout and disconnect grace durations
remain `TBD`; disconnect is never an instant escape, cleanse, restore, or grant.

## Secure Stealth and Opponent Readability

Stealth, reveal, and detection are observer-specific server decisions. The
server limits replication and presentation events to information an observer
is authorized to perceive; a hidden actor must not leak through HUD bindings,
target lists, nameplates, audio/effect events, threat UI, or debug data shipped
to an untrusted client. The replication technology that enforces the policy
remains evidence-gated, but client-side hiding alone is never sufficient.

Stealth does not grant client authority or silently erase server collision. A
server-owned area, projectile, or authored detection query may affect a
concealed actor when policy allows it without revealing hidden details in
advance. Reveal, stealth break, and re-conceal are authoritative events with
versioned rules. A disconnect, source destruction, death, respawn, or territory
transition during stealth cannot leave an observer with stale hidden-state
authority or leak a concealed identity.

Opponents receive readable, presentation-safe cues for dangerous wind-up,
active and recovery phases; Wrought, Cinder, and Wake result families; block,
Guard break, Ward depletion, interruption, eligible control, Resolve response,
death, and authorized reveal. Cues do not expose concealed actors, hidden
anti-abuse thresholds, exact unrevealed resources, or server-only detection
inputs. Animation, HUD, audio, sockets, Niagara, and camera feedback present the
authoritative result and corrections; none of them opens a window, chooses a
target, applies an effect, or establishes a hit.

## Prototype Boundary and Existing Owners

The prototype implements one Oathscar sword-and-shield proof in the controlled
arena. Its bounded shared subset is Health, Endurance, active Guard, a three-hit
Wrought combo, directional block, dodge, three representative active abilities,
the minimum effects required by those actions, death, respawn, and
readable feedback. Issue
[#107](https://github.com/ShayShimoni/aetheln-online/issues/107) may define one
optional Oathbreak exercise; Grudge and the generalized OrderResource loop are
not default prototype runtime scope. Ward, Cinder, Wake, generalized threat and
taunt, broad cleanse and Resolve catalogues, stealth gameplay, faction relation
policy, and the other Orders also remain outside prototype runtime scope.
Deferral does not remove their shared semantic contracts.

This document supplies semantics, not duplicate implementation or evidence:

| Owner | Retained responsibility |
| --- | --- |
| [#2](https://github.com/ShayShimoni/aetheln-online/issues/2) | Networking/authority candidate comparison, packaged validation, latency policy, and measured network profiles. |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Dodge cost/cooldown, authoritative invulnerability, correction, and network-condition tests. |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | PlayerState-owned GAS attributes, effects, resources, cooldowns, tags, replication, and rollback. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Authoritative AI threat evaluation, target choice, attack behavior, and runtime evidence. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Integrated death, respawn, reconnect, stale-state cleanup, and duplicate-completion tests. |
| [#40](https://github.com/ShayShimoni/aetheln-online/issues/40) | Threat controls, forgery/abuse coverage, telemetry, and residual-risk ownership. |
| [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Measured client/server/network budgets, scenarios, thresholds, and approvals. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Pure-free-aim attack timeline, authored contacts, ordering implementation, and three-hit chain. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61) | HUD, correction/rejection presentation, accessibility-safe cues, and readability evidence. |
| [#82](https://github.com/ShayShimoni/aetheln-online/issues/82) | Input/camera contract and measured pure-free-aim feel. |
| [#106](https://github.com/ShayShimoni/aetheln-online/issues/106) | Machine-readable IDs, deterministic generation, bounded listener/proc validation, and registry tooling. |

Prototype briefs and ledgers that still carry the pre-Issue-#103 unnamed-resource
placeholder are downstream reconciliation work for
[#115](https://github.com/ShayShimoni/aetheln-online/issues/115). This contract
does not rewrite historical evidence or claim that unimplemented behavior has
passed runtime, packaged, performance, security, readability, or QA gates.

## Local Control Modes

The owning client starts gameplay in Reticle mode: hidden cursor, fixed center
reticle, camera-relative movement, camera-directed aim, and continuous
camera-facing steering intent. Cursor mode is a local input gate. Entering it
clears pending movement, jump, sprint, zoom, and look input and requires fresh
presses after recapture, but it does not pause physics, remove existing
momentum, cancel accepted abilities, or stop server-owned timelines.

Left Alt provides the prototype toggle. Future CommonUI screens and dialogue
flows must use stacked cursor-ownership requests rather than independent
booleans. An unhandled viewport click may recapture gameplay; a UI-handled click
must not. Focus loss enters Cursor mode, and focus recovery remains there until
an explicit recapture.

Close-camera shoulder offset and owner-only mesh hiding are presentation. They
never modify the authoritative aim direction, attack origin, authored volume,
collision, reach, or timeline. Shoulder-camera parallax and attacks obstructed
by near cover require separate combat validation; the movement prototype does
not prove reticle-to-attack alignment.

## Runtime Ownership

### Character Movement Component

`UCharacterMovementComponent` owns predicted and reconciled player movement.
Custom movement extends its saved-move and network-prediction paths rather than
creating a second uncoordinated transform authority.

The server validates:

- Movement mode and allowed transitions.
- Acceleration, speed, rotation, and displacement constraints.
- Sprint, dodge, root, knockback, and other state prerequisites.
- Collision and world-policy restrictions.
- Sequence ordering and stale or duplicated movement input.

The owning client may predict ordinary movement and supported custom movement.
Remote clients interpolate replicated authoritative state.

### Gameplay Ability System

- A player character's Ability System Component lives on `PlayerState` so
  authoritative ability and attribute state can survive pawn death and
  respawn.
- The possessed pawn provides avatar-specific movement, collision, animation,
  and equipment presentation.
- AI Ability System Components live on their authoritative pawns unless a future
  persistence requirement justifies a different owner.
- Gameplay Tags are the shared vocabulary for activation requirements,
  cancellation, immunities, crowd control, cooldowns, and territory-policy
  gates.
- Gameplay Effects own attribute changes. Direct client-authored attribute
  writes are prohibited.

The implementation must define and test possession, respawn, avatar reassignment,
attribute initialization, and replication for the `PlayerState`-owned component.

Reference:
[Understanding the Unreal Engine Gameplay Ability System](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-the-unreal-engine-gameplay-ability-system).

### Gameplay Tag and Content-Version Conventions

The foundation that implements these conventions is specified in
[Gameplay Ability System Foundation](gas-foundation.md).

**Two vocabularies, one mapping.** Canonical semantic IDs such as
`combat.resource.endurance` and `order.oathscar.ability.gate_step` are the
content identity and belong to the registry work in
[#106](https://github.com/ShayShimoni/aetheln-online/issues/106). Gameplay Tags
are the runtime vocabulary. Every tag that names authored content maps one to
one to a semantic ID in the table below. A tag is never reused for a different
meaning. Renaming a tag is a migration that bumps every affected content
version.

**Declaration.** Authoritative tags are native C++ tags declared in `GameCore`
(`AethelnGameplayTags`). No authoritative logic depends on a tag that exists
only in an ini file or a Blueprint asset. Client and server builds must have
identical tag lists.

**Spelling.** Dotted PascalCase segments with no spaces, following the
existing examples `Ability.Melee.Combo1`, `State.Dodging`, and
`Cooldown.Dodge`. Those three are style references, not registered tags; #18
and #60 register the tags for dodge and the basic chain when they add them.
Working names may appear in tags. A display rename does not require a tag
rename.

**Families.**

| Family | Meaning | Who applies it |
| --- | --- | --- |
| `Ability.<Order>.<Name>` | Ability identity, the request `AbilityId` | Granted by the server |
| `Cooldown.<Order>.<Name>` | Ability on cooldown | Shared cooldown effect, server |
| `State.<Name>` | Authoritative actor state, for example `State.Dead` and `State.Dodging` | Server-owned effects or abilities of the owning issue only |
| `SetByCaller.<Purpose>.<Name>` | Effect magnitude keys, for example `SetByCaller.Cooldown.Duration`, `SetByCaller.Cost.Endurance`, `SetByCaller.Init.MaxHealth` | Server code building specs |
| `Ability.Test.*`, `Test.*` | Test-only tags (`AethelnCombatTestTags`) for the automation tests. They name no content and map to no semantic ID. Declared in `GameCore` under `WITH_DEV_AUTOMATION_TESTS`, so Shipping builds carry none (see the Test Plan in [Gameplay Ability System Foundation](gas-foundation.md#test-plan)) | Automation tests only |

**Order scope.** The `<Order>` segment appears only when the content's semantic
ID is Order-scoped (an `order.<order>.` prefix), as in `Ability.Oathscar.GateStep` and
`Cooldown.Oathscar.GateStep`. Order-scoped state follows the same form,
`State.<Order>.<Name>`. A shared action with no Order-scoped semantic ID, such
as dodge, block, or sprint, uses `<Family>.<Name>`, for example
`Cooldown.Dodge` and `State.Dodging`. The basic chain takes the form its
semantic ID dictates (`order.oathscar.ability.sword_shield_basic_chain` is
Order-scoped). `Ability.Melee.Combo1` is the spike's string and a spelling
example only. This keeps the mapping from tag to semantic ID one to one.

`GameplayCue.*` (presentation, #61 and #97), damage-family effect tags (#60),
and territory `Policy.*` tags (2.x) are reserved for their owners. The engine's
activation-failure tags are not configured: the activation seam reads its
rejection reason from the cooldown, cost, and tag checks directly.

**Client input.** The only tag a client sends is the request `AbilityId`. The
server accepts it only if it is in the `Ability.` family and names an ability
granted to that character.

**Content version.** Every ability definition has an unsigned `ContentVersion`,
starting at 1. Bump it in the same change whenever an authoritative field
changes: cost, cooldown, tag requirements or blocks, phase support, applied
effects, and later #60's windows and shapes. Presentation-only changes do not
bump it. The server accepts only an exact match and otherwise fails closed with
`IncompatibleVersion`. The request struct has its own `SchemaVersion`, which is
bumped on any layout change; an older schema is rejected. The authoritative
`CombatActivation` record carries the `ContentVersion` the server used. Ability
definitions live in config ini until #106 generates them. Until then, bumps are
manual and checked in review.

**Initial entries.**

| Tag | Semantic ID | Owner |
| --- | --- | --- |
| `Ability.Oathscar.GateStep` | `order.oathscar.ability.gate_step` | #19 (skeleton), #60 (contact) |
| `Ability.Oathscar.SwornRebuke` | `order.oathscar.ability.sworn_rebuke` | #19 (skeleton), #60 (contact) |
| `Ability.Oathscar.HoldTheLine` | `order.oathscar.ability.hold_the_line` | #19 (skeleton), #60 (Guard result) |
| `Ability.Oathscar.SwordShieldBasicChain` | `order.oathscar.ability.sword_shield_basic_chain` | #60 P3 |
| `State.Oathscar.SwordShieldBasicChain` | (commitment state of the above) | #60 P3 |
| `Cooldown.Oathscar.GateStep`, `Cooldown.Oathscar.SwornRebuke`, `Cooldown.Oathscar.HoldTheLine` | (cooldown state of the above) | #19 |
| `State.Dead` | (death flow state) | Declared by #19, applied by #21 |

Attributes are not tags. `Health`, `Endurance`, and `Guard` map to
`combat.resource.health`, `combat.resource.endurance`, and
`combat.resource.guard`. The working names Gate Step, Sworn Rebuke, Hold the
Line, Endurance, Guard, and Oathscar are not final display names.

## Pure Free Aim

Input provides intent:

- View orientation and movement.
- Ability identifier.
- Press, release, or charge state.
- A bounded client sequence and timing sample where the protocol allows it.

Input does not provide:

- Selected victim.
- Claimed contact point or surface.
- Claimed damage, stagger, block, dodge, or critical result.
- An arbitrary trace shape, distance, or active window.

The server resolves the authored attack definition for the validated ability
and content version. For melee, it evaluates authoritative swept shapes during
the active windows. For projectiles and persistent areas, it spawns and
simulates server-owned gameplay actors or server-owned lightweight simulation
state.

A camera-relative request is converted into a server-bounded aim direction.
The implementation records the accepted direction and correction result. It
rejects impossible orientation changes or inputs outside the allowed temporal
and angular bounds.

## Server-Owned Attack Timeline

Every accepted combat activation creates an authoritative timeline containing:

- Activation and sequence identity.
- Instigator and authoritative start time.
- Ability and content-definition version.
- Wind-up, active, recovery, cancel, and defensive windows.
- Authored shapes, transforms, and sampling rules.
- Resource, cooldown, and prerequisite state.
- Actors already affected when a rule permits only one result per activation.
- Block, dodge, interruption, crowd-control, and death ordering.
- Authoritative results and any client correction.

The timeline advances on the server even when a cosmetic montage or effect is
missing. Animation notifies may request presentation transitions or help sample
an authored pose, but a notify received from a client cannot open a gameplay
window.

Root motion and motion warping require explicit network validation. They do not
move an attack volume beyond the server's accepted character state.

## CombatActivation Contract

`CombatActivation` is the versioned authoritative record sent or replicated to
the consumers that need to present or audit one activation.

| Field | Requirement |
| --- | --- |
| `ActivationId` | Globally unique or instance-unique stable identity with documented scope |
| `SequenceId` | Monotonic identity within the actor/connection scope |
| `InstigatorId` | Authoritative actor identity |
| `AuthoritativeStartTime` | Server time in the instance clock domain |
| `AbilityId` | Stable gameplay ability/content identity |
| `ContentVersion` | Exact authored definition used by the server |
| `ActiveWindows` | Versioned offsets and semantic window types |
| `AttackShapes` | Authored shape identities and resolved server transforms, not client input |
| `CorrectionResult` | Accepted, corrected, or rejected with safe reason code |
| `ResultReferences` | Server result identities where required for audit or presentation |
| `SchemaVersion` | Contract compatibility version |

Serialization and transport remain undecided. A client copy is presentation
state, not a capability to amend the authoritative record.

## Prediction Matrix

| Behavior | Owning client | Server | Other clients |
| --- | --- | --- | --- |
| Ordinary movement | Predict, then reconcile | Validate and simulate | Interpolate |
| Supported custom movement | Predict with saved move | Validate and simulate | Interpolate |
| GAS activation | Predict when the ability supports rollback | Accept, correct, or reject | Observe accepted activation |
| Montage and cues | Predict presentation | Confirm authoritative timeline | Observe replicated presentation |
| Reversible costs/cooldowns | Predict only through supported GAS prediction | Commit or roll back | Observe committed state |
| Attack contact | Optional cosmetic anticipation only | Resolve authored volumes | Observe result |
| Damage/healing | Never authoritative | Calculate and apply | Observe result |
| Block/dodge outcome | Request/predict presentation | Order and resolve | Observe result |
| Crowd control/death/respawn | Never authoritative | Resolve and transition | Observe result |
| Rewards/persistent outcomes | Never predict as owned state | Submit validated durable command | Observe recorded receipt |

Prediction is enabled per ability only after rollback and correction behavior is
tested under the supported network profiles. A predicted visual effect must not
be mistaken for a confirmed hit.

## Ordering and Defensive Resolution

The authoritative timeline defines a deterministic order for:

1. Validate activation and territory policy.
2. Commit authoritative costs and cooldown rules.
3. Advance movement and combat windows using the server clock.
4. Revalidate authored contact, eligibility, relation, and current territory
   policy; reject duplicate activation/contact identities and enforce the
   versioned per-target result allowance with bounded records, then record the
   accepted contact, including a distinct server-issued periodic tick identity
   when applicable.
5. Resolve avoidance/immunity, directional block and Guard, family mitigation,
   Ward, and Health in the shared defense order; Health reaching zero latches
   death and makes ordinary secondary Health restoration or control ineligible
   for that target.
6. Apply eligible secondary effects, interruption, and control/Resolve after
   all declared components resolve.
7. Commit death and cancellation once.
8. Emit threat, engagement, bounded proc, authoritative presentation, and audit
   events only from the committed result.

The exact rule between simultaneous events is content data or an explicit combat
decision, never frame-order accident. Tests must cover boundary timestamps,
multi-family contacts, same-timestamp Guard/Ward/Health/control transitions,
repeated or reordered packets, authored repeat-contact allowances, already-hit
capacity saturation and replay, same-timestamp contact/result-slot ties,
duplicate versus distinct periodic ticks, source death with a surviving
projectile or area, lethal-contact secondary restoration, policy changes while
an effect is in flight, stack refresh/replacement, periodic ticks, cleanse
eligibility, proc cycles, actor destruction, disconnect, and death during an
active window.

## Corrections and Rejections

The client receives enough information to return to authoritative state without
learning sensitive detection rules.

Correction categories include:

- Stale or duplicated sequence.
- Invalid movement or orientation.
- Ability unavailable, blocked, or on cooldown.
- Insufficient authoritative resource.
- Incompatible content/protocol version.
- Territory policy rejection.
- Target/effect no longer valid.
- Timestamp outside accepted bounds.
- Rate or resource limit exceeded.

Telemetry correlates connection, character, instance, activation, ability,
content version, network profile, and safe reason code. Sensitive anti-abuse
features and secrets are excluded from client errors and ordinary logs.

Repeated rejection is an observable security signal, not proof by itself that a
player is cheating.

## Replication Strategy Gate

[Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2) must implement
the same representative actor mix and scenarios with:

1. Generic Unreal replication using push-model updates where appropriate.
2. Replication Graph.
3. Iris.

Iris and Replication Graph are mutually exclusive paths for this selection.
Neither is canonical until the benchmark records:

- Server game-thread and replication CPU.
- Client and server memory.
- Bandwidth per connection and total.
- Correction frequency and magnitude.
- Relevant actor count and actor-type mix.
- Dormancy, relevancy, prioritization, join-in-progress, and destruction
  behavior.
- Implementation and debugging complexity.
- Failure behavior during loss, stalls, overload, reconnect, and travel.

The actor mix includes players, AI, projectiles, persistent areas, objectives,
world-policy state, and representative cosmetic replication boundaries.
Measurements must distinguish editor from packaged builds.

The required two-client prototype establishes correctness and capture
instrumentation only. It does not establish player or actor density, instance
capacity, or a replication-technology selection. Selection requires equivalent
packaged candidate runs with the same actor mix and scenarios, followed by
reviewed evidence owned by Issues #2 and #45.

References:

- [Unreal Engine 5.8 release notes](https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-5-8-release-notes)
- [Migrating to Iris](https://dev.epicgames.com/documentation/en-us/unreal-engine/migrate-to-iris-in-unreal-engine)

## Latency-Compensation Evidence Gate

Before mandatory faction PvP, Issue #2 compares present-time server validation
with bounded server rewind for each eligible action family.

The spike covers:

- Swept melee volumes and multi-window attacks.
- Projectiles with server-owned trajectories.
- Directional block and dodge ordering.
- Moving, interrupting, and dying targets.
- Client timestamps mapped to the server clock.
- Timestamp clamping, history length, and discontinuities.
- Teleports, regional transfers, possession changes, and respawn.
- High latency, jitter, loss, duplication, and reordered input.
- Abuse cases such as forged old timestamps or view changes.

Rewind never accepts a client-selected target or claimed contact. The server
reconstructs bounded historical state, applies current policy and eligibility
rules, and records which validation mode produced the outcome.

History duration, eligible shapes, timestamp allowance, and precedence rules
remain `TBD` until the spike measures fairness, exploit surface, CPU, memory,
and player-facing corrections.

## Network Profiles and Evidence

Versioned profiles include:

- Clean local/reference conditions.
- Representative development latency and jitter.
- Representative packet loss and duplication.
- Harsh but supported validation conditions.
- Explicit unsupported or disconnect thresholds once evidence exists.

The repository must not invent numeric values before Issue #2 and
[Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45) record them.
Every result names build, hardware, topology, player/actor mix, map, duration,
and capture tooling.

## Automation and Manual Validation

The prototype requires:

- Packaged dedicated server and two packaged clients.
- Multi-process Gauntlet scenarios where automation supports the path.
- Unreal Insights and Networking Insights captures for representative runs.
- Focused automation for ability prerequisites, costs, cooldowns, effect
  application, death, respawn, and policy rejection.
- Invalid movement, aim, activation, hit, dodge, block, cooldown, and repeated
  command cases.
- Equivalence tests for male and female presentation variants when those assets
  exist.
- Manual feel/readability evidence where automation cannot judge the result.

Epic's
[network testing guidance](https://dev.epicgames.com/documentation/en-us/unreal-engine/testing-and-debugging-networked-games-in-unreal-engine)
is the starting point. Exact commands are added by Issues #13, #15, and #44
when the Unreal project exists.

## Failure and Recovery

- A disconnected client stops producing valid commands immediately.
- Reconnection creates a new authenticated connection and admission decision;
  it does not revive an old transport session by assertion.
- A dead or destroyed pawn cannot continue an active timeline unless the
  authored server rule explicitly permits a surviving server-owned effect.
- Join-in-progress receives current authoritative state, not a replay of
  unconfirmed client prediction.
- Version mismatch fails closed with an actionable safe error.
- An overloaded server rejects new work or admission before it silently stops
  enforcing authority.

## Open Decisions

- Replication implementation after the three-way benchmark.
- Present-time versus bounded-rewind policy by action family.
- Supported network-profile thresholds.
- Server tick and combat-history sampling.
- Projectile simulation representation at representative scale.
- Exact simultaneous-event ordering where game design has not resolved it.
- Ability-specific prediction and rollback eligibility
  ([candidate TC-008](architecture-decisions.md#candidate-decisions)).

These decisions require linked evidence and an accepted entry in
[Architecture Decisions](architecture-decisions.md).
