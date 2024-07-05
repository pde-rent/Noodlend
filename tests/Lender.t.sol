// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Lender.sol";
import "../src/RebasingErc20.sol";
import {TestERC20} from "forge-std/Test.sol";

contract LenderTest is Test {
  Lender lender;
  TestERC20 collateralToken;
  TestERC20 borrowToken;
  RebasingErc20 lp;

  address user1; // Liquidity Provider
  address user2; // Borrower

  function setUp() public {
    // Deploy Test ERC20 Tokens (replace with actual addresses on testnet)
    collateralToken = new TestERC20(18); // 18 decimals
    borrowToken = new TestERC20(18);

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
      minRate: 100, // 1%
      maxRate: 2500, // 25%
      optimalRate: 500, // 5%
      optimalUtilization: 8000 // 80%
    });

    // Deploy Lender Contract
    lender = new Lender(
      address(collateralToken),
      address(borrowToken),
      priceFeed,
      riskParams,
      irStrategyParams
    );

    // Get the LP token from the lender contract
    lp = lender.lp();

    user1 = address(0x1);
    user2 = address(0x2);

    // Mint initial tokens to users
    collateralToken.mint(user1, 100000 * 1e18);
    borrowToken.mint(user2, 100000 * 1e18);
  }

  // Test Case 1: Normal P2Pool Loan (Repaid)
  function testNormalP2PoolLoan() public {
    vm.startPrank(user1); // Liquidity Provider
    borrowToken.approve(address(lender), 1000 * 1e18);
    lender.addLiquidity(1000 * 1e18);
    vm.stopPrank();

    vm.startPrank(user2); // Borrower
    collateralToken.approve(address(lender), 2000 * 1e18);
    lender.borrow(1000 * 1e18, 30 days);

    vm.warp(block.timestamp + 30 days); // Simulate time passing
    borrowToken.approve(address(lender), 1010 * 1e18); // Approve repayment with interest
    lender.repay(1);
    vm.stopPrank();

    assertEq(lender.loans(1).status, Lender.Status.Repaid);
  }

  // Test Case 2: Defaulting P2Pool Loan (Liquidated)
  function testDefaultingP2PoolLoan() public {
    vm.startPrank(user1); // Liquidity Provider
    borrowToken.approve(address(lender), 1000 * 1e18);
    lender.addLiquidity(1000 * 1e18);
    vm.stopPrank();

    vm.startPrank(user2); // Borrower
    collateralToken.approve(address(lender), 2000 * 1e18);
    lender.borrow(1000 * 1e18, 30 days);
    vm.stopPrank();

    vm.warp(block.timestamp + 31 days); // Simulate time passing (grace period)
    lender.liquidate(1); // Liquidate the loan

    assertEq(lender.loans(1).status, Lender.Status.Liquidated);
  }

  // Test Case 3: Normal P2P Loan (Repaid)
  function testNormalP2PLoan() public {
    vm.startPrank(user1); // Lender
    borrowToken.approve(address(lender), 1000 * 1e18);
    vm.stopPrank();

    vm.startPrank(user2); // Borrower
    collateralToken.approve(address(lender), 2000 * 1e18);
    lender.requestP2PLoan(1000 * 1e18, 30 days, user1);
    vm.stopPrank();

    vm.startPrank(user1); // Lender
    lender.matchP2PLoanRequest(1);
    vm.stopPrank();

    vm.warp(block.timestamp + 30 days); // Simulate time passing
    vm.startPrank(user2); // Borrower
    borrowToken.approve(address(lender), 1010 * 1e18); // Approve repayment with interest
    lender.repay(1);
    vm.stopPrank();

    assertEq(lender.loans(1).status, Lender.Status.Repaid);
  }

  // Test Case 4: Defaulting P2P Loan (Liquidated)
  function testDefaultingP2PLoan() public {
    // ... (similar to testNormalP2PLoan, but don't repay and liquidate instead)
    vm.startPrank(user1); // Lender
    borrowToken.approve(address(lender), 1000 * 1e18);
    vm.stopPrank();

    vm.startPrank(user2); // Borrower
    collateralToken.approve(address(lender), 2000 * 1e18);
    lender.requestP2PLoan(1000 * 1e18, 30 days, user1);
    vm.stopPrank();

    vm.startPrank(user1); // Lender
    lender.matchP2PLoanRequest(1);
    vm.stopPrank();

    vm.warp(block.timestamp + 31 days); // Simulate time passing (grace period)
    lender.liquidate(1); // Liquidate the loan

    assertEq(lender.loans(1).status, Lender.Status.Liquidated);
  }
}
