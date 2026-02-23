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
        bytes32 /*userOpHash*/,
        uint256 maxCost
    ) external override returns (bytes memory context, uint256 validationData) {
        // In real EntryPoint, msg.sender is EntryPoint.
        // Keep strict check to avoid arbitrary callers draining balances via postOp.
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();

        (
            uint48 validUntil,
            uint48 validAfter,
            bytes memory sig
        ) = _parsePaymasterAndData(userOp.paymasterAndData);

        // 1) Ensure the call is exactly one of the allowed ContextObservatory actions
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
        } else {
            revert NotAllowedCall();
        }

        // 2) Signature gating: require SmartAccount.owner() signature
        address signer = ISmartAccountOwnerView(userOp.sender).owner();
        bytes32 reqHash = getPaymasterRequestHash(
            userOp,
            validUntil,
            validAfter
        );
        address recovered = reqHash.toEthSignedMessageHash().recover(sig);
        if (recovered != signer) revert BadSignature();

        // 3) Reserve maxCost from user's paymaster balance (safe side)
        uint256 bal = balances[userOp.sender];
        if (bal < maxCost) revert InsufficientBalance();
        unchecked {
            balances[userOp.sender] = bal - maxCost;
        }

        // Context passed to postOp for refunding unused gas
        context = abi.encode(userOp.sender, maxCost);
        validationData = _packValidationData(validUntil, validAfter);

        emit Charged(userOp.sender, maxCost, validUntil, validAfter);
    }

    function postOp(
        PostOpMode /*mode*/,
        bytes calldata context,
        uint256 actualGasCost
    ) external override {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();

        (address account, uint256 reserved) = abi.decode(
            context,
            (address, uint256)
        );

        // refund unused portion back to the user's internal balance
        if (reserved > actualGasCost) {
            uint256 refund = reserved - actualGasCost;
            balances[account] += refund;
            emit Refunded(account, refund, actualGasCost);
        } else {
            emit Refunded(account, 0, actualGasCost);
        }
    }

    // -----------------------------
    // Hashing / decoding helpers
    // -----------------------------
    function getPaymasterRequestHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
        // Excludes paymasterAndData to avoid circular dependency.
        // Includes this paymaster and chainid to prevent cross-contract replay.
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    userOp.sender,
                    userOp.nonce,
                    keccak256(userOp.initCode),
                    keccak256(userOp.callData),
                    userOp.accountGasLimits,
                    userOp.preVerificationGas,
                    userOp.gasFees,
                    validUntil,
                    validAfter
                )
            );
    }

    function _parsePaymasterAndData(
        bytes calldata pad
    )
        internal
        view
        returns (uint48 validUntil, uint48 validAfter, bytes memory sig)
    {
        // minimal length: 20 + 6 + 6 + 65
        if (pad.length < 20 + 6 + 6 + 65) revert BadPaymasterAndData();

        address pm;
        assembly {
            pm := shr(96, calldataload(pad.offset))
        }
        if (pm != address(this)) revert BadPaymasterAndData();

        uint256 off = 20;
        validUntil = uint48(bytes6(pad[off:off + 6]));
        off += 6;
        validAfter = uint48(bytes6(pad[off:off + 6]));
        off += 6;

        sig = pad[off:];
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

    receive() external payable {}
}
