// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutor, ModuleType} from "../../interfaces/ERC7579.sol";

/// @notice Shared, stateless executor for a specific ContextObservatory selector.
contract ContextObservatoryExecutor is IExecutor {
    error NotAllowedCall();
    error ExecFailed();

    address public immutable contextObservatory;
    bytes4 public immutable allowedSelector;

    constructor(address _contextObservatory, bytes4 _allowedSelector) {
        contextObservatory = _contextObservatory;
        allowedSelector = _allowedSelector;
    }

    function onInstall(bytes calldata) external pure override {}
    function onUninstall(bytes calldata) external pure override {}

    function isModuleType(
        uint256 typeId
    ) external pure override returns (bool) {
        return typeId == ModuleType.EXECUTOR;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory result) {
        if (target != contextObservatory) revert NotAllowedCall();
        if (data.length < 4) revert NotAllowedCall();
        if (bytes4(data[0:4]) != allowedSelector) revert NotAllowedCall();

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert ExecFailed();
        return ret;
    }
}
