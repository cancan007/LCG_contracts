// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutor} from "../interfaces/ERC7579.sol";

/// @notice Executor module that forwards execution from the account.
/// IMPORTANT: In production, scope permissions (targets/selectors/spend limits).
contract SimpleExecutor is IExecutor {
    address public account;

    error OnlyAccount();

    function onInstall(bytes calldata data) external override {
        (uint192 laneKey, bytes memory init) = abi.decode(
            data,
            (uint192, bytes)
        );
        account = msg.sender;
    }

    function onUninstall(bytes calldata) external override {
        account = address(0);
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory ret) {
        if (msg.sender != account) revert OnlyAccount();
        (bool ok, bytes memory out) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(out, 0x20), mload(out))
            }
        }
        return out;
    }
}
