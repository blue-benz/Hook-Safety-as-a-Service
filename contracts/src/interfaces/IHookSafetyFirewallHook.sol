// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IHookSafetyFirewallHook {
    function applyMitigation(
        bytes32 poolId,
        uint8 tier,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        uint16 score
    ) external;
}
