// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SmartAccount} from "../aa/SmartAccount.sol";
import {ModuleType} from "../aa/interfaces/ERC7579.sol";
import {PackedUserOperation} from "../aa/interfaces/PackedUserOperation.sol";
import {PasskeyValidatorMock} from "../aa/mocks/PasskeyValidatorMock.sol";

contract SmartAccountPasskeyEchidnaHarness {
    SmartAccount public account;
    PasskeyValidatorMock public passkey;

    bytes32 public constant RP_ID_HASH = keccak256("example.com");
    bytes32 public constant CRED_HASH = keccak256("credential-id");

    uint256 public lastValidationData;
    uint192 public lastLaneKey;
    uint64 public lastSeqBefore;
    uint64 public lastSeqAfter;
    bool public hasObservation;

    constructor() {
        account = new SmartAccount(address(this), address(this));
        passkey = new PasskeyValidatorMock();

        account.setPasskeyCredential(RP_ID_HASH, 1, 1, false, CRED_HASH);
        account.installModule(ModuleType.VALIDATOR, address(passkey), "");
        account.setLaneValidator(0, address(passkey));
    }

    function getUserOpHash(
        PackedUserOperation memory userOp
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    userOp.sender,
                    userOp.nonce,
                    keccak256(userOp.initCode),
                    keccak256(userOp.callData),
                    userOp.accountGasLimits,
                    userOp.preVerificationGas,
                    userOp.gasFees,
                    keccak256(userOp.paymasterAndData)
                )
            );
    }

    function act_validate(
        bytes calldata callData,
        uint192 laneKey,
        uint32 signCount,
        bool correctChallenge,
        bool correctRp,
        bool correctCred
    ) external {
        uint64 seq = account.nonceSequence(laneKey);
        uint256 fullNonce = (uint256(laneKey) << 64) | uint256(seq);

        PackedUserOperation memory op = PackedUserOperation({
            sender: address(account),
            nonce: fullNonce,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 h = getUserOpHash(op);
        bytes32 challenge = correctChallenge
            ? h
            : keccak256(abi.encodePacked(h, "bad"));
        bytes32 rp = correctRp ? RP_ID_HASH : keccak256("evil.com");
        bytes32 cred = correctCred ? CRED_HASH : keccak256("other-credential");
        op.signature = abi.encode(challenge, rp, cred, signCount);

        lastLaneKey = laneKey;
        lastSeqBefore = seq;
        lastValidationData = account.validateUserOp(op, h, 0);
        lastSeqAfter = account.nonceSequence(laneKey);
        hasObservation = true;
    }

    function echidna_owner_is_harness() external view returns (bool) {
        return account.owner() == address(this);
    }

    function echidna_nonce_increments_on_success()
        external
        view
        returns (bool)
    {
        if (!hasObservation) return true;
        if (lastValidationData == 0) return lastSeqAfter == lastSeqBefore + 1;
        return true;
    }

    function echidna_nonce_stable_on_failure() external view returns (bool) {
        if (!hasObservation) return true;
        if (lastValidationData == 1) return lastSeqAfter == lastSeqBefore;
        return true;
    }
}
