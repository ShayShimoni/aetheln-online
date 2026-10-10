# Aetheln Online Documentation Index

## Canonical Product and Design Documents

These documents govern player-facing behavior, lore, progression, and world
rules. Read the Bible first, then the specialized document for the system.

1. [Game Design Bible](game-design-bible.md)
2. [Playable Peoples](playable-peoples.md)
3. [Characters and Factions](characters-and-factions.md)
4. [World, Settlements, and Open-World PvP](world-and-settlements.md)
5. [Progression, Loot, and Skein Weaving](progression-loot-and-skein.md)

## Canonical Technical Documents

These documents govern implementation boundaries. They must implement the
canonical product rules rather than redefine them.

1. [Technical Architecture](technical-architecture.md)
2. [Combat and Networking Architecture](combat-and-networking-architecture.md)
3. [World Runtime and Building](world-runtime-and-building.md)
4. [Progression and Persistence Architecture](progression-and-persistence-architecture.md)
5. [Security and Operations](security-and-operations.md)
6. [Performance, Quality, and Delivery](performance-quality-and-delivery.md)
7. [Architecture Decisions](architecture-decisions.md)

## Stage Contracts and Traceability

After reading the applicable canonical product and technical documents, read
these documents in order:

1. [Prototype and 1.0 Scope Ledger](prototype-and-1.0-scope-ledger.md) records
   the normative Issue #71 inventory and requirement dispositions.
2. [Prototype Game Brief](GameBrief.md) summarizes the pre-1.0 prototype stage
   contract.
3. [1.0 Cooperative Vertical-Slice Brief](cooperative-vertical-slice-1.0-brief.md)
   summarizes the separate 1.0 stage contract.
4. [Prototype and 1.0 Supporting Artifacts](prototype-and-1.0-supporting-artifacts.md)
   provides subordinate decision, terminology, state, release, threat, test,
   and provenance traceability.
5. [Staged Multiplayer Threat Model](staged-multiplayer-threat-model.md)
   records the Issue #40 prototype baseline, representative 1.0 threat and test
   specifications, risk decisions, and follow-up traceability.

The briefs and traceability artifacts summarize stage contracts and remain
subordinate to the specialized canonical product and technical documents.

## Delivery and Work Status

- [Repository Roadmap](../README.md) defines release boundaries and dependency
  order.
- [Prototype Roadmap](next-steps-mmorpg-prototype.md) expands the pre-1.0
  prototype.
- [Playable Movement POC](movement-poc.md) records the temporary local
  movement-feel exception, imported asset provenance, and verification evidence
  for issue #100.
- [Networking Authority Spike: Unit 1](networking-authority-spike.md) records
  the Issue #2 replication-neutral authority baseline, evidence boundaries,
  focused verification commands, and remaining candidate and measurement work.
- [Structured Observability and Crash Diagnostics](observability-and-crash-diagnostics.md)
  records the Issue #38 event, metric, redaction, lifecycle, crash-context,
  environment, retention, and downstream-ownership contracts.
