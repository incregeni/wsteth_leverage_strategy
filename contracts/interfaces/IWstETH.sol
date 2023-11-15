// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IWstETH {    
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}