# AA Aggregators (laneKey, deterministic phases, versioned ops)

This document is the **AA-only** part of the repository (intended to be readable first, then verifiable in code).

If you are here for the R&D thesis (“movement of meaning”), see `README_RND.md`.

---

## TL;DR (30 seconds)

- `laneKey` partitions intent into domain contexts (industry / service / action).
- SmartAccount is a stable “intent interpreter” that enforces **deterministic phase boundaries**.
- Domain variability lives in **modules**, composed through **aggregators**.
- **New addition:** aggregators now support **version-tagged module sets** so upgrades/rollback are ops-friendly and auditable.
- A key implementation point is that `AccountFactory` manages laneKey-specific shared aggregator modules, so creating a new SmartAccount does not require manual per-lane wiring by the user.
- **Verified update:** the frontend-connected AA flow was confirmed on **OP Sepolia** from **estimate to execute** using passkey + paymaster + bundler.

---

## Verified on OP Sepolia from frontend

This architecture is not only conceptual.  
A frontend-connected AA flow was verified on **OP Sepolia** with:

- `eth_estimateUserOperationGas`
- final passkey signing
- `eth_sendUserOperation`
- successful contract execution

Confirmed execution path:

**frontend → estimate → final sign → send → execute**

The verified stack was:

- **ERC-4337 v0.7**
- **Pimlico bundler**
- **Passkey / WebAuthn**
- **ContextObservatoryPaymaster**
- **laneKey-based validator composition**
- **SmartAccount-based execution**

This matters because it shows that the design is not merely an R&D proposal:  
the AA path was validated end-to-end in a live testnet environment.

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

---

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

## Bootstrap via AccountFactory (shared lane modules, simple account creation)

A recent change is that shared lane-level aggregator modules are now registered in `AccountFactory`, not manually wired one-by-one at user deployment time.

### Why this matters

Without a bootstrap layer, creating a new SmartAccount would require:

- deploying or selecting validator/executor aggregators
- wiring them per lane
- configuring the account manually after creation

This quickly becomes operationally noisy when the application has multiple laneKeys.

### Current approach

`AccountFactory` acts as a bootstrap registry for lane-specific shared modules.

For each laneKey, the factory stores:

- validator aggregator
- validation hook (optional)
- executor aggregator
- execution hook (optional)

When a new `SmartAccount` is created, the factory:

1. deploys the account
2. installs the registered shared modules
3. sets lane configs automatically
4. transfers ownership to the user

This means that user-side account creation becomes much simpler:

- create SmartAccount
- set passkey credential
- use the app

### Separation of responsibilities

- `SmartAccount`: user-local state and stable intent interpreter
- `AccountFactory`: bootstrap registry and account wiring
- `ValidatorAggregator` / `ExecutorAggregator`: developer-controlled shared module surfaces
- `PasskeyValidator`: stateless authentication validator
- passkey credential: stored in `SmartAccount`, not in shared modules

This keeps user-specific data local, while keeping operational composition in developer-controlled shared infrastructure.

## Final stable sending flow

The final stable flow separates **estimate** and **final send**.

### 1. Estimate phase

Build an estimate UserOperation for:

- `eth_estimateUserOperationGas`
- dummy passkey signature with the correct ABI shape
- paymaster in **MODE_ESTIMATE**

At this stage, the goal is to pass validation and obtain gas values safely.

### 2. Final send phase

After estimation:

- rebuild the final UserOperation
- attach final paymaster authorization
- attach the real passkey signature
- call `eth_sendUserOperation`

The final send uses **MODE_FINAL** and enforces gas risk via **caps**, rather than strict gas hashing.

### 3. Frontend-side safety check

Before sending, the frontend performs a roundtrip decode of the generated passkey signature and verifies that:

- `credHash`
- `authenticatorData`
- `clientDataJSON`
- `challengeIndex`
- `typeIndex`
- `r`
- `s`

match the expected structure.

This significantly reduced failures caused by ABI-shape mismatches before cryptographic verification.

## ContextObservatory (ERC-4337 Paymaster, owner-signed, dual execution)

We sponsor gas for **ContextObservatory** operations via an **ERC-4337 v0.7 Paymaster**, and we require an **owner signature** so that third parties cannot burn a user’s sponsored balance by submitting arbitrary UserOps.

### Sponsored actions (allowed selectors only)

- `createContext(bytes32,string)`
- `commitDeclaration(...)`
- `redeem(uint256,uint256,string,string,bytes32[])`

Both the **Paymaster** and the **Validator** enforce:

- target contract == `ContextObservatoryV0`
- inner selector is one of the three above
- laneKey matches the action lane

