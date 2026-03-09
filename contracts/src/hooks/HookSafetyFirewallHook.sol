// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Owned} from "../common/Owned.sol";
import {RiskMath} from "../libraries/RiskMath.sol";

contract HookSafetyFirewallHook is BaseHook, Owned {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;

    uint8 public constant TIER_NORMAL = 0;
    uint8 public constant TIER_ELEVATED = 1;
    uint8 public constant TIER_EMERGENCY = 2;

    uint16 public constant RISK_MEDIUM = 55;
    uint16 public constant RISK_HIGH = 80;

    struct PoolConfig {
        uint24 baseFeePips;
        uint24 elevatedFeePips;
        uint24 emergencyFeePips;
        bool exists;
    }

    struct PoolState {
        uint64 sequence;
        uint64 lastMitigationNonce;
        uint40 pauseUntil;
        uint40 throttleUntil;
        uint40 lastSwapTimestamp;
        uint8 tier;
        uint8 lastLocalRisk;
        bool lastDirectionZeroForOne;
        uint24 currentFeePips;
        uint128 emaVolume;
        uint128 lastLiquidity;
        uint160 lastSqrtPriceX96;
        int24 lastTick;
    }

    struct SwapSnapshot {
        bytes32 poolId;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 lpFee;
        uint128 liquidity;
        int128 amount0;
        int128 amount1;
    }

    mapping(bytes32 => PoolConfig) private poolConfigs;
    mapping(bytes32 => PoolState) private poolStates;
    mapping(address => bool) public executors;

    event ExecutorSet(address indexed executor, bool allowed);
    event PoolConfigured(bytes32 indexed poolId, uint24 baseFeePips, uint24 elevatedFeePips, uint24 emergencyFeePips);
    event MitigationApplied(
        bytes32 indexed poolId,
        uint8 tier,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        uint16 score
    );

    event SecurityTelemetry(
        bytes32 indexed poolId,
        address indexed sender,
        uint64 sequence,
        uint64 timestamp,
        uint64 blockNumber,
        int24 tick,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int128 amount0,
        int128 amount1,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 activeFeePips,
        uint8 localRiskScore
    );

    error UnknownPool(bytes32 poolId);
    error UnauthorizedExecutor(address caller);
    error PoolPaused(bytes32 poolId, uint40 pausedUntil);
    error PoolThrottled(bytes32 poolId, uint40 throttledUntil);

    constructor(IPoolManager manager, address initialOwner) BaseHook(manager) Owned(initialOwner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyExecutor() {
        if (!executors[msg.sender]) revert UnauthorizedExecutor(msg.sender);
        _;
    }

    function setExecutor(address executor, bool allowed) external onlyOwner {
        executors[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    function configurePool(PoolKey calldata key, uint24 baseFeePips, uint24 elevatedFeePips, uint24 emergencyFeePips)
        external
        onlyOwner
    {
        PoolId id = key.toId();
        bytes32 poolId = PoolId.unwrap(id);

        baseFeePips.validate();
        elevatedFeePips.validate();
        emergencyFeePips.validate();

        poolConfigs[poolId] = PoolConfig({
            baseFeePips: baseFeePips,
            elevatedFeePips: elevatedFeePips,
            emergencyFeePips: emergencyFeePips,
            exists: true
        });

        PoolState storage state = poolStates[poolId];
        if (state.currentFeePips == 0) {
            state.currentFeePips = baseFeePips;
        }

        emit PoolConfigured(poolId, baseFeePips, elevatedFeePips, emergencyFeePips);
    }

    function clearMitigation(bytes32 poolId) external onlyOwner {
        PoolConfig memory config = poolConfigs[poolId];
        if (!config.exists) revert UnknownPool(poolId);

        PoolState storage state = poolStates[poolId];
        state.tier = TIER_NORMAL;
        state.pauseUntil = 0;
        state.throttleUntil = 0;
        state.currentFeePips = config.baseFeePips;
    }

    function applyMitigation(
        bytes32 poolId,
        uint8 tier,
        uint40 throttleUntil,
        uint40 pauseUntil,
        uint64 nonce,
        uint16 score
    ) external onlyExecutor {
        PoolConfig memory config = poolConfigs[poolId];
        if (!config.exists) revert UnknownPool(poolId);

        PoolState storage state = poolStates[poolId];
        // Idempotent update: silently ignore stale callbacks.
        if (nonce <= state.lastMitigationNonce) return;

        state.lastMitigationNonce = nonce;

        if (throttleUntil > state.throttleUntil) state.throttleUntil = throttleUntil;
        if (pauseUntil > state.pauseUntil) state.pauseUntil = pauseUntil;

        if (tier > TIER_EMERGENCY) tier = TIER_EMERGENCY;
        if (tier > state.tier) {
            state.tier = tier;
        }

        state.currentFeePips = _feeForTier(config, state.tier);

        emit MitigationApplied(poolId, state.tier, state.throttleUntil, state.pauseUntil, nonce, score);
    }

    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory) {
        return poolConfigs[poolId];
    }

    function getPoolState(bytes32 poolId) external view returns (PoolState memory) {
        return poolStates[poolId];
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolConfig memory config = poolConfigs[poolId];
        if (!config.exists) revert UnknownPool(poolId);

        PoolState storage state = poolStates[poolId];

        if (block.timestamp < state.pauseUntil) revert PoolPaused(poolId, state.pauseUntil);
        if (block.timestamp < state.throttleUntil) revert PoolThrottled(poolId, state.throttleUntil);

        if (state.currentFeePips == 0) state.currentFeePips = config.baseFeePips;

        uint24 feeOverride;
        if (key.fee.isDynamicFee()) {
            feeOverride = state.currentFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        SwapSnapshot memory snapshot = _loadSwapSnapshot(key, delta);
        PoolConfig memory config = poolConfigs[snapshot.poolId];
        if (!config.exists) revert UnknownPool(snapshot.poolId);
        PoolState storage state = poolStates[snapshot.poolId];
        uint16 localRisk = _computeLocalRisk(
            state, params.zeroForOne, snapshot.amount0, snapshot.amount1, snapshot.sqrtPriceX96, snapshot.tick
        );

        state.sequence += 1;
        state.lastSqrtPriceX96 = snapshot.sqrtPriceX96;
        state.lastTick = snapshot.tick;
        state.lastLiquidity = snapshot.liquidity;
        state.lastSwapTimestamp = uint40(block.timestamp);
        state.lastDirectionZeroForOne = params.zeroForOne;
        state.lastLocalRisk = uint8(localRisk);

        if (state.currentFeePips == 0) state.currentFeePips = config.baseFeePips;

        if (localRisk >= RISK_HIGH) {
            _localEmergency(state, config);
        } else if (localRisk >= RISK_MEDIUM) {
            _localThrottle(state, config);
        }

        uint24 activeFeePips = key.fee.isDynamicFee() ? state.currentFeePips : snapshot.lpFee;
        _emitTelemetry(
            sender,
            snapshot,
            state.sequence,
            params.zeroForOne,
            params.amountSpecified,
            activeFeePips,
            localRisk
        );

        return (BaseHook.afterSwap.selector, 0);
    }

    function _loadSwapSnapshot(PoolKey calldata key, BalanceDelta delta) private view returns (SwapSnapshot memory snapshot) {
        PoolId id = key.toId();
        snapshot.poolId = PoolId.unwrap(id);
        (snapshot.sqrtPriceX96, snapshot.tick,, snapshot.lpFee) = poolManager.getSlot0(id);
        snapshot.liquidity = poolManager.getLiquidity(id);
        snapshot.amount0 = delta.amount0();
        snapshot.amount1 = delta.amount1();
    }

    function _computeLocalRisk(
        PoolState storage state,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        int24 tick
    ) private returns (uint16 localRisk) {
        uint256 volume = RiskMath.absInt128(amount0) + RiskMath.absInt128(amount1);
        uint128 emaVolume = state.emaVolume;

        if (emaVolume == 0) {
            emaVolume = uint128(volume);
        } else {
            emaVolume = uint128((uint256(emaVolume) * 7 + volume) / 8);
        }
        state.emaVolume = emaVolume;

        RiskMath.FeatureVector memory features =
            _deriveFeatures(state, amount0, amount1, sqrtPriceX96, tick, zeroForOne, volume, emaVolume);
        return RiskMath.score(features, RiskMath.defaultWeights());
    }

    function _deriveFeatures(
        PoolState storage state,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        int24 tick,
        bool zeroForOne,
        uint256 volume,
        uint128 emaVolume
    ) private view returns (RiskMath.FeatureVector memory features) {
        features.priceDeviationBps = state.lastSqrtPriceX96 == 0
            ? 0
            : RiskMath.ratioBps(RiskMath.absDiff(uint256(sqrtPriceX96), uint256(state.lastSqrtPriceX96)), state.lastSqrtPriceX96);
        features.volumeSpikeBps = RiskMath.ratioBps(volume, emaVolume == 0 ? 1 : uint256(emaVolume));
        features.slippageAnomalyBps = RiskMath.clampBps(_tickDeltaBps(state.lastTick, tick));
        features.liquidityImbalanceBps = _liquidityImbalance(amount0, amount1);
        features.temporalCorrelationBps = _temporalCorrelation(state.lastSwapTimestamp);
        features.mevHeuristicBps = _mevHeuristic(
            features.priceDeviationBps,
            features.volumeSpikeBps,
            features.temporalCorrelationBps,
            zeroForOne,
            state.lastDirectionZeroForOne
        );
    }

    function _liquidityImbalance(int128 amount0, int128 amount1) private pure returns (uint16) {
        uint256 abs0 = RiskMath.absInt128(amount0);
        uint256 abs1 = RiskMath.absInt128(amount1);
        uint256 imbalanceNumerator = RiskMath.absDiff(abs0, abs1);
        return RiskMath.ratioBps(imbalanceNumerator, abs0 + abs1 + 1);
    }

    function _emitTelemetry(
        address sender,
        SwapSnapshot memory snapshot,
        uint64 sequence,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 activeFeePips,
        uint16 localRisk
    ) private {
        emit SecurityTelemetry(
            snapshot.poolId,
            sender,
            sequence,
            uint64(block.timestamp),
            uint64(block.number),
            snapshot.tick,
            snapshot.sqrtPriceX96,
            snapshot.liquidity,
            snapshot.amount0,
            snapshot.amount1,
            zeroForOne,
            amountSpecified,
            activeFeePips,
            uint8(localRisk)
        );
    }

    function _feeForTier(PoolConfig memory config, uint8 tier) private pure returns (uint24) {
        if (tier == TIER_EMERGENCY) return config.emergencyFeePips;
        if (tier == TIER_ELEVATED) return config.elevatedFeePips;
        return config.baseFeePips;
    }

    function _localThrottle(PoolState storage state, PoolConfig memory config) private {
        if (state.tier < TIER_ELEVATED) state.tier = TIER_ELEVATED;
        uint40 newThrottleUntil = uint40(block.timestamp + 30);
        if (newThrottleUntil > state.throttleUntil) state.throttleUntil = newThrottleUntil;
        state.currentFeePips = _feeForTier(config, state.tier);
    }

    function _localEmergency(PoolState storage state, PoolConfig memory config) private {
        state.tier = TIER_EMERGENCY;

        uint40 newPauseUntil = uint40(block.timestamp + 45);
        if (newPauseUntil > state.pauseUntil) state.pauseUntil = newPauseUntil;

        uint40 newThrottleUntil = uint40(block.timestamp + 120);
        if (newThrottleUntil > state.throttleUntil) state.throttleUntil = newThrottleUntil;

        state.currentFeePips = _feeForTier(config, state.tier);
    }

    function _tickDeltaBps(int24 previousTick, int24 currentTick) private pure returns (uint256) {
        int256 diff = int256(currentTick) - int256(previousTick);
        if (diff < 0) diff = -diff;
        // Tick jumps above ~500 are treated as severe.
        return uint256(diff) * 20;
    }

    function _temporalCorrelation(uint40 lastSwapTimestamp) private view returns (uint16) {
        if (lastSwapTimestamp == 0) return 0;
        uint256 deltaSeconds = block.timestamp - uint256(lastSwapTimestamp);
        if (deltaSeconds <= 2) return 10_000;
        if (deltaSeconds <= 8) return 6_500;
        if (deltaSeconds <= 20) return 3_000;
        return 1_000;
    }

    function _mevHeuristic(
        uint16 priceDeviationBps,
        uint16 volumeSpikeBps,
        uint16 temporalCorrelationBps,
        bool direction,
        bool previousDirection
    ) private pure returns (uint16) {
        uint256 score;
        if (priceDeviationBps >= 1_500) score += 3_500;
        if (volumeSpikeBps >= 7_500) score += 3_000;
        if (temporalCorrelationBps >= 6_500) score += 2_500;
        if (direction != previousDirection) score += 2_000;
        return RiskMath.clampBps(score);
    }
}
