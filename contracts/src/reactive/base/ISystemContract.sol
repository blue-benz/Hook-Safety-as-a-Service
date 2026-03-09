// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPayable} from "./IPayable.sol";
import {ISubscriptionService} from "./ISubscriptionService.sol";

interface ISystemContract is IPayable, ISubscriptionService {}
