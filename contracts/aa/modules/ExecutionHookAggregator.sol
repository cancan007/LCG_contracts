// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook, IModule, ModuleType} from "../interfaces/ERC7579.sol";

/// @notice Execution Hook Aggregator:
/// - implements a single IHook for the SmartAccount
/// - internally fans out to N preHooks and N postHooks (both lists are optional)
///
/// This keeps SmartAccount's hook call sites fixed (pre + post),
/// while allowing the app/service to iterate on hook logic by managing subhooks.
contract ExecutionHookAggregator is IHook {
    error NotAccount();
    error AlreadyInstalled();
    error NotInstalled();

    address public immutable account;

    address[] public preHooks;
    mapping(address => bool) public preHookInstalled;

    address[] public postHooks;
    mapping(address => bool) public postHookInstalled;

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
        return moduleTypeId == ModuleType.HOOK;
    }

    function addPreHook(address hook) external onlyAccount {
        if (preHookInstalled[hook]) revert AlreadyInstalled();
        preHookInstalled[hook] = true;
        preHooks.push(hook);
    }

    function removePreHook(address hook) external onlyAccount {
        if (!preHookInstalled[hook]) revert NotInstalled();
        preHookInstalled[hook] = false;

        for (uint256 i = 0; i < preHooks.length; i++) {
            if (preHooks[i] == hook) {
                preHooks[i] = preHooks[preHooks.length - 1];
                preHooks.pop();
                break;
            }
        }
    }

    function addPostHook(address hook) external onlyAccount {
        if (postHookInstalled[hook]) revert AlreadyInstalled();
        postHookInstalled[hook] = true;
        postHooks.push(hook);
    }

    function removePostHook(address hook) external onlyAccount {
        if (!postHookInstalled[hook]) revert NotInstalled();
        postHookInstalled[hook] = false;

        for (uint256 i = 0; i < postHooks.length; i++) {
            if (postHooks[i] == hook) {
                postHooks[i] = postHooks[postHooks.length - 1];
                postHooks.pop();
                break;
            }
        }
    }

    function preCheck(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) external override {
        // called by SmartAccount; we still accept external calls but they won't pass onlyAccount in subhooks if enforced
        for (uint256 i = 0; i < preHooks.length; i++) {
            address h = preHooks[i];
            if (preHookInstalled[h]) {
                IHook(h).preCheck(caller, to, value, data);
            }
        }
    }

    function postCheck(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        bool success,
        bytes calldata ret
    ) external override {
        for (uint256 i = 0; i < postHooks.length; i++) {
            address h = postHooks[i];
            if (postHookInstalled[h]) {
                IHook(h).postCheck(caller, to, value, data, success, ret);
            }
        }
    }
}
