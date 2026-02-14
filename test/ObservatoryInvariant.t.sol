// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {AuthorContextNFT} from "../contracts/AuthorContextNFT.sol";
import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";
import {ObservatoryHandler} from "./handlers/ObservatoryHandler.sol";

contract ObservatoryInvariant is StdInvariant, Test {
    AuthorContextNFT nft;
    ContextObservatoryV0 obs;
    ObservatoryHandler handler;

    uint256 constant EPOCH1 = 1;
    uint256 constant EPOCH2 = 2;

    function setUp() public {
        obs = new ContextObservatoryV0(address(this));
        nft = new AuthorContextNFT("AuthorContext", "ACTX", address(this));
        nft.transferOwnership(address(obs));
        obs.setAuthorNft(address(nft));

        // Finalize epoch1 with a dummy root, to trigger memoAlwaysPublic policy in your contract.
        // Root doesn't matter for these invariants (we're not redeeming successful proofs).
        obs.finalizeEpoch(EPOCH1, bytes32(uint256(1)), true);

        // Prepare epoch2 commit environment
        obs.setActiveEpoch(EPOCH2);
        obs.setPostPolicy(100, true); // avoid post-limit flakiness

        // create context so sourceContextId=1 exists
        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        // Stake from this contract (since handler calls from itself, not from EOAs).
        // If your stake gating checks msg.sender stake, we should stake from handler address too;
        // easiest is: create handler first, then stake as handler via prank.
        handler = new ObservatoryHandler(obs);

        // Provide ETH to handler and stake as handler (msg.sender in commit will be handler).
        vm.deal(address(handler), 1 ether);
        vm.prank(address(handler));
        obs.depositStake{value: 0.2 ether}();

        // Set the target contract for invariant fuzzing
        targetContract(address(handler));
    }

    function invariant_no_bad_commit_succeeds() public view {
        // If memoHash != keccak256(memoURI) ever succeeds, that's a bug.
        assertFalse(handler.badCommitSucceeded());
    }

    function invariant_redeem_requires_finalize() public view {
        // Redeem on non-finalized epoch must never succeed.
        assertFalse(handler.redeemWithoutFinalizeSucceeded());
    }
}
