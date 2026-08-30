// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {PackedUserOperation} from "../contracts/aa/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "../contracts/aa/interfaces/IEntryPoint.sol";
import {ModuleType, IHook} from "../contracts/aa/interfaces/ERC7579.sol";
import {ModeLib} from "../contracts/aa/libs/ModeLib.sol";

import {SimpleExecutor} from "../contracts/aa/modules/SimpleExecutor.sol";
import {ContextObservatoryExecutor} from "../contracts/aa/modules/contextobs/ContextObservatoryExecutor.sol";

contract EPStub is IEntryPoint {
    function getUserOpHash(
        PackedUserOperation calldata
    ) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function depositTo(address) external payable override {}
    function withdrawTo(address payable, uint256) external override {}
    function balanceOf(address) external view override returns (uint256) {
        return 0;
    }
}

contract MockTarget {
    address public lastSender;
    uint256 public lastValue;
    uint256 public counter;

    function ping(uint256 x) external payable returns (uint256) {
        lastSender = msg.sender;
        lastValue = msg.value;
        counter += x;
        return counter;
    }

    function boom() external pure {
        revert("boom");
    }
}

contract RecordingHook is IHook {
    uint256 public preCount;
    uint256 public postCount;
    address public lastMsgSender;
    uint192 public lastLaneKey;
    address public lastTarget;

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}
    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == ModuleType.HOOK;
    }

    function preCheck(
        address msgSender,
        uint256,
        bytes calldata msgData
    ) external override returns (bytes memory) {
        preCount++;
        lastMsgSender = msgSender;
        (uint192 laneKey, address to, , ) = abi.decode(
            msgData,
            (uint192, address, uint256, bytes)
        );
        lastLaneKey = laneKey;
        lastTarget = to;
        return abi.encode(preCount);
    }

    function postCheck(bytes calldata) external override {
        postCount++;
    }
}

