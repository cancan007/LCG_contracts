// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {ECDSA} from "../libs/ECDSA.sol";

/// @notice Simple ECDSA validator module (ERC-7579-style).
/// Stores an `owner` address for signature validation.
/// Install data: abi.encode(address owner)
contract ECDSAValidator is IValidator {
    using ECDSA for bytes32;

    // ERC-4337 constant
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    // ERC-1271 magic value
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    address public owner;

    error NotInitialized();

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    function onInstall(bytes calldata data) external override {
        owner = abi.decode(data, (address));
    }

    function onUninstall(bytes calldata) external override {
        owner = address(0);
    }

    /// @dev Returns 0 on success, SIG_VALIDATION_FAILED (1) on signature mismatch.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        address _owner = owner;
        if (_owner == address(0)) revert NotInitialized();

        address recovered = userOpHash.recover(userOp.signature);
        return recovered == _owner ? 0 : SIG_VALIDATION_FAILED;
    }

    function isValidSignatureWithSender(
        address /*sender*/,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        address _owner = owner;
        if (_owner == address(0)) return bytes4(0);

        address recovered = hash.recover(signature);
        return recovered == _owner ? MAGICVALUE : bytes4(0);
    }
}
