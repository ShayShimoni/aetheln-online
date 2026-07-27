# Build & Planning Documentation — Indie MMO-Lite Action MMORPG (Unreal Engine 5.8)

*Prepared for a beginner developer. Technical terms are explained in plain
language on first use. Modeled estimates and assumptions are flagged
explicitly. Canonical repository design documents supersede the feasibility
report whenever they conflict.*

> **Current product authority:** technical patterns in this document remain
> planning guidance, but its arena-first PvP, traditional talent-tree, and
> single-hub assumptions are superseded. Current product behavior is defined in
> the [Documentation Index](../documentation-index.md),
> [Game Design Bible](../game-design-bible.md),
> [Progression, Loot, and Skein Weaving](../progression-loot-and-skein.md),
> [Characters and Factions](../characters-and-factions.md), and
> [World and Settlements](../world-and-settlements.md).

## TL;DR
- **This is buildable by a small/beginner team on the chosen stack (UE 5.8 C++ + GAS + Nakama + PostgreSQL/Redis + GameLift), provided you enforce one rule everywhere: the dedicated server is authoritative and the client only predicts presentation.** Treat **30–64 concurrent action-combat players per UE server instance** and a **30 Hz** starting tick as modeled test assumptions, not guarantees. Measure mixed-territory and invasion combat before selecting final capacity or tick targets. Use a **TypeScript** Nakama runtime initially.
- **Do not adopt experimental tech at MVP.** Iris replication is still Experimental in 5.7 (moving to Beta) and Epic warns against shipping on it; the Unreal Animation Framework (UAF) is only first-previewed in 5.8. Use **legacy replication + Replication Graph later**, and **Motion Matching + the Game Animation Sample** for locomotion with attacks on montages.
- **Costs stay near $0 locally and in the low hundreds of dollars/month for a closed beta** if you self-host Nakama on a small VM and run GameLift instances only during tests; avoid Heroic Cloud (from **$600/mo**) until revenue justifies it. Integrate **free Easy Anti-Cheat** before any public beta, not during prototyping.

---

## A) ARCHITECTURE OVERVIEW & LIMITATIONS

### A.1 End-to-end flow (each hop explained)

1. **Game Client (UE5.8, C++)** — the player's PC app. Renders the world, reads input, *predicts* the local player's movement so it feels instant, and shows cosmetic anticipation of abilities. It never decides outcomes.
2. **Nakama (gateway / auth / social)** — an open-source backend server. First stop after launch: the client authenticates (device or email login), gets a **session token** (a signed pass proving who you are), and uses Nakama for friends, chat, groups, storage, and RPCs (**Remote Procedure Calls** — asking the server to run a named function).
3. **Matchmaking / Instance Allocator** — logic (a Nakama RPC, or GameLift FlexMatch) that decides which dedicated-server process the player should join for a zone/dungeon/arena and reserves a slot.
4. **GameLift-hosted UE Dedicated Servers** — headless (no graphics) UE server processes running the actual simulation. **Authoritative** = the server is the single source of truth; it validates every hit, cooldown, and resource spend. One process per zone/dungeon/arena instance.
5. **Persistence API** — when the game server needs to save loot, XP, Skein
   choices, Doctrine progression, or contested resources, it calls Nakama
   server-to-server using an **HTTP key / server key** (a secret only servers
   hold) so players cannot forge writes.
6. **PostgreSQL** — the durable database, the "book of record" for accounts, characters, inventory. **Redis** — a fast in-memory store for presence, party queues, cross-server chat pub/sub, rate limiting, and ephemeral state.
7. **Observability** — structured logs, metrics (Prometheus/Grafana), and crash reporting (Sentry/BugSplat) so you can see failures.

### A.2 Known limitations of every major choice

| Choice | Limitation | Practical impact |
|---|---|---|
| **Stock UE replication** | CPU cost of outgoing replication scales roughly with players × relevant actors. Measured: 100 simple characters on a 2-vCPU Linux box dropped the server to 10–15 FPS on stock replication (BorMor profiling, UE 5.7). | Plan ~30–64 real action-combat players per instance on stock replication; use relevancy culling. Fortnite's 100/instance needs Replication Graph or Iris. |
| **Iris replication** | Still Experimental in 5.7, moving to Beta; Epic warns "use caution when shipping with it." | Do NOT adopt at MVP. Keep legacy replication; leave Iris as a later optimization. |
| **Nakama** | One OSS node handled ~20,277 raw sockets in Heroic Labs' benchmark, [heroiclabs](https://heroiclabs.com/docs/nakama/getting-started/benchmarks/) but custom authoritative match code lowers this materially. OSS is single-node; clustering requires Nakama Enterprise. | Fine for closed beta on one node; plan Enterprise/managed if you cross ~10k CCU. |
| **GameLift** | Vendor lock-in (CloudFormation, fleet APIs, FlexMatch). | Keep server code engine-clean; Agones+Open Match is the escape hatch. |
| **Git LFS** | Binary `.uasset`/`.umap` files can't be merged; relies on manual file locking discipline. | Works under ~15 people / <50 GB; switch to Perforce beyond that. |
| **GAS** | Steep learning curve; prediction can't roll back chained abilities or accurately predict %-based effects. | Predict simple things; let server correct. Budget weeks to learn. |
| **Motion Matching / UAF** | UAF (future Anim Blueprint replacement) first previewed in 5.8, not production-ready. | Use Motion Matching + Game Animation Sample for locomotion; keep attacks on montages. |

---

## B) CLIENT DOCUMENTATION (Unreal Engine 5.8)

### B.1 Project & module structure

Use a **C++ project** (not Blueprint-only) so systems are version-controllable and fast. Recommended module layout (a *module* is a compiled unit of C++ code):

- `GameCore` — gameplay framework (GameMode, GameState, PlayerState, PlayerController).
- `GameCombat` — GAS abilities, attribute sets, effects, combat traces.
- `GameUI` — CommonUI widgets, HUD.
- `GameNet` — Nakama client wrapper, session handling, instance connection.
- `GameServer` — dedicated-server-only code (GameLift lifecycle, persistence writes) guarded so it never ships in the client.

