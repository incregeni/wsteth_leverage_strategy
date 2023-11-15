// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IWstETH.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/IFlashLoanReceiver.sol";

contract Strategy is IFlashLoanReceiver, AccessControl, ERC4626 {
    uint256 public constant PERCENTAGE_FACTOR = 1e4;
    uint256 public constant RECURRING_CALL_LIMIT = 10;
    uint256 public constant INTEREST_RATE_MODE = 1; // stable rate mode
    uint256 public leverageRatio;
    // uint256 public totalAssetsDeposited;
    address public swapRouter;
    uint24 public poolFee;
    address public aavePool;
    address WETH;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    event LeverageRatioChanged(
        uint256 indexed oldRatio,
        uint256 indexed newRatio
    );

    /// @notice we will use WstETH for asset
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

    function setLeverageRatio(uint256 _ratio) external onlyRole(MANAGER_ROLE) {
        uint256 old = leverageRatio;
        leverageRatio = _ratio;
        emit LeverageRatioChanged(old, leverageRatio);
    }

    function harvest(uint8 recurringCallLimit) external onlyRole(MANAGER_ROLE) {
        require(
            recurringCallLimit <= RECURRING_CALL_LIMIT,
            "Too big call limit"
        );
        uint256 expectedPositionSize = (totalAssets() * leverageRatio) /
            PERCENTAGE_FACTOR;
        uint16 ltvPercent = uint16(
            IAavePool(aavePool).getConfiguration(asset()).data >> 240
        );
        uint256 totalWstETHCollateralAmount = _totalWstETHCollateralAmount();
        if (expectedPositionSize == totalWstETHCollateralAmount) return;
        else if (expectedPositionSize > totalWstETHCollateralAmount) {
            _leverage(
                expectedPositionSize - totalWstETHCollateralAmount,
                0,
                ltvPercent,
                0,
                recurringCallLimit
            );
        } else {
            _deleverage(totalWstETHCollateralAmount - expectedPositionSize);
        }
    }

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
        uint256 maximumBorrowableAmount = (_totalWstETHCollateralAmount() *
            _priceTolerance() *
            ltvPercent) /
            PERCENTAGE_FACTOR -
            _totalETHDebtAmount();

        uint256 borrowETHAmount = desiredETHAmount > maximumBorrowableAmount
            ? maximumBorrowableAmount
            : desiredETHAmount;
        IAavePool(aavePool).borrow(
            WETH,
            borrowETHAmount,
            INTEREST_RATE_MODE,
            0,
            address(this)
        );
        uint256 mintedWstETHAmount = _wrap(borrowETHAmount);
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

    function _deleverage(
        uint256 wstETHAmount
    ) internal returns (uint256 repaidETHAmount) {
        IAavePool(aavePool).flashLoanSimple(
            address(this),
            WETH,
            (wstETHAmount * _price()) / (10 ** IWstETH(asset()).decimals()),
            abi.encode(wstETHAmount),
            0
        );
    }

    function totalAssets() public view override returns (uint256) {
        return
            _totalWstETHCollateralAmount() -
            ((_totalETHDebtAmount() * _price()) /
                (10 ** IWstETH(asset()).decimals()));
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // totalAssetsDeposited += assets;
        super._deposit(caller, receiver, assets, shares);
        IWstETH wstETH = IWstETH(asset());
        uint256 unwrappedStETHAmount = wstETH.unwrap(assets);
        SafeERC20.safeIncreaseAllowance(
            IERC20(asset()),
            aavePool,
            unwrappedStETHAmount
        );
        IAavePool(aavePool).supply(asset(), assets, address(this), 0);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // totalAssetsDeposited -= assets;
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

    function _totalETHDebtAmount()
        internal
        view
        returns (uint256 ethDebtAmount)
    {
        address ETHDebtTokenAddress = IAavePool(aavePool)
            .getReserveData(WETH)
            .stableDebtTokenAddress;
        uint256 ethDebtAmount = IERC20(ETHDebtTokenAddress).balanceOf(
            address(this)
        );
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

        IWETH9(WETH).deposit{value: amountOut}();
        return amountOut;
    }

    function _priceTolerance() internal view returns (uint256) {
        return (_price() * 98) / 100;
    }

    function _price() internal view returns (uint256) {
        return IWstETH(asset()).stEthPerToken();
    }
}
