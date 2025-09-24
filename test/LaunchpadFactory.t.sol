// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/LaunchpadFactory.sol";
import "../helpers/ArtifactStorage.sol";

contract LaunchpadFactoryTest is Test, ArtifactStorage {
    address public weth;
    address public uniswapFactory;
    address public uniswapRouter;

    LaunchpadFactory public launchpadFactory;

    address public alice = address(0x1);
    address public bob = address(0x2);

    uint256 constant INITIAL_ETH_BALANCE = 1000 ether;

    receive() external payable {}

    function setUp() public {
        weth = _deployBytecode(ArtifactStorage.wethBytecode);
        require(weth != address(0), "WETH deployment failed");

        address feeToSetter = vm.addr(1);
        bytes memory uniswapFactoryBytecode = abi.encodePacked(
            ArtifactStorage.uniswapV2Factory,
            abi.encode(feeToSetter)
        );
        uniswapFactory = _deployBytecode(uniswapFactoryBytecode);
        require(
            uniswapFactory != address(0),
            "UniswapV2Factory deployment failed"
        );

        bytes memory routerBytecodeWithArgs = abi.encodePacked(
            ArtifactStorage.uniswapV2Router,
            abi.encode(uniswapFactory, weth)
        );
        uniswapRouter = _deployBytecode(routerBytecodeWithArgs);
        require(
            uniswapRouter != address(0),
            "Uniswap Router deployment failed"
        );

        launchpadFactory = new LaunchpadFactory(uniswapRouter);
        require(
            address(launchpadFactory) != address(0),
            "LaunchpadFactory deployment failed"
        );

        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);
    }

    function test_CreateToken() public {
        string memory tokenName = "Test Token";
        string memory tokenSymbol = "TTKN";

        address tokenAddress = launchpadFactory.createLaunchpad(
            tokenName,
            tokenSymbol
        );

        assertTrue(tokenAddress != address(0), "Token creation failed");

        (
            uint256 tokensLiquidity,
            uint256 tokenSupply,
            uint256 ethSupply,
            bool isMigrated
        ) = launchpadFactory.tokenData(tokenAddress);

        assertEq(
            tokensLiquidity,
            (launchpadFactory.TOTAL_SUPPLY() * 2000) / 10_000,
            "Liquidity tokens mismatch"
        );
        assertEq(
            tokenSupply,
            launchpadFactory.TOTAL_SUPPLY() - tokensLiquidity,
            "Token supply mismatch"
        );
        assertEq(ethSupply, 0, "Initial ETH supply should be 0");
        assertFalse(isMigrated, "Should not be migrated initially");
    }

    function test_BuyTokens() public {
        address tokenAddress = launchpadFactory.createLaunchpad(
            "Test Token",
            "TTKN"
        );

        uint256 ethAmount = 0.5 ether;
        uint256 minTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            ethAmount
        );

        vm.startPrank(alice);
        uint256 tokensBought = launchpadFactory.buyTokens{value: ethAmount}(
            tokenAddress,
            minTokens
        );
        vm.stopPrank();

        assertTrue(tokensBought > 0, "Failed to buy tokens");
        assertEq(tokensBought, minTokens, "Token amount mismatch");

        (, uint256 tokenSupply, uint256 ethSupply, ) = launchpadFactory
            .tokenData(tokenAddress);
        assertEq(ethSupply, ethAmount, "ETH supply not updated");

        IERC20 token = IERC20(tokenAddress);
        assertEq(
            token.balanceOf(alice),
            tokensBought,
            "User token balance mismatch"
        );
    }

    function test_SellTokens() public {
        address tokenAddress = launchpadFactory.createLaunchpad(
            "Test Token",
            "TTKN"
        );

        vm.startPrank(alice);
        uint256 tokensBought = launchpadFactory.buyTokens{value: 1 ether}(
            tokenAddress,
            0
        );

        IERC20 token = IERC20(tokenAddress);
        token.approve(address(launchpadFactory), tokensBought);

        uint256 tokensToSell = tokensBought / 2;
        uint256 minEth = launchpadFactory.getEthersOutAtCurrentSupply(
            tokenAddress,
            tokensToSell
        );

        uint256 initialBalance = address(alice).balance;
        uint256 ethReceived = launchpadFactory.sellTokens(
            tokenAddress,
            tokensToSell,
            minEth
        );
        vm.stopPrank();

        assertTrue(ethReceived > 0, "Failed to sell tokens");
        assertEq(
            address(alice).balance,
            initialBalance + ethReceived,
            "ETH not received"
        );
        assertEq(
            token.balanceOf(alice),
            tokensBought - tokensToSell,
            "Token balance mismatch"
        );
    }

    function test_MultipleBuysIncreasePrices() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");
        uint256 buyAmount = 1 ether;

        vm.startPrank(alice);
        uint256 firstBuyTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            buyAmount
        );
        launchpadFactory.buyTokens{value: buyAmount}(tokenAddress, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 secondBuyTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            buyAmount
        );
        launchpadFactory.buyTokens{value: buyAmount}(tokenAddress, 0);
        vm.stopPrank();

        assertTrue(
            secondBuyTokens < firstBuyTokens,
            "Price should increase after buys"
        );
    }

    function test_CannotBuyAfterMigration() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 101 ether}(tokenAddress, 0);

        vm.expectRevert(
            abi.encodeWithSignature("LaunchpadFactoryInvalidState()")
        );
        launchpadFactory.buyTokens{value: 1 ether}(tokenAddress, 0);
        vm.stopPrank();
    }

    function test_CannotSellAfterMigration() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");

        vm.startPrank(alice);
        uint256 tokensBought = launchpadFactory.buyTokens{value: 10 ether}(
            tokenAddress,
            0
        );

        launchpadFactory.buyTokens{value: 11 ether}(tokenAddress, 0);

        IERC20 token = IERC20(tokenAddress);
        token.approve(address(launchpadFactory), tokensBought);

        vm.expectRevert(
            abi.encodeWithSignature("LaunchpadFactoryInvalidState()")
        );
        launchpadFactory.sellTokens(tokenAddress, tokensBought / 2, 0);
        vm.stopPrank();
    }

    function test_SlippageProtection() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");
        uint256 expectedTokens = launchpadFactory.getTokensOutAtCurrentSupply(
            tokenAddress,
            1 ether
        );

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "LaunchpadFactoryInsufficientOutputAmount()"
            )
        );
        launchpadFactory.buyTokens{value: 1 ether}(
            tokenAddress,
            expectedTokens + 1
        );
        vm.stopPrank();
    }

    function test_ExcessEthRefund() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");
        uint256 initialBalance = address(alice).balance;

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 102 ether}(tokenAddress, 0);
        vm.stopPrank();

        assertEq(
            address(alice).balance,
            initialBalance - 20 ether,
            "Excess ETH not refunded correctly"
        );
    }

    function test_ZeroAmountRevert() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("LaunchpadFactoryInsufficientInputAmount()")
        );
        launchpadFactory.buyTokens{value: 0}(tokenAddress, 0);
        vm.stopPrank();
    }

    function test_PauseUnpause() public {
        launchpadFactory.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        launchpadFactory.createLaunchpad("Test", "T");

        launchpadFactory.unpause();

        address token = launchpadFactory.createLaunchpad("Test", "T");
        assertTrue(
            token != address(0),
            "Token creation should work after unpause"
        );
    }

    function test_OnlyOwnerCanPause() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                alice
            )
        );
        launchpadFactory.pause();
        vm.stopPrank();
    }

    function test_GetSingleTokenPrice() public {
        address tokenAddress = launchpadFactory.createLaunchpad("Test", "T");

        uint256 initialPrice = launchpadFactory.getTokenPrice(tokenAddress);
        assertTrue(initialPrice >= 0, "Initial price should be >= 0");

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 1 ether}(tokenAddress, 0);
        vm.stopPrank();

        uint256 priceAfterBuy = launchpadFactory.getTokenPrice(tokenAddress);
        (, , uint256 ethSupply, ) = launchpadFactory.tokenData(tokenAddress);
        assertTrue(ethSupply == 1 ether, "Should have 1 ETH supply after buy");

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 100 ether}(tokenAddress, 0);
        vm.stopPrank();

        uint256 priceAfterMigration = launchpadFactory.getTokenPrice(
            tokenAddress
        );
        assertEq(priceAfterMigration, 0, "Migrated token should have 0 price");
    }

    function test_LiquidityMigration() public {
        address tokenAddress = launchpadFactory.createLaunchpad(
            "Test Token",
            "TTKN"
        );

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 19 ether}(tokenAddress, 0);

        (, , uint256 ethSupply, bool isMigrated) = launchpadFactory.tokenData(
            tokenAddress
        );
        assertFalse(isMigrated, "Should not be migrated yet");
        assertTrue(
            ethSupply < launchpadFactory.THRESHOLD(),
            "Should be below threshold"
        );

        launchpadFactory.buyTokens{value: 2 ether}(tokenAddress, 0);

        (, , , bool isMigratedAfter) = launchpadFactory.tokenData(tokenAddress);
        assertTrue(isMigratedAfter, "Should be migrated");
        vm.stopPrank();

        address pair = IUniswapV2Factory(uniswapFactory).getPair(
            tokenAddress,
            weth
        );
        assertTrue(pair != address(0), "Liquidity pair not created");

        uint256 pairBalance = IERC20(pair).balanceOf(address(0xdead));
        assertTrue(pairBalance > 0, "LP tokens not burned");
    }

    function test_MultipleTokensIndependence() public {
        address token1 = launchpadFactory.createLaunchpad("Token1", "T1");
        address token2 = launchpadFactory.createLaunchpad("Token2", "T2");

        vm.startPrank(alice);
        launchpadFactory.buyTokens{value: 1 ether}(token1, 0);
        vm.stopPrank();

        (, , uint256 ethSupply1, ) = launchpadFactory.tokenData(token1);
        (, , uint256 ethSupply2, ) = launchpadFactory.tokenData(token2);

        assertEq(ethSupply1, 1 ether, "Token1 should have ETH supply");
        assertEq(ethSupply2, 0, "Token2 should have no ETH supply");
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
