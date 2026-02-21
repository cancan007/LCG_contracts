# AA Aggregators (laneKey, deterministic phases, versioned ops)

This document is the **AA-only** part of the repository (intended to be readable first, then verifiable in code).

If you are here for the R&D thesis (“movement of meaning”), see `README_RND.md`.

---

## TL;DR (30 seconds)

- `laneKey` partitions intent into domain contexts (industry / service / action).
- SmartAccount is a stable “intent interpreter” that enforces **deterministic phase boundaries**.
- Domain variability lives in **modules**, composed through **aggregators**.
- **New addition:** aggregators now support **version-tagged module sets** so upgrades/rollback are ops-friendly and auditable.

---

## AA overview diagram

**Figure 1: AA whole overview**
![](./images/self-analysis/intent_aa_sa_design_image.png)

**Figure 2: laneKey × deterministic phases × versioned aggregators (DDD dev methodology)**
![](./images/self-analysis/l3_inten_aa_DDD_development_methodology_image.png)

> Figure 2 emphasizes:
>
> - laneKey as a DDD domain boundary (industry/service/function)
> - protocol-fixed phase touchpoints (pre/post hooks)
> - aggregators as the composition + ops surface
> - version management as an auditable upgrade/rollback primitive

---

## Why AA becomes blurry in L3-oriented UX

In UX-driven L3 directions, the boundaries between:

- domain logic (application semantics)
- protocol guarantees (minimal safety/interop requirements)
- account-level execution rules (what an account must do)

tend to blur.

As a result, **validator logic inevitably becomes domain-dependent**, and flexibility without structure can lead to protocol opacity.

---

## Design Goals

- Keep the SmartAccount structurally stable and easy to reason about
- Push domain flexibility into **modules**
- Route execution by **laneKey** (domain boundary)
- Make validation/execution phases deterministic
- Enable evolution via **module versioning**, without migrating accounts

This aligns with the spirit of **ERC-7579 (minimal modular account interfaces & module types for interoperability)**.
Note: this repo may implement a subset / evolving subset of the interfaces as the experiment progresses.  
(ERC-7579 defines minimal required interfaces/behavior for modular smart accounts and modules.)

---

## Stable Execution Phases (protocol-fixed)

Execution phases are intentionally kept stable:

- **Validation Phase**: optional `preHook` (0 or 1)
- **Execution Phase**: fixed `preHook` → `executor` → fixed `postHook`

In other words, the **hook invocation timing is protocol-defined**, while domain flexibility is delegated to modules.

---

## laneKey as Domain Boundary (DDD-aligned)

> **See Figure 2** (`l3_inten_aa_DDD_development_methodology_image`):  
> laneKey is treated as a DDD boundary (industry/service/function). The SmartAccount stays stable, while per-lane behavior is expressed via a fixed set of module slots (validator / hooks / executor).

Domain contexts are identified via `laneKey`.

Each `laneKey` maps to a fixed set of module slots:

- `validatorAggregator`
- `executorAggregator`
- `validationPreHookAggregator` (optional)
- `executionPreHookAggregator` (fixed)
- `executionPostHookAggregator` (fixed)

This provides:

- clear domain separation
- deterministic routing without SmartAccount bloat
- per-domain module evolution / rollback

---

## Aggregator Modules (extensibility without SmartAccount mutation)

Instead of making the SmartAccount itself “infinitely pluggable”, we use **Aggregator modules**:

- **ValidatorAggregator**: can fan-out / compose multiple validators
- **ExecutorAggregator**: can route / compose execution policies
- **HookAggregators**: can fan-out multiple hooks while keeping protocol positions stable

This keeps the SmartAccount simple, while enabling controlled extensibility.

### Validation preHook (runtime/signature/userOp observable)

A `validationPreHookAggregator` is designed to _observe_:

- runtime context
- signature bytes
- (packed) user operation payload

Its purpose is to provide a standard-ish observation point.
It can be initially empty (no-op) if no state change risk is desired, and can be enabled later.

---

## Where ERC-6900 fits (configuration & observability)

We use **ERC-6900** primarily as a _configuration/observability vocabulary_:

