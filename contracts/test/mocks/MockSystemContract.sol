// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISystemContract} from "../../src/reactive/base/ISystemContract.sol";

contract MockSystemContract is ISystemContract {
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;
    uint256 public forcedDebt;
    uint256 public receivedValue;
    bool public rejectPayments;

    uint256 public lastChainId;
    address public lastTarget;
    uint256 public lastTopic0;
    uint256 public lastTopic1;
    uint256 public lastTopic2;
    uint256 public lastTopic3;

    function setDebt(uint256 debt_) external {
        forcedDebt = debt_;
    }

    function setRejectPayments(bool reject_) external {
        rejectPayments = reject_;
    }

    function subscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        subscribeCount += 1;
        lastChainId = chainId;
        lastTarget = targetContract;
        lastTopic0 = topic0;
        lastTopic1 = topic1;
        lastTopic2 = topic2;
        lastTopic3 = topic3;
    }

    function unsubscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        unsubscribeCount += 1;
        lastChainId = chainId;
        lastTarget = targetContract;
        lastTopic0 = topic0;
        lastTopic1 = topic1;
        lastTopic2 = topic2;
        lastTopic3 = topic3;
    }

    function debt(address) external view returns (uint256) {
        return forcedDebt;
    }

    receive() external payable {
        if (rejectPayments) revert("reject-payment");
        receivedValue += msg.value;
    }
}
