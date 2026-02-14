// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";
import {AuthorContextNFT} from "../contracts/AuthorContextNFT.sol";

/// @notice Deploys ContextObservatoryV0 + AuthorContextNFT, wires them together.
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run()
        external
        returns (ContextObservatoryV0 observatory, AuthorContextNFT authorNft)
    {
        vm.startBroadcast();

        // msg.sender during broadcast is the EOA that signs the txs (your deployer).
        address author = msg.sender;

        observatory = new ContextObservatoryV0(author);

        // Make the observatory the owner so it can mint on redeem().
        authorNft = new AuthorContextNFT(
            "Nothing but a Number Paradox",
            "NBNP",
            address(observatory)
        );

        observatory.setAuthorNft(address(authorNft));

        vm.stopBroadcast();
    }
}
