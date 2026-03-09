// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "../reactive/base/AbstractCallback.sol";
import {Owned} from "../common/Owned.sol";
import {IHookSafetyFirewallHook} from "../interfaces/IHookSafetyFirewallHook.sol";

contract HookSafetyExecutor is AbstractCallback, Owned {
    IHookSafetyFirewallHook public immutable hook;

    bool public emergencyStop;
    uint256 private unlocked = 1;

    mapping(bytes32 => uint64) public lastNonceByPool;
    mapping(bytes32 => uint16) public lastScoreByPool;
    mapping(bytes32 => uint8) public lastTierByPool;
    mapping(bytes32 => bytes32) public lastEvidenceByPool;

    event MitigationExecuted(bytes32 indexed poolId, uint8 tier, uint16 score, uint64 nonce);

    event RvmBound(address indexed rvmId);
    event EmergencyStopSet(bool enabled);

    error ReplayDetected(bytes32 poolId, uint64 providedNonce, uint64 expectedGreaterThan);
    error InvalidTier(uint8 tier);
    error Stopped();
    error Reentrancy();

    constructor(address callbackSender, address hookAddress, address owner_) AbstractCallback(callbackSender) Owned(owner_) {
        hook = IHookSafetyFirewallHook(hookAddress);
    }

    modifier nonReentrant() {
        if (unlocked != 1) revert Reentrancy();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    function bindRvmId(address expectedRvmId) external onlyOwner {
        rvm_id = expectedRvmId;
        emit RvmBound(expectedRvmId);
    }

    function setEmergencyStop(bool enabled) external onlyOwner {
        emergencyStop = enabled;
        emit EmergencyStopSet(enabled);
    }

    function executeMitigation(
        address reactiveVmId,
        bytes32 poolId,
        uint8 tier,
        uint16 score,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        bytes32 evidenceHash
    ) external authorizedSenderOnly rvmIdOnly(reactiveVmId) nonReentrant {
        if (emergencyStop) revert Stopped();
        if (tier > 2) revert InvalidTier(tier);

        uint64 lastNonce = lastNonceByPool[poolId];
        if (nonce <= lastNonce) revert ReplayDetected(poolId, nonce, lastNonce);

        lastNonceByPool[poolId] = nonce;
        lastScoreByPool[poolId] = score;
        lastTierByPool[poolId] = tier;
        lastEvidenceByPool[poolId] = evidenceHash;

        hook.applyMitigation(poolId, tier, throttleUntil, pauseUntil, nonce, score);

        emit MitigationExecuted(poolId, tier, score, nonce);
    }
}
