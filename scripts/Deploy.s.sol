// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Lender.sol";
import "../src/RebasingErc20.sol";
import {TestERC20} from "forge-std/Test.sol";

contract DeployScript is Script {
  function run() public {
    vm.startBroadcast();

    // Deploy Test ERC20 Tokens (replace with actual addresses on testnet)
    TestERC20 collateralToken = new TestERC20(18); // 18 decimals
    TestERC20 borrowToken = new TestERC20(18);

    // Deploy Chainlink Price Feed Mock (replace with actual address on testnet)
    address priceFeed = address(0x6135b13325bfC4B00278B4abC5e20bbce2D6580e); // GOERLI ETH/USD

    // Set Risk and Interest Rate Parameters
    Lender.RiskParams memory riskParams = Lender.RiskParams({
      ltv: 8000, // 80%
      liquidationThresholdMarkup: 1050, // 5%
      liquidationThresholdCap: 9000, // 90%
      liquidationFee: 500 // 5%
    });

    Lender.IrStrategyParams memory irStrategyParams = Lender.IrStrategyParams({
      minRate: 20, // .20% min utilization APR
      maxRate: 90, // 90% max utilization APR
      optimalRate: 1_000, // 10% equilibria APR
      optimalUtilization: 8_000 // 80% equilibria utilization
    });

    // Deploy Lender Contract
    Lender lender = new Lender(
      address(collateralToken),
      address(borrowToken),
      priceFeed,
      riskParams,
      irStrategyParams
    );

    vm.stopBroadcast();

    // Print Addresses for Reference
    console.log("Collateral Token:", address(collateralToken));
    console.log("Borrow Token:", address(borrowToken));
    console.log("Lender Contract:", address(lender));
  }
}