- permissioned module management
- introspection / “what is installed”
- configuration updates with clear diffs/events

Domain flexibility itself (allowlists, selector routing, spend limits, rate limits, policy versions)
should live inside modules, not inside the SmartAccount core.

(ERC-6900 standardizes modular smart contract accounts and account modules/plugins,
emphasizing secure permissioning and interoperability.)

---

## Account Abstraction (ERC-4337 v0.7 + laneKey domain config)

This repo also contains an experimental **SmartAccount** scaffold:

- **ERC-4337 EntryPoint v0.7** style `validateUserOp(PackedUserOperation)`
- **ERC-7579-ish modules**: validator / executor / hook (install/uninstall)
- A 192-bit **laneKey** represents the “domain context” (e.g. `industry/app/action`).
- Per-lane configuration is stored as `LaneConfig { validator, validationHook, executor, execHook }`.
- Execution hooks are fixed at the protocol level: **pre** + **post**. To keep SmartAccount simple, use a single hook module per lane (recommended: `ExecutionHookAggregator`) that internally fans out to N pre/post hooks.

### Manual lane selection without changing the execute() signature

`SmartAccount.execute(to, value, data)` accepts either:

- **raw**: `data == innerCallData`, laneKey defaults to `0`
- **wrapped**: `data = abi.encode(uint192 laneKey, bytes innerCallData)`

So the lane can be selected purely by how you encode `data` (no new params).

> Tip: For UserOps, bind execution to validation by using `executeUserOp(..., fullNonce)` and enforcing `fullNonce == userOp.nonce` in a validation hook (e.g. `NonceBoundCallDataValidationHook`).

--

## Toward Meaning-Aware Validation

As AA validators become domain-dependent (inevitable in L3 UX-heavy systems),
we propose exploring a lightweight recommendation layer for:

- meaning-structure-aware validation
- contextual reference modeling
- commitment structuring

This may require:

- a new discussion framework
- a classification separate from protocol-level EIPs
- recommended patterns for semantic AA modules

---

## Architectural Goals

- Keep SmartAccount minimal and stable
- Push contextual flexibility into modules
- Route execution via laneKey
- Maintain deterministic validation/execution phases
- Enable contextual evolution without SmartAccount mutation

---

## Long-Term Vision

This repository is a prototype for:

- Context-native SuperApps
- Structured intent routing
- Meaning-based liquidity observation
- Domain-partitioned account abstraction

It explores the hypothesis that:

> The next stage of Web3 infrastructure will abstract economic activity from price to contextual trace.

---

## What I added: Versioned aggregators for operations & maintenance

The original architecture already separates responsibilities:

- SmartAccount: stable control-flow + deterministic phases
- Modules: where design & development happens

However, once you have many domain lanes (many `laneKey`s) and modules evolve frequently, operations can become chaotic:

- “Which module set is active for this domain?”
- “Can we safely roll forward / roll back?”
- “How do we avoid accidental re-upgrades or partial upgrades?”

To address this, I applied **version management contracts** to the aggregator layer:

> **See Figure 2 (bottom-right)**:  
> aggregators are the composition + ops surface. Module sets are version-tagged so upgrades/rollbacks become explicit, auditable on-chain operations—without rewiring the SmartAccount frequently.

- Aggregators inherit `VersionedAggregatorBase`
- A version tag is `uint96` (semantic `major.minor.patch` packed)
- Aggregators can **record** a module set per version tag
- You can switch active module sets via `upgrade(...)` / `downgrade(...)`
- A version tag cannot be recorded twice (prevents accidental overwrite)

This keeps the SmartAccount stable while making upgrades:

- repeatable,
- monitorable (events),
- and reversible (explicit rollback path).

---

## Discussion points (Ethereum Magicians)

1. **Rollback / downgrade safety**
   - Who is authorized to downgrade?
   - Should downgrade be time-locked / multisig / guardian-gated?
2. **Monitoring**
   - Should aggregators emit a module-set hash for offchain monitoring?
3. **laneKey schema**
   - uint192 is compact and fast, but should laneKey be a typed-hash schema to prevent collisions?
