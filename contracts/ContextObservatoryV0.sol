// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

interface IAuthorContextNFT {
    function mint(
        address to,
        uint256 tokenId,
        string calldata uri,
        bytes32 metadataContentHash
    ) external;
}

/// @notice Minimal Context Observatory:
/// - Users commit meaning declarations (canonical on-chain keccak)
/// - Author finalizes epochs via Merkle root
/// - Users redeem (mint) AuthorContextNFT by Merkle proof
/// - relationMode toggles AUTHOR_ONLY -> OPEN
contract ContextObservatoryV0 {
    enum MeaningGranularity {
        SUMMARY,
        STORY,
        COUNTEREXAMPLE
    }
    enum QuoteForm {
        QUOTE,
        PARAPHRASE
    }
    enum TargetSpace {
        SELF,
        YOU,
        PARTICULAR,
        PUBLIC
    }
    enum TargetTime {
        PAST,
        FUTURE,
        TIMELESS
    }
    enum RelationMode {
        AUTHOR_ONLY,
        OPEN
    }

    event ContextCreated(
        uint256 indexed contextId,
        address indexed creator,
        bytes32 contentHash,
        string uri
    );

    event DeclarationCommitted(
        uint256 indexed declarationId,
        address indexed actor,
        bytes32 indexed commitHash,
        uint256 sourceContextId,
        uint32 spanStart,
        uint32 spanEnd,
        MeaningGranularity meaning,
        QuoteForm quoteForm,
        TargetSpace targetSpace,
        TargetTime targetTime,
        bytes32 targetRef,
        bytes32 memoHash
    );

    event EpochFinalized(
        uint256 indexed epochId,
        bytes32 merkleRoot,
        bool redeemEnabled
    );
    event Redeemed(
        uint256 indexed epochId,
        address indexed user,
        uint256 indexed tokenId,
        bytes32 leaf
    );
    event RelationModeChanged(RelationMode mode);

    address public immutable author;
    RelationMode public relationMode = RelationMode.AUTHOR_ONLY;

    // Context registry (optional)
    uint256 public nextContextId = 1;
    mapping(uint256 => address) public contextCreator;
    mapping(uint256 => bytes32) public contextContentHash; //NOTE: To verify whether the content is changed or not after `createContext` called
    mapping(uint256 => string) public contextURI;

    // Declarations
    uint256 public nextDeclarationId = 1;
    mapping(uint256 => bytes32) public declarationCommit;
    mapping(address => uint32) public postsUsed;

    // Posting policy
    bool public useStakeGating = false;
    uint32 public basePostLimit = 3;

    // --- stake gating with maturity delay (A: stake becomes effective after a timelock) ---
    uint256 public constant STAKE_MATURITY_DELAY = 10 minutes;

    // matured stake counts toward posting capacity
    mapping(address => uint256) public stakeMatured;

    // pending stake does NOT count until it matures
    mapping(address => uint256) public stakePending;

    // when pending stake becomes effective
    mapping(address => uint256) public stakePendingMaturesAt;

    // Epoch distribution
    struct Epoch {
        bytes32 merkleRoot;
        bool redeemEnabled;
    }
    mapping(uint256 => Epoch) public epochs;

    // Double-claim protection: epochId + leaf
    mapping(uint256 => mapping(bytes32 => bool)) public claimedLeaf;

    IAuthorContextNFT public authorNft;

    bool public openAfterFirstEpoch = true;

    // Belonged epochId of declarations (redeem is independent)
    uint256 public activeEpochId;

    // --- createContext rate limit (per epoch, per address) ---
    // 0 means "unlimited"
    uint32 public contextCreateLimitPerEpoch = 0;

    // epochId => user => contexts created in that epoch
    mapping(uint256 => mapping(address => uint32))
        public contextsCreatedInEpoch;

    event ContextCreateLimitSet(uint32 newLimit);
    event ContextCreateUsageSet(
        uint256 indexed epochId,
        address indexed user,
        uint32 used
    );

    mapping(uint256 => uint256) public spotlightContextByEpoch; // epochId => contextId

    // epochId => user => claimed
    mapping(uint256 => mapping(address => bool)) public spotlightBonusClaimed;

    event ActiveEpochSet(uint256 indexed epochId);
    event SpotlightContextSet(
        uint256 indexed epochId,
        uint256 indexed contextId
    );
    event SpotlightBonusGranted(
        uint256 indexed epochId,
        address indexed user,
        uint32 newPostsUsed
    );

    // --- memo policy ---
    uint256 public constant FIRST_FINALIZE_EPOCH_ID = 1;
    bool public memoAlwaysPublic;

    event MemoPolicyActivated(uint256 indexed epochId);

    event MemoRevealed(
        uint256 indexed epochId,
        uint256 indexed declarationId,
        address indexed actor,
        string memoURI,
        bytes32 memoURIHash
    );

    modifier onlyAuthor() {
        require(msg.sender == author, "only author");
        _;
    }

    constructor(address _author) {
        require(_author != address(0), "author=0");
        author = _author;
    }

    function setAuthorNft(address nft) external onlyAuthor {
        require(nft != address(0), "nft=0");
        authorNft = IAuthorContextNFT(nft);
    }

    function setPostPolicy(
        uint32 _baseLimit,
        bool _useStakeGating
    ) external onlyAuthor {
        basePostLimit = _baseLimit;
        useStakeGating = _useStakeGating;
    }

    function setContextCreateLimitPerEpoch(
        uint32 newLimit
    ) external onlyAuthor {
        // newLimit = 0 => unlimited
        contextCreateLimitPerEpoch = newLimit;
        emit ContextCreateLimitSet(newLimit);
    }

    // (Optional but useful) author can adjust usage counters anytime
    function setContextCreateUsage(
        uint256 epochId,
        address user,
        uint32 used
    ) external onlyAuthor {
        contextsCreatedInEpoch[epochId][user] = used;
        emit ContextCreateUsageSet(epochId, user, used);
    }

    function setOpenAfterFirstEpoch(bool v) external onlyAuthor {
        openAfterFirstEpoch = v;
    }

    function depositStake() external payable {
        _syncStake(msg.sender);

        // If there is no pending stake yet, start a new maturity window.
        if (stakePending[msg.sender] == 0) {
            stakePendingMaturesAt[msg.sender] =
                block.timestamp + STAKE_MATURITY_DELAY;
        }

        // Add to pending; becomes effective at stakePendingMaturesAt[msg.sender]
        stakePending[msg.sender] += msg.value;
    }

    function withdrawStake(uint256 amount) external {
        // Sync stake to ensure matured/pending states are up-to-date before allowing withdrawal
        _syncStake(msg.sender);

        uint256 matured = stakeMatured[msg.sender];
        uint256 pending = stakePending[msg.sender];

        // pending may already be mature in time, but we still treat it as pending storage-wise.
        // total withdrawable is matured + pending
        require(matured + pending >= amount, "insufficient stake");

        // Withdraw from pending first (doesn't affect quota anyway until matured)
        if (pending >= amount) {
            stakePending[msg.sender] = pending - amount;
        } else {
            stakePending[msg.sender] = 0;
            stakeMatured[msg.sender] = matured - (amount - pending);
        }

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function _effectiveStake(address user) internal view returns (uint256) {
        uint256 eff = stakeMatured[user];
        if (block.timestamp >= stakePendingMaturesAt[user]) {
            eff += stakePending[user];
        }
        return eff;
    }

    function _allowedPosts(address user) internal view returns (uint32) {
        if (!useStakeGating) return basePostLimit;

        // 0.01 ETH per 1 extra post (same as before, but only effective stake counts)
        uint256 eff = _effectiveStake(user);
        uint32 extra = uint32(eff / 0.01 ether);

        return basePostLimit + extra;
    }

    function _syncStake(address user) internal {
        if (
            stakePending[user] != 0 &&
            block.timestamp >= stakePendingMaturesAt[user]
        ) {
            stakeMatured[user] += stakePending[user];
            stakePending[user] = 0;
            stakePendingMaturesAt[user] = 0;
        }
    }

    function createContext(
        bytes32 contentHash,
        string calldata uri
    ) external returns (uint256 contextId) {
        uint256 ep = activeEpochId;

        // Rate limit: per epoch per address
        uint32 limit = contextCreateLimitPerEpoch;
        if (limit != 0) {
            require(contextsCreatedInEpoch[ep][msg.sender] < limit, "ctx rate");
        }

        contextId = nextContextId++;
        contextCreator[contextId] = msg.sender;
        contextContentHash[contextId] = contentHash;
        contextURI[contextId] = uri;

        unchecked {
            contextsCreatedInEpoch[ep][msg.sender] += 1;
        }

        emit ContextCreated(contextId, msg.sender, contentHash, uri);
    }

    /// @notice Canonical on-chain commit hash for a declaration.
    /// This fixes the hashing scheme (transparency + interoperability).
    /// NOTE: This is main function for commiting future protocol.
    function commitDeclaration(
        uint256 sourceContextId,
        uint32 spanStart,
        uint32 spanEnd,
        MeaningGranularity meaning,
        QuoteForm quoteForm,
        TargetSpace targetSpace,
        TargetTime targetTime,
        bytes32 targetRef,
        bytes32 memoHash,
        string calldata memoURI
    ) external returns (uint256 declarationId, bytes32 commitHash) {
        require(spanEnd >= spanStart, "bad span");
        require(
            postsUsed[msg.sender] < _allowedPosts(msg.sender),
            "post limit"
        );

        // AUTHOR_ONLY: keep minimal signal (user -> author), reduce noise.
        if (relationMode == RelationMode.AUTHOR_ONLY) {
            if (targetSpace == TargetSpace.YOU) {
                require(
                    targetRef == bytes32(uint256(uint160(author))),
                    "YOU must be author"
                );
            }
            if (targetSpace == TargetSpace.PARTICULAR)
                revert("PARTICULAR disabled in AUTHOR_ONLY");
        }

        // Sync stake to ensure posting capacity is up-to-date before checking limits and potentially granting spotlight bonus
        _syncStake(msg.sender);

        declarationId = nextDeclarationId++;

        uint256 ep = activeEpochId;

        if (memoAlwaysPublic) {
            require(bytes(memoURI).length != 0, "memoURI required");
            bytes32 memoURIHash = keccak256(bytes(memoURI));
            require(memoURIHash == memoHash, "memoURI hash mismatch");

            emit MemoRevealed(
                activeEpochId,
                declarationId,
                msg.sender,
                memoURI,
                memoURIHash
            );
        }

        commitHash = keccak256(
            abi.encode(
                bytes32("LCG_DECL_V0"),
                msg.sender,
                sourceContextId,
                spanStart,
                spanEnd,
                meaning,
                quoteForm,
                targetSpace,
                targetTime,
                targetRef,
                memoHash
            )
        );

        declarationCommit[declarationId] = commitHash;
        postsUsed[msg.sender] += 1;

        uint256 spotlight = spotlightContextByEpoch[ep];

        if (
            useStakeGating &&
            _effectiveStake(msg.sender) > 0 &&
            spotlight != 0 &&
            sourceContextId == spotlight &&
            !spotlightBonusClaimed[ep][msg.sender]
        ) {
            // “post rights +1” = Decrease postsUsed by 1 to effectively increase the quota, which is the simplest approach
            postsUsed[msg.sender] -= 1;

            spotlightBonusClaimed[ep][msg.sender] = true;
            emit SpotlightBonusGranted(ep, msg.sender, postsUsed[msg.sender]);
        }

        emit DeclarationCommitted(
            declarationId,
            msg.sender,
            commitHash,
            sourceContextId,
            spanStart,
            spanEnd,
            meaning,
            quoteForm,
            targetSpace,
            targetTime,
            targetRef,
            memoHash
        );
    }

    /// @notice Commit epoch distribution.
    /// Leaf spec:
    /// leaf = keccak256(abi.encode(epochId, user, tokenId, metadataContentHash))
    function finalizeEpoch(
        uint256 epochId,
        bytes32 merkleRoot,
        bool enableRedeemNow
    ) external onlyAuthor {
        epochs[epochId] = Epoch({
            merkleRoot: merkleRoot,
            redeemEnabled: enableRedeemNow
        });
        emit EpochFinalized(epochId, merkleRoot, enableRedeemNow);

        if (
            !memoAlwaysPublic &&
            epochId == FIRST_FINALIZE_EPOCH_ID &&
            merkleRoot != bytes32(0)
        ) {
            memoAlwaysPublic = true;
            emit MemoPolicyActivated(epochId);
        }

        if (openAfterFirstEpoch && relationMode == RelationMode.AUTHOR_ONLY) {
            relationMode = RelationMode.OPEN;
            emit RelationModeChanged(relationMode);
        }
    }

    function setRedeemEnabled(
        uint256 epochId,
        bool enabled
    ) external onlyAuthor {
        epochs[epochId].redeemEnabled = enabled;
        emit EpochFinalized(epochId, epochs[epochId].merkleRoot, enabled);
    }

    /// @notice Redeem mints AuthorContextNFT.
    /// - metadataJsonCanonical: canonical JSON string (keys sorted, no extra whitespace)
    /// - metadataContentHash is computed on-chain as keccak256(bytes(metadataJsonCanonical))
    /// - tokenURI is stored in NFT (immutable) but not part of leaf
    function redeem(
        uint256 epochId,
        uint256 tokenId,
        string calldata tokenURI,
        string calldata metadataJsonCanonical,
        bytes32[] calldata merkleProof
    ) external {
        Epoch memory e = epochs[epochId];
        require(e.redeemEnabled, "redeem disabled");
        require(e.merkleRoot != bytes32(0), "no root");
        require(address(authorNft) != address(0), "authorNft not set");

        bytes32 metadataContentHash = keccak256(bytes(metadataJsonCanonical));
        bytes32 leaf = keccak256(
            abi.encode(epochId, msg.sender, tokenId, metadataContentHash)
        );

        require(
            MerkleProof.verify(merkleProof, e.merkleRoot, leaf),
            "invalid proof"
        );
        require(!claimedLeaf[epochId][leaf], "already claimed");
        claimedLeaf[epochId][leaf] = true;

        authorNft.mint(msg.sender, tokenId, tokenURI, metadataContentHash);
        emit Redeemed(epochId, msg.sender, tokenId, leaf);
    }

    function setActiveEpoch(uint256 epochId) external onlyAuthor {
        activeEpochId = epochId;
        emit ActiveEpochSet(epochId);
    }

    function setSpotlightContext(
        uint256 epochId,
        uint256 contextId
    ) external onlyAuthor {
        spotlightContextByEpoch[epochId] = contextId;
        emit SpotlightContextSet(epochId, contextId);
    }
}
