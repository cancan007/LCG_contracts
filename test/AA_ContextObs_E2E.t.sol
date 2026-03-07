// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {MockEntryPointV07} from "../contracts/aa/mocks/MockEntryPointV07.sol";
import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {PackedUserOperationLib} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {ModuleType} from "../contracts/aa/interfaces/ERC7579.sol";

import {LaneKeyNaming} from "../contracts/aa/libs/LaneKeyNaming.sol";
import {ECDSA} from "../contracts/aa/libs/ECDSA.sol";

import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";
import {ContextObservatoryPaymaster} from "../contracts/aa/modules/contextobs/ContextObservatoryPaymaster.sol";
import {ContextObservatoryLaneValidator} from "../contracts/aa/modules/contextobs/ContextObservatoryLaneValidator.sol";
import {ValidatorAggregator} from "../contracts/aa/modules/ValidatorAggregator.sol";
import {PasskeyValidatorMock} from "../contracts/aa/mocks/PasskeyValidatorMock.sol";
import {IPaymasterV07} from "../contracts/aa/interfaces/IPaymasterV07.sol";

contract AA_ContextObs_E2E is Test {
    using ECDSA for bytes32;
    using PackedUserOperationLib for PackedUserOperation;

    MockEntryPointV07 internal ep;
    SmartAccount internal account;
    ContextObservatoryV0 internal obs;
    ContextObservatoryPaymaster internal paymaster;

    PasskeyValidatorMock internal passkey;
    ValidatorAggregator internal aggCreate;
    ValidatorAggregator internal aggCommit;
    ValidatorAggregator internal aggRedeem;

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;

    bytes32 internal constant RP_ID_HASH = keccak256("example.com");
    bytes32 internal constant CRED_HASH = keccak256("credential-id");

    string internal constant INDUSTRY = "R&D";
    string internal constant SERVICE = "LCG";

    uint192 internal laneCreate;
    uint192 internal laneCommit;
    uint192 internal laneRedeem;

    bytes4 internal constant SEL_CREATE =
        bytes4(keccak256("createContext(bytes32,string)"));
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
        obs = new ContextObservatoryV0(address(this));
        account = new SmartAccount(owner, address(ep));
        passkey = new PasskeyValidatorMock();

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

        vm.startPrank(owner);
        account.setPasskeyCredential(
            RP_ID_HASH,
            uint256(CRED_HASH),
            1,
            false,
            CRED_HASH
        );
        account.installModule(ModuleType.VALIDATOR, address(passkey), "");
        vm.stopPrank();

        aggCreate = _installLane(laneCreate, SEL_CREATE);
        aggCommit = _installLane(laneCommit, SEL_COMMIT);
        aggRedeem = _installLane(laneRedeem, SEL_REDEEM);

        vm.deal(address(this), 10 ether);
        paymaster.depositFor{value: 1 ether}(address(account));
        paymaster.addDepositToEntryPoint{value: 1 ether}();
    }

    function _installLane(
        uint192 laneKey,
        bytes4 sel
    ) internal returns (ValidatorAggregator agg) {
        ContextObservatoryLaneValidator laneValidator = new ContextObservatoryLaneValidator(
                address(obs),
                laneKey,
                sel
            );
        agg = new ValidatorAggregator(owner);

        vm.startPrank(owner);
        account.installModule(ModuleType.VALIDATOR, address(laneValidator), "");
        account.installModule(ModuleType.VALIDATOR, address(agg), "");

        address[] memory validators = new address[](2);
        validators[0] = address(passkey);
        validators[1] = address(laneValidator);
        agg.upgrade(1, 0, 0, validators);

        account.setLaneValidator(laneKey, address(agg));
        vm.stopPrank();
    }

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
        bytes32 userOpHash,
        uint32 signCount
    ) internal pure returns (bytes memory) {
        return abi.encode(userOpHash, RP_ID_HASH, CRED_HASH, signCount);
    }

    function _userOpHash(
        PackedUserOperation memory op
    ) internal view returns (bytes32) {
        return ep.getUserOpHash(op);
    }

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
        op.signature = "";
        op.paymasterAndData = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh, 1);

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
        account.executeFromEntryPoint(laneCreate, address(obs), 0, inner);
        paymaster.postOp(IPaymasterV07.PostOpMode.opSucceeded, ctx, 0.01 ether);
        vm.stopPrank();
    }

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
        op.signature = "";
        op.paymasterAndData = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh, 1);

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
        op.signature = _accountSig(uoh, 1);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            validUntil,
            validAfter
        );

        vm.prank(address(ep));
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);
    }

    function test_E2E_revert_selector_mismatch() public {
        bytes memory inner = abi.encodeWithSignature("depositStake()");

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = _nonce(laneCreate, 0);
        op.callData = _buildOuterExecuteFrom(laneCreate, inner);
        op.initCode = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh, 1);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        vm.startPrank(address(ep));
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);

        try account.validateUserOp(op, uoh, 0) returns (uint256 vd) {
            assertTrue(vd != 0);
        } catch {}
        vm.stopPrank();
    }

    function test_E2E_revert_laneKey_mismatch_executeUserOp() public {
        bytes memory inner = abi.encodeWithSignature(
            "createContext(bytes32,string)",
            keccak256("ctx-lane-mismatch"),
            "ipfs://cid-lane-mismatch"
        );

        uint256 opNonce = _nonce(laneCreate, 0);
        uint256 fullNonceBad = _nonce(laneCommit, 0);

        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = opNonce;
        op.initCode = "";
        op.callData = _buildOuterExecuteUserOp(fullNonceBad, inner);
        op.signature = "";
        op.paymasterAndData = "";
        op = _fillGasFields(op);

        bytes32 uoh = _userOpHash(op);
        op.signature = _accountSig(uoh, 1);

        uint48 validUntil = uint48(block.timestamp + 3600);
        uint48 validAfter = uint48(block.timestamp);
        op.paymasterAndData = _paymasterAndData(op, validUntil, validAfter);

        vm.startPrank(address(ep));
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, uoh, 0.02 ether);

        try account.validateUserOp(op, uoh, 0) returns (uint256 vd) {
            assertTrue(vd != 0);
        } catch {}
        vm.stopPrank();
    }
}
