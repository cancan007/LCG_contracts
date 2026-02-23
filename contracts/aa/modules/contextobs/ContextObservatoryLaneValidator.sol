// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../../interfaces/PackedUserOperation.sol";
import {IValidator, IModule} from "../../interfaces/ERC7579.sol";
import {ECDSA} from "../../libs/ECDSA.sol";

interface ISmartAccountOwnerView {
    function owner() external view returns (address);
}

/// @notice Lane-specific validator for ContextObservatory actions.
/// - checks laneKey (top 192 bits of userOp.nonce)
/// - checks callData targets ContextObservatory + exact selector
/// - verifies signature by SmartAccount.owner()
///
/// Note: Paymaster already enforces the same target+selector and charges gas.
/// Validator is defense-in-depth + keeps account validation consistent.
contract ContextObservatoryLaneValidator is IValidator {
    using ECDSA for bytes32;

    error NotInstalled();
    error BadLane();
    error NotAllowedCall();
    error BadSignature();

    bool public installed;
    address public smartAccount;
    address public contextObservatory;
    uint192 public expectedLaneKey;
    bytes4 public allowedSelector;

    function _first4(bytes memory b) internal pure returns (bytes4 sel) {
        if (b.length < 4) revert NotAllowedCall();
        assembly {
            sel := mload(add(b, 32))
        }
    }

    function onInstall(bytes calldata data) external override {
        // initData = abi.encode(contextObservatory, expectedLaneKey, allowedSelector)
        (contextObservatory, expectedLaneKey, allowedSelector) = abi.decode(
            data,
            (address, uint192, bytes4)
        );
        installed = true;
        smartAccount = msg.sender;
    }

    function onUninstall(bytes calldata) external override {
        installed = false;
    }

    function isModuleType(uint256 typeId) external pure returns (bool) {
        // ModuleType.VALIDATOR == 1 in your ERC7579.sol
        return typeId == 1;
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external view override returns (uint256 validationData) {
        if (!installed || msg.sender != smartAccount) revert NotInstalled();

        uint192 laneKey = uint192(uint256(userOp.nonce) >> 64);
        if (laneKey != expectedLaneKey) revert BadLane();

        // Require outer call is either:
        // 1) executeFromEntryPoint(uint192,address,uint256,bytes)
        // 2) executeUserOp(address,uint256,bytes,uint256)
        bytes calldata cd = userOp.callData;
        if (cd.length < 4) revert NotAllowedCall();
        bytes4 outerSel = bytes4(cd[0:4]);

        address target;
        bytes memory inner;

        if (
            outerSel ==
            bytes4(
                keccak256(
                    "executeFromEntryPoint(uint192,address,uint256,bytes)"
                )
            )
        ) {
            (
                uint192 laneKeyArg,
                address to,
                uint256 value,
                bytes memory data
            ) = abi.decode(cd[4:], (uint192, address, uint256, bytes));
            if (laneKeyArg != laneKey) revert BadLane();
            if (value != 0) revert NotAllowedCall();
            target = to;
            inner = data;
        } else if (
            outerSel ==
            bytes4(keccak256("executeUserOp(address,uint256,bytes,uint256)"))
        ) {
            (
                address to,
                uint256 value,
                bytes memory data,
                uint256 fullNonce
            ) = abi.decode(cd[4:], (address, uint256, bytes, uint256));
            if (value != 0) revert NotAllowedCall();
            uint192 laneFromFull = uint192(fullNonce >> 64);
            if (laneFromFull != laneKey) revert BadLane();
            target = to;
            inner = data;
        } else {
            revert NotAllowedCall();
        }

        if (target != contextObservatory) revert NotAllowedCall();
        if (inner.length < 4) revert NotAllowedCall();
        if (_first4(inner) != allowedSelector) revert NotAllowedCall();

        // Signature by SmartAccount.owner()
        address signer = ISmartAccountOwnerView(userOp.sender).owner();
        address recovered = userOpHash.toEthSignedMessageHash().recover(
            userOp.signature
        );
        if (recovered != signer) return 1; // SIG_VALIDATION_FAILED

        return 0;
    }

    // ERC-1271 style signature check with explicit sender.
    // Some ERC-7579 validator interfaces require this.
    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4) {
        if (!installed) revert NotInstalled();
        // sender should be the SmartAccount
        address signer = ISmartAccountOwnerView(sender).owner();
        address recovered = hash.toEthSignedMessageHash().recover(signature);
        return recovered == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
