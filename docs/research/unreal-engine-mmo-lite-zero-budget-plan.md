# Indie UE5 "MMO-Lite" Action MMORPG: Build Plan + $0 Budget Analysis

> **Document status - historical research.** This report explicitly could not
> read the project files and therefore uses placeholders and alternative tool
> assumptions. It is retained for budget and implementation background, not as
> current product authority. Use the
> [Documentation Index](../documentation-index.md),
> [Game Design Bible](../game-design-bible.md), and repository roadmap for current
> decisions.

**IMPORTANT SOURCING NOTE (read first):** I was unable to open the six Project Knowledge files ("deep-research-report.md", "Lore_Architecture...", "Indie_MMO-Lite...", "champions_of_the_first_cycle.pdf", "Settlements_of_Aetheln_City_and_Village_Codex.pdf", "phase0environmentsetup.pdf") — no file-reading tool was available in this environment. Per your instruction NOT to invent project details (game name, class list, zone counts, exact tech stack), I have written the plan using neutral placeholders like **[per phase0environmentsetup.pdf]** and flagged every spot where the files are the authority. Reconcile each placeholder against your files; where they conflict, **your files win.**

## TL;DR
- **You can build and playtest this entire game for $0 today.** The $0 stack: Epic Games account + UE5 (free under $1M revenue), Epic Online Services (free at any scale for auth/friends/voice/lobbies), Diversion or Perforce for large-file version control (both free for a solo dev), Fab/Quixel Megascans + Blender for assets, and Tailscale (free, 6 users) so friends join your locally-hosted server without paid hosting.
- **EOS is the right free backend for auth/social/voice/matchmaking, but it is NOT a game-server host and NOT an MMORPG database.** You must run your own authoritative dedicated server and your own database for persistent characters/inventory. For a 10–50 player playtest, a free Oracle Cloud Always Free ARM VM + Supabase free tier covers both at $0.
- **First real costs arrive only later:** a persistent 24/7 server beyond free-tier limits (~$4–13/mo VPS), and one-time launch fees (Steam Direct $100, domain ~$12/yr). None are needed now.

## Key Findings

**Licensing is free for you.** Unreal Engine 5 is free to develop and ship. Per unrealengine.com/license, "All lifetime gross revenue above $1M... will be subject to a 5% royalty," and Epic's royalty FAQ describes the "Launch Everywhere with Epic" program giving "a reduced Unreal Engine royalty rate of 3.5% rather than the 5% standard," effective January 1, 2025. As a beginner earning $0, you owe nothing and file nothing until you ship and cross the $1M-per-product threshold.

**EOS is free at any scale but has hard architectural limits.** Epic Online Services carries "no royalty or hosting fees," "no limit on number of player accounts," and no MAU threshold. But (from research into Epic's own docs): EOS does **not** host your game simulation — its P2P relay "is not intended for use as a dedicated (authoritative) game server." [Edgegap](https://edgegap.com/blog/can-epic-online-services-eos-relays-allow-for-dedicated-server-or-authoritative-server) Its Player Data Storage is a client-owned cloud-save (200 MB max file; 400 MB / 1,000 files per user; no cross-player queries), explicitly not a managed database for player inventories. Its Lobby default/max is **64 players** per lobby (per the EOS Lobby Interface; Redpoint's EOS Framework notes lobbies now "default to 64 players instead of 4"). **Translation:** use EOS free for login, friends, voice, and matchmaking; build your own authoritative dedicated server + database for the persistent world.

**Version control is the beginner's biggest trap.** UE projects are full of large binary files. Per GitHub Docs, "GitHub Free and Pro users will receive 10 GB of storage and 10 GB of bandwidth per month" for Git LFS — a UE project blows through that fast, and pushes are "silently rejected"/blocked once quota is exceeded without a payment method. Better free options for large UE projects: **Diversion** (free for 5 users, 100 GB storage, built for UE binaries) or **Perforce P4/Helix Core** (free up to 5 users / 20 workspaces; [Perforce Software](https://www.perforce.com/products/helix-core) the industry-standard for UE, but heavier to self-host).