- [Gameplay Ability System Foundation](gas-foundation.md) records the Issue #19
  implementation spec for the PlayerState-owned ability system: class layout,
  lifecycle, attribute policy, the versioned activation seam, closure of the
  stock GAS activation routes, rejection telemetry, test plan, PR phasing,
  known interim gaps, and open decisions. The Gameplay Tag and content-version
  conventions it implements live in
  [Combat and Networking Architecture](combat-and-networking-architecture.md#gameplay-tag-and-content-version-conventions).
- [Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md) records
  the Issue #60 implementation spec for the server-owned pure-free-aim attack
  timeline: request schema 2 and the aim policy, chain progression and
  buffering, cancel and reset rules, authored volumes and deterministic hit
  resolution, lag-compensation and prediction policy, outcome reporting,
  rejection reasons, data-driven tuning, test plan, phased delivery, and the
  owner decisions of 2026-10-05.
- [Dodge and Block](dodge-and-block.md) records the Issue #18 implementation
  spec for the server-validated dodge and the right-mouse block: the
  movement-carried dodge request, predicted displacement against the
  server-owned invulnerability window, the held block and the defense state,
  arc, and Guard hook it exposes to Issue #60, prediction and outcome
  reporting, telemetry, test plan, phased delivery, owner decisions, and open
  decisions.
- [Continuous Integration](continuous-integration.md) records the Issue #16
  prototype CI quality gates, required-versus-advisory checks, runner
  constraints, and machine-readable evidence path, plus the Issue #167
  accepted-base selector, receipt, aggregate, activation, and live-observation
  contracts used to recover and evolve CI without creating false authority.
- [Unreal Automation](unreal-automation.md) records the pinned headless harness,
  exact Issue #85 tests and discovery contract, fail-closed behavior, local
  invocation, and normalized evidence schema.
- [Developer Environment and DDC](developer-environment-and-ddc.md) records the
  Issue #81 clean-package timing and identity evidence (`build-timing.json`),
  the identity-bound persistent Derived Data Cache contract, the attested
  fail-closed prebuilt host-tools boundary and its operator attestation step,
  and capacity and recovery ownership.
- [Asset Intake and Content Validation](asset-intake-and-content-validation.md)
  defines lifecycle, provenance, stable identity, audience, validation, and
  client/server cook-evidence contracts for Issue #120.
- [GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) govern
  work status, ownership, priority, and target version.

## Rendered Artifacts

- [Character Codex](../output/pdf/champions_of_the_first_cycle-2026-10-10-vesh-revamp-final.pdf)
- [Settlement Codex](../output/pdf/Settlements_of_Aetheln_City_and_Village_Codex-2026-10-10-vesh-revamp-final.pdf)

The PDF codices are complete rendered snapshots of the canonical Markdown
character and settlement documents, regenerated on 2026-10-10 with the Vesh
spirit/Light story revision and the existing Kell redesign. Their complete
source text was checked for parity and all 25 pages (16 character, 9 settlement)
were rendered and visually inspected. Canonical Markdown remains the
source of truth when later edits occur.

The earlier [character](../output/pdf/champions_of_the_first_cycle.pdf) and
[settlement](../output/pdf/Settlements_of_Aetheln_City_and_Village_Codex.pdf)
editions are preserved as historical exports; they predate the current race
revisions and do not define current canon. The intervening
[Kell character edition](../output/pdf/champions_of_the_first_cycle-2026-10-10-kell-revamp-final.pdf)
and [Kell settlement edition](../output/pdf/Settlements_of_Aetheln_City_and_Village_Codex-2026-10-10-kell-revamp-final.pdf)
are likewise preserved; the Vesh editions above are the current snapshots.

## Approved Art Direction

- [Retained character results](art-style-references/character-results-2026-10-10.md)
  lists the selected Kell and Aurin pairs and the current Vesh redesign pair,
  their exact prompts, image hashes, and selection states. External source
  images and superseded explorations are kept outside the repository.
- [Art Style and Generation Guide](art-style-guide.md) records the user-approved
  polished stylized 3D rendering direction, the selected Aurin and Kell references,
  reusable prompts, and consistency checks for future characters and assets.
  It supersedes older painterly rendering guidance. The selected Kell pair is
  the race baseline in [Playable Peoples](playable-peoples.md#kell); its revised
  story is recorded in the character and settlement documents.
- [Approved Aurin design record](art-style-references/aurin-approved-design-2026-10-10.md)
  records the selected male v06 and female v13, exact prompts, provenance, and
  image hashes. The pair is the updated visual baseline in
  [Playable Peoples](playable-peoples.md#aurin); Aurin biology and story remain
  unchanged. Earlier Aurin studies and their historical approval states are
  superseded for new race visuals.

## Non-Canonical Visual Development

- [Visual-development package](../visuals/README.md) describes the imported
  concepts and editable UI studies.
- [Asset provenance](../visuals/asset-provenance.md) records source, processing,
  and review status for the imported package.
- [Future visuals plan](../visuals/FUTURE-VISUALS-PLAN.md) records the earlier
  visual-development sequence. For current rendering style, use the approved
  art guide above.

These files support review and production planning. They do not override the
canonical product or technical documents, and repository inclusion does not
approve an asset for Unreal `Content/` or runtime use.

Earlier Kell anatomy instructions, generation prompts, and anatomy review
judgments in the visual package describe the superseded skin, crown, and
mantle direction. Preserve those historical records; use the approved pair and
current [Kell canon](playable-peoples.md#kell) for new work.

Earlier Vesh dream-veiled anatomy, back-veils, and dream-reader identity are
likewise superseded by the [embodied-spirit Vesh canon](playable-peoples.md#vesh).
Use the retained black-and-white design and the current character/settlement
stories for new work. The male palette is selected; final female visual
approval and production validation remain separately recorded.

## Historical Research Archive

- [Historical planning and research](research/README.md)

The archive preserves feasibility, lore, delivery, environment, and roadmap
background under Issue
[#65](https://github.com/ShayShimoni/aetheln-online/issues/65). Archive contents
are non-authoritative and must not override canonical product, technical, or
delivery documents.

## Decision Precedence

When documents disagree:

1. Explicit user-approved product decisions and the canonical Game Design
   Bible define player-facing behavior.
2. The specialized canonical product document defines detailed system behavior.
3. The technical overview and specialized technical document define
   implementation, with accepted entries in the architecture registry governing
   evidence-based technical choices.
4. The repository and prototype roadmaps define delivery order and stage
   boundaries.
5. GitHub Issues define current work status, not product or architecture rules.
6. Supporting research, older planning reports, and historical artifacts are
   background only.

If a technical constraint appears unable to implement a product rule, record the
conflict and obtain a reviewed product or architecture decision. Do not silently
change the product rule or revive a rejected historical recommendation.
