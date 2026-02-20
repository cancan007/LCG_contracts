// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {VersionedAggregatorBase} from "./VersionedAggregatorBase.sol";

/// @notice Versioned validator aggregator.
/// - You manage "active validator set" by version (major/minor/patch).
/// - validateUserOp tries validators in order; first non-failure wins.
/// - Intended as your "dev / ops" surface: upgrade/downgrade by switching the active set.
///
/// IMPORTANT:
/// - This contract must be installed as a VALIDATOR module in the SmartAccount.
/// - It expe96 `onlyAuditor` to be the SmartAccount address.
contract ValidatorAggregator is VersionedAggregatorBase, IValidator {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    struct Snapshot {
        address[] validators;
    }

    address auditor;

    mapping(uint96 => Snapshot) private _snapshots;
    address[] private _activeValidators;

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
        return moduleTypeId == ModuleType.VALIDATOR;
    }

    function onInstall(bytes calldata data) external override onlyAuditor {}

    function onUninstall(bytes calldata) external override onlyAuditor {}

    // Ops
    function upgrade(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] calldata validators
    ) external onlyAuditor {
        _replaceModules(validators);
        _recordUpgrade(major, minor, patch);
    }

    function downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) external onlyAuditor {
        _downgrade(major, minor, patch); // checks version existence and emits event
    }

    function getCurrentValidators() external view returns (address[] memory) {
        return _activeValidators;
    }

    function getActiveValidators() external view returns (address[] memory) {
        uint96 tag = this.activeVersionTag();
        (uint32 major, uint32 minor, uint32 patch) = _versionTagParse(tag); // sanity check for overflow
        address[] memory validators = _loadSnapshot(major, minor, patch);
        return validators;
    }

    // -----------------------------
    // IValidator
    // -----------------------------
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        address[] memory list = _activeValidators;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 vd = IValidator(list[i]).validateUserOp(userOp, userOpHash);
            if (vd != SIG_VALIDATION_FAILED) return vd;
        }
        return SIG_VALIDATION_FAILED;
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        address[] memory list = _activeValidators;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            bytes4 magic = IValidator(list[i]).isValidSignatureWithSender(
                sender,
                hash,
                signature
            );
            if (magic != bytes4(0)) return magic;
        }
        return bytes4(0);
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
        return _activeValidators;
    }

    function _replaceModules(address[] memory newModules) internal override {
        delete _activeValidators;
        for (uint256 i = 0; i < newModules.length; i++) {
            _activeValidators.push(newModules[i]);
        }
    }

    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory validators
    ) internal override {
        uint96 tag = _versionTag(major, minor, patch);
        _snapshots[tag] = Snapshot({validators: validators});
    }

    function _loadSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view override returns (address[] memory) {
        uint96 tag = _versionTag(major, minor, patch);
        Snapshot memory s = _snapshots[tag];
        if (s.validators.length == 0)
            revert VersionNotFound(major, minor, patch);
        return s.validators;
    }
}
