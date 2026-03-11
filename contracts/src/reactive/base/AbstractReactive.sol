// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "./IReactive.sol";
import {ISystemContract} from "./ISystemContract.sol";
import {AbstractPayer} from "./AbstractPayer.sol";

abstract contract AbstractReactive is IReactive, AbstractPayer {
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    ISystemContract internal constant SERVICE_ADDR = ISystemContract(payable(0x0000000000000000000000000000000000fffFfF));

    bool internal vm;
    ISystemContract internal service;

    error ReactiveNetworkOnly();
    error ReactVmOnly();

    constructor() {
        vendor = service = SERVICE_ADDR;
        addAuthorizedSender(address(SERVICE_ADDR));
        vm = address(SERVICE_ADDR).code.length == 0;
    }

    modifier rnOnly() {
        if (vm) revert ReactiveNetworkOnly();
        _;
    }

    modifier vmOnly() {
        if (!vm) revert ReactVmOnly();
        _;
    }

}
