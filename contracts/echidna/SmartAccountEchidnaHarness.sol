// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SmartAccount} from "../aa/SmartAccount.sol";
import {ECDSAValidator} from "../aa/modules/ECDSAValidator.sol";
import {AllowAllHook} from "../aa/modules/AllowAllHook.sol";
import {SimpleExecutor} from "../aa/modules/SimpleExecutor.sol";
import {MockEntryPointV07} from "../aa/mocks/MockEntryPointV07.sol";
import {ModuleType} from "../aa/interfaces/ERC7579.sol";

/// @notice An attacker helper that tries to call owner-gated functions.
contract Attacker {
    function tryExecute(
        address account,
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool ok) {
        (ok, ) = account.call(
            abi.encodeWithSignature(
                "execute(address,uint256,bytes)",
                to,
                value,
                data
            )
        );
    }

    function tryInstallModule(
        address account,
        uint256 moduleType,
        address module,
        bytes calldata data
    ) external returns (bool ok) {
        (ok, ) = account.call(
            abi.encodeWithSignature(
                "installModule(uint256,address,bytes)",
                moduleType,
                module,
                data
            )
        );
    }

    function trySetLaneConfig(
        address account,
        uint192 laneKey,
        address validator,
        address validationHook,
        address executor,
        address execHook
    ) external returns (bool ok) {
        (ok, ) = account.call(
            abi.encodeWithSignature(
                "setLaneConfig(uint192,address,address,address,address)",
                laneKey,
                validator,
                validationHook,
                executor,
                execHook
            )
        );
    }
}

/// @notice Echidna properties for the AA scaffold.
/// Focus: access control invariants (attacker should not gain power).
contract SmartAccountEchidnaHarness {
    MockEntryPointV07 ep;
    ECDSAValidator validator;
    AllowAllHook execHook;
    SimpleExecutor execModule;
    SmartAccount account;
    Attacker attacker;

    constructor() {
        ep = new MockEntryPointV07();
        validator = new ECDSAValidator();
        execHook = new AllowAllHook();
        execModule = new SimpleExecutor();

        // Owner is this harness contract.
        account = new SmartAccount(
            address(this),
            address(ep),
            address(validator),
            abi.encode(address(this))
        );

        // Install modules as owner.
        account.installModule(ModuleType.HOOK, address(execHook), "");
        account.installModule(ModuleType.EXECUTOR, address(execModule), "");

        // Default lane (laneKey=0)
        account.setLaneConfig(
            uint192(0),
            address(validator),
            address(0),
            address(execModule),
            address(execHook)
        );

        attacker = new Attacker();
    }

    // --- Properties ---

    function echidna_attacker_cannot_execute() public returns (bool) {
        bool ok = attacker.tryExecute(
            address(account),
            address(this),
            0,
            abi.encodeWithSignature("noop()")
        );
        return ok == false;
    }

    function echidna_attacker_cannot_install_module() public returns (bool) {
        bool ok = attacker.tryInstallModule(
            address(account),
            ModuleType.HOOK,
            address(execHook),
            ""
        );
        return ok == false;
    }

    function echidna_attacker_cannot_set_lane_config() public returns (bool) {
        bool ok = attacker.trySetLaneConfig(
            address(account),
            uint192(1),
            address(validator),
            address(0),
            address(execModule),
            address(execHook)
        );
        return ok == false;
    }

    function noop() external pure {}
}
