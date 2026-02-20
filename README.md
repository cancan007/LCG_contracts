# aa_aggregators

This repository contains **two tracks** that share a common theme: making “context” and “intent” composable onchain — but they are intentionally separated so each can be discussed clearly.

1. **AA Aggregators (Account Abstraction, ops-first)**
   - laneKey-partitioned intent routing
   - deterministic validation/execution phases
   - aggregators as the fixed integration surface between SmartAccount and modules
   - **versioned module sets** for maintainable upgrades/rollback (operations & maintenance)

2. **Context Observatory (R&D)**
   - an experimental contract to record “declarations” as canonical commitments
   - epoch-finalized Merkle distribution to mint an external AuthorContextNFT
   - explores a thesis about “meaning movement” as economic state

---

## Quick links

- **AA / Ethereum Magicians discussion**: `README_AA.md`
- **R&D (Context Observatory)**: `README_RND.md`

---

## AA overview (one diagram)

![](./images/self-analysis/intent_aa_sa_design_image.png)

---

## Why this repo exists (short)

AA systems that are UX-heavy / L3-oriented tend to become “blurry”: validation logic becomes domain-dependent, hook timing gets ad-hoc, and upgrades become hard to operate safely.

This repo proposes a simple stance:

- keep SmartAccount stable,
- fix phase touchpoints,
- route by laneKey,
- evolve via modules,
- and manage change via **version tags** on aggregators.

---

## Status

Prototype / R&D. Feedback welcome.
