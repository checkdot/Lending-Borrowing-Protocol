// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
}

contract LendingPool is Ownable, ReentrancyGuard {
    struct Collateral {
        uint256 amount;
    }

    struct TokenConfig {
        uint256 weight; // 0-100, e.g., 100 = 1.0, 70 = 0.7
        bool isActive;
    }

    struct DebtInfo {
        uint256 principal;
        uint256 interestIndex;
        uint256 lastUpdateTime;
    }

    // Constants
    address public constant NATIVE_ETH = address(0);
    address public constant WBNB = 0xB8c77482e45F1F44dE1745F52C74426C631bDD52;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant CDT = 0xCdB37A4fBC2Da5b78aA4E41a432792f9533e85Cc;
    address public constant WBNB_WETH_PAIR =
        0x9E7809C21BA130c1A51C112928eA6474D9a9Ae3C; // WBNB/WETH v3 pair
    address public constant WETH_USDT_PAIR =
        0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852; // WETH/USDT pair
    address public constant CDT_WETH_PAIR =
        0x04eb5b4C9D8Becfc1F10a7e7C541B1169DC3aDc9; // CDT/WETH pair
    uint256 public constant MAX_BORROW_RATIO = 80; // 80% LTV
    uint256 public constant LIQUIDATION_THRESHOLD = 85; // 85% indebtedness threshold
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% bonus for liquidators
    uint256 private constant PRECISION = 1e18; // 18 decimals for precision
    uint256 public constant INTEREST_RATE_BASE = 2e16; // 2% base annual rate
    uint256 public constant INTEREST_RATE_SLOPE = 10e16; // 10% slope based on utilization
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant TIME_ELAPSE_INTERVAL = 5 minutes;

    // State variables
    mapping(address => mapping(address => Collateral)) public userCollateral; // user => token => collateral
    mapping(address => mapping(address => DebtInfo)) public userDebt; // user => token => debt info
    mapping(address => uint256) public totalCollateralPerToken; // token => total collateral in pool
    mapping(address => uint256) public totalDebtPerToken; // token => total debt in pool
    mapping(address => TokenConfig) public tokenConfigs;
    mapping(address => uint256) public reserves; // token => pool reserve amount
    mapping(address => uint256) public globalInterestIndex; // token => global interest index
    mapping(address => uint256) public lastInterestUpdate; // token => last update timestamp
    address[] public supportedTokens;

    // Events
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed token, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address indexed collateralToken,
        uint256 collateralAmount,
        address debtToken,
        uint256 debtRepaid
    );
    event TokenAdded(address indexed token, uint256 weight);
    event PoolFunded(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event PoolFundsWithdrawn(
        address indexed owner,
        address indexed token,
        uint256 amount
    );
    event InterestAccrued(address indexed token, uint256 newIndex);

    constructor() Ownable(msg.sender) {
        // Initialize supported tokens
        _addToken(USDT, 100); // 1.0 weight
        _addToken(NATIVE_ETH, 70); // 0.7 weight
        _addToken(USDC, 100); // 1.0 weight
        _addToken(WBNB, 70); // 0.7 weight
        _addToken(CDT, 50); // 0.5 weight

        // Initialize interest indices
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            globalInterestIndex[supportedTokens[i]] = PRECISION;
            lastInterestUpdate[supportedTokens[i]] =
                (block.timestamp / TIME_ELAPSE_INTERVAL) *
                TIME_ELAPSE_INTERVAL;
        }
    }

    function _addToken(address token, uint256 weight) internal {
        require(weight > 0 && weight <= 100, "Invalid weight");
        require(tokenConfigs[token].weight == 0, "Token already exists");

        tokenConfigs[token] = TokenConfig({weight: weight, isActive: true});
        supportedTokens.push(token);
        emit TokenAdded(token, weight);
    }

    function addToken(address token, uint256 weight) external onlyOwner {
        _addToken(token, weight);
        globalInterestIndex[token] = PRECISION;
        lastInterestUpdate[token] =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;
    }

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");

        _transferIn(token, msg.sender, amount);
        userCollateral[msg.sender][token].amount += amount;
        totalCollateralPerToken[token] += amount;
        reserves[token] += amount;

        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");
        require(
            userCollateral[msg.sender][token].amount >= amount,
            "Insufficient collateral"
        );

        // Accrue interest before checking health
        _accrueInterest(token);

        TokenConfig memory config = tokenConfigs[token];

        uint256 currentCapacity = getBorrowCapacity(msg.sender);
        uint256 totalDebtUSD = getTotalDebtUSD(msg.sender);

        // Calculate the USD value being withdrawn (with weight applied)
        uint256 withdrawalUSD = (((amount * getTokenPrice(token)) / PRECISION) *
            config.weight) / 100;

        // Check if withdrawal would make position unhealthy
        // After withdrawal: (capacity - withdrawalUSD) * MAX_BORROW_RATIO / 100 >= totalDebtUSD
        require(
            currentCapacity > withdrawalUSD,
            "Withdrawal exceeds available collateral"
        );

        uint256 remainingCapacity = currentCapacity - withdrawalUSD;
        require(
            (remainingCapacity * MAX_BORROW_RATIO) / 100 >= totalDebtUSD,
            "Withdrawal would make position unhealthy"
        );

        userCollateral[msg.sender][token].amount -= amount;
        totalCollateralPerToken[token] -= amount;
        reserves[token] -= amount;

        _transferOut(token, msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }

    function getTokenPrice(address token) public view returns (uint256) {
        _ensureTokenSupported(token);

        if (token == USDT || token == USDC) {
            return 1e18; // $1.00 in 18 decimals
        }

        if (token == NATIVE_ETH || token == WETH) {
            // WETH price = USDT balance / WETH balance in WETH/USDT pair
            return _getV2Price(WETH_USDT_PAIR, USDT, WETH);
        }

        if (token == WBNB) {
            // WBNB price = WETH price * (WETH balance / WBNB balance in WBNB/WETH pair)
            uint256 wethPrice = _getV2Price(WETH_USDT_PAIR, USDT, WETH);
            uint256 wbnbPrice = _getV3Price(WBNB_WETH_PAIR, WBNB, WETH);
            return (wethPrice * wbnbPrice) / PRECISION;
        }

        if (token == CDT) {
            // CDT price = WETH price * (WETH balance / CDT balance in CDT/WETH pair)
            uint256 wethPrice = _getV2Price(WETH_USDT_PAIR, USDT, WETH);
            uint256 cdtPrice = _getV3Price(CDT_WETH_PAIR, CDT, WETH);
            return (wethPrice * cdtPrice) / PRECISION;
        }

        revert("No price calculation for token");
    }

    function _getV2Price(
        address pair,
        address tokenA,
        address tokenB
    ) internal view returns (uint256) {
        uint256 reserveA = IERC20(tokenA).balanceOf(pair);
        uint256 reserveB = IERC20(tokenB).balanceOf(pair);
        require(reserveA > 0 && reserveB > 0, "Zero reserves in pair");
        return (reserveA * PRECISION) / reserveB;
    }

    function _getV3Price(
        address pool,
        address tokenA,
        address tokenB
    ) internal view returns (uint256) {
        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96, , , , , , ) = uniswapPool.slot0();
        if (uniswapPool.token0() == tokenA) {
            return
                (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >>
                (96 * 2);
        } else {
            return
                (1e18 << (96 * 2)) /
                (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
        }
    }

    function getBorrowCapacity(address user) public view returns (uint256) {
        uint256 capacity;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 amount = userCollateral[user][token].amount;
            TokenConfig memory config = tokenConfigs[token];

            if (amount > 0 && config.isActive) {
                uint256 valueUSD = (amount * getTokenPrice(token)) / PRECISION;
                uint256 weighted = (valueUSD * config.weight) / 100;
                capacity += weighted;
            }
        }
        return capacity;
    }

    function getUserDebtAmount(
        address user,
        address token
    ) public view returns (uint256) {
        DebtInfo memory debt = userDebt[user][token];
        if (debt.principal == 0) return 0;

        // Calculate current interest index
        uint256 currentIndex = _calculateCurrentIndex(token);

        // Return debt with accrued interest
        return (debt.principal * currentIndex) / debt.interestIndex;
    }

    function getTotalDebtUSD(address user) public view returns (uint256) {
        uint256 totalDebtUSD;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 debt = getUserDebtAmount(user, token);
            if (debt > 0) {
                uint256 debtUSD = (debt * getTokenPrice(token)) / PRECISION;
                totalDebtUSD += debtUSD;
            }
        }
        return totalDebtUSD;
    }

    function getIndebtedness(address user) public view returns (uint256) {
        uint256 capacity = getBorrowCapacity(user);
        if (capacity == 0) return 0;
        uint256 totalDebtUSD = getTotalDebtUSD(user);
        return (totalDebtUSD * 100) / capacity;
    }

    function _calculateCurrentIndex(
        address token
    ) internal view returns (uint256) {
        uint256 lastIndex = globalInterestIndex[token];
        uint256 lastUpdate = lastInterestUpdate[token];

        uint256 currentTime = (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        if (lastUpdate == currentTime) {
            return lastIndex;
        }

        uint256 timeElapsed = currentTime - lastUpdate;
        uint256 utilizationRate = _getUtilizationRate(token);
        uint256 borrowRate = _getBorrowRate(utilizationRate);

        // Calculate interest: index * (1 + rate * time / SECONDS_PER_YEAR)
        uint256 interestFactor = PRECISION +
            (borrowRate * timeElapsed) /
            SECONDS_PER_YEAR;
        return (lastIndex * interestFactor) / PRECISION;
    }

    function _accrueInterest(address token) internal {
        uint256 newIndex = _calculateCurrentIndex(token);
        globalInterestIndex[token] = newIndex;
        lastInterestUpdate[token] =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        emit InterestAccrued(token, newIndex);
    }

    function _getUtilizationRate(
        address token
    ) internal view returns (uint256) {
        uint256 totalSupply = reserves[token] + totalDebtPerToken[token];
        if (totalSupply == 0) return 0;

        return (totalDebtPerToken[token] * PRECISION) / totalSupply;
    }

    function _getBorrowRate(
        uint256 utilizationRate
    ) internal pure returns (uint256) {
        // Rate = BASE_RATE + SLOPE * utilization
        return
            INTEREST_RATE_BASE +
            (INTEREST_RATE_SLOPE * utilizationRate) /
            PRECISION;
    }

    function borrow(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");
        require(reserves[token] >= amount, "Insufficient pool reserve");

        // Accrue interest before borrowing
        _accrueInterest(token);

        uint256 capacity = getBorrowCapacity(msg.sender);
        uint256 currentDebtUSD = getTotalDebtUSD(msg.sender);
        uint256 borrowUSD = (amount * getTokenPrice(token)) / PRECISION;
        uint256 maxBorrowUSD = (capacity * MAX_BORROW_RATIO) / 100;

        require(
            currentDebtUSD + borrowUSD <= maxBorrowUSD,
            "Exceeds borrowing limit"
        );

        // Update user debt with current interest index
        DebtInfo storage debt = userDebt[msg.sender][token];
        if (debt.principal > 0) {
            // Accrue existing debt
            uint256 currentDebt = getUserDebtAmount(msg.sender, token);
            debt.principal = currentDebt + amount;
        } else {
            debt.principal = amount;
        }
        debt.interestIndex = globalInterestIndex[token];
        debt.lastUpdateTime =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        totalDebtPerToken[token] += amount;
        reserves[token] -= amount;

        _transferOut(token, msg.sender, amount);

        emit Borrowed(msg.sender, token, amount);
    }

    function repay(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");

        // Accrue interest before repayment
        _accrueInterest(token);

        uint256 currentDebt = getUserDebtAmount(msg.sender, token);
        require(currentDebt > 0, "No debt to repay");
        require(amount <= currentDebt, "Repay amount exceeds debt");

        _transferIn(token, msg.sender, amount);

        DebtInfo storage debt = userDebt[msg.sender][token];

        // Calculate how much principal to reduce
        uint256 newDebt = currentDebt - amount;
        debt.principal = newDebt;
        debt.interestIndex = globalInterestIndex[token];
        debt.lastUpdateTime =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        // Reduce by the amount of principal (not including accrued interest that was paid)
        uint256 principalReduction = amount;
        if (totalDebtPerToken[token] >= principalReduction) {
            totalDebtPerToken[token] -= principalReduction;
        } else {
            totalDebtPerToken[token] = 0;
        }

        reserves[token] += amount;

        emit Repaid(msg.sender, token, amount);
    }

    function liquidate(
        address user,
        address debtToken,
        uint256 debtAmount,
        address collateralToken
    ) external payable nonReentrant {
        _ensureTokenSupported(debtToken);
        _ensureTokenSupported(collateralToken);

        // Accrue interest before liquidation
        _accrueInterest(debtToken);
        _accrueInterest(collateralToken);

        uint256 capacity = getBorrowCapacity(user);
        uint256 totalDebtUSD = getTotalDebtUSD(user);

        require(capacity > 0, "User has no collateral");
        require(totalDebtUSD > 0, "User has no debt");
        require(
            getIndebtedness(user) > LIQUIDATION_THRESHOLD,
            "User not eligible for liquidation"
        );

        uint256 userDebtAmount = getUserDebtAmount(user, debtToken);
        require(userDebtAmount > 0, "User has no debt in this token");
        require(debtAmount <= userDebtAmount, "Debt amount too high");

        // Liquidator pays the debt
        _transferIn(debtToken, msg.sender, debtAmount);

        // Calculate collateral to seize (with liquidation bonus)
        uint256 debtValueUSD = (debtAmount * getTokenPrice(debtToken)) /
            PRECISION;
        uint256 collateralValueUSD = (debtValueUSD *
            (100 + LIQUIDATION_BONUS)) / 100;
        uint256 collateralPrice = getTokenPrice(collateralToken);
        uint256 collateralToSeize = (collateralValueUSD * PRECISION) /
            collateralPrice;

        uint256 userCollateralAmount = userCollateral[user][collateralToken]
            .amount;
        require(
            userCollateralAmount > 0,
            "User has no collateral in this token"
        );

        // Cap at available collateral
        if (collateralToSeize > userCollateralAmount) {
            collateralToSeize = userCollateralAmount;
        }

        // Update user debt
        DebtInfo storage debt = userDebt[user][debtToken];
        uint256 currentDebt = getUserDebtAmount(user, debtToken);
        uint256 newDebt = currentDebt - debtAmount;
        debt.principal = newDebt;
        debt.interestIndex = globalInterestIndex[debtToken];
        debt.lastUpdateTime =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        totalDebtPerToken[debtToken] -= debtAmount;

        // Transfer collateral to liquidator
        userCollateral[user][collateralToken].amount -= collateralToSeize;
        totalCollateralPerToken[collateralToken] -= collateralToSeize;

        // Debt goes to reserves, collateral goes to liquidator
        reserves[debtToken] += debtAmount;
        reserves[collateralToken] -= collateralToSeize;

        _transferOut(collateralToken, msg.sender, collateralToSeize);

        emit Liquidated(
            msg.sender,
            user,
            collateralToken,
            collateralToSeize,
            debtToken,
            debtAmount
        );
    }

    function fundPool(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");

        _transferIn(token, msg.sender, amount);

        reserves[token] += amount;
        emit PoolFunded(msg.sender, token, amount);
    }

    function withdrawPoolFunds(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");

        // Can only withdraw excess reserves (not borrowed funds)
        uint256 availableToWithdraw = reserves[token] -
            totalDebtPerToken[token];
        require(
            amount <= availableToWithdraw,
            "Cannot withdraw borrowed funds"
        );

        reserves[token] -= amount;

        _transferOut(token, owner(), amount);

        emit PoolFundsWithdrawn(owner(), token, amount);
    }

    function _transferIn(address token, address from, uint256 amount) internal {
        if (token == NATIVE_ETH) {
            require(msg.value == amount, "Invalid ETH amount");
        } else {
            require(msg.value == 0, "ETH not allowed");
            require(
                IERC20(token).transferFrom(from, address(this), amount),
                "ERC20 transfer failed"
            );
        }
    }

    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_ETH) {
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            require(
                IERC20(token).transfer(to, amount),
                "ERC20 transfer failed"
            );
        }
    }

    function _ensureTokenSupported(address token) internal view {
        require(tokenConfigs[token].isActive, "Unsupported token");
    }

    receive() external payable {
        reserves[NATIVE_ETH] += msg.value;
        emit PoolFunded(msg.sender, NATIVE_ETH, msg.value);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // View functions for interest rates
    function getCurrentBorrowRate(
        address token
    ) external view returns (uint256) {
        uint256 utilization = _getUtilizationRate(token);
        return _getBorrowRate(utilization);
    }

    function getUtilizationRate(address token) external view returns (uint256) {
        return _getUtilizationRate(token);
    }
}
