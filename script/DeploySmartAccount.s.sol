// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {AccountFactory} from "../contracts/aa/AccountFactory.sol";
import {SmartAccount} from "../contracts/aa/SmartAccount.sol";

/// @notice User-side account deployment script.
/// After deployment, it can optionally store the user's passkey credential in the account.
contract DeploySmartAccount is Script {
    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        address userOwner = vm.envAddress("USER_OWNER");
        bytes32 salt = vm.envBytes32("SALT");

        bytes32 rpIdHash = vm.envOr("PASSKEY_RPID_HASH", bytes32(0));
        uint256 pubKeyX = vm.envOr("PASSKEY_PUBKEY_X", uint256(0));
        uint256 pubKeyY = vm.envOr("PASSKEY_PUBKEY_Y", uint256(0));
        bool requireUV = vm.envOr("PASSKEY_REQUIRE_UV", true);
        bytes32 credentialIdHashOpt = vm.envOr(
            "PASSKEY_CREDENTIAL_ID_HASH",
            bytes32(0)
        );

        vm.startBroadcast();
        address accountAddr = AccountFactory(factoryAddr).deploy(
            userOwner,
            salt
        );

        if (rpIdHash != bytes32(0) && pubKeyX != 0 && pubKeyY != 0) {
            SmartAccount(payable(accountAddr)).setPasskeyCredential(
                rpIdHash,
                pubKeyX,
                pubKeyY,
                requireUV,
                credentialIdHashOpt
            );
        }
        vm.stopBroadcast();

        console2.log("SmartAccount:", accountAddr);
    }
}
