//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "hardhat/console.sol";

import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IWETH.sol";
import "./libraries/Decimal.sol";
import "./libraries/SafeMath.sol";

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

contract FlashBot is Ownable {
    using Decimal for Decimal.D256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable wallet =
        0x626B0bB69bC86aa0E8b5a1c167857a66514E36E1;

    // 访问控制
    // 只有 `permissionedPairAddress` 可以调用 `uniswapV2Call` 函数
    address permissionedPairAddress = address(1);

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

    //提现
    function withdraw() external {
        //主币
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(wallet).transfer(balance);
            emit Withdrawn(wallet, balance);
        }
        //基础代币
        for (uint256 i = 0; i < baseTokens.length(); i++) {
            address token = baseTokens.at(i);
            balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                // 不要在这里使用安全转移来防止任何糟糕的令牌还原
                IERC20(token).transfer(wallet, balance);
            }
        }
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

    //判断基础代币是否包含
    function baseTokensContains(address token) public view returns (bool) {
        return baseTokens.contains(token);
    }

    // 是否基础代币更小 基础代币小，就是基础代币是token0;
    function isbaseTokenSmaller(address pool0, address pool1)
        internal
        view
        returns (
            bool baseSmaller,
            address baseToken,
            address quoteToken
        )
    {
        require(pool0 != pool1, "Same pair address");
        (address pool0Token0, address pool0Token1) = (
            IUniswapV2Pair(pool0).token0(),
            IUniswapV2Pair(pool0).token1()
        );
        (address pool1Token0, address pool1Token1) = (
            IUniswapV2Pair(pool1).token0(),
            IUniswapV2Pair(pool1).token1()
        );
        // 判断是否token小的在前边，否则不是标准的AMM池子
        require(
            pool0Token0 < pool0Token1 && pool1Token0 < pool1Token1,
            "Non standard uniswap AMM pair"
        );
        // 判断是否币对一样的池子
        require(
            pool0Token0 == pool1Token0 && pool0Token1 == pool1Token1,
            "Require same token pair"
        );
        // 判断是否有基础代币
        require(
            baseTokensContains(pool0Token0) || baseTokensContains(pool0Token1),
            "No base token in pair"
        );

        (baseSmaller, baseToken, quoteToken) = baseTokensContains(pool0Token0)
            ? (true, pool0Token0, pool0Token1)
            : (false, pool0Token1, pool0Token0);
    }

    /// @dev 比较两个池之间以报价代币计价的价格
    /// 我们通过使用闪兑从低价池中借入基础代币，然后将其出售给高价池
    function getOrderedReserves(
        address pool0,
        address pool1,
        bool baseTokenSmaller
    )
        internal
        view
        returns (
            address lowerPool,
            address higherPool,
            OrderedReserves memory orderedReserves
        )
    {
        // 获取池子内余额
        (uint256 pool0Reserve0, uint256 pool0Reserve1, ) = IUniswapV2Pair(pool0)
            .getReserves();
        (uint256 pool1Reserve0, uint256 pool1Reserve1, ) = IUniswapV2Pair(pool1)
            .getReserves();

        // 计算报价资产代币计价的价格
        (
            Decimal.D256 memory price0,
            Decimal.D256 memory price1
        ) = baseTokenSmaller
                ? (
                    Decimal.from(pool0Reserve0).div(pool0Reserve1),
                    Decimal.from(pool1Reserve0).div(pool1Reserve1)
                )
                : (
                    Decimal.from(pool0Reserve1).div(pool0Reserve0),
                    Decimal.from(pool1Reserve1).div(pool1Reserve0)
                );
        // 使用以下规则获取 a1, b1, a2, b2：
        // 1. (a1, b1) 基础代币存量 a1代表价格较低的矿池，a2代表价格较高的矿池
        // 2. (a2, b2) 套利代币存量 a2代表价格较低的矿池，b2代表价格较高的矿池
        //判断哪个池子的便宜
        if (price0.lessThan(price1)) {
            (lowerPool, higherPool) = (pool0, pool1); //价格低的(债务池) 价格高的(套利池)
            (
                orderedReserves.a1,
                orderedReserves.b1,
                orderedReserves.a2,
                orderedReserves.b2
            ) = baseTokenSmaller
                ? (pool0Reserve0, pool0Reserve1, pool1Reserve0, pool1Reserve1)
                : (pool0Reserve1, pool0Reserve0, pool1Reserve1, pool1Reserve0);
        } else {
            (lowerPool, higherPool) = (pool1, pool0);
            (
                orderedReserves.a1,
                orderedReserves.b1,
                orderedReserves.a2,
                orderedReserves.b2
            ) = baseTokenSmaller
                ? (pool1Reserve0, pool1Reserve1, pool0Reserve0, pool0Reserve1)
                : (pool1Reserve1, pool1Reserve0, pool0Reserve1, pool0Reserve0);
        }
    }

    /// @notice 在两个类似 Uniswap 的 AMM 池之间进行套利
    /// @dev 两个池必须包含相同的令牌对
    function flashArbitrageforYulin(address pool0, address pool1) external {
        // 套利信息
        ArbitrageInfo memory info;
        (
            info.baseTokenSmaller,
            info.baseToken,
            info.quoteToken
        ) = isbaseTokenSmaller(pool0, pool1);
        console.log("ss",info.baseTokenSmaller);
        OrderedReserves memory orderedReserves;
        // 确认借贷池子、套利池子、池子内代币信息
        (info.lowerPool, info.higherPool, orderedReserves) = getOrderedReserves(
            pool0,
            pool1,
            info.baseTokenSmaller
        );

        // 必须在每个事务中更新回调源身份验证
        // 只能借贷池子调用回调
        permissionedPairAddress = info.lowerPool;

        uint256 balanceBefore = IERC20(info.baseToken).balanceOf(address(this));

        // 避免堆栈太深错误
        {
            console.log("v1lowerPoolBaseReserve", orderedReserves.a1);
            console.log("v1higherPoolBaseReserve", orderedReserves.a2);
            console.log("v1lowerPoolQuoteReserve", orderedReserves.b1);
            console.log("v1higherPoolQuoteReserve", orderedReserves.b2);
            // 获取借款金额
            uint256 borrowAmount = calcBorrowAmount(orderedReserves);
            console.log("borrowAmount", borrowAmount);
            (uint256 amount0Out, uint256 amount1Out) = info.baseTokenSmaller
                ? (uint256(0), borrowAmount)
                : (borrowAmount, uint256(0));
            // 在较低价格池中借入报价代币，计算我们需要支付多少债务，以基础代币为基础
            uint256 debtAmount = getAmountIn(
                borrowAmount,
                orderedReserves.a1,
                orderedReserves.b1
            );
            // 在更高的价格池上出售借来的报价代币，计算我们可以获得多少基础代币
            uint256 baseTokenOutAmount = getAmountOut(
                borrowAmount,
                orderedReserves.b2,
                orderedReserves.a2
            );
            require(
                baseTokenOutAmount > debtAmount,
                "Arbitrage fail, no profit"
            );

            // 只能这样初始化，避免stack too deep错误
            CallbackData memory callbackData;
            callbackData.debtPool = info.lowerPool;
            callbackData.targetPool = info.higherPool;
            callbackData.debtTokenSmaller = info.baseTokenSmaller;
            callbackData.borrowedToken = info.quoteToken; //套利代币 借来的代币
            callbackData.debtToken = info.baseToken; //债务代币 基础代币 需要还的代币
            callbackData.debtAmount = debtAmount; //债务金额
            callbackData.debtTokenOutAmount = baseTokenOutAmount; //从套利池子卖出换来的基础代币数量
            bytes memory data = abi.encode(callbackData);
            IUniswapV2Pair(info.lowerPool).swap(
                amount0Out,
                amount1Out,
                address(this),
                data
            );
        }

        uint256 balanceAfter = IERC20(info.baseToken).balanceOf(address(this));
        require(
            balanceAfter > balanceBefore &&
                balanceAfter > baseTokensMinProfit[info.baseToken],
            "Losing money"
        );

        // 把钱打到自己钱包
        IERC20(info.baseToken).safeTransfer(wallet, balanceAfter);
        permissionedPairAddress = address(1);
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes memory data
    ) public {
        // access control
        require(
            msg.sender == permissionedPairAddress,
            "Non permissioned address call"
        );
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
    function getProfit(address pool0, address pool1)
        external
        view
        returns (uint256 profit, address baseToken)
    {
        (bool baseTokenSmaller, , ) = isbaseTokenSmaller(pool0, pool1);
        baseToken = baseTokenSmaller
            ? IUniswapV2Pair(pool0).token0()
            : IUniswapV2Pair(pool0).token1();

        (, , OrderedReserves memory orderedReserves) = getOrderedReserves(
            pool0,
            pool1,
            baseTokenSmaller
        );

        uint256 borrowAmount = calcBorrowAmount(orderedReserves);
        // 在低价池中借用套利代币
        uint256 debtAmount = getAmountIn(
            borrowAmount,
            orderedReserves.a1,
            orderedReserves.b1
        );
        // 在更高的价格池上出售借来的报价代币
        uint256 baseTokenOutAmount = getAmountOut(
            borrowAmount,
            orderedReserves.b2,
            orderedReserves.a2
        );
        if (baseTokenOutAmount < debtAmount) {
            profit = 0;
        } else {
            profit = baseTokenOutAmount - debtAmount;
        }
    }

    /// @dev 计算套利时为了获得最大利润而借入的最大基础资产金额
    function calcBorrowAmount(OrderedReserves memory reserves)
        internal
        view
        returns (uint256 amount)
    {
        // 我们不能直接使用 a1,b1,a2,b2，因为它会导致中间结果上溢/下溢
        // 所以我们:
        //    1. 将所有数字除以 d 以防止上溢/下溢
        //    2. 使用上述数字计算结果
        //    3.将d与结果相乘得到最终结果
        // 注意：此解决方法仅适用于 18 位小数的 ERC20 代币，我相信大多数代币都这样做

        uint256 min1 = reserves.a1 < reserves.b1 ? reserves.a1 : reserves.b1;
        uint256 min2 = reserves.a2 < reserves.b2 ? reserves.a2 : reserves.b2;
        uint256 min = min1 < min2 ? min1 : min2;

        console.log("min",min);
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
        } else {
            d = 1e7;
        }
        
        console.log("d",d);
        (int256 a1, int256 a2, int256 b1, int256 b2) = (
            int256(reserves.a1 / d),
            int256(reserves.a2 / d),
            int256(reserves.b1 / d),
            int256(reserves.b2 / d)
        );
        
        
        console.log("a1",uint256(a1));
        console.log("a2",uint256(a2));
        console.log("b1",uint256(b1));
        console.log("b2",uint256(b2));
        int256 a = a1 * b1 - a2 * b2;
        int256 b = 2 * b1 * b2 * (a1 + a2);
        int256 c = b1 * b2 * (a1 * b2 - a2 * b1);
        
        console.log("a1",uint256(a));
        console.log("a2",uint256(b));
        console.log("b1",uint256(c));
        (int256 x1, int256 x2) = calcSolutionForQuadratic(a, b, c);
        
        console.log("a1",uint256(x1));
        console.log("a2",uint256(x2));
        // 0 < x < b1 and 0 < x < b2
        if ((x1 > 0 && x1 < b1 && x1 < b2) || (x2 > 0 && x2 < b1 && x2 < b2)) {
            amount = (x1 < b1 && x1 < b2) ? uint256(x1) * d : uint256(x2) * d;
        } else {
            amount = (reserves.b1 < reserves.b2) ? reserves.b1 : reserves.b2;
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
