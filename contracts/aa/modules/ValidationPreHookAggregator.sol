// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {IValidationHook} from "../interfaces/IValidationHook.sol";
import {IModule, ModuleType} from "../interfaces/ERC7579.sol";
import {VersionedAggregatorBase} from "./VersionedAggregatorBase.sol";

/// @notice Versioned Validation-PreHook aggregator.
/// - Stores an ordered list of IValidationHook implementations per versionTag.
/// - preValidate runs them sequentially; any revert fails validation (good for DoS-resistance via pre-checks).
contract ValidationPreHookAggregator is
    VersionedAggregatorBase,
    IValidationHook
{
    struct Snapshot {
        address[] hooks;
    }

    address auditor;

    mapping(uint96 => Snapshot) private _snapshots;
    address[] private _activeHooks;

    constructor(address _auditor) VersionedAggregatorBase() {
        auditor = _auditor;
    }

    modifier onlyAuditor() {
        if (msg.sender != auditor) revert NotAccount();
        _;
    }

    function setAuditor(address newAuditor) external onlyAuditor {
        auditor = newAuditor;
    }

    // IModule
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.HOOK;
    }

    function onInstall(bytes calldata data) external override {}

    function onUninstall(bytes calldata) external override {}

    function upgrade(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] calldata hooks
    ) external onlyAuditor {
        _replaceModules(hooks);
        _recordUpgrade(major, minor, patch);
    }

    function downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) external onlyAuditor {
        _downgrade(major, minor, patch); // checks version existence and emits event
    }

    function getCurrentHooks() external view returns (address[] memory) {
        return _activeHooks;
    }

    function getActiveHooks() external view returns (address[] memory) {
        uint96 tag = this.activeVersionTag();
        (uint32 major, uint32 minor, uint32 patch) = _versionTagParse(tag); // sanity check for overflow
        address[] memory hooks = _loadSnapshot(major, minor, patch);
        return hooks;
    }

    // IValidationHook
    function preValidate(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        bytes calldata signature,
        bytes calldata runtimeData
    ) external view override {
        address[] memory list = _activeHooks;
        for (uint256 i = 0; i < list.length; i++) {
            IValidationHook(list[i]).preValidate(
                userOp,
                userOpHash,
                signature,
                runtimeData
            );
        }
    }
    // -----------------------------
    // internal
    // -----------------------------
    function _currentModules()
        internal
        view
        override
        returns (address[] memory)
    {
        return _activeHooks;
    }

    function _replaceModules(address[] memory newModules) internal override {
        delete _activeHooks;
        for (uint256 i = 0; i < newModules.length; i++) {
            _activeHooks.push(newModules[i]);
        }
    }

    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory hooks
    ) internal override {
        uint96 tag = _versionTag(major, minor, patch);
        _snapshots[tag] = Snapshot({hooks: hooks});
    }

    function _loadSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view override returns (address[] memory) {
        uint96 tag = _versionTag(major, minor, patch);
        Snapshot memory s = _snapshots[tag];
        if (s.hooks.length == 0) revert VersionNotFound(major, minor, patch);
        return s.hooks;
    }
}
