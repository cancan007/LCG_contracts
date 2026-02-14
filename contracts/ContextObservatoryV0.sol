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
    mapping(uint256 => bytes32) public contextContentHash;
    mapping(uint256 => string) public contextURI;

    // Declarations
    uint256 public nextDeclarationId = 1;
    mapping(uint256 => bytes32) public declarationCommit;
    mapping(address => uint32) public postsUsed;

    // Posting policy
    bool public useStakeGating = false;
    uint32 public basePostLimit = 3;
    mapping(address => uint256) public stake;

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

    modifier onlyAuthor() {
        require(msg.sender == author, "only author");
        _;
    }

    constructor(address _author, address _authorNft) {
        require(_author != address(0), "author=0");
        author = _author;
        require(_authorNft != address(0), "nft=0");
        authorNft = IAuthorContextNFT(_authorNft);
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

    function setOpenAfterFirstEpoch(bool v) external onlyAuthor {
        openAfterFirstEpoch = v;
    }

    // Optional stake to increase posting capacity
    function depositStake() external payable {
        stake[msg.sender] += msg.value;
    }

    function withdrawStake(uint256 amount) external {
        require(stake[msg.sender] >= amount, "insufficient stake");
        stake[msg.sender] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function _allowedPosts(address user) internal view returns (uint32) {
        if (!useStakeGating) return basePostLimit;
        uint32 extra = uint32(stake[user] / 0.01 ether);
        return basePostLimit + extra;
    }

    function createContext(
        bytes32 contentHash,
        string calldata uri
    ) external returns (uint256 contextId) {
        contextId = nextContextId++;
        contextCreator[contextId] = msg.sender;
        contextContentHash[contextId] = contentHash;
        contextURI[contextId] = uri;
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
        bytes32 memoHash
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

        declarationId = nextDeclarationId++;

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
}
