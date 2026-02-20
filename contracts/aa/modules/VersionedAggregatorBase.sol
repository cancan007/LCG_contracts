// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract VersionedAggregatorBase {
    error NotAccount();
    error VersionNotFound(uint32 major, uint32 minor, uint32 patch);
    error VersionAlreadyRecorded(uint32 major, uint32 minor, uint32 patch);

    constructor() {}

    /// @notice verTag = uint96 (major<<64 | minor<<32 | patch)
    function _versionTag(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal pure returns (uint96) {
        return (uint96(major) << 64) | (uint96(minor) << 32) | uint96(patch);
    }

    function _versionTagParse(
        uint96 verTag
    ) internal pure returns (uint32 major, uint32 minor, uint32 patch) {
        major = uint32(verTag >> 64);
        minor = uint32((verTag >> 32) & 0xFFFFFFFF);
        patch = uint32(verTag & 0xFFFFFFFF);
    }

    /// @dev 子コントラクトが参照している識別子をBaseに用意（undeclared回避）
    uint96 internal _activeVersionTag;

    /// @dev verTag が既に記録済みかどうか（上書き防止用）
    mapping(uint96 => bool) internal _versionRecorded;

    event Upgrade(
        uint32 indexed major,
        uint32 indexed minor,
        uint32 indexed patch,
        address[] modules
    );
    event Downgrade(
        uint32 indexed major,
        uint32 indexed minor,
        uint32 indexed patch,
        address[] modules
    );

    // -----------------------------
    // Hooks for child contracts
    // -----------------------------

    /// @dev 子が “今のmodules” を返す
    function _currentModules() internal view virtual returns (address[] memory);

    /// @dev 子が “modulesを丸ごと置換” する
    function _replaceModules(address[] memory newModules) internal virtual;

    /// @dev 子がスナップショット保存する（必要ならoverride）
    function _storeSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch,
        address[] memory modules
    ) internal virtual;

    /// @dev 子がスナップショットをロードする
    function _loadSnapshot(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal view virtual returns (address[] memory modules);

    // -----------------------------
    // Active version controls (for child usage)
    // -----------------------------

    /// @dev 子が _setActive(...) を呼んでもundeclaredにならないようBaseに実装
    function _setActive(uint96 verTag) internal {
        _activeVersionTag = verTag;
    }

    /// @dev (major,minor,patch) -> active version を切り替える
    function _setActiveVersion(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal {
        uint96 tag = _versionTag(major, minor, patch);
        if (!_versionRecorded[tag]) revert VersionNotFound(major, minor, patch);
        _setActive(tag);
    }

    // -----------------------------
    // External API (onlyAccount)
    // -----------------------------

    /// @notice 現在のmodules状態を指定verでスナップショットとして記録する
    /// @dev 同じverTagには二度と記録できない（freeze不要）
    function _recordUpgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal virtual {
        uint96 tag = _versionTag(major, minor, patch);
        if (_versionRecorded[tag])
            revert VersionAlreadyRecorded(major, minor, patch);

        address[] memory cur = _currentModules();
        _storeSnapshot(major, minor, patch, cur);

        _versionRecorded[tag] = true;
        _setActive(tag);

        emit Upgrade(major, minor, patch, cur);
    }

    /// @notice 指定verへ modules を一括置換して戻す
    function _downgrade(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) internal virtual {
        uint96 tag = _versionTag(major, minor, patch);
        if (!_versionRecorded[tag]) revert VersionNotFound(major, minor, patch);

        address[] memory mods = _loadSnapshot(major, minor, patch);
        if (mods.length == 0) revert VersionNotFound(major, minor, patch);

        _replaceModules(mods);
        _setActive(tag);

        emit Downgrade(major, minor, patch, mods);
    }

    /// @notice 記録済みか（UI/テスト用）
    function isRecorded(
        uint32 major,
        uint32 minor,
        uint32 patch
    ) external view returns (bool) {
        return _versionRecorded[_versionTag(major, minor, patch)];
    }

    /// @notice 現在activeなversionTag（UI/テスト用）
    function activeVersionTag() external view returns (uint96) {
        return _activeVersionTag;
    }
}
