// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";

// webauthn-sol
import {WebAuthn} from "webauthn-sol/WebAuthn.sol";

/// @notice WebAuthn / Passkey validator (P-256 / secp256r1)
/// - Checks rpIdHash (authenticatorData[0:32]) against installed value (recommended).
/// - Uses webauthn-sol to verify:
///   - type == webauthn.get
///   - challenge == base64url(userOpHash bytes)
///   - UP bit set; UV optionally required
///   - signature (r,s) valid for pubkey (x,y)
///
/// Signature encoding:
///   userOp.signature = abi.encode(WebAuthn.WebAuthnAuth auth, bytes32 credentialIdHashOpt)
///
/// Install data:
///   abi.encode(bytes32 rpIdHash, uint256 pubKeyX, uint256 pubKeyY, bool requireUV, bytes32 credentialIdHashOpt)
contract PasskeyValidator is IValidator {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    bytes32 public rpIdHash; // expected authenticatorData[0:32]
    uint256 public pubKeyX; // P-256 pubkey X
    uint256 public pubKeyY; // P-256 pubkey Y
    bool public requireUV; // require User Verified flag
    bytes32 public credentialIdHashOpt; // optional binding (0 => ignore)

    error NotInitialized();
    error BadSignatureFormat();
    error BadAuthenticatorData();

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    function onInstall(bytes calldata data) external override {
        (
            bytes32 _rpIdHash,
            uint256 _x,
            uint256 _y,
            bool _requireUV,
            bytes32 _credHashOpt
        ) = abi.decode(data, (bytes32, uint256, uint256, bool, bytes32));

        rpIdHash = _rpIdHash;
        pubKeyX = _x;
        pubKeyY = _y;
        requireUV = _requireUV;
        credentialIdHashOpt = _credHashOpt;
    }

    function onUninstall(bytes calldata) external override {
        rpIdHash = bytes32(0);
        pubKeyX = 0;
        pubKeyY = 0;
        requireUV = false;
        credentialIdHashOpt = bytes32(0);
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        if (rpIdHash == bytes32(0) || pubKeyX == 0 || pubKeyY == 0)
            revert NotInitialized();

        // Decode signature
        if (userOp.signature.length < 32) revert BadSignatureFormat();
        (WebAuthn.WebAuthnAuth memory auth, bytes32 credHash) = abi.decode(
            userOp.signature,
            (WebAuthn.WebAuthnAuth, bytes32)
        );

        // Optional credential binding
        if (
            credentialIdHashOpt != bytes32(0) && credHash != credentialIdHashOpt
        ) {
            return SIG_VALIDATION_FAILED;
        }

        // Basic authenticatorData sanity & rpIdHash binding
        // authenticatorData = rpIdHash(32) || flags(1) || signCount(4) || ...
        bytes memory ad = auth.authenticatorData;
        if (auth.authenticatorData.length < 37) revert BadAuthenticatorData();

        bytes32 gotRp;
        assembly {
            // load first 32 bytes of auth.authenticatorData
            gotRp := mload(add(ad, 32))
        }
        if (gotRp != rpIdHash) return SIG_VALIDATION_FAILED;

        // WebAuthn.verify expects the raw challenge bytes.
        // We bind challenge to the exact UserOp via userOpHash (32 bytes).
        bool ok = WebAuthn.verify(
            abi.encode(userOpHash),
            requireUV,
            auth,
            pubKeyX,
            pubKeyY
        );

        return ok ? 0 : SIG_VALIDATION_FAILED;
    }

    function isValidSignatureWithSender(
        address,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        if (rpIdHash == bytes32(0) || pubKeyX == 0 || pubKeyY == 0)
            return bytes4(0);

        (WebAuthn.WebAuthnAuth memory auth, bytes32 credHash) = abi.decode(
            signature,
            (WebAuthn.WebAuthnAuth, bytes32)
        );

        if (
            credentialIdHashOpt != bytes32(0) && credHash != credentialIdHashOpt
        ) {
            return bytes4(0);
        }

        bytes memory ad = auth.authenticatorData;
        if (auth.authenticatorData.length < 37) return bytes4(0);
        bytes32 gotRp;
        assembly {
            gotRp := mload(add(ad, 32))
        }
        if (gotRp != rpIdHash) return bytes4(0);

        bool ok = WebAuthn.verify(
            abi.encode(hash),
            requireUV,
            auth,
            pubKeyX,
            pubKeyY
        );

        return ok ? MAGICVALUE : bytes4(0);
    }
}
