import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("Strategy", function () {
  /// All params here are from Ethereum mainnet
  const WSTETH_ADDRESS = "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0";
  const WETH_ADDRESS = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
  const AAVE_POOL_ADDRESS = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";
  const UNI_ROUTER_ADDRESS = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
  const UNI_POOL_FEE = 100; // for WstETH/ETH pool
  const BASIC_DECIMALS = 18;
  const ETH_SWAP_AMOUNT = ethers.utils.parseUnits("100", BASIC_DECIMALS);
  const BASIC_DEPOSIT_AMOUNT = ethers.utils.parseUnits("10", BASIC_DECIMALS);
  const PERCENTAGE_FACTOR = 10000;
  const RECURRING_CALL_LIMIT = 8;

    
  const checkPositionValid = (totalAsset: any, totalWstETHAmount: any, leverageRatio: any) => {
    expect(totalWstETHAmount.mul(10000).div(totalAsset).toNumber() / 10000).to.be.at.most(Number(leverageRatio * 101 / 100));
    expect(totalWstETHAmount.mul(10000).div(totalAsset).toNumber() / 10000).to.be.at.least(Number(leverageRatio * 99 / 100));
  }

  before(async function () {
    [this.owner, this.alice, this.bob] = await ethers.getSigners();

    const Strategy = await ethers.getContractFactory("Strategy");
    this.strategyContract = await Strategy.deploy(WSTETH_ADDRESS, AAVE_POOL_ADDRESS, UNI_ROUTER_ADDRESS, UNI_POOL_FEE);
    await this.strategyContract.deployed();

    /// get WETH for test
    this.WETH = await ethers.getContractAt("IWETH9", WETH_ADDRESS);
    await this.WETH.connect(this.alice).deposit({value:ETH_SWAP_AMOUNT.mul(60)});
    await this.WETH.connect(this.bob).deposit({value:ETH_SWAP_AMOUNT.mul(30)});
    await this.WETH.connect(this.owner).deposit({value:ETH_SWAP_AMOUNT.mul(30)});

    /// get WstETH for test
    this.uniswapV3Router = await ethers.getContractAt("ISwapRouter", UNI_ROUTER_ADDRESS);
    this.WETH = await ethers.getContractAt("IERC20", WETH_ADDRESS);

    this.WstETH = await ethers.getContractAt("IERC20", WSTETH_ADDRESS);
    await this.WETH.connect(this.alice).approve(this.uniswapV3Router.address, ETH_SWAP_AMOUNT.mul(30));
    await this.uniswapV3Router.connect(this.alice).exactInputSingle({      
      tokenIn: WETH_ADDRESS,
      tokenOut: WSTETH_ADDRESS,
      fee: UNI_POOL_FEE,
      recipient: this.alice.address,
      deadline: Math.floor(Date.now() / 1000 + 300),
      amountIn: ETH_SWAP_AMOUNT.mul(30),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0
    });
    await this.WstETH.connect(this.alice).transfer(this.owner.address, ETH_SWAP_AMOUNT.mul(10));
    await this.WstETH.connect(this.alice).transfer(this.bob.address, ETH_SWAP_AMOUNT.mul(10));
  });

  describe("Initialize", async function () {
    it("setLeverageRatio", async function () {
      await expect(this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR)).to.be.revertedWith("Too low leverage ratio");
      await expect(this.strategyContract.connect(this.alice).setLeverageRatio(PERCENTAGE_FACTOR * 1.2)).to.be.revertedWithCustomError;
      await this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR * 3);
    });
  });
  describe("Deposit", async function () {
    it("deposit1", async function () {
      await this.WstETH.connect(this.alice).approve(this.strategyContract.address, BASIC_DEPOSIT_AMOUNT);
      await this.strategyContract.connect(this.alice).deposit(BASIC_DEPOSIT_AMOUNT, this.alice.address);

      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.most(BASIC_DEPOSIT_AMOUNT);
      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.least(BASIC_DEPOSIT_AMOUNT.mul(99).div(100));
    });
    it("deposit2", async function () {
      await this.WstETH.connect(this.bob).approve(this.strategyContract.address, BASIC_DEPOSIT_AMOUNT);
      await this.strategyContract.connect(this.bob).deposit(BASIC_DEPOSIT_AMOUNT, this.bob.address);

      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.most(BASIC_DEPOSIT_AMOUNT);
      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.least(BASIC_DEPOSIT_AMOUNT.mul(99).div(100));
    });
    it("deposit3", async function () {
      await this.WstETH.connect(this.owner).approve(this.strategyContract.address, BASIC_DEPOSIT_AMOUNT);
      await this.strategyContract.connect(this.owner).deposit(BASIC_DEPOSIT_AMOUNT, this.owner.address);

      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.most(BASIC_DEPOSIT_AMOUNT);
      expect(await this.strategyContract.balanceOf(this.alice.address)).to.be.at.least(BASIC_DEPOSIT_AMOUNT.mul(99).div(100));
    });
  });
  
  describe("Harvest", async function () {
    it("harvest-reverted", async function () {
      await expect(this.strategyContract.connect(this.alice).harvest(RECURRING_CALL_LIMIT)).to.be.revertedWithCustomError;
      await expect(this.strategyContract.harvest(13)).to.be.revertedWith("Too big recurring call limit");
    });
    it("harvest-leverage", async function () {
      await this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR * 2);  /// set leverage as 2x
      await this.strategyContract.harvest(RECURRING_CALL_LIMIT);
      
      checkPositionValid(await this.strategyContract.totalAssets(), await this.strategyContract.totalWstETHCollateralAmount(), 2);
    });
    it("harvest-deleverage", async function () {
      await this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR * 1.5);  /// set leverage as 1.5x
      await this.strategyContract.harvest(RECURRING_CALL_LIMIT);

      checkPositionValid(await this.strategyContract.totalAssets(), await this.strategyContract.totalWstETHCollateralAmount(), 1.5);
    });
    it("harvest-high-recurring-call", async function () {
      await this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR * 4);  /// set leverage as 1.5x
      await this.strategyContract.harvest(1);
      await this.strategyContract.setLeverageRatio(PERCENTAGE_FACTOR * 1.5);  /// set leverage as 1.5x
      await this.strategyContract.harvest(RECURRING_CALL_LIMIT);
    });
  });
  describe("Withdraw", async function () {
    it("withdraw", async function () {
      await this.strategyContract.connect(this.alice).withdraw(ethers.utils.parseUnits("5", BASIC_DECIMALS), this.alice.address, this.alice.address);

      checkPositionValid(await this.strategyContract.totalAssets(), await this.strategyContract.totalWstETHCollateralAmount(), 1.5);
    });
  });
  describe("Other", async function () {
    it("check position", async function () {
      console.log("total WstETH collateral amount : ", await this.strategyContract.totalWstETHCollateralAmount());
      console.log("capital WstETH amount : ", await this.strategyContract.totalAssets());
      console.log("total WETH debt amount : ", await this.strategyContract.totalETHDebtAmount());
    });

  });
});
