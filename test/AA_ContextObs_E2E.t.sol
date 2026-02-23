// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {MockEntryPointV07} from "../contracts/aa/mocks/MockEntryPointV07.sol";
import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {PackedUserOperationLib} from "../contracts/aa/interfaces/PackedUserOperation.sol";

import {LaneKeyNaming} from "../contracts/aa/libs/LaneKeyNaming.sol";
import {ECDSA} from "../contracts/aa/libs/ECDSA.sol";

import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";
import {ContextObservatoryPaymaster} from "../contracts/aa/modules/contextobs/ContextObservatoryPaymaster.sol";
import {ContextObservatoryLaneValidator} from "../contracts/aa/modules/contextobs/ContextObservatoryLaneValidator.sol";
import {ContextObservatoryExecutor} from "../contracts/aa/modules/contextobs/ContextObservatoryExecutor.sol";
import {IPaymasterV07} from "../contracts/aa/interfaces/IPaymasterV07.sol";

/// @notice E2E-ish tests without a full EntryPoint.handleOps:
/// We impersonate EntryPoint (MockEntryPointV07) and call:
/// 1) Paymaster.validatePaymasterUserOp
/// 2) SmartAccount.validateUserOp
/// 3) SmartAccount.executeFromEntryPoint / executeUserOp
/// 4) Paymaster.postOp
contract AA_ContextObs_E2E is Test {
    using ECDSA for bytes32;
    using PackedUserOperationLib for PackedUserOperation;

    MockEntryPointV07 internal ep;
    SmartAccount internal account;
    ContextObservatoryV0 internal obs;

    ContextObservatoryPaymaster internal paymaster;

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;

    // lane naming
    string internal constant INDUSTRY = "R&D";
    string internal constant SERVICE = "LCG";

    uint192 internal laneCreate;
    uint192 internal laneCommit;
    uint192 internal laneRedeem;

    bytes4 internal constant SEL_CREATE =
        bytes4(keccak256("createContext(bytes32,string)"));
    // NOTE: must match your contract signature exactly
    bytes4 internal constant SEL_COMMIT =
        bytes4(
            keccak256(
                "commitDeclaration(uint256,uint32,uint32,uint8,uint8,uint8,uint8,bytes32,bytes32,string)"
            )
        );
    bytes4 internal constant SEL_REDEEM =
        bytes4(keccak256("redeem(uint256,uint256,string,string,bytes32[])"));

    function setUp() public {
        owner = vm.addr(OWNER_PK);

        ep = new MockEntryPointV07();
        obs = new ContextObservatoryV0(address(this)); // author = test contract
        account = new SmartAccount(owner, address(ep));

        // derive lanes (industry/service/process)
        laneCreate = LaneKeyNaming.laneKey(
            INDUSTRY,
            SERVICE,
            "internal/createContext"
        );
        laneCommit = LaneKeyNaming.laneKey(
            INDUSTRY,
            SERVICE,
            "internal/commitDeclaration"
        );
        laneRedeem = LaneKeyNaming.laneKey(
            INDUSTRY,
            SERVICE,
            "internal/redeem"
        );

        paymaster = new ContextObservatoryPaymaster(
            address(ep),
            address(obs),
            INDUSTRY,
            SERVICE
        );

        // Deploy per-lane validator+executor and install into SmartAccount
        _installLane(laneCreate, SEL_CREATE);
        _installLane(laneCommit, SEL_COMMIT);
        _installLane(laneRedeem, SEL_REDEEM);

        // fund paymaster balance for this account (sponsored balance)
        vm.deal(address(this), 10 ether);
        paymaster.depositFor{value: 1 ether}(address(account)); // user gas budget in paymaster

        // Fund EntryPoint deposit (mock has bookkeeping only, but paymaster enforces msg.sender == entryPoint)
        // This call exists on paymaster for real EP integration; for mock it's fine to call.
        paymaster.addDepositToEntryPoint{value: 1 ether}();
    }

    function _installLane(uint192 laneKey, bytes4 sel) internal {
        ContextObservatoryLaneValidator v = new ContextObservatoryLaneValidator();
        ContextObservatoryExecutor e = new ContextObservatoryExecutor();

        vm.startPrank(owner);
        account.installModule(
            1,
            address(v),
            abi.encode(address(obs), laneKey, sel)
        ); // ModuleType.VALIDATOR == 1
        account.installModule(2, address(e), abi.encode(address(obs), sel)); // ModuleType.EXECUTOR  == 2
        account.setLaneValidator(laneKey, address(v));
        account.setLaneExecutor(laneKey, address(e));
        vm.stopPrank();
    }

    // -------------------------
    // Helpers to build UserOps
    // -------------------------

    function _nonce(
        uint192 laneKey,
        uint64 seq
    ) internal pure returns (uint256) {
        return (uint256(laneKey) << 64) | uint256(seq);
    }

    function _buildOuterExecuteFrom(
        uint192 laneKey,
        bytes memory inner
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "executeFromEntryPoint(uint192,address,uint256,bytes)",
                laneKey,
                address(obs),
                uint256(0),
                inner
            );
    }

    function _buildOuterExecuteUserOp(
        uint256 fullNonce,
        bytes memory inner
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "executeUserOp(address,uint256,bytes,uint256)",
                address(obs),
                uint256(0),
                inner,
                fullNonce
            );
    }

    function _sign(
        bytes32 digest,
        uint256 pk
    ) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fillGasFields(
        PackedUserOperation memory op
    ) internal pure returns (PackedUserOperation memory) {
        // Keep these small but non-zero.
        uint256 callGas = 200_000;
        uint256 verifGas = 400_000;
        op.accountGasLimits = bytes32((verifGas << 128) | callGas);

        op.preVerificationGas = 50_000;

        uint256 maxFee = 1 gwei;
        uint256 maxPrio = 1 gwei;
        op.gasFees = bytes32((maxPrio << 128) | maxFee);

        return op;
    }

    function _paymasterAndData(
        PackedUserOperation memory op,
        uint48 validUntil,
        uint48 validAfter
    ) internal view returns (bytes memory) {
        // build paymasterAndData = paymaster || validUntil || validAfter || sig
        bytes32 reqHash = paymaster.getPaymasterRequestHash(
            op,
            validUntil,
            validAfter
        );
        bytes32 digest = reqHash.toEthSignedMessageHash();
        bytes memory sig = _sign(digest, OWNER_PK);

        return
            abi.encodePacked(address(paymaster), validUntil, validAfter, sig);
    }

    function _accountSig(
        bytes32 userOpHash
    ) internal pure returns (bytes memory) {
        return _sign(userOpHash.toEthSignedMessageHash(), OWNER_PK);
    }

    function _userOpHash(
        PackedUserOperation memory op
    ) internal view returns (bytes32) {
        return ep.getUserOpHash(op);
    }

    // -------------------------
    // Tests
    // -------------------------

    /// 1) Success path using executeFromEntryPoint + owner-signed paymasterAndData
    function test_E2E_success_executeFromEntryPoint() public {
        bytes memory inner = abi.encodeWithSignature(
            "createContext(bytes32,string)",
            keccak256("ctx"),
            "ipfs://cid"
        );

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = _nonce(laneCreate, 0);
        op.initCode = "";
        op.callData = _buildOuterExecuteFrom(laneCreate, inner);
        op.signature = ""; // filled later
        op.paymasterAndData = ""; // filled later
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        // 4337-ish flow (impersonate EntryPoint)
        vm.startPrank(address(ep));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(
            op,
            uoh,
            0.02 ether
        );
        uint256 vd = account.validateUserOp(op, uoh, 0);
        assertEq(vd, 0);

        // execute
        account.executeFromEntryPoint(laneCreate, address(obs), 0, inner);

        // postOp refund simulation (use smaller actual cost than reserved)
        paymaster.postOp(IPaymasterV07.PostOpMode.opSucceeded, ctx, 0.01 ether);
        vm.stopPrank();
    }

    /// 2) Success path using executeUserOp + owner-signed paymasterAndData
    function test_E2E_success_executeUserOp() public {
        bytes memory inner = abi.encodeWithSignature(
            "createContext(bytes32,string)",
            keccak256("ctx2"),
            "ipfs://cid2"
        );

        uint256 fullNonce = _nonce(laneCreate, 0);

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = fullNonce;
        op.initCode = "";
        op.callData = _buildOuterExecuteUserOp(fullNonce, inner);
        op.signature = ""; // filled later
        op.paymasterAndData = ""; // filled later
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        vm.startPrank(address(ep));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(
            op,
            uoh,
            0.02 ether
        );
        uint256 vd = account.validateUserOp(op, uoh, 0);
        assertEq(vd, 0);

        account.executeUserOp(address(obs), 0, inner, fullNonce);

        paymaster.postOp(IPaymasterV07.PostOpMode.opSucceeded, ctx, 0.01 ether);
        vm.stopPrank();
    }

    /// 3) Reject: missing paymaster signature (third party cannot burn balance)
    function test_E2E_revert_missing_paymaster_sig() public {
        bytes memory inner = abi.encodeWithSignature(
            "createContext(bytes32,string)",
            keccak256("ctx3"),
            "ipfs://cid3"
        );

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = _nonce(laneCreate, 0);
        op.callData = _buildOuterExecuteFrom(laneCreate, inner);
        op.initCode = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh);

        // paymasterAndData WITHOUT signature (just address + validity)
        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            validUntil,
            validAfter
        );

        vm.prank(address(ep));
        vm.expectRevert(); // BadSignature() / parse fail depending on implementation
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);
    }

    /// 4) Reject: selector mismatch (attempt to call non-allowed function)
    function test_E2E_revert_selector_mismatch() public {
        // inner calldata with WRONG selector (e.g., depositStake() does not exist on observatory)
        bytes memory inner = abi.encodeWithSignature("depositStake()");

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = _nonce(laneCreate, 0);
        op.callData = _buildOuterExecuteFrom(laneCreate, inner);
        op.initCode = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        vm.startPrank(address(ep));
        // Paymaster should reject because selector is not one of {create, commit, redeem}
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);

        // Even if paymaster were bypassed, validator must reject.
        // Some implementations revert (e.g., NotAllowedCall), others return SIG_VALIDATION_FAILED.
        try account.validateUserOp(op, uoh, 0) returns (uint256 vd) {
            assertTrue(vd != 0);
        } catch {
            // ok (revert is also a valid rejection)
        }
        vm.stopPrank();
    }

    /// 5) Reject: laneKey mismatch between userOp.nonce (top 192 bits) and executeUserOp(fullNonce)
    function test_E2E_revert_laneKey_mismatch_executeUserOp() public {
        bytes memory inner = abi.encodeWithSignature(
            "createContext(bytes32,string)",
            keccak256("ctx-lane-mismatch"),
            "ipfs://cid-lane-mismatch"
        );

        // userOp.nonce carries laneCreate
        uint256 opNonce = _nonce(laneCreate, 0);

        // fullNonce carries a DIFFERENT lane (use laneCommit)
        uint256 fullNonceBad = _nonce(laneCommit, 0);

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = opNonce;
        op.initCode = "";
        op.callData = _buildOuterExecuteUserOp(fullNonceBad, inner);
        op.signature = ""; // filled later
        op.paymasterAndData = ""; // filled later
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        vm.startPrank(address(ep));
        // Paymaster should reject because laneKey extracted from fullNonce differs from laneKey in userOp.nonce (or not in allowlist)
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);

        // Validator should also fail (either revert or return SIG_VALIDATION_FAILED)
        // We accept either behavior; if it doesn't revert, it must return non-zero.
        try account.validateUserOp(op, uoh, 0) returns (uint256 vd) {
            assertTrue(vd != 0);
        } catch {
            // ok
        }
        vm.stopPrank();
    }
}
