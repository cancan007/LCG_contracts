// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ContextObservatoryV0} from "../ContextObservatoryV0.sol";
import {AuthorContextNFT} from "../AuthorContextNFT.sol";

/// @notice Echidna harness that verifies properties across phases:
/// phase0: before finalize(epoch1)
/// phase1: after finalize(epoch1)
/// phase2: epoch2 active + staked + context prepared (commitDeclaration constraints)
contract ContextObservatoryEchidnaHarness {
    ContextObservatoryV0 public obs;
    AuthorContextNFT public nft;

    // epochs
    uint256 public constant EPOCH1 = 1;
    uint256 public constant EPOCH2 = 2;
    uint256 public constant EPOCH_NOT_FINALIZED = 999;

    // phase machine
    // 0: before finalize(epoch1)
    // 1: after finalize(epoch1)
    // 2: epoch2 prepared for commit tests
    uint8 public phase;

    // redeem test vectors
    uint256 public constant TOKEN_ID = 999;
    string public constant TOKEN_URI = "ipfs://cid-token-999";
    string public constant METADATA_JSON_CANON =
        '{"description":"echidna","name":"t999"}';

    bytes32 public immutable metadataHash;
    bytes32 public immutable leaf;

    // commitDeclaration test vectors (memo)
    string public constant MEMO_URI_OK = "ipfs://cid-memo-1";
    bytes32 public immutable memoHashOk;
    bytes32 public immutable memoHashBad;

    constructor() payable {
        nft = new AuthorContextNFT("AuthorContext", "ACTX", address(this));
        obs = new ContextObservatoryV0(address(this));
        nft.transferOwnership(address(obs));
        obs.setAuthorNft(address(nft));

        metadataHash = keccak256(bytes(METADATA_JSON_CANON));
        leaf = keccak256(
            abi.encode(EPOCH1, address(this), TOKEN_ID, metadataHash)
        );

        memoHashOk = keccak256(bytes(MEMO_URI_OK));
        memoHashBad = keccak256(bytes("ipfs://different"));

        // Do NOT finalize epoch1 here; we want Echidna to explore both pre/post finalize.
        phase = 0;
    }

    // -----------------------
    // Phase transition steps
    // -----------------------

    /// Step: finalize epoch1 (enables redeem and (in your design) activates memoAlwaysPublic).
    function echidna_step_finalize_epoch1() public returns (bool) {
        if (phase != 0) return true;

        // single leaf tree: root = leaf, proof = []
        obs.finalizeEpoch(EPOCH1, leaf, true);

        // If your ContextObservatoryV0 exposes memoAlwaysPublic(), sanity-check it.
        // If not present, this try/catch just skips.
        try obs.memoAlwaysPublic() returns (bool on) {
            if (!on) return false;
        } catch {}

        phase = 1;
        return true;
    }

    /// Step: prepare epoch2 commit tests: set active epoch, enable stake gating, stake, create a context.
    function echidna_step_prepare_epoch2_commit() public returns (bool) {
        if (phase != 1) return true;

        // If your contract uses activeEpochId, set it.
        obs.setActiveEpoch(EPOCH2);

        // Enable stake gating to make "staked user" constraints meaningful.
        obs.setPostPolicy(10, true);

        // Stake (requires echidna.yaml balance >= this amount).
        obs.depositStake{value: 0.05 ether}();

        // Create at least one context so sourceContextId=1 exists.
        obs.createContext(keccak256("ctx1"), "ipfs://cid-ctx-1");

        phase = 2;
        return true;
    }

    // -----------------------
    // Redeem properties
    // -----------------------

    /// Property: cannot redeem unless epoch is finalized (root exists + redeemEnabled).
    function echidna_redeem_requires_finalize() public returns (bool) {
        bytes32[] memory proof = new bytes32[](0);
        // epoch that is never finalized should always revert
        return _tryRedeem(EPOCH_NOT_FINALIZED, proof) == false;
    }

    /// Property: redeeming twice with the same leaf must fail on second attempt.
    function echidna_redeem_twice_fails() public returns (bool) {
        if (phase < 1) return true; // only meaningful after finalize(epoch1)

        bytes32[] memory proof = new bytes32[](0);
        bool firstOk = _tryRedeem(EPOCH1, proof);
        bool secondOk = _tryRedeem(EPOCH1, proof);

        // Require that it can succeed at least once, then must fail.
        if (!firstOk) return false;
        return secondOk == false;
    }

    /// Property: minted token must store expected metadata hash.
    function echidna_metadata_hash_is_stored() public returns (bool) {
        if (phase < 1) return true;

        bytes32[] memory proof = new bytes32[](0);
        _tryRedeem(EPOCH1, proof);

        try nft.ownerOf(TOKEN_ID) returns (address) {
            return nft.metadataContentHash(TOKEN_ID) == metadataHash;
        } catch {
            // Not minted yet: allow, because this property may run before redeem.
            return true;
        }
    }

    // -----------------------
    // commitDeclaration properties (epoch2+)
    // -----------------------

    /// epoch2+: for staked users, memoURI must be non-empty (when memo is public by policy)
    function echidna_epoch2_requires_memoURI_when_staked()
        public
        returns (bool)
    {
        if (phase != 2) return true;
        return _tryCommit(memoHashOk, "") == false;
    }

    /// epoch2+: for staked users, memoHash must match memoURI
    function echidna_epoch2_requires_memoHash_match_when_staked()
        public
        returns (bool)
    {
        if (phase != 2) return true;
        return _tryCommit(memoHashBad, MEMO_URI_OK) == false;
    }

    /// epoch2+: valid memoHash+memoURI must allow commit
    function echidna_epoch2_commit_succeeds_with_valid_memo_when_staked()
        public
        returns (bool)
    {
        if (phase != 2) return true;
        return _tryCommit(memoHashOk, MEMO_URI_OK) == true;
    }

    // -----------------------
    // Helpers
    // -----------------------

    function _tryRedeem(
        uint256 epochId,
        bytes32[] memory proof
    ) internal returns (bool) {
        try
            obs.redeem(epochId, TOKEN_ID, TOKEN_URI, METADATA_JSON_CANON, proof)
        {
            return true;
        } catch {
            return false;
        }
    }

    function _tryCommit(
        bytes32 memoHash,
        string memory memoURI
    ) internal returns (bool) {
        // NOTE:
        // - sourceContextId=1 because we created ctx1 in phase2 step.
        // - targetSpace=YOU and targetRef=author are used to satisfy AUTHOR_ONLY constraints if present.
        //   Here author == address(this).
        try
            obs.commitDeclaration(
                1, // sourceContextId
                0, // spanStart
                1, // spanEnd
                ContextObservatoryV0.MeaningGranularity.SUMMARY,
                ContextObservatoryV0.QuoteForm.QUOTE,
                ContextObservatoryV0.TargetSpace.YOU,
                ContextObservatoryV0.TargetTime.TIMELESS,
                bytes32(uint256(uint160(address(this)))), // targetRef = author
                memoHash,
                memoURI
            )
        returns (uint256, bytes32) {
            return true;
        } catch {
            return false;
        }
    }
}
