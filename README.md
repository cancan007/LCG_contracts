# LCG Context Observatory v0

Minimal prototype with **Foundry** tests and **Echidna** harness.

## Leaf spec

The epoch distribution is committed as a Merkle root where each leaf is:

```
leaf = keccak256(abi.encode(epochId, user, tokenId, metadataContentHash))
metadataContentHash = keccak256(bytes(metadataJsonCanonical))
```

`metadataJsonCanonical` must be a canonical JSON string (sorted keys, no extra whitespace). The provided TypeScript script canonicalizes a JSON object for you.

## Quickstart (Foundry)

```bash
# install deps
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# run tests
forge test -vvv
```

## Merkle builder (TypeScript)

The script reads `airdrop/epoch-1.json` and outputs `airdrop/epoch-1.proofs.json`.

```bash
npm i ethers merkletreejs keccak256 ts-node typescript @types/node
npx ts-node scripts/build-merkle.ts airdrop/epoch-1.json airdrop/epoch-1.proofs.json
```

## Echidna (Docker)

```bash
./scripts/run-echidna-docker.sh
```

The harness is `echidna/ContextObservatoryEchidnaHarness.sol` and checks:
- Redeem cannot be claimed twice for the same leaf
- Minted NFT stores the expected `metadataContentHash`
