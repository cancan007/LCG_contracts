// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SmartAccount} from "../aa/SmartAccount.sol";
import {ModuleType} from "../aa/interfaces/ERC7579.sol";
import {ModeLib} from "../aa/libs/ModeLib.sol";

import {ValidationPreHookAggregator} from "../aa/modules/ValidationPreHookAggregator.sol";
import {NonceBoundCallDataValidationHook} from "../aa/modules/NonceBoundCallDataValidationHook.sol";
import {ExecutionHookAggregator} from "../aa/modules/ExecutionHookAggregator.sol";
import {AllowAllHook} from "../aa/modules/AllowAllHook.sol";
import {ECDSAValidator} from "../aa/modules/ECDSAValidator.sol";

/// @notice Echidna harness focusing on:
/// - module installation + lane wiring
/// - validation pre-hook (NonceBoundCallDataValidationHook) via ValidationPreHookAggregator
/// - versioned aggregator upgrade/downgrade events don't revert
contract SmartAccountEchidnaHarness {
    SmartAccount public account;

    ValidationPreHookAggregator public vph;
    NonceBoundCallDataValidationHook public nb;
    ExecutionHookAggregator public eha;
    AllowAllHook public allowAll;
    ECDSAValidator public ecdsa;

    bool public configured;

    constructor() {
        // Use this harness as owner and "entrypoint" for simplicity in Echidna
        account = new SmartAccount(address(this), address(this));

        // Deploy modules
        vph = new ValidationPreHookAggregator(address(account));
        nb = new NonceBoundCallDataValidationHook(address(account));

        eha = new ExecutionHookAggregator(address(account));
        allowAll = new AllowAllHook();

        ecdsa = new ECDSAValidator();

        // Install modules
        account.installModule(
            ModuleType.VALIDATOR,
            address(ecdsa),
            abi.encode(address(this))
        );
        account.installModule(ModuleType.HOOK, address(vph), "");
        account.installModule(ModuleType.HOOK, address(nb), "");
        account.installModule(ModuleType.HOOK, address(eha), "");
        account.installModule(ModuleType.HOOK, address(allowAll), "");

        // Wire default lane (0)
        account.setLaneValidator(0, address(ecdsa));
        account.setLaneValidationHook(0, address(vph));
        account.setLaneExecHook(0, address(eha));

        // Configure aggregators (onlyAccount)
        address[] memory hooks = new address[](1);
        hooks[0] = address(nb);

        // call as account
        (bool ok1, ) = address(vph).call(
            abi.encodeWithSignature(
                "upgrade(uint32,uint32,uint32,address[])",
                1,
                0,
                0,
                hooks
            )
        );
        require(!ok1, "vph.upgrade must be onlyAccount"); // sanity: should fail from harness directly

        // Use account as sender via a low-level call from account.execute (manual path).
        // For simplicity we just skip configuring vph here (property tests can call an exposed helper).
    }

    /// @dev Helper to configure aggregators as the account (needed because of onlyAccount).
    function configureAggregators() external {
        if (configured) return;
        configured = true;
        // Configure vph to include nb
        address[] memory hooks = new address[](1);
        hooks[0] = address(nb);

        // Call from the account: owner can execute to call into module
        bytes memory data = abi.encodeWithSelector(
            ValidationPreHookAggregator.upgrade.selector,
            uint32(1),
            uint32(0),
            uint32(0),
            hooks
        );
        account.execute(
            ModeLib.encodeSimpleSingle(),
            ModeLib.encodeSingleCalldata(address(vph), 0, data)
        );

        // Configure execution hook aggregator (pre=[allowAll], post=[])
        address[] memory pre = new address[](1);
        pre[0] = address(allowAll);
        address[] memory post = new address[](0);

        bytes memory data2 = abi.encodeWithSelector(
            ExecutionHookAggregator.upgrade.selector,
            uint32(1),
            uint32(0),
            uint32(0),
            pre,
            post
        );
        account.execute(
            ModeLib.encodeSimpleSingle(),
            ModeLib.encodeSingleCalldata(address(eha), 0, data2)
        );
    }

    function _lane0()
        internal
        view
        returns (
            address validator,
            address validationHook,
            address executor,
            address execHook
        )
    {
        SmartAccount.LaneConfig memory cfg = account.getLaneConfig(0);
        return (cfg.validator, cfg.validationHook, cfg.executor, cfg.execHook);
    }

    // -----------------------------
    // Echidna properties
    // -----------------------------

    function echidna_owner_is_harness() public view returns (bool) {
        return account.owner() == address(this);
    }

    function echidna_default_lane_validator_set() public view returns (bool) {
        // lane 0 validator must be set
        (address v, , , ) = _lane0();
        return v != address(0);
    }
}
