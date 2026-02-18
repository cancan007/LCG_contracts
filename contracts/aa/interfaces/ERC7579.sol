// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ModuleType {
    uint256 internal constant VALIDATOR = 1;
    uint256 internal constant EXECUTOR = 2;
    uint256 internal constant HOOK = 3;
    uint256 internal constant FALLBACK = 4;
}

interface IModule {
    function onInstall(bytes calldata data) external;

    /**
     * @dev This function is called by the smart account during uninstallation of the module
     * @param data arbitrary data that may be required on the module during `onUninstall` de-initialization
     *
     * MUST revert on error
     */
    function onUninstall(bytes calldata data) external;

    /**
     * @dev Returns boolean value if module is a certain type
     * @param moduleTypeId the module type ID according the ERC-7579 spec
     *
     * MUST return true if the module is of the given type and false otherwise
     */
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

interface IValidator is IModule {
    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view returns (bool);
}

interface IExecutor is IModule {
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory ret);
}

interface IHook is IModule {
    function preCheck(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) external;
    function postCheck(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        bool success,
        bytes calldata ret
    ) external;
}

interface IModuleManager {
    event ModuleInstalled(uint256 indexed moduleType, address indexed module);
    event ModuleUninstalled(uint256 indexed moduleType, address indexed module);

    function installModule(
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external;
    function uninstallModule(
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external;
    function isModuleInstalled(
        uint256 moduleType,
        address module
    ) external view returns (bool);
    function getModules(
        uint256 moduleType
    ) external view returns (address[] memory);
}
