# Aetheln Online Game Design Bible

## Document Status

This document is the canonical high-level product and gameplay direction for
Aetheln Online. Detailed rules live in the linked system documents.

When older research or planning material conflicts with this document, this
document wins. Names marked as working names still require a final creative and
legal review.

## Game Identity

Aetheln Online is a server-authoritative, third-person fantasy action MMORPG
about two opposing factions struggling over the remaining light of a dying
star.

The game combines:

- A persistent fantasy world with quests, dungeons, settlements, factions, and
  character progression.
- Mandatory open-world faction PvP once a character leaves protected faction
  territory.
- Pure-free-aim action combat built around aim, spacing, attack commitment,
  blocking, dodging, interruption, resource management, and readable
  animations.
- Equipment that creates meaningful power and utility without replacing player
  skill.
- Character development through Skein Weaving rather than a traditional
  point-by-point talent tree.

## Design Pillars

### Skill Decides How Power Is Used

Levels, equipment, Skein choices, and faction Doctrines provide real
advantages. They do not aim, time a block, read a telegraph, manage Endurance, or
choose a safe commitment for the player.

A skilled but moderately under-equipped player should be able to defeat an
average better-equipped opponent. Extreme progression differences still matter,
but the combat model must avoid routine one-hit victories and invulnerable
defenders.

### The World Becomes Dangerous by Progression

New characters begin inside their faction's protected territory. They learn
their class, complete faction-specific quests, and build an initial identity
without encountering rival players.

At a clearly communicated progression threshold, the story sends them into
mixed territory. PvP there is always active outside explicit
server-authoritative sanctuary subzones. There is no opt-in flag.

### Challenge Produces Earned Progress

The game does not distribute constant low-value rewards to manufacture
engagement. Rewards are less frequent, understandable, and materially useful.

Progress should be felt through:

- Increased damage, defense, resources, and recovery.
- New ability behavior and combo relationships.
- Better movement or traversal options within controlled limits.
- Stronger class and faction utility.
- Visible armor, weapon, and Ember-light changes.
- Access to more dangerous territory and more difficult encounters.

### PvE and PvP Share One Combat Language

PvE teaches the same mechanics used against players. Normal enemies teach one
verb, elites combine several verbs, and bosses test the complete vocabulary.

The primary verbs are:

- Aim.
- Position.
- Commit.
- Dodge.
- Block.
- Counter.
- Interrupt.
- Break guard.
- Control space.
- Protect allies.

### Factions Are Different, Not Morally Simple

Both factions contain protectors, opportunists, idealists, and extremists.
Neither side is the designated evil faction. The Ashen Choir remains a common
enemy whose plan threatens the entire world.

All playable races can join either faction. Faction identity comes from
belief, territory, quests, relationships, skills, utilities, and world goals,
not biological restrictions.

## Core Player Flow

1. Create a male or female character from any available playable race.
2. Select a faction and begin in its protected starting territory.
3. Learn movement, class combat, faction history, and early PvE mechanics.
4. Gain permanent Character Levels and unlock initial Skein options.
5. Enter mixed territory when the frontier threshold is reached.
6. Quest, gather, explore, fight enemies, and encounter hostile players under
   mandatory PvP rules.
7. Bank contested resources in a safe mixed city or faction holding.
8. Improve equipment, configure the Skein, and advance the faction Doctrine.
9. Join dungeons, world encounters, territorial battles, infiltration, or
   capital invasions.
10. Increase permanent power and seasonal Ember Rank, then challenge more
    dangerous regions.

## World Structure

### Protected Faction Territory

- Each faction owns a distinct starting territory and quest experience.
- Rival players cannot enter beginner districts through ordinary world travel.
- New characters are not valid PvP targets before reaching the frontier
  threshold.
- Faction capitals sit within these territories but have separate invasion
  rules.

### Mixed Territory

- Both factions receive PvE quests and world objectives in the same regions.
- PvP is mandatory and always enabled except inside explicit
  server-authoritative sanctuary subzones.
