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
    function onUninstall(bytes calldata data) external;
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
