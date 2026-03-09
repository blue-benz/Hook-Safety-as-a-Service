// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IHookSafetyExecutor {
    function executeMitigation(
        address rvmId,
        bytes32 poolId,
        uint8 tier,
        uint16 score,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        bytes32 evidenceHash
    ) external;
}
