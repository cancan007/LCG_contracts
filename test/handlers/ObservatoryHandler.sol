// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ContextObservatoryV0} from "../../contracts/ContextObservatoryV0.sol";

/// @notice Handler for invariants: calls into ContextObservatoryV0 using try/catch and records any unexpected successes.
contract ObservatoryHandler {
    ContextObservatoryV0 public obs;

    // Invariant flags
    bool public badCommitSucceeded;
    bool public redeemWithoutFinalizeSucceeded;
    bool public contextLimitExceededSucceeded;

    // Params
    uint256 public constant EPOCH_NOT_FINALIZED = 999;
    uint256 public constant TOKEN_ID = 4242;

    string public constant TOKEN_URI = "ipfs://cid-token-4242";
    string public constant META_CANON = '{"description":"inv","name":"t4242"}';

    // For commit tests
    string public memoURI;
    bytes32 public memoHashOk;

    constructor(ContextObservatoryV0 _obs) {
        obs = _obs;
        memoURI = "ipfs://cid-memo-inv-1";
        memoHashOk = keccak256(bytes(memoURI));
    }

    /// Try a commit with provided (memoHash, memoURI). If it succeeds unexpectedly for mismatch cases, flag it.
    function commitMaybe(bytes32 memoHash, string calldata _memoURI) external {
        // We want to detect if a mismatch ever succeeds.
        bool mismatch = (keccak256(bytes(_memoURI)) != memoHash);

        try
            obs.commitDeclaration(
                1, // sourceContextId (prepared in invariant setUp)
                0,
                1,
                ContextObservatoryV0.MeaningGranularity.SUMMARY,
                ContextObservatoryV0.QuoteForm.QUOTE,
                ContextObservatoryV0.TargetSpace.YOU,
                ContextObservatoryV0.TargetTime.TIMELESS,
                bytes32(uint256(uint160(address(this)))), // targetRef=author (author == test contract in setup)
                memoHash,
                _memoURI
            )
        returns (uint256, bytes32) {
            if (mismatch) badCommitSucceeded = true;
        } catch {
            // ignore revert
        }
    }

    /// Convenience: attempt a "good" commit.
    function commitGood() external {
        this.commitMaybe(memoHashOk, memoURI);
    }

    /// Attempt redeem on an epoch that is never finalized; if it ever succeeds, flag it.
    function redeemNeverFinalized(bytes32[] calldata proof) external {
        try
            obs.redeem(
                EPOCH_NOT_FINALIZED,
                TOKEN_ID,
                TOKEN_URI,
                META_CANON,
                proof
            )
        {
            redeemWithoutFinalizeSucceeded = true;
        } catch {
            // expected to revert
        }
    }

    function act_setContextLimit(uint32 newLimit) external {
        // handler is called by the invariant contract (author), so onlyAuthor should pass
        obs.setContextCreateLimitPerEpoch(newLimit);
    }

    function act_createContext(bytes32 contentHash) external {
        uint256 ep = obs.activeEpochId();
        uint32 limit = obs.contextCreateLimitPerEpoch();
        uint32 used = obs.contextsCreatedInEpoch(ep, address(this));

        // If already at/over limit, this call MUST revert.
        bool shouldRevert = (limit != 0 && used >= limit);

        try obs.createContext(contentHash, TOKEN_URI) returns (uint256) {
            if (shouldRevert) {
                contextLimitExceededSucceeded = true;
            }
        } catch {
            // ok
        }
    }
}
