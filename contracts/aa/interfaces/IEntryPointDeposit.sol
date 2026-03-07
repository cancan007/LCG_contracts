// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal EntryPoint subset used for deposit bookkeeping (v0.7-style).
interface IEntryPointDeposit {
    function depositTo(address account) external payable;
    function withdrawTo(
        address payable withdrawAddress,
        uint256 amount
    ) external;
    function balanceOf(address account) external view returns (uint256);
}
