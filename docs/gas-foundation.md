# Gameplay Ability System Foundation

## Document Status

This is the implementation specification for
[Issue #19](https://github.com/ShayShimoni/aetheln-online/issues/19): a
PlayerState-owned Ability System Component (ASC), one combat attribute set, a
versioned activation seam, three ability skeletons, and the rejection
telemetry around them. It distils the design approved on the issue (revision 2,
after an independent review and a fix verification). Pull requests P2 to P6
deliver it in phases (see [PR Phasing](#pr-phasing-and-evidence)): P2 adds the
PlayerState-owned ASC, the attribute set, the init effect, the combat game mode,
the AI character base, and their tests; P3 adds the activation seam, the base
ability with its choke point, grant validation, and the rejection telemetry; P4
adds the cost and cooldown overrides, the shared effects, the three Oathscar
skeletons with their grant list and config, and their tests; the two-client
evidence follows in P5 and P6.

**Selected T1 contract (2026-10-09).** The lead selected #18's movement-carried
entry under delegated technical authority, recorded on
[#19](https://github.com/ShayShimoni/aetheln-online/issues/19#issuecomment-6085274596)
and [#18](https://github.com/ShayShimoni/aetheln-online/issues/18#issuecomment-6085274264).
The independent design review found it suitable with a required implementation
delta checklist, not implemented or accepted at runtime. Its retained report
is `technical-design-review.json`, SHA-256
`86680107c7b0651fc48b65343623d73ab2a78143d7f8a2440fd5c50b34ed20cb`.
That review disclosed earlier P2 movement-test authorship and did not freshly
approve those authored changes. The contract below amends the ordinary seam;
proposed entry/outcome names are not claims that APIs already exist. #18 P2
movement merged in [PR #282](https://github.com/ShayShimoni/aetheln-online/pull/282).
#60 P3's callback-safe operation and external-boundary integration and #19 P4
integration readiness remain prerequisites for #18 P3; this selection does not
satisfy them, the remaining product decisions, two-client PIE, or either whole
issue's acceptance criteria.

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
TA-002, TA-003, TA-004, and TA-021 in
[Architecture Decisions](architecture-decisions.md), and the canonical product
documents, and it changes no product rule. Every tuning value stays `TBD`; a
`Provisional...` config key is a named placeholder, never tuning. The Gameplay
Tag and content-version conventions are in
[Combat and Networking Architecture](combat-and-networking-architecture.md#gameplay-tag-and-content-version-conventions).
C++ names are proposed code names. Gate Step, Sworn Rebuke, Hold the Line,
Endurance, Guard, and Oathscar are working names, not final names.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `688b6b1`; citations into the combat document use section names,
because lines move. Engine citations are relative to the root of the pinned
UE 5.8.1 source, revision `71fe36aac5`
(`scripts/ci/Invoke-UnrealAutomationTests.ps1:12`). `GAS/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Source/GameplayAbilities/` and
`Runtime/` abbreviates `Engine/Source/Runtime/`.

## Decisions at a Glance

1. The player ASC lives on a new `AAethelnPlayerState` in Mixed replication
   mode. The possessed pawn is its avatar, null before the first possession.
   AI uses its own ASC on the pawn, in Minimal mode.
2. `APlayerState::OnPawnSet` drives the lifecycle. The GameCore pawn stays free
   of GAS.
3. One attribute set holds Health, Endurance, Guard, and each maximum. All six
   replicate to the owner only. Gameplay Effects make every change.
4. One activation authority has two selected entries: the ordinary versioned
   RPC and #18's server-internal movement-carried entry, called only while
   simulating an actual received CMC move. The ordinary schema-2 request carries
   bounded aim and a client server-time estimate, with no target, hit, contact,
   shape, range, window, or attribute field. Dodge carries neither ordinary
   sequence nor aim/time history; it cannot use the ordinary RPC.
5. The stock GAS activation routes are closed by two engine overrides and a
   choke point in the base ability. Every activation request draws from a
   per-connection rate bucket, and outcomes go to the owner only.
6. P2 to P5 merge without prediction. Predicting Hold the Line (P6) waits for
   an owner decision after the P5 feel test (candidate TC-008).
7. CI runs a frozen two-test filter, so P2 to P5 record local automation
   evidence. The spike classes are untouched.

The PlayerState network update frequency is raised to a provisional 100 Hz
under the config name `ProvisionalNetUpdateFrequency`; Issue
[#45](https://github.com/ShayShimoni/aetheln-online/issues/45) owns the final
value.

## Canon Anchors and Existing Code

Canon names five shared resources (Shared Combat Semantic Contract in the
combat document). The prototype uses Health, Endurance, and active Guard
(Prototype Boundary and Existing Owners; `docs/characters-and-factions.md:302-328`),
with stable IDs `combat.resource.health`, `combat.resource.endurance`, and
`combat.resource.guard`. Ward and OrderResource are not prototype runtime
scope, and nothing is reserved for them. Old "unnamed prototype combat
resource" wording remains in the roadmap
(`docs/next-steps-mmorpg-prototype.md:42`, `:265`), the scope ledger
(`docs/prototype-and-1.0-scope-ledger.md:102`), and Issue #61's body. Issue
[#115](https://github.com/ShayShimoni/aetheln-online/issues/115) owns that
cleanup (`docs/game-design-bible.md:285-291`); #19 does not edit it.

[Characters and Factions](characters-and-factions.md)
(`docs/characters-and-factions.md:313-319`) defines exactly three
representative actives, Gate Step, Sworn Rebuke, and Hold the Line, with their
stable IDs and canon summaries and with all tuning `TBD` (`:324-328`). The
combat document's conventions table maps their IDs to tags. #19 builds only
their skeletons: identity, activation, validation, cost, cooldown, and state
tags. Contacts, Guard pressure, interruption, movement, and attack windows
belong to Issue [#60](https://github.com/ShayShimoni/aetheln-online/issues/60);
dodge interplay belongs to Issue
[#18](https://github.com/ShayShimoni/aetheln-online/issues/18).

Existing code, as of `develop` `688b6b1`:

| Existing code | Disposition |
| --- | --- |
| Spike PlayerState, pawn hooks, and attribute set (`Source/GameCombat/Private/AethelnSpikePlayerState.cpp:7-38`; `Source/GameCombat/Private/AethelnSpikeCharacter.cpp:98-110`, `:143-149`; `Source/GameCombat/Private/AethelnSpikeAttributeSet.cpp:6-36`) | Reuse the patterns: default subobjects, `Mixed`, the clamp (`:12-19`), `REPNOTIFY_Always` (`:24-25`). Replace the classes: no unpossess handling, null avatar, or one-time init; no Endurance or Guard; hardcoded values (`:8-9`); public setters from `ATTRIBUTE_ACCESSORS_BASIC`; replicates to everyone; update frequency never raised, so the engine's stock 1 Hz applies (`Runtime/Engine/Private/PlayerState.cpp:28`). |
| Spike melee ability and damage effect (`Source/GameCombat/Private/AethelnSpikeMeleeAbility.cpp:6-29`; `Source/GameCombat/Private/AethelnSpikeDamageEffect.cpp:5-14`) | Leave for #2. Do not copy the ability: it never sets `NetSecurityPolicy`, so the engine default `ClientOrServer` applies (`GAS/Private/Abilities/GameplayAbility.cpp:104`). |
| Spike enemy (`Source/GameCombat/Private/AethelnSpikeEnemy.cpp:19-31`) | Reuse the pawn-ASC `Minimal` pattern in a new AI class. |
| Spike intent, validator, rejection, telemetry (`Source/GameCombat/Public/AethelnSpikeAuthorityTypes.h:7-71`; `Source/GameCombat/Public/AethelnSpikeAuthorityComponent.h:31-38`, `:57-58`, `:72-78`; `Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:29-45`, `:69-116`, `:375-471`, `:657-661`) | Reuse the public reason mirror with a private GameNet mapping (TA-021), the static pure validator, "advance on accept only" (`.cpp:470`), and the telemetry shape. Replace the five-field intent (no ability id or phase), the pawn-scoped sequence state (it resets with every pawn), and the rejection that replicates to everyone who sees the pawn. |
| Modules and harness (`Source/GameCombat/GameCombat.Build.cs:9-20`; `Source/GameCore/GameCore.Build.cs:11-13`; `Source/GameCombat/Private/AethelnNetworkSpikeAuthorityTests.cpp:117-120`, `:216-243`) | GameCombat already has its dependencies; GameCore gains `GameplayTags`. Reuse the test naming and the headless `UWorld::CreateWorld` harness. |

No gameplay tags are registered today; the spike uses the plain string
`Ability.Melee.Combo1`
(`Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:27`).

## Class Layout

Everything is in `GameCombat` except the native tags, which are in `GameCore`:
`docs/technical-architecture.md:155-157` assigns shared identifiers and tags to
GameCore, and GameUI may depend only on GameCore and presentation-safe combat
interfaces (`:157`), so the HUD (Issue
[#61](https://github.com/ShayShimoni/aetheln-online/issues/61)) can reach tags
only if they are declared in GameCore.

| Class or file | Module | Responsibility |
| --- | --- | --- |
| `AethelnGameplayTags.h/.cpp` | GameCore | Native tag declarations; adds `GameplayTags` to `GameCore.Build.cs`. |
| `AAethelnPlayerState` | GameCombat | Owns the player ASC and attribute set as default subobjects; implements `IAbilitySystemInterface`; sets the avatar to null before first possession; binds a `UFUNCTION` handler to its own `OnPawnSet`; validates and grants configured abilities once; applies initial attributes once; sets the provisional update frequency. |
| `UAethelnAbilitySystemComponent` | GameCombat | Project ASC for players and AI. Hosts the activation seam (request RPC, validator, per-connection sequence and rate state, seam scope with result slot, owner-only outcome RPC). Overrides the two stock client-route entry points. Provides static `FindForPawn(const APawn*)`. |
| `UAethelnCombatAttributeSet` | GameCombat | `Health`, `MaxHealth`, `Endurance`, `MaxEndurance`, `Guard`, `MaxGuard`. |
| `AethelnActivationTypes.h` | GameCombat | `FAethelnCombatActivationRequest`, `EAethelnActivationPhase`, `EAethelnActivationResult` (client-facing mirror of the safe reasons). |
| `UAethelnGameplayAbility` (abstract) | GameCombat | Base ability: reads config, overrides `CheckCost`, `ApplyCost`, `GetCooldownTags`, `ApplyCooldown`, `CanActivateAbility` (the choke point), and `CommitAbility` (records the seam's result slot), refuses the partial `CommitAbilityCost` and `CommitAbilityCooldown`, fixes the net and instancing policies, leaves the engine cost and cooldown effect classes null. |
| `AethelnOathscarAbilities.h/.cpp` | GameCombat | `UAethelnGateStepAbility`, `UAethelnSwornRebukeAbility`, `UAethelnHoldTheLineAbility` skeletons. |
| `AethelnCombatEffects.h/.cpp` | GameCombat | `UAethelnCooldownEffect`, `UAethelnEnduranceCostEffect`, `UAethelnAttributeInitEffect` (maxima first). All magnitudes set by caller. |
| `AAethelnCombatGameMode` | GameCombat | Derives from `AGameModeBase` (for example through `AAethelnGameModeBase`), never `AGameMode`: `AGameMode::FindInactivePlayer` (`Runtime/Engine/Private/GameMode.cpp:687-751`) would reuse the old PlayerState on reconnect, which breaks the sequence policy and T34. A later base-class change must revisit both. Sets `PlayerStateClass`. The input-enabled pawn is a generated Blueprint, so P5 selects it by extending `scripts/build_movement_poc.py`, a config soft-class path, or a `?game=` URL, never by editing binary assets by hand. |
| `AAethelnCombatAICharacter` | GameCombat | Base for Issue [#20](https://github.com/ShayShimoni/aetheln-online/issues/20)'s enemy: its own ASC in Minimal mode and its own attribute set. |

### Why Mixed for players and Minimal for AI

- Minimal mode does not work for owned ASCs
  (`GAS/Public/AbilitySystemComponent.h:81-89`, note at `:83`); Full would send
  every player's effect list to every client.
- In Mixed mode the active-effects container replicates owner-only on the
  server (`GAS/Private/GameplayEffect.cpp:5183-5213`), with ownership resolved
  through the PlayerState's controller (`:5225-5240`). The owner gets full
  effect data, including cooldown time remaining; non-owners get only tags
  (`MinimalReplicationTags`, `COND_SkipOwner`,
  `GAS/Private/AbilitySystemComponent.cpp:1874`), so the cooldown tag still
  reaches them. Granted specs replicate to the owner only (`:1861-1862`).
- The attribute set must be a default subobject of the ASC's owner actor
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:78-108`), so it is created
  in the PlayerState's constructor.
- The engine updates a PlayerState at 1 Hz and keeps it always relevant
  (`Runtime/Engine/Private/PlayerState.cpp:26-28`), and GAS forces a net update
  only on effect removal and cue add, not instant attribute changes. Hence the
  provisional 100 Hz.
- AI uses Minimal, as the spike enemy does
  (`Source/GameCombat/Private/AethelnSpikeEnemy.cpp:21`).

### Owner and avatar rules

- **Owner:** the PlayerState for players, the pawn for AI. It never changes
  while the ASC exists.
- **Avatar before first possession: null.** The ASC's own `InitializeComponent`
  would make the PlayerState its avatar
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:84`), which
  `CanActivateAbility` would accept
  (`GAS/Private/Abilities/GameplayAbility.cpp:461-466`). So
  `PostInitializeComponents` calls `InitAbilityActorInfo(this, GetPawn())` on
  the server and on clients; `GetPawn()` is null there.
- **Avatar afterwards:** the pawn the PlayerState currently has, or null. Only
  the server chooses it; clients follow the replicated `OwnerActor` and
  `AvatarActor` (`GAS/Private/AbilitySystemComponent.cpp:1856-1857`;
  `OnRep_OwningActor`, `GAS/Private/AbilitySystemComponent_Abilities.cpp:263-283`).
- **Clear with `SetAvatarActor(nullptr)`** (`:249-253`), never `ClearActorInfo`
  (`:255-261`), which also clears the owner and breaks `IsNetAuthority`
  (`GAS/Private/GameplayAbilityTypes.cpp:139-151`).
- **No cached raw pointers.** `AbilityActorInfo` holds weak pointers, so a
  destroyed avatar reads as null and `CanActivateAbility` fails closed. The
  seam scope holds weak pointers only.

### Pawn to ASC lookup and AI

`UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(Pawn)` returns null
for a pawn with neither `IAbilitySystemInterface` nor an ASC component
(`GAS/Private/AbilitySystemGlobals.cpp:232-252`), which describes the GameCore
pawn. `FindForPawn` resolves pawn, then `GetPlayerState()`, then its
`IAbilitySystemInterface`; otherwise the pawn's own ASC (AI). #20 and #60 share
that lookup, and GameCore stays free of GAS.

The AI character creates its ASC and attribute set as default subobjects of
the pawn. `InitializeComponent` already makes the pawn owner and avatar,
`PossessedBy` calls `RefreshAbilityActorInfo`
(`GAS/Private/AbilitySystemComponent_Abilities.cpp:286-290`), and the server
applies initial attributes once in `BeginPlay`. AI never uses the request seam:
it has no owning connection, the choke point exempts its non-PlayerState ASC,
and server code (#20) activates its abilities directly.

## Lifecycle

`APlayerState::OnPawnSet` fires from `FSetPlayerStatePawn`
(`Runtime/Engine/Classes/GameFramework/PlayerState.h:438-450`) on server
possession (`Runtime/Engine/Private/Pawn.cpp:671-688`), server unpossession
(`:713-719`, only if the PlayerState's pawn is this pawn, `:656-659`), and on
clients through `OnRep_PlayerState` (`:647-669`). The delegate is dynamic
(`PlayerState.h:34`, `:134-135`), so the handler is a `UFUNCTION` bound in
`PostInitializeComponents`. All ASC lifecycle code stays in one GameCombat
class.

Engine facts the handler respects:

- **The server never sees a direct pawn-to-pawn switch.** The old pawn is
  unpossessed first (`Runtime/Engine/Private/PlayerController.cpp:880-890`;
  `Runtime/Engine/Private/Controller.cpp:356-363`), so it sees new-to-null,
  then null-to-new. Clients may see a direct switch.
- **The controller still points at the old pawn during the handler**
  (`PlayerController.cpp:890` runs before `SetPawn` at `:895`). Never read
  `Controller->GetPawn()` there.
- **Destroying a possessed pawn fires the null case first** on the server and
  owning client (`Pawn.cpp:550-554`, `:1112-1123`). Non-owning clients get no
  null broadcast when the channel closes
  (`Runtime/Engine/Private/PlayerState.cpp:556-562`); the replicated null
  avatar reaches `OnRep_OwningActor` instead.

| Server event | Action |
| --- | --- |
| `PostInitializeComponents` | `InitAbilityActorInfo(this, GetPawn())` (avatar null). Bind the handler. |
| `OnPawnSet`, new pawn non-null | 1. `InitAbilityActorInfo(this, NewPawn)`. 2. If the server-only flag `bCombatStateInitialized` is false: validate and grant the configured abilities, apply `UAethelnAttributeInitEffect`, set the flag. Keyed on the flag only, never on `OldPawn`. 3. The seam becomes ready. |
| `OnPawnSet`, new pawn null (unpossess, or destroy while possessed) | 1. `CancelAllAbilities()` (`GAS/Private/AbilitySystemComponent_Abilities.cpp:1374-1384`). 2. `SetAvatarActor(nullptr)`, only when `GetAvatarActor() == OldPawn` or `OldPawn` is null (it can be null after an `EndPlay` detach). 3. The seam rejects with `ConnectionClosed` until the next avatar. |
| Re-possession (for example respawn) | The null case, then the non-null case. The flag stops a second grant or init, so it never refills Health or resets cooldowns. |
| Avatar destroyed without unpossession | The seam checks avatar validity and `IsActorBeingDestroyed` on every request and rejects with `ActorDestroyed`. |
| PlayerState destroyed or logout | `OnUnregister` calls `DestroyActiveState` (`GAS/Private/AbilitySystemComponent.cpp:236-251`). Nothing extra except flushing pending telemetry (see Rejection Telemetry). |

`InitAbilityActorInfo` does not cancel abilities when the avatar changes (it
only calls `OnAvatarSet`, `GAS/Private/AbilitySystemComponent_Abilities.cpp:182-204`),
which is why the cancel in the null case is explicit. Granted abilities,
cooldown effects, attribute values, and the seam's sequence and rate state
persist across avatar changes.

T1 extends cleanup to the movement-carried operation and its pending outcome
delegates: cancel the actual operation before losing the old avatar, close its
window/boundaries and end its server displacement once. Revalidate identity
across synchronous callbacks so cleanup cannot cancel a replacement. It does
not reset the shared limiter or ordinary accepted history, change ASC ownership,
re-grant abilities, or revive a window on re-possession.

**Client.** `PostInitializeComponents` sets the null avatar locally. The
authoritative path is the engine's replication of `OwnerActor` and
`AvatarActor`. The client's `OnPawnSet` handler also calls
`InitAbilityActorInfo(this, NewPawn)` for a non-null pawn, covering the race
where the pawn arrives before or after the PlayerState; both converge on the
server's value. Nothing authoritative reads client actor info, and in P2 to P5
the client runs no abilities.

**Handoff to #21.** Issue
[#21](https://github.com/ShayShimoni/aetheln-online/issues/21) owns death,
respawn, reconnect, and stale-state cleanup. #19 guarantees that abilities are
granted once per PlayerState and survive avatar changes; cooldowns and
attribute values persist across avatar changes (what respawn clears or
restores is #21's explicit allowlist, per Lifecycle restoration in the combat
document); avatar loss cancels every active ability; and `State.Dead` is
declared by #19, blocks every #19 ability, and is applied or removed only by
#21. #19 adds no empty "reset for respawn" hook.

## Attribute Policy

| Actor | May change attributes? | How |
| --- | --- | --- |
| Client | Never | No RPC accepts an attribute, magnitude, cost, cooldown, or effect. Attributes replicate down only. |
| Server GAS | Yes | `UAethelnAttributeInitEffect` (once), `UAethelnEnduranceCostEffect` (commit), and #60's and #21's damage and restoration effects later. |
| Server C++ outside effects | No | No public setters. The only direct writes are the set's own clamps, through a protected setter. Reviewers reject `SetNumericAttributeBase` on combat attributes. |
| Client prediction (P6 only) | Temporary, local | GAS applies a predicted instant effect as a temporary infinite-duration modifier and removes it on confirm or reject (`GAS/Public/GameplayPrediction.h:113-132`). |

- **No meta "incoming damage" attribute.** Damage resolution in the shared
  defense order is #60's.
- **Initial values are `TBD`.** They reach the set only through the init
  effect, with set-by-caller values read from `Provisional...` config keys.
- **Ordering trap.** Every attribute starts at 0, so every maximum is 0 until
  init runs, and a current value set before its maximum clamps to 0. The init
  effect therefore lists every maximum modifier before any current value (T9).
- **Clamping.** `PreAttributeChange` and `PreAttributeBaseChange` clamp each
  current value to `[0, Max]` and each maximum to `>= 0`;
  `PostGameplayEffectExecute` clamps again after instant effects. When a
  maximum drops, `PostAttributeChange` on that maximum re-clamps the current
  value (`GAS/Public/AttributeSet.h:223`), because the current value's own
  `PreAttributeChange` does not fire. A current value is never scaled up.
  **The re-clamp only lowers** (owner decision on #19, 2026-10-05): it writes
  the base as the lower of the new maximum and the existing base, so lowering a
  maximum never raises a base value, even while a positive temporary modifier
  holds the current value above the base. Rewriting an unchanged base still
  re-evaluates the current value, which its own clamp then lowers. The clamp
  after instant effects follows the same rule.
- **Replication:** all six use `COND_OwnerOnly` with `REPNOTIFY_Always`. Canon
  says opponent cues must not expose exact unrevealed resources (Secure
  Stealth and Opponent Readability in the combat document). Owner-only fails
  closed and is easy to widen; #61 decides later what opponents may see. Other
  clients still get death from #21's replicated state and hit results from
  cues. `REPNOTIFY_Always` lets prediction reconcile later
  (`GAS/Public/GameplayPrediction.h:122-132`).
- **Resource contract mapping** (Shared Combat Semantic Contract in the combat
  document). The authored bound is the matching `Max*` attribute. The mutation
  reason is the applying effect class: init and cost here, with #60 and #21
  adding theirs. The per-resource content version is `TBD` with #106.
- **No identity data.** Race, sex, and appearance are never inputs to any
  attribute, effect, or ability. Faction and Faction Doctrine inputs are outside
  #19's scope; canon Doctrine abilities arrive in a later stage.

## Abilities

All three derive from `UAethelnGameplayAbility`.

- **Policies:** `InstancedPerActor`, `NetExecutionPolicy = ServerOnly`,
  `NetSecurityPolicy = ServerOnly`. The engine itself then rejects client
  requests to execute, end, or cancel
  (`GAS/Public/Abilities/GameplayAbilityTypes.h:79-96`;
  `GAS/Private/AbilitySystemComponent_Abilities.cpp:2087-2093`, `:2147`,
  `:2227`, `:2253`).
- **Config** (`UCLASS(Config=Game)`, one section per ability in
  `Config/DefaultGame.ini`; ini now, generation from Issue
  [#106](https://github.com/ShayShimoni/aetheln-online/issues/106) later):
  `ContentVersion`, `ProvisionalEnduranceCost` (optional, `TBD`),
  `ProvisionalCooldownSeconds` (`TBD`), `bAcceptsRelease`. The prefix follows
  the spike (`Source/GameCombat/Public/AethelnSpikeAuthorityComponent.h:60-70`).
  Identity, cooldown tag, and activation tag rules are structure in the C++
  constructor. Until #107 and #45 decide, each section sets `ContentVersion=1`
  and both placeholders to 0, which means no cost and no cooldown; automation
  tests set their own values on the granted instances. `AAethelnPlayerState`
  grants the three, in order, from `+GrantedAbilities` entries in its own
  section.
- **`State.Dead`** blocks every project ability: the base constructor adds it
  to `ActivationBlockedTags`.
- **Phase:** Press only by default; `bAcceptsRelease = false` for all three.
- **`CostGameplayEffectClass` and `CooldownGameplayEffectClass` stay null.**
  The overrides apply the shared effects directly, so the engine's cost check
  never evaluates set-by-caller magnitudes that have no value.
- **`ActivateAbility`** calls `CommitAbility`, writes the outcome (committed or
  not) and the server `ActivationId` into the seam scope's result slot, then
  calls `EndAbility`; #60 replaces the end with its timeline. `CommitAbility`
  is the only commit: an ability commits once, synchronously, inside
  `ActivateAbility`. The partial `CommitAbilityCost` and `CommitAbilityCooldown`
  (and their Blueprint versions) are refused and apply nothing. If the
  activation has not committed when `TryActivateAbility` returns, the seam
  cancels it and reports `InternalFailure`. That cancel is only a fallback:
  `CancelAbility` does nothing for an ability that marks itself non-cancelable
  (`GAS/Private/Abilities/GameplayAbility.cpp:743`), so a project ability ends
  itself directly with `EndAbility`, as the seam's `EndForRelease` does, whether
  or not its commit succeeded. A C++ subclass could still call `ApplyCost`,
  `ApplyCooldown`, or `CommitExecute` directly, which Blueprint cannot; review
  refuses that, so `CommitAbility` stays the only spend. The three skeletons do
  not override `ActivateAbility`; they inherit the base one, which follows both
  rules, and T17 pins them. Hold the Line may
  later hold its own state tag while active, `State.<Order>.<Name>` under the
  conventions (for example `State.Oathscar.HoldTheLine`, a technical
  identifier, not a display name). The PR that creates it adds it to the
  Initial entries table. Hold the Line's duration-or-hold behavior is `TBD`.

**Grant-time validation.** `AAethelnPlayerState` refuses to grant, and logs,
any configured class that:

- does not derive from `UAethelnGameplayAbility` (a plain `UGameplayAbility`
  subclass would bypass the choke point);
- is not InstancedPerActor, or not ServerOnly in both net policies;
- lacks a valid `Ability.` identity tag, or has a `ContentVersion` of 0;
- has a cost or cooldown that is non-finite or negative;
- has non-empty `AbilityTriggers` (`GAS/Public/Abilities/GameplayAbility.h:727`)
  or sets `bReplicateInputDirectly` (`:480`); or
- would be granted with a spec `InputID` other than `INDEX_NONE`, or with
  spec-level `DynamicAbilityTriggers`.

This also catches a future Blueprint subclass that edits policies or values.

For #18 T1, grant validation also requires a movement-carried ability to be
Press-only with `bAcceptsRelease = false`, preserving the ServerOnly policies,
InstancedPerActor, no triggers, no spec input id, and no direct input
replication. The dodge's finite, ordered definition and cost-or-cooldown rule
must be checked through the actual PlayerState grant path (see
[Dodge grant validation](dodge-and-block.md#server-owned-windows), including
the unresolved Q4 choice). `FindGrantProblem` is non-virtual at the reviewed
GAS baseline `63f43184c6a775080f337152f1f694286df55d17`: a hidden derived method
cannot satisfy this contract when the caller holds a base ability pointer.
Implementation must introduce a reviewed virtual hook or an equivalent
integrated check that reaches the specialized definition from that caller.

**Cost and cooldown.** One shared `UAethelnCooldownEffect` takes its duration
from `SetByCaller.Cooldown.Duration`. `ApplyCooldown` adds the ability's
`Cooldown.<Order>.<Name>` tag to the spec's `DynamicGrantedTags`
(`GAS/Public/GameplayEffect.h:1238-1240`), and `GetCooldownTags` returns it, so
the engine's `CheckCooldown` works unchanged
(`GAS/Private/Abilities/GameplayAbility.cpp:1064-1104`). One shared
`UAethelnEnduranceCostEffect` is instant, with a negated Endurance modifier
from `SetByCaller.Cost.Endurance`; `ApplyCost` applies it with the activation's
prediction key (always a server key in P2 to P5). A Guard or other cost is
added only when a canon ability spends that resource. `CommitAbility`
re-checks and applies both. A zero cost or a zero cooldown applies no effect:
a duration effect without a positive duration gets no expiry timer
(`GAS/Private/GameplayEffect.cpp:4438-4441`), so it would never end. Recovery
windows, cooldowns, and resource recovery are separate states, and resource
recovery is not #19 scope.

### Prediction

P2 to P5 predict no GAS ability state. #18's supported CMC displacement
prediction is separate: no predicted GAS cost, cooldown or window is enabled
by T1. The stock client activation RPC carries only a spec
handle, an input flag, and a prediction key
(`GAS/Public/AbilitySystemComponent.h:1724-1725`), so the versioned request
cannot ride on it, and activating from the seam leaves the client no
prediction key. The acceptance criterion allows prediction only for reversible
paths with tested rollback, so without P6 the tests prove nothing is
predicted. The client shows nothing authoritative until the server accepts;
the reliable owner outcome tells #61 and Issue
[#97](https://github.com/ShayShimoni/aetheln-online/issues/97) when to cancel
optimistic presentation.

Whether #19 can close without P6 is an owner decision after the P5 two-client
PIE feel test, recorded as candidate TC-008. If approved, P6 predicts only Hold
the Line's activation, Endurance cost (if it has one), cooldown, and own state
tag: self-only
and reversible, with no contact, Guard result, or damage predicted (Prediction
Matrix in the combat document). The mechanism uses only engine hooks:

- Hold the Line becomes `LocalPredicted` with `ServerOnlyTermination`: a client
  may request execution but never end or cancel it. Grant validation accepts
  that pair only for abilities on the approved prediction list (T15 and T20
  change to match).
- On the client, `RequestActivation` opens a seam scope (so the choke point
  passes), sets the flag `ShouldDoServerAbilityRPCBatch()` reads, and only then
  builds `FScopedServerAbilityRPCBatcher`, which reads the flag in its
  constructor (`GAS/Private/AbilitySystemComponent_Abilities.cpp:4163-4173`).
  The ASC overrides virtual `EndServerAbilityRPCBatch`
  (`GAS/Public/AbilitySystemComponent.h:1306`) to send one project RPC,
  `ServerSubmitPredictedActivation(Request, PredictionKey)`.
- On the server, run steps 1 to 8. Reject with
  `ClientActivateAbilityFailed(Handle, PredictionKey.Current)`, which rolls the
  client back (`GAS/Public/GameplayPrediction.h:84-94`), and send the outcome;
  accept through `Super::InternalServerTryActivateAbility` inside the seam
  scope. P6 adds that exemption to the override, which refuses unconditionally
  until then.
- P6's first task is a compile-level check that the override reaches the batch
  data: `LocalServerAbilityRPCBatchData` is declared in a `public:` section
  (`GAS/Public/AbilitySystemComponent.h:1280`), at `:1309`. If batching is
  fragile, send the seam request first and let the engine's own activation RPC
  follow on the same ordered channel. The server pairs the engine activation
  with the validated pending request and refuses any activation without one.
  This uses two messages and keeps per-handle pending state.

## Activation Seam

```cpp
UENUM()
enum class EAethelnActivationPhase : uint8 { Press = 0, Release = 1 };

/** Client intent only. No target, hit, contact, damage, magnitude, cost, cooldown, shape, range, window or attribute field. */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatActivationRequest
{
	GENERATED_BODY()

	UPROPERTY() uint8 SchemaVersion = 2;      // layout version of this struct
	UPROPERTY() FGameplayTag AbilityId;       // Ability.<Order>.<Name>
	UPROPERTY() uint32 ContentVersion = 0;    // authored definition the client built for
	UPROPERTY() EAethelnActivationPhase Phase = EAethelnActivationPhase::Press;
	UPROPERTY() uint32 Sequence = 0;          // per connection, one PlayerState lifetime, never wraps
	UPROPERTY() FVector_NetQuantizeNormal Aim = FVector_NetQuantizeNormal(ForceInitToZero);
	UPROPERTY() double ClientServerTimeSeconds = 0.0;
};
```

- **Phase.** Canon lists "press, release, or charge state" (Pure Free Aim in
  the combat document). No prototype ability charges, so Charge is absent;
  adding it later is an append plus a `SchemaVersion` bump.
- **Transport.** `UFUNCTION(Server, Reliable) ServerSubmitActivation` on
  `UAethelnAbilitySystemComponent`. The PlayerState belongs to the client's
  controller, so only the owning connection can call it. The client entry
  point `RequestActivation(AbilityId, Phase)` fills in the sequence, local
  content version, owning controller's control-rotation aim and the GameState's
  server world time (local world time without a GameState). It flushes held
  character moves before sending, as a mitigation for the lagging server
  rotation. It cannot bypass validation and remains non-Blueprint-callable.
- **Activation id.** The ability creates `ActivationId` (a GUID scoped to the
  instance, as the spike does at
  `Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:431`) and
  writes it, with the sequence, into the seam scope's result slot. #60 builds
  the full `CombatActivation` record (CombatActivation Contract in the combat
  document) from them. The request is input, not that record.
- **Territory policy** is a 2.x system and is not checked in #19. It will be
  checked in the seam after step 7 and again at every effect application
  (Combat Invariants in the combat document).

### Selected movement-carried entry

The proposed native `ProcessMovementCarriedRequest` is server-internal, not an
RPC, Blueprint entry, or a client-selected ability route. GameCore calls its
plain movement-authority interface; the PlayerState adapter and ASC must resolve
the currently owned dodge grant and actual possessed avatar in the shared
pipeline, with the token drawn before ability lookup. A received flagged move
must pass the CMC authority, current
network-move-data, timestamp-order and positive-delta gates. Forced position
updates, client replay, old avatars and avatar reassignment cannot start an
activation. The start predicate supplied by movement is a server-derived fact,
never arbitrary client `bMovementAllowsStart` authority. Standalone and
listen-host authority copies without received moves remain outside this
dedicated-server route.

The entry uses the validation substitutions below, the same one-spec scope,
eligibility checks and full commit as the ordinary entry. Before either entry
validates, apply the requester's due #60 boundaries to the server processing
time. #60 P3 must supply reviewed external-boundary registration and operation
lifetime protection; this document names no new boundary API. Dodge windows
are authored half-open intervals from that processing time, never from the
client timestamp or prediction.

### Outcome and client rules

`UFUNCTION(Client, Reliable) ClientActivationOutcome(uint32 Sequence,
EAethelnActivationResult Result)` goes to the owner only, which closes the
spike's replicate-to-everyone rejection. It is reliable because, with
server-only abilities, it is the only correction signal: a lost rejection would
leave optimistic presentation stuck. The cost is bounded: one outcome per
request, the bucket bounds requests, and a rate-limited window sends at most
one outcome.

Rules for the client, written for #61 and #97:

These sequence rules apply only to the ordinary RPC. T1 uses a dedicated
reliable owning-client movement outcome (proposed
`ClientMovementActivationOutcome`, carrying a typed activation result and the
move timestamp). Its pending-move correlation is timestamp plus send order;
it never calls `ClientActivationOutcome` with sequence 0. The separate nonzero
PlayerState movement ordinal is telemetry correlation, not a new client
request sequence or a cure for timestamp-reset aliases. See
[Movement outcome rules](dodge-and-block.md#replication-and-outcome-reporting)
and [residual risk 8](dodge-and-block.md#residual-risks-and-known-gaps).

- **Outcomes arrive reliably and in order.** After a `RateLimited` outcome for
  sequence N, treat every later pending request as rate-limited and show no
  optimistic presentation for it. An outcome for any later sequence means every
  earlier pending request that never got an outcome was suppressed.
- **Do not use `CanActivateAbility` as a readiness query.** On a client the
  choke point makes it false for every player ability. HUD readiness comes
  from the cooldown and cost checks or from replicated tags.

### Validation order

Cheap structural checks run first, so nothing is spent or granted on a request
that fails. Each rejection has one reason, and precedence is deterministic.

| Step | Check | Rejection result |
| --- | --- | --- |
| 1 | Per-connection token bucket; capacity and refill come from `Provisional...` config placeholders (values `TBD`, #45 owns the final ones). Every activation request counts, malformed ones included, and so does every refused stock-route call (see Closing the Stock Routes). It runs before any lookup. | `RateLimited` |
| 2 | Lifecycle: the ASC has an avatar, it is the PlayerState's current pawn, possessed by its controller, and not being destroyed | `ConnectionClosed` (no avatar or unpossessed) / `ActorDestroyed` |
| 3 | `SchemaVersion` matches exactly | `IncompatibleVersion` |
| 4 | Sequence: zero or lower than the last accepted / equal to it. Forward gaps are accepted. | `StaleSequence` / `DuplicateSequence` |
| 5 | `AbilityId` is a valid `Ability.` tag naming a spec granted to this ASC | `MalformedRequest` (unknown) / `ActivationBlocked` (known, not granted) |
| 6 | `ContentVersion` matches the granted ability's config exactly | `IncompatibleVersion` |
| 6a | Aim/time config is valid; client server-time sample is finite, within age/lead bounds and regression tolerance | `InternalFailure` (bounds) / `TimestampOutOfBounds` (sample) |
| 6b | Finite, non-zero, unit aim within tolerance, with a defined great-circle direction if correction is needed | `MalformedRequest` |
| 6c | Raw aim is within the hard angular bound of server control rotation | `ImpossibleAimTransition` |
| 6d | Raw aim change is within the rate bound and separate slack over the nonnegative client-time interval; first accepted request skips this check | `ImpossibleAimTransition` |
| 7 | Phase and instance state (below) | `ActivationBlocked` (already active) / `MalformedRequest` (unsupported phase) |
| 8 | Engine eligibility: call the ability's `CheckCooldown`, `CheckCost`, and `DoesAbilitySatisfyTagRequirements` directly, in the engine's order, and take the reason from the first to fail | `OnCooldown` / `InsufficientResource` / `ActivationBlocked` |
| 9 | Activate on the server inside the seam scope. `CommitAbility` re-checks and applies cooldown and cost. The seam reads the result slot, not the return value of `TryActivateAbility`. | `ActivationBlocked` (refused for a reason step 8 does not cover) / `InternalFailure` (activated but not committed) |
| 10 | Advance last accepted sequence, raw aim and client time; emit any aim correction before the accepted event with the same activation id, then send one owner outcome | `Accepted` |

- **Step 7.** A `Press` while the ability's single instance is active is
  blocked here, so the reason is deterministic and precedes commit (the engine
  would refuse later: `GAS/Private/AbilitySystemComponent_Abilities.cpp:1831-1850`).
  A `Release` is valid only if `bAcceptsRelease` is set and the instance is
  active: an undeclared Release is `MalformedRequest`, and a declared Release
  while the instance is not active is `ActivationBlocked`. **A valid Release is
  an accepted request:** it ends the instance,
  skips steps 8 and 9, and runs step 10, so the sequence advances, the owner
  gets `Accepted`, and the event carries the running activation's id. A
  replayed Release then fails step 4.
- **Step 8 uses no failure tags.** The three checks are public virtuals
  (`GAS/Public/Abilities/GameplayAbility.h:285`, `:357`, `:363`), called in
  the engine's own order (cooldown at `GAS/Private/Abilities/GameplayAbility.cpp:508`,
  cost `:518`, tags `:528`). The cooldown, cost, and tag-requirement
  failure-tag keys moved from `AbilitySystemGlobals` to the GAS developer
  settings in 5.5 (`GAS/Public/AbilitySystemGlobals.h:187-234`); step 8 does not
  need them, so none is configured. **Cheat variables:** the engine wraps its checks in
  `ShouldIgnoreCooldowns` and `ShouldIgnoreCosts` (`GameplayAbility.cpp:508`,
  `:518`, and in `CommitCheck` at `:671`, `:676`); the seam does not. With the
  cheats on in a non-shipping build the seam rejects where the engine would
  allow, which fails closed (T16).
- **State.** `State.Dead` (applied by #21) and an action-state tag held by
  another active ability are activation-blocked tags checked in step 8. Which
  abilities block which is content data and `TBD` (#60 and #18).
- **Resource bounds.** The engine's cost check cannot see set-by-caller values
  (`GAS/Private/GameplayEffect.cpp:5497-5528`), so `CheckCost` checks bounds
  itself: the configured cost is finite and `>= 0`, and current `Endurance` is
  at least the cost. A cost above `MaxEndurance` is a content error caught by a
  test.
- **Commit failure.** On the server `TryActivateAbility` returns true once
  `ActivateAbility` has been called, even if the commit then fails
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:1682`), so the result slot
  decides between `Accepted` and `InternalFailure`. A failed commit applies
  nothing and does not advance the sequence.
- **Pure validator.** Step 1 is a token bucket that takes the server time as an
  input and runs before any lookup. Steps 2 to 7 are a static pure function,
  modeled on the spike's, taking the request and the server and instance state
  as inputs. Both are headless table-testable.

**T1 validation substitutions.** Split shared lifecycle, grant identity,
content-version and phase/instance checks into pure helpers used by both
entries. Keep ordinary schema, sequence and aim/time checks in `ValidateRequest`.
The movement entry never synthesizes a `FAethelnCombatActivationRequest`, calls
that request-only validator, or advances ordinary accepted history.

| Ordinary step | Movement-carried contract |
| --- | --- |
| 1 | Every received flagged move the server actually simulates draws one token from the same connection bucket before lookup, including invalid-start, version and lifecycle cases. CMC-dropped/zero-delta copies draw none because the entry is not called. |
| 2 | Same lifecycle check against the current owned avatar. |
| 3 and 4 | No ordinary schema or sequence. Build-identical move data and the engine's received-move timestamp ordering apply. |
| 5 and 6 | Resolve the current granted movement-carried dodge; exact move content version must match its definition. An ordinary RPC naming a movement-carried grant is `MalformedRequest`. |
| 6a to 6d | No ordinary aim or time sample; neither check nor accepted-history update runs for movement. |
| 7 | Press-only, inactive instance and live movement start predicate; active, airborne or already-displacing starts are `ActivationBlocked`. |
| 8 and 9 | Same cooldown, cost, tag precedence, cheat-independent eligibility and one-spec full commit. |
| 10 | Typed movement outcome and nonzero server ordinal; `LastAcceptedSequence`, raw aim and client time remain unchanged. |

**Operation and commit checklist.** Both entries must use #60 P3's reviewed
operation/epoch and callback-safe context lifetime. Keep the scope bound to the
resolved spec, record at most one successful full `CommitAbility`, and refuse
partial commits and commits through another spec or stock route. The merged
GAS baseline's mutable boolean result slot alone is insufficient: synchronous
cost, tag, cancellation or avatar callbacks can replace or end an operation
before commit returns. Revalidate the actual operation and avatar after those
callbacks; neither open a stale dodge window/displacement nor cancel a valid
replacement. Rejecting before commit leaves no spend, cooldown, tags or
activation id; later cancellation must follow a future owner-selected refund
policy, not a fabricated rollback. Q16's truncated-displacement refund and
#60 OQ5's queued/interrupted refund policy remain unresolved; T1 selects neither.
`State.Dead`, unpossession, avatar loss and
PlayerState teardown cancel the actual operation, close its boundaries and end
server displacement once. Re-possession revives none of them. See
[T1 implementation checklist](dodge-and-block.md#technical-decision-t1-the-movement-carried-seam-entry).

**Sequence policy.** The sequence advances only on acceptance (a valid Release
included), accepts forward gaps, never wraps, and lives for one PlayerState
lifetime. A client that jumps to the maximum only makes its own later requests
stale. With the `AGameModeBase` base class pinned in Class Layout, a reconnect
gets a new PlayerState and starts at 1 (see Known Interim Gaps).

**Input-contract findings** (numbers from the Issue
[#82](https://github.com/ShayShimoni/aetheln-online/issues/82) review). The
seam closes F9 (no ability id or phase), F6 (rejection replicated to everyone),
and F3 (no rate limit) for itself; #60 still owns window and combo gating, and
T14 replaces #82's planned spike test
`Aetheln.GameCombat.NetworkSpike.RequestRateBound`. F1 and F2 (aim equality and
angular or temporal bounds) are addressed by #60 P2's schema-2 aim/time checks
and bounded correction policy. The eight config values remain unset/`TBD`;
every request fails closed until reviewed values are supplied. P3 carries
accepted aim through the activation scope. The threat
model's CM-04 and CM-07 rows map onto steps 1 to 8 and step 9
(`docs/staged-multiplayer-threat-model.md:87`, `:90`).

## Closing the Stock Routes

The pinned engine has two groups of routes that can activate a granted ability
with no project check.

- **Client RPC routes.** On a client, `TryActivateAbility` still forwards a
  `ServerOnly` ability with `CallServerTryActivateAbility`
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:1660-1668`). The server
  handler `InternalServerTryActivateAbility` is virtual
  (`GAS/Public/AbilitySystemComponent.h:1763`) and rejects client activation
  on `NetSecurityPolicy` only
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:2054-2125`, check at
  `:2087-2093`). It is reached from `ServerTryActivateAbility_Implementation`
  (`:2016-2018`), `ServerTryActivateAbilityWithEventData_Implementation`
  (`:2026-2028`), and the batch route `ServerAbilityRPCBatch_Internal`
  (virtual at `GAS/Public/AbilitySystemComponent.h:1315`; called at
  `GAS/Private/AbilitySystemComponent_Abilities.cpp:4194-4198`), which also
  forwards client `TargetData` into the target-data cache (`:4199`).
- **Server-internal routes** call the non-virtual `InternalTryActivateAbility`
  (`GAS/Public/AbilitySystemComponent.h:1189`): `GiveAbilityAndActivateOnce`
  (`GAS/Private/AbilitySystemComponent_Abilities.cpp:333-366`), server-side
  `TryActivateAbility`, `TryActivateAbilityByClass`, and
  `TryActivateAbilitiesByTag` (`:1562`, `:1682`), gameplay-event triggers
  (`:2496-2527`, `:2564`), and owned-tag triggers (`:2683`). None is
  client-reachable today, but each would bypass the seam. All reach
  `CanActivateAbility` through `InternalTryActivateAbility` (`:1817`).

Three mechanisms close them:

T1 adds only one server-internal exemption: the validated movement entry may
open the scope for its resolved dodge spec. The ordinary entry refuses that
marker with `MalformedRequest`. No stock route, event, batch, nested other-spec
activation, client replay or forced update gains an exemption; existing
refusal/token/no-reply behavior remains. Grant validation must enforce the
marker and specialized definition through base-pointer callers.

1. **Two overrides on `UAethelnAbilitySystemComponent`:**
   `InternalServerTryActivateAbility` (covering both single-ability RPCs) and
   `ServerAbilityRPCBatch_Internal` (dropping the whole batch, including its
   target-data write). In P2 to P5 both refuse unconditionally; P6 adds the
   seam-scope exemption to the first. Each refusal takes one token from the
   connection's bucket and records a metric only (`RejectionCount`, subject
   Ability, safe reason `Rejected`). It sends **no reply**: no
   legitimate client uses these routes, so a hostile client gets no reliable
   `ClientActivateAbilityFailed` to amplify. The ServerOnly security policy is
   a second, independent guard.
2. **The choke point plus grant validation.**
   `UAethelnGameplayAbility::CanActivateAbility` returns false on a
   PlayerState-owned ASC unless a seam scope is open for that ability's spec
   handle (AI ASCs are exempt). The scope passes only the handle the seam is
   activating, so an ability activated from inside another ability's
   `ActivateAbility` is refused. One check thus covers event and tag triggers, `GiveAbilityAndActivateOnce`,
   server-side `TryActivate*`, and the stock Blueprint calls, and it stops a
   client forwarding through the stock path, because the client-side check runs
   first (`GAS/Private/AbilitySystemComponent_Abilities.cpp:1665`). Grant
   validation (see Abilities) refuses triggers, input ids, and direct input
   replication, so #60 sending gameplay events cannot start a player ability by
   accident.
3. **Inherited Blueprint API.** `TryActivateAbilitiesByTag`,
   `TryActivateAbilityByClass` (`GAS/Public/AbilitySystemComponent.h:1023-1032`),
   `K2_GiveAbility`, `K2_GiveAbilityAndActivateOnce` (`:968-980`), and
   `BP_ApplyGameplayEffectToSelf` (`:771-772`) exist on the base class. The
   choke point makes any activation through them fail on a player ASC. Review
   rule: no project Blueprint calls them on a player ASC.

Other engine client-to-server RPCs have no gameplay effect in this design, and
these rules keep it so:

| RPC | Status | Rule |
| --- | --- | --- |
| `ServerSetReplicatedTargetData`, `ServerSetReplicatedTargetDataCancelled` (`GAS/Public/AbilitySystemComponent.h:1572-1577`) | Refused by virtual generated `_Implementation` overrides on the project ASC (#60 P2); no cache write. | Each draws one bucket token, emits a metric only and sends no reply. No project ability uses target-data tasks. |
| `ServerSetReplicatedEvent`, `...WithPayload` (`GAS/Public/AbilitySystemComponent.h:1554-1559`) | The engine implementations write the same cache through `InvokeReplicatedEvent` / `InvokeReplicatedEventWithPayload`; project `_Implementation` overrides refuse them (#60 P2). | Same token/metric/no-reply contract; no project ability uses replicated-event tasks. |
| `ServerSetInputPressed`, `ServerSetInputReleased` (`GAS/Public/AbilitySystemComponent.h:1618-1622`) | Only update spec input state (`GAS/Private/AbilitySystemComponent_Abilities.cpp:2885-2893`). | Phase comes only from the request. Abilities must not read `InputPressed` or `InputReleased`. |
| Montage section and play-rate RPCs (`GAS/Public/AbilitySystemComponent.h:1803-1812`) | Presentation only. | No gameplay window may derive from a montage (Server-Owned Attack Timeline in the combat document). |

**Blueprint exposure review (DoD2).** Attributes are `BlueprintReadOnly` with
no setters. P3 exposes no project Blueprint entry point; the client-side
`RequestActivation` may become `BlueprintCallable` when #61 or #82 needs it.
Server RPCs are not `BlueprintCallable`; no project
function grants abilities, applies effects, or writes attributes for Blueprint.
Inherited calls are covered by mechanism 3 (T13), and grant validation (T15)
covers Blueprint subclasses that change policies or values.

## Rejection Telemetry

The seam reuses the observability event contract
(`docs/observability-and-crash-diagnostics.md:15-48`) and the spike's emission
shape (`Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:69-116`):
one event and one metric per outcome (`EventCount` for accepted,
`RejectionCount` for rejected), resolved at emit time, never changing gameplay
when the sink fails. Rejections use the subject-bearing envelope: `Category =
Rejection`, a subject category, and a safe reason. The activation id is empty
for every rejection, because rejections precede activation
(`docs/observability-and-crash-diagnostics.md:65-67`).

| Result (`EAethelnActivationResult`) | Subject category | `EAethelnSafeReason` |
| --- | --- | --- |
| `Accepted` (Press or valid Release) | Ability | `Accepted` |
| `ConnectionClosed`, `ActorDestroyed` | Ability | same name |
| `RateLimited` | Ability | **`RateLimited` (new)** |
| `IncompatibleVersion`, `StaleSequence`, `DuplicateSequence`, `MalformedRequest`, `ActivationBlocked` | Ability | same name |
| `OnCooldown` | **Cooldown** | `ActivationBlocked` |
| `InsufficientResource` | **Resource** | `ActivationBlocked` |
| `InternalFailure` (activated but not committed) | Ability | `InternalFailure` |
| `TimestampOutOfBounds` | Ability | `TimestampOutOfBounds` |
| `ImpossibleAimTransition` | Aim | `ImpossibleAimTransition` |

An accepted corrected aim adds one Correction/Aim/`Corrected` event before
the accepted event, with matching activation id, ability id and sequence,
and one `CorrectionCount` sample. It adds no owner reply. P2 outputs the
accepted aim; P3 passes it through the seam scope to the timeline.

### Bounding client-driven telemetry

The client must not control event volume in the observability critical lane.

- **Which messages draw from the bucket.** Seam requests, the two overridden
  stock routes, all four refused target-data/replicated-event routes, and T1's
  received flagged moves that the server simulates.
  Input-state and montage RPCs retain their existing bounded behavior and
  do not draw from this bucket.
- **Refused stock-route calls** emit a metric only: they have no sequence, and
  the contract drops any event with sequence 0
  (`Source/GameNet/Public/AethelnObservabilitySubsystem.h:56-61`;
  `docs/observability-and-crash-diagnostics.md:37-43`).
- **Rate-limited windows.** A connection enters the limited state when its
  bucket is empty and leaves it when a request is admitted again.
  - On entry: one `RateLimited` event (if the request has a nonzero sequence),
    one metric sample, and, only when the entering message is a seam request,
    one `RateLimited` outcome to the owner. A refused stock-route call that
    empties the bucket sends no reply.
  - While limited: no events and no outcomes. Refused seam requests and
    refused stock-route calls are only counted in memory, folded into one
    suppressed count.
  - On exit: one metric sample whose value is the suppressed count, which may
    be 0.
  - **Teardown flush.** A window ends only when a request is admitted, so
    PlayerState or ASC teardown while limited flushes the exit metric;
    otherwise a client that disconnects mid-window would never emit it.

  Every limited window therefore costs at most two metric samples, one event,
  and one outcome, whatever the client sends.
  This is one shared window across ordinary, movement and refused stock routes.
  Emission is route-aware: if movement enters it, use the typed movement
  outcome and nonzero ordinal; if an ordinary request enters it, use its
  sequence outcome; stock entry sends no reply. Mixed traffic does not open a
  second window or budget. Subsequent traffic contributes to the same bounded
  suppressed count, and teardown flushes its exit metric and clears pending
  movement delegates without emitting into the ordinary client stream.
- **Zero-sequence requests** outside a window are counted by metric only; their
  event is dropped by contract. This is documented, not worked around.

### Other rules

- **Allowlisted correlation only:** connection pseudonym, activation id,
  ability id, and sequence
  (`Source/GameNet/Public/AethelnObservabilitySubsystem.h:27-33`). The ability
  id is filled only once the server resolved a granted spec (step 6 onward).
  Accepted events carry both ids (`:47-61`); a valid Release carries the
  running activation's id.
  Movement emits a separate nonzero PlayerState ordinal in the telemetry
  sequence slot; it never manufactures a client sequence-0 activation event.
  The result's subject comes from the resolved action (`Dodge`, `Block`,
  otherwise `Ability`), with the same cooldown/resource reason mapping and
  step-6 ability-id disclosure rule. No target identity or Guard value is added.
- **Connection pseudonym: `excluded` in #19.** No pseudonym property or
  assigner is added; events use the explicit `excluded` value the contract
  allows (`docs/observability-and-crash-diagnostics.md:55-58`). When a packaged
  scenario first uses the new path (#2 or Issue
  [#48](https://github.com/ShayShimoni/aetheln-online/issues/48)), the
  pseudonym moves to the PlayerState with `COND_OwnerOnly`, because a
  PlayerState is always relevant.
- **Nothing sensitive.** The diagnostic code stays on the restricted channel
  (`MakePublicCopy` removes it). Outcomes, events, and logs never contain
  bucket values, token counts, or request bodies; the client sees only the
  result enum. The bucket placeholders live in shared `Config/DefaultGame.ini`,
  because `DedicatedServer*.ini` would not load in an in-process PIE server
  (`Runtime/Core/Private/Misc/ConfigContext.cpp:853`, `:974-996`).
- **Vocabulary change.** Append `RateLimited` after `ControlledShutdown` in
  `EAethelnSafeReason` (`Source/GameNet/Public/AethelnObservability.h:58-76`),
  inside schema v1, and update `IsKnown` (`:171-195`), `LexToString`
  (`:257-279`, string `rate-limited`), and
  `Aetheln.Observability.Contracts.SchemaAndVocabulary`
  (`Source/GameNet/Private/AethelnObservabilityTests.cpp:123-163`; its
  version-1 assertion at `:132` stays). Staying in v1 keeps #2's runner green
  (`scripts/build/Invoke-NetworkAuthoritySpike.ps1:329`).
- **Append-only rule.** P3 adds this to
  `docs/observability-and-crash-diagnostics.md`: *"Closed-enum values may be
  appended within a schema version. Removing, renumbering, or changing the
  meaning of an existing value requires a schema version bump."*
- **Module boundary.** The mapping table stays in a private `.cpp`; no GameNet
  type appears in a GameCombat public header (TA-021).
- **Content version in correlation** is deferred to Issue
  [#38](https://github.com/ShayShimoni/aetheln-online/issues/38), when #60
  needs it. Repeated rejection is a signal, not proof of cheating (Corrections
  and Rejections in the combat document); #19 adds no automatic penalty.

## Test Plan

Names follow `Aetheln.<Area>.<Group>.<Case>`. Each test is
`IMPLEMENT_SIMPLE_AUTOMATION_TEST` with `EditorContext | EngineFilter`. The P2
tests, their headless-world helper, and the test-only ability UCLASS live in
the editor-only `GameTests` module (`Source/GameTests/Private/`), whose
dependencies follow the `GameTests` row of the
[Technical Architecture module table](technical-architecture.md#unreal-module-boundaries)
([TA-023](architecture-decisions.md#ta-023---editor-only-gametests-module-for-project-automation-and-content-validation)),
so the Client and Server targets carry no test class. The test-only native tags (`Ability.Test.*`,
`Test.*`) are the exception: the engine accepts native tags only from Runtime
modules, and client and server tag sets must match, so they are declared in
`GameCore` under `WITH_DEV_AUTOMATION_TESTS` and are absent from Shipping
builds. The test-ability header itself stays unguarded: UHT does not recognize
`WITH_DEV_AUTOMATION_TESTS` and skips the contents of such a block
(`Engine/Source/Programs/Shared/EpicGames.UHT/Parsers/UhtHeaderFileParser.cs:1187-1194`),
so guarded `UCLASS` types would lose their generated code and fail to compile.
The editor-only module already keeps them out of Client and Server targets.
Test names keep the
`Aetheln.GameCombat.*` prefix. Tests that pin a policy set their own values,
never a tuning number. **H** is a headless single authority world using the
spike's harness and the in-memory sink (`SetTestSink`). **P** is PIE with a
dedicated server and two clients; no multi-client PIE harness exists, so these
are manual steps recorded in the PR unless one lands. A headless world cannot
exercise `OnRep`, owner-only conditions, Mixed replication, or rollback, so
those are P. **K** is a packaged run (later #2 and #48 evidence). Numbering
matches the approved design; T32 is intentionally unassigned.

| # | Test | PR | Kind | What it proves |
| --- | --- | --- | --- | --- |
| T1 | `Aetheln.GameCombat.Lifecycle.PlayerStateOwnsAbilitySystem` | P2 | H | ASC on `AAethelnPlayerState` in Mixed mode, set in `SpawnedAttributes`, pawn has no ASC, owner is the PlayerState, **avatar null before possession** |
| T2 | `Aetheln.GameCombat.Lifecycle.PossessionSetsAvatar` | P2 | H | Real `Possess` makes the pawn the avatar; abilities granted once, attributes initialized once |
| T3 | `Aetheln.GameCombat.Lifecycle.UnpossessCancelsAndClearsAvatar` | P2 | H | Real `UnPossess` cancels a test-only long-running ability and nulls the avatar; owner unchanged; a test duration effect persists |
| T4 | `Aetheln.GameCombat.Lifecycle.AvatarReassignment` | P2 | H | Real `Possess` of pawn B after A: B is the avatar, no re-grant, no refill, no synthetic broadcasts |
| T5 | `Aetheln.GameCombat.Lifecycle.AvatarDestroyedWhilePossessed` | P2 | H | Null case fires first; avatar null; PlayerState ASC intact; no crash |
| T6 | `Aetheln.GameCombat.Lifecycle.AIPawnOwnsAbilitySystem` | P2 | H | AI ASC on the pawn, Minimal, owner and avatar the pawn; possession refreshes actor info; no PlayerState |
| T7 | `Aetheln.GameCombat.Attributes.ReplicationPolicy` | P2 | H | From the class default object: all six attributes `COND_OwnerOnly` and `REPNOTIFY_Always` |
| T8 | `Aetheln.GameCombat.Attributes.ClampAndBounds` | P2 (P4 adds the lower-only case) | H | Values clamp to `[0, Max]`; lowering each max re-clamps its current value and lowers a base above it; with a positive temporary modifier active, lowering a max below the current value but above the base re-clamps the current value and never raises the base |
| T9 | `Aetheln.GameCombat.Attributes.InitOnceThroughEffect` | P2 | H | Values arrive only through the init effect, once per PlayerState; every current value equals its configured value; re-possession does not reapply |
| T10 / A1 | `Aetheln.GameCombat.ActivationSeam.RequestShape` | P3, #60 P2 update | H | Exactly seven reflected fields; only Aim and ClientServerTimeSeconds are added; no target, hit, contact, damage, magnitude, attribute, shape, range, window, cost, or cooldown field |
| T11 | `Aetheln.GameCombat.ActivationSeam.ValidateMatrix` | P3 | H | Steps 1 to 7 with an injected clock: each failure, precedence, zero/lower/equal sequences, an accepted forward gap, Press while active, Release undeclared, a valid Release |
| T12 | `Aetheln.GameCombat.ActivationSeam.RejectionHasNoSideEffect` | P3 | H | Every rejection leaves no cost, cooldown, state tag, sequence advance, or activation id; a failing commit gives `InternalFailure`, and so does a failing commit whose ability keeps running (the seam cancels it) and a commit through the refused partial `CommitAbilityCost` and `CommitAbilityCooldown`, which apply nothing; a valid Release advances the sequence and replaying it is rejected |
| T13 | `Aetheln.GameCombat.ActivationSeam.StockRoutesRefused` | P3 | H | Nothing activates or commits via the single-ability RPCs, `ServerAbilityRPCBatch` (whole batch dropped, target-data cache untouched), `TryActivateAbilityByClass`, `TryActivateAbilitiesByTag`, `GiveAbilityAndActivateOnce`, a gameplay event matching a test trigger, or an ability activated from inside another ability's `ActivateAbility`. The trigger case grants its test ability directly, because T15 refuses triggers. The cache assertion uses a test accessor on the project ASC, because `AbilityTargetDataMap` is protected (`GAS/Public/AbilitySystemComponent.h:1650`, `:1671`). |
| T14 | `Aetheln.GameCombat.ActivationSeam.RateBound` | P3 | H | With an injected clock and test-set bucket: excess requests get `RateLimited` with no side effect; refused stock-route calls draw from the same bucket; in-bound requests are unaffected. The bucket runs before validation: zero-sequence, malformed, and no-avatar requests each spend a token, and once the bucket is empty a malformed request gets `RateLimited`, not its validation reason |
| T15 | `Aetheln.GameCombat.ActivationSeam.GrantValidationFailsClosed` | P3 | H | Grant refused for a class not deriving from `UAethelnGameplayAbility`, a null class, a client security policy, a predicted execution policy, per-execution instancing, a missing tag, an identity outside the `Ability.` family or the bare root, content version 0, a negative or non-finite cost or cooldown, `AbilityTriggers`, `bReplicateInputDirectly`, a spec input id, or spec-level `DynamicAbilityTriggers`. Each definition case first shows the unchanged definition is grantable, the exact refusal count is pinned, and end to end the PlayerState grants only the valid configured class |
| T16 | `Aetheln.GameCombat.ActivationSeam.CheatFlagsOff` | P3 | H | `AbilitySystem.IgnoreCooldowns` and `IgnoreCosts` are off by default (cheat variables, `GAS/Private/AbilitySystemGlobals.cpp:39-40`); the seam ignores them |
| T17 | `Aetheln.GameCombat.Abilities.CostAndCooldownCommit` | P4 | H | For each of the three skeletons, with test-set values on the granted instance: acceptance commits once through `CommitAbility`, applies one cost (Endurance drops by exactly the cost) and one cooldown effect that grants the ability's own cooldown tag for the set duration, and the activation ends itself without a cancel; a request during the cooldown gets `OnCooldown` and spends nothing; after the test removes the cooldown effect (no ticking), the next is accepted; one ability's cooldown never blocks another |
| T18 | `Aetheln.GameCombat.Abilities.ResourceBounds` | P4 | H | Endurance below cost gives `InsufficientResource`, no partial spend; a non-finite or negative cost fails closed the same way; cost equal to Endurance is accepted and leaves 0; a zero cost is accepted at 0 Endurance and applies no cost effect; content check: no configured cost exceeds the configured `MaxEndurance` |
| T19 | `Aetheln.GameCombat.Abilities.TagAndStateGates` | P4 | H | For each skeleton, `State.Dead` and a test block give `ActivationBlocked` with nothing spent or committed, and removing either allows activation. Which abilities block which is `TBD` (#60, #18), so the test block uses the ASC's blocked-ability tags (`BlockAbilitiesWithTags` on the ability's identity), as an active blocking ability would, and puts no test tag on a production ability |
| T20 | `Aetheln.GameCombat.Abilities.DefinitionsAndVersions` | P4 | H | `DefaultGame.ini` grants exactly the three skeletons, in order, and every definition passes grant validation; unique `Ability.` tags whose native tag comments are their semantic IDs, `ContentVersion >= 1` loaded from the ini, `InstancedPerActor` and ServerOnly policies (nothing predicted), exactly one unique cooldown tag, null effect classes, `bAcceptsRelease = false`; through the configured grant list, a newer or older content version gives `IncompatibleVersion` and the matching one is accepted |
| T21 | `Aetheln.GameCombat.Telemetry.ActivationOutcomes` | P3 | H | One event and one metric per ordinary outcome, matching the telemetry table; activation id empty on rejections, ability id only from step 6; a valid Release event carries the running activation id; public copy has no diagnostic code; zero-sequence rejections and refused stock-route calls are metric-only; a rate-limited flood gives one event and one outcome on entry and one aggregated metric on exit; a stock-route flood during a window folds into the suppressed count; teardown while limited flushes the exit metric. The test calls `SetRuntimeContext` itself (as `Source/GameCombat/Private/AethelnNetworkSpikeAuthorityTests.cpp:251` does), because `TryComposeCorrelation` drops every event without one (`Source/GameNet/Private/AethelnObservabilitySubsystem.cpp:149-152`). |
| T22 | `Aetheln.Observability.Contracts.SchemaAndVocabulary` (update) | P3 | H | `RateLimited` is known, its string `rate-limited` is stable, the schema version is still 1 |
| T23 | `Aetheln.GameCombat.Net.ClientAvatarConvergence` | P5 | P | On both clients the avatar is null before possession and equals the pawn after spawn, re-possession, and unpossession, including when the PlayerState arrives after the pawn |
| T24 | `Aetheln.GameCombat.Net.AttributeReplication` | P5 | P | All six attributes reach the owner only, at the provisional frequency rather than 1 Hz |
| T25 | `Aetheln.GameCombat.Net.MixedEffectReplication` | P5 | P | The owner gets the full cooldown effect with time remaining; the other client sees only the tag |
| T26 | `Aetheln.GameCombat.Net.OutcomeOwnerOnly` | P5 | P | The outcome reaches the owning client only, reliably |
| T27 | `Aetheln.GameCombat.Net.ClientCannotActivateDirectly` | P5 | P | A client calling `TryActivateAbility` or the engine RPCs activates and commits nothing and gets no reply to amplify; client-side `CanActivateAbility` is false for every player ability |
| T28 | `Aetheln.GameCombat.Net.ReliabilityMasksNetworkDuplication` | P5 | P | Under loss, duplication, and reordering profiles the reliable channel prevents double commits and both clients see the same cooldown state. Adversarial duplicates are T11 and T12. |
| T29 | `Aetheln.GameCombat.Net.PredictedHoldTheLineRollback` | P6 only | P | Rejected prediction rolls back cost, cooldown, and tag; accepted converges with no double cost, including under loss |
| T30 | Packaged two-client run with the new seam | later | K | Not required to merge #19 |
| T31 | `Aetheln.GameCombat.ActivationSeam.LifecycleRejections` | P3 | H | No avatar gives `ConnectionClosed`; a dying avatar gives `ActorDestroyed`; sequence state survives re-possession |
| T33 | `Aetheln.GameCombat.Lifecycle.PawnToAbilitySystemLookup` | P2 | H | `FindForPawn` returns the PlayerState ASC for a player pawn, the pawn's own ASC for AI, null for neither |
| T34 | `Aetheln.GameCombat.Lifecycle.ReconnectInterimGap` | P2 | H | Pins the known gap: a fresh PlayerState for the same player gets a full init. #21 flips it. |

### T1 required integration coverage

These additions to existing test rows are required before movement-carried
implementation acceptance. They do not widen the frozen CI filter or report
an existing pass. D rows refer to the
[Dodge test plan](dodge-and-block.md#test-plan).

| #19 rows | #18 rows | Added obligation |
| --- | --- | --- |
| T11 | D8 | Shared check precedence and version/lifecycle/instance/start failures; ordinary RPC for a movement-carried grant is `MalformedRequest`. A valid ordinary Press immediately after movement is accepted using ordinary sequence, raw aim and client time state left untouched by the dodge; it advances that history only under the ordinary acceptance rule. |
| T13 | D8 | Scope authorizes only the resolved spec. Client replay, forced updates and no-current-move-data calls authorize nothing; stock RPC/batch/event and nested other-spec routes remain refused and rate-accounted. |
| T15 | D7 | Positive valid definition first, then finite/order/duration/tag/cost-or-cooldown failures as applicable to Q4; marker requires Press-only/no Release. Specialized checks are reached through the actual base-pointer PlayerState grant path. Test values are policy fixtures, not tuning. |
| T12, T17, T18 | D9, D11, D12 | One full cost/cooldown commit; rejection and refused partial commits spend nothing or advance no history. Repeated full commit and synchronous cancellation/replacement/tag/avatar callbacks preserve operation identity and clear obsolete state. Use actual packed-move delivery to assert simulated-move and authority-call counts for dropped/duplicate/reordered/zero-delta/forced/unacknowledged cases. |
| T14, T21 | D15 | Mixed ordinary/movement/stock flood shares one token budget and limited window; typed route-correct entry outcome/event, nonzero movement ordinal, bounded suppression and teardown exit metric. Preserve subject mapping, owner-only RPC, step-6 disclosure and unchanged gameplay when the sink is absent. |
| T12 (operation cleanup), T11 (due-boundary validation) | D10, D13, D14, D16 | Due boundaries precede either transport's validation; half-open windows use server processing time even with withheld moves or absent presentation. State.Dead/avatar/PlayerState cleanup closes the actual operation and displacement once; re-possession or synchronous replacement cannot resurrect stale avoidance. |

| Acceptance item | Tests and text |
| --- | --- |
| AC1 ASC on PlayerState; pawn is avatar | T1, T2, T23, T33 |
| AC2 Possession, init, unpossession, reassignment, replication tested | T2 to T5, T9, T23, T31, T34 |
| AC3 AI ASC on authoritative pawns | T6, T33 |
| AC4 Health and class resources replicate by documented policy | T7, T24, T25; Attribute Policy |
| AC5 Three abilities validate tags, state, cost, cooldown, bounds, content version | T11, T12, T17 to T20, T28, T31 |
| AC6 Effects own attribute changes | T8, T9, T12, T17, T18 |
| AC7 Prediction only on reversible paths with tested rollback and correction | T13, T20 (nothing predicted in P2 to P5); T29 (P6, owner-gated); outcome T26 |
| AC8 Versioned activation seam for #60 | T10, T11, T20; Activation Seam |
| AC9 No client target, claimed hit, or direct attribute write | T10, T13, T15, T27; Attribute Policy |
| AC10 Tag and content-version conventions documented | The combat document's conventions section (P1); T20 |
| DoD1 Lifecycle, prediction, rejection, possession, unpossession, reassignment tested on server and clients | T2 to T5, T11 to T14, T23 to T28, T31 (and T29) |
| DoD2 Blueprint exposure and null or avatar transitions reviewed | Blueprint exposure review; T1 to T5, T13, T15, T23 |
| DoD3 Rejection telemetry with safe reason codes | T21, T22, T26 |
| DoD4 #21 owns death and respawn | Handoff to #21; T34 flipped by #21 |

## PR Phasing and Evidence

Each PR targets `develop`, references #19 with `Refs #19`, stays small, and
leaves the spike files untouched.

| PR | Scope | Depends on |
| --- | --- | --- |
| **P1** | The conventions section in the combat document, this document, the TC-008 candidate, and the index entry. Docs only. | Review of the approved design |
| **P2** ASC foundation | Native tags (`Source/GameCore/GameCore.Build.cs`, `AethelnGameplayTags.*`); `AethelnPlayerState.*`; `AethelnAbilitySystemComponent.*` (with `FindForPawn`, no seam yet); the attribute set; the init effect; the combat game mode; the AI character base; `Config/DefaultGame.ini` sections; T1 to T9, T33, T34, using a test-only long-running ability, all in `Source/GameTests/Private/` (`GameTests.Build.cs` gains `GameCombat`, `GameplayAbilities`, and `GameplayTags`). | P1 |
| **P3** Seam and telemetry | `AethelnActivationTypes.h`; in `AethelnAbilitySystemComponent.*`: the seam RPC, static validator, rate bucket, two stock-route overrides, seam scope and result slot, owner outcome, and telemetry; in `AethelnPlayerState.*`: grant validation; the base `AethelnGameplayAbility.*` with the choke point (cost and cooldown arrive in P4); `RateLimited` in `Source/GameNet/Public/AethelnObservability.h` and its test; T10 to T16, T21, T22, T31 with test-only abilities; the append-only rule in `docs/observability-and-crash-diagnostics.md`. | P2 |
| **P4** Abilities | Cost and cooldown overrides on the base ability, the shared effects, the three skeletons (`AethelnOathscarAbilities.*`), the grant list and per-ability config, T17 to T20. | P3 |
| **P5** Two-client evidence | Select the input-enabled pawn with `AAethelnCombatGameMode` by one of the three routes in Class Layout. T23 to T28 as manual PIE steps recorded in the PR. This is also the feel test after which the owner answers whether #19 can close without P6. | P4 |
| **P6** Predicted Hold the Line (gated) | Batching override, `ServerSubmitPredictedActivation`, the Hold the Line policy change, the grant-validation allowance, T29 under network emulation, and the TC-008 update. | P5 and the owner's decision |

Not part of #19: ability input bindings (they go with #60 and #82); damage and
the defense order, contacts, Guard pressure, block resolution, the basic chain,
and attack timelines (#60); dodge (#18);
death, respawn, and reconnect restoration (#21); the HUD and opponent
visibility (#61); enemy behavior (#20); widening the CI filter; and migrating
the spike classes after #2 closes.

### Local automation evidence for P2 to P5

CI compiles the new code but runs only a frozen filter of two tests,
`Aetheln.Harness.ProjectAndModuleLoad` and
`Aetheln.GameCombat.NetworkSpike.Authority`
(`scripts/ci/Invoke-UnrealAutomationTests.ps1:14-15`; harness contract
`docs/unreal-automation.md:18-37`; receipt and aggregate pins
`scripts/ci/New-CiAcceptanceReceipt.ps1:329-336`,
`scripts/ci/Invoke-CiAcceptanceAggregate.ps1:610-617`,
`docs/continuous-integration.md:513`). The new tests therefore do not run in
CI. Under the repository rule to record manual test steps in the pull request
when automation is unavailable, each of P2 to P5 records, at its exact head on
the pinned engine, the `Automation RunTests` command, the revision, and the
pass counts:

- **P2:** `Aetheln.GameCombat`, plus `Aetheln.Movement` and `Aetheln.POC`,
  because P2 also changes GameCore (the `GameplayTags` dependency and native
  tags) and those groups hold the existing movement and POC tests.
- **P3:** `Aetheln.GameCombat` and `Aetheln.Observability`.
- **P4:** `Aetheln.GameCombat`.
- **P5:** the manual PIE steps for T23 to T28.

Widening the CI filter, its receipt and aggregate pins, and the TA-020 harness
contract is a later ticket under Issues
[#85](https://github.com/ShayShimoni/aetheln-online/issues/85) and
[#167](https://github.com/ShayShimoni/aetheln-online/issues/167), not planned
here.

## Known Interim Gaps

- **Reconnect is a free refill (owner: #21).** With the `AGameModeBase` base
  class pinned in Class Layout, a reconnect creates a new PlayerState, so
  `bCombatStateInitialized` is false and P2 applies the init effect again: the
  player returns with full Health and Endurance and no cooldowns. Canon forbids this: "disconnect is never an instant escape,
  cleanse, restore, or grant" (Death, Logout, and Recovery Safety in the combat
  document). #19 adds no restoration code. The test
  `Aetheln.GameCombat.Lifecycle.ReconnectInterimGap` pins the current behavior
  so the gap stays visible, and #21 flips it when it lands its reconnect rule
  (its acceptance criterion: reconnect during death or respawn resolves to one
  valid state).
- **Replicated-data cache closure (#60 P2).** All four client-callable cache
  writers now refuse through generated virtual implementations. A3 covers
  no writes, token accounting, metric-only telemetry, no replies, and
  unaffected bounded input-state RPCs. Local non-RPC cache APIs remain
  available to trusted engine code; project abilities do not use these tasks.

## Open Decisions

All stay `TBD` until the named owner decides.

1. **Whether #19 can close without P6**, and so whether any ability is
   predicted. Owner decision after P5, with an accepted architecture entry
   (TC-008 is the candidate).
2. **Tuning values:** initial `MaxHealth`, `MaxEndurance`, and `MaxGuard`,
   starting current values, each ability's Endurance cost (or none), and each
   cooldown duration. Owners: Issue
   [#107](https://github.com/ShayShimoni/aetheln-online/issues/107) and the
   evidence tickets (#45).
3. **Final values** for the PlayerState update frequency and the rate bucket
   (placeholders set and reviewed in P3). Owner: #45.
4. **Numeric aim/time bounds** (#82 F1, F2). #60 P2 decides the schema-2
   representation, bounded correction and raw-to-raw rate policy. Its eight
   keys remain unset/`TBD`; owners #60, #2 and #45 approve future values.
5. **Phase behavior of Hold the Line:** a fixed-duration commitment, or
   hold-and-release (which would set `bAcceptsRelease`). Owners: #107 and the
   owner.
6. **Blocking and cancel relations** among the three actives, the basic chain,
   dodge, and block. Owners: #60 and #18 content.
7. **Cooldown and attribute behavior across death, respawn, and reconnect**,
   including closing the reconnect gap. Owner: #21.
8. **What opponents may see** of the six attributes. Owner: #61.
9. **Content version in the observability correlation fields.** Owner: #38,
   when #60 needs it.
10. **Final display names** of the abilities, resources, and the Order.
11. **Widening the CI automation filter** for the new test groups. A later
    ticket under #85 and #167.
