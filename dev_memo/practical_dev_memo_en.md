# Account Abstraction + Paymaster + Passkey Implementation Memo

## Overview

This memo documents the implementation and debugging process for an AA flow on OP Sepolia using the following components:

- Smart Account
- laneKey-based validator aggregator
- PasskeyValidator
- ContextObservatoryLaneValidator
- ContextObservatoryPaymaster
- Pimlico bundler
- EntryPoint v0.7

The final result was a working flow for:

**estimate → final sign → send**

---

## Final Stable Sending Flow

### 1. Build an estimate UserOperation

The estimate-phase UserOperation is separated from the final send-phase UserOperation.

For estimate:

- paymaster uses **MODE_ESTIMATE**
- passkey signature is a **dummy signature with correct ABI shape**
- prefund is covered by the paymaster
- strict final authorization is not required at this step

### 2. Run bundler gas estimation

Call:

`eth_estimateUserOperationGas`

This yields:

- `callGasLimit`
- `verificationGasLimit`
- `preVerificationGas`

### 3. Build the final UserOperation

For final send:

- paymaster uses **MODE_FINAL**
- paymasterData contains **final authorization**
- gas values are **not hashed**, but enforced via **caps**
- a real passkey signature is attached at the end

### 4. Perform roundtrip decode before send

Before sending, decode the generated passkey signature on the frontend and verify that it matches expectations.

Check:

- `credHash`
- `authenticatorData`
- `clientDataJSON`
- `challengeIndex`
- `typeIndex`
- `r`
- `s`

### 5. Call `eth_sendUserOperation`

This is the final send step.

---

# Main Fixes

## 1. Split paymaster logic into 2 modes

### Added modes

- `MODE_ESTIMATE`
- `MODE_FINAL`

### Reason

Estimate and final send have different requirements, so responsibilities were separated.

#### MODE_ESTIMATE

- used only to pass gas estimation
- handles prefund
- does not need postOp
- returns empty context

#### MODE_FINAL

- used for production send
- enforces paymaster authorization
- validates gas using caps
- may use postOp if needed

---

## 2. Removed gas fields from final paymaster signature hash

### Previous problem

`reqHash` included:

- `accountGasLimits`
- `preVerificationGas`
- `gasFees`

This made signatures fragile against bundler-side packing and gas interpretation differences.

### After fix

Final signature hash only includes:

- `chainId`
- `address(this)`
- `sender`
- `nonce`
- `keccak256(callData)`
- `validUntil`
- `validAfter`

### How gas is handled now

Gas fields are no longer part of the signature hash.  
They are enforced separately via **caps**.

---

## 3. Manage gas via caps

In final mode, the following values are stored as caps inside paymasterData:

- `maxVerificationGas`
- `maxCallGas`
- `maxPreVerificationGas`
- `maxMaxPriorityFeePerGas`
- `maxMaxFeePerGas`

Onchain checks:

- `verificationGasLimit <= maxVerificationGas`
- `callGasLimit <= maxCallGas`
- `preVerificationGas <= maxPreVerificationGas`
- `maxPriorityFeePerGas <= maxMaxPriorityFeePerGas`
- `maxFeePerGas <= maxMaxFeePerGas`

This avoids strict gas equality while still keeping risk bounded.

---

## 4. Fixed passkey signature ABI shape

### Problem

The frontend-generated signature ABI shape did not match Solidity-side decode:

```solidity
abi.decode(userOp.signature, (WebAuthn.WebAuthnAuth, bytes32))
```

This caused:

- `AA23 reverted 0x`
- `AA24 signature error`
- `panic: memory allocation error (0x41)`

### Fixed ABI

The frontend was unified to:

```ts
"(bytes authenticatorData,string clientDataJSON,uint256 challengeIndex,uint256 typeIndex,bytes32 r,bytes32 s),bytes32";
```

### Important rule

- do not wrap it as ((...),bytes32)
- match Solidity decode exactly

---

## 5. Dummy signature was aligned to the same ABI

The estimate-phase dummy signature was also changed to use the exact same ABI shape as the real signature.

Important points:

empty signature is not acceptable

it must be ABI-decodable and well-formed

This prevented unnecessary account validation reverts during estimation.

