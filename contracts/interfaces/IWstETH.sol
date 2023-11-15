// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IStETH {
    function submit(address _referral) external payable returns (uint256);
}

interface IWstETH {
    function decimals() external view returns (uint8);

    function stETH() external view returns (address);

    function stEthPerToken() external view returns (uint256);

    function wrap(uint256 _stETHAmount) external returns (uint256);

    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}
