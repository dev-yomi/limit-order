# Limit Order Contract for Uniswap V3

This repository contains a smart contract that enables users to place, execute, and cancel limit orders on Uniswap V3. The contract is written in Solidity and is based on the `^0.8.0` version.

## Features

- Users can place limit orders by specifying input/output tokens, pool fee tier, input amount, desired price, resolver fee (in basis points), and a slippage buffer.
- Users can cancel their own limit orders and retrieve their input tokens.
- Anyone can execute a limit order if the current price is equal to or better than the desired price (within the slippage buffer).
- Contract owners can withdraw collected fees earned in tokens.

## How it works

### Placing a limit order

Users can place a limit order by calling the `placeLimitOrder` function with the following parameters:

- `address tokenIn`: Address of the input token
- `address tokenOut`: Address of the output token
- `uint256 poolFee`: Fee tier of the Uniswap V3 pool
- `uint256 amountIn`: Amount of input tokens to be swapped
- `uint256 price`: Desired price for the swap
- `uint256 resolverFee`: Resolver fee in basis points
- `uint256 slippageBuffer`: Slippage buffer in basis points

### Canceling a limit order

Users can cancel their limit orders by calling the `cancelLimitOrder` function with the following parameter:

- `uint256 orderId`: ID of the limit order to be canceled

### Executing a limit order

Anyone can execute a limit order by calling the `executeLimitOrder` function with the following parameter:

- `uint256 orderId`: ID of the limit order to be executed

The function checks whether the current price is equal to or better than the desired price (within the slippage buffer) and, if so, executes the limit order.

## Contract

The contract relies on several external libraries and contracts:

- Uniswap V3 Core: https://github.com/Uniswap/uniswap-v3-core
- Uniswap V3 Periphery: https://github.com/Uniswap/uniswap-v3-periphery
- OpenZeppelin Contracts: https://github.com/OpenZeppelin/openzeppelin-contracts

## Security

The contract uses the ReentrancyGuard from the OpenZeppelin Contracts library to prevent reentrancy attacks.

