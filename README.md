# Context Observatory

_A Modular Account Abstraction Experiment for Contextual Economics_

---

## Overview

This repository implements a smart contract system designed to explore a fundamental hypothesis:

> **Future liquidity will manifest not as price, but as the movement of meaning.**  
> Web3 can serve as an experimental field where this “movement of meaning” is observable as timestamped commitments on-chain.

This DApp is not merely a token mechanism.  
It is an experiment in modeling economic state as structured contextual commitments.

---

## Core Thesis

### Liquidity as the Movement of Meaning

Traditional liquidity is measured through price and numerical abstraction.

We propose:

- Economic activity can be understood as the accumulation and evolution of contextual commitments.
- Meaning moves across space, time, and interpretive granularity.
- Web3 infrastructure allows these movements to be recorded as immutable, chronological logs.

In this model:

- **NBNP is not value itself.**
- It is a log of expectation before value emerges.
- Once value stabilizes, NBNP becomes commemorative.
- The center of gravity shifts from token quantity to contextual aggregation.

> Economic state can be modeled as structured contextual commitments across space, time, and interpretive granularity.

---

## Contextual Modeling Dimensions

The DApp structures meaning through:

### Spatial Scope

- `self`
- `individual`
- `organization`
- `public`

### Temporal Scope

- `past`
- `future`
- `timeless`

### Interpretive Granularity

- `summary`
- `story`
- `counterexample`

Economic trajectory emerges from:

- Mutual relational commitments
- Contextual declarations
- Referential interpretations
- Time-bounded participation

Value is abstracted from absolute numerical indicators into contextual trace.

---

# Account Abstraction Architecture

This project also explores a **modular AA architecture** for L3-oriented UX ecosystems.

![current AA whole image](./images/self-analysis/intent_aa_sa_design_image.png)

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
:contentReference[oaicite:2]{index=2}

---

## Stable Execution Phases (protocol-fixed)

Execution phases are intentionally kept stable:

- **Validation Phase**: optional `preHook` (0 or 1)
- **Execution Phase**: fixed `preHook` → `executor` → fixed `postHook`

In other words, the **hook invocation timing is protocol-defined**, while domain flexibility is delegated to modules.

---

## laneKey as Domain Boundary (DDD-aligned)

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
:contentReference[oaicite:3]{index=3}

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
