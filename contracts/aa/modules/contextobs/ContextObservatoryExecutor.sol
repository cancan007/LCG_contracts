// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutor, IModule} from "../../interfaces/ERC7579.sol";

/// @notice Defense-in-depth executor: only allows a single target + selector.
contract ContextObservatoryExecutor is IExecutor {
    error NotInstalled();
    error NotAllowedCall();

    bool public installed;
    address public smartAccount;
    address public contextObservatory;
    bytes4 public allowedSelector;

    function onInstall(bytes calldata data) external override {
        (contextObservatory, allowedSelector) = abi.decode(
            data,
            (address, bytes4)
        );
        installed = true;
        smartAccount = msg.sender;
    }

    function onUninstall(bytes calldata) external override {
        installed = false;
    }

    function isModuleType(uint256 typeId) external pure returns (bool) {
        // ModuleType.EXECUTOR == 2 in your ERC7579.sol
        return typeId == 2;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory result) {
        if (!installed || msg.sender != smartAccount) revert NotInstalled();
        if (target != contextObservatory) revert NotAllowedCall();
        if (data.length < 4) revert NotAllowedCall();
        if (bytes4(data[0:4]) != allowedSelector) revert NotAllowedCall();

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "exec failed");
        return ret;
    }
}
