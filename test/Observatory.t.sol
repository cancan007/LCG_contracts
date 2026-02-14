// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {AuthorContextNFT} from "../contracts/AuthorContextNFT.sol";
import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";

contract ObservatoryTest is Test {
    AuthorContextNFT nft;
    ContextObservatoryV0 obs;

    uint256 constant EPOCH = 1;

    address user1 = address(0x1111);
    address user2 = address(0x2222);

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

        bytes32 leaf1 = keccak256(abi.encode(EPOCH, user1, uint256(1001), h1));
        bytes32 leaf2 = keccak256(abi.encode(EPOCH, user2, uint256(1002), h2));

        bytes32 root = _pairRoot(leaf1, leaf2);
        obs.finalizeEpoch(EPOCH, root, true);
    }

    function testRedeemMintsAndStoresHash() public {
        // user1 redeem
        vm.prank(user1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(
            abi.encode(EPOCH, user2, uint256(1002), keccak256(bytes(_meta2())))
        );
        obs.redeem(EPOCH, 1001, "ipfs://cid-token-1001", _meta1(), proof);

        assertEq(nft.ownerOf(1001), user1);
        assertEq(nft.metadataContentHash(1001), keccak256(bytes(_meta1())));

        // double claim should revert
        vm.prank(user1);
        vm.expectRevert();
        obs.redeem(EPOCH, 1001, "ipfs://cid-token-1001", _meta1(), proof);
    }

    function testUser2Redeem() public {
        vm.prank(user2);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(
            abi.encode(EPOCH, user1, uint256(1001), keccak256(bytes(_meta1())))
        );
        obs.redeem(EPOCH, 1002, "ipfs://cid-token-1002", _meta2(), proof);
        assertEq(nft.ownerOf(1002), user2);
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
