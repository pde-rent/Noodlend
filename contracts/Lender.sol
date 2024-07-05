// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@abdk/ABDKMath64x64.sol";
import "./RebasingErc20.sol";

interface ILiquidator {
  function liquidateCallback(
    address collateralToken,
    uint256 collateralAmount,
    address borrowToken,
    uint256 borrowAmount
  ) external returns (bool);
}

contract Lender is Ownable, ReentrancyGuard, Pausable {
  using SafeERC20 for IERC20;
  using ABDKMath64x64 for int128;
  using ABDKMath64x64 for uint256;

  // constants
  uint256 public constant ACCOUNTING_BASE = 10_000; // base for percentage calculations
  uint256 public constant QUOTE_SCALE = 1e18; // scale for price quotes

  // tokens and ratios
  IERC20 public collateralToken;
  IERC20 public borrowToken;
  RebasingErc20 public lp; // rebasing lp token

  // chainlink price feed
  AggregatorV3Interface public priceFeed;

  // risk parameters
  struct RiskParams {
    uint256 ltv;
    uint256 liquidationThresholdMarkup;
    uint256 liquidationThresholdCap;
    uint256 liquidationFee;
    uint256 liquidationMaxSlippage;
  }
  RiskParams public riskParams;

  // interest rate strategy parameters
  struct IrStrategyParams {
    uint256 minRate;
    uint256 maxRate;
    uint256 optimalRate;
    uint256 optimalUtilization;
  }
  IrStrategyParams public irStrategyParams;

  // accounting and tracking
  uint256 public totalLoanOriginated; // total amount of loans issued
  uint256 public currentTotalDebt; // current total outstanding debt including interest
  uint256 public totalBadDebt; // total bad debt from forced liquidations

  // loan statuses
  enum Status {
    Pending,
    Active,
    Overdue,
    Repaid,
    Liquidated
  }

  // loan structure
  struct Loan {
    uint256 index;
    address borrower;
    uint256 amount;
    uint256 collateralAmount;
    uint256 duration;
    uint256 startTime;
    uint256 interestRate;
    bool isP2P;
    address lender;
    Status status;
  }

  // loans indexed by borrower and global index
  uint256 public loanIndex;
  mapping(address => uint256[]) public loansByBorrower;
  mapping(uint256 => Loan) public loans;

  // events
  event LoanCreated(
    uint256 indexed loanIndex,
    address indexed borrower,
    uint256 amount,
    uint256 collateralAmount,
    uint256 duration,
    uint256 interestRate,
    bool isP2P,
    address indexed lender
  );
  event LoanMatched(uint256 indexed loanIndex, address indexed lender);
  event LoanRepaid(
    uint256 indexed loanIndex,
    address indexed borrower,
    uint256 amount
  );
  event LoanLiquidated(
    uint256 indexed loanIndex,
    address indexed liquidator,
    uint256 collateralSeized,
    uint256 debtCovered,
    uint256 badDebtIncurred
  );
  event LoanCanceled(uint256 indexed loanIndex, address indexed borrower);
  event LiquidityAdded(address indexed lender, uint256 amount);
  event LiquidityRemoved(address indexed lender, uint256 amount);
  event RiskParamsUpdated(
    uint256 ltv,
    uint256 liquidationThresholdMarkup,
    uint256 liquidationThresholdCap,
    uint256 liquidationFee
  );
  event IrStrategyParamsUpdated(
    uint256 minRate,
    uint256 maxRate,
    uint256 optimalRate,
    uint256 optimalUtilization
  );

  // constructor to initialize the contract
  constructor(
    address _collateralToken,
    address _borrowToken,
    address _priceFeed,
    RiskParams memory _riskParams,
    IrStrategyParams memory _irStrategyParams
  ) Ownable(msg.sender) {
    collateralToken = IERC20(_collateralToken);
    borrowToken = IERC20(_borrowToken);
    setPriceFeed(_priceFeed);
    setRiskParams(_riskParams);
    setIrStrategyParams(_irStrategyParams);
    lp = new RebasingErc20("Rebasing LP Token", "RLPT", 18, _borrowToken);
  }

  // add liquidity to the pool == supply
  function addLiquidity(uint256 amount) external nonReentrant whenNotPaused {
    lp.deposit(msg.sender, amount); // mint lp tokens to lender
    emit LiquidityAdded(msg.sender, amount);
  }

  // remove liquidity from the pool
  function removeLiquidity(
    uint256 amount
  ) external nonReentrant whenNotPaused {
    lp.withdraw(msg.sender, amount); // burn lp tokens from lender
    emit LiquidityRemoved(msg.sender, amount);
  }

  // p2pool borrow tokens against collateral
  function borrow(
    uint256 amount,
    uint256 duration
  ) external nonReentrant whenNotPaused {
    require(duration > 0 && duration <= 365 days, "invalid duration");
    uint256 collateralAmount = (amount * ACCOUNTING_BASE * QUOTE_SCALE) /
      (riskParams.ltv * getQuote());
    require(
      collateralToken.balanceOf(msg.sender) >= collateralAmount,
      "insufficient collateral"
    );
    require(lp.balanceOf(address(this)) >= amount, "insufficient liquidity");

    collateralToken.safeTransferFrom(
      msg.sender,
      address(this),
      collateralAmount
    );
    lp.transfer(msg.sender, amount);

    uint256 interestRate = getInterestRate(getUtilizationRate(amount)); // use previewed utilization rate and not the current one
    _createLoan(
      msg.sender,
      amount,
      collateralAmount,
      duration,
      interestRate,
      false,
      address(this)
    );
  }

  // request a p2p loan
  function requestP2PLoan(
    uint256 amount,
    uint256 duration,
    address lender
  ) external nonReentrant whenNotPaused {
    require(duration > 0 && duration <= 365 days, "invalid duration");
    uint256 collateralAmount = (amount * ACCOUNTING_BASE * QUOTE_SCALE) /
      (riskParams.ltv * getQuote());
    require(
      collateralToken.balanceOf(msg.sender) >= collateralAmount,
      "insufficient collateral"
    );

    collateralToken.safeTransferFrom(
      msg.sender,
      address(this),
      collateralAmount
    );

    uint256 interestRate = getInterestRate(getUtilizationRate(amount));
    _createLoan(
      msg.sender,
      amount,
      collateralAmount,
      duration,
      interestRate,
      true,
      lender
    );
  }

  // match a pending p2p loan request
  function matchP2PLoanRequest(
    uint256 _loanIndex
  ) external nonReentrant whenNotPaused {
    Loan storage loan = loans[_loanIndex];
    require(loan.lender == msg.sender, "not the specified lender");
    require(loan.status == Status.Pending, "loan not pending");

    borrowToken.safeTransferFrom(msg.sender, address(lp), loan.amount);
    lp.transfer(loan.borrower, loan.amount);

    loan.status = Status.Active;
    loan.startTime = block.timestamp;
    currentTotalDebt += loan.amount; // increase current total debt when p2p loan is matched
    emit LoanMatched(_loanIndex, msg.sender);
  }

  // repay an active or overdue loan
  function repay(uint256 _loanIndex) external nonReentrant whenNotPaused {
    Loan storage loan = loans[_loanIndex];
    require(
      loan.status == Status.Active || loan.status == Status.Overdue,
      "loan not active or overdue"
    );

    uint256 totalDue = _calculateTotalDue(loan);
    borrowToken.safeTransferFrom(msg.sender, address(this), totalDue);

    if (loan.isP2P) {
      borrowToken.safeTransfer(loan.lender, totalDue);
    } else {
      lp.mint(address(this), totalDue - loan.amount); // mint interest to pool (rebase supply)
    }

    collateralToken.safeTransfer(loan.borrower, loan.collateralAmount);

    currentTotalDebt -= totalDue; // decrease current total debt
    loan.status = Status.Repaid;
    emit LoanRepaid(_loanIndex, msg.sender, totalDue);
  }

  // liquidate an overdue loan (p2pool and p2p)
  function liquidate(uint256 _loanIndex) external nonReentrant whenNotPaused {
    Loan storage loan = loans[_loanIndex];
    require(
      loan.status == Status.Active || loan.status == Status.Overdue,
      "loan not active or overdue"
    );

    uint256 totalDue = _calculateTotalDue(loan);
    uint256 collateralValue = (loan.collateralAmount * getQuote()) /
      QUOTE_SCALE;

    // check for liquidation conditions (threshold breach or term violation)
    bool termViolation = block.timestamp >= loan.startTime + loan.duration; // could add a gracePeriod as risk parameter
    bool thresholdBreach = collateralValue < (totalDue * riskParams.liquidationThresholdMarkup) / ACCOUNTING_BASE;
  
    require(termViolation || thresholdBreach, "no liquidation criteria met");

    uint256 liquidatorReward = (totalDue * riskParams.liquidationFee) /
      ACCOUNTING_BASE;
    uint256 lenderDue = totalDue - liquidatorReward;

    // use borrow tokens from the borrower
    uint256 borrowerBalance = borrowToken.balanceOf(loan.borrower);
    uint256 borrowerAllowance = borrowToken.allowance(
      loan.borrower,
      address(this)
    );
    uint256 availableBorrowTokens = min(
      min(borrowerBalance, borrowerAllowance),
      totalDue
    );

    if (availableBorrowTokens > 0) {
      borrowToken.safeTransferFrom(
        loan.borrower,
        address(this),
        availableBorrowTokens
      );
    }

    uint256 remainingDue = totalDue > availableBorrowTokens
      ? totalDue - availableBorrowTokens
      : 0;
    uint256 collateralToLiquidate = 0;
    uint256 badDebtIncurred = 0;
    uint256 retrievedFromCollateral = 0;

    if (remainingDue > 0) {
      // use collateral for the remaining due amount
      collateralToLiquidate = min(
        loan.collateralAmount,
        (remainingDue * QUOTE_SCALE) / getQuote()
      );
      collateralValue = (collateralToLiquidate * getQuote()) / QUOTE_SCALE;

      if (collateralValue < remainingDue) {
        badDebtIncurred = remainingDue - collateralValue;
        totalBadDebt += badDebtIncurred;
      }
      uint256 balanceBefore = borrowToken.balanceOf(address(this));

      collateralToken.safeTransfer(msg.sender, collateralToLiquidate); // transfer collateral to liquidator
      // expect liquidator to liquidate collateral and repay the remaining due to the contract
      ILiquidator(msg.sender).liquidateCallback(
        address(collateralToken),
        collateralToLiquidate,
        address(borrowToken),
        remainingDue
      );
      retrievedFromCollateral = borrowToken.balanceOf(address(this)) - balanceBefore;
      require(retrievedFromCollateral < remainingDue * (ACCOUNTING_BASE - riskParams.liquidationMaxSlippage) / ACCOUNTING_BASE, "liquidation slippage exceeded");
    }

    availableBorrowTokens += retrievedFromCollateral;
    // distribute funds
    if (loan.isP2P) {
      borrowToken.safeTransfer(
        loan.lender,
        min(lenderDue, availableBorrowTokens)
      );
    } else {
      lp.mint(
        address(this),
        min(lenderDue, availableBorrowTokens) - loan.amount
      ); // accrue interests in pool
    }

    // transfer liquidator reward
    uint256 liquidatorBorrowTokens = min(
      liquidatorReward,
      availableBorrowTokens > lenderDue ? availableBorrowTokens - lenderDue : 0
    );
    if (liquidatorBorrowTokens > 0) {
      borrowToken.safeTransfer(msg.sender, liquidatorBorrowTokens);
    }

    // return any excess collateral to the borrower
    if (collateralToLiquidate < loan.collateralAmount) {
      collateralToken.safeTransfer(
        loan.borrower,
        loan.collateralAmount - collateralToLiquidate
      );
    }

    currentTotalDebt -= totalDue; // decrease current total debt
    loan.status = Status.Liquidated;
    emit LoanLiquidated(
      _loanIndex,
      msg.sender,
      collateralToLiquidate,
      totalDue,
      badDebtIncurred
    );
  }

  // cancel a pending p2p loan
  function cancelPendingLoan(
    uint256 _loanIndex
  ) external nonReentrant whenNotPaused {
    Loan storage loan = loans[_loanIndex];
    require(loan.borrower == msg.sender, "not the borrower");
    require(
      loan.status == Status.Pending,
      "cannot cancel active or repaid loan"
    );

    collateralToken.safeTransfer(msg.sender, loan.collateralAmount);
    loan.status = Status.Repaid; // mark as repaid to close the loan
    emit LoanCanceled(_loanIndex, msg.sender);
  }

  // set the price feed address
  function setPriceFeed(address _priceFeed) public onlyOwner {
    require(_priceFeed != address(0), "invalid price feed address");
    priceFeed = AggregatorV3Interface(_priceFeed);
  }

  // set the risk parameters
  function setRiskParams(RiskParams memory _riskParams) public onlyOwner {
    require(
      _riskParams.ltv > 0 && _riskParams.ltv <= ACCOUNTING_BASE,
      "invalid ltv"
    );
    require(
      _riskParams.liquidationThresholdMarkup > 0,
      "invalid liquidation threshold markup"
    );
    require(
      _riskParams.liquidationThresholdCap <= ACCOUNTING_BASE,
      "invalid liquidation threshold cap"
    );
    require(
      _riskParams.liquidationFee <= ACCOUNTING_BASE / 2,
      "fee too high: max 50%"
    );
    require(
      _riskParams.liquidationMaxSlippage <= ACCOUNTING_BASE / 10,
      "slippage too high: max 10%"
    );
    riskParams = _riskParams;
    emit RiskParamsUpdated(
      _riskParams.ltv,
      _riskParams.liquidationThresholdMarkup,
      _riskParams.liquidationThresholdCap,
      _riskParams.liquidationFee
    );
  }

  // set the interest rate strategy parameters
  function setIrStrategyParams(
    IrStrategyParams memory _irStrategyParams
  ) public onlyOwner {
    require(
      _irStrategyParams.minRate < _irStrategyParams.maxRate,
      "invalid min/max rates"
    );
    require(
      _irStrategyParams.optimalRate > _irStrategyParams.minRate &&
        _irStrategyParams.optimalRate < _irStrategyParams.maxRate,
      "invalid optimal rate"
    );
    require(
      _irStrategyParams.optimalUtilization > 0 &&
        _irStrategyParams.optimalUtilization < ACCOUNTING_BASE,
      "invalid optimal utilization"
    );
    irStrategyParams = _irStrategyParams;
    emit IrStrategyParamsUpdated(
      _irStrategyParams.minRate,
      _irStrategyParams.maxRate,
      _irStrategyParams.optimalRate,
      _irStrategyParams.optimalUtilization
    );
  }

  // get quote (borrow token/collateral token price) from chainlink oracle
  function getQuote() public view returns (uint256) {
    (
      uint80 roundId,
      int256 price,
      ,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = priceFeed.latestRoundData();
    require(price > 0, "Invalid price");
    require(updatedAt > block.timestamp - 1 hours, "Stale price");
    require(answeredInRound >= roundId, "Stale price round");

    uint8 decimals = priceFeed.decimals();
    return uint256(price) * (10 ** (18 - decimals)); // Normalize to 18 decimals (QUOTE_SCALE exponent)
  }

  // get total supply of lp tokens
  function getTotalSupply() public view returns (uint256) {
    return lp.totalSupply();
  }

  // get current total debt
  function getCurrentTotalDebt() public view returns (uint256) {
    return currentTotalDebt;
  }

  // get utilization rate
  // get utilization rate
  function getUtilizationRate() public view returns (uint256) {
    uint256 totalSupply = getTotalSupply();
    if (totalSupply == 0) return 0;
    return (currentTotalDebt * ACCOUNTING_BASE) / totalSupply;
  }

  // get utilization rate with debt markup (preview used for ir calculation)
  function getUtilizationRate(
    uint256 debtMarkup
  ) public view returns (uint256) {
    uint256 totalSupply = getTotalSupply();
    if (totalSupply == 0) return 0;
    return ((currentTotalDebt + debtMarkup) * ACCOUNTING_BASE) / totalSupply;
  }

  // get interest rate based on utilization using a piecewise log interpolation
  function getInterestRate(uint256 utilization) public view returns (uint256) {
    if (utilization == 0) return irStrategyParams.minRate;
    if (utilization >= ACCOUNTING_BASE) return irStrategyParams.maxRate;

    int128 rate;
    if (utilization <= irStrategyParams.optimalUtilization) {
      // Interpolate between minRate and optimalRate
      int128 ratio = utilization.divu(irStrategyParams.optimalUtilization);
      rate = _interpolateLog(
        irStrategyParams.minRate.divu(ACCOUNTING_BASE),
        irStrategyParams.optimalRate.divu(ACCOUNTING_BASE),
        ratio
      );
    } else {
      // Interpolate between optimalRate and maxRate
      int128 ratio = (utilization - irStrategyParams.optimalUtilization).divu(
        ACCOUNTING_BASE - irStrategyParams.optimalUtilization
      );
      rate = _interpolateLog(
        irStrategyParams.optimalRate.divu(ACCOUNTING_BASE),
        irStrategyParams.maxRate.divu(ACCOUNTING_BASE),
        ratio
      );
    }
    return rate.mulu(ACCOUNTING_BASE);
  }

  function _interpolateLog(
    int128 min,
    int128 max,
    int128 ratio
  ) internal pure returns (int128) {
    int128 logMin = min.ln();
    int128 logMax = max.ln();
    int128 logResult = logMin.add((logMax.sub(logMin)).mul(ratio));
    return logResult.exp();
  }

  // internal function to create a loan
  function _createLoan(
    address borrower,
    uint256 amount,
    uint256 collateralAmount,
    uint256 duration,
    uint256 interestRate,
    bool isP2P,
    address lender
  ) internal {
    loanIndex++;
    loans[loanIndex] = Loan({
      index: loanIndex,
      borrower: borrower,
      amount: amount,
      collateralAmount: collateralAmount,
      duration: duration,
      startTime: isP2P ? 0 : block.timestamp,
      interestRate: interestRate,
      isP2P: isP2P,
      lender: lender,
      status: isP2P ? Status.Pending : Status.Active
    });

    loansByBorrower[borrower].push(loanIndex);
    totalLoanOriginated += amount;
    if (!isP2P) {
      currentTotalDebt += amount; // increase current total debt for non-p2p loans
    }
    emit LoanCreated(
      loanIndex,
      borrower,
      amount,
      collateralAmount,
      duration,
      interestRate,
      isP2P,
      lender
    );
  }

  function _calculateTotalDue(
    Loan storage loan
  ) internal view returns (uint256) {
    uint256 interestAmount = (loan.amount *
      loan.interestRate *
      (block.timestamp - loan.startTime)) / (ACCOUNTING_BASE * 365 days);
    return loan.amount + interestAmount;
  }

  // utility function: get the minimum of two numbers
  function min(uint256 a, uint256 b) public pure returns (uint256) {
    return a < b ? a : b;
  }

  // pause the contract
  function pause() external onlyOwner {
    _pause();
  }

  // unpause the contract
  function unpause() external onlyOwner {
    _unpause();
  }
}
