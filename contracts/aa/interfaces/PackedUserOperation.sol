// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice ERC-4337 v0.7-style PackedUserOperation.
/// Gas fields are packed to reduce calldata size:
/// - accountGasLimits = (verificationGasLimit << 128) | callGasLimit
/// - gasFees         = (maxPriorityFeePerGas  << 128) | maxFeePerGas
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

library PackedUserOperationLib {
    function callGasLimit(
        PackedUserOperation calldata op
    ) internal pure returns (uint256) {
        return uint256(uint128(uint256(op.accountGasLimits)));
    }

    function verificationGasLimit(
        PackedUserOperation calldata op
    ) internal pure returns (uint256) {
        return uint256(uint128(uint256(op.accountGasLimits) >> 128));
    }

    function maxFeePerGas(
        PackedUserOperation calldata op
    ) internal pure returns (uint256) {
        return uint256(uint128(uint256(op.gasFees)));
    }

    function maxPriorityFeePerGas(
        PackedUserOperation calldata op
    ) internal pure returns (uint256) {
        return uint256(uint128(uint256(op.gasFees) >> 128));
    }
}