**A key 2026 change:** Microsoft **PlayFab cut its free tier from 100,000 to 1,000 lifetime players on March 11, 2026.** Per Microsoft's docs, "A title in development mode can only have up to 1,000 lifetime player account creations," and full free "Foundation Mode" now requires shipping on Xbox. This removes PlayFab as a general-purpose free MMO backend — use Supabase or Firebase for persistence instead.

## Details

### DELIVERABLE 1 — Step-by-step UE5 implementation plan

**How to read this:** Tasks are grouped by phase. Each lists **Priority** (P0 = must-do foundation, P1 = core gameplay, P2 = later), **Depends on**, and **Done when** (acceptance criteria).
- *Replication* = Unreal's system for syncing state between server and clients.
- *Server-authoritative* = the server decides what's true; clients only request and display.
- *Listen server* = one player's PC acts as both host and player. *Dedicated server* = a headless host with no local player, running the authoritative world.
- *PIE* = Play-In-Editor (test multiplayer inside the editor with multiple windows).

#### Phase 0 — Environment Setup *(follow phase0environmentsetup.pdf as the authority; steps below are standard UE5 setup to reconcile against it)*
- **0.1 Epic account + Launcher + UE5** — P0 — Depends on: none — *Done when:* UE5 (use the version specified in phase0environmentsetup.pdf; if unspecified, latest stable is UE 5.7, released Nov 2025) opens and launches a blank C++ project.
- **0.2 Install IDE + compiler** — P0 — Depends on: 0.1 — *Done when:* Visual Studio (Windows) or Rider builds the C++ project with no errors.
- **0.3 Choose & init version control** — P0 — Depends on: 0.1 — *Done when:* Project is committed to Diversion (recommended) or Perforce; an ignore rule excludes `Binaries/`, `Intermediate/`, `DerivedDataCache/`, `Saved/`; a second machine/teammate can pull and open the project.
- **0.4 Project scaffolding** — P0 — Depends on: 0.1–0.3 — *Done when:* Folder structure, naming conventions, and default maps exist per phase0environmentsetup.pdf.
- **0.5 Free asset pipeline** — P1 — Depends on: 0.1 — *Done when:* You can import a Fab/Quixel Megascans asset and a Blender-exported FBX into the project.

