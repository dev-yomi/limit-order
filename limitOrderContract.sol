// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";

contract LimitOrderContract is ReentrancyGuard {

/*
 * LimitOrderContract: A smart contract for placing, executing, and canceling limit orders on Uniswap V3.
 *
 * The contract allows users to place limit orders by specifying input/output tokens, pool fee tier,
 * input amount, desired price, resolver fee (in basis points), and a slippage buffer. 
 *
 * Users can cancel their own limit orders and retrieve their input tokens, while anyone can execute a limit order if the
 * current price is equal to or better than the desired price (within the slippage buffer). 
 * The contract also allows the owner to withdraw collected fees earned in tokens.
 * -devYomi
 */

    //Struct for orders placed
    struct LimitOrder {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 poolFee;
        uint256 amountIn;
        uint256 price;
        uint256 resolverFee;
        uint256 slippageBuffer;
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
    // token addresses, pool fee tier, input amount, desired price, resolver fee (in basis points), and slippage buffer (in basis points)
    function placeLimitOrder(
        address tokenIn, 
        address tokenOut, 
        uint256 poolFee, 
        uint256 amountIn, 
        uint256 price, 
        uint256 resolverFee, 
        uint256 slippageBuffer) external nonReentrant {

        require(tokenIn != tokenOut, "Input and output tokens must be different");
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
            poolFee,
            amountIn,
            price,
            resolverFee,
            slippageBuffer,
            true
        );
        emit LimitOrderCreated(nextOrderId, msg.sender, tokenIn, tokenOut, amountIn, price, resolverFee);
        nextOrderId++;
    }

     // executeLimitOrder: Allows anyone to execute a limit order if the current price is equal to or better than the desired price (within the slippage buffer)
     // resolver earns the order's defined resolverFee in the final token
    function executeLimitOrder(uint256 orderId) external nonReentrant {
        LimitOrder storage order = limitOrders[orderId];
        require(order.isActive, "Order not active");

        //Get the UniswapV3 pool and current price for the token pair
        IUniswapV3Pool pool = getPool(order.tokenIn, order.tokenOut, uint24(order.poolFee));
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        //Calculate the current price as a ratio of the token amounts (scaled by 2^96)
        uint256 currentPrice = (uint256(sqrtPriceX96)**2) / 2**96;

        //Calculate slip % of the order price
        uint256 priceBuffer = (order.price * order.slippageBuffer) / 10000;

        //Check if the current price is within defined buffer of the order price
        if (currentPrice <= order.price + priceBuffer) {
            uint256 amountOut = swapTokenOnUniswapV3(
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.poolFee
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
        IERC20 token = IERC20(order.tokenIn);
        token.transfer(order.user, order.amountIn);
        emit LimitOrderCancelled(orderId);
    }

    //Swap tokens on Uniswap V3 using the exact input amount and specified token pair, internal.
    function swapTokenOnUniswapV3(address tokenIn, address tokenOut, uint256 amountIn, uint256 fee) internal returns (uint256 amountOut) {
        address recipient = address(this);

        //Set a reasonable deadline for the swap (e.g., 5 minutes from now)
        uint256 deadline = block.timestamp + 300;

        uint160 sqrtPriceLimitX96 = 0;

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: uint24(fee),
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });

        amountOut = ISwapRouter(uniswapV3SwapRouter).exactInputSingle(params);
    }

    //Helper internal function to retrieve the pool data from uniV3
    function getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool){
        IUniswapV3Factory factory = IUniswapV3Factory(uniswapV3Factory);
        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        require(poolAddress != address(0), "Pool not found");
        return IUniswapV3Pool(poolAddress);
    }

    //Contract fee calculation
    function getFee(uint256 _amount, uint256 feeBasisPoints) internal pure returns (uint256) {
        return _amount * feeBasisPoints / 10000;
    }

    //onlyOwner function to remove fees earned in any token
    function pullEarnedFees(address _token) public onlyOwner {
        require(feeFlag, "set fee flag");
        IERC20 token = IERC20(_token);
        token.transfer(msg.sender, token.balanceOf(address(this)));
        feesCollected[_token] = 0;
    }
    
    bool public feeFlag  = false;
    
    function setFeeFlag() public onlyOwner {
        if(!feeFlag){
            feeFlag = false;
        }
    }

    //basic onlyOwner modifier
    modifier onlyOwner(){
        require(msg.sender == owner, "Not the right permissions");
        _;
    }

    //TODO: renounceOwnership function, changeContractFee function, updateRouterAddress and updateFactoryAddress functions probably a good idea too
}
