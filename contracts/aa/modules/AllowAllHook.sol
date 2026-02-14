// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/ERC7579.sol";

/// @notice No-op hook module. Template for your own checks.
contract AllowAllHook is IHook {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function preCheck(
        address,
        address,
        uint256,
        bytes calldata
    ) external override {}
    function postCheck(
        address,
        address,
        uint256,
        bytes calldata,
        bool,
        bytes calldata
    ) external override {}
}
