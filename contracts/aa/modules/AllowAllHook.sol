// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook, ModuleType} from "../interfaces/ERC7579.sol";

/// @notice No-op hook module. Template for your own checks.
/// @dev For ExecutionHookAggregator, you'd typically install the aggregator as the lane execHook,
/// and the aggregator would call concrete hooks like this one.
contract AllowAllHook is IHook {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.HOOK;
    }

    function preCheck(
        address,
        uint256,
        bytes calldata
    ) external override returns (bytes memory) {
        return bytes("");
    }

    function postCheck(bytes calldata) external override {}
}
