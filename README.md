<div align="center">
  <img style="border-radius=25px; max-height=160px;" src="./banner.png" />
  <p>
    <a href="https://opensource.org/licenses/MIT"><img alt="License" src="https://img.shields.io/github/license/pde-rent/noodlend?style=social" /></a>
    <a href="https://twitter.com/jake_the_slug"><img alt="Twitter Follow" src="https://img.shields.io/twitter/follow/jake_the_slug?label=@JakeTheSlug&style=social"></a>
  </p>
</div>

### Overview

Noodlend is a DeFi lending protocol that enables isolated peer-to-pool and direct peer-to-peer lending of crypto assets. Inspired by Silo Finance, Aave, and PWN XYZ, Noodlend aims to offer a simple yet comprehensive lending solution with features such as an efficient interest rate curve and support for both types of loans.

### Features

- **Simple, Comprehensive Internals**: The protocol's architecture is designed for clarity and efficiency.
- **Support for P2P and P2Pool Loans**: Users can participate in both peer-to-peer and peer-to-pool lending.
- **Smoothed, Efficient Interest Rate Curve**: Utilizes piecewise interpolation for a stable and responsive interest rate.
- **Cross-Collateral Aggregation**: Similar to Morpho Blue and Euler V2 Vaults, Noodlend can serve as a primitive for contracts that aggregate cross-collateral.

### Core Methods

| Method                     | Description                                                                                                 |
|----------------------------|-------------------------------------------------------------------------------------------------------------|
| `addLiquidity`             | Adds liquidity to the pool by minting LP tokens to the lender.                                              |
| `removeLiquidity`          | Removes liquidity from the pool by burning LP tokens from the lender.                                       |
| `borrow`                   | Allows users to borrow tokens against collateral in a peer-to-pool fashion.                                 |
| `requestP2PLoan`           | Requests a peer-to-peer loan, specifying the amount, duration, and lender.                                  |
| `matchP2PLoanRequest`      | Matches a pending peer-to-peer loan request.                                                                |
| `repay`                    | Repays an active or overdue loan, transferring the due amount to the lender or pool.                        |
| `liquidate`                | Liquidates an overdue loan, utilizing a callback mechanism to ensure lenders are paid back in base assets.  |
| `cancelPendingLoan`        | Cancels a pending peer-to-peer loan, returning collateral to the borrower.                                  |
| `setPriceFeed`             | Sets the Chainlink price feed address for the protocol.                                                     |
| `setRiskParams`            | Updates the risk parameters, such as LTV and liquidation thresholds.                                        |
| `setIrStrategyParams`      | Updates the interest rate strategy parameters.                                                              |
| `getQuote`                 | Retrieves the current supply/collateral quote from Chainlink                                                |
| `getTotalSupply`           | Returns the total supply of LP tokens.                                                                      |
| `getCurrentTotalDebt`      | Returns the current total outstanding debt.                                                                 |
| `getUtilizationRate`       | Computes the current utilization rate of the pool.                                                          |
| `getInterestRate`          | Calculates the interest rate based on the utilization rate.                                                 |

### Deployment
TBD

### Contribution Guide

Contributions are welcome! Here are some ideas:

- **Implement the LendingAggregator.sol**: Create a contract that handles multiple collateral types.
- **Develop an Off-Chain Liquidation Bot**: Automate the liquidation process with an off-chain bot.
- **Build a User Interface**: Provide a minimal UI for interacting with the protocol.
- **Cross-Chain Collateral Support**: Enhance the protocol to accept and manage collateral from different blockchain networks.

### Inspiration

Noodlend draws inspiration from several lending projects:

- **Silo Finance:**  The isolated lending pool model, where each asset has its own pool, is inspired by Silo Finance. This design helps mitigate risks associated with multiple assets.
- **Aave:** The use of a rebasing LP token for P2Pool lending and the callback mechanism for liquidations are concepts borrowed from Aave. This allows for efficient liquidity management and flexible liquidation strategies.
- **PWN.xyz:** The idea of combining P2Pool and P2P lending in a single protocol is similar to the approach taken by PWN.xyz. This provides users with more options and flexibility.

### License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