/// @notice Covers the ERC-7579 executor flow:
///   executor module -> account.executeFromExecutor(mode, executionCalldata) -> target
/// The target always sees msg.sender == SmartAccount, never the executor module.
contract SmartAccount_Executor_Test is Test {
    uint192 internal constant LANE = 7;

    SmartAccount public account;
    EPStub public ep;

    SimpleExecutor public simpleExec;
    ContextObservatoryExecutor public coExec;
    MockTarget public target;
    RecordingHook public hook;

    function setUp() public {
        ep = new EPStub();
        account = new SmartAccount(address(this), address(ep));

        target = new MockTarget();
        simpleExec = new SimpleExecutor();
        coExec = new ContextObservatoryExecutor(
            address(target),
            MockTarget.ping.selector
        );
        hook = new RecordingHook();

        account.installModule(ModuleType.EXECUTOR, address(simpleExec), "");
        account.installModule(ModuleType.HOOK, address(hook), "");

        // exec hook only on LANE (default lane stays unhooked)
        account.setLaneExecHook(LANE, address(hook));

        vm.deal(address(account), 10 ether);
    }

    function _single(
        address to,
        uint256 value,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return ModeLib.encodeSingleCalldata(to, value, data);
    }

    // -----------------------------
    // execute(mode, executionCalldata)
    // -----------------------------

    function test_execute_by_owner_single() public {
        bytes[] memory ret = account.execute(
            ModeLib.encodeSimpleSingle(),
            _single(address(target), 0, abi.encodeCall(MockTarget.ping, (5)))
        );

        assertEq(ret.length, 1);
        assertEq(abi.decode(ret[0], (uint256)), 5);
        assertEq(target.lastSender(), address(account));
        assertEq(hook.preCount(), 0); // default lane has no exec hook
    }

    function test_execute_forwards_value() public {
        account.execute(
            ModeLib.encodeSimpleSingle(),
            _single(address(target), 1 ether, abi.encodeCall(MockTarget.ping, (1)))
        );

        assertEq(target.lastValue(), 1 ether);
        assertEq(address(target).balance, 1 ether);
    }

    function test_execute_revert_not_authorized() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SmartAccount.NotAuthorized.selector);
        account.execute(
            ModeLib.encodeSimpleSingle(),
            _single(address(target), 0, abi.encodeCall(MockTarget.ping, (1)))
        );
    }

    function test_execute_revert_unsupported_calltype() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SmartAccount.UnsupportedCallType.selector,
                ModeLib.CALLTYPE_BATCH
            )
        );
        account.execute(bytes32(ModeLib.CALLTYPE_BATCH), "");
    }

    function test_execute_bubbles_target_revert() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "boom"));
        account.execute(
            ModeLib.encodeSimpleSingle(),
            _single(address(target), 0, abi.encodeCall(MockTarget.boom, ()))
        );
    }

    // -----------------------------
    // executeFromExecutor
    // -----------------------------

    function test_executeFromExecutor_keeps_account_as_msg_sender() public {
        bytes[] memory ret = simpleExec.executeOn(
            address(account),
            address(target),
            0,
            abi.encodeCall(MockTarget.ping, (3))
        );

        assertEq(abi.decode(ret[0], (uint256)), 3);
        // the target must see the account, NOT the executor module
        assertEq(target.lastSender(), address(account));
        assertTrue(target.lastSender() != address(simpleExec));
    }

    function test_executeFromExecutor_revert_when_module_not_installed() public {
        SimpleExecutor rogue = new SimpleExecutor();

        vm.expectRevert(SmartAccount.ModuleNotInstalled.selector);
        rogue.executeOn(
            address(account),
            address(target),
            0,
            abi.encodeCall(MockTarget.ping, (1))
        );
    }

    function test_executeFromExecutor_revert_when_called_by_owner_directly()
        public
    {
        // owner is not an installed executor module
        vm.expectRevert(SmartAccount.ModuleNotInstalled.selector);
        account.executeFromExecutor(
            ModeLib.encodeSimpleSingle(),
            _single(address(target), 0, abi.encodeCall(MockTarget.ping, (1)))
        );
    }

    // -----------------------------
    // laneKey mode
    // -----------------------------

    function test_executeOnWithLane_routes_lane_and_runs_exec_hook() public {
        simpleExec.executeOnWithLane(
            address(account),
            LANE,
            address(target),
            0,
            abi.encodeCall(MockTarget.ping, (2))
        );

        assertEq(target.lastSender(), address(account));
        assertEq(hook.preCount(), 1);
        assertEq(hook.postCount(), 1);
        assertEq(uint256(hook.lastLaneKey()), uint256(LANE));
        assertEq(hook.lastTarget(), address(target));
        // preCheck sees the module that initiated the call
        assertEq(hook.lastMsgSender(), address(simpleExec));
    }

    function test_lane_mode_is_detected_from_mode_selector() public pure {
        assertTrue(ModeLib.isLane(ModeLib.encodeLaneSingle()));
        assertTrue(!ModeLib.isLane(ModeLib.encodeSimpleSingle()));
        assertEq(
            ModeLib.getCallType(ModeLib.encodeLaneSingle()),
            ModeLib.CALLTYPE_SINGLE
        );
    }

    // -----------------------------
    // ContextObservatoryExecutor policy
    // -----------------------------

    function test_contextObsExecutor_allows_configured_selector() public {
        account.installModule(ModuleType.EXECUTOR, address(coExec), "");

        coExec.executeOn(
            address(account),
            0,
            abi.encodeCall(MockTarget.ping, (4))
        );

        assertEq(target.lastSender(), address(account));
        assertEq(target.counter(), 4);
    }

    function test_contextObsExecutor_rejects_other_selector() public {
        account.installModule(ModuleType.EXECUTOR, address(coExec), "");

        vm.expectRevert(ContextObservatoryExecutor.NotAllowedCall.selector);
        coExec.executeOn(
            address(account),
            0,
            abi.encodeCall(MockTarget.boom, ())
        );
    }
}
