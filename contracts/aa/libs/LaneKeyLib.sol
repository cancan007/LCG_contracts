// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 192-bit laneKey namespacing helper.
/// Suggested layout (example):
/// - [191:128] industryId (uint64)
/// - [127:64]  appId      (uint64)
/// - [63:0]    actionId   (uint64)
///
/// You can reinterpret the 3 x uint64 slots however you want, as long as you keep it consistent.
library LaneKeyLib {
    function pack(
        uint64 industryId,
        uint64 appId,
        uint64 actionId
    ) internal pure returns (uint192) {
        return
            (uint192(industryId) << 128) |
            (uint192(appId) << 64) |
            uint192(actionId);
    }

    function industry(uint192 laneKey) internal pure returns (uint64) {
        return uint64(uint192(laneKey) >> 128);
    }

    function app(uint192 laneKey) internal pure returns (uint64) {
        return uint64(uint192(laneKey) >> 64);
    }

    function action(uint192 laneKey) internal pure returns (uint64) {
        return uint64(laneKey);
    }
}
