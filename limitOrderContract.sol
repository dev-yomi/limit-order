// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

contract LimitOrderContract is ReentrancyGuard {

/*
 * LimitOrderContract: A smart contract for placing, executing, and canceling limit orders on Uniswap V3.
 *
 * The contract allows users to place limit orders by specifying input/output tokens, pool fee tier,
 * input amount, desired price, resolver fee (in basis points)
 *
 * Users can cancel their own limit orders and retrieve their input tokens, while anyone can execute a limit order if the
 * current price is equal to or better than the desired price
 * The contract also allows the owner to withdraw collected fees earned in tokens.
 * -devYomi
 */

    //Struct for orders placed
    struct LimitOrder {
        address user;
        address tokenIn;
        address tokenOut;
        address poolAddress;
        uint256 amountIn;
        uint256 price;
        uint256 resolverFee;
        bool isActive;
    }

    //Mapping to store structs by ID
    mapping(uint256 => LimitOrder) public limitOrders;
    mapping(address => uint256) public feesCollected;
    uint256 public nextOrderId;

    address public uniswapV3Factory;
    address public uniswapV3SwapRouter;
    uint256 public contractFee = 10;
    address public owner;

    //Events for Creation/Cancellation/Execution of orders
    event LimitOrderCreated(uint256 indexed offerId, address user, address tokenIn, address tokenOut, uint256 amountIn, uint256 price, uint256 fee);
    event LimitOrderCancelled(uint256 indexed offerId);
    event LimitOrderExecuted(uint256 indexed offerId, address resolver, uint256 feeEarned);

    constructor(address _uniswapV3Factory, address _uniswapV3SwapRouter) {
        uniswapV3Factory = _uniswapV3Factory;
        uniswapV3SwapRouter = _uniswapV3SwapRouter;
        owner = msg.sender;
    }

    // placeLimitOrder: Allows users to place a limit order by specifying;
    // token addresses, pool fee tier, input amount, desired price, resolver fee (in basis points)
function placeLimitOrder(
    address tokenIn,
    address poolAddress,
    uint256 amountIn,
    uint256 price,
    uint256 resolverFee
) external nonReentrant {
    // Get the UniswapV3 pool and retrieve token0 and token1
    IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
    address token0 = pool.token0();
    address token1 = pool.token1();

    require(tokenIn == token0 || tokenIn == token1, "Invalid input token for the pool");

    address tokenOut = tokenIn == token0 ? token1 : token0;
        //Transfer tokens from user to contract and approve Uniswap router for spending
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(uniswapV3SwapRouter, amountIn);
        uint256 dec = IERC20WithDecimals(tokenOut).decimals();
        uint256 desiredPrice = calculateSimplifiedPrice(price, 10**(dec));


        //Store the limit order in the mapping
        limitOrders[nextOrderId] = LimitOrder(
            msg.sender,
            tokenIn,
            tokenOut,
            poolAddress,
            amountIn,
            desiredPrice,
            resolverFee,
            true
        );
        emit LimitOrderCreated(nextOrderId, msg.sender, tokenIn, tokenOut, amountIn, price, resolverFee);
        nextOrderId++;
    }

     // executeLimitOrder: Allows anyone to execute a limit order if the current price is equal to or better than the desired price
     // resolver earns the order's defined resolverFee in the final token
    function executeLimitOrder(uint256 orderId) external nonReentrant {
        LimitOrder storage order = limitOrders[orderId];
        require(order.isActive, "Order not active");

        //Get the UniswapV3 pool and current price for the token pair
        IUniswapV3Pool pool = IUniswapV3Pool(order.poolAddress);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        //Calculate the current price as a ratio of the token amounts (scaled by 2^96)
        uint256 currentPrice = (uint256(sqrtPriceX96)**2) / 2**96;

        //Check if the current price is within defined buffer of the order price
        if (currentPrice <= order.price) {
            uint256 amountOut = swapTokenOnUniswapV3(
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.poolAddress
            );
            
            //Calculate the resolverFee
            uint256 fee = getFee(amountOut, order.resolverFee);
            //Mark as inactive
            order.isActive = false;

            //Add calculated contract fee to the feesCollected mapping
            uint256 contractCut = getFee(fee, contractFee);

            
            //Transfer the swapped tokens to the user and earned resolverFee to the resolver
            IERC20(order.tokenOut).transfer(order.user, amountOut - fee);
            IERC20(order.tokenOut).transfer(msg.sender, fee - contractCut);
            feesCollected[order.tokenOut] += contractCut;
            emit LimitOrderExecuted(orderId, msg.sender, fee - contractCut);
        }
    }

    // cancelLimitOrder: Allows the user who created a limit order to cancel it and retrieve their input tokens
    function cancelLimitOrder(uint256 orderId) public nonReentrant {
        LimitOrder storage order = limitOrders[orderId];
        require(msg.sender == order.user, "Not your order!");
        require(order.isActive, "Order not active!");

        order.isActive = false;
        IERC20(order.tokenIn).transfer(order.user, order.amountIn);
        emit LimitOrderCancelled(orderId);
    }

    //Swap tokens on Uniswap V3 using the exact input amount and specified token pair, internal.
    function swapTokenOnUniswapV3(address tokenIn, address tokenOut, uint256 amountIn, address poolAddress) internal returns (uint256 amountOut) {
        address recipient = address(this);

        //Set a reasonable deadline for the swap (e.g., 5 minutes from now)
        uint256 deadline = block.timestamp + 300;
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        uint24 feeTier = pool.fee();

        uint160 sqrtPriceLimitX96 = 0;

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: feeTier,
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });

        amountOut = ISwapRouter(uniswapV3SwapRouter).exactInputSingle(params);
    }

    function getOrderDetails(uint256 id) public view returns(LimitOrder memory) {
        return limitOrders[id];
    }

    //Helper function to calculate the price correctly, allowing users to simply determine the price in terms of X tokenOut = 1 tokenIn
    function calculateSimplifiedPrice(uint256 desiredPrice, uint256 scalingFactor) public pure returns (uint256) {
        return (desiredPrice * (2**96)) / scalingFactor;
    }

    //Contract fee calculation
    function getFee(uint256 _amount, uint256 feeBasisPoints) internal pure returns (uint256) {
        return _amount * feeBasisPoints / 10000;
    }

    //onlyOwner function to remove fees earned in any token
    function pullEarnedFees(address _token) public onlyOwner {
        IERC20(_token).transfer(msg.sender, feesCollected[_token]);
        feesCollected[_token] = 0;
    }

    //basic onlyOwner modifier
    modifier onlyOwner(){
        require(msg.sender == owner, "Not the right permissions");
        _;
    }

    //TODO: renounceOwnership function, changeContractFee function, updateRouterAddress and updateFactoryAddress functions probably a good idea too
    //TODO: getOrderInfo function
}
