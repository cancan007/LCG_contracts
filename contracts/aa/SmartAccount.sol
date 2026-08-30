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
    IModuleManager,
    IAccountExecution
} from "./interfaces/ERC7579.sol";
import {IValidationHook} from "./interfaces/IValidationHook.sol";
import {ModeLib} from "./libs/ModeLib.sol";

interface IPasskeyCredentialStore {
    function getPasskeyCredential()
        external
        view
        returns (
            bytes32 rpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            bool requireUV,
            bytes32 credentialIdHashOpt
        );
}

/// @notice ERC-4337 Smart Account scaffold (EntryPoint v0.7 / PackedUserOperation) with:
/// - ERC-7579 module registry (validator/executor/hook)
/// - laneKey (uint192) -> LaneConfig selection
/// - ValidationPreHookAggregator (IValidationHook) (optional per lane)
/// - ExecutionHookAggregator (IHook) (optional per lane; recommended to be an aggregator)
///
/// Design notes:
/// - laneKey selection is derived from userOp.nonce ([uint192 laneKey | uint64 seq]).
/// - nonceSequence is updated ONLY after successful validation (preHook + validator).
/// - execute() / executeFromExecutor() take an ERC-7579 (mode, executionCalldata) pair;
///   the laneKey mode carries the laneKey inside executionCalldata (see ModeLib).
contract SmartAccount is IAccount, IModuleManager {
    // -----------------------------
    // Constants
    // -----------------------------
    // ERC-4337 constant: return value indicating signature failure (should not revert)
    uint256 internal constant SIG_VALIDATION_FAILED = 1; // :contentReference[oaicite:1]{index=1}

    uint192 internal constant DEFAULT_LANE = 0;

    // -----------------------------
    // Errors
    // -----------------------------
    error NotEntryPoint();
    error NotOwner();
    error NotAuthorized();
    error ModuleAlreadyInstalled();
    error ModuleNotInstalled();
    error InvalidModuleType();
    error ValidatorNotSet();
    error InvalidNonce();
    error UnsupportedCallType(bytes1 callType);

    // -----------------------------
    // Events
    // -----------------------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event EntryPointChanged(address indexed oldEP, address indexed newEP);

    event LaneValidatorSet(
        uint192 indexed laneKey,
        address indexed oldValidator,
        address indexed newValidator
    );
    event LaneValidationHookSet(
        uint192 indexed laneKey,
        address indexed oldHook,
        address indexed newHook
    );
    event LaneExecutorSet(
        uint192 indexed laneKey,
        address indexed oldExecutor,
        address indexed newExecutor
    );
    event LaneExecHookSet(
        uint192 indexed laneKey,
        address indexed oldHook,
        address indexed newHook
    );

    // -----------------------------
    // Storage
    // -----------------------------
    address public owner;
    IEntryPoint public entryPoint;

    // module registry (ERC-7579-ish)
    mapping(uint256 => mapping(address => bool)) private _moduleInstalled;
    mapping(uint256 => address[]) private _modules;

    struct LaneConfig {
        address validator; // IValidator
        address validationHook; // IValidationHook (OPTIONAL; stored as Hook module type)
        address executor; // IExecutor (OPTIONAL)
        address execHook; // IHook (OPTIONAL; recommended: ExecutionHookAggregator)
    }

    mapping(uint192 => LaneConfig) internal laneConfig;

    // laneKey => sequence (uint64)
    mapping(uint192 => uint64) public nonceSequence;

    struct PasskeyCredential {
        bytes32 rpIdHash;
        uint256 pubKeyX;
        uint256 pubKeyY;
        bool requireUV;
        bytes32 credentialIdHashOpt;
    }

    PasskeyCredential internal _passkeyCredential;

    event PasskeyCredentialSet(
        bytes32 indexed rpIdHash,
        uint256 pubKeyX,
        uint256 pubKeyY,
        bool requireUV,
        bytes32 credentialIdHashOpt
    );
    event PasskeyCredentialCleared();

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

    modifier onlyEntryPointOrOwner() {
        if (msg.sender != address(entryPoint) && msg.sender != owner)
            revert NotAuthorized();
        _;
    }

    modifier onlyInstalledExecutor() {
        if (!_moduleInstalled[ModuleType.EXECUTOR][msg.sender])
            revert ModuleNotInstalled();
        _;
    }

    constructor(address _owner, address _entryPoint) {
        owner = _owner;
        entryPoint = IEntryPoint(_entryPoint);
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

    function setPasskeyCredential(
        bytes32 rpIdHash,
        uint256 pubKeyX,
        uint256 pubKeyY,
        bool requireUV,
        bytes32 credentialIdHashOpt
    ) external onlyOwner {
        _passkeyCredential = PasskeyCredential({
            rpIdHash: rpIdHash,
            pubKeyX: pubKeyX,
            pubKeyY: pubKeyY,
            requireUV: requireUV,
            credentialIdHashOpt: credentialIdHashOpt
        });

        emit PasskeyCredentialSet(
            rpIdHash,
            pubKeyX,
            pubKeyY,
            requireUV,
            credentialIdHashOpt
        );
    }

    function clearPasskeyCredential() external onlyOwner {
        delete _passkeyCredential;
        emit PasskeyCredentialCleared();
    }

    function getPasskeyCredential()
        external
        view
        returns (
            bytes32 rpIdHash,
            uint256 pubKeyX,
            uint256 pubKeyY,
            bool requireUV,
            bytes32 credentialIdHashOpt
        )
    {
        PasskeyCredential memory c = _passkeyCredential;
        return (
            c.rpIdHash,
            c.pubKeyX,
            c.pubKeyY,
            c.requireUV,
            c.credentialIdHashOpt
        );
    }

    // lane wiring (domain config; laneKey structure is off-chain convention)
    function setLaneValidator(
        uint192 laneKey,
        address validator
    ) external onlyOwner {
        if (
            validator != address(0) &&
            !_moduleInstalled[ModuleType.VALIDATOR][validator]
        ) revert ModuleNotInstalled();
        address old = laneConfig[laneKey].validator;
        laneConfig[laneKey].validator = validator;
        emit LaneValidatorSet(laneKey, old, validator);
    }

    function setLaneValidationHook(
        uint192 laneKey,
        address hook
    ) external onlyOwner {
        if (hook != address(0) && !_moduleInstalled[ModuleType.HOOK][hook])
            revert ModuleNotInstalled();
        address old = laneConfig[laneKey].validationHook;
        laneConfig[laneKey].validationHook = hook;
        emit LaneValidationHookSet(laneKey, old, hook);
    }

    function setLaneExecutor(
        uint192 laneKey,
        address executor
    ) external onlyOwner {
        if (
            executor != address(0) &&
            !_moduleInstalled[ModuleType.EXECUTOR][executor]
        ) revert ModuleNotInstalled();
        address old = laneConfig[laneKey].executor;
        laneConfig[laneKey].executor = executor;
        emit LaneExecutorSet(laneKey, old, executor);
    }

    function setLaneExecHook(uint192 laneKey, address hook) external onlyOwner {
        if (hook != address(0) && !_moduleInstalled[ModuleType.HOOK][hook])
            revert ModuleNotInstalled();
        address old = laneConfig[laneKey].execHook;
        laneConfig[laneKey].execHook = hook;
        emit LaneExecHookSet(laneKey, old, hook);
    }

    function getLaneConfig(
        uint192 laneKey
    ) external view returns (LaneConfig memory) {
        return laneConfig[laneKey];
    }

    function withdraw(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient balance");
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // -----------------------------
    // ERC-4337 v0.7: validateUserOp
    // -----------------------------
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override onlyEntryPoint returns (uint256 validationData) {
        (uint192 laneKey, uint64 seq) = _splitNonce(userOp.nonce);

        // lane replay protection (do NOT bump nonce until *after* successful validation)
        if (seq != nonceSequence[laneKey]) revert InvalidNonce();

        LaneConfig memory cfg = _laneOrDefault(laneKey);

        if (cfg.validationHook != address(0)) {
            // runtimeData is optional in your design; pass empty for now
            IValidationHook(cfg.validationHook).preValidate(
                userOp,
                userOpHash,
                userOp.signature,
                bytes("")
            );
        }

        if (cfg.validator == address(0)) revert ValidatorNotSet();

        // validator may touch state, so NOT view (ERC-7579 style) :contentReference[oaicite:2]{index=2}
        validationData = IValidator(cfg.validator).validateUserOp(
            userOp,
            userOpHash
        );

        if (validationData != SIG_VALIDATION_FAILED) {
            // successful validation -> bump nonce
            nonceSequence[laneKey] = seq + 1;
        }

        if (missingAccountFunds != 0) {
            (bool sent, ) = payable(msg.sender).call{
                value: missingAccountFunds
            }("");
            if (!sent) return SIG_VALIDATION_FAILED;
        }
    }

    // -----------------------------
    // Execution
    // -----------------------------

    /// @notice Called by EntryPoint during UserOp execution.
    /// @dev `fullNonce` SHOULD be userOp.nonce (enforced by a validation hook like NonceBoundCallDataValidationHook).
    function executeUserOp(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 fullNonce
    ) external onlyEntryPoint returns (bytes memory ret) {
        (uint192 laneKey, ) = _splitNonce(fullNonce);
        return _exec(laneKey, to, value, data);
    }

    /// @notice Backward-compatible EntryPoint method that takes an explicit laneKey.
    function executeFromEntryPoint(
        uint192 laneKey,
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint returns (bytes memory ret) {
        return _exec(laneKey, to, value, data);
    }

    // -----------------------------
    // ERC-7579: execute / executeFromExecutor
    // -----------------------------

    /// @notice ERC-7579 compliant execute.
    /// @dev Called by EntryPoint (after UserOp validation) or directly by owner.
    ///      Supported modes: CALLTYPE_SINGLE (standard or laneKey variant).
    ///      msg.sender to the target is always this SmartAccount — not a module.
    function execute(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external onlyEntryPointOrOwner returns (bytes[] memory returnData) {
        return _executeWithMode(mode, executionCalldata);
    }

    /// @notice Called by installed executor modules to trigger execution on this account.
    /// @dev Executor modules must be installed via installModule(EXECUTOR, ...) first.
    ///      This keeps msg.sender = SmartAccount for the target, regardless of which
    ///      executor module initiated the call.
    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external onlyInstalledExecutor returns (bytes[] memory returnData) {
        return _executeWithMode(mode, executionCalldata);
    }

    function _executeWithMode(
        bytes32 mode,
        bytes calldata executionCalldata
    ) internal returns (bytes[] memory returnData) {
        bytes1 callType = ModeLib.getCallType(mode);

        if (callType == ModeLib.CALLTYPE_SINGLE) {
            returnData = new bytes[](1);
            if (ModeLib.isLane(mode)) {
                (
                    uint192 laneKey,
                    address to,
                    uint256 value,
                    bytes memory data
                ) = ModeLib.decodeLane(executionCalldata);
                returnData[0] = _exec(laneKey, to, value, data);
            } else {
                (address to, uint256 value, bytes calldata data) = ModeLib
                    .decodeSingle(executionCalldata);
                returnData[0] = _exec(DEFAULT_LANE, to, value, data);
            }
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    /// @dev Core execution: runs execHook, then calls target. Executor routing is
    ///      intentionally removed — executors call executeFromExecutor() instead.
    function _exec(
        uint192 laneKey,
        address to,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory) {
        LaneConfig memory cfg = _laneOrDefault(laneKey);

        bytes memory hookData;
        if (cfg.execHook != address(0)) {
            hookData = IHook(cfg.execHook).preCheck(
                msg.sender,
                value,
                abi.encode(laneKey, to, value, data)
            );
        }

        (bool success, bytes memory retdata) = to.call{value: value}(data);
        if (!success) _bubble(retdata);

        if (cfg.execHook != address(0)) {
            IHook(cfg.execHook).postCheck(hookData);
        }

        return retdata;
    }

    function _bubble(bytes memory retdata) internal pure {
        assembly {
            revert(add(retdata, 0x20), mload(retdata))
        }
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
    // ERC-7579-ish ModuleManager
    // -----------------------------
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external override onlyOwner {
        _installModuleInternal(moduleTypeId, module, initData);
    }

    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external override onlyOwner {
        if (!_moduleInstalled[moduleTypeId][module])
            revert ModuleNotInstalled();
        _moduleInstalled[moduleTypeId][module] = false;

        address[] storage arr = _modules[moduleTypeId];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == module) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }

        IModule(module).onUninstall(deInitData);
        emit ModuleUninstalled(moduleTypeId, module);
    }

    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata /*additionalContext*/
    ) external view override returns (bool) {
        return _moduleInstalled[moduleTypeId][module];
    }

    function getModules(
        uint256 moduleTypeId
    ) external view override returns (address[] memory) {
        return _modules[moduleTypeId];
    }

    function _installModuleInternal(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) internal {
        if (moduleTypeId < 1 || moduleTypeId > 4) revert InvalidModuleType();
        if (_moduleInstalled[moduleTypeId][module])
            revert ModuleAlreadyInstalled();

        _moduleInstalled[moduleTypeId][module] = true;
        _modules[moduleTypeId].push(module);

        IModule(module).onInstall(initData);
        emit ModuleInstalled(moduleTypeId, module);
    }

    function _laneOrDefault(
        uint192 laneKey
    ) internal view returns (LaneConfig memory cfg) {
        cfg = laneConfig[laneKey];

        LaneConfig storage d = laneConfig[DEFAULT_LANE];
        if (cfg.validator == address(0)) cfg.validator = d.validator;
        if (cfg.validationHook == address(0))
            cfg.validationHook = d.validationHook;
        if (cfg.executor == address(0)) cfg.executor = d.executor;
        if (cfg.execHook == address(0)) cfg.execHook = d.execHook;
    }

    function _splitNonce(
        uint256 fullNonce
    ) internal pure returns (uint192 key, uint64 seq) {
        key = uint192(fullNonce >> 64);
        seq = uint64(fullNonce);
    }
}
