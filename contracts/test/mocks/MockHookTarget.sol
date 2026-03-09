// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockHookTarget {
    bytes32 public lastPoolId;
    uint8 public lastTier;
    uint40 public lastThrottleUntil;
    uint40 public lastPauseUntil;
    uint64 public lastNonce;
    uint16 public lastScore;

    function applyMitigation(
        bytes32 poolId,
        uint8 tier,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        uint16 score
    ) external {
        lastPoolId = poolId;
        lastTier = tier;
        lastThrottleUntil = throttleUntil;
        lastPauseUntil = pauseUntil;
        lastNonce = nonce;
        lastScore = score;
    }
}
