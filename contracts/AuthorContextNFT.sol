// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract AuthorContextNFT is ERC721, Ownable {
    mapping(uint256 => string) private _uris;
    mapping(uint256 => bytes32) private _contentHashes;

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC721(name_, symbol_) Ownable(owner_) {}

    function mint(
        address to,
        uint256 tokenId,
        string calldata uri,
        bytes32 metadataContentHash_
    ) external onlyOwner {
        _safeMint(to, tokenId);
        _uris[tokenId] = uri;
        _contentHashes[tokenId] = metadataContentHash_;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        return _uris[tokenId];
    }

    function metadataContentHash(
        uint256 tokenId
    ) external view returns (bytes32) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        return _contentHashes[tokenId];
    }
}
