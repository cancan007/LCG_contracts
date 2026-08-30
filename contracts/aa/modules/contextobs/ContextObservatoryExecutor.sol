// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IExecutor,
    IAccountExecution,
    ModuleType
} from "../../interfaces/ERC7579.sol";
import {ModeLib} from "../../libs/ModeLib.sol";

/// @notice Stateless executor module that restricts execution to a single
///         (contextObservatory, allowedSelector) pair.
///
/// ERC-7579 executor pattern:
///   External caller → ContextObservatoryExecutor.executeOn(account, value, callData)
///     → validates target == contextObservatory && selector == allowedSelector
///     → IAccountExecution(account).executeFromExecutor(mode, executionCalldata)
///     → account executes: msg.sender to target = SmartAccount (not this executor)
///
/// The account must have installed this executor via installModule(EXECUTOR,...).
contract ContextObservatoryExecutor is IExecutor {
    error NotAllowedCall();

    address public immutable contextObservatory;
    bytes4 public immutable allowedSelector;

    constructor(address _contextObservatory, bytes4 _allowedSelector) {
        contextObservatory = _contextObservatory;
        allowedSelector = _allowedSelector;
    }

    function onInstall(bytes calldata) external pure override {}
    function onUninstall(bytes calldata) external pure override {}

    function isModuleType(
        uint256 typeId
    ) external pure override returns (bool) {
        return typeId == ModuleType.EXECUTOR;
    }

    /// @notice Trigger execution on `account` for the allowed call.
    /// @dev Validates target and selector before delegating to the account.
    ///      The account's executeFromExecutor() checks that this contract is installed,
    ///      so only accounts that have opted in can be called.
    function executeOn(
        address account,
        uint256 value,
        bytes calldata callData
    ) external returns (bytes[] memory returnData) {
        if (callData.length < 4) revert NotAllowedCall();
        if (bytes4(callData[0:4]) != allowedSelector) revert NotAllowedCall();

        bytes memory execCalldata = ModeLib.encodeSingleCalldata(
            contextObservatory,
            value,
            callData
        );
        return
            IAccountExecution(account).executeFromExecutor(
                ModeLib.encodeSimpleSingle(),
                execCalldata
            );
    }
}
