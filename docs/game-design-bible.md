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
- Non-target action combat built around aim, spacing, attack commitment,
  blocking, dodging, interruption, resource management, and readable
  animations.
- Equipment that creates meaningful power and utility without replacing player
  skill.
- Character development through Skein Weaving rather than a traditional
  point-by-point talent tree.

## Design Pillars

### Skill Decides How Power Is Used

Levels, equipment, Skein choices, and faction Doctrines provide real
advantages. They do not aim, time a block, read a telegraph, manage stamina, or
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
mixed territory. PvP there is always active. There is no opt-in flag.

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
- PvP is mandatory and always enabled.
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

Combat is third-person, action-based, and mostly non-targeted.

### Authoritative Rules

- The server decides movement validity, hits, damage, healing, resources,
  cooldowns, crowd control, death, loot, and PvP rewards.
- Clients may predict local movement, animation, and presentation.
- Melee attacks use server-validated swept traces during authored animation
  windows.
- Projectiles and persistent combat areas are server owned.
- Dodges grant a server-validated defensive window.
- Blocks are directional and consume a defensive resource.
- Input buffering supports deliberate combo timing without automating the
  rotation.

### Readability Rules

- Dangerous actions have readable animation and effects.
- Range, direction, and impact timing must be learnable.
- Crowd effects cannot obscure critical telegraphs.
- Visual character differences must not change the authoritative combat
  capsule or create male, female, or race-based hitbox advantages.

## Playable Classes

The initial class concepts remain:

- **Bulwark:** pavise and spear; blocking, counters, protection, and guard
  pressure.
- **Skeinblade:** paired light-glass blades; dodging, momentum, pursuit, and
  recovery punishment.
- **Embercaller:** focus or relic gauntlet; aimed bursts, channels, zones, and
  ranged control.
- **Lumen:** chime-staff; healing, wards, support, and battlefield tempo.

Classes are not faction-locked. Faction Doctrines modify how a class approaches
the world and combat without replacing its identity.

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

- **Forms:** mutually exclusive behavior changes for class abilities.
- **Threads:** limited links in which one successful combat action changes
  another.
- **Keystone:** one major rule that changes the class's combat rhythm.
- **Faction Doctrine:** faction-specific active and utility development.

The initial playable implementation should use a small number of meaningful
choices rather than many percentage nodes.

Detailed rules are defined in
[Progression, Loot, and Skein Weaving](progression-loot-and-skein.md).

## Equipment and Loot

Equipment supports every part of combat:

- Offensive power and damage type.
- Health, protection, and resistance.
- Stamina, Guard, class resources, and recovery.
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

- Every playable race supports male and female characters.
- Sex does not change attributes, combat power, class access, faction access,
  or authoritative hitboxes.
- Every playable race may use every supported class.
- Every playable race may join either player faction.
- Appearance data is separate from class, faction, progression, equipment, and
  combat state.
- Planned appearance categories include race, sex, body preset, face, hair,
  markings, and voice.

## Lore Spine

Aetheln was dreamed into existence by the Waking Star. The Star's light is the
source of life, magic, and memory.

The Lucent Choir attempted to bind that light permanently and caused the
Duskbreak, cracking the Star and glassing much of civilization. The wounded
Star now sheds scarce Embers into the world.

The Concord was created to regulate those Embers, but its laws are severe and
its control is disputed. The two player factions now disagree over who should
control the remaining light and what survival justifies.

The Ashen Choir seeks to complete the failed ritual. Its success would extinguish
the Star and end all life.

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
- One representative class kit.
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
- Ember Cycle duration and seasonal reset details.
