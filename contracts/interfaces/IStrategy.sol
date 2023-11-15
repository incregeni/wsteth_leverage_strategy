// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IFlashLoanReceiver.sol";

interface IStrategy is IFlashLoanReceiver {
    event LeverageRatioChanged(
        uint256 indexed oldRatio,
        uint256 indexed newRatio
    );

    event Harvested(
        address indexed manager,
        uint256 adjustedWstETHAmount,
        uint256 adjustedETHAmount,
        bool indexed isLeveraged
    );

    /// @notice Managers can set leverage ratio
    function setLeverageRatio(uint256 _ratio) external;

    /// @notice Adjust position size to leverageRatio * capitalAmount
    function harvest(
        uint8 recurringCallLimit
    )
        external
        returns (
            uint256 adjustedWstETHAmount,
            uint256 adjustedETHAmount,
            bool isLeveraged
        );

    /// @notice Callback function for flashloan.
    /// Here the steps are that repay portion of loan with flash borrowed WETH,
    /// withdraw wstETH, and swap wstETH for WETH then repay the flashloan
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata params
    ) external returns (bool);
}