- The game clearly communicates the transition before a player crosses it.
- Hostile-player risk raises the value of resources and rewards.
- Territory objectives provide stronger incentives than random killing.

### Safe Mixed Cities

- Neutral cities allow both factions to trade, craft, form permitted groups,
  use services, and socialize.
- Hostile abilities cannot be used inside their sanctuary boundaries.
- Leaving the boundary returns the character to the region's mandatory PvP
  rules.

### Invasion-Enabled Faction Capitals

- Individual enemies may infiltrate through difficult routes.
- Organized forces may attack military objectives and attempt a full invasion.
- Beginner districts remain inaccessible to invaders.
- Guards and defenses make unsupported attacks dangerous.
- Invasions target gates, towers, barracks, commanders, and Ember stores rather
  than civilian NPCs.
- A successful invasion creates temporary consequences and rewards, not
  permanent denial of essential services.

Detailed world-PvP and invasion rules are defined in
[World and Settlements](world-and-settlements.md). Character loyalties and
Faction Doctrine identities are defined in
[Characters and Factions](characters-and-factions.md).

## Combat

Combat is third-person, action-based, and pure free aim. The player aims an
authored attack; neither a soft lock nor a selected target determines
authoritative contact.

Reticle mode is the default gameplay state: the cursor is hidden, a fixed
center reticle expresses camera-directed aim, movement is camera relative, and
the character turns smoothly toward camera-forward combat facing. Left mouse
defaults to the primary attack and right mouse to the class defensive action;
both bindings remain remappable. Space remains jump, including when a combo
follow-up is available through its normal remappable ability binding.

Manual Left Alt toggling and future interface or dialogue layers may request
Cursor mode. Those future layers must hold stacked cursor ownership so closing
one layer cannot recapture the mouse while another still needs it. Cursor mode
blocks new gameplay input; it does not pause gravity, erase momentum, cancel an
accepted attack, or stop an authoritative combat timeline.

### Shared Combat Grammar

Every Order uses the same five resource concepts. Display names may be localized,
but their semantic identities and responsibilities do not change by Order,
equipment, Form, Thread, Keystone, or faction Doctrine.

| Resource | Stable semantic ID | Player-facing rule |
| --- | --- | --- |
| Health | `combat.resource.health` | Remaining life. Reaching zero enters the server-authoritative death flow. Any future deliberate Health cost must be explicit rather than inferred from another resource. |
| Endurance | `combat.resource.endurance` | Shared exertion used by authored physical actions such as dodge, sprint, or demanding defense. An action spends it only when that action's data says so. |
| Guard | `combat.resource.guard` | Stability while actively defending. Guard pressure can break a block or defensive stance; Guard is not bonus Health and does not passively absorb every hit. |
| Ward | `combat.resource.ward` | Explicit temporary protection that absorbs only the damage its authored rule permits. Ward is separate from Health, Guard, armor, and invulnerability. |
| OrderResource | `combat.resource.order` | The one Order-specific combat currency slot. Its display identity is Grudge, Proof, Tempo, Cadence, or Tension according to the selected Order; it never aliases Endurance, Guard, or Ward. |

Damage belongs to one of three stable families. **Wrought**
(`combat.damage.wrought`) is material force: weapons, impacts, and other
physical trauma. **Cinder** (`combat.damage.cinder`) is destructive
Ember-light, heat, and burning transformation. **Wake**
(`combat.damage.wake`) is Deepwake pressure that attacks continuity, memory,
or realized form. An ability may contain more than one explicitly authored
component, but the server resolves each component under its own family. Names
do not imply fixed resistance values, bypasses, or status effects; those rules
remain data driven and tuning-owned. No family is unmitigated "true damage,"
and content cannot bypass the shared defense order by relabeling a packet.

Combat resolves from authoritative state in a consistent order: action and
world-policy eligibility, authored contact, avoidance or immunity, directional
defense and Guard pressure, family-specific mitigation, eligible Ward
absorption, remaining Health change, then secondary effects, interruption, and
death. A Guard break affects later resolution only as its authored rule states;
it never causes the same contact to be evaluated again. Simultaneous events use
an explicit deterministic tie rule rather than frame or packet arrival order.

