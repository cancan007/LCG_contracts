// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../../interfaces/PackedUserOperation.sol";
import {IValidator, ModuleType} from "../../interfaces/ERC7579.sol";

/// @notice Shared, stateless policy validator for a specific ContextObservatory lane.
/// @dev Authentication is handled by another validator (e.g. PasskeyValidator) in the same aggregator.
///      This module only enforces lane / target / selector policy.
contract ContextObservatoryLaneValidator is IValidator {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    error BadLane();
    error NotAllowedCall();

    bytes4 internal constant EXEC_FROM_ENTRYPOINT_SELECTOR =
        bytes4(
            keccak256("executeFromEntryPoint(uint192,address,uint256,bytes)")
        );
    bytes4 internal constant EXEC_USEROP_SELECTOR =
        bytes4(keccak256("executeUserOp(address,uint256,bytes,uint256)"));

    address public immutable contextObservatory;
    uint192 public immutable expectedLaneKey;
    bytes4 public immutable allowedSelector;

    constructor(
        address _contextObservatory,
        uint192 _expectedLaneKey,
        bytes4 _allowedSelector
    ) {
        contextObservatory = _contextObservatory;
        expectedLaneKey = _expectedLaneKey;
        allowedSelector = _allowedSelector;
    }

    function onInstall(bytes calldata) external pure override {}
    function onUninstall(bytes calldata) external pure override {}

    function isModuleType(
        uint256 typeId
    ) external pure override returns (bool) {
        return typeId == ModuleType.VALIDATOR;
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32
    ) external view override returns (uint256 validationData) {
        uint192 laneKey = uint192(uint256(userOp.nonce) >> 64);
        if (laneKey != expectedLaneKey) revert BadLane();

        bytes calldata cd = userOp.callData;
        if (cd.length < 4) revert NotAllowedCall();
        bytes4 outerSel = bytes4(cd[0:4]);

        address target;
        bytes memory inner;

        if (outerSel == EXEC_FROM_ENTRYPOINT_SELECTOR) {
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
        } else if (outerSel == EXEC_USEROP_SELECTOR) {
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

        return 0;
    }

    function isValidSignatureWithSender(
        address,
        bytes32,
        bytes calldata
    ) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }

    function _first4(bytes memory b) internal pure returns (bytes4 sel) {
        if (b.length < 4) revert NotAllowedCall();
        assembly {
            sel := mload(add(b, 32))
        }
    }
}
