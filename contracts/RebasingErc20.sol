// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RebasingErc20 is ERC20, Ownable, ReentrancyGuard {
  ERC20 public immutable underlying; // underlying ERC20 token
  uint8 private immutable _decimals; // decimals of the token
  uint256 private constant PRECISION = 1e18; // precision for calculations

  event Deposit(address indexed user, uint256 amount); // event for deposit
  event Withdraw(address indexed user, uint256 amount); // event for withdrawal

  // constructor to initialize the token
  constructor(string memory name, string memory symbol, uint8 decimals_, address underlying_) 
    ERC20(name, symbol) 
    Ownable(msg.sender) 
  {
    underlying = ERC20(underlying_);
    _decimals = decimals_;
  }

  // returns the number of decimals of the token
  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }


  function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external onlyOwner {
    _burn(from, amount);
  }

  // deposits tokens to the contract
  function deposit(uint256 amount) external {
    return deposit(msg.sender, amount); // calls internal deposit function
  }

  // deposits tokens to the contract for a specific receiver
  function deposit(address receiver, uint256 amount) public nonReentrant {
    require(amount > 0, "Amount must be greater than zero"); // ensures amount is positive
    uint256 totalUnderlyingBefore = underlying.balanceOf(address(this)); // balance before transfer
    underlying.transferFrom(receiver, address(this), amount); // transfers tokens from user to contract
    uint256 mintAmount = (amount * totalSupply() * PRECISION) / totalUnderlyingBefore; // calculates mint amount
    mintAmount = mintAmount / PRECISION; // adjusts for precision
    _mint(receiver, mintAmount); // mints new tokens
    emit Deposit(receiver, amount); // emits deposit event
  }

  // withdraws tokens from the contract
  function withdraw(uint256 lpAmount) external {
    return withdraw(msg.sender, lpAmount); // calls internal withdraw function
  }

  // withdraws tokens from the contract for a specific owner
  function withdraw(address owner, uint256 lpAmount) public nonReentrant {
    require(lpAmount > 0, "Amount must be greater than zero"); // ensures amount is positive
    uint256 totalUnderlyingBalance = underlying.balanceOf(address(this)); // balance of underlying tokens
    uint256 withdrawAmount = (lpAmount * totalUnderlyingBalance * PRECISION) / totalSupply(); // calculates withdraw amount
    withdrawAmount = withdrawAmount / PRECISION; // adjusts for precision
    _burn(owner, lpAmount); // burns tokens
    underlying.transfer(owner, withdrawAmount); // transfers underlying tokens to user
    emit Withdraw(owner, withdrawAmount); // emits withdraw event
  }

  // returns the balance of an account
  function balanceOf(address account) public view virtual override returns (uint256) {
    uint256 totalUnderlyingBalance = underlying.balanceOf(address(this)); // balance of underlying tokens
    if (totalSupply() == 0 || totalUnderlyingBalance == 0) return super.balanceOf(account); // if no supply or no balance, return normal balance
    return (super.balanceOf(account) * totalUnderlyingBalance * PRECISION) / totalSupply() / PRECISION; // calculates adjusted balance
  }

  // transfers tokens
  function transfer(address to, uint256 amount) public virtual override returns (bool) {
    uint256 adjustedAmount = (amount * PRECISION) / _getExchangeRate(); // adjusts amount based on exchange rate
    return super.transfer(to, adjustedAmount); // performs transfer
  }

  // transfers tokens from one account to another
  function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
    uint256 adjustedAmount = (amount * PRECISION) / _getExchangeRate(); // adjusts amount based on exchange rate
    return super.transferFrom(from, to, adjustedAmount); // performs transfer
  }

  // returns the current exchange rate
  function _getExchangeRate() internal view returns (uint256) {
    if (totalSupply() == 0) return PRECISION; // if no supply, return precision
    return (underlying.balanceOf(address(this)) * PRECISION) / totalSupply(); // calculates exchange rate
  }
}
