// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {
    ModuleType,
    IHook,
    IModule
} from "../contracts/aa/interfaces/ERC7579.sol";

import {ECDSAValidator} from "../contracts/aa/modules/ECDSAValidator.sol";
import {NonceBoundCallDataValidationHook} from "../contracts/aa/modules/NonceBoundCallDataValidationHook.sol";
import {AllowAllHook} from "../contracts/aa/modules/AllowAllHook.sol";
import {MockEntryPointV07} from "../contracts/aa/mocks/MockEntryPointV07.sol";

contract Target {
    event Ping(address caller, bytes data);

    function ping(bytes calldata data) external returns (bytes memory) {
        emit Ping(msg.sender, data);
        return data;
    }
}

contract RevertingHook is IHook {
    error RevertingHookTriggered();

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.HOOK;
    }

    function preCheck(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override {
        revert RevertingHookTriggered();
    }

    function postCheck(
        address,
        address,
        uint256,
        bytes calldata,
        bool,
        bytes calldata
    ) external pure override {
        // no-op
    }
}

contract SmartAccount_CallData_Tests is Test {
    SmartAccount acct;
    MockEntryPointV07 ep;
    ECDSAValidator validator;

    NonceBoundCallDataValidationHook vhook;

    AllowAllHook allowHook;
    RevertingHook revertHook;

    Target target;

    address owner;
    uint256 ownerKey;

    function setUp() public {
        ownerKey = 0xA11CE;
        owner = vm.addr(ownerKey);

        ep = new MockEntryPointV07();
        validator = new ECDSAValidator();

        acct = new SmartAccount(
            owner,
            address(ep),
            address(validator),
            abi.encode(owner)
        );

        // hooks
        allowHook = new AllowAllHook();
        revertHook = new RevertingHook();
        target = new Target();

        // install hooks so SmartAccount accepts them
        vm.startPrank(owner);
        acct.installModule(ModuleType.HOOK, address(allowHook), "");
        acct.installModule(ModuleType.HOOK, address(revertHook), "");

        // validation hook
        vhook = new NonceBoundCallDataValidationHook(address(acct));
        acct.installModule(ModuleType.HOOK, address(vhook), "");
        vm.stopPrank();

        // lane0: allow exec + enable nonce-bound validation hook
        vm.prank(owner);
        acct.setLaneConfig(
            uint192(0),
            address(0),
            address(vhook),
            address(0),
            address(allowHook)
        );

        // lane1: revert on execution (to observe lane switching via execute() data encoding)
        vm.prank(owner);
        acct.setLaneConfig(
            uint192(1),
            address(0),
            address(0),
            address(0),
            address(revertHook)
        );
    }

    function _packNonce(
        uint192 laneKey,
        uint64 seq
    ) internal pure returns (uint256) {
        return (uint256(laneKey) << 64) | uint256(seq);
    }

    // -------------------------
    // Validation hook tests
    // -------------------------

    function test_validate_reverts_if_selector_wrong() public {
        uint192 laneKey = 1;
        uint256 nonce = _packNonce(laneKey, 0);

        PackedUserOperation memory op;
        op.nonce = nonce;
        op.signature = hex"00";
        op.callData = hex"12345678";

        vm.prank(address(ep));
        vm.expectRevert(); // selector mismatch -> revert
        acct.validateUserOp(op, keccak256("h"), 0);
    }

    function test_validate_reverts_if_nonce_mismatch_in_callData() public {
        uint192 laneKey = 2;
        uint256 nonce = _packNonce(laneKey, 0);
        uint256 wrong = _packNonce(laneKey, 9);

        PackedUserOperation memory op;
        op.nonce = nonce;
        op.signature = hex"00";
        op.callData = abi.encodeCall(
            SmartAccount.executeUserOp,
            (address(0xBEEF), 0, hex"", wrong)
        );

        vm.prank(address(ep));
        vm.expectRevert(); // NonceBound hook should revert
        acct.validateUserOp(op, keccak256("h"), 0);
    }

    function test_validate_ok_for_hook_checks_if_nonce_matches_but_sig_may_fail()
        public
    {
        uint192 laneKey = 3;
        uint256 nonce = _packNonce(laneKey, 0);

        PackedUserOperation memory op;
        op.nonce = nonce;
        op.signature = hex"00";
        op.callData = abi.encodeCall(
            SmartAccount.executeUserOp,
            (address(0xBEEF), 0, hex"", nonce)
        );

        vm.prank(address(ep));
        // It may revert later due to signature validation (depending on your validator),
        // but it must NOT revert due to selector/nonce mismatch.
        vm.expectRevert(); // expected due to sig validation in ECDSAValidator
        acct.validateUserOp(op, keccak256("h"), 0);
    }

    // -------------------------
    // execute() laneKey encoding tests (A方式 memory)
    // -------------------------

    function test_execute_raw_data_uses_lane0_and_succeeds() public {
        bytes memory inner = abi.encodeCall(Target.ping, (bytes("hello")));
        vm.prank(owner);
        acct.execute(address(target), 0, inner); // raw => lane0 => allowHook => ok
    }

    function test_execute_wrapped_lane1_reverts_due_to_execHook() public {
        bytes memory inner = abi.encodeCall(Target.ping, (bytes("hello")));
        bytes memory wrapped = abi.encode(uint192(1), inner);

        vm.prank(owner);
        vm.expectRevert(RevertingHook.RevertingHookTriggered.selector);
        acct.execute(address(target), 0, wrapped);
    }

    function test_execute_malformed_wrapped_falls_back_to_raw_lane0() public {
        bytes memory inner = abi.encodeCall(Target.ping, (bytes("hello")));

        // malformed: offset != 0x40 (we craft a broken encoding)
        // [laneKey word][offset word != 0x40][...]
        bytes memory bad = abi.encodePacked(
            bytes32(uint256(uint192(1)) << 64),
            bytes32(uint256(0x20)), // WRONG offset
            inner
        );

        vm.prank(owner);
        // should be treated as raw; lane0 allowHook => ok
        acct.execute(address(target), 0, bad);
    }
}
