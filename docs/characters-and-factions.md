# Characters and Factions of Aetheln

## Document Status

This is the canonical character, faction, and Order summary. It updates the
earlier Champions of the First Cycle artifact for the two-faction, mandatory
open-world-PvP direction.

Faction and Order names are working names. Character loyalties describe their
current position and may change through the story.

Under Issue #104, Crowned Ledger (`faction.crowned_ledger`) and Hundred
Witnesses (`faction.hundred_witnesses`) supersede the earlier Dawn Concordat
and Unbound Flame as the provisional faction display names. The semantic IDs
are stable even when the display names change. Both display names remain
provisional working names; final faction naming is owned by Issue #54.
Historical research and completed evidence that use the earlier names remain
unchanged.

Playable anatomy, visual identity, culture, and presentation contracts are
defined in [Playable Peoples](playable-peoples.md).

## Faction Conflict

### Crowned Ledger - Working Name

The Crowned Ledger, previously recorded under the working name Dawn Concordat,
believes scarce Ember-light must be regulated and shared under a common law.
Its members fear that independent stockpiles will create another Duskbreak.

The Crowned Ledger preserves accountable continuity but risks owned truth: a
single lawful record of what happened, held by the few empowered to write it.
Its virtues are discipline, collective defense, and continuity. Its dangers are
authoritarian control, procedural cruelty, and the belief that individual lives
can be sacrificed for stability.

Gameplay identity:

- Wards, banners, formation support, and defensive siege tools.
- Holding ground and protecting shared objectives.
- Regulated travel and resource logistics.
- Doctrine choices that reward coordination and prepared defense.

### Hundred Witnesses - Working Name

The Hundred Witnesses, previously recorded under the working name Unbound
Flame, believe settlements and individuals who recover Embers should decide
how to use them. Its members view the Concord's monopoly as a different form
of slow extinction.

The Hundred Witnesses protect plurality but risk fragmentation and paralysis:
truth held by many independent witnesses can survive any single tyrant, yet it
may never agree on one answer in time to act.
Its virtues are autonomy, adaptability, mercy, and local responsibility. Its
dangers are fragmentation, hoarding, opportunism, and extremists who confuse
freedom with entitlement.

Gameplay identity:

- Mobility, disruption, infiltration, and field improvisation.
- Breaking formations and stealing contested resources.
- Flexible travel and independent supply.
- Doctrine choices that reward timing, adaptation, and coordinated disruption.

### The Concord

The Concord is the old legal and religious structure governing Ember use. It is
not identical to the Crowned Ledger, although the Crowned Ledger broadly
supports it. The Concord attempts to mediate the conflict while also protecting
its authority.

### The Ashen Choir

The Ashen Choir is hostile to both player factions. It is the surviving remnant
of the Lucent Choir and intends to complete the ritual that cracked the Waking
Star.

The Ashen Choir must not become a playable faction in the initial design.

## The Unison

The Unison is a growing movement that offers relief from unbearable memory. It
began as voluntary relief: consenting sufferers asked its practitioners to
still a memory, a grief, or a dying moment, and Corvath's preservation practice
is widely cited as its most famous precedent. Over the course of the story the
Unison evolves from voluntary relief into enforced mercy, deciding for others
which suffering must end.

The Unison is not a player faction. Members and sympathizers exist inside both
the Crowned Ledger and the Hundred Witnesses, and each faction reads the
movement through its own fear: the Crowned Ledger sees unaccountable erasure of
the record, and the Hundred Witnesses see a new monopoly over what may be
remembered. Its trajectory converges with Sevrin Vale's belief that the Onefold
Vault can end suffering outright.

## The Five Orders

The Orders are the surviving martial and scholarly institutions that train the
Emberbound. In gameplay terms, an Order is the game's class. Under Issue #104,
the five Orders below supersede the earlier four initial class concepts
(Bulwark, Skeinblade, Embercaller, and Lumen); Oathscar specifically supersedes
Skeinblade as the active initial Order working label. Historical research and
completed evidence keep the earlier labels unchanged.

Shared Order rules:

- Every listed Order, specialization, and Peak display name is a working name
  with a stable semantic ID. IDs remain stable when display names change.
- Every playable people and sex may join every Order, and every Order serves
  either faction. Orders are institutions, not faction organs.
- Each Order swears one oath. Its two specializations are the two dominant
  interpretations of that oath, and a member's specialization selects which
  interpretation governs their practice.
- Each Order guards one Peak: a technique that briefly realizes a forbidden
  version of the character. Peaks are feared, regulated, and central to each
  Order's taboos.
- Each Order channels one named combat resource. Resource names are working
  names; each is the selected presentation of the shared OrderResource slot.
  All resource behavior and numeric tuning remain `TBD`.

