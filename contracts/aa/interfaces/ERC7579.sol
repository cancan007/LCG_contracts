// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @dev Module type ids per ERC-7579:
/// 1 = Validator, 2 = Executor, 3 = Fallback, 4 = Hook
library ModuleType {
    uint256 internal constant VALIDATOR = 1;
    uint256 internal constant EXECUTOR = 2;
    uint256 internal constant FALLBACK = 3;
    uint256 internal constant HOOK = 4;
}

/// @dev ERC-7579 core module interface (minimal).
interface IModule {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;

    /// MUST return true if the module is of the given type.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

/// @dev ERC-7579 validator interface.
/// NOTE: validateUserOp is NOT view (may touch state, though SHOULD be careful).
interface IValidator is IModule {
    /// SHOULD return ERC-4337 SIG_VALIDATION_FAILED (1) on signature mismatch (and not revert).
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256);

    /// ERC-1271 forwarding helper (optional but recommended by ERC-7579).
    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4);
}

/// @dev Executor module (ERC-7579 only requires IModule; execute() is a common extension we use internally).
interface IExecutor is IModule {
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory ret);
}

/// @dev ERC-7579 hook interface (optional extension in ERC-7579).
interface IHook is IModule {
    function preCheck(
        address msgSender,
        uint256 value,
        bytes calldata msgData
    ) external returns (bytes memory hookData);

    function postCheck(bytes calldata hookData) external;
}

/// @dev Account-side module manager interface (subset).
interface IModuleManager {
    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);

    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external;

    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external;

    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata additionalContext
    ) external view returns (bool);

    function getModules(uint256 moduleTypeId) external view returns (address[] memory);
}
