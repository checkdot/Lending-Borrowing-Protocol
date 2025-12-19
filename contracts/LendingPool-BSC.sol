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
            uint32 feeProtocol,
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
        address pair;
        bool isV2Pair;
        address pairToken;
    }

    struct DebtInfo {
        uint256 principal;
        uint256 interestIndex;
        uint256 lastUpdateTime;
    }

    // Constants
    address public constant NATIVE_BNB = address(0);
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address public constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address public constant CDT = 0x0cBD6fAdcF8096cC9A43d90B45F65826102e3eCE;
    address public constant WBNB_USDT_PAIR =
        0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE; // WBNB/USDT pair
    address public constant WETH_USDT_PAIR =
        0x531FEbfeb9a61D948c384ACFBe6dCc51057AEa7e; // WETH/USDT pair
    address public constant CDT_WBNB_PAIR =
        0xf8104aAa719D31ea25dC494576593c10a8f929E6; // CDT/WBNB pair
    uint256 public constant MAX_BORROW_RATIO = 80; // 80% LTV
    uint256 public constant LIQUIDATION_THRESHOLD = 85; // 85% indebtedness threshold
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% bonus for liquidators
    uint256 private constant PRECISION = 1e18; // 18 decimals for precision
    uint256 public constant INTEREST_RATE_BASE = 2e16; // 2% base annual rate
    uint256 public constant INTEREST_RATE_SLOPE = 10e16; // 10% slope based on utilization
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant TIME_ELAPSE_INTERVAL = 5 minutes;

    uint256 public lastEventNonce;

    // State variables
    address public feeWallet;
    uint256 public depositFee = 3;

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
        uint256 amount,
        uint256 nonce
    );
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 nonce
    );
    event Borrowed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 nonce
    );
    event Repaid(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 nonce
    );
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address indexed collateralToken,
        uint256 collateralAmount,
        address debtToken,
        uint256 debtRepaid,
        uint256 nonce
    );
    event TokenAdded(
        address indexed token,
        uint256 weight,
        address pair,
        bool isV2Pair
    );
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

    event FeeConfigUpdated(address indexed newFeeWallet, uint256 newDepositFee);

    constructor(address _feeWallet) Ownable(msg.sender) {
        feeWallet = _feeWallet;

        // Initialize supported tokens
        _addToken(USDT, 100, address(0), false, USDT); // 1.0 weight
        _addToken(USDC, 100, address(0), false, USDC); // 1.0 weight
        _addToken(NATIVE_BNB, 70, WBNB_USDT_PAIR, true, USDT); // 0.7 weight
        _addToken(WETH, 70, WETH_USDT_PAIR, true, USDT); // 0.7 weight
        _addToken(CDT, 50, CDT_WBNB_PAIR, false, WBNB); // 0.5 weight
    }

    function setFeeConfig(
        address _feeWallet,
        uint256 _depositFee
    ) external onlyOwner {
        feeWallet = _feeWallet;
        depositFee = _depositFee;
        emit FeeConfigUpdated(_feeWallet, _depositFee);
    }

    function addToken(
        address token,
        uint256 weight,
        address pair,
        bool isV2Pair,
        address pairToken
    ) external onlyOwner {
        _addToken(token, weight, pair, isV2Pair, pairToken);
    }

    function _addToken(
        address token,
        uint256 weight,
        address pair,
        bool isV2Pair,
        address pairToken
    ) internal {
        require(weight > 0 && weight <= 100, "Invalid weight");
        require(tokenConfigs[token].weight == 0, "Token already exists");
        require(
            pairToken == USDC || pairToken == USDT || pairToken == WBNB,
            "Invalid pair token"
        );

        tokenConfigs[token] = TokenConfig({
            weight: weight,
            isActive: true,
            pair: pair,
            isV2Pair: isV2Pair,
            pairToken: pairToken
        });
        supportedTokens.push(token);

        globalInterestIndex[token] = PRECISION;
        lastInterestUpdate[token] =
            (block.timestamp / TIME_ELAPSE_INTERVAL) *
            TIME_ELAPSE_INTERVAL;

        emit TokenAdded(token, weight, pair, isV2Pair);
    }

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        _ensureTokenSupported(token);
        require(amount > 0, "Amount must be greater than zero");

        uint256 fee = (amount * depositFee) / 10000;
        uint256 amountAfterFee = amount - fee;

        _transferIn(token, msg.sender, amount);

        if (fee > 0) {
            _transferOut(token, feeWallet, fee);
        }

        userCollateral[msg.sender][token].amount += amountAfterFee;
        totalCollateralPerToken[token] += amountAfterFee;
        reserves[token] += amountAfterFee;

        lastEventNonce = lastEventNonce + 1;

        emit Deposited(msg.sender, token, amount, lastEventNonce);
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
            currentCapacity >= withdrawalUSD,
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

        lastEventNonce = lastEventNonce + 1;

        emit Withdrawn(msg.sender, token, amount, lastEventNonce);
    }

    function getTokenPrice(address token) public view returns (uint256) {
        _ensureTokenSupported(token);

        TokenConfig memory config = tokenConfigs[token];

        if (token == USDT || token == USDC) {
            return 1e18; // $1.00 in 18 decimals
        }

        if (token == NATIVE_BNB || token == WBNB) {
            return _getV2Price(WBNB_USDT_PAIR, USDT, WBNB);
        }

        if (config.isV2Pair) {
            if (config.pairToken == USDC || config.pairToken == USDT) {
                return _getV2Price(config.pair, config.pairToken, token);
            } else {
                return
                    (_getV2Price(config.pair, WBNB, token) *
                        _getV2Price(WBNB_USDT_PAIR, USDT, WBNB)) / PRECISION;
            }
        } else {
            if (config.pairToken == USDC || config.pairToken == USDT) {
                return _getV3Price(config.pair, token, config.pairToken);
            } else {
                return
                    (_getV3Price(config.pair, token, WBNB) *
                        _getV2Price(WBNB_USDT_PAIR, USDT, WBNB)) / PRECISION;
            }
        }
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

        uint256 timeElapsed = (currentTime - lastUpdate);
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

        lastEventNonce = lastEventNonce + 1;

        emit Borrowed(msg.sender, token, amount, lastEventNonce);
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

        lastEventNonce = lastEventNonce + 1;

        emit Repaid(msg.sender, token, amount, lastEventNonce);
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

        lastEventNonce = lastEventNonce + 1;

        emit Liquidated(
            msg.sender,
            user,
            collateralToken,
            collateralToSeize,
            debtToken,
            debtAmount,
            lastEventNonce
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
        if (token == NATIVE_BNB) {
            require(msg.value == amount, "Invalid BNB amount");
        } else {
            require(msg.value == 0, "BNB not allowed");
            require(
                IERC20(token).transferFrom(from, address(this), amount),
                "ERC20 transfer failed"
            );
        }
    }

    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_BNB) {
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "BNB transfer failed");
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
        reserves[NATIVE_BNB] += msg.value;
        emit PoolFunded(msg.sender, NATIVE_BNB, msg.value);
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