---

## 6. Added a floor to verificationGasLimit

### Problem

Using the bundler-estimated verificationGasLimit directly in final send was insufficient for real WebAuthn verification, causing:

- AA26 over verificationGasLimit

### Fix

A floor was added to verificationGasLimit for final send.
In this case, setting it back to 0xc3500 made the flow succeed.

---

## 7. Fixed postOp to match EntryPoint v0.7

### Problem

Execution phase reverted inside postOp.

The most likely root cause was that the paymaster’s postOp signature did not match EntryPoint v0.7.

### Fix

It was updated to the correct 4-argument v0.7 version.

---

## Main Errors Encountered and Their Meanings

`AA33 reverted`

Cause:

- paymaster signature hash included gas-related fields
- bundler-side differences caused signature mismatch

Fix:

- removed gas fields from final hash
- switched to gas cap enforcement

---

`AA21 didn't pay prefund`

Cause:

- paymaster was completely removed during estimate
- sender could not prefund

Fix:

- keep paymaster active in estimate via MODE_ESTIMATE

---

`AA23 reverted 0x`

Cause:

- dummy signature was not ABI-decodable
- account validator reverted

Fix:

- introduced well-formed dummy signature
- aligned ABI shape with the real signature

---

`AA24 signature error`

Cause:

- passkey signature ABI shape did not match Solidity decode

Fix:

- corrected signature ABI
- added roundtrip decode before send

---

`AA26 over verificationGasLimit`

Cause:

- final verificationGasLimit was too low

Fix:

- added a floor to final verification gas

---

`AA50 postOp reverted`

Cause:

- estimate/final context/postOp path
- ultimately tied to postOp implementation issues

Fix:

- returned empty context in estimate mode
- aligned postOp with EntryPoint v0.7

---

## Useful Debugging Techniques

### 1. Onchain debug helpers

Paymaster-side debug checks included:

- mode
- reqHash
- signer
- recovered
- allowedCall
- enoughBalance
- gasCapsOk

Note: debug mode parsing remained partially out of sync and was useful only as a secondary aid.

---

## 2. Final signature roundtrip decode

This turned out to be one of the most important checks.

Before sending:

- encode the passkey signature
- decode it immediately on the frontend

Verify:

- decodedCredHash
- decoded.authenticatorData
- decoded.clientDataJSON
- decoded.challengeIndex
- decoded.typeIndex
- decoded.r
- decoded.s

---

### 3. Replay tests

Foundry replay tests helped isolate:

- the core issue was not the paymaster
- the root issue was not the laneValidator
- the real blocker was passkey signature shape / ABI mismatch
- panic(0x41) came from ABI shape problems

## Implementation Lessons

### 1. Separate estimate from final

With AA + paymaster + passkey, estimate and final send should not be treated identically.

### 2. Avoid strict gas hashing in paymaster auth

Gas-related fields are better enforced with caps than by strict signature hashing.

### 3. WebAuthn/passkey signatures depend heavily on ABI shape

Failures can happen before cryptographic verification if ABI shape is wrong.
Always verify that decode roundtrip works first.

### 4. postOp must match the EntryPoint version

If the paymaster’s postOp signature does not match the EntryPoint version, execution phase can fail.

---

## Current Success Conditions

The flow succeeded under the following conditions:

- estimate paymasterData uses MODE_ESTIMATE
- final paymasterData uses MODE_FINAL
- final gas is enforced via caps
- passkey signature ABI matches Solidity decode exactly
- roundtrip decode before final send succeeds
- verificationGasLimit has a floor
- postOp matches EntryPoint v0.7

---

## Future Improvements

### High priority

- fix paymaster debug function mode/parse mismatch
- save successful fixtures permanently
- turn the successful final payload into replay tests

### Medium priority

- optimize gas floors
- test postOp refund logic
- improve lane validator / passkey validator debug helpers

### Low priority

- clean up paymaster debug output
- organize revert selector notes from Tenderly traces

---

## Artifacts Worth Saving

- final successful ContextObservatoryPaymaster.sol
- final successful sendUserOp.ts
- final successful passkeyAssertion.ts
- successful finalRpcUserOp
- successful finalUserOpHash
- successful replay fixture JSON
