// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICToken {    
    function borrow(uint borrowAmount) external returns (uint);
    function mint() external payable;
}