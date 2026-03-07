// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";

// webauthn-sol
import {WebAuthn} from "webauthn-sol/WebAuthn.sol";

interface IPasskeyCredentialStore {
    function getPasskeyCredential()
        external
        view
        returns (
            bytes32 rpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            bool requireUV,
            bytes32 credentialIdHashOpt
        );
}

/// @notice WebAuthn / Passkey validator (P-256 / secp256r1)
/// @dev This module is intentionally stateless. User-dependent passkey material is
///      stored in the SmartAccount and read via `sender` / `userOp.sender`.
/// Signature encoding:
///   userOp.signature = abi.encode(WebAuthn.WebAuthnAuth auth, bytes32 credentialIdHashOpt)
contract PasskeyValidator is IValidator {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    error NotInitialized();
    error BadSignatureFormat();
    error BadAuthenticatorData();

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    function onInstall(bytes calldata) external pure override {}

    function onUninstall(bytes calldata) external pure override {}

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        return
            _validate(userOp.sender, userOpHash, userOp.signature, true)
                ? 0
                : SIG_VALIDATION_FAILED;
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        return
            _validate(sender, hash, signature, false) ? MAGICVALUE : bytes4(0);
    }

    function _validate(
        address sender,
        bytes32 hashOrUserOpHash,
        bytes calldata signature,
        bool revertOnFormat
    ) internal view returns (bool) {
        (
            bytes32 rpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            bool requireUV,
            bytes32 credentialIdHashOpt
        ) = IPasskeyCredentialStore(sender).getPasskeyCredential();

        if (rpIdHash == bytes32(0) || pubKeyX == 0 || pubKeyY == 0) {
            if (revertOnFormat) revert NotInitialized();
            return false;
        }

        if (signature.length < 32) {
            if (revertOnFormat) revert BadSignatureFormat();
            return false;
        }

        (WebAuthn.WebAuthnAuth memory auth, bytes32 credHash) = abi.decode(
            signature,
            (WebAuthn.WebAuthnAuth, bytes32)
        );

        if (
            credentialIdHashOpt != bytes32(0) && credHash != credentialIdHashOpt
        ) {
            return false;
        }

        if (auth.authenticatorData.length < 37) {
            if (revertOnFormat) revert BadAuthenticatorData();
            return false;
        }

        bytes32 gotRp;
        bytes memory ad = auth.authenticatorData;
        assembly {
            gotRp := mload(add(ad, 32))
        }
        if (gotRp != rpIdHash) return false;

        return
            WebAuthn.verify(
                abi.encode(hashOrUserOpHash),
                requireUV,
                auth,
                pubKeyX,
                pubKeyY
            );
    }
}
