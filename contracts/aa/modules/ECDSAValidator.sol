// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator} from "../interfaces/ERC7579.sol";
import {ECDSA} from "../libs/ECDSA.sol";

/// @notice Simple ECDSA validator module (ERC-7579-style).
/// Stores an `owner` address for signature validation.
///
/// Install data: abi.encode(address owner)
contract ECDSAValidator is IValidator {
    using ECDSA for bytes32;

    address public owner;

    error NotInitialized();

    function onInstall(bytes calldata data) external override {
        owner = abi.decode(data, (address));
    }

    function onUninstall(bytes calldata) external override {
        owner = address(0);
    }

    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view override returns (bool) {
        address _owner = owner;
        if (_owner == address(0)) revert NotInitialized();

        // Many 4337 clients sign userOpHash directly (not personal_sign).
        // If your client uses personal_sign, validate against toEthSignedMessageHash(userOpHash).
        address signer = ECDSA.recover(userOpHash, signature);
        return signer == _owner;
    }
}
