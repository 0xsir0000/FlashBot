//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";

import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IWETH.sol";
import "./libraries/Decimal.sol";

struct OrderedReserves {
    uint256 a1; // 基础资产
    uint256 b1;
    uint256 a2;
    uint256 b2;
}

/* 套利信息 */
struct ArbitrageInfo {
    address baseToken; // 基础代币
    address quoteToken; // 套利代币
    bool baseTokenSmaller; //是否基础代币少
    address lowerPool; // 价格较低的矿池，以报价资产计价
    address higherPool; // 价格较高的矿池，以报价资产计价
}

/** 回调信息 */
struct CallbackData {
    address debtPool; // 债务池
    address targetPool; //目标池
    bool debtTokenSmaller; //债务代币更少
    address borrowedToken; // 套利代币
    address debtToken; //债务代币（基础代币）
    uint256 debtAmount; //债务金额
    uint256 debtTokenOutAmount; //套利池换出来的债务代币数量
}

contract FlashBotV3 is Ownable {
    using Decimal for Decimal.D256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable wallet =
        0x626B0bB69bC86aa0E8b5a1c167857a66514E36E1;

    mapping(address => uint256) public baseTokensMinProfit;
    // ETH 上的 WETH 或 BSC 上的 WBNB
    address immutable WBNB;

    // 可用的基础代币
    EnumerableSet.AddressSet baseTokens;

    event Withdrawn(address indexed to, uint256 indexed value);
    event BaseTokenAdded(address indexed token);
    event BaseTokenRemoved(address indexed token);

    constructor(address _WBNB, uint256 _minProfit) {
        WBNB = _WBNB;
        baseTokensMinProfit[WBNB] = _minProfit;
        baseTokens.add(WBNB);
    }

    //接受主币 暂时没用
    receive() external payable {}

    /// @dev 重定向uniswap回调函数
    /// 不同DEX上的回调函数不一样，所以使用fallback重定向到uniswapV2Call
    fallback() external {
        (
            address sender,
            uint256 amount0,
            uint256 amount1,
            bytes memory data
        ) = abi.decode(msg.data[4:], (address, uint256, uint256, bytes));
        uniswapV2Call(sender, amount0, amount1, data);
    }

    // 添加基础代币
    function addBaseToken(address token, uint256 _minProfit)
        external
        onlyOwner
    {
        baseTokens.add(token);
        baseTokensMinProfit[token] = _minProfit;
        emit BaseTokenAdded(token);
    }

    // 设置基础代币最小利润
    // 添加基础代币
    function setBaseTokenMinProfit(address token, uint256 _minProfit)
        external
        onlyOwner
    {
        baseTokensMinProfit[token] = _minProfit;
    }

    // 删除基础代币
    function removeBaseToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            // 不要在这里使用安全转移来防止任何糟糕的令牌还原
            IERC20(token).transfer(wallet, balance);
        }
        baseTokens.remove(token);
        emit BaseTokenRemoved(token);
    }

    // 获取基础代币
    function getBaseTokens() external view returns (address[] memory tokens) {
        uint256 length = baseTokens.length();
        tokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = baseTokens.at(i);
        }
    }

    /// @notice 在两个类似 Uniswap 的 AMM 池之间进行套利
    /// @dev 两个池必须包含相同的令牌对
    function flashArbitrageForYulin(
        address _lowerPool,
        address _higherPool,
        bool _isbaseTokenSmaller,
        address _baseToken,
        address _quoteToken,
        uint256 _borrowAmount
    ) external {
        uint256 lowerPoolBaseReserve = 0;
        uint256 lowerPoolQuoteReserve = 0;
        uint256 higherPoolBaseReserve = 0;
        uint256 higherPoolQuoteReserve = 0;
        if (_isbaseTokenSmaller) {
            (lowerPoolBaseReserve, lowerPoolQuoteReserve, ) = IUniswapV2Pair(
                _lowerPool
            ).getReserves();
            (higherPoolBaseReserve, higherPoolQuoteReserve, ) = IUniswapV2Pair(
                _higherPool
            ).getReserves();
        } else {
            (lowerPoolQuoteReserve, lowerPoolBaseReserve, ) = IUniswapV2Pair(
                _lowerPool
            ).getReserves();
            (higherPoolQuoteReserve, higherPoolBaseReserve, ) = IUniswapV2Pair(
                _higherPool
            ).getReserves();
        }
        // 在较低价格池中借入报价代币，计算我们需要支付多少债务，以基础代币为基础
        uint256 debtAmount = getAmountIn(
            _borrowAmount,
            lowerPoolBaseReserve,
            lowerPoolQuoteReserve
        );
        // 在更高的价格池上出售借来的报价代币，计算我们可以获得多少基础代币
        uint256 baseTokenOutAmount = getAmountOut(
            _borrowAmount,
            higherPoolQuoteReserve,
            higherPoolBaseReserve
        );
        if (
            debtAmount > baseTokenOutAmount ||
            (baseTokenOutAmount - debtAmount) < baseTokensMinProfit[_baseToken]
        ) {
            return;
        }
        // 避免堆栈太深错误
        {
            // 只能这样初始化，避免stack too deep错误
            CallbackData memory callbackData;
            callbackData.debtPool = _lowerPool;
            callbackData.targetPool = _higherPool;
            callbackData.debtTokenSmaller = _isbaseTokenSmaller;
            callbackData.borrowedToken = _quoteToken; //套利代币 借来的代币
            callbackData.debtToken = _baseToken; //债务代币 基础代币 需要还的代币
            callbackData.debtAmount = debtAmount; //债务金额
            callbackData.debtTokenOutAmount = baseTokenOutAmount; //从套利池子卖出换来的基础代币数量
            bytes memory data = abi.encode(callbackData);
            if (_isbaseTokenSmaller) {
                IUniswapV2Pair(callbackData.debtPool).swap(
                    uint256(0),
                    _borrowAmount,
                    address(this),
                    data
                );
            } else {
                IUniswapV2Pair(callbackData.debtPool).swap(
                    _borrowAmount,
                    uint256(0),
                    address(this),
                    data
                );
            }
        }

        uint256 balanceAfter = IERC20(_baseToken).balanceOf(address(this));
        require(balanceAfter > baseTokensMinProfit[_baseToken], "Losing money");

        // 把钱打到自己钱包
        IERC20(_baseToken).safeTransfer(wallet, balanceAfter);
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes memory data
    ) public {
        require(sender == address(this), "Not from this contract");

        uint256 borrowedAmount = amount0 > 0 ? amount0 : amount1;
        CallbackData memory info = abi.decode(data, (CallbackData));

        // 把借来的代币转到价格高的池子
        IERC20(info.borrowedToken).safeTransfer(
            info.targetPool,
            borrowedAmount
        );

        (uint256 amount0Out, uint256 amount1Out) = info.debtTokenSmaller
            ? (info.debtTokenOutAmount, uint256(0))
            : (uint256(0), info.debtTokenOutAmount);
        // 直接在价格高的池子里进行swap,不走DexRouter,传入可套取的基础代币数量，因为前边已经把套利代币转给swap了，new bytes(0)，要传0，不然无限回调
        IUniswapV2Pair(info.targetPool).swap(
            amount0Out,
            amount1Out,
            address(this),
            new bytes(0)
        );
        // 还款
        IERC20(info.debtToken).safeTransfer(info.debtPool, info.debtAmount);
    }

    /// @notice 通过在两个池之间进行套利，计算我们可以获得多少利润
    function getProfit(
        uint256 _a1,
        uint256 _a2,
        uint256 _b1,
        uint256 _b2,
        address _baseToken
    ) external view returns (bool isRun, uint256 borrowAmount) {
        uint256 amount = calcBorrowAmount(_a1, _a2, _b1, _b2);
        if (amount == uint256(0)) {
            return (false, uint256(0));
        }
        // 在较低价格池中借入报价代币，计算我们需要支付多少债务，以基础代币为基础
        uint256 debtAmount = getAmountIn(amount, _a1, _b1);
        console.log(debtAmount);
        // 在更高的价格池上出售借来的报价代币，计算我们可以获得多少基础代币
        uint256 baseTokenOutAmount = getAmountOut(amount, _b2, _a2);
        console.log("baseTokenOutAmount",baseTokenOutAmount);
        console.log("debtAmount",debtAmount);
        if (
            baseTokenOutAmount > debtAmount &&
            (baseTokenOutAmount - debtAmount) > baseTokensMinProfit[_baseToken]
        ) {
            isRun = true;
            borrowAmount = amount;
        }
    }

    /// @dev 计算套利时为了获得最大利润而借入的最大基础资产金额
    function calcBorrowAmount(
        uint256 _a1,
        uint256 _a2,
        uint256 _b1,
        uint256 _b2
    ) internal pure returns (uint256 amount) {
        // 我们不能直接使用 a1,b1,a2,b2，因为它会导致中间结果上溢/下溢
        // 所以我们:
        //    1. 将所有数字除以 d 以防止上溢/下溢
        //    2. 使用上述数字计算结果
        //    3.将d与结果相乘得到最终结果
        // 注意：此解决方法仅适用于 18 位小数的 ERC20 代币，我相信大多数代币都这样做

        uint256 min1 = _a1 < _a2 ? _a1 : _a2;
        uint256 min2 = _b1 < _b2 ? _b1 : _b2;
        uint256 min = min1 < min2 ? min1 : min2;
        // 根据最小数量选择合适的数量进行划分
        uint256 d;
        if (min > 1e24) {
            d = 1e20;
        } else if (min > 1e23) {
            d = 1e19;
        } else if (min > 1e22) {
            d = 1e18;
        } else if (min > 1e21) {
            d = 1e17;
        } else if (min > 1e20) {
            d = 1e16;
        } else if (min > 1e19) {
            d = 1e15;
        } else if (min > 1e18) {
            d = 1e14;
        } else if (min > 1e17) {
            d = 1e13;
        } else if (min > 1e16) {
            d = 1e12;
        } else if (min > 1e15) {
            d = 1e11;
        } else if (min > 1e14) {
            d = 1e10;
        } else if (min > 1e13) {
            d = 1e9;
        } else if (min > 1e12) {
            d = 1e8;
        } else if (min > 1e11) {
            d = 1e7;
        } else if (min > 1e10) {
            d = 1e6;
        } else {
            d = 1e5;
        }
        (int256 a1, int256 a2, int256 b1, int256 b2) = (
            int256(_a1 / d),
            int256(_a2 / d),
            int256(_b1 / d),
            int256(_b2 / d)
        );
        int256 a = a1 * b1 - a2 * b2;
        int256 b = 2 * b1 * b2 * (a1 + a2);
        int256 c = b1 * b2 * (a1 * b2 - a2 * b1);
        (int256 x1, int256 x2) = calcSolutionForQuadratic(a, b, c);
        // 0 < x < b1 and 0 < x < b2
        if ((x1 > 0 && x1 < b1 && x1 < b2) || (x2 > 0 && x2 < b1 && x2 < b2)) {
            amount = (x1 < b1 && x1 < b2) ? uint256(x1) * d : uint256(x2) * d;
        }
    }

    /// @dev 求二次方程的解：ax^2 + bx + c = 0，只返回正解
    function calcSolutionForQuadratic(
        int256 a,
        int256 b,
        int256 c
    ) internal pure returns (int256 x1, int256 x2) {
        int256 m = b**2 - 4 * a * c;
        // m < 0 导致负数
        require(m > 0, "Complex number");

        int256 sqrtM = int256(sqrt(uint256(m)));
        x1 = (-b + sqrtM) / (2 * a);
        x2 = (-b - sqrtM) / (2 * a);
    }

    /// @dev 牛顿法计算 n 的平方根
    function sqrt(uint256 n) internal pure returns (uint256 res) {
        assert(n > 1);

        //   比例因子是将所有内容转换为整数计算的粗略方法。
        // 实际上做 (n * 10 ^ 4) ^ (1/2)
        uint256 _n = n * 10**6;
        uint256 c = _n;
        res = _n;

        uint256 xi;
        while (true) {
            xi = (res + c / res) / 2;
            // 不需要太精确以节省气体
            if (res - xi < 1000) {
                break;
            }
            res = xi;
        }
        res = res / 10**3;
    }

    // 从 UniswapV2Library 复制
    // 给定一个资产的输出量和对储备金，返回另一个资产所需的输入量
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // 从 UniswapV2Library 复制
    // 给定一个资产的输出量和对储备金，返回另一个资产所需的输入量
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }
}
