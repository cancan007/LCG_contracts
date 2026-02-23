// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {AuthorContextNFT} from "../contracts/AuthorContextNFT.sol";
import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";

contract ObservatoryTest is Test {
    AuthorContextNFT nft;
    ContextObservatoryV0 obs;

    uint256 constant EPOCH1 = 1;
    uint256 constant EPOCH2 = 2;

    address user1 = address(0x1111);
    address user2 = address(0x2222);

    bytes32 root;
    bytes32 leaf1;
    bytes32 leaf2;

    function setUp() public {
        // Deploy obs with author = this test contract
        obs = new ContextObservatoryV0(address(this));
        nft = new AuthorContextNFT("AuthorContext", "ACTX", address(this));

        // Transfer NFT ownership to observatory so it can mint on redeem
        nft.transferOwnership(address(obs));
        obs.setAuthorNft(address(nft));

        // Prepare epoch distribution (2 leaves, sortPairs=true)
        bytes32 h1 = keccak256(bytes(_meta1()));
        bytes32 h2 = keccak256(bytes(_meta2()));

        leaf1 = keccak256(abi.encode(EPOCH1, user1, uint256(1001), h1));
        leaf2 = keccak256(abi.encode(EPOCH1, user2, uint256(1002), h2));

        root = _pairRoot(leaf1, leaf2);
    }

    function testRedeemRequiresFinalize() public {
        // user1 tries to redeem before finalize -> must revert
        vm.prank(user1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        vm.expectRevert();
        obs.redeem(EPOCH1, 1001, "ipfs://cid-token-1001", _meta1(), proof);

        // finalize then redeem should work
        obs.finalizeEpoch(EPOCH1, root, true);
        vm.prank(user1);
        obs.redeem(EPOCH1, 1001, "ipfs://cid-token-1001", _meta1(), proof);
        assertEq(nft.ownerOf(1001), user1);
    }

    function testRedeemMintsAndStoresHash() public {
        // finalize epoch1 first
        obs.finalizeEpoch(EPOCH1, root, true);

        // user1 redeem
        vm.prank(user1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;
        obs.redeem(EPOCH1, 1001, "ipfs://cid-token-1001", _meta1(), proof);

        assertEq(nft.ownerOf(1001), user1);
        assertEq(nft.metadataContentHash(1001), keccak256(bytes(_meta1())));

        // double claim should revert
        vm.prank(user1);
        vm.expectRevert();
        obs.redeem(EPOCH1, 1001, "ipfs://cid-token-1001", _meta1(), proof);
    }

    function testUser2Redeem() public {
        obs.finalizeEpoch(EPOCH1, root, true);

        vm.prank(user2);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;
        obs.redeem(EPOCH1, 1002, "ipfs://cid-token-1002", _meta2(), proof);
        assertEq(nft.ownerOf(1002), user2);
    }

    // --------------------------------------------
    // commitDeclaration requirements after epoch1
    // --------------------------------------------

    function testEpoch2CommitRequiresMemoWhenStaked() public {
        // finalize epoch1 => memoAlwaysPublic should be ON in your design
        obs.finalizeEpoch(EPOCH1, root, true);

        // move to epoch2 + stake gating
        obs.setActiveEpoch(EPOCH2);
        obs.setPostPolicy(3, true);

        // prepare context to quote (sourceContextId=1)
        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        // fund and stake for user1
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        obs.depositStake{value: 0.05 ether}();

        // memoURI empty should revert
        string memory memoURI = "ipfs://cid-memo-1";
        bytes32 memoHashOk = keccak256(bytes(memoURI));

        vm.prank(user1);
        vm.expectRevert();
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))), // author (AUTHOR_ONLY) 前提
            memoHashOk,
            ""
        );

        // memoHash mismatch should revert
        vm.prank(user1);
        vm.expectRevert();
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            keccak256(bytes("ipfs://different")),
            memoURI
        );

        // correct pair should pass
        vm.prank(user1);
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            memoHashOk,
            memoURI
        );
    }

    /// Fuzz: with stake + epoch2, commit must revert unless memoHash == keccak256(memoURI)
    function testFuzzEpoch2MemoHashMustMatch(
        bytes32 randomHash,
        string memory memoURI
    ) public {
        // keep memoURI reasonably sized to avoid excessive gas / memory in fuzz
        vm.assume(bytes(memoURI).length > 0);
        vm.assume(bytes(memoURI).length < 128);

        obs.finalizeEpoch(EPOCH1, root, true);
        obs.setActiveEpoch(EPOCH2);
        obs.setPostPolicy(10, true);
        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        obs.depositStake{value: 0.1 ether}();

        bytes32 correct = keccak256(bytes(memoURI));

        vm.prank(user1);
        if (randomHash != correct) {
            vm.expectRevert();
        }
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            randomHash,
            memoURI
        );
    }

    // ------------------------------------------------------------
    // Fuzz: stake maturity (10min)
    // ------------------------------------------------------------

    function testFuzzStakeNotEffectiveBefore10min(
        uint96 stakeAmount,
        uint32 warpSeconds
    ) public {
        // stakeAmount: at least 0.01 ether, keep within sane bounds
        vm.assume(stakeAmount >= 0.01 ether);
        vm.assume(stakeAmount <= 5 ether);

        // warpSeconds: strictly less than 10 minutes
        vm.assume(warpSeconds < 600);

        // epoch1 finalize => memoAlwaysPublic ON
        obs.finalizeEpoch(EPOCH1, root, true);

        // move to epoch2 and keep commit allowance tight so we can observe gating
        obs.setActiveEpoch(EPOCH2);
        obs.setPostPolicy(1, true); // base=1, stake gating on

        // create context so sourceContextId=1 exists
        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        // 1st commit succeeds without stake (allowed=1)
        string memory memo1 = "ipfs://cid-memo-1";
        bytes32 h1 = keccak256(bytes(memo1));

        vm.prank(user1);
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            h1,
            memo1
        );

        // deposit stake but do NOT wait 10min => stake not effective yet
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        obs.depositStake{value: uint256(stakeAmount)}();

        vm.warp(block.timestamp + uint256(warpSeconds));

        // 2nd commit should still revert because allowed remains 1 until maturity
        string memory memo2 = "ipfs://cid-memo-2";
        bytes32 h2 = keccak256(bytes(memo2));

        vm.prank(user1);
        vm.expectRevert(); // "post limit"
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            h2,
            memo2
        );
    }

    function testFuzzStakeBecomesEffectiveAfter10min(
        uint96 stakeAmount
    ) public {
        vm.assume(stakeAmount >= 0.01 ether);
        vm.assume(stakeAmount <= 5 ether);

        obs.finalizeEpoch(EPOCH1, root, true);
        obs.setActiveEpoch(EPOCH2);
        obs.setPostPolicy(1, true);

        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        // 1st commit (no stake needed)
        string memory memo1 = "ipfs://cid-memo-1";
        bytes32 h1 = keccak256(bytes(memo1));

        vm.prank(user1);
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            h1,
            memo1
        );

        // deposit stake then wait >=10min
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        obs.depositStake{value: uint256(stakeAmount)}();

        vm.warp(block.timestamp + 600);

        // 2nd commit should succeed now (extra>=1 for stake>=0.01)
        string memory memo2 = "ipfs://cid-memo-2";
        bytes32 h2 = keccak256(bytes(memo2));

        vm.prank(user1);
        obs.commitDeclaration(
            1,
            0,
            1,
            ContextObservatoryV0.MeaningGranularity.SUMMARY,
            ContextObservatoryV0.QuoteForm.QUOTE,
            ContextObservatoryV0.TargetSpace.YOU,
            ContextObservatoryV0.TargetTime.TIMELESS,
            bytes32(uint256(uint160(address(this)))),
            h2,
            memo2
        );
    }

    // ------------------------------------------------------------
    // Fuzz: createContext per-epoch rate limit
    // ------------------------------------------------------------

    function testFuzzCreateContextRespectsPerEpochLimit(uint32 limit) public {
        // keep limit reasonable for fuzz
        vm.assume(limit >= 1);
        vm.assume(limit <= 25);

        // set limit as author (this test contract is author)
        obs.setContextCreateLimitPerEpoch(limit);

        // activeEpochId is default 1 in your contract; this test doesn't depend on finalize.
        for (uint32 i = 0; i < limit; i++) {
            vm.prank(user1);
            obs.createContext(
                keccak256(abi.encodePacked("ctx", i)),
                "ipfs://cid-ctx"
            );
        }

        // (limit+1)th must revert
        vm.prank(user1);
        vm.expectRevert(); // "ctx rate"
        obs.createContext(keccak256("ctx-over"), "ipfs://cid-ctx-over");
    }

    function _pairRoot(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        (bytes32 x, bytes32 y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(x, y));
    }

    function _meta1() internal pure returns (string memory) {
        return '{"description":"u1","name":"t1001"}';
    }

    function _meta2() internal pure returns (string memory) {
        return '{"description":"u2","name":"t1002"}';
    }
}
