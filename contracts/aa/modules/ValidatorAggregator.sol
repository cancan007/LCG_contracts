// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {IValidator, ModuleType} from "../interfaces/ERC7579.sol";
import {VersionedAggregatorBase} from "./VersionedAggregatorBase.sol";

/// @notice Versioned validator aggregator.
/// @dev All active validators must pass. This lets you compose authentication
///      (e.g. PasskeyValidator) and lane policy validators safely.
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
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

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
        _downgrade(major, minor, patch);
    }
    function getCurrentValidators() external view returns (address[] memory) {
        return _activeValidators;
    }
    function getActiveValidators() external view returns (address[] memory) {
        uint96 tag = this.activeVersionTag();
        (uint32 major, uint32 minor, uint32 patch) = _versionTagParse(tag);
        return _loadSnapshot(major, minor, patch);
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256) {
        address[] memory list = _activeValidators;
        uint256 n = list.length;
        if (n == 0) return SIG_VALIDATION_FAILED;

        uint256 merged;
        for (uint256 i = 0; i < n; i++) {
            uint256 vd = IValidator(list[i]).validateUserOp(userOp, userOpHash);
            if (vd == SIG_VALIDATION_FAILED) return SIG_VALIDATION_FAILED;
            merged |= vd;
        }
        return merged;
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        address[] memory list = _activeValidators;
        uint256 n = list.length;
        if (n == 0) return bytes4(0);

        bytes4 finalMagic = 0x1626ba7e;
        for (uint256 i = 0; i < n; i++) {
            bytes4 magic = IValidator(list[i]).isValidSignatureWithSender(
                sender,
                hash,
                signature
            );
            if (magic == bytes4(0)) return bytes4(0);
            finalMagic = magic;
        }
        return finalMagic;
    }

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
        for (uint256 i = 0; i < newModules.length; i++)
            _activeValidators.push(newModules[i]);
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
