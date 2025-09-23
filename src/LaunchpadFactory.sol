// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Token} from "./token/Token.sol";
import {BondingCurve} from "./libraries/BondingCurve.sol";
import {ILaunchpadFactory} from "./interfaces//launchpad/ILaunchpadFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "./interfaces/uniswap/IUniswapV2Factory.sol";

contract LaunchpadFactory is
    Ownable(msg.sender),
    Pausable,
    ReentrancyGuardTransient,
    ILaunchpadFactory
{
    using Address for address;
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant THRESHOLD = 100 ether;

    address public immutable uniswapV2Router;

    struct TokenData {
        uint256 tokensLiquidity;
        uint256 tokenSupply;
        uint256 ethSupply;
        bool isMigrated;
    }
    struct TokenPrice {
        address tokenAddress;
        uint256 currentPrice;
        uint256 ethSupply;
        uint256 tokenSupply;
        bool isMigrated;
    }

    mapping(address => TokenData) public tokenData;
    mapping(address => IERC20) public tokens;
    address[] public allTokens;

    error LaunchpadFactoryInvalidRouter();
    error LaunchpadFactoryTokenDeploymentFailed();
    error LaunchpadFactoryInvalidState();
    error LaunchpadFactoryInsufficientInputAmount();
    error LaunchpadFactoryInsufficientOutputAmount();
    error LaunchpadFactoryInsufficientLiquidity();
    error LaunchpadFactoryInvalidAddress();

    event LaunchpadCreation(address indexed token, address indexed creator);
    event TokenPurchase(
        address indexed token,
        address indexed recipient,
        uint256 ethAmountSent,
        uint256 tokenAmountReceived
    );
    event TokenSale(
        address indexed token,
        address indexed recipient,
        uint256 tokenAmountSent,
        uint256 ethAmountReceived
    );
    event LiquidityMigration(
        address indexed token,
        address indexed pair,
        uint256 ethAmount,
        uint256 tokenAmount
    );

    modifier whenNotMigrated(address tokenAddress) {
        if (tokenData[tokenAddress].isMigrated)
            revert LaunchpadFactoryInvalidState();
        _;
    }

    modifier validToken(address tokenAddress) {
        if (tokenAddress == address(0)) revert LaunchpadFactoryInvalidAddress();
        if (address(tokens[tokenAddress]) == address(0))
            revert LaunchpadFactoryInvalidAddress();
        _;
    }

    constructor(address _uniswapV2Router) {
        if (_uniswapV2Router == address(0))
            revert LaunchpadFactoryInvalidRouter();

        uniswapV2Router = _uniswapV2Router;
    }

    function createLaunchpad(
        string memory _name,
        string memory _symbol
    ) external whenNotPaused returns (address token) {
        token = _deployToken(address(this), _name, _symbol);

        uint256 tokensLiquidity = (TOTAL_SUPPLY * 2000) / 10_000;
        uint256 tokenSupply = TOTAL_SUPPLY - tokensLiquidity;

        tokenData[token] = TokenData({
            tokensLiquidity: tokensLiquidity,
            tokenSupply: tokenSupply,
            ethSupply: 0,
            isMigrated: false
        });

        tokens[token] = IERC20(token);
        allTokens.push(token);

        IERC20(token).approve(uniswapV2Router, tokensLiquidity);

        emit LaunchpadCreation(token, msg.sender);
        return token;
    }

    function buyTokens(
        address tokenAddress,
        uint256 amountOutMin
    )
        external
        payable
        nonReentrant
        whenNotPaused
        validToken(tokenAddress)
        whenNotMigrated(tokenAddress)
        returns (uint256 amountOut)
    {
        uint256 ethAmount = msg.value;
        if (ethAmount == 0) revert LaunchpadFactoryInsufficientInputAmount();

        TokenData storage data = tokenData[tokenAddress];

        uint256 totalSupplyAfterETH = data.ethSupply + ethAmount;
        if (totalSupplyAfterETH >= THRESHOLD) {
            data.isMigrated = true;
            amountOut = _fillOrder(
                tokenAddress,
                ethAmount,
                totalSupplyAfterETH
            );
            return amountOut;
        }

        amountOut = BondingCurve.calculatePurchaseReturn(
            data.ethSupply,
            ethAmount
        );
        if (amountOut > data.tokenSupply)
            revert LaunchpadFactoryInsufficientLiquidity();
        if (amountOut < amountOutMin)
            revert LaunchpadFactoryInsufficientOutputAmount();

        data.ethSupply += ethAmount;
        data.tokenSupply -= amountOut;

        tokens[tokenAddress].safeTransfer(msg.sender, amountOut);

        emit TokenPurchase(tokenAddress, msg.sender, ethAmount, amountOut);

        return amountOut;
    }

    function sellTokens(
        address tokenAddress,
        uint256 amountIn,
        uint256 amountOutMin
    )
        external
        nonReentrant
        whenNotPaused
        validToken(tokenAddress)
        whenNotMigrated(tokenAddress)
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert LaunchpadFactoryInsufficientInputAmount();

        TokenData storage data = tokenData[tokenAddress];

        uint256 ethReturn = BondingCurve.calculateSellReturn(
            data.ethSupply,
            amountIn
        );
        if (ethReturn < amountOutMin)
            revert LaunchpadFactoryInsufficientOutputAmount();
        if (ethReturn > data.ethSupply)
            revert LaunchpadFactoryInsufficientLiquidity();

        data.ethSupply -= ethReturn;
        data.tokenSupply += amountIn;

        tokens[tokenAddress].safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        payable(msg.sender).sendValue(ethReturn);

        emit TokenSale(tokenAddress, msg.sender, amountIn, ethReturn);

        return ethReturn;
    }

    function getAllTokenPrices()
        external
        view
        returns (TokenPrice[] memory prices)
    {
        prices = new TokenPrice[](allTokens.length);

        for (uint i = 0; i < allTokens.length; i++) {
            address tokenAddr = allTokens[i];
            TokenData storage data = tokenData[tokenAddr];

            uint256 currentPrice = data.ethSupply > 0
                ? BondingCurve.calculatePurchaseReturn(data.ethSupply, 1 ether)
                : BondingCurve.calculatePurchaseReturn(0, 1 ether);

            prices[i] = TokenPrice({
                tokenAddress: tokenAddr,
                currentPrice: currentPrice,
                ethSupply: data.ethSupply,
                tokenSupply: data.tokenSupply,
                isMigrated: data.isMigrated
            });
        }

        return prices;
    }

    function getEthersOutAtCurrentSupply(
        address tokenAddress,
        uint256 amountIn
    ) public view validToken(tokenAddress) returns (uint256 amountOut) {
        amountOut = BondingCurve.calculateSellReturn(
            tokenData[tokenAddress].ethSupply,
            amountIn
        );
    }

    function getTokensOutAtCurrentSupply(
        address tokenAddress,
        uint256 amountIn
    ) public view validToken(tokenAddress) returns (uint256 amountOut) {
        amountOut = BondingCurve.calculatePurchaseReturn(
            tokenData[tokenAddress].ethSupply,
            amountIn
        );
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _fillOrder(
        address tokenAddress,
        uint256 amountIn,
        uint256 totalSupply
    ) internal returns (uint256 amountOut) {
        TokenData storage data = tokenData[tokenAddress];

        uint256 excess = totalSupply - THRESHOLD;
        uint256 contribution = amountIn - excess;

        if (excess > 0) {
            payable(msg.sender).sendValue(excess);
            amountOut = BondingCurve.calculatePurchaseReturn(
                data.ethSupply,
                contribution
            );
            if (amountOut > data.tokenSupply)
                revert LaunchpadFactoryInsufficientLiquidity();
            data.ethSupply += contribution;
            data.tokenSupply -= amountOut;

            tokens[tokenAddress].safeTransfer(msg.sender, amountOut);
        }

        _migrateLiquidity(tokenAddress, THRESHOLD, data.tokensLiquidity);
        emit TokenPurchase(tokenAddress, msg.sender, contribution, amountOut);
        return amountOut;
    }

    function _migrateLiquidity(
        address tokenAddress,
        uint256 ethAmount,
        uint256 tokenAmount
    ) internal {
        if (ethAmount == 0 || tokenAmount == 0)
            revert LaunchpadFactoryInsufficientInputAmount();

        uint256 minTokenAmount = (tokenAmount * 95) / 100;
        uint256 minEthAmount = (ethAmount * 95) / 100;

        IUniswapV2Router02(uniswapV2Router).addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenAmount,
            minTokenAmount,
            minEthAmount,
            address(this),
            block.timestamp
        );

        address tokenPairLP = IUniswapV2Factory(
            IUniswapV2Router02(uniswapV2Router).factory()
        ).getPair(tokenAddress, IUniswapV2Router02(uniswapV2Router).WETH());

        if (tokenPairLP == address(0)) revert LaunchpadFactoryInvalidAddress();

        IERC20(tokenPairLP).safeTransfer(
            address(0xdead),
            IERC20(tokenPairLP).balanceOf(address(this))
        );
        emit LiquidityMigration(
            tokenAddress,
            tokenPairLP,
            ethAmount,
            tokenAmount
        );
    }

    function _deployToken(
        address _beneficiary,
        string memory _name,
        string memory _symbol
    ) internal whenNotPaused returns (address token) {
        token = address(new Token(TOTAL_SUPPLY, _beneficiary, _name, _symbol));
        if (token == address(0)) revert LaunchpadFactoryTokenDeploymentFailed();
    }
}