### laneKey naming (industry/service/process)

We treat laneKey as a DDD boundary: `industry/service/process`.

For this R&D:

- industry: `"R&D"`
- service: `"LCG"`
- process:
  - `"internal/createContext"`
  - `"internal/commitDeclaration"`
  - `"internal/redeem"`

laneKey is encoded into the **top 192 bits** of the UserOp nonce:

- `laneKey = uint192(userOp.nonce >> 64)`

Deterministic derivation:

- `id64(x) = uint64(bytes8(keccak256(bytes(x))))`
- `laneKey = pack(id64(industry), id64(service), id64(process))`

### Onchain components

- `ContextObservatoryPaymaster`: holds per-account balances and pays gas
- `PasskeyValidator`: stateless authentication validator; reads passkey credential from `SmartAccount`
- `ContextObservatoryLaneValidator`: shared lane policy validator (laneKey + selector + target)
- `ContextObservatoryExecutor`: defense-in-depth executor (target + selector)
- `ValidatorAggregator`: composes authentication + lane policy validators
- `ExecutorAggregator`: shared execution surface for lane-specific execution policies

### Validator composition

In the current design, validator aggregation is not merely "pick one validator that passes."

For a lane-specific action, validation is conceptually composed as:

- authentication validator (`PasskeyValidator`)
- lane policy validator (`ContextObservatoryLaneValidator`)

This means that both:

1. the user must be authenticated, and
2. the action must match the lane-specific policy

The aggregator therefore acts as a developer-controlled composition surface for combining authentication and per-lane policy.

### Dual execution path (both OK)

UserOp outer call can be either:

1. `executeFromEntryPoint(uint192 laneKey, address to, uint256 value, bytes innerCallData)`
2. `executeUserOp(address to, uint256 value, bytes innerCallData, uint256 fullNonce)`

For (2), laneKey is derived from `fullNonce >> 64`.  
The validator checks **laneKey consistency**:

- `uint192(fullNonce >> 64) == uint192(userOp.nonce >> 64)`

### paymasterAndData format (owner-signed)

We require owner signature in `paymasterAndData`:

- `paymasterAndData = paymasterAddress || validUntil(uint48) || validAfter(uint48) || signature`

Signature is produced by `SmartAccount.owner()` over the Paymaster’s request hash (defined in the Paymaster contract).
This prevents third parties from submitting UserOps that spend a user’s sponsored balance.

### Funding model

Two balances exist:

1. **EntryPoint deposit** (Paymaster must maintain):

- `paymaster.addDepositToEntryPoint(){value: ...}`

2. **Per-account sponsored balance** (gas budget held by paymaster):

- `paymaster.depositFor(account){value: ...}`
- charged upfront by `maxCost`, refunded in `postOp` based on actual cost

### Deploy script toggle

The deploy script can emit sample outer calldata for both paths:

- `USE_EXECUTE_USEROP=true` → emit `executeUserOp(...)` outer calldata
- default (`false`) → emit `executeFromEntryPoint(...)` outer calldata

## What made the OP Sepolia flow stable with Pimlico bundler

Several implementation fixes were necessary before the flow became stable on OP Sepolia.

### 1. Split paymaster behavior into estimate / final modes

The paymaster was split into:

- `MODE_ESTIMATE`
- `MODE_FINAL`

This was necessary because estimation and production send require different guarantees.

### 2. Removed gas fields from the final paymaster signature hash

Strictly hashing gas-related fields made signatures fragile against bundler-side differences.

Instead of strict equality on gas packing, the final flow now uses **gas caps** for bounded risk.

### 3. Enforced gas via caps

The final mode checks upper bounds for:

- verification gas
- call gas
- preVerificationGas
- priority fee
- max fee

This made authorization more robust while still keeping risk controlled.

### 4. Fixed passkey signature ABI shape

A major blocker was ABI mismatch between frontend-encoded passkey signatures and Solidity-side decoding.

The successful flow depends on using the exact ABI shape expected by the validator and keeping the estimate dummy signature aligned with the same format.

**estimate → final sign → send → execute**

flow on OP Sepolia.

### 5. Added a verificationGasLimit floor

Bundler-estimated verification gas alone was sometimes insufficient for real WebAuthn verification.

A floor was therefore applied for final send stability.

---

## Discussion points (Ethereum Magicians)

1. **Rollback / downgrade safety**
   - Who is authorized to downgrade?
   - Should downgrade be time-locked / multisig / guardian-gated?
2. **Monitoring**
   - Should aggregators emit a module-set hash for offchain monitoring?
3. **laneKey schema**
   - uint192 is compact and fast, but should laneKey be a typed-hash schema to prevent collisions?
