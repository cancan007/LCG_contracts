// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice ERC-7579 mode encoding helpers + laneKey extension.
///
/// bytes32 mode layout (ERC-7579 §5.3):
///   [byte  0   ] CallType     0x00=single, 0x01=batch, 0xfe=staticcall, 0xff=delegatecall
///   [byte  1   ] ExecType     0x00=revert on failure, 0x01=try (no revert)
///   [bytes 2-5 ] Reserved
///   [bytes 6-9 ] ModeSelector 0x00000000=standard; MODE_LANE=laneKey mode
///   [bytes 10-31] ModePayload (unused here; laneKey lives in executionCalldata)
///
/// executionCalldata format:
///   Standard single : abi.encodePacked(address target, uint256 value, bytes callData)
///   Lane single     : abi.encode(uint192 laneKey, address target, uint256 value, bytes callData)
library ModeLib {
    // ── CallType ──────────────────────────────────────────────────────────────
    bytes1 internal constant CALLTYPE_SINGLE = 0x00;
    bytes1 internal constant CALLTYPE_BATCH = 0x01;
    bytes1 internal constant CALLTYPE_DELEGATECALL = 0xff;

    // ── ExecType ──────────────────────────────────────────────────────────────
    bytes1 internal constant EXECTYPE_DEFAULT = 0x00; // revert on failure
    bytes1 internal constant EXECTYPE_TRY = 0x01; // don't revert

    // ── laneKey-specific ModeSelector ─────────────────────────────────────────
    /// @dev Custom selector: executionCalldata starts with uint192 laneKey.
    bytes4 internal constant MODE_LANE = bytes4(keccak256("LCG.lane.v1"));

    // ── Mode builders ─────────────────────────────────────────────────────────

    /// @notice Standard ERC-7579 single call (DEFAULT_LANE, revert on failure).
    function encodeSimpleSingle() internal pure returns (bytes32) {
        return bytes32(0);
    }

    /// @notice laneKey single call (laneKey encoded in executionCalldata).
    function encodeLaneSingle() internal pure returns (bytes32) {
        // byte0=CALLTYPE_SINGLE(0x00), byte1=EXECTYPE_DEFAULT(0x00),
        // bytes2-5=Reserved(0x00000000), bytes6-9=MODE_LANE
        // bytes32(MODE_LANE) puts selector in bits [255:224]; >> 48 shifts to bytes[6:10]
        return bytes32(MODE_LANE) >> 48;
    }

    // ── Mode decoders ─────────────────────────────────────────────────────────

    function getCallType(bytes32 mode) internal pure returns (bytes1) {
        return bytes1(mode); // MSB = byte 0
    }

    function getExecType(bytes32 mode) internal pure returns (bytes1) {
        return bytes1(mode << 8); // byte 1
    }

    /// @dev bytes 6-9 of mode.
    function getModeSelector(bytes32 mode) internal pure returns (bytes4) {
        return bytes4(mode << 48); // shift 6 bytes left, take MSB 4 bytes
    }

    function isLane(bytes32 mode) internal pure returns (bool) {
        return getModeSelector(mode) == MODE_LANE;
    }

    // ── ExecutionCalldata helpers ─────────────────────────────────────────────

    /// @notice Encode standard single calldata: abi.encodePacked(target, value, callData).
    /// @dev target=20 bytes, value=32 bytes, callData=remaining
    function encodeSingleCalldata(
        address target,
        uint256 value,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData);
    }

    /// @notice Decode standard single calldata.
    function decodeSingle(
        bytes calldata executionCalldata
    )
        internal
        pure
        returns (address target, uint256 value, bytes calldata callData)
    {
        target = address(bytes20(executionCalldata[0:20]));
        value = uint256(bytes32(executionCalldata[20:52]));
        callData = executionCalldata[52:];
    }

    /// @notice Encode laneKey single calldata.
    function encodeLaneCalldata(
        uint192 laneKey,
        address target,
        uint256 value,
        bytes memory callData
    ) internal pure returns (bytes memory) {
        return abi.encode(laneKey, target, value, callData);
    }

    /// @notice Decode laneKey single calldata.
    function decodeLane(
        bytes calldata executionCalldata
    )
        internal
        pure
        returns (
            uint192 laneKey,
            address target,
            uint256 value,
            bytes memory callData
        )
    {
        return
            abi.decode(executionCalldata, (uint192, address, uint256, bytes));
    }
}
