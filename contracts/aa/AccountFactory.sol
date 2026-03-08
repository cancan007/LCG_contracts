// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SmartAccount} from "./SmartAccount.sol";
import {ModuleType} from "./interfaces/ERC7579.sol";

contract AccountFactory {
    struct BootstrapLane {
        uint192 laneKey;
        address validator;
        address validationHook;
        address executor;
        address execHook;
        bool enabled;
    }

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event BootstrapLaneConfigured(
        uint192 indexed laneKey,
        address indexed validator,
        address indexed executor,
        address validationHook,
        address execHook,
        bool enabled
    );
    event AccountDeployed(
        address indexed account,
        address indexed owner,
        bytes32 salt
    );

    error NotOwner();

    address public owner;
    address public immutable entryPoint;

    mapping(uint192 => BootstrapLane) public bootstrapLanes;
    mapping(uint192 => bool) private _bootstrapLaneRegistered;
    uint192[] private _bootstrapLaneKeys;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _entryPoint) {
        owner = msg.sender;
        entryPoint = _entryPoint;
    }

    function setOwner(address newOwner) external onlyOwner {
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function configureBootstrapLane(
        uint192 laneKey,
        address validator,
        address validationHook,
        address executor,
        address execHook,
        bool enabled
    ) external onlyOwner {
        if (!_bootstrapLaneRegistered[laneKey]) {
            _bootstrapLaneRegistered[laneKey] = true;
            _bootstrapLaneKeys.push(laneKey);
        }

        bootstrapLanes[laneKey] = BootstrapLane({
            laneKey: laneKey,
            validator: validator,
            validationHook: validationHook,
            executor: executor,
            execHook: execHook,
            enabled: enabled
        });

        emit BootstrapLaneConfigured(
            laneKey,
            validator,
            executor,
            validationHook,
            execHook,
            enabled
        );
    }

    function getBootstrapLaneKeys() external view returns (uint192[] memory) {
        return _bootstrapLaneKeys;
    }

    function getAddress(
        address /* userOwner */,
        bytes32 salt
    ) external view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(SmartAccount).creationCode,
            abi.encode(address(this), entryPoint)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(initCode)
            )
        );

        return address(uint160(uint256(hash)));
    }

    function deploy(
        address userOwner,
        bytes32 salt
    ) external returns (address account) {
        bytes memory initCode = abi.encodePacked(
            type(SmartAccount).creationCode,
            abi.encode(address(this), entryPoint)
        );

        assembly {
            account := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(account) {
                revert(0, 0)
            }
        }

        SmartAccount acct = SmartAccount(payable(account));

        uint256 len = _bootstrapLaneKeys.length;
        for (uint256 i = 0; i < len; i++) {
            uint192 laneKey = _bootstrapLaneKeys[i];
            BootstrapLane memory lane = bootstrapLanes[laneKey];
            if (!lane.enabled) continue;

            if (lane.validator != address(0)) {
                acct.installModule(ModuleType.VALIDATOR, lane.validator, "");
                acct.setLaneValidator(laneKey, lane.validator);
            }
            if (lane.validationHook != address(0)) {
                acct.installModule(ModuleType.HOOK, lane.validationHook, "");
                acct.setLaneValidationHook(laneKey, lane.validationHook);
            }
            if (lane.executor != address(0)) {
                acct.installModule(ModuleType.EXECUTOR, lane.executor, "");
                acct.setLaneExecutor(laneKey, lane.executor);
            }
            if (lane.execHook != address(0)) {
                acct.installModule(ModuleType.HOOK, lane.execHook, "");
                acct.setLaneExecHook(laneKey, lane.execHook);
            }
        }

        acct.setOwner(userOwner);
        emit AccountDeployed(account, userOwner, salt);
    }
}
