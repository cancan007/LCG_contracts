// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccount} from "./interfaces/IAccount.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";
import {IPlugin} from "./interfaces/IPlugin.sol";
import {IPluginManager} from "./interfaces/IPluginManager.sol";
import {
    ModuleType,
    IModule,
    IValidator,
    IExecutor,
    IHook,
    IModuleManager
} from "./interfaces/ERC7579.sol";

/// @notice ERC-4337 Smart Account scaffold (EntryPoint v0.7 / PackedUserOperation) with:
/// - ERC-6900-ish plugin hooks (pre/post)
/// - ERC-7579-ish module registry (validator/executor/hook)
///
/// Minimal design:
/// - A single "default validator" module is used for `validateUserOp`.
/// - Account `execute` runs plugin + hook checks.
/// - Owner installs/uninstalls plugins/modules (tighten as needed).
contract SmartAccount is IAccount, IPluginManager, IModuleManager {
    // -----------------------------
    // Errors
    // -----------------------------
    error NotEntryPoint();
    error NotOwner();
    error PluginAlreadyInstalled();
    error PluginNotInstalled();
    error ModuleAlreadyInstalled();
    error ModuleNotInstalled();
    error InvalidModuleType();
    error ValidatorNotSet();
    error ValidationFailed();

    // -----------------------------
    // Events
    // -----------------------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event EntryPointChanged(address indexed oldEP, address indexed newEP);
    event DefaultValidatorChanged(
        address indexed oldValidator,
        address indexed newValidator
    );

    // -----------------------------
    // Storage
    // -----------------------------
    address public owner;
    IEntryPoint public entryPoint;

    // ERC-6900-ish plugins
    mapping(address => bool) private _pluginInstalled;
    address[] private _plugins;

    // ERC-7579-ish modules by type
    mapping(uint256 => mapping(address => bool)) private _moduleInstalled;
    mapping(uint256 => address[]) private _modules;

    // Default validator (required for validateUserOp)
    address public defaultValidator; // implements IValidator

    // optional: default lane for backward compatibility
    uint192 internal constant DEFAULT_NONCE_KEY = 0;

    // laneKey (uint192) => sequence (uint64)
    mapping(uint192 => uint64) public nonceSequence;

    // laneKey => validator / executor
    mapping(uint192 => address) public validatorByKey;
    mapping(uint192 => address) public executorByKey;

    event LaneValidatorSet(
        uint192 indexed laneKey,
        address indexed oldValidator,
        address indexed newValidator
    );
    event LaneExecutorSet(
        uint192 indexed laneKey,
        address indexed oldExecutor,
        address indexed newExecutor
    );

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _owner,
        address _entryPoint,
        address _defaultValidator,
        bytes memory validatorInitData
    ) {
        owner = _owner;
        entryPoint = IEntryPoint(_entryPoint);

        if (_defaultValidator != address(0)) {
            _installModuleInternal(
                ModuleType.VALIDATOR,
                _defaultValidator,
                validatorInitData
            );
            defaultValidator = _defaultValidator;
        }
    }

    // -----------------------------
    // Admin
    // -----------------------------
    function setOwner(address newOwner) external onlyOwner {
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setEntryPoint(address newEntryPoint) external onlyOwner {
        emit EntryPointChanged(address(entryPoint), newEntryPoint);
        entryPoint = IEntryPoint(newEntryPoint);
    }

    function setDefaultValidator(address validator) external onlyOwner {
        if (!_moduleInstalled[ModuleType.VALIDATOR][validator])
            revert ModuleNotInstalled();
        emit DefaultValidatorChanged(defaultValidator, validator);
        defaultValidator = validator;
    }

    function setLaneValidator(
        uint192 laneKey,
        address validator
    ) external onlyOwner {
        // validatorは installed validator module であることを要求（安全）
        if (
            validator != address(0) &&
            !_moduleInstalled[ModuleType.VALIDATOR][validator]
        ) {
            revert ModuleNotInstalled();
        }
        address old = validatorByKey[laneKey];
        validatorByKey[laneKey] = validator;
        emit LaneValidatorSet(laneKey, old, validator);
    }

    function setLaneExecutor(
        uint192 laneKey,
        address executor
    ) external onlyOwner {
        if (
            executor != address(0) &&
            !_moduleInstalled[ModuleType.EXECUTOR][executor]
        ) {
            revert ModuleNotInstalled();
        }
        address old = executorByKey[laneKey];
        executorByKey[laneKey] = executor;
        emit LaneExecutorSet(laneKey, old, executor);
    }

    // -----------------------------
    // ERC-4337 v0.7: validateUserOp
    // -----------------------------
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256) {
        (uint192 laneKey, uint64 seq) = _splitNonce(userOp.nonce);

        // replay protection per lane
        if (seq != nonceSequence[laneKey]) revert ValidationFailed();
        nonceSequence[laneKey] = seq + 1;

        // pick validator for this lane (fallback to default)
        address validator = validatorByKey[laneKey];
        if (validator == address(0)) validator = defaultValidator;
        if (validator == address(0)) revert ValidatorNotSet();

        bool ok = IValidator(validator).validateUserOp(
            userOpHash,
            userOp.signature
        );
        if (!ok) revert ValidationFailed();

        if (missingAccountFunds != 0) {
            (bool sent, ) = payable(msg.sender).call{
                value: missingAccountFunds
            }("");
            if (!sent) return 1;
        }
        return 0;
    }

    // -----------------------------
    // Execution
    // -----------------------------
    function executeFromEntryPoint(
        uint192 laneKey,
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint returns (bytes memory ret) {
        // laneKeyにexecutorが設定されているなら、それに従う（レーンごとの実行制約）
        address exec = executorByKey[laneKey];
        if (exec != address(0)) {
            // 例：exec が許可するターゲット/selector等をhookやexecutor内で制約する
            // ここでは最低限「execがインストール済みである」ことを保証
            if (!_moduleInstalled[ModuleType.EXECUTOR][exec])
                revert ModuleNotInstalled();
        }

        return _executeInternal(msg.sender, to, value, data);
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory ret) {
        // owner / executor module direct path (manual)
        if (
            msg.sender != address(entryPoint) &&
            msg.sender != owner &&
            !_isExecutor(msg.sender)
        ) revert NotOwner();
        return _executeInternal(msg.sender, to, value, data);
    }

    function _executeInternal(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory) {
        _runPluginPreHooks(caller, to, value, data);
        _runHookPreChecks(caller, to, value, data);

        (bool success, bytes memory out) = to.call{value: value}(data);

        _runHookPostChecks(caller, to, value, data, success, out);
        _runPluginPostHooks(caller, to, value, data, success, out);

        if (!success) {
            assembly {
                revert(add(out, 0x20), mload(out))
            }
        }
        return out;
    }

    receive() external payable {}

    // -----------------------------
    // EntryPoint deposit helpers
    // -----------------------------
    function addDeposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawDepositTo(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // -----------------------------
    // ERC-6900-ish PluginManager
    // -----------------------------
    function installPlugin(
        address plugin,
        bytes calldata data
    ) external override onlyOwner {
        if (_pluginInstalled[plugin]) revert PluginAlreadyInstalled();
        _pluginInstalled[plugin] = true;
        _plugins.push(plugin);
        IPlugin(plugin).onInstall(data);
        emit PluginInstalled(plugin);
    }

    function uninstallPlugin(
        address plugin,
        bytes calldata data
    ) external override onlyOwner {
        if (!_pluginInstalled[plugin]) revert PluginNotInstalled();
        _pluginInstalled[plugin] = false;

        for (uint256 i = 0; i < _plugins.length; i++) {
            if (_plugins[i] == plugin) {
                _plugins[i] = _plugins[_plugins.length - 1];
                _plugins.pop();
                break;
            }
        }

        IPlugin(plugin).onUninstall(data);
        emit PluginUninstalled(plugin);
    }

    function isPluginInstalled(
        address plugin
    ) external view override returns (bool) {
        return _pluginInstalled[plugin];
    }

    function listPlugins() external view override returns (address[] memory) {
        return _plugins;
    }

    function _runPluginPreHooks(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) internal {
        for (uint256 i = 0; i < _plugins.length; i++) {
            address p = _plugins[i];
            if (_pluginInstalled[p]) {
                IPlugin(p).preExecutionHook(caller, to, value, data);
            }
        }
    }

    function _runPluginPostHooks(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        bool success,
        bytes memory ret
    ) internal {
        for (uint256 i = 0; i < _plugins.length; i++) {
            address p = _plugins[i];
            if (_pluginInstalled[p]) {
                IPlugin(p).postExecutionHook(
                    caller,
                    to,
                    value,
                    data,
                    success,
                    ret
                );
            }
        }
    }

    // -----------------------------
    // ERC-7579-ish ModuleManager
    // -----------------------------
    function installModule(
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external override onlyOwner {
        // (optional) lane-aware encoding
        // If data is (uint192 laneKey, bytes init), auto wire lane to module
        if (data.length >= 32) {
            (uint192 laneKey, bytes memory init) = abi.decode(
                data,
                (uint192, bytes)
            );
            _installModuleInternal(moduleType, module, init);

            if (moduleType == ModuleType.VALIDATOR) {
                address old = validatorByKey[laneKey];
                validatorByKey[laneKey] = module;
                emit LaneValidatorSet(laneKey, old, module);
            } else if (moduleType == ModuleType.EXECUTOR) {
                address old = executorByKey[laneKey];
                executorByKey[laneKey] = module;
                emit LaneExecutorSet(laneKey, old, module);
            }
            return;
        }

        // fallback: keep old behavior (no lane wiring)
        _installModuleInternal(moduleType, module, data);
    }

    function uninstallModule(
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external override onlyOwner {
        if (!_moduleInstalled[moduleType][module]) revert ModuleNotInstalled();
        _moduleInstalled[moduleType][module] = false;

        address[] storage arr = _modules[moduleType];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == module) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }

        IModule(module).onUninstall(data);
        emit ModuleUninstalled(moduleType, module);

        if (moduleType == ModuleType.VALIDATOR && defaultValidator == module) {
            emit DefaultValidatorChanged(defaultValidator, address(0));
            defaultValidator = address(0);
        }
    }

    function isModuleInstalled(
        uint256 moduleType,
        address module
    ) external view override returns (bool) {
        return _moduleInstalled[moduleType][module];
    }

    function getModules(
        uint256 moduleType
    ) external view override returns (address[] memory) {
        return _modules[moduleType];
    }

    function _installModuleInternal(
        uint256 moduleType,
        address module,
        bytes memory data
    ) internal {
        if (moduleType < 1 || moduleType > 4) revert InvalidModuleType();
        if (_moduleInstalled[moduleType][module])
            revert ModuleAlreadyInstalled();
        _moduleInstalled[moduleType][module] = true;
        _modules[moduleType].push(module);

        IModule(module).onInstall(data);
        emit ModuleInstalled(moduleType, module);
    }

    function _isExecutor(address maybeExecutor) internal view returns (bool) {
        return _moduleInstalled[ModuleType.EXECUTOR][maybeExecutor];
    }

    function _runHookPreChecks(
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) internal {
        address[] storage hooks = _modules[ModuleType.HOOK];
        for (uint256 i = 0; i < hooks.length; i++) {
            address h = hooks[i];
            if (_moduleInstalled[ModuleType.HOOK][h]) {
                IHook(h).preCheck(caller, to, value, data);
            }
        }
    }

    function _runHookPostChecks(
        address caller,
        address to,
        uint256 value,
        bytes calldata data,
        bool success,
        bytes memory ret
    ) internal {
        address[] storage hooks = _modules[ModuleType.HOOK];
        for (uint256 i = 0; i < hooks.length; i++) {
            address h = hooks[i];
            if (_moduleInstalled[ModuleType.HOOK][h]) {
                IHook(h).postCheck(caller, to, value, data, success, ret);
            }
        }
    }

    function _splitNonce(
        uint256 fullNonce
    ) internal pure returns (uint192 key, uint64 seq) {
        // forge-lint: disable-next-line(unsafe-typecast)
        // safe because fullNonce is packed as [uint192 key | uint64 seq]
        key = uint192(fullNonce >> 64);
        seq = uint64(fullNonce);
    }

    function _packNonce(
        uint192 key,
        uint64 seq
    ) internal pure returns (uint256) {
        return (uint256(key) << 64) | uint256(seq);
    }
}
