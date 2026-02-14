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

    function tryInstallPlugin(
        address account,
        address plugin,
        bytes calldata data
    ) external returns (bool ok) {
        (ok, ) = account.call(
            abi.encodeWithSignature(
                "installPlugin(address,bytes)",
                plugin,
                data
            )
        );
    }
}

/// @notice Echidna properties for the AA scaffold.
/// Focus: access control invariants (attacker should not gain power).
contract SmartAccountEchidnaHarness {
    MockEntryPointV07 ep;
    ECDSAValidator validator;
    AllowAllHook hook;
    SimpleExecutor execModule;
    SmartAccount account;
    Attacker attacker;

    constructor() {
        ep = new MockEntryPointV07();
        validator = new ECDSAValidator();
        hook = new AllowAllHook();
        execModule = new SimpleExecutor();

        // Owner is this harness contract.
        account = new SmartAccount(
            address(this),
            address(ep),
            address(validator),
            abi.encode(address(this))
        );

        // Install hook/executor as owner.
        account.installModule(ModuleType.HOOK, address(hook), "");
        account.installModule(
            ModuleType.EXECUTOR, //NOTE: this should be laneKey, not ModuleSolidEnum value
            address(execModule),
            abi.encode(uint192(0), abi.encode(uint192(0), ""))
        );

        attacker = new Attacker();
    }

    // --- Properties ---

    /// @notice Attacker cannot execute arbitrary calls.
    function echidna_attacker_cannot_execute() public returns (bool) {
        bool ok = attacker.tryExecute(
            address(account),
            address(this),
            0,
            abi.encodeWithSignature("noop()")
        );
        return ok == false;
    }

    /// @notice Attacker cannot install modules.
    function echidna_attacker_cannot_install_module() public returns (bool) {
        bool ok = attacker.tryInstallModule(
            address(account),
            ModuleType.HOOK,
            address(hook),
            ""
        );
        return ok == false;
    }

    /// @notice Attacker cannot install plugins.
    function echidna_attacker_cannot_install_plugin() public returns (bool) {
        bool ok = attacker.tryInstallPlugin(
            address(account),
            address(hook),
            ""
        );
        return ok == false;
    }

    function noop() external pure {}
}