| Order | Stable ID | Specializations | Peak | Resource | Weapon traditions |
| --- | --- | --- | --- | --- | --- |
| Oathscar | `order.oathscar` | Ironwake (`order.oathscar.spec.ironwake`), Last Gate (`order.oathscar.spec.last_gate`) | Oathbreak (`order.oathscar.peak.oathbreak`) | Grudge | Greatsword, sword-and-shield, two-handed spear, dual wield |
| Nullwright | `order.nullwright` | Ashscript (`order.nullwright.spec.ashscript`), Black Geometry (`order.nullwright.spec.black_geometry`) | Contradiction (`order.nullwright.peak.contradiction`) | Proof | Staff, focus gauntlet, grimoire-blade, orbiting seals |
| Hushblade | `order.hushblade` | Red Echo (`order.hushblade.spec.red_echo`), Hollow Guard (`order.hushblade.spec.hollow_guard`) | Missing Second (`order.hushblade.peak.missing_second`) | Tempo | Twin knives, sheathed blade, chain-sickle, needle fan |
| Gravecant | `order.gravecant` | Dirge (`order.gravecant.spec.dirge`), Refrain (`order.gravecant.spec.refrain`) | Last Chorus (`order.gravecant.peak.last_chorus`) | Cadence | Chime-staff, mace-reliquary, chain-censer, tome-rod |
| Blackfletch | `order.blackfletch` | Far Thorn (`order.blackfletch.spec.far_thorn`), Waykeeper (`order.blackfletch.spec.waykeeper`) | Narrowed Horizon (`order.blackfletch.peak.narrowed_horizon`) | Tension | Longbow, recurve bow, greatbow, tether/trap bow |

Every name in the Resource column is the Order-specific presentation of the
shared `combat.resource.order` slot: Grudge maps to `order.oathscar`, Proof to
`order.nullwright`, Tempo to `order.hushblade`, Cadence to
`order.gravecant`, and Tension to `order.blackfletch`. Changing an Order changes
which authored resource rules may occupy that slot; it does not turn Health,
Endurance, Guard, or Ward into an Order resource. The server validates the
selected Order, its stable ID, and the compatible resource definition. A client
cannot request another Order's resource identity or claim a gain, spend, or
refund.

