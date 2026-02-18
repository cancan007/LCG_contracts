// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IValidator, IModule, ModuleType} from "../interfaces/ERC7579.sol";

contract ValidatorAggregator is IValidator {
    error NotAccount();
    error NoValidator();

    address public immutable account;
    address[] public validators;

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
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    function addValidator(address v) external onlyAccount {
        validators.push(v);
    }
    function removeValidator(uint256 i) external onlyAccount {
        validators[i] = validators[validators.length - 1];
        validators.pop();
    }

    function _pick(bytes calldata signature) internal view returns (address v) {
        if (validators.length == 0) revert NoValidator();
        uint8 idx = uint8(signature[0]) % uint8(validators.length);
        v = validators[idx];
    }

    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view override returns (bool) {
        address v = _pick(signature);
        return IValidator(v).validateUserOp(userOpHash, signature);
    }
}
