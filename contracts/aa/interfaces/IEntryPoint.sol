// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "./PackedUserOperation.sol";

interface IEntryPoint {
    function getUserOpHash(
        PackedUserOperation calldata userOp
    ) external view returns (bytes32);

    function depositTo(address account) external payable;

    function balanceOf(address account) external view returns (uint256);

    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external;
}
