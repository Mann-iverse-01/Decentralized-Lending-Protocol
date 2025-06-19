// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/access/Ownable.sol";

/**
 * @title Decentralized Lending Protocol
 * @dev A basic lending platform for deposits, borrowing, interest, and liquidation
 */
contract Project is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120%
    uint256 public constant LIQUIDATION_PENALTY = 5; // 5%
    uint256 public constant BASE_INTEREST_RATE = 5; // 5% annual
    uint256 public constant UTILIZATION_MULTIPLIER = 20;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public totalDeposits;
    uint256 public totalBorrows;
    uint256 public lastUpdateTimestamp;
    uint256 public cumulativeInterestIndex;

    struct UserDeposit {
        uint256 amount;
        uint256 interestIndex;
        uint256 timestamp;
    }

    struct UserBorrow {
        uint256 amount;
        uint256 collateralAmount;
        uint256 interestIndex;
        uint256 timestamp;
        address collateralToken;
    }

    struct TokenInfo {
        bool isSupported;
        uint256 collateralFactor;
        uint256 price; // mock price in USD
    }

    mapping(address => UserDeposit) public deposits;
    mapping(address => UserBorrow) public borrows;
    mapping(address => TokenInfo) public supportedTokens;
    mapping(address => uint256) public userCollateralBalance;

    IERC20 public immutable lendingToken;

    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 remainingBalance);
    event Borrowed(address indexed user, uint256 amount, uint256 collateralAmount, address collateralToken);
    event Repaid(address indexed user, uint256 amount, uint256 remainingDebt);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 debtAmount, uint256 collateralSeized);
    event InterestRateUpdated(uint256 newRate);

    constructor(address _lendingToken) {
        lendingToken = IERC20(_lendingToken);
        cumulativeInterestIndex = 1e18;
        lastUpdateTimestamp = block.timestamp;

        supportedTokens[_lendingToken] = TokenInfo(true, 80, 1e18);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        _updateInterestRates();

        if (deposits[msg.sender].amount > 0) {
            uint256 interest = _calculateAccruedInterest(deposits[msg.sender].amount, deposits[msg.sender].interestIndex);
            deposits[msg.sender].amount += interest;
        }

        lendingToken.safeTransferFrom(msg.sender, address(this), amount);

        deposits[msg.sender].amount += amount;
        deposits[msg.sender].interestIndex = cumulativeInterestIndex;
        deposits[msg.sender].timestamp = block.timestamp;

        totalDeposits += amount;

        emit Deposited(msg.sender, amount, deposits[msg.sender].amount);
    }

    function borrow(uint256 borrowAmount, uint256 collateralAmount, address collateralToken) external nonReentrant {
        require(borrowAmount > 0 && collateralAmount > 0, "Invalid amounts");
        require(supportedTokens[collateralToken].isSupported, "Unsupported token");
        require(borrows[msg.sender].amount == 0, "Loan exists");

        _updateInterestRates();

        uint256 collateralValue = _getCollateralValue(collateralAmount, collateralToken);
        uint256 requiredCollateral = (borrowAmount * COLLATERAL_RATIO) / 100;
        require(collateralValue >= requiredCollateral, "Insufficient collateral");

        uint256 availableLiquidity = totalDeposits - totalBorrows;
        require(availableLiquidity >= borrowAmount, "Insufficient liquidity");

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        lendingToken.safeTransfer(msg.sender, borrowAmount);

        borrows[msg.sender] = UserBorrow({
            amount: borrowAmount,
            collateralAmount: collateralAmount,
            interestIndex: cumulativeInterestIndex,
            timestamp: block.timestamp,
            collateralToken: collateralToken
        });

        userCollateralBalance[msg.sender] += collateralAmount;
        totalBorrows += borrowAmount;

        emit Borrowed(msg.sender, borrowAmount, collateralAmount, collateralToken);
    }

    function repay(uint256 repayAmount) external nonReentrant {
        require(repayAmount > 0, "Repay > 0");
        require(borrows[msg.sender].amount > 0, "No debt");

        _updateInterestRates();

        uint256 accruedInterest = _calculateAccruedInterest(borrows[msg.sender].amount, borrows[msg.sender].interestIndex);
        uint256 totalDebt = borrows[msg.sender].amount + accruedInterest;

        uint256 actualRepayAmount = repayAmount > totalDebt ? totalDebt : repayAmount;
        lendingToken.safeTransferFrom(msg.sender, address(this), actualRepayAmount);

        if (actualRepayAmount >= totalDebt) {
            uint256 originalAmount = borrows[msg.sender].amount;
            address collateralToken = borrows[msg.sender].collateralToken;
            uint256 collateralToReturn = borrows[msg.sender].collateralAmount;

            delete borrows[msg.sender];
            userCollateralBalance[msg.sender] = 0;
            totalBorrows -= originalAmount;

            IERC20(collateralToken).safeTransfer(msg.sender, collateralToReturn);

            emit Repaid(msg.sender, actualRepayAmount, 0);
        } else {
            uint256 newDebt = totalDebt - actualRepayAmount;
            borrows[msg.sender].amount = newDebt;
            borrows[msg.sender].interestIndex = cumulativeInterestIndex;
            borrows[msg.sender].timestamp = block.timestamp;

            emit Repaid(msg.sender, actualRepayAmount, newDebt);
        }
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Withdraw > 0");
        require(deposits[msg.sender].amount > 0, "No deposit");

        _updateInterestRates();

        uint256 interest = _calculateAccruedInterest(deposits[msg.sender].amount, deposits[msg.sender].interestIndex);
        uint256 totalAvailable = deposits[msg.sender].amount + interest;

        require(amount <= totalAvailable, "Too much");
        require(amount <= totalDeposits - totalBorrows, "Low liquidity");

        deposits[msg.sender].amount = totalAvailable - amount;
        deposits[msg.sender].interestIndex = cumulativeInterestIndex;
        deposits[msg.sender].timestamp = block.timestamp;

        totalDeposits -= amount;

        lendingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, deposits[msg.sender].amount);
    }

    function liquidate(address borrower) external nonReentrant {
        require(borrows[borrower].amount > 0, "No loan");

        _updateInterestRates();

        uint256 accruedInterest = _calculateAccruedInterest(borrows[borrower].amount, borrows[borrower].interestIndex);
        uint256 totalDebt = borrows[borrower].amount + accruedInterest;

        uint256 collateralValue = _getCollateralValue(borrows[borrower].collateralAmount, borrows[borrower].collateralToken);
        uint256 liquidationValue = (totalDebt * LIQUIDATION_THRESHOLD) / 100;

        require(collateralValue < liquidationValue, "Not liquidatable");

        uint256 penalty = (totalDebt * LIQUIDATION_PENALTY) / 100;
        uint256 cost = totalDebt + penalty;

        address collateralToken = borrows[borrower].collateralToken;
        uint256 seizedCollateral = borrows[borrower].collateralAmount;

        lendingToken.safeTransferFrom(msg.sender, address(this), cost);
        IERC20(collateralToken).safeTransfer(msg.sender, seizedCollateral);

        uint256 originalAmount = borrows[borrower].amount;
        delete borrows[borrower];
        userCollateralBalance[borrower] = 0;
        totalBorrows -= originalAmount;

        emit Liquidated(borrower, msg.sender, totalDebt, seizedCollateral);
    }

    function _updateInterestRates() internal {
        if (block.timestamp > lastUpdateTimestamp) {
            uint256 utilization = (totalDeposits == 0) ? 0 : (totalBorrows * 100) / (totalDeposits + 1);
            uint256 rate = BASE_INTEREST_RATE + (utilization * UTILIZATION_MULTIPLIER) / 100;

            uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
            uint256 interest = (rate * timeElapsed) / SECONDS_PER_YEAR / 100;

            cumulativeInterestIndex += (cumulativeInterestIndex * interest) / 1e18;
            lastUpdateTimestamp = block.timestamp;

            emit InterestRateUpdated(rate);
        }
    }

    function _calculateAccruedInterest(uint256 principal, uint256 userIndex) internal view returns (uint256) {
        if (userIndex == 0) return 0;
        return (principal * (cumulativeInterestIndex - userIndex)) / 1e18;
    }

    function _getCollateralValue(uint256 amount, address token) internal view returns (uint256) {
        TokenInfo memory info = supportedTokens[token];
        return (amount * info.price * info.collateralFactor) / 100 / 1e18;
    }

    // Views
    function getUserDepositBalance(address user) external view returns (uint256) {
        if (deposits[user].amount == 0) return 0;
        uint256 interest = _calculateAccruedInterest(deposits[user].amount, deposits[user].interestIndex);
        return deposits[user].amount + interest;
    }

    function getUserBorrowBalance(address user) external view returns (uint256) {
        if (borrows[user].amount == 0) return 0;
        uint256 interest = _calculateAccruedInterest(borrows[user].amount, borrows[user].interestIndex);
        return borrows[user].amount + interest;
    }

    function getCurrentInterestRate() external view returns (uint256) {
        if (totalDeposits == 0) return BASE_INTEREST_RATE;
        uint256 utilization = (totalBorrows * 100) / totalDeposits;
        return BASE_INTEREST_RATE + (utilization * UTILIZATION_MULTIPLIER) / 100;
    }

    function getProtocolStats() external view returns (
        uint256 _totalDeposits,
        uint256 _totalBorrows,
        uint256 _utilizationRate,
        uint256 _interestRate
    ) {
        _totalDeposits = totalDeposits;
        _totalBorrows = totalBorrows;
        _utilizationRate = totalDeposits > 0 ? (totalBorrows * 100) / totalDeposits : 0;
        _interestRate = this.getCurrentInterestRate();
    }

    // Owner functions
    function addSupportedToken(address token, uint256 collateralFactor, uint256 price) external onlyOwner {
        require(collateralFactor <= 100, "Too high");
        supportedTokens[token] = TokenInfo(true, collateralFactor, price);
    }

    function updateTokenPrice(address token, uint256 newPrice) external onlyOwner {
        require(supportedTokens[token].isSupported, "Not supported");
        supportedTokens[token].price = newPrice;
    }
}

