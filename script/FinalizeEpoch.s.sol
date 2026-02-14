// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";

/// @notice Finalize an epoch by committing the Merkle root.
/// Env vars:
///   OBSERVATORY   - deployed ContextObservatoryV0 address
///   EPOCH_ID      - uint256
///   MERKLE_ROOT   - bytes32 (0x...)
///   ENABLE_REDEEM - bool (true/false)
///
/// Usage:
///   export OBSERVATORY=0x...
///   export EPOCH_ID=1
///   export MERKLE_ROOT=0x...
///   export ENABLE_REDEEM=true
///   forge script script/FinalizeEpoch.s.sol:FinalizeEpoch --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract FinalizeEpoch is Script {
    function run() external {
        address obsAddr = vm.envAddress("OBSERVATORY");
        uint256 epochId = vm.envUint("EPOCH_ID");
        bytes32 root = vm.envBytes32("MERKLE_ROOT");
        bool enableRedeem = vm.envBool("ENABLE_REDEEM");

        vm.startBroadcast();
        ContextObservatoryV0(obsAddr).finalizeEpoch(epochId, root, enableRedeem);
        vm.stopBroadcast();
    }
}
