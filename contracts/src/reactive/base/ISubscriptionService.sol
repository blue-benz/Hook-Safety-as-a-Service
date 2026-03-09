// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPayable} from "./IPayable.sol";

interface ISubscriptionService is IPayable {
    function subscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;

    function unsubscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;
}
