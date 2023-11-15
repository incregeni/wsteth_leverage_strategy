// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IWstETH.sol";
import "./interfaces/ISwapRouter.sol";
import {ICToken} from "./interfaces/ICToken.sol";

contract Strategy is AccessControl, ERC4626 {
    uint256 public constant FLOAT_PRECESION = 10e6;
    uint256 public leverageRatio;
    uint256 public totalAssetsAvailable;
    address public swapRouter;
    uint24 poolFee;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    event LeverageRatioChanged(uint256 indexed oldRatio, uint256 indexed newRatio);

    /// @notice we will use WstETH for asset
    constructor(address _asset, address _swapRouter, uint24 _poolFee) ERC4626(IERC20(_asset)) ERC20("YieldStrategy", "YSEth") {
        grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        swapRouter = _swapRouter;
        poolFee = _poolFee;
    }

    function setLeverageRatio(uint256 _ratio) external onlyRole(MANAGER_ROLE) {
        uint256 old = leverageRatio;
        leverageRatio = _ratio;
        emit LeverageRatioChanged(old, leverageRatio);
    }

    function harvest() external onlyRole(MANAGER_ROLE) {
        
    }

    /// @notice wrap Eth to WstETH
    function _wrap(uint256 wrapAmount) internal returns (uint256) {
        if(wrapAmount == 0) return 0;
        
        address stETH = IWstETH(asset()).stETH();

        /// @dev Wrap the ETH into stETH.
        uint256 mintedStETHAmount = IERC20(stETH).balanceOf(address(this));
        IStETH(stETH).submit{ value: wrapAmount }(address(this));
        mintedStETHAmount = IERC20(stETH).balanceOf(address(this)) - mintedStETHAmount;

        /// @dev Wrap the stETH into wstETH.
        SafeERC20.safeIncreaseAllowance(IERC20(stETH), asset(), mintedStETHAmount);
        uint256 mintedWstEthAmount = IWstETH(asset()).wrap(mintedStETHAmount);

        return mintedWstEthAmount;
    }

    /// @notice unwrap WstETH to Eth via DEX while we can not withdraw WstETH for ETH in one tx
    function _unwrap(uint256 unwrapAmount) internal returns (uint256) {
        if(unwrapAmount == 0) return 0;

        SafeERC20.safeIncreaseAllowance(IERC20(asset()), swapRouter, unwrapAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: asset(),
            tokenOut: ISwapRouter(swapRouter).WETH9(),
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: unwrapAmount,
            amountOutMinimum:  unwrapAmount * _price() * 98 / 100,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        return amountOut;
    }

    function _price() internal view returns(uint256) {
        return IWstETH(asset()).stEthPerToken();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        totalAssetsAvailable += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        totalAssetsAvailable -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        return totalAssetsAvailable;
    }
}
