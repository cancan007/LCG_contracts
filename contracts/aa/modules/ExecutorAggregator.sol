// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutor, IModule, ModuleType} from "../interfaces/ERC7579.sol";
import {VersionedAggregatorBase} from "./VersionedAggregatorBase.sol";

contract ExecutorAggregator is VersionedAggregatorBase, IExecutor {
    error NoExecutor();
    struct Snapshot {
        address[] executors;
    }

    address auditor;

    mapping(uint96 => Snapshot) private _snapshots;
    address[] private _activeExecutors;

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

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.EXECUTOR;
    }

    function upgrade(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] calldata executors
    ) external onlyAuditor {
        _replaceModules(executors);
        _recordUpgrade(major, minor, patch);
    }

    function downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) external onlyAuditor {
        _downgrade(major, minor, patch); // checks version existence and emits event
    }

    function getCurrentExecutors() external view returns (address[] memory) {
        return _activeExecutors;
    }

    function getActiveExecutors() external view returns (address[] memory) {
        uint96 tag = this.activeVersionTag();
        (uint32 major, uint32 minor, uint32 patch) = _versionTagParse(tag); // sanity check for overflow
        address[] memory executors = _loadSnapshot(major, minor, patch);
        return executors;
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory ret) {
        address[] memory list = _activeExecutors;
        for (uint256 i = 0; i < list.length; i++) {
            ret = IExecutor(list[i]).execute(to, value, data);
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
        return _activeExecutors;
    }

    function _replaceModules(address[] memory newModules) internal override {
        delete _activeExecutors;
        for (uint256 i = 0; i < newModules.length; i++) {
            _activeExecutors.push(newModules[i]);
        }
    }

    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory executors
    ) internal override {
        uint96 tag = _versionTag(major, minor, patch);
        _snapshots[tag] = Snapshot({executors: executors});
    }

    function _loadSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view override returns (address[] memory) {
        uint96 tag = _versionTag(major, minor, patch);
        Snapshot memory s = _snapshots[tag];
        if (s.executors.length == 0)
            revert VersionNotFound(major, minor, patch);
        return s.executors;
    }
}
