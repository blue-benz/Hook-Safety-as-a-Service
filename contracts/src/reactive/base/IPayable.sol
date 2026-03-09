// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPayable {
    receive() external payable;

    function debt(address target) external view returns (uint256);
}
