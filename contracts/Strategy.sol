// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import {IWstETH} from "./interfaces/IWstETH.sol";

contract Strategy is AccessControl, ERC4626 {
    uint256 public constant FLOAT_PRECESION = 10e6;
    uint256 public leverageRatio;
    uint256 public totalAssetsAvailable;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice we will use WstETH for asset
    constructor(address _asset) ERC4626(IERC20(_asset)) ERC20("YieldStrategy", "YSEth") {
        grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setLeverageRatio(uint256 _ratio) external onlyRole(MANAGER_ROLE) {
        leverageRatio = _ratio;
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
