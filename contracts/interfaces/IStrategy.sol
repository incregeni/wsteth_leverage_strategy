// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IFlashLoanSimpleReceiver.sol";

interface IStrategy is IFlashLoanSimpleReceiver {
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

    function totalWstETHCollateralAmount() external view returns (uint256);

    function totalETHDebtAmount() external view returns (uint256);

    function estimatedUserPosition(
        address user
    ) external view returns (uint256 witdrawableWstETHAmount);

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
}
