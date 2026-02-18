// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "./PackedUserOperation.sol";
import {IModule} from "./ERC7579.sol";

/// @notice Validation preHook interface (view-only) invoked during validateUserOp.
/// Implementations SHOULD NOT write state.
interface IValidationHook is IModule {
    function preValidate(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        bytes calldata signature,
        bytes calldata runtimeData
    ) external view;
}