The shared effect language distinguishes immediate changes from duration
effects and distinguishes helpful effects, harmful effects, and control. Every
duration effect declares its stacking key, source scope, refresh or replacement
behavior, maximum stacks, cleanse eligibility, and proc eligibility. A cleanse
removes only effects in its authored cleanse set. **Resolve** is the shared
server-owned protection against repeated control: eligible control builds or
consumes it according to authored data, while displacement, immunity, and
uncontrolled damage remain separate concepts. Exact durations, stack limits,
Resolve behavior, and all numeric values are tuning `TBD`.

Triggered effects form a bounded server-owned chain. A proc cannot recursively
grant itself, create an unbounded cycle, or escape the root activation's finite
listener, event, target, and construct budgets through branching, delay, or
periodic work. A replayed activation cannot grant a second result. Exact proc
budgets remain tuning `TBD`. Opponents receive readable cues for dangerous
wind-up, active and recovery phases, defense, control, and meaningful state
changes, without receiving secrets that secure stealth or anti-abuse rules
intentionally withhold.

### Relations, Engagement, and Recovery

- The server classifies a source/target pair as self, friendly, neutral,
  hostile, or protected/non-interactable for the current world-policy context.
  Party, faction, ownership, and sanctuary data are inputs; no client-provided
  relation or PvP flag is truth. Projectiles, areas, summons, and other proxies
  inherit an authoritative source identity and recheck current policy when
  their result would apply.
- Movement collision, combat query volumes, and presentation geometry are
  separate. Character meshes and rendered weapons never become authoritative
  collision merely because they overlap on a client.
- Engagement is server-owned state derived from validated hostile actions,
  damage, healing, protection, threat, and encounter rules. It is not a player
  toggle and does not end merely because a client disconnects.
- PvE threat is a server-owned input to AI target choice. A taunt is an
  authored temporary priority rule for eligible AI, not selected-target combat
  authority and never control of another player's input.
- Resource recovery can be passive, delayed, event-driven, or supplied by an
  authored restoration effect. Ability recovery windows and cooldowns are
  separate from resource recovery. Exact rates, delays, and reset values are
  `TBD`.
- Death and respawn clear or preserve only explicitly authored state. Logout,
  disconnect, reconnect, and encounter reset cannot be used to duplicate a
  grant, erase an accepted hostile result, or revive stale attacks, threat,
  effects, or invulnerability.
- Stealth and detection are server decisions. A concealed opponent's hidden
  state must not be disclosed through UI, targeting, replication, audio, or
  effects before the observer is authorized to perceive the corresponding
  cue.

### Prototype Combat Boundary

