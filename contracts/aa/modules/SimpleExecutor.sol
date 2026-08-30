// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IExecutor,
    IAccountExecution,
    ModuleType
} from "../interfaces/ERC7579.sol";
import {ModeLib} from "../libs/ModeLib.sol";

/// @notice General-purpose executor module with no call restrictions.
/// @dev In production, use a scoped executor (target + selector allow-list) such as
///      ContextObservatoryExecutor instead.
///
/// ERC-7579 executor pattern:
///   External caller → SimpleExecutor.executeOn(account, to, value, data)
///     → IAccountExecution(account).executeFromExecutor(mode, executionCalldata)
///     → account executes: msg.sender to target = SmartAccount (not SimpleExecutor)
contract SimpleExecutor is IExecutor {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.EXECUTOR;
    }

    /// @notice Trigger an arbitrary call on `account`.
    function executeOn(
        address account,
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes[] memory returnData) {
        bytes memory execCalldata = ModeLib.encodeSingleCalldata(
            to,
            value,
            data
        );
        return
            IAccountExecution(account).executeFromExecutor(
                ModeLib.encodeSimpleSingle(),
                execCalldata
            );
    }

    /// @notice Trigger a laneKey-scoped call on `account`.
    function executeOnWithLane(
        address account,
        uint192 laneKey,
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes[] memory returnData) {
        bytes memory execCalldata = ModeLib.encodeLaneCalldata(
            laneKey,
            to,
            value,
            data
        );
        return
            IAccountExecution(account).executeFromExecutor(
                ModeLib.encodeLaneSingle(),
                execCalldata
            );
    }
}
