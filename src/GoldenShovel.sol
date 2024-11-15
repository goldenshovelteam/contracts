// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";
import {SafeCast} from "v3-core/contracts/libraries/SafeCast.sol";
import {IWETH} from "v2-periphery/interfaces/IWETH.sol";
import {IERC20} from "v2-periphery/interfaces/IERC20.sol";

contract GoldenShovel {
    using SafeCast for uint256;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    address immutable WETH_ADDR;

    constructor(address _weth) {
        WETH_ADDR = _weth;
    }

    receive() external payable {}

    fallback() external payable {}

    /// sellV2
    /// @param tokenAddr token address
    /// @param pairAddr uniswap v2 pair address
    /// @param amount sell amount
    /// @param feeAddress fee address
    /// @param feeBps fee rate: feeBps / 1000
    function sellV2(
        address tokenAddr,
        address pairAddr,
        uint256 amount,
        uint256 minOut,
        address feeAddress,
        uint feeBps
    ) external {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddr);
        address token0 = pair.token0();
        address token1 = pair.token1();

        bool notContainWeth = token0 != WETH_ADDR && token1 != WETH_ADDR;
        bool notContainToken = token0 != tokenAddr && token1 != tokenAddr;

        if (notContainWeth || notContainToken) {
            revert("invalid token or uniswap pair");
        }

        require(
            IERC20(tokenAddr).balanceOf(msg.sender) >= amount,
            "insufficient token balance"
        );

        address[] memory path = new address[](2);
        if (token0 == tokenAddr) {
            path[0] = token0;
            path[1] = token1;
        } else {
            path[0] = token1;
            path[1] = token0;
        }

        IERC20(tokenAddr).transferFrom(msg.sender, pairAddr, amount);
        uint amountInput;
        uint amountOutput;
        (uint reserve0, uint reserve1, ) = pair.getReserves();
        (uint reserveInput, uint reserveOutput) = tokenAddr == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        amountInput = IERC20(tokenAddr).balanceOf(pairAddr) - reserveInput;
        amountOutput = getAmountOutV2(amountInput, reserveInput, reserveOutput);

        (uint amount0Out, uint amount1Out) = tokenAddr == token0
            ? (uint(0), amountOutput)
            : (amountOutput, uint(0));
        pair.swap(amount0Out, amount1Out, address(this), new bytes(0));
        uint amountOut = IERC20(WETH_ADDR).balanceOf(address(this));
        require(amountOut >= minOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH_ADDR).withdraw(amountOut);

        uint fee = (amountOut * feeBps) / 1000;

        (bool sendFeeSuccessed, ) = feeAddress.call{value: fee}("");
        require(sendFeeSuccessed, "failed transfer fee");

        (bool successed, ) = msg.sender.call{value: amountOut - fee}("");
        require(successed, "failed transfer eth to seller");
    }

    struct SwapCallbackData {
        address token;
        address payer;
    }

    /// uniswap v3 callback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));

        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0
            ? (data.token < WETH_ADDR, uint256(amount0Delta))
            : (WETH_ADDR < data.token, uint256(amount1Delta));

        if (isExactInput) {
            pay(data.token, data.payer, msg.sender, amountToPay);
        } else {
            revert("only support exact input single sell");
        }
    }

    /// sellV3
    /// @param tokenAddr token address
    /// @param poolAddr uniswap v3 pool address
    /// @param amount sell amount
    /// @param feeAddress fee address
    /// @param feeBps fee rate: feeBps / 1000
    function sellV3(
        address tokenAddr,
        address poolAddr,
        uint256 amount,
        uint256 minOut,
        address feeAddress,
        uint feeBps
    ) external {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();
        bool notContainWeth = token0 != WETH_ADDR && token1 != WETH_ADDR;
        bool notContainToken = token0 != tokenAddr && token1 != tokenAddr;

        if (notContainWeth || notContainToken) {
            revert("invalid token or uniswap pair");
        }

        require(
            IERC20(tokenAddr).balanceOf(msg.sender) >= amount,
            "insufficient token balance"
        );

        bool zeroForOne = tokenAddr < WETH_ADDR;

        SwapCallbackData memory callbackData = SwapCallbackData({
            token: tokenAddr,
            payer: msg.sender
        });
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            amount.toInt256(),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(callbackData)
        );

        uint256 amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= minOut, "Too little received");
        IWETH(WETH_ADDR).withdraw(amountOut);

        uint fee = (amountOut * feeBps) / 1000;

        (bool sendFeeSuccessed, ) = feeAddress.call{value: fee}("");
        require(sendFeeSuccessed, "failed transfer fee");

        (bool successed, ) = msg.sender.call{value: amountOut - fee}("");
        require(successed, "failed transfer eth to seller");
    }

    /// getAmountOutV2
    /// calculate amount out for uniswap v2
    function getAmountOutV2(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH_ADDR && address(this).balance >= value) {
            // pay with WETH9
            IWETH(WETH_ADDR).deposit{value: value}(); // wrap only what is needed to pay
            IWETH(WETH_ADDR).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }
}
