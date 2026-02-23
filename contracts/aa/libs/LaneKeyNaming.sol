// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LaneKeyLib} from "../libs/LaneKeyLib.sol";

/// @notice Helper for deterministic laneKey naming using "industry/service/process".
/// Convention:
/// - id64(s) = uint64(bytes8(keccak256(bytes(s))))
/// - laneKey = LaneKeyLib.pack(industryId, serviceId, processId) (uint192)
library LaneKeyNaming {
    function id64(string memory s) internal pure returns (uint64) {
        return uint64(bytes8(keccak256(bytes(s))));
    }

    function laneKey(
        string memory industry,
        string memory service,
        string memory process
    ) internal pure returns (uint192) {
        return LaneKeyLib.pack(id64(industry), id64(service), id64(process));
    }
}
