// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal "ERC-6900-style" plugin interface (scaffold).
/// Real ERC-6900 includes manifests and more granular function selectors.
/// This keeps a simple hook-based API you can evolve.
interface IPlugin {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;

    function preExecutionHook(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) external;
    function postExecutionHook(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        bool success,
        bytes calldata ret
    ) external;
}
