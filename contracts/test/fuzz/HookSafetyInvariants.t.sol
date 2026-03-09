// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {HookSafetyExecutor} from "../../src/executor/HookSafetyExecutor.sol";
import {MockCallbackProxy} from "../mocks/MockCallbackProxy.sol";
import {MockHookTarget} from "../mocks/MockHookTarget.sol";

contract ExecutorHandler {
    HookSafetyExecutor public immutable executor;
    MockCallbackProxy public immutable callbackProxy;
    bytes32 public immutable poolId;
    address public immutable expectedRvm;

    uint64 public maxAcceptedNonce;

    constructor(HookSafetyExecutor executor_, MockCallbackProxy callbackProxy_, bytes32 poolId_, address expectedRvm_) {
        executor = executor_;
        callbackProxy = callbackProxy_;
        poolId = poolId_;
        expectedRvm = expectedRvm_;
    }

    function relayMitigation(uint64 nonce, uint8 tier, uint16 score) external {
        tier = uint8(bound(tier, 0, 2));
        score = uint16(bound(score, 0, 100));

        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            expectedRvm,
            poolId,
            tier,
            score,
            uint40(block.timestamp + 15),
            uint40(0),
            nonce,
            keccak256(abi.encodePacked(nonce, tier, score))
        );

        try callbackProxy.relay(address(executor), payload) {
            if (nonce > maxAcceptedNonce) maxAcceptedNonce = nonce;
        } catch {}
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }
}

contract HookSafetyInvariantTest is StdInvariant, Test {
    HookSafetyExecutor internal executor;
    MockCallbackProxy internal callbackProxy;
    ExecutorHandler internal handler;

    bytes32 internal constant POOL_ID = keccak256("invariant-pool");

    function setUp() public {
        callbackProxy = new MockCallbackProxy();
        executor = new HookSafetyExecutor(address(callbackProxy), address(new MockHookTarget()), address(this));
        handler = new ExecutorHandler(executor, callbackProxy, POOL_ID, address(this));

        targetContract(address(handler));
    }

    function invariant_nonceNeverExceedsHighestAccepted() public view {
        assertLe(executor.lastNonceByPool(POOL_ID), handler.maxAcceptedNonce());
    }
}
