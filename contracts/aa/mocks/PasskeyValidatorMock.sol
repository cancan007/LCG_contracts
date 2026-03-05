// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";

/// @notice A *mock* Passkey/WebAuthn validator for fuzzing.
///
/// Why mock?
/// - Real Passkeys usually sign with P-256 (secp256r1) and require WebAuthn parsing.
/// - This repository doesn't include a secp256r1 verifier (e.g., RIP-7212 precompile),
///   and Foundry doesn't provide a built-in P-256 signing cheatcode.
///
/// What this mock tests (the important AA security properties):
/// - The "challenge" is bound to the action: challenge MUST equal userOpHash.
/// - The credential is domain scoped: rpIdHash MUST match what was installed.
/// - Replay resistance at the authenticator layer: signCount must monotonically increase.
///
/// Signature encoding (abi.encode):
///   (bytes32 challenge, bytes32 rpIdHash, bytes32 credentialIdHash, uint32 signCount)
contract PasskeyValidatorMock is IValidator {
    // ERC-4337 constant
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    // ERC-1271 magic value
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    bytes32 public rpIdHash;
    bytes32 public credentialIdHash;
    uint32 public lastSignCount;

    error NotInitialized();
    error BadSignatureFormat();

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    /// @dev Install data: abi.encode(bytes32 rpIdHash, bytes32 credentialIdHash)
    function onInstall(bytes calldata data) external override {
        (rpIdHash, credentialIdHash) = abi.decode(data, (bytes32, bytes32));
        lastSignCount = 0;
    }

    function onUninstall(bytes calldata) external override {
        rpIdHash = bytes32(0);
        credentialIdHash = bytes32(0);
        lastSignCount = 0;
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        if (rpIdHash == bytes32(0) || credentialIdHash == bytes32(0)) {
            revert NotInitialized();
        }

        // signature must be exactly 4 words (abi.encode of 4 values)
        if (userOp.signature.length != 32 * 4) revert BadSignatureFormat();

        (
            bytes32 challenge,
            bytes32 _rpIdHash,
            bytes32 _credHash,
            uint32 signCount
        ) = abi.decode(userOp.signature, (bytes32, bytes32, bytes32, uint32));

        // Bind approval to the exact action (callData, nonce, fees, etc.) via userOpHash
        if (challenge != userOpHash) return SIG_VALIDATION_FAILED;

        // Domain scoping (origin/RP binding)
        if (_rpIdHash != rpIdHash) return SIG_VALIDATION_FAILED;

        // Credential binding
        if (_credHash != credentialIdHash) return SIG_VALIDATION_FAILED;

        // Authenticator replay resistance
        if (signCount <= lastSignCount) return SIG_VALIDATION_FAILED;
        lastSignCount = signCount;

        return 0;
    }

    function isValidSignatureWithSender(
        address /*sender*/,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        if (rpIdHash == bytes32(0) || credentialIdHash == bytes32(0)) {
            return bytes4(0);
        }
        if (signature.length != 32 * 4) return bytes4(0);

        (
            bytes32 challenge,
            bytes32 _rpIdHash,
            bytes32 _credHash,
            uint32 signCount
        ) = abi.decode(signature, (bytes32, bytes32, bytes32, uint32));

        if (challenge != hash) return bytes4(0);
        if (_rpIdHash != rpIdHash) return bytes4(0);
        if (_credHash != credentialIdHash) return bytes4(0);

        // For ERC-1271 view checks, we don't update lastSignCount.
        // We still enforce strictly-increasing vs stored count to discourage reuse.
        if (signCount <= lastSignCount) return bytes4(0);

        return MAGICVALUE;
    }
}
