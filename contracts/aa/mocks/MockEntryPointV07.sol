// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";

/// @notice Minimal EntryPoint-like mock for tests.
/// Only implements `getUserOpHash` and deposit bookkeeping used by the SmartAccount scaffold.
contract MockEntryPointV07 {
    mapping(address => uint256) private _deposit;

    function getUserOpHash(
        PackedUserOperation calldata userOp
    ) external view returns (bytes32) {
        // NOTE: This is a simplified hash for tests, not canonical EntryPoint logic.
        // Canonical logic includes chain id, this address, and packing rules.
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    userOp.sender,
                    userOp.nonce,
                    keccak256(userOp.initCode),
                    keccak256(userOp.callData),
                    userOp.accountGasLimits,
                    userOp.preVerificationGas,
                    userOp.gasFees,
                    keccak256(userOp.paymasterAndData)
                )
            );
    }

    function depositTo(address account) external payable {
        _deposit[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _deposit[account];
    }

    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external {
        // For tests: allow the caller to withdraw their own tracked deposit.
        address caller = msg.sender;
        require(_deposit[caller] >= amount, "insufficient");
        _deposit[caller] -= amount;
        (bool ok, ) = withdrawAddress.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {}
}
