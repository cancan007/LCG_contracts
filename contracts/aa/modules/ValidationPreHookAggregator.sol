// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {IValidationHook} from "../interfaces/IValidationHook.sol";
import {ModuleType} from "../interfaces/ERC7579.sol";

contract ValidationPreHookAggregator is IValidationHook {
    error NotAccount();
    error Disabled();

    address public immutable account;
    bool public enabled = true;

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

    function setEnabled(bool v) external onlyAccount {
        enabled = v;
    }

    function preValidate(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        bytes calldata signature,
        bytes calldata runtimeData
    ) external view override {
        if (!enabled) revert Disabled();

        // 初期は “拡張性だけ担保” なので何もしなくてOK。
        // 将来ここに runtime/signature/userOp の検証を入れる。
        // 例: require(signature.length > 0, "empty sig");
        (userOp, userOpHash, signature, runtimeData); // silence warnings
    }
}
