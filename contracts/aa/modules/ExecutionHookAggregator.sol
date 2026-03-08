// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook, ModuleType} from "../interfaces/ERC7579.sol";
import {VersionedAggregatorBase} from "./VersionedAggregatorBase.sol";

/// @notice Versioned execution hook aggregator.
/// - SmartAccount calls this as the lane's single execHook.
/// - This aggregator then calls `preCheck` on all preHooks and `postCheck` on all postHooks.
/// - Snapshot (upgrade/downgrade) is emitted via events and stored on-chain.
contract ExecutionHookAggregator is VersionedAggregatorBase, IHook {
    struct Snapshot {
        address[] preHooks;
        address[] postHooks;
    }

    address auditor;

    mapping(uint96 => Snapshot) private _versionToSnapshots;
    address[] private _activePre;
    address[] private _activePost;

    event Upgrade(
        uint32 indexed major,
        uint32 indexed minor,
        uint32 indexed patch,
        address[] preHooks,
        address[] postHooks
    );

    event Downgrade(
        uint32 indexed major,
        uint32 indexed minor,
        uint32 indexed patch,
        address[] preHooks,
        address[] postHooks
    );

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

    // Ops
    function upgrade(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] calldata preHooks,
        address[] calldata postHooks
    ) external onlyAuditor {
        _replaceExecutorHooks(preHooks, postHooks);
        _recordUpgrade(major, minor, patch);
    }

    function downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) external onlyAuditor {
        _downgrade(major, minor, patch);
    }

    function getCurrentExecutorHooks()
        external
        view
        returns (address[] memory preHooks, address[] memory postHooks)
    {
        return (_activePre, _activePost);
    }

    function getActiveExecutorHooks()
        external
        view
        returns (address[] memory preHooks, address[] memory postHooks)
    {
        uint96 tag = this.activeVersionTag();
        (uint32 major, uint32 minor, uint32 patch) = _versionTagParse(tag); // sanity check for overflow
        Snapshot memory s = _loadExecutorHookSnapshot(major, minor, patch);
        return (s.preHooks, s.postHooks);
    }

    // IHook
    /// @dev Returns encoded hookData for postCheck.
    /// hookData = abi.encode(bytes[] preHookDatas)
    function preCheck(
        address msgSender,
        uint256 value,
        bytes calldata msgData
    ) external override returns (bytes memory hookData) {
        address[] memory pre = _activePre;
        bytes[] memory hookDatas = new bytes[](pre.length);

        for (uint256 i = 0; i < pre.length; i++) {
            hookDatas[i] = IHook(pre[i]).preCheck(msgSender, value, msgData);
        }
        return abi.encode(hookDatas);
    }

    function postCheck(bytes calldata hookData) external override {
        bytes[] memory preHookDatas = abi.decode(hookData, (bytes[]));
        address[] memory post = _activePost;

        // If you want symmetric data passing, you can include extra data in hookData.
        // Here, we just call post hooks with empty / aggregated info.
        for (uint256 i = 0; i < post.length; i++) {
            IHook(post[i]).postCheck(bytes(""));
        }

        // Optional: also allow preHooks to do a postCheck, if you want. Kept off for clarity.
        // (We still decoded preHookDatas to validate the format and avoid unused var warnings.)
        preHookDatas;
    }

    // -----------------------------
    // internal
    // -----------------------------
    function _currentExecutorHooks()
        internal
        view
        returns (address[] memory, address[] memory)
    {
        return (_activePre, _activePost);
    }

    function _replaceExecutorHooks(
        address[] memory preHooks,
        address[] memory postHooks
    ) internal {
        delete _activePre;
        delete _activePost;

        for (uint256 i = 0; i < preHooks.length; i++) {
            _activePre.push(preHooks[i]);
        }
        for (uint256 i = 0; i < postHooks.length; i++) {
            _activePost.push(postHooks[i]);
        }
    }

    function _loadExecutorHookSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view returns (Snapshot storage s) {
        uint96 tag = _versionTag(major, minor, patch);
        s = _versionToSnapshots[tag];
        if (s.preHooks.length == 0 && s.postHooks.length == 0) {
            revert VersionNotFound(major, minor, patch);
        }
        return s;
    }

    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory preHooks,
        address[] memory postHooks
    ) internal {
        uint96 tag = _versionTag(major, minor, patch);
        _versionToSnapshots[tag] = Snapshot({
            preHooks: preHooks,
            postHooks: postHooks
        });
    }

    /// @notice 現在のmodules状態を指定verでスナップショットとして記録する
    /// @dev 同じverTagには二度と記録できない（freeze不要）
    function _recordUpgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal override {
        uint96 tag = _versionTag(major, minor, patch);
        if (_versionRecorded[tag])
            revert VersionAlreadyRecorded(major, minor, patch);

        (
            address[] memory preHooks,
            address[] memory postHooks
        ) = _currentExecutorHooks();
        _storeSnapshot(major, minor, patch, preHooks, postHooks);
        _versionRecorded[tag] = true;
        _setActive(tag);

        emit Upgrade(major, minor, patch, preHooks, postHooks);
    }

    function _downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal override {
        uint96 tag = _versionTag(major, minor, patch);
        if (!_versionRecorded[tag]) revert VersionNotFound(major, minor, patch);

        Snapshot storage s = _loadExecutorHookSnapshot(major, minor, patch);
        if (s.preHooks.length == 0 || s.postHooks.length == 0)
            revert VersionNotFound(major, minor, patch);

        _replaceExecutorHooks(s.preHooks, s.postHooks);
        _setActiveVersion(major, minor, patch);
        emit Downgrade(major, minor, patch, s.preHooks, s.postHooks);
    }

    function _currentModules()
        internal
        view
        virtual
        override
        returns (address[] memory)
    {}

    function _replaceModules(
        address[] memory newModules
    ) internal virtual override {}

    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory modules
    ) internal virtual override {}

    function _loadSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view virtual override returns (address[] memory modules) {}
}
