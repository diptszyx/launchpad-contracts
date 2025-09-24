// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/LaunchpadFactory.sol";
import "../helpers/ArtifactStorage.sol";

contract LaunchpadFactoryFuzzTest is Test, ArtifactStorage {
    LaunchpadFactory public launchpadFactory;
    address public uniswapRouter;
    address public tokenAddress;
    address public weth;
    address public uniswapFactory;

    receive() external payable {}

    function setUp() public {
        weth = _deployBytecode(ArtifactStorage.wethBytecode);
        address feeToSetter = vm.addr(1);
        bytes memory uniswapFactoryBytecode = abi.encodePacked(
            ArtifactStorage.uniswapV2Factory,
            abi.encode(feeToSetter)
        );
        uniswapFactory = _deployBytecode(uniswapFactoryBytecode);
        bytes memory routerBytecodeWithArgs = abi.encodePacked(
            ArtifactStorage.uniswapV2Router,
            abi.encode(uniswapFactory, weth)
        );
        uniswapRouter = _deployBytecode(routerBytecodeWithArgs);

        launchpadFactory = new LaunchpadFactory(uniswapRouter);
        tokenAddress = launchpadFactory.createLaunchpad("Test Token", "TTKN");
    }

    function testFuzz_BuyTokensInvariant(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 0.01 ether, 19 ether);

        (
            ,
            uint256 initialTokenSupply,
            uint256 initialEthSupply,

        ) = launchpadFactory.tokenData(tokenAddress);

        uint256 expectedTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            ethAmount
        );
        vm.assume(expectedTokens <= initialTokenSupply);

        uint256 actualTokens = launchpadFactory.buyTokens{value: ethAmount}(
            tokenAddress,
            0
        );

        assertEq(actualTokens, expectedTokens, "Token output mismatch");

        (, uint256 newTokenSupply, uint256 newEthSupply, ) = launchpadFactory
            .tokenData(tokenAddress);
        assertEq(
            newEthSupply,
            initialEthSupply + ethAmount,
            "ETH supply not updated correctly"
        );
        assertEq(
            newTokenSupply,
            initialTokenSupply - actualTokens,
            "Token supply not updated correctly"
        );
    }

    function testFuzz_SellTokensInvariant(uint256 sellAmount) public {
        uint256 boughtTokens = launchpadFactory.buyTokens{value: 1 ether}(
            tokenAddress,
            0
        );
        sellAmount = bound(sellAmount, boughtTokens / 100, boughtTokens);

        IERC20 token = IERC20(tokenAddress);
        token.approve(address(launchpadFactory), sellAmount);

        (
            ,
            uint256 initialTokenSupply,
            uint256 initialEthSupply,

        ) = launchpadFactory.tokenData(tokenAddress);
        uint256 expectedEth = launchpadFactory.getEthersOutAtCurrentSupply(
            tokenAddress,
            sellAmount
        );

        uint256 initialBalance = address(this).balance;
        uint256 actualEth = launchpadFactory.sellTokens(
            tokenAddress,
            sellAmount,
            0
        );

        assertEq(actualEth, expectedEth, "ETH output mismatch");
        assertEq(
            address(this).balance,
            initialBalance + actualEth,
            "ETH balance not updated"
        );

        (, uint256 newTokenSupply, uint256 newEthSupply, ) = launchpadFactory
            .tokenData(tokenAddress);
        assertEq(
            newEthSupply,
            initialEthSupply - actualEth,
            "ETH supply not updated correctly"
        );
        assertEq(
            newTokenSupply,
            initialTokenSupply + sellAmount,
            "Token supply not updated correctly"
        );
    }

    function testFuzz_MigrationThreshold(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 18 ether, 22 ether);

        launchpadFactory.buyTokens{value: ethAmount}(tokenAddress, 0);

        (, , , bool isMigrated) = launchpadFactory.tokenData(tokenAddress);

        if (ethAmount >= 20 ether) {
            assertTrue(isMigrated, "Should be migrated");

            address pair = IUniswapV2Factory(uniswapFactory).getPair(
                tokenAddress,
                weth
            );
            assertTrue(pair != address(0), "Liquidity pair should be created");

            uint256 pairBalance = IERC20(pair).balanceOf(address(0xdead));
            assertTrue(pairBalance > 0, "LP tokens should be burned");
        } else {
            assertFalse(isMigrated, "Should not be migrated yet");
        }
    }

    function testFuzz_PriceConsistency(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 0.01 ether, 10 ether);

        (, uint256 tokenSupply, , ) = launchpadFactory.tokenData(tokenAddress);
        uint256 expectedTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            ethAmount
        );

        vm.assume(expectedTokens <= tokenSupply);

        uint256 actualTokens = launchpadFactory.buyTokens{value: ethAmount}(
            tokenAddress,
            0
        );

        assertEq(
            expectedTokens,
            actualTokens,
            "Price calculation should match actual output"
        );
    }

    function testFuzz_SlippageProtection(
        uint256 ethAmount,
        uint256 minTokens
    ) public {
        ethAmount = bound(ethAmount, 0.01 ether, 10 ether);

        uint256 expectedTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            ethAmount
        );
        minTokens = bound(minTokens, expectedTokens + 1, expectedTokens * 2);

        vm.expectRevert(
            abi.encodeWithSignature(
                "LaunchpadFactoryInsufficientOutputAmount()"
            )
        );
        launchpadFactory.buyTokens{value: ethAmount}(tokenAddress, minTokens);
    }

    function _deployBytecode(
        bytes memory bytecode
    ) internal returns (address addr) {
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "Deployment failed");
    }
}
