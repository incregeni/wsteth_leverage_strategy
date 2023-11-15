// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IWstETH.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/IStrategy.sol";

import "hardhat/console.sol";

contract Strategy is IStrategy, AccessControl, ERC4626 {
    uint256 public constant PERCENTAGE_FACTOR = 1e4;
    uint256 public constant RECURRING_CALL_LIMIT = 10;
    uint256 public constant INTEREST_RATE_MODE = 2; // variable rate mode
    uint256 public leverageRatio;
    address public swapRouter;
    uint24 public poolFee;
    address public aavePool;
    address WETH;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice We will use WstETH for asset
    constructor(
        address _asset,
        address _lendingPool,
        address _swapRouter,
        uint24 _poolFee
    ) ERC4626(IERC20(_asset)) ERC20("YieldStrategy", "YSEth") {
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(MANAGER_ROLE, ADMIN_ROLE);

        swapRouter = _swapRouter;
        WETH = ISwapRouter(swapRouter).WETH9();
        aavePool = _lendingPool;
        poolFee = _poolFee;
    }

    /// @notice Managers can set leverage ratio
    function setLeverageRatio(uint256 _ratio) external onlyRole(MANAGER_ROLE) {
        uint256 old = leverageRatio;
        leverageRatio = _ratio;
        emit LeverageRatioChanged(old, leverageRatio);
    }

    /// @notice Adjust position size to leverageRatio * capitalAmount
    function harvest(
        uint8 recurringCallLimit
    )
        external
        onlyRole(MANAGER_ROLE)
        returns (
            uint256 adjustedWstETHAmount,
            uint256 adjustedETHAmount,
            bool isLeveraged
        )
    {
        require(
            recurringCallLimit <= RECURRING_CALL_LIMIT,
            "Too big call limit"
        );
        uint256 expectedPositionSize = (totalAssets() * leverageRatio) /
            PERCENTAGE_FACTOR;
        uint16 ltvPercent = uint16(
            (IAavePool(aavePool).getConfiguration(asset()).data << 240) >> 240
        );

        uint256 totalWstETHCollateralAmount = _totalWstETHCollateralAmount();
        if (expectedPositionSize == totalWstETHCollateralAmount)
            return (0, 0, true);
        else if (expectedPositionSize > totalWstETHCollateralAmount) {
            adjustedWstETHAmount =
                expectedPositionSize -
                totalWstETHCollateralAmount;
            adjustedETHAmount = _leverage(
                adjustedWstETHAmount,
                0,
                ltvPercent,
                0,
                recurringCallLimit
            );
            isLeveraged = true;
        } else {
            adjustedWstETHAmount =
                totalWstETHCollateralAmount -
                expectedPositionSize;
            adjustedETHAmount = _deleverage(adjustedWstETHAmount);
            isLeveraged = false;
        }
        emit Harvested(
            msg.sender,
            adjustedWstETHAmount,
            adjustedETHAmount,
            isLeveraged
        );
    }

    /// @notice Callback function for flashloan.
    /// Here the steps are that repay portion of loan with flash borrowed WETH,
    /// withdraw wstETH, and swap wstETH for WETH then repay the flashloan
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata params
    ) external returns (bool) {
        IAavePool(aavePool).repay(
            assets[0],
            amounts[0],
            INTEREST_RATE_MODE,
            address(this)
        );
        uint256 wstETHAmount = abi.decode(params, (uint256));

        IAavePool(aavePool).withdraw(asset(), wstETHAmount, address(this));

        uint256 unwrappedWETHAmount = _unwrap(wstETHAmount);

        SafeERC20.safeIncreaseAllowance(
            IERC20(WETH),
            aavePool,
            unwrappedWETHAmount
        );
        return true;
    }

    /// @notice Leverage position
    function _leverage(
        uint256 wstETHAmount,
        uint256 newlyBorrowedETH,
        uint16 ltvPercent,
        uint8 callCounter,
        uint8 callCountLimit
    ) internal returns (uint256) {
        if (callCounter > callCountLimit) return newlyBorrowedETH;
        uint256 desiredETHAmount = (wstETHAmount *
            (10 ** IWstETH(asset()).decimals())) / _price();

        console.log(
            "*** _totalWstETHCollateralAmount : ",
            _totalWstETHCollateralAmount()
        );
        console.log("*** _priceTolerance() : ", _priceTolerance());
        console.log("*** ltvPercent : ", ltvPercent);
        console.log("*** PERCENTAGE_FACTOR : ", PERCENTAGE_FACTOR);
        console.log("*** _totalETHDebtAmount() : ", _totalETHDebtAmount());
        uint256 maximumBorrowableAmount = (_totalWstETHCollateralAmount() *
            _priceTolerance() *
            ltvPercent) /
            PERCENTAGE_FACTOR -
            _totalETHDebtAmount();

        uint256 borrowETHAmount = desiredETHAmount > maximumBorrowableAmount
            ? maximumBorrowableAmount
            : desiredETHAmount;
        console.log("*** desiredETHAmount : ", desiredETHAmount);
        console.log("*** maximumBorrowableAmount : ", maximumBorrowableAmount);
        console.log("*** borrowETHAmount : ", borrowETHAmount);
        if (borrowETHAmount == 0) return newlyBorrowedETH;
        IAavePool(aavePool).borrow(
            WETH,
            borrowETHAmount,
            INTEREST_RATE_MODE,
            0,
            address(this)
        );
        uint256 mintedWstETHAmount = _wrap(borrowETHAmount);
        SafeERC20.safeIncreaseAllowance(
            IERC20(asset()),
            aavePool,
            mintedWstETHAmount
        );
        IAavePool(aavePool).supply(
            asset(),
            mintedWstETHAmount,
            address(this),
            0
        );
        if (desiredETHAmount > maximumBorrowableAmount) {
            return
                _leverage(
                    desiredETHAmount - borrowETHAmount,
                    newlyBorrowedETH + borrowETHAmount,
                    ltvPercent,
                    callCounter + 1,
                    callCountLimit
                );
        }
        return desiredETHAmount;
    }

    /// @notice Deleverage position with flashloan
    function _deleverage(
        uint256 wstETHAmount
    ) internal returns (uint256 repaidETHAmount) {
        repaidETHAmount =
            (wstETHAmount * _price()) /
            (10 ** IWstETH(asset()).decimals());
        IAavePool(aavePool).flashLoanSimple(
            address(this),
            WETH,
            repaidETHAmount,
            abi.encode(wstETHAmount),
            0
        );
    }

    /// @notice The function which returns the total asset amount which the contract can manage
    /// Calculated by total collateral amount(WstETH) minus total borrow amount(WETH)
    function totalAssets() public view override returns (uint256) {
        return
            _totalWstETHCollateralAmount() -
            ((_totalETHDebtAmount() * _price()) /
                (10 ** IWstETH(asset()).decimals()));
    }

    /// @notice Supply deposited WstETH to Aave Pool to increase collateral amount
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
        SafeERC20.safeIncreaseAllowance(IERC20(asset()), aavePool, assets);
        IAavePool(aavePool).supply(asset(), assets, address(this), 0);
    }

    /// @notice Repay and withdraw share-related WETH / WstETH with flashloan and send remaining WstETH to the user
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256,
        uint256 shares
    ) internal override {
        uint256 repayETHAmount = (_totalETHDebtAmount() * shares) /
            totalSupply();
        uint256 repayWstETHAmount = (_totalETHDebtAmount() *
            (10 ** IWstETH(asset()).decimals())) / _price();
        uint256 userWstETHAmount = (_totalWstETHCollateralAmount() * shares) /
            totalSupply();
        IAavePool(aavePool).flashLoanSimple(
            address(this),
            WETH,
            repayETHAmount,
            abi.encode(repayWstETHAmount),
            0
        );
        uint256 resultWstETHAmount = userWstETHAmount - repayWstETHAmount;
        IAavePool(aavePool).withdraw(
            asset(),
            resultWstETHAmount,
            address(this)
        );
        super._withdraw(caller, receiver, owner, resultWstETHAmount, shares);
    }

    /// @notice Getter function for total WstETH collateral amount of this contract in Aave(v3)
    function _totalWstETHCollateralAmount()
        internal
        view
        returns (uint256 wstETHCollateralAmount)
    {
        address aWstETH = IAavePool(aavePool)
            .getReserveData(asset())
            .aTokenAddress;
        wstETHCollateralAmount = IERC20(aWstETH).balanceOf(address(this));
    }

    /// @notice Getter function for total WETH debt amount of this contract in Aave(v3)
    function _totalETHDebtAmount()
        internal
        view
        returns (uint256 ethDebtAmount)
    {
        address ETHDebtTokenAddress = IAavePool(aavePool)
            .getReserveData(WETH)
            .variableDebtTokenAddress;
        ethDebtAmount = IERC20(ETHDebtTokenAddress).balanceOf(address(this));
    }

    /// @notice wrap Eth to WstETH
    function _wrap(uint256 wrapAmount) internal returns (uint256) {
        if (wrapAmount == 0) return 0;

        // Unwrap the WETH into ETH.
        IWETH9(WETH).withdraw(wrapAmount);

        /// @dev Wrap the ETH into stETH.
        address stETH = IWstETH(asset()).stETH();
        uint256 mintedStETHAmount = IERC20(stETH).balanceOf(address(this));
        IStETH(stETH).submit{value: wrapAmount}(address(this));
        mintedStETHAmount =
            IERC20(stETH).balanceOf(address(this)) -
            mintedStETHAmount;

        /// @dev Wrap the stETH into wstETH.
        SafeERC20.safeIncreaseAllowance(
            IERC20(stETH),
            asset(),
            mintedStETHAmount
        );
        uint256 mintedWstEthAmount = IWstETH(asset()).wrap(mintedStETHAmount);

        return mintedWstEthAmount;
    }

    /// @notice unwrap WstETH to Eth via DEX while we can not withdraw WstETH for ETH in one tx
    function _unwrap(uint256 unwrapAmount) internal returns (uint256) {
        if (unwrapAmount == 0) return 0;

        SafeERC20.safeIncreaseAllowance(
            IERC20(asset()),
            swapRouter,
            unwrapAmount
        );

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: asset(),
                tokenOut: WETH,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: unwrapAmount,
                amountOutMinimum: unwrapAmount * _priceTolerance(),
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);

        return amountOut;
    }

    /// @notice Price which is used for swap via DEX (uniswap)
    function _priceTolerance() internal view returns (uint256) {
        return (_price() * 98) / 100;
    }

    /// @notice WstETH redemption price for ETH
    function _price() internal view returns (uint256) {
        return IWstETH(asset()).stEthPerToken();
    }

    /// @notice receive function to receive eth
    receive() external payable {}
}
