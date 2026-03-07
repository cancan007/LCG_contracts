// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";

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

/// @notice Mock Passkey/WebAuthn validator for fuzzing.
/// @dev User-dependent passkey material is stored in the SmartAccount.
///      This mock only checks:
///      - challenge == userOpHash
///      - rpIdHash matches account config
///      - credentialIdHash matches account config
///      - signCount increases per sender
///
/// Signature encoding:
///   abi.encode(bytes32 challenge, bytes32 rpIdHash, bytes32 credentialIdHash, uint32 signCount)
contract PasskeyValidatorMock is IValidator {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    mapping(address => uint32) public lastSignCount;

    error NotInitialized();
    error BadSignatureFormat();

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
        (
            bytes32 expectedRpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            ,
            bytes32 expectedCredHash
        ) = IPasskeyCredentialStore(userOp.sender).getPasskeyCredential();

        if (
            expectedRpIdHash == bytes32(0) ||
            expectedCredHash == bytes32(0) ||
            pubKeyX == 0 ||
            pubKeyY == 0
        ) {
            revert NotInitialized();
        }

        if (userOp.signature.length != 32 * 4) revert BadSignatureFormat();

        (
            bytes32 challenge,
            bytes32 rpIdHash_,
            bytes32 credHash_,
            uint32 signCount
        ) = abi.decode(userOp.signature, (bytes32, bytes32, bytes32, uint32));

        if (challenge != userOpHash) return SIG_VALIDATION_FAILED;
        if (rpIdHash_ != expectedRpIdHash) return SIG_VALIDATION_FAILED;
        if (credHash_ != expectedCredHash) return SIG_VALIDATION_FAILED;

        uint32 prev = lastSignCount[userOp.sender];
        if (signCount <= prev) return SIG_VALIDATION_FAILED;

        lastSignCount[userOp.sender] = signCount;
        return 0;
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        (
            bytes32 expectedRpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            ,
            bytes32 expectedCredHash
        ) = IPasskeyCredentialStore(sender).getPasskeyCredential();

        if (
            expectedRpIdHash == bytes32(0) ||
            expectedCredHash == bytes32(0) ||
            pubKeyX == 0 ||
            pubKeyY == 0
        ) {
            return bytes4(0);
        }

        if (signature.length != 32 * 4) return bytes4(0);

        (
            bytes32 challenge,
            bytes32 rpIdHash_,
            bytes32 credHash_,
            uint32 signCount
        ) = abi.decode(signature, (bytes32, bytes32, bytes32, uint32));

        if (challenge != hash) return bytes4(0);
        if (rpIdHash_ != expectedRpIdHash) return bytes4(0);
        if (credHash_ != expectedCredHash) return bytes4(0);
        if (signCount <= lastSignCount[sender]) return bytes4(0);

        return MAGICVALUE;
    }
}
