// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {ModuleType} from "../contracts/aa/interfaces/ERC7579.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {MockEntryPointV07} from "../contracts/aa/mocks/MockEntryPointV07.sol";

import {PasskeyValidatorMock} from "../contracts/aa/mocks/PasskeyValidatorMock.sol";

/// @notice Foundry fuzz tests for "Passkey-style" validation.
///
/// These tests focus on the AA/security invariants that should remain true regardless of
/// whether the underlying signer is an EOA (secp256k1) or a Passkey (WebAuthn / P-256):
/// - The approval is bound to the exact action (callData etc.) via userOpHash.
/// - Lane nonce sequencing only increments on successful validation.
/// - Wrong challenge / RP / credential / signCount => signature failure (no revert).
contract SmartAccountPasskeyFuzzTest is Test {
    MockEntryPointV07 internal ep;
    SmartAccount internal account;
    PasskeyValidatorMock internal passkey;

    bytes32 internal constant RP_ID_HASH = keccak256("example.com");
    bytes32 internal constant CRED_HASH = keccak256("credential-id");

    function setUp() public {
        ep = new MockEntryPointV07();
        account = new SmartAccount(address(this), address(ep));
        passkey = new PasskeyValidatorMock();

        account.installModule(
            ModuleType.VALIDATOR,
            address(passkey),
            abi.encode(RP_ID_HASH, CRED_HASH)
        );
        account.setLaneValidator(0, address(passkey));
    }

    function _mkOp(
        bytes memory callData,
        uint192 laneKey,
        uint64 seq,
        bytes memory sig
    ) internal view returns (PackedUserOperation memory op, bytes32 h) {
        uint256 fullNonce = (uint256(laneKey) << 64) | uint256(seq);
        op = PackedUserOperation({
            sender: address(account),
            nonce: fullNonce,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
        h = ep.getUserOpHash(op);
    }

    function testFuzz_passkey_success_increments_nonce(
        bytes memory callData,
        uint32 signCount
    ) public {
        signCount = uint32(bound(signCount, 1, type(uint32).max));

        uint64 seq = account.nonceSequence(0);
        (PackedUserOperation memory op, bytes32 h) = _mkOp(
            callData,
            0,
            seq,
            ""
        );
        op.signature = abi.encode(h, RP_ID_HASH, CRED_HASH, signCount);

        vm.prank(address(ep));
        uint256 vd = account.validateUserOp(op, h, 0);

        assertEq(vd, 0, "expected validation success");
        assertEq(
            account.nonceSequence(0),
            seq + 1,
            "nonce must increment on success"
        );
    }

    function testFuzz_wrong_challenge_fails_and_nonce_stable(
        bytes memory callData,
        bytes32 wrongChallenge,
        uint32 signCount
    ) public {
        signCount = uint32(bound(signCount, 1, type(uint32).max));

        uint64 seq = account.nonceSequence(0);
        (PackedUserOperation memory op, bytes32 h) = _mkOp(
            callData,
            0,
            seq,
            ""
        );

        // Ensure it's wrong
        if (wrongChallenge == h)
            wrongChallenge = keccak256(abi.encodePacked(h, "x"));

        op.signature = abi.encode(
            wrongChallenge,
            RP_ID_HASH,
            CRED_HASH,
            signCount
        );

        vm.prank(address(ep));
        uint256 vd = account.validateUserOp(op, h, 0);

        assertEq(vd, 1, "expected SIG_VALIDATION_FAILED");
        assertEq(
            account.nonceSequence(0),
            seq,
            "nonce must not change on failure"
        );
    }

    function testFuzz_wrong_rp_or_cred_fails(
        bytes memory callData,
        bool wrongRp,
        bool wrongCred,
        uint32 signCount
    ) public {
        signCount = uint32(bound(signCount, 1, type(uint32).max));

        uint64 seq = account.nonceSequence(0);
        (PackedUserOperation memory op, bytes32 h) = _mkOp(
            callData,
            0,
            seq,
            ""
        );

        bytes32 rp = wrongRp ? keccak256("evil.com") : RP_ID_HASH;
        bytes32 cred = wrongCred ? keccak256("other-credential") : CRED_HASH;

        op.signature = abi.encode(h, rp, cred, signCount);

        vm.prank(address(ep));
        uint256 vd = account.validateUserOp(op, h, 0);

        if (wrongRp || wrongCred) {
            assertEq(vd, 1, "expected failure when rp/cred mismatch");
            assertEq(
                account.nonceSequence(0),
                seq,
                "nonce must not change on failure"
            );
        } else {
            assertEq(vd, 0, "expected success when rp/cred correct");
            assertEq(
                account.nonceSequence(0),
                seq + 1,
                "nonce must increment on success"
            );
        }
    }

    function test_passkey_signCount_must_increase() public {
        bytes memory callData = hex"deadbeef";

        // 1) succeed with signCount=10
        uint64 seq0 = account.nonceSequence(0);
        (PackedUserOperation memory op0, bytes32 h0) = _mkOp(
            callData,
            0,
            seq0,
            ""
        );
        op0.signature = abi.encode(h0, RP_ID_HASH, CRED_HASH, uint32(10));

        vm.prank(address(ep));
        uint256 vd0 = account.validateUserOp(op0, h0, 0);
        assertEq(vd0, 0);

        // 2) Next op must use seq1; try reusing signCount=10 => validator fails (even though challenge matches)
        uint64 seq1 = account.nonceSequence(0);
        (PackedUserOperation memory op1, bytes32 h1) = _mkOp(
            callData,
            0,
            seq1,
            ""
        );
        op1.signature = abi.encode(h1, RP_ID_HASH, CRED_HASH, uint32(10));

        vm.prank(address(ep));
        uint256 vd1 = account.validateUserOp(op1, h1, 0);
        assertEq(vd1, 1, "expected failure when signCount not increasing");
        assertEq(
            account.nonceSequence(0),
            seq1,
            "nonce must not change on failure"
        );

        // 3) signCount=11 => success
        op1.signature = abi.encode(h1, RP_ID_HASH, CRED_HASH, uint32(11));
        vm.prank(address(ep));
        uint256 vd2 = account.validateUserOp(op1, h1, 0);
        assertEq(vd2, 0);
        assertEq(account.nonceSequence(0), seq1 + 1);
    }
}
