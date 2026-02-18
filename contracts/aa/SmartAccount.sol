// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccount} from "./interfaces/IAccount.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

import {
    ModuleType,
    IModule,
    IValidator,
    IExecutor,
    IHook,
    IModuleManager
} from "./interfaces/ERC7579.sol";

import {IValidationHook} from "./interfaces/IValidationHook.sol";
import {LaneKeyLib} from "./libs/LaneKeyLib.sol";

/// @notice ERC-4337 Smart Account scaffold (EntryPoint v0.7 / PackedUserOperation) with:
/// - ERC-7579-ish module registry (validator/executor/hook)
/// - laneKey-based LaneConfig (domain context)
/// - Optional validation preHook (IValidationHook) per lane (recommend: ValidationPreHookAggregator)
/// - Fixed execution hooks: pre+post via ONE IHook per lane (recommend: ExecutionHookAggregator)
///
/// Manual execute() lane selection:
/// - raw:        data = innerCallData             -> laneKey = 0
/// - wrapped:    data = abi.encode(uint192, bytes)-> laneKey = provided
contract SmartAccount is IAccount, IModuleManager {
    using LaneKeyLib for uint192;

    // -----------------------------
    // Errors
    // -----------------------------
    error NotEntryPoint();
    error NotOwner();
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

    event LaneConfigSet(
        uint192 indexed laneKey,
        address validator,
        address validationHook,
        address executor,
        address execHook
    );

    // -----------------------------
    // Storage
    // -----------------------------
    address public owner;
    IEntryPoint public entryPoint;

    // ERC-7579-ish modules by type
    mapping(uint256 => mapping(address => bool)) private _moduleInstalled;
    mapping(uint256 => address[]) private _modules;

    // Default validator (fallback if lane config has no validator)
    address public defaultValidator; // IValidator

    // laneKey (uint192) => sequence (uint64)
    mapping(uint192 => uint64) public nonceSequence;

    struct LaneConfig {
        address validator; // IValidator
        address validationHook; // IValidationHook (registered under ModuleType.HOOK)
        address executor; // IExecutor (optional)
        address execHook; // IHook (ONE per lane; recommended: ExecutionHookAggregator)
    }

    mapping(uint192 => LaneConfig) internal laneConfig;

    // -----------------------------
    // Modifiers
    // -----------------------------
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

    /// @notice laneKeyごとの構成をまとめて設定（laneKey=0 を “デフォルトレーン” として運用する想定）
    function setLaneConfig(
        uint192 laneKey,
        address validator,
        address validationHook,
        address executor,
        address execHook
    ) external onlyOwner {
        if (
            validator != address(0) &&
            !_moduleInstalled[ModuleType.VALIDATOR][validator]
        ) revert ModuleNotInstalled();
        if (
            executor != address(0) &&
            !_moduleInstalled[ModuleType.EXECUTOR][executor]
        ) revert ModuleNotInstalled();
        if (
            validationHook != address(0) &&
            !_moduleInstalled[ModuleType.HOOK][validationHook]
        ) revert ModuleNotInstalled();
        if (
            execHook != address(0) &&
            !_moduleInstalled[ModuleType.HOOK][execHook]
        ) revert ModuleNotInstalled();

        laneConfig[laneKey] = LaneConfig({
            validator: validator,
            validationHook: validationHook,
            executor: executor,
            execHook: execHook
        });

        emit LaneConfigSet(
            laneKey,
            validator,
            validationHook,
            executor,
            execHook
        );
    }

    function getLaneConfig(
        uint192 laneKey
    ) external view returns (LaneConfig memory) {
        return laneConfig[laneKey];
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

        LaneConfig memory cfg = _laneOrDefault(laneKey);

        // optional validation preHook (view-only checks)
        if (cfg.validationHook != address(0)) {
            IValidationHook(cfg.validationHook).preValidate(
                userOp,
                userOpHash,
                userOp.signature,
                abi.encode(laneKey)
            );
        }

        // pick validator for this lane (fallback to defaultValidator)
        address validator = cfg.validator;
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

    /// @notice Called by EntryPoint during UserOp execution.
    /// @dev fullNonce SHOULD be userOp.nonce (enforced by a validation hook like NonceBoundCallDataValidationHook)
    function executeUserOp(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 fullNonce
    ) external onlyEntryPoint returns (bytes memory ret) {
        (uint192 laneKey, ) = _splitNonce(fullNonce);
        return _executeForLane(laneKey, msg.sender, to, value, data);
    }

    /// @notice Backward-compatible entry-point method that takes an explicit laneKey.
    function executeFromEntryPoint(
        uint192 laneKey,
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint returns (bytes memory ret) {
        return _executeForLane(laneKey, msg.sender, to, value, data);
    }

    /// @notice Manual path: owner or installed executor module can call.
    /// @dev laneKey can be embedded into `data` as abi.encode(uint192 laneKey, bytes innerCallData).
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory ret) {
        if (msg.sender != owner && !_isExecutor(msg.sender)) revert NotOwner();

        (uint192 laneKey, bytes memory inner) = _decodeLaneDataOrDefaultMemory(
            data
        );
        return _executeForLaneMemory(laneKey, msg.sender, to, value, inner);
    }

    function _executeForLane(
        uint192 laneKey,
        address caller,
        address to,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory) {
        // calldata版（EntryPoint経路）
        LaneConfig memory cfg = _laneOrDefault(laneKey);

        if (cfg.executor != address(0)) {
            if (!_moduleInstalled[ModuleType.EXECUTOR][cfg.executor])
                revert ModuleNotInstalled();
        }

        if (cfg.execHook != address(0)) {
            IHook(cfg.execHook).preCheck(caller, to, value, data);
        }

        (bool success, bytes memory out) = to.call{value: value}(data);

        if (cfg.execHook != address(0)) {
            IHook(cfg.execHook).postCheck(
                caller,
                to,
                value,
                data,
                success,
                out
            );
        }

        if (!success) {
            assembly {
                revert(add(out, 0x20), mload(out))
            }
        }
        return out;
    }

    function _executeForLaneMemory(
        uint192 laneKey,
        address caller,
        address to,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory) {
        // memory版（manual execute 経路）
        LaneConfig memory cfg = _laneOrDefault(laneKey);

        if (cfg.executor != address(0)) {
            if (!_moduleInstalled[ModuleType.EXECUTOR][cfg.executor])
                revert ModuleNotInstalled();
        }

        if (cfg.execHook != address(0)) {
            IHook(cfg.execHook).preCheck(caller, to, value, data);
        }

        (bool success, bytes memory out) = to.call{value: value}(data);

        if (cfg.execHook != address(0)) {
            IHook(cfg.execHook).postCheck(
                caller,
                to,
                value,
                data,
                success,
                out
            );
        }

        if (!success) {
            assembly {
                revert(add(out, 0x20), mload(out))
            }
        }
        return out;
    }

    receive() external payable {}

    // -----------------------------
    // ERC-7579-ish ModuleManager
    // -----------------------------
    function installModule(
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external override onlyOwner {
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

    // -----------------------------
    // Internals
    // -----------------------------
    function _laneOrDefault(
        uint192 laneKey
    ) internal view returns (LaneConfig memory) {
        LaneConfig memory c = laneConfig[laneKey];
        if (
            c.validator != address(0) ||
            c.validationHook != address(0) ||
            c.executor != address(0) ||
            c.execHook != address(0)
        ) {
            return c;
        }
        return laneConfig[uint192(0)];
    }

    function _splitNonce(
        uint256 fullNonce
    ) internal pure returns (uint192 key, uint64 seq) {
        key = uint192(fullNonce >> 64);
        seq = uint64(fullNonce);
    }

    /// @dev A方式(memory): raw bytes OR abi.encode(uint192 laneKey, bytes innerCallData).
    /// If not matching the expected encoding, treat as raw and laneKey=0.
    function _decodeLaneDataOrDefaultMemory(
        bytes calldata data
    ) internal pure returns (uint192 laneKey, bytes memory inner) {
        // If too short to be abi.encode(uint192, bytes) (which is 96 + len),
        // treat as raw.
        if (data.length < 96) {
            return (uint192(0), bytes(data));
        }

        // Layout of abi.encode(uint192, bytes):
        // [ 0x00..0x1f ] uint192 (in high bits) + padding
        // [ 0x20..0x3f ] offset to bytes (=0x40)
        // [ 0x40..0x5f ] bytes length
        // [ 0x60..      ] bytes data
        uint256 offset;
        uint256 len;
        uint192 key;

        assembly {
            // key stored in the high 192 bits of the word -> shift right 64 bits
            key := shr(64, calldataload(data.offset))
            offset := calldataload(add(data.offset, 0x20))
        }

        if (offset != 0x40) {
            return (uint192(0), bytes(data));
        }

        assembly {
            len := calldataload(add(data.offset, offset))
        }

        // total length must be exactly 0x60 + len
        if (data.length != 0x60 + len) {
            return (uint192(0), bytes(data));
        }

        inner = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            inner[i] = data[i + 0x60];
        }
        return (uint192(key), inner);
    }
}
