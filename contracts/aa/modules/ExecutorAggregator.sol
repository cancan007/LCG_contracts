// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutor, IModule, ModuleType} from "../interfaces/ERC7579.sol";

contract ExecutorAggregator is IExecutor {
    error NotAccount();
    error NoExecutor();

    address public immutable account;
    address[] public executors;

    constructor(address _account) {
        account = _account;
    }

    modifier onlyAccount() {
        if (msg.sender != account) revert NotAccount();
        _;
    }

    function onInstall(bytes calldata) external override onlyAccount {}
    function onUninstall(bytes calldata) external override onlyAccount {}
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.EXECUTOR;
    }

    function addExecutor(address ex) external onlyAccount {
        executors.push(ex);
    }
    function removeExecutor(uint256 i) external onlyAccount {
        executors[i] = executors[executors.length - 1];
        executors.pop();
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory ret) {
        if (executors.length == 0) revert NoExecutor();
        return IExecutor(executors[0]).execute(to, value, data);
    }
}
