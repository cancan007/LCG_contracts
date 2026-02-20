// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "../contracts/aa/interfaces/IEntryPoint.sol";
import {ModuleType, IValidator} from "../contracts/aa/interfaces/ERC7579.sol";

import {ValidationPreHookAggregator} from "../contracts/aa/modules/ValidationPreHookAggregator.sol";
import {NonceBoundCallDataValidationHook} from "../contracts/aa/modules/NonceBoundCallDataValidationHook.sol";

contract MockEntryPoint is IEntryPoint {
    function getUserOpHash(
        PackedUserOperation calldata
    ) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function depositTo(address) external payable override {}
    function withdrawTo(address payable, uint256) external override {}
    function balanceOf(address) external view override returns (uint256) {
        return 0;
    }
}

contract AlwaysPassValidator is IValidator {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.VALIDATOR;
    }
    function validateUserOp(
        PackedUserOperation calldata,
        bytes32
    ) external override returns (uint256) {
        return 0;
    }
    function isValidSignatureWithSender(
        address,
        bytes32,
        bytes calldata
    ) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract SmartAccount_CallData_Test is Test {
    SmartAccount public account;
    MockEntryPoint public ep;

    ValidationPreHookAggregator public vph;
    NonceBoundCallDataValidationHook public nb;
    AlwaysPassValidator public validator;

    function setUp() public {
        ep = new MockEntryPoint();
        account = new SmartAccount(address(this), address(ep));

        // modules
        validator = new AlwaysPassValidator();
        vph = new ValidationPreHookAggregator(address(account));
        nb = new NonceBoundCallDataValidationHook(address(account));

        // install modules into the account
        account.installModule(ModuleType.VALIDATOR, address(validator), "");
        account.installModule(ModuleType.HOOK, address(vph), "");
        account.installModule(ModuleType.HOOK, address(nb), "");

        // set default lane config
        account.setLaneValidator(0, address(validator));
        account.setLaneValidationHook(0, address(vph));

        // configure vph (onlyAccount)
        vm.prank(address(account));
        address[] memory hooks = new address[](1);
        hooks[0] = address(nb);
        vph.upgrade(1, 0, 0, hooks);
    }

    function _makeUserOp(
        bytes memory callData,
        uint192 laneKey,
        uint64 seq
    ) internal view returns (PackedUserOperation memory op) {
        uint256 nonce = (uint256(laneKey) << 64) | uint256(seq);
        op.sender = address(account);
        op.nonce = nonce;
        op.initCode = "";
        op.callData = callData;
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        op.paymasterAndData = "";
        op.signature = hex"01"; // ignored by AlwaysPassValidator
    }

    function test_preHook_reverts_on_selector_mismatch() public {
        // wrong selector
        bytes memory callData = abi.encodeWithSignature("notExecuteUserOp()");
        PackedUserOperation memory op = _makeUserOp(callData, 0, 0);

        vm.prank(address(ep));
        vm.expectRevert(); // InvalidCallDataSelector()
        account.validateUserOp(op, keccak256("h"), 0);
    }

    function test_preHook_reverts_on_nonce_mismatch() public {
        // fullNonce inside calldata differs from userOp.nonce
        uint256 otherNonce = (uint256(0) << 64) | uint256(999);
        bytes memory callData = abi.encodeWithSelector(
            account.executeUserOp.selector,
            address(0xBEEF),
            0,
            bytes(""),
            otherNonce
        );
        PackedUserOperation memory op = _makeUserOp(callData, 0, 0);

        vm.prank(address(ep));
        vm.expectRevert(); // NonceMismatch()
        account.validateUserOp(op, keccak256("h"), 0);
    }

    function test_nonce_sequence_updates_only_after_success() public {
        // correct fullNonce inside calldata (matches userOp.nonce)
        uint256 nonce = (uint256(0) << 64) | uint256(0);
        bytes memory callData = abi.encodeWithSelector(
            account.executeUserOp.selector,
            address(0xBEEF),
            0,
            bytes(""),
            nonce
        );
        PackedUserOperation memory op = _makeUserOp(callData, 0, 0);

        assertEq(account.nonceSequence(0), 0);

        vm.prank(address(ep));
        account.validateUserOp(op, keccak256("h"), 0);

        assertEq(account.nonceSequence(0), 1);
    }
}
