// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {SmartAccount} from "../contracts/aa/SmartAccount.sol";
import {ModuleType} from "../contracts/aa/interfaces/ERC7579.sol";

import {ContextObservatoryPaymaster} from "../contracts/aa/modules/contextobs/ContextObservatoryPaymaster.sol";
import {ContextObservatoryLaneValidator} from "../contracts/aa/modules/contextobs/ContextObservatoryLaneValidator.sol";
import {ContextObservatoryExecutor} from "../contracts/aa/modules/contextobs/ContextObservatoryExecutor.sol";
import {LaneKeyNaming} from "../contracts/aa/libs/LaneKeyNaming.sol";

/// @notice Deploy and wire ContextObservatory modules (Paymaster + 3 lanes) into an existing SmartAccount.
/// Environment variables:
/// - ENTRYPOINT: EntryPoint v0.7 address
/// - ACCOUNT: SmartAccount address (owned by DEPLOYER key)
/// - OBSERVATORY: ContextObservatoryV0 address
/// - INDUSTRY: "R&D" (default)
/// - SERVICE: "LCG" (default)
/// - USER_BALANCE_WEI: paymaster internal balance to deposit for ACCOUNT (default 0.05 ether)
/// - EP_DEPOSIT_WEI: amount to deposit into EntryPoint for paymaster (default 0.2 ether)
/// - USE_EXECUTE_USEROP: "true" to emit sample calldata for executeUserOp, otherwise executeFromEntryPoint (default false)
contract DeployContextObservatoryPaymaster is Script {
    function run() external {
        address entryPoint = vm.envAddress("ENTRYPOINT");
        address accountAddr = vm.envAddress("ACCOUNT");
        address observatory = vm.envAddress("OBSERVATORY");

        string memory industry = vm.envOr("INDUSTRY", string("R&D"));
        string memory service = vm.envOr("SERVICE", string("LCG"));

        uint256 userBal = vm.envOr("USER_BALANCE_WEI", uint256(0.05 ether));
        uint256 epDep = vm.envOr("EP_DEPOSIT_WEI", uint256(0.2 ether));
        bool useExecuteUserOp = vm.envOr("USE_EXECUTE_USEROP", false);

        vm.startBroadcast();

        // 1) Deploy Paymaster
        ContextObservatoryPaymaster paymaster = new ContextObservatoryPaymaster(
            entryPoint,
            observatory,
            industry,
            service
        );

        // 2) Compute laneKeys and selectors
        uint192 laneCreate = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/createContext"
        );
        uint192 laneCommit = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/commitDeclaration"
        );
        uint192 laneRedeem = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/redeem"
        );

        bytes4 selCreate = bytes4(keccak256("createContext(bytes32,string)"));
        bytes4 selCommit = bytes4(
            keccak256(
                "commitDeclaration(uint256,uint32,uint32,uint8,uint8,uint8,uint8,bytes32,bytes32,string)"
            )
        );
        bytes4 selRedeem = bytes4(
            keccak256("redeem(uint256,uint256,string,string,bytes32[])")
        );

        // 3) Deploy per-lane validator + executor
        ContextObservatoryLaneValidator vCreate = new ContextObservatoryLaneValidator();
        ContextObservatoryLaneValidator vCommit = new ContextObservatoryLaneValidator();
        ContextObservatoryLaneValidator vRedeem = new ContextObservatoryLaneValidator();

        ContextObservatoryExecutor eCreate = new ContextObservatoryExecutor();
        ContextObservatoryExecutor eCommit = new ContextObservatoryExecutor();
        ContextObservatoryExecutor eRedeem = new ContextObservatoryExecutor();

        // 4) Install modules into SmartAccount and wire lanes
        SmartAccount acct = SmartAccount(payable(accountAddr));

        // install validators
        acct.installModule(
            ModuleType.VALIDATOR,
            address(vCreate),
            abi.encode(observatory, laneCreate, selCreate)
        );
        acct.installModule(
            ModuleType.VALIDATOR,
            address(vCommit),
            abi.encode(observatory, laneCommit, selCommit)
        );
        acct.installModule(
            ModuleType.VALIDATOR,
            address(vRedeem),
            abi.encode(observatory, laneRedeem, selRedeem)
        );

        // install executors
        acct.installModule(
            ModuleType.EXECUTOR,
            address(eCreate),
            abi.encode(observatory, selCreate)
        );
        acct.installModule(
            ModuleType.EXECUTOR,
            address(eCommit),
            abi.encode(observatory, selCommit)
        );
        acct.installModule(
            ModuleType.EXECUTOR,
            address(eRedeem),
            abi.encode(observatory, selRedeem)
        );

        // wire lane configs
        acct.setLaneValidator(laneCreate, address(vCreate));
        acct.setLaneExecutor(laneCreate, address(eCreate));

        acct.setLaneValidator(laneCommit, address(vCommit));
        acct.setLaneExecutor(laneCommit, address(eCommit));

        acct.setLaneValidator(laneRedeem, address(vRedeem));
        acct.setLaneExecutor(laneRedeem, address(eRedeem));

        // 5) Fund paymaster
        paymaster.addDepositToEntryPoint{value: epDep}();
        paymaster.depositFor{value: userBal}(accountAddr);

        // 6) Emit sample outer callData for clients/bundlers (toggle by USE_EXECUTE_USEROP)
        {
            // Example inner calldata (dummy values)
            bytes32 exContentHash = keccak256("example-content");
            string memory exUri = "ipfs://example";

            // createContext(bytes32,string)
            bytes memory innerCreate = abi.encodeWithSignature(
                "createContext(bytes32,string)",
                exContentHash,
                exUri
            );

            // commitDeclaration(...)
            // NOTE: These are example placeholders (ids/params should be filled by client).
            bytes memory innerCommit = abi.encodeWithSignature(
                "commitDeclaration(uint256,uint32,uint32,uint8,uint8,uint8,uint8,bytes32,bytes32,string)",
                uint256(1), // sourceContextId
                uint32(0), // spanBottom
                uint32(1), // spanTop
                uint8(0), // MeaningGranularity
                uint8(0), // QuoteForm
                uint8(0), // TargetSpace
                uint8(0), // TargetTime
                bytes32(uint256(0)), // targetEntity (example)
                keccak256(bytes("ipfs://example-memo")), // memoHash (must match memoURI in real calls)
                "ipfs://example-memo"
            );

            // redeem(uint256,uint256,string,string,bytes32[])
            bytes32[] memory emptyProof = new bytes32[](0);
            bytes memory innerRedeem = abi.encodeWithSignature(
                "redeem(uint256,uint256,string,string,bytes32[])",
                uint256(1), // epochId
                uint256(1), // leafIndex
                "ipfs://metadata", // metadataURI
                "{ }", // metadataJson (example)
                emptyProof // proof (example)
            );

            // outer calldata builder (either executeFromEntryPoint or executeUserOp)
            function(
                uint192,
                address,
                bytes memory
            ) pure returns (bytes memory) buildOuter = useExecuteUserOp
                    ? _buildExecuteUserOp
                    : _buildExecuteFromEntryPoint;

            console2.log("USE_EXECUTE_USEROP:", useExecuteUserOp);

            console2.log("Sample outer calldata (createContext lane):");
            console2.logBytes(buildOuter(laneCreate, observatory, innerCreate));

            console2.log("Sample outer calldata (commitDeclaration lane):");
            console2.logBytes(buildOuter(laneCommit, observatory, innerCommit));

            console2.log("Sample outer calldata (redeem lane):");
            console2.logBytes(buildOuter(laneRedeem, observatory, innerRedeem));
        }

        vm.stopBroadcast();

        console2.log("Paymaster:", address(paymaster));
        console2.log("laneCreate:", uint256(laneCreate));
        console2.log("laneCommit:", uint256(laneCommit));
        console2.log("laneRedeem:", uint256(laneRedeem));
    }

    function _buildExecuteFromEntryPoint(
        uint192 laneKey,
        address to,
        bytes memory inner
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "executeFromEntryPoint(uint192,address,uint256,bytes)",
                laneKey,
                to,
                uint256(0),
                inner
            );
    }

    function _buildExecuteUserOp(
        uint192 laneKey,
        address to,
        bytes memory inner
    ) internal pure returns (bytes memory) {
        uint256 fullNonce = (uint256(laneKey) << 64);
        return
            abi.encodeWithSignature(
                "executeUserOp(address,uint256,bytes,uint256)",
                to,
                uint256(0),
                inner,
                fullNonce
            );
    }
}