The prototype remains one `order.oathscar` character using sword and shield.
Grudge is canonical Oathscar intent but is not part of the default prototype
resource subset. Issue [#107](https://github.com/ShayShimoni/aetheln-online/issues/107)
may define one optional Oathbreak exercise; any resulting bounded attribute or
ability work remains owned by Issue
[#19](https://github.com/ShayShimoni/aetheln-online/issues/19). This document
does not schedule the complete Oathscar kit, its specializations, Peak, other
weapon traditions, or any other Order. Exact generation, spend, decay, caps,
and UI values remain tuning `TBD`.

### Oathscar - Working Name

The Oathscar swear to stand where a promise was made. Their oath binds a sworn
grievance to the body: an Oathscar carries every unresolved wrong as Grudge and
spends it in combat.

- **Recruitment:** the Order accepts petitioners who can name one wrong they
  refuse to release. Veterans of broken sieges, disgraced guards, and survivors
  of unpunished crimes are common; the rite of entry is the public statement of
  the grudge before witnesses.
- **Duties:** hold gates, escorts, and last lines; enforce sworn contracts of
  protection; stand witness at executions and truces so neither side can later
  deny what was promised.
- **Taboos:** an Oathscar must not swear a grudge they do not personally hold,
  abandon a sworn charge while alive, or invoke Oathbreak - the Peak that
  briefly realizes the self who broke every oath - except when the sworn charge
  is already lost.
- **Internal conflicts:** the Ironwake interpretation reads the oath as
  advancing punishment and argues grudges exist to be spent; the Last Gate
  interpretation reads it as immovable protection and argues a spent grudge is
  a failed vigil. The Order also disputes whether a lawful order can dissolve a
  personal grudge.
- **Weapon traditions:** greatsword, sword-and-shield, two-handed spear, and
  dual wield. Each tradition is taught as a form of standing ground: the
  greatsword answers many, the shield answers a line, the spear answers a
  charge, and paired blades answer a single named enemy.
- **Faction relationships:** the Crowned Ledger values Oathscar witness-duty
  and hires them to guarantee its rulings, but distrusts grudges that outrank
  the law. The Hundred Witnesses treat a personal grudge as the purest owned
  truth, but fear the Order's habit of enforcing settlements no community
  voted for.
- **Named characters:** Kaelen Dross carries the Order's defining wound - his
  sworn commission against his brother Maren - and his epithet, the Last Gate,
  names the specialization he embodies. Vothram, the Forgedoor, is an Oathscar
  of the Ironwake line whose falsified vault records are a live breach of the
  Order's witness duty.

#### Canonical Intent

This full design shard has maturity **Canonical Intent**. Display names remain
working names, while the semantic IDs below are stable references for the
future registry. It defines product behavior and compatibility boundaries; it
does not claim **Evidence Validated** or **Implementation Ready** maturity.

The Oathscar's mechanical identity is committed, readable pressure. They take
and hold a line with active defense, then answer a witnessed wrong through an
aimed, deliberately committed attack. Their base kit must remain functional
without a specialization, Grudge, a Skein loadout, equipment bonuses, a
Doctrine, or another player. Specialization and build choices change how the
Oathscar applies pressure; they do not supply the missing half of an otherwise
nonfunctional class.

One authoritative weapon discipline is active in combat. A weapon model,
animation, client request, or equipped presentation cannot select or combine
discipline rules. The server validates the active discipline, its compatible
ability definitions, and any allowed transition before accepting an
activation. Rules for learning, changing, and persisting a discipline belong
to Issues [#112](https://github.com/ShayShimoni/aetheln-online/issues/112) and
[#113](https://github.com/ShayShimoni/aetheln-online/issues/113).

| Weapon discipline | Stable ID | Mechanical identity |
| --- | --- | --- |
| Greatsword | `order.oathscar.weapon.greatsword` | Broad committed sweeps and heavy Wrought pressure that threaten a held approach but expose readable wind-up and recovery. |
| Sword-and-shield | `order.oathscar.weapon.sword_and_shield` | Directional defense, short counter-pressure, and deliberate advances that exchange reach and pursuit for control of the immediate line. |
| Two-handed spear | `order.oathscar.weapon.two_handed_spear` | Aimed reach and charge denial that reward spacing while becoming vulnerable when an opponent crosses the authored point-control window. |
| Dual wield | `order.oathscar.weapon.dual_wield` | Focused pursuit of one sworn opponent through successive free-aim commitments, without lock-on, homing, or client-selected-target authority. |

Ironwake (`order.oathscar.spec.ironwake`) interprets the oath as advancing
punishment. It favors forcing a response, spending earned pressure, and
continuing through a contested line, but it does not gain automatic contact or
protection during commitment. Last Gate (`order.oathscar.spec.last_gate`)
interprets the oath as immovable protection. It favors interception,
directional defense, and punishments earned by correctly holding a line, but it
does not create passive Guard, omnidirectional block, or permanent denial.
Neither specialization changes pure free aim, the shared defense order, or the
meaning of Health, Endurance, Guard, Ward, or OrderResource.

Grudge (`order.oathscar.resource.grudge`) is the Oathscar presentation of the
shared `combat.resource.order` slot. It records server-recognized grievances
that the Oathscar can answer through compatible authored actions. A qualifying
grant exists only after its source combat result commits; the server records it
at most once for the result's stable activation or effect identity, so replay,
prediction, reordered delivery, or reconnect cannot grant it twice. A spend is
likewise accepted and committed by the server against compatible content and
current authoritative state. Grudge is not Guard, bonus Health, Ward,
Endurance, threat, or an ownership claim over an opponent. It cannot be granted
because a client reports being hit, names a target, or claims a successful
block. Qualifying events, decay, bounds, costs, refunds, and every numeric rule
remain tuning `TBD`.

Oathbreak (`order.oathscar.peak.oathbreak`) briefly realizes the forbidden
Oathscar who abandons the sworn line to force an ending. An accepted activation
enters a server-owned temporary Peak state whose compatible Oathscar actions
use explicitly authored aggressive variants. If an authored rule spends or
grants Grudge, the server validates and commits that resource transition;
presentation cannot create or refund it. Oathbreak does not convert Guard into
damage, grant invulnerability, bypass
Wrought/Cinder/Wake mitigation, erase costs or recovery, or make presentation
authoritative. Opponents must receive a distinct activation tell, readable
active state, and readable ending/recovery. Their counterplay is to evade the
free-aim commitments, break contact, force poor facing, interrupt only where
the authored window permits, or punish the defensive actions that Oathbreak
replaces. Eligibility, Grudge cost and grant/refund policy during the Peak,
duration, action replacements, cancellation, final recovery, and all numeric
values remain `TBD`.

The complete base kit must support solo play before specialization or build
choices: the Oathscar can approach, apply Wrought damage, defend directionally,
dodge, interrupt through an authored action where eligible, recover through
the shared combat rules, defeat a representative ordinary enemy, and survive
or fail through readable decisions. It must not require an ally to create a
target, generate a resource, cover an unavoidable weakness, or finish a basic
combat loop. Group play may reward line holding and interception without making
solo viability depend on party state.

Oathscar counterplay remains structural:

- attacks and advances carry authored wind-up, active, and recovery phases;
- directional defense loses to valid angle, timing, Guard pressure, or an
  authored unblockable rule rather than protecting every side passively;
- Endurance, Guard, Grudge, cooldowns, and action state remain distinct limits,
  with no automatic conversion that hides a failed decision;
- greatsword and spear commitments can be crossed or avoided, dual-wield
  pursuit can be disengaged or interrupted as authored, and sword-and-shield
  gives up reach and pursuit for immediate-line control; and
- the Order receives no inherent long-range homing, unavoidable damage,
  permanent control immunity, free sustain, or client-authoritative shortcut.

The following are representative weave definitions at **Canonical Intent**,
not an approved final collection, slot count, unlock schedule, or tuning set:

| Kind | Working name and stable ID | Decision changed |
| --- | --- | --- |
| Form | Advancing Answer (`order.oathscar.form.gate_step.advancing_answer`) | Changes Gate Step into a more committed advance; contact, movement, and recovery remain authored and server resolved. |
| Form | Rooted Answer (`order.oathscar.form.gate_step.rooted_answer`) | Gives up the advance so Gate Step contests Guard from a held position; it is mutually exclusive with Advancing Answer for that ability. |
| Form | Closed Oath (`order.oathscar.form.hold_the_line.closed_oath`) | Narrows Hold the Line to a more committed directional defense with a distinct readable facing requirement. |
| Thread | Witnessed Reprisal (`order.oathscar.thread.witnessed_reprisal`) | A committed perfect-block result authorizes one compatible follow-up; duplicate result delivery cannot authorize it again. |
| Thread | Unbroken Sequence (`order.oathscar.thread.unbroken_sequence`) | Completing the authored basic chain without a miss changes the next compatible Sworn Rebuke rather than adding an invisible passive bonus. |
| Thread | Ground Reclaimed (`order.oathscar.thread.ground_reclaimed`) | A committed dodge result changes the next compatible Gate Step; a predicted dodge alone cannot trigger it. |
| Keystone | Debt Comes Due (`order.oathscar.keystone.debt_comes_due`) | Makes committed Grudge spends favor continuing offensive pressure while preserving the normal defense and authority rules. |
| Keystone | The Line Remembers (`order.oathscar.keystone.the_line_remembers`) | Makes correctly resolved directional defense favor deliberate counter-pressure without turning Guard into Grudge or passive damage. |

Forms modify only their referenced ability, Threads consume bounded and visible
server-owned triggers, and one Keystone changes the build's central rhythm.
None may create a target, contact, hit, resource result, or recursive proc from
client presentation. Compatibility, listener budgets, cycles, versioning, and
machine-readable generation remain owned by
[#106](https://github.com/ShayShimoni/aetheln-online/issues/106); compiled
builds, presets, persistence, and atomic equipment changes remain owned by
[#113](https://github.com/ShayShimoni/aetheln-online/issues/113).

#### Sword-and-Shield Prototype Candidate

Only this bounded subset has maturity **Prototype Candidate**. The authoritative
discipline is fixed to `order.oathscar.weapon.sword_and_shield` in one
controlled combat space. Its default playable contract is exactly:

- Health, Endurance, and active Guard under their shared semantic identities;
- one server-owned, pure-free-aim, three-hit Wrought basic combo
  (`order.oathscar.ability.sword_shield_basic_chain`);
- directional block, the shared prototype dodge, and exactly three
  representative active abilities:
  - Gate Step (`order.oathscar.ability.gate_step`), an aimed, server-bounded
    shield-led advance with authored Wrought contact and Guard pressure;
  - Sworn Rebuke (`order.oathscar.ability.sworn_rebuke`), an aimed committed
    Wrought answer with an authored interruption rule; and
  - Hold the Line (`order.oathscar.ability.hold_the_line`), an active
    directional defensive commitment whose Guard result comes only from the
    authoritative contact and facing check;
- one representative enemy; and
- authoritative damage, readable acceptance/correction/rejection feedback,
  death, and respawn.

All damage, Guard pressure, Endurance costs, cooldowns, ranges, shapes, movement,
phase timings, interruption rules, recovery, enemy values, and other tuning are
`TBD` for their owning implementation and evidence work. The active abilities
describe distinct prototype decisions; their working names do not approve
animation, VFX, audio, or final balance.

The default prototype does not read, grant, spend, display, or persist Grudge
and does not depend on Ironwake, Last Gate, Oathbreak, Forms, Threads,
Keystones, equipment, Doctrine, inventory, a specialization trial, weapon
learning, or a wider Order roster. It therefore remains functional with no
Skein selection and no durable character-system dependency.

One optional Oathbreak exercise may separately instantiate
`order.oathscar.peak.oathbreak` with fixed, temporary test state. It is not part
of the default loop, does not unlock or persist anything, does not mutate
inventory or saved build state, and does not require the default prototype to
implement Grudge. The exercise must end by restoring or discarding only its
explicit temporary state; disconnect, retry, death, or replay cannot preserve a
Peak grant or duplicate a result. Passing that exercise would not validate the
full Oathbreak, Grudge, specialization, or Skein designs.

This shard retains existing delivery ownership:

| Owner | Boundary retained |
| --- | --- |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Dodge cost, cooldown, authoritative defensive window, correction, and network evidence. |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | PlayerState-owned GAS attributes, resources, effects, abilities, cooldowns, replication, rollback, and bounded optional-Peak attribute/resource/effect/ability work. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Representative enemy authority, target choice, attack behavior, and runtime evidence. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Integrated death, respawn, reconnect, stale-state cleanup, and duplicate-completion tests. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Server-owned attack timeline, authored free-aim contacts, deterministic ordering, and the three-hit chain. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61) | HUD, readable combat feedback, accessibility-safe cues, and correction/rejection presentation. |
| [#82](https://github.com/ShayShimoni/aetheln-online/issues/82) | Input, camera, bounded aim intent, and measured pure-free-aim feel. |
| [#84](https://github.com/ShayShimoni/aetheln-online/issues/84) | Attack, defense, telegraph, volume, animation, and presentation authoring pipeline. |
| [#106](https://github.com/ShayShimoni/aetheln-online/issues/106) | Registry schema, stable-ID validation, maturity validation, generation, drift checks, and bounded proc/listener rules. |
| [#112](https://github.com/ShayShimoni/aetheln-online/issues/112) | Specialization trial/reset, weapon learning, Heritage, and Order-mastery rules. |
| [#113](https://github.com/ShayShimoni/aetheln-online/issues/113) | Skein compilation, presets, compatibility manifests, persistence, and atomic equipment/build changes. |
| [#115](https://github.com/ShayShimoni/aetheln-online/issues/115) | Downstream canonical, roadmap, brief, ledger, glossary, generated-artifact, and board reconciliation. |

No statement in this shard is runtime, packaged, balance, performance,
security, readability, accessibility, or QA evidence. Only the bounded subset
above is a Prototype Candidate; every broader Oathscar definition remains
Canonical Intent.

### Nullwright - Working Name

The Nullwright swear to test what the world claims is true. They treat the
Deepwake's rejected histories as propositions and combat as demonstration;
their resource, Proof, accumulates as their claims survive contact.

- **Recruitment:** the Order recruits from archivists, failed Concord clerks,
  and anyone who has caught the world in a contradiction. Entry requires
  publicly disproving one accepted account, however small.
- **Duties:** audit Ember records and attunement claims, map unstable
  Deepwake incursions, and unmake constructs of forced history left over from
  the Great Concordance.
- **Taboos:** a Nullwright must not assert what they cannot demonstrate,
  falsify a record even to save a life, or hold the Peak of Contradiction -
  briefly realizing a self whose premises are false - long enough to believe
  it.
- **Internal conflicts:** Ashscript practitioners erase failed histories and
  argue the kindest record is a closed one; Black Geometry practitioners bind
  contradictions into standing seals and argue nothing should be erased before
  it is understood. Their standing dispute is whether the Waking Star's intent
  is a solvable question.
- **Weapon traditions:** staff, focus gauntlet, grimoire-blade, and orbiting
  seals. The Order teaches each as a notation: the staff states, the gauntlet
  underlines, the grimoire-blade cites, and the seals hold open arguments in
  the air.
- **Faction relationships:** the Crowned Ledger relies on Nullwright audits to
  keep its single record honest and resents how often the audits succeed. The
  Hundred Witnesses admire the Order's refusal to accept owned truth while
  suspecting that Proof is simply a ledger by another name.
- **Named characters:** Aldrec Fane, the Pyrelaw, works in the Nullwright
  manner - his case against Serra is real evidence serving an inhuman
  conclusion, the exact failure the taboos exist to prevent. Saeril,
  Nine-Dreams, is the Order's living cautionary text: her journal is a
  Nullwright record of a self she can no longer demonstrate.

### Hushblade - Working Name

The Hushblade swear to end violence in the least time possible. Their art is
subtraction - the removed step, the unspent breath, the missing second - and
their resource, Tempo, is the rhythm they steal from a fight.

- **Recruitment:** the Order takes students who survived violence they could
  not match, and teaches that reads, timing, and judgment beat raw attunement.
  Many recruits arrive through Nhalen's public salles.
- **Duties:** escort negotiators through mixed territory, remove specific
  military targets under faction sanction, and train civilians to survive the
  frontier.
- **Taboos:** a Hushblade must not prolong a kill, take a contract on a target
  they cannot name, or enter the Missing Second - the Peak that briefly
  realizes the self who was never seen - to escape a debt rather than a death.
- **Internal conflicts:** the Red Echo interpretation pursues and punishes,
  arguing that a fight ends when the aggressor cannot repeat it; the Hollow
  Guard interpretation slips and protects, arguing that a fight ends when the
  victim is out of reach. The Order also argues over sanctioned kill contracts:
  discipline or hire-murder with etiquette.
- **Weapon traditions:** twin knives, sheathed blade, chain-sickle, and needle
  fan. Each is taught as a grammar of economy: the knives converse, the
  sheathed blade answers once, the chain-sickle controls the distance of the
  conversation, and the needle fan punctuates it.
- **Faction relationships:** the Crowned Ledger licenses Hushblade contracts
  to keep killing accountable and on record; the Order accepts the license and
  ignores it when the record would name a client. The Hundred Witnesses shelter
  Hushblades as proof that skill owes nothing to sanctioned attunement, while
  quietly fearing blades that answer to no assembly.
- **Named characters:** Nhalen, the Gutterlight, is the Order's finest living
  instructor and its conscience - severed from Ember attunement, he embodies
  the claim that the art needs no borrowed light. Serra Vale trains in the
  Hushblade manner under scrutiny from both factions; Kaelen trained her early
  guard and knows what the Concord's demands are doing to her.

### Gravecant - Working Name

The Gravecant swear that nothing true should end unwitnessed. They sing the
dying into coherent memory and the living back into continuity; their
resource, Cadence, is the measured breath of that song.

- **Recruitment:** the Order calls singers, Ninh-priests, bonesetters, and
  mourners - anyone who has kept a vigil to its end. Entry is a night spent
  witnessing a stranger's passing and recording it truly.
- **Duties:** keep the witnessed records from which the Emberbound respawn,
  tend Forgettings when they can be recovered and end them when they cannot,
  and hold funeral truces that both factions honor.
- **Taboos:** a Gravecant must not falsify a witnessed record, sing the Last
  Chorus - the Peak that briefly realizes the self who already died - over one
  who can still be saved, or refuse witness to an enemy.
- **Internal conflicts:** the Dirge interpretation carries endings to the
  unwilling and shades toward the Unison's enforced mercy; the Refrain
  interpretation restores and repeats, holding that a witness serves the
  living first. The Unison's evolution is the Order's central crisis: relief
  that was once asked for is beginning to be imposed.
- **Weapon traditions:** chime-staff, mace-reliquary, chain-censer, and
  tome-rod. Each doubles as liturgical instrument: the chime-staff keeps the
  measure, the reliquary carries a witnessed name, the censer marks the
  boundary of a vigil, and the tome-rod is the record made weapon.
- **Faction relationships:** the Crowned Ledger treats Gravecant records as
  admissible law and presses to own them; the Order refuses, holding that a
  witness belongs to the witnessed. The Hundred Witnesses celebrate the Order
  as a hundred witnesses in literal fact, yet resist any suggestion that its
  records outrank a community's memory.
- **Named characters:** Matron Halveth, the Ledger, commands the Order's
  lawful wing and authorized Kaelen's commission; her name is the Crowned
  Ledger's argument made flesh. Corvath, the Still, stands at the Order's
  edge: his glass preservation is either the perfect witness or the refusal
  to let a record close, and the Unison claims him as precedent either way.

### Blackfletch - Working Name

The Blackfletch swear to see the path before it is walked. They are wardens of
distance - scouts, hunters, and route-keepers - and their resource, Tension,
is the drawn stillness between sighting and release.

- **Recruitment:** the Order recruits frontier guides, caravan scouts, and
  Selaen-trained forecast readers. Entry is a solitary crossing of hostile
  ground with nothing but a bow and one arrow, returned unspent.
- **Duties:** watch the frontier thresholds where protected territory ends,
  mark and tether Deepwake incursions before they spread, keep caravan routes
  and Emberfall predictions honest, and deny ground rather than take it.
- **Taboos:** a Blackfletch must not loose without a named target, abandon a
  marked route while travelers still trust it, or hold the Narrowed Horizon -
  the Peak that briefly realizes the self who sees only one future - after the
  shot is taken. "Named target" is an Order oath and authored intent, not a
  target lock, client-selected authoritative target, guaranteed contact, or
  exception to pure free aim.
- **Internal conflicts:** the Far Thorn interpretation strikes at the greatest
  distance and argues the kindest arrow arrives before the war does; the
  Waykeeper interpretation traps, tethers, and escorts, arguing that an Order
  of wardens must never become an Order of assassins. The Order also disputes
  how far to trust Vesh dream forecasts over walked ground.
- **Weapon traditions:** longbow, recurve bow, greatbow, and tether/trap bow.
  The traditions are taught as ranges of responsibility: the longbow watches a
  region, the recurve rides with a caravan, the greatbow answers a siege, and
  the tether/trap bow closes a route without a corpse.
- **Faction relationships:** the Crowned Ledger contracts Blackfletch wardens
  to police regulated routes and resents that the Order also marks the
  Ledger's own convoys. The Hundred Witnesses depend on Blackfletch paths for
  independent supply and chafe when a Waykeeper closes a route no assembly
  agreed to close.
- **Named characters:** the Order keeps Selaen's dream-forecast tables and is
  the standing customer of Lanternrest's readers, which puts it inside the
  Vesh argument over foreknowledge and free choice. Nhalen sends Hushblade
  students to Blackfletch wardens to learn patience, and Aldrec Fane uses
  chartered Blackfletch trackers in his hunt for Ashen Choir survivors - a
  charter the Waykeeper line publicly protests.

## The Emberbound Table

The Emberbound Table contains champions whose loyalties divide the world. They
are connected by the Duskbreak, Concord law, and Choirmaster Sevrin Vale.

The Emberbound are those who carry realized Embers. When an Emberbound dies,
the world restores them from their last coherent witnessed record; keeping
those records true is a Gravecant duty. What an Emberbound loses between the
record and the death is a story question, not a combat statistic.

### Kaelen Dross - The Last Gate

- **People:** Aurin
- **Order:** Oathscar, Last Gate specialization
- **Current alignment:** Crowned Ledger
- **Combat lesson:** block, flank, feint, and punish

Kaelen served as the Concord's executioner. His final commission was his own
brother, Maren, who murdered pilgrims for a dying Ember. Kaelen performed the
death rite himself and forged his tower shield from the door of their family
home.

Kaelen believes law prevented greater bloodshed, but Corvath's preservation of
Maren forces him to live beside the possibility that duty did not end his
brother's suffering.

Conflict:

- Enforces the system Nhalen considers unjust.
- Respects Vothram despite their opposing politics.
- Trained Serra and recognizes that the Concord is consuming her family.
- Could become either the Crowned Ledger's unbreakable defender or the person
  who finally refuses an order.

### Serra Vale - The Ashen Heir

- **People:** Aurin
- **Order:** Hushblade
- **Current alignment:** undecided at the beginning
- **Combat lesson:** attack commitment, dodge timing, and recovery punishment

Serra is the last known descendant of Sevrin Vale, the Choirmaster who cracked
the Star. Rather than execute the Vale family, the Concord condemned every
generation to publicly earn back a name that can never be cleared.

The Ashen Choir has begun contacting her. Her story is not a simple corruption
arc: both factions want to turn her inherited guilt into a political weapon.

Conflict:

- Crowned Ledger leaders demand proof of loyalty that can never be complete.
- Hundred Witnesses leaders offer freedom but may want her name more than her
  trust.
- Aldrec believes she is already compromised.
- Her faction decision is a major story pivot and remains intentionally open.

### Nhalen - The Gutterlight

- **People:** Vesh
- **Order:** Hushblade
- **Current alignment:** Hundred Witnesses
- **Combat lesson:** reads, timing, and skill over raw attunement

Nhalen killed an Ashen Choir agent to save a captive child. No sanctioned
arbiter was present, so the Concord applied its law without considering motive.
His attunement was severed and he was permanently barred from holding an Ember.

Nhalen fights without supernatural advantage and remains one of the finest
combat instructors alive.

Conflict:

- Aldrec confirmed the killing was justified and concealed that truth.
- Kaelen represents the enforcement that destroyed Nhalen's future.
- Nhalen opposes the Concord but rejects indiscriminate revenge.
- He teaches players that equipment and light create options, not automatic
  victory.

### Saeril - Nine-Dreams

- **People:** Vesh
- **Order:** Nullwright
- **Current alignment:** public Crowned Ledger figurehead
- **Combat lesson:** gap closing, interruption, and zone pressure

Saeril is the greatest living Ember champion. Each Ember she integrated consumed
a memory. She records her lost identity in a journal because she no longer
remembers why she began climbing.

Her ninth recurring dream identifies a future betrayal within the Emberbound
Table. She has not revealed the traitor or whether the act is truly a betrayal.

Conflict:

- The Crowned Ledger uses her as proof that controlled ascension works.
- The Hundred Witnesses see her as proof that the system consumes its
  champions.
- Matron Halveth manages her decline.
- Her eventual decision can change the perceived legitimacy of the faction war.

### Aldrec Fane - The Pyrelaw

- **People:** Aurin
- **Order:** Nullwright, Ashscript specialization
- **Current alignment:** Crowned Ledger hardliner
- **Combat lesson:** movement, pressure zones, and low-health danger

Aldrec is a Concord inquisitor whose family died in an Ashen Choir atrocity. His
commitment to destroying the Choir is sincere.

He also verified that Nhalen acted to save a child and allowed the punishment to
stand because he believed the law's example mattered more than one innocent
life.

Conflict:

- Builds a case against Serra from evidence that is real but incomplete.
- Audits Vothram's vault while Vothram falsifies its records.
- Treats Hundred Witnesses autonomy as the first stage of another catastrophe.
- Embodies the danger of correct facts serving an inhuman conclusion.

### Corvath - The Still

- **People:** Kell
- **Order:** Gravecant, Refrain specialization
- **Current alignment:** Hundred Witnesses sympathizer
- **Combat lesson:** line of sight, healing angles, and area control

Corvath crystallized from the glassed earth during the Duskbreak and remembers
the catastrophe from inside its light. He remains a unique living-glass Kell:
his complete material state is not ordinary Kell biology or an available player
appearance.

He preserves people at the instant before death as conscious, painless living
glass. Among them is Maren Dross. Corvath considers this mercy; others consider
it an endless refusal to let the dead pass.

Conflict:

- Rejects Concord ownership of memory and death.
- Opens the sealed Hollow Choirhouse for the player.
- Opposes Halveth over whether remembrance belongs in a ledger or a living
  witness.
- His preservation practice divides even his Hundred Witnesses allies, and the
  Unison claims it as precedent.

### Vothram - The Forgedoor

- **People:** Kell
- **Order:** Oathscar, Ironwake specialization
- **Current alignment:** covert Hundred Witnesses supporter
- **Combat lesson:** Guard and Endurance pressure, and heavy commitment

Vothram forged the instruments Sevrin used to crack the Star. He did not know
their purpose, but ignorance did not save the cities they destroyed.

He now guards the Concord's Ember vault. Secretly, he preserves memory-Embers
that the law requires him to surrender and allow to expire.

Conflict:

- His archive can preserve history or become a private hoard.
- The Ashen Choir knows the vault's true inventory.
- Aldrec is closing in on the falsified records.
- Kaelen is his rival, friend, and political opposite.

### Matron Halveth - The Ledger

- **People:** Aurin
- **Order:** Gravecant, Dirge specialization
- **Current alignment:** Crowned Ledger authority
- **Combat lesson:** patience, denial, and cooldown discipline

Halveth controls attunement rites. She once refused an unready village champion.
Without an eligible claimant, the village could not replace its dying
Ember-well, and hundreds died.

She records every person affected by her decisions but continues to believe
that consistent law is the only barrier against collapse.

Conflict:

- Represents lawful harm rather than personal malice.
- Controls access to power the Hundred Witnesses want decentralized.
- Manages Saeril's loss of memory.
- Authorized Kaelen's commission against Maren.

## Primary Antagonist

### Choirmaster Sevrin Vale

- **Faction:** Ashen Choir
- **Role:** initial dungeon antagonist and living origin of the faction crisis

Sevrin led the Great Concordance, the attempt to make the golden age eternal by
forcing incompatible histories to coexist. The ritual cracked the Waking Star,
caused the Duskbreak, and left him sustained by the stolen light.

He believes the failure came from incomplete execution rather than a false
premise. He now believes the Onefold Vault - a completed Concordance holding
every history reconciled in one place - can end suffering itself. The Waking
Star never clearly commands him: whether his conviction is guidance, echo, or
delusion remains disputed, and that dispute is deliberate canon. Both player
factions oppose him, but each uses his crime to justify a different future for
Ember control. The Unison's turn toward enforced mercy runs parallel to his
promise.

## Relationship Threads

### Law and Autonomy

Halveth authorizes, Kaelen enforces, Aldrec investigates, and Nhalen bears the
punishment. Their conflict gives the faction war a human cost.

### Blood of the Duskbreak

Sevrin designed the ritual, Vothram forged its instruments, Corvath was created
by its destruction, Serra inherited its blame, and Aldrec hunts its survivors.

### Memory and Ownership

Saeril loses memories to power, Vothram steals memories to preserve them,
Corvath keeps memory alive in glass, and Halveth records the dead in law. The
faction conflict asks whether memory can ever be owned for the common good.

### Future Fractures

- Saeril's ninth dream points to a traitor.
- Serra must choose whether either faction deserves her loyalty.
- Kaelen may refuse an order involving Maren.
- Aldrec's concealment of Nhalen's innocence can damage the Crowned Ledger.
- Vothram's archive can strengthen the Hundred Witnesses' cause or expose its
  hypocrisy.

## Character Creation Rules

- Aurin, Kell, Vesh, and future playable races support male and female
  characters.
- Sex, body preset, and race do not change combat statistics or hitboxes.
- Every playable race may use every supported Order (the game's class).
- Every playable race may join either player faction.
- Character appearance and voice are independent from Order, faction, Skein,
  equipment, and progression data.
- Aurin, Kell, and Vesh use the race-specific appearance and shared combat
  contracts defined in [Playable Peoples](playable-peoples.md).

Faction selection enters the playable delivery in 2.0. Before that stage,
persisted characters use `Faction = Unassigned` and have no Doctrine. The
approved one-time selection then assigns the protected starting territory,
faction story, and Doctrine; any later faction-change policy remains open.
