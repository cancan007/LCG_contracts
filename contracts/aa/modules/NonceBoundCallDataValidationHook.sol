// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../interfaces/PackedUserOperation.sol";
import {IValidationHook} from "../interfaces/IValidationHook.sol";
import {ModuleType} from "../interfaces/ERC7579.sol";

/// @notice Enforces: userOp.callData must be SmartAccount.executeUserOp(..., fullNonce)
/// and fullNonce == userOp.nonce. This prevents "lane mismatch" between validation and execution.
contract NonceBoundCallDataValidationHook is IValidationHook {
    error NotAccount();
    error Disabled();
    error InvalidCallDataSelector();
    error InvalidCallDataLength();
    error NonceMismatch();

    address public immutable account;
    bool public enabled = true;

    bytes4 public constant EXECUTE_USER_OP_SELECTOR =
        bytes4(keccak256("executeUserOp(address,uint256,bytes,uint256)"));

    constructor(address _account) {
        account = _account;
    }

    modifier onlyAccount() {
        if (msg.sender != account) revert NotAccount();
        _;
    }

    function onInstall(bytes calldata) external override onlyAccount {}
    function onUninstall(bytes calldata) external override onlyAccount {}
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.HOOK;
    }

    /// @dev Service/operator controlled (not per-user).
    function setEnabled(bool v) external onlyAccount {
        enabled = v;
    }

    function preValidate(
        PackedUserOperation calldata userOp,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external view override {
        if (!enabled) revert Disabled();

        bytes calldata cd = userOp.callData;
        if (cd.length < 4) revert InvalidCallDataLength();

        bytes4 sel;
        assembly {
            sel := calldataload(cd.offset)
        }
        if (sel != EXECUTE_USER_OP_SELECTOR) revert InvalidCallDataSelector();

        bytes memory params = cd[4:];
        (
            address _to,
            uint256 _value,
            bytes memory _data,
            uint256 fullNonce
        ) = abi.decode(params, (address, uint256, bytes, uint256));

        if (fullNonce != userOp.nonce) revert NonceMismatch();
    }
}