#### Phase 1 — Core Character & Movement *(reconcile class list against champions_of_the_first_cycle.pdf)*
- **1.1 Player Character + Enhanced Input** — P0 — Depends on: 0.4 — *Done when:* A character moves/looks/jumps using UE5 Enhanced Input; Input Mapping Contexts separate movement from abilities.
- **1.2 Camera & control feel** — P1 — Depends on: 1.1 — *Done when:* Action-combat camera (per the build-plan file) behaves correctly.
- **1.3 Make movement replicated** — P0 — Depends on: 1.1 — *Done when:* In a 2-player PIE test set to "Play As Client," both players see each other move smoothly; movement is server-validated (CharacterMovementComponent replicates by default — verify, don't assume).

#### Phase 2 — Networking Foundation
- **2.1 Client-server model working in PIE** — P0 — Depends on: 1.3 — *Done when:* PIE with 2–3 players + "Run Dedicated Server" shows all clients sharing one authoritative world state.
- **2.2 Replicated core stats (health/resource)** — P0 — Depends on: 2.1 — *Done when:* A replicated `Health` variable (`UPROPERTY(ReplicatedUsing=OnRep_Health)`, registered in `GetLifetimeReplicatedProps` with `DOREPLIFETIME`) updates on all clients when the server changes it; clients cannot change it directly.
- **2.3 Server RPCs for actions** — P0 — Depends on: 2.2 — *Done when:* A client action triggers a `Server_` RPC; the server validates and applies it; result replicates to all. No gameplay outcome is decided on the client.

#### Phase 3 — Action Combat *(scope from the "Indie_MMO-Lite..." build plan + champions_of_the_first_cycle.pdf)*
- **3.1 Adopt Gameplay Ability System (GAS)** — P1 — Depends on: 2.3 — *Done when:* GAS plugin enabled; AbilitySystemComponent placed correctly (PlayerState is Epic's recommended pattern for persistent player stats; Character for simple NPCs). *Open decision — see Caveats.*
- **3.2 First ability (server-authoritative)** — P1 — Depends on: 3.1 — *Done when:* A basic attack runs through GAS; the server is authoritative for all GameplayEffects and attribute changes; clients predict for responsiveness only.
- **3.3 Attributes & AttributeSet** — P1 — Depends on: 3.1 — *Done when:* Health/resource/damage attributes live in an AttributeSet that only clamps values and broadcasts events (ability logic stays in abilities).
- **3.4 Hit detection & damage** — P1 — Depends on: 3.2–3.3 — *Done when:* Damage is applied server-side; a client cannot spoof damage.
- **3.5 Enemy AI** — P2 — Depends on: 3.4 — *Done when:* A basic enemy searches/chases/attacks, all driven server-side.

#### Phase 4 — World & Zones *(zone count/layout: Settlements_of_Aetheln_City_and_Village_Codex.pdf is the authority)*
- **4.1 First playable zone** — P1 — Depends on: 3.x — *Done when:* One zone from the codex is greyboxed and traversable in multiplayer.
- **4.2 Zone travel** — P2 — Depends on: 4.1 — *Done when:* Player moves between two zones with state preserved. *Open decision: seamless travel vs. instanced zones vs. World Partition — depends on the world design in your files.*
- **4.3 Content pass with free assets** — P2 — Depends on: 4.1 — *Done when:* Zone dressed with Megascans/Blender assets at target performance.

#### Phase 5 — Backend & Persistence
- **5.1 Integrate EOS (auth + friends + voice)** — P1 — Depends on: 2.x — *Done when:* Players log in via EOS, see friends, and can voice chat. (The community "EOS Integration Kit" plugin can speed this up.)
- **5.2 EOS matchmaking/sessions** — P1 — Depends on: 5.1 — *Done when:* A player can create/find/join a session (≤64 per lobby).
- **5.3 Own database for persistence** — P0 for persistence — Depends on: 5.1 — *Done when:* Character position/stats/inventory save to your own DB (Supabase free tier recommended) and reload on next login. **Do NOT use EOS Player Data Storage as your DB** (client-owned, no cross-player queries).
- **5.4 Server↔DB writes are authoritative** — P0 — Depends on: 5.3 — *Done when:* Only the dedicated server reads/writes persistent data; clients never talk to the DB directly.

#### Phase 6 — Dedicated Server Build & Playtesting
- **6.1 First dedicated server build** — P0 — Depends on: 2.x — *Done when:* A headless server build cooks and runs; a packaged client connects by IP. (Building a UE dedicated server historically requires a **source build** of the engine from GitHub, not just the Launcher version — plan for this.)
- **6.2 LAN / listen-server playtest** — P1 — Depends on: 6.1 — *Done when:* You + a friend play together on the same LAN, or via a listen server.
- **6.3 Remote friends via VPN tunnel** — P1 — Depends on: 6.2 — *Done when:* Friends across the internet join your locally-hosted server through **Tailscale** (free; no port-forwarding, no paid hosting).
- **6.4 Free-tier cloud dedicated server** — P2 — Depends on: 6.1 — *Done when:* Server runs 24/7 on an **Oracle Cloud Always Free ARM VM** and remote clients connect. *(Cook a LinuxArm64 server target — see Caveats.)*
- **6.5 Playtest loop** — P1 — Depends on: 6.2 — *Done when:* You run repeatable 10–50 player sessions and log bugs/perf.

### Using Codex (AI coding assistant) safely

**Write precise prompts.** Every Codex prompt for this project should include:
1. **Engine version** (e.g., "Unreal Engine 5.7").
2. **C++ vs Blueprint** and the exact class you're editing (e.g., "in `AAethelnCharacter` derived from `ACharacter`").
3. **Networking requirements** — state explicitly: "server-authoritative; client sends a `Server_` RPC; validate on server; replicate result; do not decide outcomes on the client."
4. **Replication specifics** — "expose `Health` with `UPROPERTY(ReplicatedUsing=OnRep_Health)`, register in `GetLifetimeReplicatedProps` with `DOREPLIFETIME`."
5. **Context** — paste the relevant existing header/struct so names match.
6. **GAS specifics** when relevant — "AbilitySystemComponent lives on PlayerState; use GameplayEffects for attribute changes."

**Review checklist for every Codex output:**
- **Correctness:** Compiles; does what the ticket's "Done when" says; no hallucinated APIs (verify each engine function exists in your UE version).
- **Unreal best practices:** Correct `UPROPERTY`/`UFUNCTION` macros; Unreal containers (`TArray`, `TMap`) and `TObjectPtr`; no raw `new`/`delete` on UObjects; Epic naming (`A`/`U`/`F` prefixes).
- **Networking correctness:** Server-authoritative; `HasAuthority()` guards server-only logic; replicated vars registered; RPCs marked `Server`/`Client`/`NetMulticast` correctly and `WithValidation` where needed; no trusting client input.
- **Performance:** No per-frame heavy work in `Tick`; use events/timers/Ability Tasks; sane replication frequency; no unbounded loops.
- **Security:** Server validates all client requests (range, cooldown, ownership); no secrets/keys in client code; DB access only from the server.

### DELIVERABLE 2 — Budget & accounts research (2026 pricing)

#### "Cost now: $0" — sign up for these today (all free)
1. **Epic Games account + Unreal Engine 5** — free; royalty only above $1M lifetime revenue per product (5%, or 3.5% if launched on Epic Games Store). You owe nothing now.
2. **Epic Online Services (EOS)** — free at any scale: auth, friends/presence, lobbies/sessions, matchmaking, voice, Easy Anti-Cheat. No account/MAU limit, no hosting/royalty fee.
3. **Version control — pick ONE:**
   - **Diversion (recommended for beginners):** free for 5 users, 100 GB storage, up to 5 repos; built for UE binaries; cloud-hosted (nothing to run). Indie eligibility: revenue < $100K, funding < $1M.
   - **Perforce P4 / Helix Core:** free up to 5 users / 20 workspaces; UE-native and industry-standard, but you host the server yourself (steeper setup).
   - **Avoid GitHub + Git LFS as your primary store** for a large UE project: free LFS is only 10 GB storage + 10 GB/month bandwidth; overages block pushes.
4. **Assets & tools:** **Fab / Quixel Megascans** (Megascans/Megaplants free to claim under Fab's Standard License for UE users), **Blender** (free, open-source), Quixel Mixer (free).
5. **Multiplayer playtesting (free):** local **listen server** and **LAN** for same-network friends; **Tailscale free "Personal"** tier — per Tailscale's April 8, 2026 pricing change it now "accommodates up to six users and places no limit on the number of user-owned devices" — to let remote friends join your locally-hosted server with no port-forwarding and no paid hosting. (Alternatives: ZeroTier free tier, now 10 devices / limited networks after its 2026 restructuring; Radmin/Hamachi for small LAN emulation.)
6. **Backend persistence (free tier):** **Supabase** free — per rates verified May 2026, "500 MB of database storage, 50,000 monthly active users, 5 GB of egress, and 500 MB of file storage across up to 2 projects... free projects auto-pause after 1 week of inactivity" (ping it to keep alive). Recommended as your character/inventory DB. Alternative: **Firebase Spark** (free: Firestore ~1 GB, 50K reads / 20K writes / 20K deletes per day; Auth free up to 50K MAU).
7. **Free-tier 24/7 dedicated server (when ready):** **Oracle Cloud Always Free** ARM (Ampere A1). Per InfoQ (July 2026), Oracle "reduced the Always Free Ampere A1 Compute allowance... from 4 OCPUs and 24 GB of RAM to 2 OCPUs and 12 GB of RAM," effective June 15, 2026 — still enough (2 OCPU / 12 GB + 200 GB storage) for a small UE dedicated server at 10–50 player playtest scale.

#### "Costs later" — realistic monthly estimates at 10–50 concurrent players, and when they trigger

| Item | When it triggers | Realistic cost |
|---|---|---|
| **Persistent cloud dedicated server** (beyond Oracle free tier, or if Oracle ARM capacity is unavailable / the idle instance is reclaimed) | When you need reliable 24/7 uptime or more than 2 OCPU/12 GB | **Hetzner** ARM CAX11 ~$4–5/mo, or CPX-class ~$8–13/mo (note the April 2026 price rises; CX/CAX are EU-only) |
| **Version control overage** | Assets exceed 100 GB (Diversion) or you add a 6th user | Diversion +$10/mo per 100 GB; users 6–10 = $12/user/mo [Diversion](https://www.diversion.dev/indie-pricing) |
| **Supabase Pro** | DB > 500 MB, > 50K MAU, or you need no-pause uptime | $25/mo |
| **Firebase Blaze** (if used instead) | Past free daily quotas | pay-as-you-go (~$12/mo at ~5K DAU) — **no hard spending cap; set budget alerts** |
| **Tailscale paid (Standard)** | Only if > 6 users need the tunnel | $8/user/mo |
| **EOS** | Never for base features; only enterprise anti-cheat support is paid | $0 |

#### Deferred future costs — **NOT needed now**
- **Steam Direct:** $100 one-time per app, recoupable after $1,000 revenue — only when you decide to publish on Steam.
- **Domain name:** ~$10–15/year — only for a website/marketing.
- **Code signing certificate:** ~$100–400/yr — only to avoid "unknown publisher" warnings at public release.
- **Marketing / capsule art / trailers:** variable — only near launch.
- **UE royalty:** only above $1M lifetime revenue per product.

## Recommendations

**Do this week (all $0):**
1. Create an Epic account; install UE5 (version per phase0environmentsetup.pdf) and Visual Studio/Rider.
2. Set up **Diversion** and commit your project with correct ignore rules. (Choose Perforce instead only if you specifically want the industry-standard workflow and can host it.)
3. Open an EOS product in the Epic Dev Portal and a **Supabase** project.
4. Build **Phase 0 → Phase 2** (character + replicated movement + working client-server PIE) *before* touching combat. Getting server-authority right early prevents rewrites.

**Then, in order:** GAS combat (Phase 3) → first zone (Phase 4) → EOS login + your DB persistence (Phase 5) → dedicated server build + Tailscale playtest (Phase 6). Only move a server to Oracle's free tier once local/LAN/Tailscale play is stable.

**Thresholds that change the plan:**
- **> 64 concurrent players in one space** → you must shard/instance; EOS lobbies won't cover it; re-architect zones as instances.
- **Oracle ARM "out of capacity" or idle-reclaim problems** → switch to Hetzner CAX11 (~$4–5/mo).
- **Supabase pausing hurts playtests** → add a keep-alive ping, or upgrade to Pro ($25/mo).
- **Version-control storage > 100 GB** → prune history or pay Diversion's $10/100 GB.
- **You decide to ship on Steam** → budget the $100 Steam Direct fee + domain + optional code signing.

**Backend verdict:** Use **EOS (free) for auth/social/voice/matchmaking + your own dedicated server + Supabase (free) for persistence.** Do **not** adopt PlayFab as your free backend — its free tier was cut 99% on March 11, 2026 (100K → 1,000 lifetime players) and full free access now effectively requires an Xbox commitment.

## Caveats
- **Project files not read:** All game-specific specifics (name, classes, zones, exact UE version, chosen tech stack) must come from your six Project Knowledge files, which I could not open. Every **[bracketed placeholder]** and "reconcile against your files" note marks a spot where your files override this plan.
- **Open decisions you must make:** (a) GAS AbilitySystemComponent placement (PlayerState vs Character); (b) zone architecture (seamless World Partition vs instanced zones) — depends on whether your design is one continuous world or sharded instances; (c) dedicated-server OS/arch target (Linux x86 vs LinuxArm64 — Oracle's free tier is ARM, so you'd cook a **LinuxArm64** server); (d) version-control choice (Diversion vs Perforce).
- **Free tiers change fast in 2026:** Oracle halved its ARM free allowance (June 15, 2026); PlayFab cut its free tier (March 11, 2026); Tailscale (April 8, 2026), Hetzner (April 1, 2026), and ZeroTier all changed pricing this year. Re-verify any tier before you architect around it.
- **"MMO" scale reality:** UE's out-of-the-box networking struggles well below true "massive" counts (community testing cites practical limits of roughly a few hundred players in one area, and far fewer for action combat). "MMO-lite" with sharded/instanced zones of ≤64 players is realistic for a solo/small team; a single 500+ player battlefield is not.
- **Dedicated server source build:** Building a UE dedicated server typically requires the GitHub source version of the engine, a heavier setup than the Launcher version — budget time for it.
- **EOS is glue, not hosting or a database:** "Free" covers EOS backend services only. Your own dedicated-server compute, database, and any bandwidth outside EOS relays are separate costs (all $0 on the free tiers above at playtest scale).
