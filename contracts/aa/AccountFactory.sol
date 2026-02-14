// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SmartAccount} from "./SmartAccount.sol";

/// @notice Simple CREATE2 factory for SmartAccount deployments.
contract AccountFactory {
    event AccountDeployed(
        address indexed account,
        address indexed owner,
        bytes32 salt
    );

    address public immutable entryPoint;
    address public immutable defaultValidator;

    constructor(address _entryPoint, address _defaultValidator) {
        entryPoint = _entryPoint;
        defaultValidator = _defaultValidator;
    }

    function getAddress(
        address owner,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(SmartAccount).creationCode,
            abi.encode(owner, entryPoint, defaultValidator, abi.encode(owner)) // validator init: owner
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(initCode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    function deploy(
        address owner,
        bytes32 salt
    ) external returns (address account) {
        bytes memory initCode = abi.encodePacked(
            type(SmartAccount).creationCode,
            abi.encode(owner, entryPoint, defaultValidator, abi.encode(owner))
        );

        assembly {
            account := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(account) {
                revert(0, 0)
            }
        }
        emit AccountDeployed(account, owner, salt);
    }
}
