# WstETH Leverage Strategy

This contract exposes users to leveraged WstETH position to earn additional staking rewards by utilizing Aave lending protocol.

It uses OpenZeppelin's ERC4626 and is tested on Ethereum forked network and average coverage ratio is over 90%.
It overrides and changes logic of `totalAssets()` function due to it's capability of leveraged lending, so inflation attack is not possible.

Try running some of the following tasks:

```shell
npx hardhat test
npx hardhat coverage
```

## Workflow

### Harvest

The manager(operator who has manager role) can call this function to adjust the contract's leveraged position to keep the leverage ratio as stored one.
If the position is smaller than expected one, it will call `leverage()` function (it uses recursive funcion call to leverage position) and if the position is bigger than expected, it will call `deleverage()` function

### Deposit

Users deposit WstETH and the contract directly deposit asset to the Aave protocol

### Withdraw

Users can withdraw WstETH by buring their shares.
The withdrawn WsthETH amount is calculated as below

```math
( total deposited WstETH amount - total borrowed WETH amount * WETH amount per WstETH ) * shares / total shares
```

#### P . S

Lybra finance launched LST backed stable token(eUSD) and it's omnichain version(peUSD) and is now widely expanding.
