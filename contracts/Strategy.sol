// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract Strategy is AccessControl, ERC4626 {
    uint256 public constant FLOAT_PRECESION = 10e6;
    uint256 public leverageRatio;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice we will use WETH for asset
    constructor(address _asset) ERC4626(IERC20(_asset)) ERC20("YieldStrategy", "YSEth") {
        grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setLeverageRatio(uint256 _ratio) external onlyRole(MANAGER_ROLE) {
        leverageRatio = _ratio;
    }
}
