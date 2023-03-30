pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LimitOrderContract {

    //Struct for orders placed
    struct LimitOrder {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 price;
        bool isActive;
    }

    //Mapping to store structs by ID
    mapping(uint256 => LimitOrder) public limitOrders;
    uint256 public nextOrderId;

    address public uniswapV3Factory;
    address public uniswapV3SwapRouter;
    uint24 public poolFee;

    constructor(address _uniswapV3Factory, address _uniswapV3SwapRouter, uint24 _poolFee) {
        uniswapV3Factory = _uniswapV3Factory;
        uniswapV3SwapRouter = _uniswapV3SwapRouter;
        poolFee = _poolFee;
    }

    //Place a limit order by specifying token addresses, input amount, and desired price
    function placeLimitOrder(address tokenIn, address tokenOut, uint256 amountIn, uint256 price) external {
        require(amountIn > 0, "Amount must be greater than 0");
        require(price > 0, "Price must be greater than 0");

        //Transfer tokens from user to contract and approve Uniswap router for spending
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(uniswapV3SwapRouter, amountIn);

        //Store the limit order in the mapping
        limitOrders[nextOrderId] = LimitOrder(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            price,
            true
        );
        nextOrderId++;
    }

    //Execute a limit order if the current price is equal to or better than the desired price (callable by anyone)
    function executeLimitOrder(uint256 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        require(order.isActive, "Order not active");

        //Get the UniswapV3 pool and current price for the token pair
        IUniswapV3Pool pool = getPool(order.tokenIn, order.tokenOut);
        (, int24 currentTick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        uint256 currentPrice = uint256(int256(currentTick)) * uint256(int256(tickSpacing));


        //Execute the order if the current price meets the user's desired price
        if (order.price <= currentPrice) {
            uint256 amountOut = swapTokenOnUniswapV3(
                pool,
                order.tokenIn,
                order.tokenOut,
                order.amountIn
            );
            //Transfer the swapped tokens to the user and mark the order as inactive
            IERC20(order.tokenOut).transfer(order.user, amountOut);
            order.isActive = false;
        }
    }

    //Swap tokens on Uniswap V3 using the exact input amount and specified token pair
    function swapTokenOnUniswapV3(IUniswapV3Pool pool, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        address recipient = address(this);

        // Set a reasonable deadline for the swap (e.g., 5 minutes from now)
        uint256 deadline = block.timestamp + 300;

        uint160 sqrtPriceLimitX96 = 0;

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });

        amountOut = ISwapRouter(uniswapV3SwapRouter).exactInputSingle(params);
    }

function getPool(address tokenA, address tokenB) internal view returns (IUniswapV3Pool){
        IUniswapV3Factory factory = IUniswapV3Factory(uniswapV3Factory);
        address poolAddress = factory.getPool(tokenA, tokenB, poolFee);
        require(poolAddress != address(0), "Pool not found");
        return IUniswapV3Pool(poolAddress);
    }
}