The prototype remains one Oathscar using sword and shield in one controlled
combat space. It exercises only the shared grammar needed for Health,
Endurance, active Guard, a three-hit Wrought combo, directional block, dodge,
three representative active abilities, one enemy, death, respawn, and readable
feedback. Issue [#107](https://github.com/ShayShimoni/aetheln-online/issues/107)
may define one optional Oathbreak exercise; it does not make Grudge or the full
OrderResource loop default prototype scope. Ward, Cinder, Wake, generalized
threat and taunt, full effect and cleanse collections, full Resolve tuning,
stealth gameplay, faction relations, and the other four Orders remain defined
future-compatible concepts, not prototype runtime scope.

This grammar does not take over runtime or evidence ownership. Networking and
authority selection remain with [Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2);
dodge with [#18](https://github.com/ShayShimoni/aetheln-online/issues/18);
GAS attributes, effects, resources, and cooldowns with
[#19](https://github.com/ShayShimoni/aetheln-online/issues/19); death and
respawn with [#21](https://github.com/ShayShimoni/aetheln-online/issues/21);
threat controls with [#40](https://github.com/ShayShimoni/aetheln-online/issues/40);
measured budgets with [#45](https://github.com/ShayShimoni/aetheln-online/issues/45);
the attack timeline and combo with
[#60](https://github.com/ShayShimoni/aetheln-online/issues/60); HUD and
readability with [#61](https://github.com/ShayShimoni/aetheln-online/issues/61);
and input/camera feel with
[#82](https://github.com/ShayShimoni/aetheln-online/issues/82).

Some prototype brief and scope-ledger text still carries the pre-Issue-#103
placeholder phrase `prototype combat resource` or says not to canonize Guard.
This Issue-#105 grammar is the approved source contract for the four canonical
documents updated here; [Issue #115](https://github.com/ShayShimoni/aetheln-online/issues/115)
owns the downstream brief, ledger, roadmap, glossary, generated-artifact, and
board reconciliation. Historical evidence keeps the terminology it recorded
at the time and is not silently rewritten.

### Authoritative Rules

- The server decides movement validity, hits, damage, healing, resources,
  cooldowns, crowd control, death, loot, and PvP rewards.
- Clients may predict supported local movement, GAS activation, animation, and
  reversible presentation, but never a hit or persistent outcome.
- Melee attacks use server-resolved swept volumes during authored windows on a
  server-owned attack timeline. Those authored volumes match the readable
  animation; rendered-weapon or character-mesh collision is not gameplay truth.
- Projectiles and persistent combat areas are server owned.
- Dodges grant a server-validated defensive window.
- Blocks are directional and consume a defensive resource.
- Ability-authored movement restrictions provide commitment. Individual
  attacks may restrict movement differently rather than sharing a universal
  immobilization rule.
- Input buffering supports deliberate combo timing without automating the
  rotation.
- Animation notifies, sockets, effects, audio, and camera feedback visualize the
  authoritative timeline but do not create gameplay truth.
- The server never accepts a client-selected target or claimed contact.
- Shoulder framing, close-camera offsets, and mesh hiding are presentation
  only. They never alter attack origins, hitboxes, reach, timing, or collision.

### Readability Rules

- Dangerous actions have readable animation and effects.
- Range, direction, and impact timing must be learnable.
- Crowd effects cannot obscure critical telegraphs.
- Visual character differences must not change the authoritative combat
  capsule or create male, female, or race-based hitbox advantages.

## Playable Orders

Orders are the game's classes: surviving institutions that train the
Emberbound. Under Issue #104, the five Orders below supersede the earlier four
initial class concepts (Bulwark, Skeinblade, Embercaller, and Lumen), and
Oathscar supersedes Skeinblade as the active initial Order working label.
Every display name below is a working name with a stable semantic ID.

- **Oathscar** (`order.oathscar`): greatsword, sword-and-shield, two-handed
  spear, and dual wield; sworn grudges spent as the Grudge resource; standing
  ground, guard pressure, and punishment.
- **Nullwright** (`order.nullwright`): staff, focus gauntlet, grimoire-blade,
  and orbiting seals; demonstrated claims banked as the Proof resource; aimed
  bursts, zones, and unmaking forced history.
- **Hushblade** (`order.hushblade`): twin knives, sheathed blade, chain-sickle,
  and needle fan; stolen rhythm banked as the Tempo resource; dodging,
  momentum, pursuit, and recovery punishment.
- **Gravecant** (`order.gravecant`): chime-staff, mace-reliquary, chain-censer,
  and tome-rod; measured song banked as the Cadence resource; healing, wards,
  witness-keeping, and battlefield tempo.
- **Blackfletch** (`order.blackfletch`): longbow, recurve bow, greatbow, and
  tether/trap bow; drawn stillness banked as the Tension resource; range,
  traps, tethers, and route control.

Each Order has two specializations and one Peak; a specialization selects the
dominant interpretation of the Order's oath, and a Peak briefly realizes a
forbidden version of the character. Resource names are working names and all
resource behavior is tuning TBD; the shared resource identities and prototype
subset are defined by the combat grammar above.

Orders are not faction-locked. Faction Doctrines modify how an Order approaches
the world and combat without replacing its identity. The full Order
institutions, specializations, Peaks, and character connections are defined in
[Characters and Factions](characters-and-factions.md).

## Character Development

### Character Level

Character Level is permanent. It governs base growth, ability access, equipment
requirements, and Skein unlocks.

The level cap, exact progression curve, and unlock levels remain tuning
decisions. They must be data driven.

### Ember Rank

Ember Rank represents story recognition, faction-war participation, and
seasonal achievement. It may compress or reset between Ember Cycles without
removing permanent Character Levels.

### Skein Weaving

Skein Weaving replaces a traditional WoW-style talent tree.

Its initial elements are:

- **Forms:** mutually exclusive behavior changes for class abilities. In lore,
  a Form is an alternate history of a technique drawn from the Deepwake.
- **Threads:** limited links in which one successful combat action changes
  another. In lore, a Thread binds a remembered cause to its consequence.
- **Keystone:** one major rule that changes the class's combat rhythm. In lore,
  a Keystone accepts one defining contradiction into the character.
- **Faction Doctrine:** faction-specific active and utility development.

The initial playable implementation should use a small number of meaningful
choices rather than many percentage nodes.

Detailed rules are defined in
[Progression, Loot, and Skein Weaving](progression-loot-and-skein.md).

## Equipment and Loot

Equipment supports every part of combat:

- Offensive power and damage type.
- Health, protection, and resistance.
- Endurance, Guard, Ward, OrderResource, and recovery.
- Attack cadence and ability recovery within controlled limits.
- Stagger, guard pressure, healing, and support.
- Conditional class, faction, PvE, PvP, traversal, and siege utility.

Equipment must not invalidate aiming, timing, positioning, or defensive
execution. Raw movement-speed and cooldown stacking require strict caps because
they can break animation readability and network fairness.

Loot generation is server-side, transactional, auditable, and data driven.
Encounter difficulty, territory danger, contribution, source identity, and
mastery conditions may improve rewards. Equipped items do not drop on PvP
death. Characters may lose a controlled portion of unbanked contested resources.

## Character Creation

Full character creation is a future system, but data and animation architecture
must account for it from the beginning.

Confirmed rules:

- The confirmed playable peoples are Aurin, Kell, and Vesh. The Waking Star
  dreamed each people separately, all three predate the Duskbreak, and no
  confirmed account identifies which was dreamed first.
- Kell are living crystalline people with ivory-quartz outer plates, dark
  amethyst connections, swept horns, external pointed ears, glowing violet
  eyes, and clawed extremities. Their approved male and female references and
  full anatomy contracts are recorded in [Playable Peoples](playable-peoples.md#kell).
- Vesh are mortal embodied spirit creatures connected to the world's spirits
  and guided by the Light. The retained design uses an obsidian-black coat,
  white markings, an ivory faceted natural face, golden eyes, three-digit hands,
  and solid tapered feet. Their spiritual kinship supplies no innate gameplay
  advantage; [Playable Peoples](playable-peoples.md#vesh) defines the full contract.
- Every playable race supports male and female characters.
- Sex does not change attributes, combat power, class access, faction access,
  or authoritative hitboxes.
- Every playable race may use every supported class.
- Every playable race may join either player faction.
- Appearance data is separate from class, faction, progression, equipment, and
  combat state.
- Planned appearance categories include race, sex, body preset, constrained
  visual height, age presentation, face, skin, markings, voice, and a
  race-discriminated feature set.

Before the 2.0 faction stage, persisted characters use
`Faction = Unassigned`. Doctrine is unavailable until the approved one-time
faction choice. This delivery state does not change the target-game flow in
which a faction character begins in its protected territory.

Detailed anatomy, culture, customization, rig, animation, equipment-fitting,
and art-validation rules are defined in
[Playable Peoples](playable-peoples.md).

## Lore Spine

Before the world there was the Deepwake, an ocean of unrealized lives and
histories - everything that could have happened and did not. The Waking Star
emerged from it: a partly sentient memory engine that dreamed Aetheln into
physical existence by realizing some histories and rejecting the rest. Whether
the Star intends anything by what it realizes remains disputed, and that
dispute is deliberate canon. The Star's light is the source of life, magic, and
memory.

The Star dreamed the Aurin, Kell, and Vesh separately. All three peoples
predate the Duskbreak, and their creation order remains unknown.

The Vesh were dreamed as spirits with tangible lives and bodies of their own.
They follow the Light through listening, compassion, and responsible judgment.
The spirits they meet are local continuities of realized lives and places;
their testimony can be incomplete, mistaken, or refused. Neither an encounter
nor the Vesh's existence settles the Star's intention. Enlightenment is a
practice rather than moral infallibility, and neither faction owns the Light.
The Duskbreak fractured the histories many spirits carry. Selaen's caravans and
Lanternrest's Mother-Lanterns now gather willing witnesses and care for places
whose continuity is fading. In the Quieting, the Ashen Choir erases distinct
voices into a single account, drawing Nhalen and Saeril into the conflict
between preservation, consent, and certainty.

The Kell were dreamed as living layered crystal. Their long lives leave
growth and repair visible in quartz and amethyst, shaping a cultural argument
over continuity through change. Their bodies do not automatically store
readable memories; preservation is learned craft. Graefell remembers their
first awakening before its canyon was glassed. Vothram's ritual instruments
and secret archive turn care into a question of responsibility and ownership,
while Corvath's exceptional birth as living catastrophe glass confronts his
people with life preserved at the cost of its next change.

The Lucent Choir attempted the Great Concordance: binding the Star's light
permanently and forcing incompatible histories to coexist. The Concordance
caused the Duskbreak, cracking the Star and glassing much of civilization. The
wounded Star now sheds scarce Embers - rejected memories seeking realization -
into the world. Forgettings are what remains when a life or place loses its
continuity: still present, no longer coherent. The Emberbound, who carry
realized Embers, respawn from their last coherent witnessed record.

The Concord was created to regulate those Embers, but its laws are severe and
its control is disputed. The two player factions now disagree over who should
control the remaining light and what survival justifies.

The Ashen Choir seeks to complete the failed ritual. Its Choirmaster believes a
completed Concordance - the Onefold Vault - can end suffering; the Waking Star
never clearly commands him. The Choir's success would extinguish the Star and
end all life.

## Reward Philosophy

Rewards should be earned, legible, and useful.

- Routine enemies primarily support materials, currency, and occasional
  equipment.
- Elites and difficult encounters offer stronger and more distinctive rewards.
- Bosses provide reliable progress plus a chance at signature items.
- Contested territory adds risk-based reward value.
- Mastery conditions may add reward opportunities without removing the base
  completion reward.
- Extreme random outliers require a fairness mechanism so a player is not
  trapped indefinitely, but the game should not shower the player with constant
  consolation rewards.
- Earlier enemies should become meaningfully easier as permanent power grows.

## Development Scope

The target game includes faction territories, mandatory mixed-territory PvP,
safe neutral cities, faction-capital invasions, progression, equipment, Skein
Weaving, PvE, and persistent online services.

The current prototype does not build that entire game at once. It first proves:

- Responsive replicated movement.
- One representative Order kit; Oathscar is the active initial Order working
  label, superseding Skeinblade.
- Server-authoritative attacks, dodge, damage, death, and respawn.
- One enemy and one controlled combat space.
- Playability under representative latency and packet loss.

Later vertical slices introduce permanent progression and loot, cooperative
PvE, faction identity, one contested region, and finally capital-invasion
systems. Deferring a target feature from the prototype does not make that
feature optional in the final game.

## Open Decisions

The following require dedicated design decisions and must not be guessed:

- Final faction names and heraldry.
- Frontier unlock level.
- Level cap and progression curve.
- Faction-switching and cross-faction grouping rules.
- Item slots, rarity names, trading, binding, and economy rules.
- Exact PvP death loss and contested-resource banking rules.
- Territory population balancing and outnumbered-faction support.
- Capital-invasion schedule, scale, victory state, and recovery duration.
- Skein slot counts, unlock cadence, and class-specific Forms.
- Relationship between Character Level and Doctrine prerequisites.
- Ember Cycle duration and seasonal reset details.
