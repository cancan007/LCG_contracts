// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "../../interfaces/PackedUserOperation.sol";
import {IPaymasterV07} from "../../interfaces/IPaymasterV07.sol";
import {IEntryPointDeposit} from "../../interfaces/IEntryPointDeposit.sol";

import {ECDSA} from "../../libs/ECDSA.sol";
import {LaneKeyNaming} from "../../libs/LaneKeyNaming.sol";

interface ISmartAccountOwnerView {
    function owner() external view returns (address);
}

/// @notice Paymaster that sponsors gas ONLY for ContextObservatory actions:
/// - createContext
/// - commitDeclaration
/// - redeem
///
/// Security: to prevent 3rd parties from burning user balance, require an EOA signature
/// by SmartAccount.owner() inside paymasterAndData.
///
/// paymasterAndData encoding:
///   [0:20]   paymaster address
///   [20:26]  validUntil (uint48)  (0 = no expiry)
///   [26:32]  validAfter (uint48)  (0 = immediately valid)
///   [32:]    signature (bytes) over paymasterRequestHash(userOp, validUntil, validAfter)
///
/// The signature authorizes THIS exact UserOp fields (callData, nonce, gas fields), but excludes
/// paymasterAndData to avoid circular hashing.
contract ContextObservatoryPaymaster is IPaymasterV07 {
    using ECDSA for bytes32;

    error NotEntryPoint();
    error NotOwner();
    error BadPaymasterAndData();
    error BadSignature();
    error NotAllowedCall();
    error InsufficientBalance();

    error BadMode();
    error BadEstimateSignature();
    error BadFinalSignature();
    error GasCapExceeded();

    error BadPostOpContext();

    error BadPostOpContextLength(uint256 len);
    error BadPostOpDecode();
    error BadPostOpSender(address caller);

    uint8 internal constant MODE_ESTIMATE = 1;
    uint8 internal constant MODE_FINAL = 2;

    struct EstimateAuth {
        uint48 validUntil;
        uint48 validAfter;
        bytes sig;
    }

    struct FinalAuth {
        uint48 validUntil;
        uint48 validAfter;
        uint128 maxVerificationGas;
        uint128 maxCallGas;
        uint128 maxPreVerificationGas;
        uint128 maxMaxPriorityFeePerGas;
        uint128 maxMaxFeePerGas;
        bytes sig;
    }

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(
        address indexed account,
        address indexed to,
        uint256 amount
    );
    event EntryPointDepositAdded(uint256 amount);
    event EntryPointDepositWithdrawn(address indexed to, uint256 amount);

    event Charged(
        address indexed account,
        uint256 reservedMaxCost,
        uint48 validUntil,
        uint48 validAfter
    );
    event Refunded(
        address indexed account,
        uint256 refund,
        uint256 actualGasCost
    );

    IEntryPointDeposit public immutable entryPoint;
    address public immutable contextObservatory;
    address public owner;

    // user (smart account) -> balance used for sponsoring gas (in wei)
    mapping(address => uint256) public balances;

    // lane keys for actions
    uint192 public immutable laneCreate;
    uint192 public immutable laneCommit;
    uint192 public immutable laneRedeem;
    uint192 public immutable laneDeposit;
    uint192 public immutable laneWithdraw;

    // allowed selectors
    bytes4 public constant SEL_CREATE =
        bytes4(keccak256("createContext(bytes32,string)"));
    bytes4 public constant SEL_COMMIT =
        bytes4(
            keccak256(
                "commitDeclaration(uint256,uint32,uint32,uint8,uint8,uint8,uint8,bytes32,bytes32,string)"
            )
        );
    bytes4 public constant SEL_REDEEM =
        bytes4(keccak256("redeem(uint256,uint256,string,string,bytes32[])"));
    bytes4 public constant SEL_DEPOSIT = bytes4(keccak256("depositStake()"));

    bytes4 public constant SEL_WITHDRAW =
        bytes4(keccak256("withdrawStake(uint256)"));

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _entryPoint,
        address _contextObservatory,
        string memory industry,
        string memory service
    ) {
        entryPoint = IEntryPointDeposit(_entryPoint);
        contextObservatory = _contextObservatory;
        owner = msg.sender;

        laneCreate = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/createContext"
        );
        laneCommit = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/commitDeclaration"
        );
        laneRedeem = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/redeem"
        );
        laneDeposit = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/depositStake"
        );
        laneWithdraw = LaneKeyNaming.laneKey(
            industry,
            service,
            "internal/withdrawStake"
        );
    }

    // -----------------------------
    // Funding (user balances)
    // -----------------------------
    function depositFor(address account) external payable {
        balances[account] += msg.value;
        emit Deposited(account, msg.value);
    }

    function withdrawTo(address payable to, uint256 amount) external {
        address account = msg.sender;
        require(balances[account] >= amount, "insufficient");
        balances[account] -= amount;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(account, to, amount);
    }

    // -----------------------------
    // EntryPoint deposit (paymaster stake/deposit)
    // -----------------------------
    function addDepositToEntryPoint() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit EntryPointDepositAdded(msg.value);
    }

    function withdrawDepositTo(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
        emit EntryPointDepositWithdrawn(to, amount);
    }

    function entryPointDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // -----------------------------
    // IPaymasterV07
    // -----------------------------
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external override returns (bytes memory context, uint256 validationData) {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();

        (
            uint192 laneKey,
            address target,
            bytes4 selector
        ) = _extractLaneTargetSelector(userOp.callData);

        if (target != contextObservatory) revert NotAllowedCall();

        if (selector == SEL_CREATE) {
            if (laneKey != laneCreate) revert NotAllowedCall();
        } else if (selector == SEL_COMMIT) {
            if (laneKey != laneCommit) revert NotAllowedCall();
        } else if (selector == SEL_REDEEM) {
            if (laneKey != laneRedeem) revert NotAllowedCall();
        } else if (selector == SEL_DEPOSIT) {
            if (laneKey != laneDeposit) revert NotAllowedCall();
        } else if (selector == SEL_WITHDRAW) {
            if (laneKey != laneWithdraw) revert NotAllowedCall();
        } else {
            revert NotAllowedCall();
        }

        uint256 bal = balances[userOp.sender];
        if (bal < maxCost) revert InsufficientBalance();

        address signer = ISmartAccountOwnerView(userOp.sender).owner();

        (uint8 mode, bytes calldata body) = _parseMode(userOp.paymasterAndData);

        if (mode == MODE_ESTIMATE) {
            EstimateAuth memory a = _parseEstimateAuth(body);

            bytes32 reqHash = getEstimateRequestHash(
                userOp,
                a.validUntil,
                a.validAfter
            );

            address recovered = reqHash.toEthSignedMessageHash().recover(a.sig);
            if (recovered != signer) revert BadEstimateSignature();

            validationData = _packValidationData(a.validUntil, a.validAfter);
            return ("", validationData);
        }

        if (mode == MODE_FINAL) {
            FinalAuth memory a = _parseFinalAuth(body);

            if (
                !_checkGasCaps(
                    userOp,
                    a.maxVerificationGas,
                    a.maxCallGas,
                    a.maxPreVerificationGas,
                    a.maxMaxPriorityFeePerGas,
                    a.maxMaxFeePerGas
                )
            ) revert GasCapExceeded();

            bytes32 reqHash = getFinalRequestHash(
                userOp,
                a.validUntil,
                a.validAfter
            );

            address recovered = reqHash.toEthSignedMessageHash().recover(a.sig);
            if (recovered != signer) revert BadFinalSignature();

            unchecked {
                balances[userOp.sender] = bal - maxCost;
            }

            context = abi.encode(userOp.sender, maxCost);
            validationData = _packValidationData(a.validUntil, a.validAfter);

            emit Charged(userOp.sender, maxCost, a.validUntil, a.validAfter);
            return (context, validationData);
        }

        revert BadMode();
    }

    function postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /*actualUserOpFeePerGas*/
    ) external override {
        if (msg.sender != address(entryPoint)) {
            revert BadPostOpSender(msg.sender);
        }

        if (context.length == 0) {
            // estimate mode など context なしを許容するなら、ここで return
            return;
        }

        if (context.length != 64) {
            revert BadPostOpContextLength(context.length);
        }

        address account;
        uint256 reserved;
        try this._decodePostOpContext(context) returns (address a, uint256 r) {
            account = a;
            reserved = r;
        } catch {
            revert BadPostOpDecode();
        }

        if (reserved > actualGasCost) {
            uint256 refund = reserved - actualGasCost;
            balances[account] += refund;
            emit Refunded(account, refund, actualGasCost);
        } else {
            emit Refunded(account, 0, actualGasCost);
        }
    }

    function _decodePostOpContext(
        bytes calldata context
    ) external pure returns (address, uint256) {
        return abi.decode(context, (address, uint256));
    }

    function getEstimateRequestHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
        (
            uint192 laneKey,
            address target,
            bytes4 selector
        ) = _extractLaneTargetSelector(userOp.callData);

        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    uint8(MODE_ESTIMATE),
                    userOp.sender,
                    laneKey,
                    target,
                    selector,
                    keccak256(userOp.callData),
                    validUntil,
                    validAfter
                )
            );
    }

    function getFinalRequestHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    userOp.sender,
                    userOp.nonce,
                    keccak256(userOp.callData),
                    validUntil,
                    validAfter
                )
            );
    }

    function _parseMode(
        bytes calldata pad
    ) internal view returns (uint8 mode, bytes calldata body) {
        // [20:36] paymaster gas fields already included in paymasterAndData
        // body starts after:
        // 20 bytes paymaster + 16 + 16 bytes gas fields
        if (pad.length < 20 + 16 + 16 + 1) revert BadPaymasterAndData();

        address pm;
        assembly {
            pm := shr(96, calldataload(pad.offset))
        }
        if (pm != address(this)) revert BadPaymasterAndData();

        uint256 off = 20 + 16 + 16;
        mode = uint8(bytes1(pad[off:off + 1]));
        body = pad[off + 1:];
    }

    function _parseEstimateAuth(
        bytes calldata body
    ) internal pure returns (EstimateAuth memory a) {
        // [mode:1][validUntil:6][validAfter:6][sig:65+]
        if (body.length < 6 + 6 + 65) revert BadPaymasterAndData();

        uint256 off = 0;
        a.validUntil = uint48(bytes6(body[off:off + 6]));
        off += 6;
        a.validAfter = uint48(bytes6(body[off:off + 6]));
        off += 6;
        a.sig = body[off:];
    }

    function _parseFinalAuth(
        bytes calldata body
    ) internal pure returns (FinalAuth memory a) {
        // [mode:1]
        // [validUntil:6][validAfter:6]
        // [maxVerificationGas:16][maxCallGas:16][maxPreVerificationGas:16]
        // [maxMaxPriorityFeePerGas:16][maxMaxFeePerGas:16]
        // [sig:65+]
        if (body.length < 6 + 6 + 16 * 5 + 65) revert BadPaymasterAndData();

        uint256 off = 0;
        a.validUntil = uint48(bytes6(body[off:off + 6]));
        off += 6;
        a.validAfter = uint48(bytes6(body[off:off + 6]));
        off += 6;

        a.maxVerificationGas = uint128(bytes16(body[off:off + 16]));
        off += 16;
        a.maxCallGas = uint128(bytes16(body[off:off + 16]));
        off += 16;
        a.maxPreVerificationGas = uint128(bytes16(body[off:off + 16]));
        off += 16;
        a.maxMaxPriorityFeePerGas = uint128(bytes16(body[off:off + 16]));
        off += 16;
        a.maxMaxFeePerGas = uint128(bytes16(body[off:off + 16]));
        off += 16;

        a.sig = body[off:];
    }

    function _checkGasCaps(
        PackedUserOperation calldata userOp,
        uint128 maxVerificationGas,
        uint128 maxCallGas,
        uint128 maxPreVerificationGas,
        uint128 maxMaxPriorityFeePerGas,
        uint128 maxMaxFeePerGas
    ) internal pure returns (bool) {
        uint128 verificationGasLimit = uint128(
            bytes16(userOp.accountGasLimits)
        );
        uint128 callGasLimit = uint128(uint256(userOp.accountGasLimits));
        uint128 maxPriorityFeePerGas = uint128(bytes16(userOp.gasFees));
        uint128 maxFeePerGas = uint128(uint256(userOp.gasFees));

        return
            verificationGasLimit <= maxVerificationGas &&
            callGasLimit <= maxCallGas &&
            userOp.preVerificationGas <= maxPreVerificationGas &&
            maxPriorityFeePerGas <= maxMaxPriorityFeePerGas &&
            maxFeePerGas <= maxMaxFeePerGas;
    }

    function _packValidationData(
        uint48 validUntil,
        uint48 validAfter
    ) internal pure returns (uint256) {
        // Pack per ERC-4337 convention: [validUntil (48 bits) | validAfter (48 bits) | aggregator (160 bits=0)]
        return (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    function _first4(bytes memory b) internal pure returns (bytes4 sel) {
        if (b.length < 4) revert NotAllowedCall();
        assembly {
            sel := mload(add(b, 32))
        }
    }

    function _extractLaneTargetSelector(
        bytes calldata callData
    ) internal pure returns (uint192 laneKey, address target, bytes4 sel) {
        // Supports two common call paths in your SmartAccount:
        // 1) executeFromEntryPoint(uint192,address,uint256,bytes)
        // 2) executeUserOp(address,uint256,bytes,uint256)  (laneKey carried in fullNonce)
        //
        // Decode method selector first.
        if (callData.length < 4) revert NotAllowedCall();
        bytes4 outerSel = bytes4(callData[0:4]);

        if (
            outerSel ==
            bytes4(
                keccak256(
                    "executeFromEntryPoint(uint192,address,uint256,bytes)"
                )
            )
        ) {
            (
                uint192 _laneKey,
                address _target,
                uint256 _value,
                bytes memory inner
            ) = abi.decode(callData[4:], (uint192, address, uint256, bytes));
            if (inner.length < 4) revert NotAllowedCall();
            sel = _first4(inner);
            return (_laneKey, _target, sel);
        }

        if (
            outerSel ==
            bytes4(keccak256("executeUserOp(address,uint256,bytes,uint256)"))
        ) {
            (
                address _target,
                uint256 _value,
                bytes memory inner,
                uint256 fullNonce
            ) = abi.decode(callData[4:], (address, uint256, bytes, uint256));
            if (inner.length < 4) revert NotAllowedCall();
            sel = _first4(inner);
            laneKey = uint192(fullNonce >> 64);
            return (laneKey, _target, sel);
        }

        revert NotAllowedCall();
    }

    // // Temporary for debug test(should be removed)
    // function debugValidateMode(
    //     PackedUserOperation calldata userOp,
    //     uint256 maxCost
    // )
    //     external
    //     view
    //     returns (
    //         uint8 mode,
    //         uint48 validUntil,
    //         uint48 validAfter,
    //         uint192 laneKey,
    //         address target,
    //         bytes4 selector,
    //         bytes32 reqHash,
    //         address signer,
    //         address recovered,
    //         bool allowedCall,
    //         bool enoughBalance,
    //         bool gasCapsOk
    //     )
    // {
    //     (laneKey, target, selector) = _extractLaneTargetSelector(
    //         userOp.callData
    //     );

    //     allowedCall = false;
    //     if (target == contextObservatory) {
    //         if (selector == SEL_CREATE && laneKey == laneCreate) {
    //             allowedCall = true;
    //         } else if (selector == SEL_COMMIT && laneKey == laneCommit) {
    //             allowedCall = true;
    //         } else if (selector == SEL_REDEEM && laneKey == laneRedeem) {
    //             allowedCall = true;
    //         }
    //     }

    //     enoughBalance = balances[userOp.sender] >= maxCost;
    //     signer = ISmartAccountOwnerView(userOp.sender).owner();

    //     (uint8 _mode, bytes calldata body) = _parseMode(
    //         userOp.paymasterAndData
    //     );

    //     if (_mode == MODE_ESTIMATE) {
    //         EstimateAuth memory a = _parseEstimateAuth(body);
    //         validUntil = a.validUntil;
    //         validAfter = a.validAfter;
    //         reqHash = getEstimateRequestHash(
    //             userOp,
    //             a.validUntil,
    //             a.validAfter
    //         );
    //         recovered = reqHash.toEthSignedMessageHash().recover(a.sig);
    //         gasCapsOk = true;
    //         return (
    //             mode,
    //             validUntil,
    //             validAfter,
    //             laneKey,
    //             target,
    //             selector,
    //             reqHash,
    //             signer,
    //             recovered,
    //             allowedCall,
    //             enoughBalance,
    //             gasCapsOk
    //         );
    //     }

    //     if (mode == MODE_FINAL) {
    //         FinalAuth memory a = _parseFinalAuth(body);
    //         validUntil = a.validUntil;
    //         validAfter = a.validAfter;
    //         gasCapsOk = _checkGasCaps(
    //             userOp,
    //             a.maxVerificationGas,
    //             a.maxCallGas,
    //             a.maxPreVerificationGas,
    //             a.maxMaxPriorityFeePerGas,
    //             a.maxMaxFeePerGas
    //         );
    //         reqHash = getFinalRequestHash(userOp, a.validUntil, a.validAfter);
    //         recovered = reqHash.toEthSignedMessageHash().recover(a.sig);
    //         return (
    //             mode,
    //             validUntil,
    //             validAfter,
    //             laneKey,
    //             target,
    //             selector,
    //             reqHash,
    //             signer,
    //             recovered,
    //             allowedCall,
    //             enoughBalance,
    //             gasCapsOk
    //         );
    //     }

    //     return (
    //         mode,
    //         validUntil,
    //         validAfter,
    //         laneKey,
    //         target,
    //         selector,
    //         bytes32(0),
    //         signer,
    //         address(0),
    //         allowedCall,
    //         enoughBalance,
    //         false
    //     );
    // }

    receive() external payable {}
}
