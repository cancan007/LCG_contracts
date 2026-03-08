// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {ContextObservatoryV0} from "../contracts/ContextObservatoryV0.sol";
import {AuthorContextNFT} from "../contracts/AuthorContextNFT.sol";
import {AccountFactory} from "../contracts/aa/AccountFactory.sol";
import {PasskeyValidator} from "../contracts/aa/validators/PasskeyValidator.sol";
import {ValidatorAggregator} from "../contracts/aa/modules/ValidatorAggregator.sol";
import {ExecutorAggregator} from "../contracts/aa/modules/ExecutorAggregator.sol";
import {ContextObservatoryLaneValidator} from "../contracts/aa/modules/contextobs/ContextObservatoryLaneValidator.sol";
import {ContextObservatoryExecutor} from "../contracts/aa/modules/contextobs/ContextObservatoryExecutor.sol";
import {ContextObservatoryPaymaster} from "../contracts/aa/modules/contextobs/ContextObservatoryPaymaster.sol";
import {LaneKeyNaming} from "../contracts/aa/libs/LaneKeyNaming.sol";

/// @notice Developer-side one-shot deployment for shared ContextObservatory infra.
/// Deploys the app contracts, shared validators/executors, aggregators, paymaster,
/// and configures AccountFactory bootstrap lanes so user-side flow only needs account deployment.
contract DeployAAInfra is Script {
    function run() external {
        address entryPoint = vm.envAddress("ENTRYPOINT");
        string memory industry = vm.envOr("INDUSTRY", string("R&D"));
        string memory service = vm.envOr("SERVICE", string("LCG"));
        uint256 epDep = vm.envOr("EP_DEPOSIT_WEI", uint256(0.001 ether)); // Optionally fund the paymaster with some ETH to cover users' first transactions.

        vm.startBroadcast();
        address deployer = msg.sender;

        ContextObservatoryV0 observatory = new ContextObservatoryV0(deployer);
        AuthorContextNFT authorNft = new AuthorContextNFT(
            "Nothing but a Number Paradox",
            "NBNP",
            address(observatory)
        );
        observatory.setAuthorNft(address(authorNft));

        PasskeyValidator passkeyValidator = new PasskeyValidator();
        AccountFactory factory = new AccountFactory(entryPoint);
        ContextObservatoryPaymaster paymaster = new ContextObservatoryPaymaster(
            entryPoint,
            address(observatory),
            industry,
            service
        );

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

        _deployLane(
            factory,
            deployer,
            address(passkeyValidator),
            address(observatory),
            laneCreate,
            selCreate
        );
        _deployLane(
            factory,
            deployer,
            address(passkeyValidator),
            address(observatory),
            laneCommit,
            selCommit
        );
        _deployLane(
            factory,
            deployer,
            address(passkeyValidator),
            address(observatory),
            laneRedeem,
            selRedeem
        );

        if (epDep != 0) {
            paymaster.addDepositToEntryPoint{value: epDep}();
        }

        vm.stopBroadcast();

        console2.log("ContextObservatoryV0:", address(observatory));
        console2.log("AuthorContextNFT:", address(authorNft));
        console2.log("PasskeyValidator:", address(passkeyValidator));
        console2.log("AccountFactory:", address(factory));
        console2.log("Paymaster:", address(paymaster));
        console2.log("laneCreate:", uint256(laneCreate));
        console2.log("laneCommit:", uint256(laneCommit));
        console2.log("laneRedeem:", uint256(laneRedeem));
    }

    function _deployLane(
        AccountFactory factory,
        address auditor,
        address passkeyValidator,
        address observatory,
        uint192 laneKey,
        bytes4 selector
    ) internal {
        ContextObservatoryLaneValidator laneValidator = new ContextObservatoryLaneValidator(
                observatory,
                laneKey,
                selector
            );
        ContextObservatoryExecutor laneExecutor = new ContextObservatoryExecutor(
                observatory,
                selector
            );

        ValidatorAggregator validatorAggregator = new ValidatorAggregator(
            auditor
        );
        ExecutorAggregator executorAggregator = new ExecutorAggregator(auditor);

        address[] memory validators = new address[](2);
        validators[0] = passkeyValidator;
        validators[1] = address(laneValidator);
        validatorAggregator.upgrade(1, 0, 0, validators);

        address[] memory executors = new address[](1);
        executors[0] = address(laneExecutor);
        executorAggregator.upgrade(1, 0, 0, executors);

        factory.configureBootstrapLane(
            laneKey,
            address(validatorAggregator),
            address(0),
            address(executorAggregator),
            address(0),
            true
        );

        console2.log("laneKey:", uint256(laneKey));
        console2.log("  validatorAggregator:", address(validatorAggregator));
        console2.log("  executorAggregator:", address(executorAggregator));
        console2.log("  laneValidator:", address(laneValidator));
        console2.log("  laneExecutor:", address(laneExecutor));
    }
}
