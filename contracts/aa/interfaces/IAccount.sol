// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "./PackedUserOperation.sol";

interface IAccount {
    /// @notice Validate user's signature and pay prefund if needed.
    /// @dev Must return 0 for success, or a failure code (per 4337 conventions).
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}
