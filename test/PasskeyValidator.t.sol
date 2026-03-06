// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {ModuleType} from "../contracts/aa/interfaces/ERC7579.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {PasskeyValidator} from "../contracts/aa/validators/PasskeyValidator.sol";

import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
// webauthn-sol
import {WebAuthn} from "webauthn-sol/WebAuthn.sol";

contract PasskeyValidatorTest is Test {
    SmartAccount account;
    PasskeyValidator v;

    bytes32 internal rp;
    uint256 internal x;
    uint256 internal y;

    function setUp() public {
        // harness acts as EntryPoint
        account = new SmartAccount(address(this), address(this));
        v = new PasskeyValidator();

        // Values copied from webauthn-sol README example usage :contentReference[oaicite:7]{index=7}
        rp = bytes32(
            hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d9763"
        );
        x = 28573233055232466711029625910063034642429572463461595413086259353299906450061;
        y = 39367742072897599771788408398752356480431855827262528811857788332151452825281;

        account.installModule(
            ModuleType.VALIDATOR,
            address(v),
            abi.encode(rp, x, y, true, bytes32(0))
        );
        account.setLaneValidator(0, address(v));
    }

    function test_passkey_validation_vector() public {
        bytes32 userOpHash = bytes32(
            0xf631058a3ba1116acce12396fad0a125b5041c43f8e15723709f81aa8d5f4ccf
        );
        bytes memory challenge = abi.encode(userOpHash);

        // setUpで state 変数化した x,y を使う前提
        WebAuthn.WebAuthnAuth memory auth = WebAuthn.WebAuthnAuth({
            authenticatorData: hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000101",
            clientDataJSON: string.concat(
                '{"type":"webauthn.get","challenge":"',
                Base64.encodeURL(challenge),
                '","origin":"http://localhost:3005"}'
            ),
            challengeIndex: 23,
            typeIndex: 1,
            r: 43684192885701841787131392247364253107519555363555461570655060745499568693242,
            s: 22655632649588629308599201066602670461698485748654492451178007896016452673579
        });

        assertTrue(
            WebAuthn.verify(challenge, true, auth, x, y),
            "WebAuthn.verify failed (direct)"
        );

        PackedUserOperation memory op = PackedUserOperation({
            sender: address(account),
            nonce: 0, // laneKey=0 seq=0
            initCode: "",
            callData: hex"",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: abi.encode(auth, bytes32(0))
        });

        uint256 vd = account.validateUserOp(op, userOpHash, 0);
        assertEq(vd, 0);
    }
}