**Lyra as reference, not gospel.** Lyra is Epic's sample online game. Its **Experiences** (a data-driven way to define "what mode/loadout is active in this level") and **Game Features** (plugins that add gameplay without touching core code) are powerful but heavy for a beginner. **Recommendation:** study Lyra's ASC-on-PlayerState and modular pawn pattern (`ULyraHeroComponent`/`ULyraPawnExtensionComponent` grant abilities to the PlayerState's ASC on possession); adopt a *simplified* single-plugin structure at MVP. Add Game Features later only when you have multiple content teams.

### B.2 GAS deep dive for this combat model

GAS (**Gameplay Ability System**) is Epic's framework for abilities, stats, and effects, used in Fortnite/Paragon.

- **ASC placement:** put the **AbilitySystemComponent (ASC)** on the **PlayerState** for players (survives respawn, per Epic's Dave Ratti guidance: "anything that does respawn should have the Owner and Avatar be different"), and on the **Pawn** for AI enemies. Implement `IAbilitySystemInterface` on the class that *owns* the ASC (the PlayerState), or `UAbilitySystemBlueprintLibrary` lookups fail. Call `InitAbilityActorInfo` on both server (`PossessedBy`) and client (`OnRep_PlayerState`) or attributes won't replicate to the owning client.
- **Attribute Sets** (grouped stats): `Health`, `Stamina`/`Guard` (block resource), `Mana`/class resource, plus derived combat stats. Clamp in `PreAttributeChange`; react to damage/death in `PostGameplayEffectExecute`.
- **Gameplay Effects (GE):** data assets for instant damage, buffs, cooldowns (Duration/Infinite/Instant). Cooldowns are GEs with a Cooldown tag.
- **Gameplay Cues (GC):** cosmetic FX/SFX hooks, fired by tag, safe to predict on clients.
- **Ability activation & prediction keys:** the client generates a **prediction key** (an integer identifier) when it locally activates an ability; the server confirms or rejects. **Limits (from Epic's own docs):** GAS "rollback of any chained activations (including triggered events) is currently not possible out of the box," and it can't accurately predict %-based effects because "the server replicates down the 'final value' of an attribute, but not the entire aggregator chain." **Rule:** predict the animation and cast start; let the server own damage.
- **Targeting:** for TERA-style non-target combat, prefer **custom server-side traces** (swept shapes) over the built-in Target Actor system, which is aimed at tab/reticle confirmation.
- **Tag conventions:** `Ability.Melee.Combo1`, `State.Dodging`, `State.Blocking`, `Cooldown.Dodge`, `Damage.Type.Physical`. Start minimal — over-engineering the tag tree early is a common GAS mistake.

### B.3 Non-target combat implementation

- **Melee swept traces synced to anim notifies.** An **Anim Notify State** marks a window in an animation (e.g., "blade is live" from frame 8–14). During that window the server runs a **swept capsule/box trace** (sweeps a shape along the blade's path) each tick and applies damage to whoever it hits. Cleaves use a cone/arc query.
- **Combo chaining** via a small state machine: input during the "combo window" notify advances to the next montage section; otherwise the combo drops. Use **input buffering** so a slightly-early press still registers.
- **Root motion vs in-place:** **root motion** (animation drives movement) looks great but is harder to net-correct. For MVP, use root motion for committed lunges via **Root Motion Sources** (CMC feature for server-friendly authored motion) and in-place for basic strikes.
- **Dodge i-frames:** grant a `State.Dodging` (invulnerability) tag for a fixed window; the server checks this tag on hit resolution so dodge validity is server-decided.
- **Directional block:** compute the angle between the attacker's direction and the defender's facing; if within the frontal cone (e.g., ±60°) and the block tag is active with enough Guard resource, negate/reduce damage. All resolved server-side.
- **Server-owned projectiles:** the server spawns and simulates projectiles; clients see a cosmetic copy. Optionally add lag compensation (rewind) later.
- **Hit-stop & camera feedback:** brief local time-dilation/freeze on hit confirm (cosmetic, client-only).

### B.4 Character Movement Component (CMC) for beginners

The **CMC** moves the character and does **client prediction + reconciliation**: the client moves immediately, sends its moves to the server, the server re-simulates authoritatively and sends back corrections; if they differ, the client "reconciles" (snaps/smooths). **Custom moves** (dash/lunge) should use **Root Motion Sources** or a CMC extension rather than teleporting. **Pitfalls:** *rubber-banding* (client corrected backward because server disagreed — usually caused by trusting client velocity), and *move combining* (CMC batches small moves; heavy per-move logic can break it).

### B.5 Replication

- **Property replication** (a variable auto-syncs when it changes) vs **RPCs** (one-off function calls: Server, Client, or NetMulticast). Use replicated properties for state (health), RPCs for events (ability request).
- **Relevancy / interest management:** don't send every actor to every client. Use **NetCullDistanceSquared** (stop replicating far actors), **dormancy** (stop updating actors that aren't changing), and per-actor **NetUpdateFrequency**.
- **Replication Graph vs Iris:** Replication Graph is the production-proven way to scale relevancy (what Fortnite uses; Epic calls the default replication "more an example than a ready-to-use production solution"). [BorMor](https://bormor.dev/posts/iris-one-hundred-players/) **Iris** is Experimental in 5.7 → Beta; do not ship on it at MVP.
- **Tick rate:** begin dedicated-server testing at **30 Hz**
  (`NetServerMaxTickRate=30`). Profile mixed-territory and invasion combat under
  representative population, latency, and packet loss before selecting a
  higher target. A higher tick rate is useful only if the server CPU and
  bandwidth budgets can sustain it.
- **Bandwidth budget:** default per-client cap is ~10 KB/s (`MaxClientRate`/`MaxInternetClientRate`); to raise it you must also raise `TotalNetBandwidth` and `MaxDynamicBandwidth` in `GameNetworkManager`. Budget ~10–20 KB/s per player for action combat. Measured: raising server tick from 30→70+ FPS pushed a 5-minute test from ~600 MB to ~900 MB outgoing. [BorMor](https://bormor.dev/posts/iris-one-hundred-players/)
- **Players per zone server:** plan **~30–64 concurrent action-combat players per instance on stock replication** — a modeled range grounded in BorMor's measured result (100 simple characters → only 10–15 server FPS on a 2-vCPU box, bottlenecked on `NetBroadcastTickTime` = 66 ms of an 84 ms frame) [bormor](https://bormor.dev/posts/iris-one-hundred-players/) plus Epic's 100/instance Fortnite reference which requires Replication Graph. UE's server game thread is largely single-thread-bound, so prefer high single-core-clock CPUs.

### B.6 Animation pipeline

- **One humanoid skeleton standard** (UE5 Mannequin / UEFN skeleton) for all humanoids so animations retarget freely.
- **IK Rig / IK Retargeter** — tools to transfer animation between skeletons of different proportions.
- **Motion Matching + Game Animation Sample** — Epic's free 500+ animation locomotion system (compatible with UE5 Mannequins via runtime retargeting), updated through 5.7/5.8. Production-usable for locomotion today; **UAF** (the future Anim Blueprint replacement) is only first-previewed in 5.8, so don't build on it yet.
- **Attacks on Anim Montages** with notifies driving traces/VFX/SFX. Build a **hit-reaction/stagger matrix**: light hit → flinch, heavy → stagger, launcher → knockdown.

### B.7 Niagara VFX

- **Telegraphs:** ground **decals** (circle/cone/line) plus particle edges. Standardize timing: windup telegraph appears before the damage tick.
- **Pooling** (reuse effect instances) and **scalability settings** to cap cost in crowded fights.
- Prefer **CPU emitters** for gameplay-critical readable telegraphs (deterministic); **GPU emitters** for dense cosmetic sparks. Watch **overdraw** (many transparent layers stacking).

### B.8 UI (CommonUI)

- **CommonUI** is Epic's cross-platform UI framework (originally built for Fortnite) layered on Slate/UMG, with input routing (top visible layer gets input) and shared style assets.
- **HUD:** health/stamina/cast bars, minimal center clutter, a subtle **reticle** for aiming.
- **Nameplates:** cap draw count and update frequency; pool them; hide beyond distance.
- **Damage numbers:** debug-only detailed numbers during dev; simplified/toggleable in shipping.

### B.9 Enhanced Input for action combat

**Enhanced Input** is UE5's input system using **Input Actions** (IA_) and **Input Mapping Contexts** (IMC_ — swappable sets of bindings). Use **modifiers** and **triggers** for hold/tap, and implement **input buffering** so a combo press slightly early still registers. UE 5.8 unified Enhanced Input with Common Input/UI.

### B.10 Client performance budgets (stylized PC)

- Target **16.6 ms/frame (60 FPS)**; stylized art means you can afford higher counts than photoreal.
- Rough per-frame guidance (modeled): a few thousand draw calls max; hero character ~30–60k triangles (well below the 80–120k AAA hero range since this is stylized); props/kit pieces a few hundred to low-thousands of tris.
- **Profiling:** **Unreal Insights** (timeline profiler), `stat unit`, `stat game`, `stat gpu`, `stat rhi`. Use **Scalability** settings for low-end PCs.

### B.11 Client security posture

The client is **never trusted** — a determined player can modify it. Common cheats: **speed hacks** (move faster), **teleports**, **cooldown/fire-rate hacks**, **fake hit claims**. **Everything that affects outcomes must be server-validated:** movement bounds/speed, ability eligibility, cooldowns, resource costs, hit detection, damage. Client-side protection only raises the bar. **Easy Anti-Cheat (EAC)** is free via Epic Online Services (EOS) on Windows/Mac/Linux/Steam Deck — Epic's licensing page confirms "free services offer comprehensive, prevention-first protection… at no cost," with paid Core/Fortified/Premier tiers for high-risk competitive games. **Recommendation:** add EAC before any public/paid beta, not during early prototyping.

### B.12 Building, packaging & testing

- Build the **client + Linux dedicated server from source**; the GameLift Unreal plugin supports native Linux cross-compile from the editor.
- **PIE** (Play In Editor) multiplayer modes to test with multiple clients + dedicated server locally; launch a standalone server with `-server -log`.
- **Network emulation:** use UE's built-in **net emulation** (packet lag/jitter/loss settings) to test under bad connections.

---

## C) BACKEND DOCUMENTATION

### C.1 Nakama for beginners

Nakama (Heroic Labs, Apache-2.0 open source) provides out of the box: **authentication** (device/email/social), **sessions**, real-time **sockets**, **friends**, **chat**, **groups/guilds**, a **storage engine** (JSON objects with per-object permissions and versions), **leaderboards/tournaments**, a **matchmaker**, and a **wallet** with an audit ledger. It runs custom logic via a **server runtime** in **Go, TypeScript, or Lua**.

**Runtime recommendation: TypeScript.** For a beginner solo/small team, TypeScript gives type safety, easy JSON handling, no Go build toolchain, and no compile-to-`.so` step like Go plugins. Go is fastest under CPU-heavy load and is the language Nakama itself is written in, but adds toolchain overhead; Lua is simplest (no toolchain) but least safe for a growing codebase. In Heroic Labs' own light-RPC benchmark all three ran within a few percent of each other (~700 req/s/node), so for typical CRUD/economy RPCs TypeScript costs you nothing. Use TypeScript for RPCs and authoritative writes; drop to Go later only for a profiled hot path. The Unreal client connects via the official **C++/Unreal Nakama SDK** over REST/gRPC/WebSocket.

### C.2 Data model

Separate three lifetimes: **account** (login, entitlements), **character** (per-character progression), **session** (ephemeral, in Redis).

Recommended Nakama storage collections (collection/key/user-id JSON objects):
- `accounts/{userId}` — account flags, settings.
- `characters/{characterId}` — class, faction, permanent level, XP, Ember
  Rank, playable race, male/female sex, and appearance references.
- `inventory/{characterId}` — items, stacks.
- `equipment/{characterId}` — equipped loadout.
- `skein/{characterId}` — unlocked and equipped Forms, Threads, and Keystone.
- `doctrine/{characterId}` — faction Doctrine choices and progression.
- `quests/{characterId}` — quest flags.
- `pvp/{characterId}` — contribution, bounty, repeat-opponent, and unbanked
  contested-resource state.
- `currencies` — use Nakama's **wallet** (has a built-in audit ledger).
- `friends/social` — use Nakama's native friends/groups.
- `audit/{...}` — transaction logs (also mirror critical events to Postgres).

**Anti-dupe patterns:** all economy writes go through **authoritative server RPCs** (never client-written). Use Nakama storage **version strings** for **optimistic concurrency control (OCC)** — the write only succeeds if the version matches the server's current version (Nakama computes versions via MD5 hashing; note a historical OCC bug under high write contention was fixed in a Nakama release). Make writes **idempotent** (safe to retry) using request IDs. Use Nakama's `MultiUpdate` for atomic multi-object transactions. Version your JSON schemas with a `schemaVersion` field and write migrations.

The canonical reward-generation contract and pseudocode are defined in
[Progression, Loot, Skein Weaving, and Character
Creation](../progression-loot-and-skein.md). Every reward uses a stable event ID,
versioned loot table, server-only random stream, eligibility record, atomic
inventory mutation, and auditable receipt.

### C.3 PostgreSQL specifics

- Nakama's own DB (Postgres or CockroachDB) suffices for account/social/storage. Add a **separate game DB** only for heavy analytics or bespoke relational queries.
- Use **JSONB** columns (binary JSON, indexable/queryable) for flexible per-character blobs; index the fields you filter on.
- Add indexes on foreign keys and lookup columns; avoid over-indexing write-hot tables.
- **Backups:** enable automated snapshots + **point-in-time recovery (PITR)** (restore to any second using the write-ahead log). Test restores.

### C.4 Redis usage

Good for: **presence** (who's online/where), **party & matchmaking queues**, **pub/sub** for cross-server chat, **rate limiting** counters, and short-lived caches. **Do NOT** put the durable source of truth (characters, inventory) in Redis — it's a cache, not the book of record. Persist anything you can't afford to lose to Postgres.

### C.5 Session flow end-to-end

1. Login → Nakama returns session token.
2. Character select (read `characters/*`).
3. Client requests a zone/dungeon/arena → matchmaker/allocator RPC.
4. Allocator reserves a slot on a GameLift game session → returns IP/port + a join token.
5. Client connects to the UE dedicated server with the token; server verifies it.
6. Gameplay; server periodically writes progression to Nakama using the **server HTTP key** (server-to-server; never client-forgeable).
7. Logout/transfer → final persistence write, release slot.

### C.6 AWS GameLift Servers

- **Unreal plugin (Server SDK 5.x):** open-sourced, supports UE5, x64+ARM, in-editor fleet deploy via CloudFormation, native Linux cross-compile, and integrated testing maps.
- **Lifecycle:** `InitSDK()` → `ProcessReady()` (tells GameLift the process can host) → `OnStartGameSession` (a match is placed here) → periodic **health checks** → `OnProcessTerminate` (graceful shutdown/persist). InitSDK must specify server SDK version 5.x (the default 4.x is incompatible on Anywhere fleets).
- **Fleet types:** **Managed EC2** (AWS runs the VMs), **Container**, and **Anywhere** (register your own/local machine as compute — ideal for cheap dev testing and integrates with FlexMatch/Queues).
- **Instance sizing:** compute-optimized C-family (e.g., c5.large 2 vCPU/4 GB ≈ $0.109/hr Linux US-East-Ohio, c6i, or Graviton c6g ≈ $0.088/hr for cost) suit UE servers because single-core speed matters. Bandwidth is free on gen-6+ instances.
- **FlexMatch vs Nakama matchmaker:** FlexMatch is AWS's rule-based matchmaker tied to GameLift. **Recommendation:** use **Nakama's matchmaker** for party/queue logic (keeps you portable) and GameLift purely for allocation/hosting; adopt FlexMatch only if you lean fully into the AWS stack.

### C.7 Alternative path: Agones + Open Match

**Agones** (game-server orchestration on Kubernetes) + **Open Match** (open-source matchmaker) is worth it when GameLift costs or lock-in become painful, or you need multi-cloud. It trades convenience for control and requires Kubernetes expertise. Keep it as a documented future option, not MVP.

### C.8 Scaling limits & realistic numbers

- **UE dedicated server:** ~30–64 action players/instance on stock replication (modeled, per §B.5).
- **Nakama (official Heroic Labs benchmarks, Tsung tool, no custom game code):** 1 node (1 vCPU/3 GB) = **20,277 max concurrent sockets**; [heroiclabs](https://heroiclabs.com/docs/nakama/getting-started/benchmarks/) **~528 registrations/s** [heroiclabs](https://heroiclabs.com/docs/nakama/getting-started/benchmarks/) and **~531 auths/s** per node; **~700 light-RPC/s** per node (Go/TS/Lua all similar). Two 2-vCPU nodes = **35,723 CCU**. [heroiclabs](https://heroiclabs.com/docs/nakama/getting-started/benchmarks/) Rule of thumb: ~10,000 CCU per node; run ≥2 nodes in production for failover. [Heroic Labs](https://heroiclabs.com/blog/announcements/nakama-enterprise/) **Code Wizards Group, working with AWS, load-tested Nakama on Heroic Cloud to 2,000,000 CCU "with no issues, every time"** [Heroic Labs](https://heroiclabs.com/blog/code-wizards-scale-test-of-nakama-2m-ccu/) (client on AWS Fargate/Aurora; Nakama on EC2/EKS/RDS), with CTO Martin Thomas stating "Hitting 2 million CCU without a hitch is a massive milestone… we had the capacity to go even further." [Heroic Labs](https://heroiclabs.com/blog/code-wizards-scale-test-of-nakama-2m-ccu/) **Critical caveat:** Heroic Labs' Benchmarks documentation states its figures "represent the Nakama server without custom game code" [Heroic Labs](https://heroiclabs.com/docs/heroic-cloud/operations/load-testing/) and that "no universal formula exists for how many vCPUs you need for a given CCU target" [Heroic Labs](https://heroiclabs.com/docs/heroic-cloud/operations/load-testing/) — authoritative match code lowers per-node CCU materially, so **re-benchmark with your own code**.
- **Scaling:** OSS = single node; multi-node clustering = Nakama Enterprise / managed Heroic Cloud. Scale UE horizontally (more instances) via the allocator; scale Nakama vertically first, then out.

### C.9 Backend security threat model

- **Token theft/replay** → short token lifetimes, TLS everywhere, rotate keys.
- **Forged server writes** → only servers hold the HTTP key; clients can't write economy data.
- **SQL injection** → parameterized queries only.
- **Rate limiting / DDoS** → Redis counters, cloud WAF/shield, connection caps.
- **Secrets management** → never in the repo; use env vars / AWS Secrets Manager.
- **Least privilege** → the game server's backend credential can write only what it needs.
- **Economy exploits** → server-side price/cost checks, audit logs, periodic reconciliation of wallet ledger vs balances.

### C.10 Observability

- **Structured logging** (JSON) from client, server, and Nakama.
- **Metrics:** Prometheus + Grafana (or cloud-native CloudWatch). Nakama exposes metrics.
- **Crash reporting for UE:** **Sentry** has an official UE plugin; its free **Developer plan includes 5,000 errors [Sentrypricing](https://sentrypricing.com/free-plan) + 10,000 performance units/month, [Vendr](https://www.vendr.com/marketplace/sentry) 1 user, and 30-day retention** [Sentrypricing](https://sentrypricing.com/free-plan) (paid Team tier from **$26/month billed annually**). [AIToolPick](https://aitoolpick.org/blog/sentry-pricing-2026/) **BugSplat** and **Backtrace** are UE-focused alternatives (contact for pricing). **Recommendation:** start with Sentry's free tier.
- **Alerting:** on server FPS drops, error-rate spikes, DB latency, and crash volume.

### C.11 Cost model (modeled estimates — verify current rates)

| Environment | Approx. monthly | Notes |
|---|---|---|
| **Local dev** | ~$0 | Docker Compose (Nakama+Postgres+Redis) + GameLift Anywhere on your PC. |
| **First cloud test** | low tens of $ | 1–2 small Linux GameLift instances (c5.large ~$0.109/hr; Graviton c6g ~$0.088/hr, US-East-Ohio; bandwidth free on gen-6+) run only during tests + a small Nakama VM (~$5–20/mo self-hosted; Cloudzy from ~$4.48/mo) + managed Postgres. |
| **Small closed beta** | low hundreds of $ | Several GameLift instance-hours + Nakama self-host VM. Heroic Cloud managed Nakama starts at **$600/mo** — skip until revenue justifies it. |

---

## D) GENERAL GUIDELINES / PROJECT BIBLE

### D.1 Art style guide

**Philosophy:** stylized high-readability fantasy — characters must pop against environments. Environments use **desaturated neutrals**; characters and important gameplay elements use **higher saturation and value (brightness)**.

**Palette structure (example hex — adjust to taste):**
- Environment neutrals: `#6B6559`, `#8A8375`, `#4A5568`, `#2D3748`.
- Character saturation accents: `#E53E3E`, `#3182CE`, `#38A169`, `#D69E2E`.
- **Item rarity ladder** (keep the genre-standard ladder — deviating hurts readability): Common `#9D9D9D` (gray), Uncommon `#1EFF00` (green), Rare `#0070DD` (blue), Epic `#A335EE` (purple), Legendary `#FF8000` (orange). Deviate only for a distinct top tier if needed.
- **Class identity colors:** assign one signature hue per class for UI, VFX tint, and iconography.
- **Faction colors** and **enemy threat colors** (elite/boss) as separate ramps.

**Telegraph color language:** enemy danger = **red/orange**; ally/beneficial = **blue/green**; neutral warning = **yellow**. **Colorblind-safe:** deuteranopia struggles with red/green — never rely on hue alone. Use **shape + color redundancy** (e.g., spiky = damage, smooth ring = heal) and offer colorblind palettes. Keep consistent **lighting direction** across assets.

### D.2 Character/environment art rules

- **Silhouette-first design** — readable in solid black.
- **Texel density:** pick a project standard (e.g., ~10.24 px/cm for hero close-ups, lower for distant props) and enforce at UV layout; keep within ~±25% across an asset. Reserve UV channel 0 for PBR, channel 1 for lightmaps if using static lighting. Each material slot on a skeletal mesh = one draw call.
- **Tri-count budgets (stylized PC, modeled):** player character ~30–60k; enemy ~15–40k; hero prop ~2–8k; modular kit piece a few hundred–2k. (AAA photoreal heroes run 80–120k at LOD-0; stylized needs far less.) Use modular character assembly (head/body/hands/legs on one skeleton) so parts LOD independently.
- **Trim sheets & modular kits** to reuse texture space; **master materials + instances** (one parent material, many cheap variations).
- **Naming conventions (Epic/community standard, form `Prefix_AssetName_Descriptor_Variant`):** `SM_` static mesh, `SK_` skeletal mesh, `T_` texture (`_D/_N/_R/_MT/_AO` suffixes), `M_` material, `MI_` material instance, `NS_` Niagara system, `ABP_` anim blueprint, `AM_` anim montage, `BP_` blueprint, `IA_/IMC_` input, `DT_` data table, `DA_` data asset.
- **Folder structure:** feature-first (`/Content/Characters/…`, `/Environments/…`, `/Abilities/…`) with a `Developers` folder for WIP.

### D.3 Animation standards (combat timing, modeled from action-game norms)

- **Attack:** anticipation/startup ~4–8 frames (~66–133 ms @60fps), active hit window ~2–5 frames, recovery ~8–16 frames. Tune per weapon weight.
- **Dodge:** total ~0.4–0.7 s; i-frame window ~0.2–0.4 s inside it (TERA grants i-frames on skills like Backstep/Evasive Roll; keep MVP tighter and readable than TERA's up-to-~2 s extremes).
- **Block raise:** ~4–8 frames to full guard.
- **Hit-stop:** ~50–120 ms on solid hits for impact feel (cosmetic, client-side).
- Apply the **12 principles** to combat (anticipation, follow-through, exaggeration for readable telegraphs).
- **Root motion policy:** authored root motion for committed attacks/dodges; in-place for locomotion via Motion Matching.
- **Naming:** `AM_Class_Attack_Combo1`, notifies `ANS_HitWindow`, `AN_Footstep`.
- **Retarget rules:** everything retargets from the one humanoid skeleton via IK Retargeter.

### D.4 VFX guidelines

- **Telegraph shapes:** circle (AoE), cone (frontal cleave), line (charge/beam) — standardized so players learn them.
- **Timing:** windup duration ≥ human reaction (~250 ms minimum) before the damage tick.
- **Layering:** decal (ground) + particles (edge) + sound (audio cue) for redundancy.
- **Performance:** cap particle counts, minimize overdraw, pool systems.

### D.5 UI/UX guidelines

- Minimal center-screen clutter; clean **reticle**; health/stamina near center-bottom.
- Readable **sans-serif font**; high contrast.
- **Damage numbers** toggleable and de-cluttered.
- **Accessibility:** full input remapping, subtitles, colorblind modes, camera-shake toggle, telegraph audio cues.

### D.6 Audio guidelines (FMOD)

- **FMOD** is middleware for adaptive game audio. Its **Indie License is free** for commercial projects with a development budget **under US$600,000 AND total gross annual revenue/funding under US$200,000** [GameFromScratch](https://gamefromscratch.com/fmod-studio-now-free-for-indie-game-developers/) (Basic License covers $600k–$1.8m budgets; Premium over $1.8m) [Wikipedia](https://en.wikipedia.org/wiki/FMOD) — well within an indie MVP's reach; re-check the tier as your budget grows.
- **Event naming:** `event:/Combat/Melee/HitConfirm`, `event:/Enemy/Telegraph/Slam`.
- **Mixing buses:** Master → Music, SFX (→ Combat, World), VO, UI.
- **Combat audio priority:** hit-confirms and enemy telegraphs must always be audible (duck music/ambience under them).
- **Music states:** explore / combat / boss / victory transitions.

### D.7 Code standards

- Follow the **Epic C++ Coding Standard** (naming: `U`/`A`/`F`/`E` prefixes, `PascalCase`, etc.).
- **C++ vs Blueprint split:** systems/networking/authoritative logic in **C++**; content, tuning, and designer-facing tweaks in **Blueprint/Data Assets**.
- **Gameplay Tag taxonomy:** `Ability.Melee.Combo1`, `State.Dodging`, `Damage.Type.Fire`, `Cooldown.Dodge`, `Event.Montage.HitWindow`.
- **Data-driven design:** **DataTables/DataAssets** for abilities, items, classes, and combat tuning so designers change values without recompiling.

### D.8 Source control workflow (Git + Git LFS)

- Track binaries with LFS and mark lockable: `git lfs track "*.uasset" --lockable` and `"*.umap" --lockable`. [SteveStreeting.com](https://www.stevestreeting.com/2020/08/09/my-unreal-engine-vcs-setup-gitea--git--lfs--locking/)
- `.gitattributes` sets `filter=lfs diff=lfs merge=binary -text lockable` for UE binary types; [Believer Entertainment](https://believer.gg/using-git-with-unreal-engine-part-2-a-first-pass-at-a-friendly-workflow/) robust `.gitignore` for `Binaries/`, `Intermediate/`, `Saved/`, `DerivedDataCache/`.
- Enable **One File Per Actor (OFPA)** so level edits are more atomic and reduce map-file conflicts — but note it creates many small external `.uasset` files (in `__ExternalActors__`).
- **File locking discipline:** lock before editing a binary; release on push. Use a UE Git source-control plugin (e.g., getnamo's refactored Git plugin) for in-editor lock/checkout — your locked files show a red checkmark, others' locks show blue.
- **Branching:** trunk-based with short-lived feature branches; make binary edits on main to avoid unmergeable divergence.
- **Switch to Perforce** when team >~15, assets >~50 GB, or `.uasset` conflicts become a daily problem — **Perforce P4 (formerly Helix Core) is free for up to 5 users and 20 workspaces** (self-hosted, no storage restriction), [Perforce](https://www.perforce.com/resources/vcs/helix-core-pricing) so it's also a viable start for tiny teams that prefer its native UE integration.

### D.9 CI/CD

- **GitHub Actions or Jenkins** running `RunUAT BuildCookRun` to build/cook/package client + Linux dedicated server.
- **Nightly builds**; smoke test = launch dedicated server, connect a headless client, run one ability, assert no crash.

### D.10 Testing strategy

- **Functional tests** (UE automation) for abilities and persistence.
- **Network emulation matrix:** test at latency {30, 80, 150, 250 ms}, jitter {0, 30 ms}, packet loss {0, 1%, 5%}.
- **Playtest cadence:** weekly internal, milestone external.
- **Exploit testing checklist:** try speed hack, teleport, spam ability past cooldown, forge hit, dupe via disconnect timing, replay packets — confirm server rejects each.

### D.11 Legal / IP guidelines

Stay **"inspired by," not infringing.** No Blizzard/Krafton trademarks, names, logos, or distinctive designs; no cloned assets. Do a basic **trademark search** on your game/class/ability names. The rarity color ladder and MMO conventions are genre-standard and not protectable, but distinctive named creatures, spell names, and art must be original. Maintain an **original art bible** documenting your own designs.

### D.12 Documentation & PM

- **ADRs (Architecture Decision Records):** one short doc per major decision (why ASC-on-PlayerState, why TypeScript runtime, etc.).
- **Task tracking:** GitHub Projects/Jira/Trello.
- **Definition of Done:** code reviewed, server-authoritative, tested under net emulation, no new crashes, tuning data-driven.

---

## E) PERFORMANCE & SECURITY SUMMARY

### E.1 Consolidated budgets

| Metric | Target |
|---|---|
| Server tick rate | Start at 30 Hz; measure contested-world and invasion combat before selecting a higher target |
| Bandwidth/player | ~10–20 KB/s (raise `MaxClientRate` + GameNetworkManager caps) |
| CCU / UE instance (action) | ~30–64 (stock replication, modeled) |
| Client frame time | 16.6 ms (60 FPS) |
| Nakama CCU / node | ~10,000 (rule of thumb; [Heroic Labs](https://heroiclabs.com/blog/announcements/nakama-enterprise/) ~20k raw sockets measured, less with custom match code) |

### E.2 Top 10 security controls (ranked)

1. Server-authoritative outcomes (hits, cooldowns, resources, damage).
2. Server-side movement validation (speed/teleport bounds).
3. Server-only economy writes via HTTP key (no client writes).
4. Optimistic-concurrency + idempotent persistence (anti-dupe).
5. TLS everywhere + short-lived session tokens.
6. Rate limiting + connection caps (Redis).
7. Secrets in a manager, least-privilege server credentials.
8. Audit logs + wallet reconciliation.
9. Parameterized SQL (no injection).
10. Easy Anti-Cheat before public beta.

### E.3 Top exploit classes & mitigations

| Exploit | Mitigation |
|---|---|
| Speed hack | Server validates max speed/position deltas per tick |
| Teleport | Server rejects impossible position jumps |
| Cooldown/fire-rate bypass | Server owns cooldown GEs; rejects early activation |
| Hit forgery | Server runs the trace; client hit claims ignored |
| Dupe via disconnect timing | Atomic transactions + OCC versions + idempotency |
| Packet replay | Nonces/sequence numbers, short token TTL, TLS |

---

## F) BUILD ROADMAP (each task ≤ ~1 week for a beginner)

Priority: **P0** = must-have for MVP; **P1** = important; **P2** = nice-to-have.

### Phase 0 — Environment setup
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 0.1 | Install UE 5.8 (source build for Linux server) | P0 | — | Editor launches; can build a blank C++ project |
| 0.2 | Git + Git LFS + `.gitattributes`/`.gitignore` + locking plugin | P0 | — | `.uasset` locks/unlocks in editor; repo pushes |
| 0.3 | Docker Compose: Nakama + Postgres + Redis locally | P0 | — | Nakama console reachable; test RPC returns |
| 0.4 | Install Nakama Unreal SDK; Sentry free tier | P0 | 0.3 | Client authenticates (device login) and logs a session |
| 0.5 | ADR template + task board + naming/folder standards doc | P1 | 0.2 | First ADR (ASC placement) written |

### Phase 1 — Local combat prototype (single-player)
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 1.1 | Character + CMC + Enhanced Input (move/look/dodge/attack) | P0 | 0.1 | Character moves/dodges locally with buffered input |
| 1.2 | Import Game Animation Sample; Motion Matching locomotion | P0 | 1.1 | Character locomotes smoothly with retargeted anims |
| 1.3 | Basic melee montage + Anim Notify State hit window | P0 | 1.2 | Notify fires trace window; debug shape draws |
| 1.4 | Swept-trace melee hit on a dummy (local) | P0 | 1.3 | Dummy takes damage only during hit window |
| 1.5 | Dodge i-frames + directional block cone (local) | P1 | 1.1 | Dodge grants invuln tag; frontal block negates hit |

### Phase 2 — Networked combat on dedicated server
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 2.1 | Package Linux dedicated server; connect 2 PIE clients | P0 | 1.1 | Two clients see each other move on a dedicated server |
| 2.2 | Move validation + reconciliation sanity (no rubber-band) | P0 | 2.1 | Normal play shows no rubber-banding at 80 ms latency |
| 2.3 | Server-authoritative swept-trace hits | P0 | 1.4,2.1 | Only server applies damage; client claims ignored |
| 2.4 | Server-validated dodge i-frames + block | P0 | 1.5,2.3 | Dodge/block validity decided on server tick |
| 2.5 | Net emulation matrix pass | P1 | 2.3 | Combat playable at 150 ms / 1% loss |

### Phase 3 — GAS classes & abilities
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 3.1 | ASC on PlayerState; Attribute Sets (Health/Stamina/Guard) | P0 | 2.1 | Attributes replicate to owning client |
| 3.2 | Convert attack/dodge/block to Gameplay Abilities + GEs | P0 | 3.1,2.4 | Abilities activate with prediction; server confirms |
| 3.3 | Cooldowns/costs as GEs; tag taxonomy | P0 | 3.2 | Early re-activation rejected server-side |
| 3.4 | One class with data-driven Skein Forms, Threads, and one Keystone | P0 | 3.3 | Equipped Skein choices visibly change combat behavior |
| 3.5 | Gameplay Cues (VFX/SFX) + Niagara telegraphs | P1 | 3.2 | Telegraph decal+particles precede damage tick |
| 3.6 | Add classes 3–4 | P2 | 3.4 | Four classes selectable |

### Phase 4 — Nakama persistence integration
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 4.1 | Account login + character record/select flow | P0 | 0.4 | Minimal character persists; schema separates people, male/female sex, appearance, class, faction, level, and Ember Rank |
| 4.2 | TypeScript RPC: authoritative inventory write w/ version check | P0 | 4.1 | Concurrent writes can't dupe; version mismatch rejected |
| 4.3 | Server-to-server persistence via HTTP key | P0 | 4.2,2.1 | Dedicated server writes XP/loot; client can't forge |
| 4.4 | Persist equipment/Skein/Doctrine/quests/currency (wallet) | P0 | 4.3 | Full character state round-trips |
| 4.5 | Schema versioning + one migration | P1 | 4.4 | Old character upgrades cleanly |

### Phase 5 — Dungeon & party flow
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 5.1 | Representative safe hub + outdoor zone + instanced dungeon maps | P0 | 2.1 | All three spaces load; hub boundary behavior is data driven |
| 5.2 | Party creation/invite (Nakama) + Redis presence | P0 | 4.1 | Party of up to 4 forms; presence shows in Redis |
| 5.3 | Instance allocator RPC → connect with token | P0 | 5.1,5.2 | Party enters same dungeon instance |
| 5.4 | One co-op boss with telegraphs + loot on the server | P1 | 5.3,3.5 | Boss killable; loot persists via 4.3 |
| 5.5 | Chat + friends | P1 | 4.1 | Zone/party chat + friends list work |

### Phase 6 — Mandatory faction-frontier PvP slice
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 6.1 | Server-owned faction identity and territory PvP policy | P0 | 4.1,5.1 | Hostility is mandatory in mixed territory and disabled in the safe city |
| 6.2 | One contained mixed-territory objective | P0 | 6.1 | Opposing players contest one PvPvE objective without opt-in flagging |
| 6.3 | Contribution, unbanked resource, death, and banking flow | P0 | 6.2,4.3 | Reward and controlled loss persist transactionally without duplication |
| 6.4 | Respawn safety, repeat-kill decay, bounty, and anti-collusion pass | P1 | 6.3 | Spawn camping and kill trading provide no progression advantage |
| 6.5 | Population and network measurement | P1 | 6.2 | Server FPS, bandwidth, combat latency, and faction ratio are recorded under load |

### Phase 7 — GameLift cloud test
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 7.1 | GameLift Unreal plugin + Server SDK 5.x lifecycle | P0 | 2.1 | InitSDK/ProcessReady/OnStartGameSession/OnProcessTerminate wired |
| 7.2 | GameLift Anywhere local fleet test | P0 | 7.1 | Local machine hosts a GameLift session |
| 7.3 | Managed EC2 fleet (1–2 c5.large Linux) closed test | P1 | 7.2 | Remote players connect via allocator |
| 7.4 | Cost + capacity measurement | P1 | 7.3 | Real CCU/instance and $/hour recorded |

### Phase 8 — Polish, metrics, GM tools
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 8.1 | CommonUI HUD (health/stamina/cast bars, reticle, nameplates) | P0 | 3.1 | HUD readable; nameplates pooled |
| 8.2 | Metrics (Prometheus/Grafana) + structured logs + crash reports | P0 | 0.4 | Dashboards show server FPS, errors, crashes |
| 8.3 | Simple GM/admin tools (kick, teleport, grant item, inspect) | P1 | 4.4 | GM can act with audit logging |
| 8.4 | Accessibility (remap, colorblind, shake toggle, subtitles) | P1 | 8.1 | All toggles function |
| 8.5 | Easy Anti-Cheat integration | P1 | 7.3 | EAC-protected build runs |
| 8.6 | Performance pass (Unreal Insights, scalability) | P1 | 8.1 | 60 FPS on target PC; server ≥ tick rate |

### Phase 9 — Faction world and capital invasion expansion
| ID | Task | Pri | Deps | Done when… |
|---|---|---|---|---|
| 9.1 | Two protected faction-start slices | P0 | 6.1,8.6 | Each faction reaches the same frontier threshold through a distinct campaign |
| 9.2 | Individual capital infiltration | P1 | 9.1 | Enemy infiltrators can reach military targets but never beginner districts |
| 9.3 | Organized capital-invasion objective chain | P1 | 9.2,6.5 | Attackers and defenders resolve a temporary, recoverable invasion state |
| 9.4 | Population recovery and anti-snowball validation | P1 | 9.3 | A losing faction retains a measured route back into meaningful conflict |

---

## G) CODEX PROMPT PACK + AI CODE REVIEW CHECKLIST

Each prompt: repo context, hard constraints, output format, validation checklist.

### Prompt 1 — Server-validated melee swept-trace tied to anim notify
> **Context:** UE 5.8 C++ project, module `GameCombat`. Character uses GAS with ASC on PlayerState. Melee attacks are Anim Montages with an `ANS_HitWindow` Anim Notify State.
> **Task:** Implement server-authoritative melee hit detection. During `ANS_HitWindow`, the **server** performs a swept capsule trace along the weapon socket each tick, collects unique hit actors, and applies a damage GameplayEffect via the source ASC. The client only plays cosmetics.
> **Hard constraints:** No client authority over hits. Client hit claims must be ignored. Dedupe targets per swing. Respect team/faction filter. Use `AbilitySystemComponent`/GE for damage, not direct health edits.
> **Output format:** `.h` + `.cpp` for the Anim Notify State and a `UGameplayAbility_MeleeAttack`, with inline comments and the exact server/authority guards.
> **Validation checklist:** (a) trace runs only on `HasAuthority()`; (b) damage applied only via GE; (c) no duplicate hits per swing; (d) works at 150 ms latency; (e) no per-frame allocation in the trace loop.

### Prompt 2 — Directional block ability (frontal cone + stamina) in GAS
> **Context:** Same project; `AttributeSet` has `Guard` (stamina). Block is a Gameplay Ability with tag `State.Blocking`.
> **Task:** Implement a hold-to-block ability that, while active, checks incoming damage: if the attacker is within a frontal cone (configurable half-angle, default 60°) and `Guard > 0`, reduce/negate damage and drain Guard; else normal damage. All resolved server-side in damage execution.
> **Hard constraints:** Server-authoritative; block state and Guard drain decided on server. No client-trusted mitigation. Data-driven cone angle and drain rate.
> **Output format:** Ability `.h/.cpp` + a `UGameplayEffectExecutionCalculation` for mitigation, with comments.
> **Validation checklist:** authority guard; cone math correct (dot product vs facing); Guard clamped ≥0; mitigation only server-side; tunable via DataAsset.

### Prompt 3 — Dodge ability with i-frame tag + server validation
> **Context:** GAS project; tag `State.Dodging` = invulnerability window.
> **Task:** Implement a dodge Gameplay Ability that plays a root-motion dodge, grants `State.Dodging` for a configurable window, and has the server ignore incoming damage while the tag is active. Client predicts the animation; server owns invulnerability.
> **Hard constraints:** i-frame validity decided on server tick; no client authority; cooldown as a GE; configurable window/cooldown via DataAsset.
> **Output format:** Ability `.h/.cpp` + notes on prediction-key handling and where the server checks the tag during damage.
> **Validation checklist:** authority-owned i-frames; predicted anim only; cooldown enforced server-side; window matches design (~0.2–0.4 s); no rollback issues on mispredict.

### Prompt 4 — Nakama TypeScript RPC: authoritative inventory write w/ version check
> **Context:** Nakama TypeScript runtime; collection `inventory/{characterId}`; economy writes must be server-authoritative and dupe-proof.
> **Task:** Write an RPC `rpcInventoryApply` that takes an operation + expected version, reads the storage object, validates the operation server-side (ownership, cost, stack limits), and writes back using the storage **version** for OCC. Reject on version mismatch. Make it idempotent via a request-id guard.
> **Hard constraints:** No client-supplied balances trusted; all validation server-side; use OCC version; idempotent; log to audit collection.
> **Output format:** One TypeScript file with the RPC, types, and error handling; registered in `InitModule`.
> **Validation checklist:** version mismatch → rejected; duplicate request-id → no double apply; invalid op → rejected with code; audit entry written; no floating-point money.

### Prompt 5 — GameLift Server SDK 5.x lifecycle in the UE dedicated server
> **Context:** UE 5.8 Linux dedicated server, module `GameServer`, GameLift Unreal plugin (Server SDK 5.x).
> **Task:** Implement the GameLift lifecycle: `InitSDK()` (SDK v5), `ProcessReady()` with `OnStartGameSession`, `OnProcessTerminate`, and periodic health check callbacks; on `OnStartGameSession` load the requested map/instance and accept players; on terminate, persist and shut down gracefully.
> **Hard constraints:** Server-only code (guard against client builds); SDK version explicitly 5.x; graceful drain on terminate; no blocking calls on the game thread.
> **Output format:** A `UGameInstanceSubsystem` (or module) `.h/.cpp` with the lifecycle wiring and comments.
> **Validation checklist:** InitSDK version 5.x; ProcessReady called after subsystems ready; terminate persists state; health check returns true only when healthy; compiles server-target only.

### Prompt 6 — Redis-backed party presence
> **Context:** Nakama TypeScript runtime + Redis; parties up to 4; presence must survive zone transfers.
> **Task:** Implement RPCs to create/join/leave a party and update per-member presence (zone/instance/status) in Redis with TTL, plus pub/sub notify to party members on change.
> **Hard constraints:** Redis is cache only (source of truth in Postgres for membership if durable); TTL to auto-clean stale presence; server-authoritative; rate-limited.
> **Output format:** TypeScript RPCs + Redis key schema documentation.
> **Validation checklist:** stale presence expires via TTL; leave cleans keys; pub/sub reaches members; no durable data lost if Redis flushes; rate limited.

### AI code-review checklist (apply to every generated snippet)
1. **Authority boundary** — does the server decide all outcomes? Any client trust?
2. **Latency behavior** — does it hold up at 150 ms / jitter / loss?
3. **Replication scope** — is anything over-replicated? Relevancy/dormancy used?
4. **Exploit surface** — speed/teleport/cooldown/hit/dupe/replay all covered?
5. **Persistence integrity** — OCC version + idempotency + audit log?
6. **Performance** — no per-frame allocations; pooled FX; bounded traces.

---

## H) GLOSSARY

- **Replication** — Unreal auto-syncing server state to clients.
- **RPC (Remote Procedure Call)** — calling a named function on another machine (Server/Client/Multicast).
- **Authoritative server** — the server is the single source of truth for outcomes.
- **Prediction / reconciliation** — client acts on input immediately, then corrects if the server disagrees.
- **GAS / ASC / GE / GA / GC** — Gameplay Ability System / Ability System Component (the hub) / Gameplay Effect (damage/buff/cooldown) / Gameplay Ability (an action) / Gameplay Cue (cosmetic FX).
- **Anim Notify** — a marker on an animation that fires code at a specific frame (a "Notify State" spans a window).
- **Dedicated server** — a headless (no graphics) server process running the simulation.
- **Shard / instance** — a separate running copy of a zone/dungeon/arena.
- **CCU (Concurrent Users)** — players online at the same time.
- **Tick rate** — how many times per second the server updates (e.g., 30 Hz).
- **i-frames (invulnerability frames)** — a window during a dodge where you take no damage.
- **Interest management** — only sending each client the actors relevant to it.
- **Idempotency** — a repeated request has the same effect as doing it once (safe retries).
- **JSONB** — PostgreSQL binary JSON column type, indexable and queryable.
- **Pub/sub** — publish/subscribe messaging; publishers post to channels, subscribers receive.
- **OCC (Optimistic Concurrency Control)** — write succeeds only if the data version matches, preventing lost updates/dupes.

---

## I) OPEN DECISIONS (each with a recommended default)

1. **Number of MVP classes: 2 or 4?** — *Default: start with 2 (one melee, one ranged), add 3–4 after combat feel is proven.*
2. **Nakama runtime language: TypeScript vs Go?** — *Default: TypeScript for the team's speed; revisit Go only for a profiled hot path.*
3. **Contested-world tick rate: 30 Hz vs a higher measured target?** —
   *Default: begin at 30 Hz and raise it only when combat tests show a
   responsiveness gain the server and bandwidth budgets can sustain.*
4. **Adopt Lyra Experiences/Game Features now or later?** — *Default: simplified single-plugin structure now; Game Features later.*
5. **EAC timing.** — *Default: integrate before the first public/paid beta, not during prototyping.*
6. **Self-host Nakama vs Heroic Cloud.** — *Default: self-host a small VM through closed beta; Heroic Cloud ($600/mo start) only when revenue justifies it.*
7. **When to introduce Replication Graph.** — *Default: only when a real instance exceeds ~30–40 concurrent players and profiling shows replication CPU as the bottleneck.*
8. **Party size cap.** — *Default: 4 for MVP co-op.*
9. **Frontier progression threshold.** — *No default; decide from the tested
   onboarding and level curve rather than inventing a level now.*
10. **Capital-invasion cadence and scale.** — *No default; prototype
    infiltration and one objective chain before choosing schedules or player
    counts.*

*Modeled estimates (tri-counts, CCU-per-instance ranges, animation frame timings, costs) are engineering rules of thumb, not measured guarantees — validate with your own profiling and current vendor pricing. Version- and price-sensitive facts (UE 5.8 Iris status, GameLift instance rates, Nakama/Sentry/FMOD/Perforce pricing tiers, EAC tiers) were verified against 2025–2026 sources but should be re-checked at purchase time.*
