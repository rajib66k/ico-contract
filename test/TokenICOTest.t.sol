// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console, Test} from "forge-std/Test.sol";
import {MynaToken} from "../src/Myna.sol";
import {TokenICO} from "../src/TokenICO.sol";
import {DeployICO} from "../script/DeployICO.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./Mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MynaTest is Test {
    event TokensPurchased(address indexed buyer, uint256 paymentTokenAmount, uint256 saleTokenAmount);
    event SaleRefundEnabled(uint256 timestamp);
    event SaleFinalizedSuccessfully(uint256 timestamp);
    event FundsWithdrawn(uint256 amount);
    event UnsoldTokensWithdrawn(uint256 amount);

    MynaToken public mynaToken;
    TokenICO public tokenIco;
    DeployICO public deployer;
    HelperConfig public config;
    HelperConfig.NetworkConfig public activeConfig;

    address public user = makeAddr("user");

    uint256 public constant STARTING_USER_BALANCE = 1000 ether;
    uint256 public constant SALE_TOKENS_AMOUNT = 100 ether;

    function setUp() public {
        deployer = new DeployICO();
        (mynaToken, tokenIco, config) = deployer.run();

        (activeConfig) = config.getActiveNetworkConfig();

        ERC20Mock(activeConfig.weth).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    function testRevertsIfVestingDurationIsZeroOrLessThanCliffDuration() public {
        uint256 wrongVestingDuration = 120 days;
        uint256 wrongCliffDuration = 121 days;

        vm.expectRevert(TokenICO.TokenICO__InvalidVestingDuration.selector);
        new TokenICO(
            activeConfig.weth,
            activeConfig.wethUsdPriceFeed,
            activeConfig.saleTokenPrice,
            activeConfig.saleEndTime,
            activeConfig.maxTokenForSale,
            activeConfig.softCap,
            activeConfig.maxTokenPerUser,
            0,
            activeConfig.cliffDuration,
            activeConfig.initialUnlockPercentage
        );

        vm.expectRevert(TokenICO.TokenICO__InvalidCliffDuration.selector);
        new TokenICO(
            activeConfig.weth,
            activeConfig.wethUsdPriceFeed,
            activeConfig.saleTokenPrice,
            activeConfig.saleEndTime,
            activeConfig.maxTokenForSale,
            activeConfig.softCap,
            activeConfig.maxTokenPerUser,
            wrongVestingDuration,
            wrongCliffDuration,
            activeConfig.initialUnlockPercentage
        );
    }

    function testRevertsIfInitialUnlockPercentageIsMoreThanPercentagePrecision(uint256 initialUnlockPercentage) public {
        initialUnlockPercentage = bound(initialUnlockPercentage, 100e18 + 1, type(uint96).max);

        vm.expectRevert(TokenICO.TokenICO__InvalidInitialUnlockPercentage.selector);
        new TokenICO(
            activeConfig.weth,
            activeConfig.wethUsdPriceFeed,
            activeConfig.saleTokenPrice,
            activeConfig.saleEndTime,
            activeConfig.maxTokenForSale,
            activeConfig.softCap,
            activeConfig.maxTokenPerUser,
            activeConfig.vestingDuration,
            activeConfig.cliffDuration,
            initialUnlockPercentage
        );
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testGetTokenAmountFromUsd(uint256 usdAmount) public view {
        usdAmount = bound(usdAmount, 0, type(uint96).max);
        uint256 expectedWeth = usdAmount / 2000;
        uint256 amountWeth = tokenIco.getTokenAmountFromUsd(activeConfig.weth, usdAmount);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetSaleTokenAmountFromUsd(uint256 usdAmount) public view {
        usdAmount = bound(usdAmount, 0, type(uint96).max);
        uint256 expectedTokenAmount = usdAmount;
        uint256 tokenAmount = tokenIco.getSaleTokenAmountFromUsd(usdAmount);
        assertEq(tokenAmount, expectedTokenAmount);
    }

    //////////////////////////
    // Buy Tokens Tests     //
    //////////////////////////
    function _buySaleTokens(address buyer, uint256 usdAmount) internal {
        ERC20Mock weth = ERC20Mock(activeConfig.weth);
        weth.mint(buyer, STARTING_USER_BALANCE);

        vm.startPrank(buyer);
        weth.approve(address(tokenIco), type(uint256).max);

        tokenIco.buyTokens(usdAmount);

        vm.stopPrank();
    }

    function testBuyTokensRevertsIfSaleTimeOver() public {
        vm.warp(activeConfig.saleEndTime + 1);
        vm.startPrank(user);
        ERC20Mock(activeConfig.weth).approve(address(tokenIco), type(uint256).max);

        MockV3Aggregator mockV3Aggregator = MockV3Aggregator(activeConfig.wethUsdPriceFeed);
        mockV3Aggregator.updateRoundData(2, 2000e8, block.timestamp, block.timestamp);

        vm.expectRevert(TokenICO.TokenICO__SaleIsOver.selector);
        tokenIco.buyTokens(100 ether);
        vm.stopPrank();
    }

    function testBuyTokensRevertsIfUserBuyLessThanMinimum(uint256 usdAmount) public {
        usdAmount = bound(usdAmount, 0, tokenIco.I_SALE_TOKEN_PRICE() - 1);
        vm.startPrank(user);
        ERC20Mock(activeConfig.weth).approve(address(tokenIco), type(uint256).max);

        vm.expectRevert(TokenICO.TokenICO__InsufficientAmount.selector);
        tokenIco.buyTokens(usdAmount);
        vm.stopPrank();
    }

    function testBuyTokensRevertsIfUserExceedsMaxTokenPerUser() public {
        uint256 maxTokenPerUserInUsd = (activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice) / 1e18;

        vm.startPrank(user);
        ERC20Mock(activeConfig.weth).approve(address(tokenIco), type(uint256).max);

        vm.expectRevert(TokenICO.TokenICO__MaxTokensPerUserExceeded.selector);
        tokenIco.buyTokens(maxTokenPerUserInUsd + 1);

        tokenIco.buyTokens(maxTokenPerUserInUsd);

        vm.expectRevert(TokenICO.TokenICO__MaxTokensPerUserExceeded.selector);
        tokenIco.buyTokens(1e18);
        vm.stopPrank();

        (uint256 saleTokenAmount,,) = tokenIco.sUserData(user);
        assertEq(saleTokenAmount, activeConfig.maxTokenPerUser);
    }

    function testBuyTokensRevertsIfMaxSaleAmountReached() public {
        uint256 maxTokenPerUserInUsd = (activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice) / 1e18;
        uint256 maxTokenForSaleInUsd = (activeConfig.maxTokenForSale * activeConfig.saleTokenPrice) / 1e18;

        uint256 sold;

        while (sold + maxTokenPerUserInUsd <= maxTokenForSaleInUsd) {
            address newUser = makeAddr(vm.toString(sold));
            _buySaleTokens(newUser, maxTokenPerUserInUsd);
            sold += maxTokenPerUserInUsd;
        }

        address extraUser = makeAddr("extraUser");
        ERC20Mock weth = ERC20Mock(activeConfig.weth);
        weth.mint(extraUser, STARTING_USER_BALANCE);

        vm.startPrank(extraUser);
        weth.approve(address(tokenIco), type(uint256).max);

        vm.expectRevert(TokenICO.TokenICO__AllTokenSold.selector);
        tokenIco.buyTokens(maxTokenPerUserInUsd);

        vm.stopPrank();
    }

    function testBuyTokensUpdatesUserDataAndTotalSaleCorrectly(uint256 usdAmount) public {
        usdAmount = bound(
            usdAmount, tokenIco.I_SALE_TOKEN_PRICE(), activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice / 1e18
        );

        vm.startPrank(user);
        ERC20Mock(activeConfig.weth).approve(address(tokenIco), type(uint256).max);

        uint256 expectedSaleTokenAmount = usdAmount * 1e18 / activeConfig.saleTokenPrice;
        uint256 expectedPaymentTokenAmount = tokenIco.getTokenAmountFromUsd(activeConfig.weth, usdAmount);

        vm.expectEmit(true, false, false, true);
        emit TokensPurchased(user, expectedPaymentTokenAmount, expectedSaleTokenAmount);
        tokenIco.buyTokens(usdAmount);
        vm.stopPrank();

        (uint256 saleTokenAmount,, uint256 paymentTokenAmount) = tokenIco.sUserData(user);
        uint256 totalSale = tokenIco.sTokensSold();

        assertEq(saleTokenAmount, expectedSaleTokenAmount);
        assertEq(paymentTokenAmount, expectedPaymentTokenAmount);
        assertEq(totalSale, expectedSaleTokenAmount);
        assertEq(ERC20Mock(activeConfig.weth).balanceOf(address(tokenIco)), expectedPaymentTokenAmount);
    }

    //////////////////////////////
    // Set Sale Token Tests     //
    //////////////////////////////
    function testSetSaleTokenRevertsIfNotOwner() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        tokenIco.setSaleToken(address(mynaToken));
        vm.stopPrank();
    }

    function testSetSaleTokenSetsSaleTokenCorrectly() public {
        vm.startPrank(tokenIco.owner());
        tokenIco.setSaleToken(address(mynaToken));
        assertEq(tokenIco.sSaleToken(), address(mynaToken));
        vm.stopPrank();
    }

    /////////////////////////////
    // Finalize Sale Tests     //
    /////////////////////////////
    function testFinalizeSaleRevertsIfNotOwnerOrSaleOrOverOrSaleIsNotPending() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        tokenIco.finalizeSale();
        vm.stopPrank();

        vm.startPrank(tokenIco.owner());
        vm.expectRevert(TokenICO.TokenICO__SaleNotEnded.selector);
        tokenIco.finalizeSale();

        vm.warp(activeConfig.saleEndTime + 1);
        tokenIco.finalizeSale();

        vm.expectRevert(TokenICO.TokenICO__SaleAlreadyFinalized.selector);
        tokenIco.finalizeSale();
        vm.stopPrank();
    }

    function testFinalizeSaleIfSoftCapReachedRevertsIfNoSaleTokenSetOrNotEnoughTokens() public {
        uint256 maxTokenPerUserInUsd = (activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice) / 1e18;

        uint256 sold;

        while (sold < activeConfig.softCap) {
            address newUser = makeAddr(vm.toString(sold));
            _buySaleTokens(newUser, maxTokenPerUserInUsd);
            sold += maxTokenPerUserInUsd;
        }

        vm.warp(activeConfig.saleEndTime + 1);

        vm.startPrank(tokenIco.owner());
        vm.expectRevert(TokenICO.TokenICO__NoIcoToken.selector);
        tokenIco.finalizeSale();

        tokenIco.setSaleToken(address(mynaToken));
        mynaToken.transfer(address(tokenIco), activeConfig.softCap - 1);

        vm.expectRevert(TokenICO.TokenICO__NotEnoughIcoToken.selector);
        tokenIco.finalizeSale();
        vm.stopPrank();

        assert(tokenIco.sSaleFinalized() == TokenICO.SaleFinalized.PENDING);
    }

    function testFinalizeSaleUpdatesStateAsRefundIfSoftCapNotReached() public {
        vm.startPrank(tokenIco.owner());
        vm.warp(activeConfig.saleEndTime + 1);
        vm.expectEmit(false, false, false, true);
        emit SaleRefundEnabled(block.timestamp);
        tokenIco.finalizeSale();
        assert(tokenIco.sSaleFinalized() == TokenICO.SaleFinalized.REFUND);
        vm.stopPrank();
    }

    function testFinalizeSaleUpdatesStateAsSuccessfulIfSoftCapReached() public {
        uint256 maxTokenPerUserInUsd = (activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice) / 1e18;

        uint256 sold;

        while (sold < activeConfig.softCap) {
            address newUser = makeAddr(vm.toString(sold));
            _buySaleTokens(newUser, maxTokenPerUserInUsd);
            sold += maxTokenPerUserInUsd;
        }

        vm.warp(activeConfig.saleEndTime + 1);

        vm.startPrank(tokenIco.owner());
        tokenIco.setSaleToken(address(mynaToken));
        mynaToken.transfer(address(tokenIco), sold);

        vm.expectEmit(false, false, false, true);
        emit SaleFinalizedSuccessfully(block.timestamp);
        tokenIco.finalizeSale();

        assert(tokenIco.sSaleFinalized() == TokenICO.SaleFinalized.SUCCESSFUL);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // Owner Withdraw Funds Tests     //
    ////////////////////////////////////
    modifier finalizeSaleSuccessful() {
        uint256 maxTokenPerUserInUsd = (activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice) / 1e18;

        uint256 sold;

        while (sold < activeConfig.softCap) {
            address newUser = makeAddr(vm.toString(sold));
            _buySaleTokens(newUser, maxTokenPerUserInUsd);
            sold += maxTokenPerUserInUsd;
        }

        vm.warp(activeConfig.saleEndTime + 1);

        vm.startPrank(tokenIco.owner());
        tokenIco.setSaleToken(address(mynaToken));
        mynaToken.transfer(address(tokenIco), sold);
        tokenIco.finalizeSale();
        vm.stopPrank();

        assert(tokenIco.sSaleFinalized() == TokenICO.SaleFinalized.SUCCESSFUL);
        _;
    }

    function testWithdrawFundsRevertsIfNotOwnerOrSaleFinalizedIsNotSuccessful(uint256 usdAmount) public {
        usdAmount = bound(
            usdAmount, tokenIco.I_SALE_TOKEN_PRICE(), activeConfig.maxTokenPerUser * activeConfig.saleTokenPrice / 1e18
        );

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        tokenIco.withdrawFunds();
        vm.stopPrank();

        vm.startPrank(tokenIco.owner());
        vm.expectRevert(TokenICO.TokenICO__SaleNotFinalizedAsSuccessful.selector);
        tokenIco.withdrawFunds();
        vm.stopPrank();

        _buySaleTokens(user, usdAmount);

        vm.warp(activeConfig.saleEndTime + 1);
        MockV3Aggregator mockV3Aggregator = MockV3Aggregator(activeConfig.wethUsdPriceFeed);
        mockV3Aggregator.updateRoundData(2, 2000e8, block.timestamp, block.timestamp);

        vm.startPrank(tokenIco.owner());
        tokenIco.finalizeSale();

        vm.expectRevert(TokenICO.TokenICO__SaleNotFinalizedAsSuccessful.selector);
        tokenIco.withdrawFunds();
        vm.stopPrank();

        assert(
            ERC20Mock(activeConfig.weth).balanceOf(address(tokenIco))
                == tokenIco.getTokenAmountFromUsd(activeConfig.weth, usdAmount)
        );
    }

    function testWithdrawFundsRevertsIfBalanceOfTokenIcoIsZero() public finalizeSaleSuccessful {
        vm.startPrank(tokenIco.owner());
        tokenIco.withdrawFunds();
        vm.expectRevert(TokenICO.TokenICO__NotEnoughFunds.selector);
        tokenIco.withdrawFunds();
        vm.stopPrank();
    }

    function testWithdrawFundsTransfersFundsToOwner() public finalizeSaleSuccessful {
        uint256 expectedAmount = ERC20Mock(activeConfig.weth).balanceOf(address(tokenIco));

        vm.startPrank(tokenIco.owner());
        vm.expectEmit(false, false, false, true);
        emit FundsWithdrawn(expectedAmount);
        tokenIco.withdrawFunds();
        vm.stopPrank();

        assertEq(ERC20Mock(activeConfig.weth).balanceOf(tokenIco.owner()), expectedAmount);
    }

    ////////////////////////////////////////////
    // Owner Withdraw Unsold Tokens Tests     //
    ////////////////////////////////////////////
    function testWithdrawUnsoldTokensRevertsIfNotOwnerOrSaleFinalizedIsPending() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        tokenIco.withdrawUnsoldTokens();
        vm.stopPrank();

        vm.startPrank(tokenIco.owner());
        vm.expectRevert(TokenICO.TokenICO__SaleNotFinalized.selector);
        tokenIco.withdrawUnsoldTokens();
        vm.stopPrank();
    }

    function testWithdrawUnsoldTokensRevertsIfBalanceOfTokenIcoIsLessThanMinimum() public finalizeSaleSuccessful {
        vm.startPrank(tokenIco.owner());
        vm.expectRevert(TokenICO.TokenICO__NotEnoughIcoToken.selector);
        tokenIco.withdrawUnsoldTokens();
        vm.stopPrank();
    }

    function testWithdrawUnsoldTokensTransfersUnsoldTokensToOwner() public finalizeSaleSuccessful {
        uint256 soldToken = tokenIco.sTokensSold();
        uint256 expectedOwnerBalance = mynaToken.totalSupply() - soldToken;

        vm.startPrank(tokenIco.owner());
        mynaToken.transfer(address(tokenIco), SALE_TOKENS_AMOUNT);

        uint256 balanceBefore = mynaToken.balanceOf(tokenIco.owner());

        vm.expectEmit(false, false, false, true);
        emit UnsoldTokensWithdrawn(SALE_TOKENS_AMOUNT);
        tokenIco.withdrawUnsoldTokens();
        vm.stopPrank();

        uint256 balanceAfter = mynaToken.balanceOf(tokenIco.owner());

        assertEq(balanceAfter - balanceBefore, SALE_TOKENS_AMOUNT);
        assertEq(mynaToken.balanceOf(tokenIco.owner()), expectedOwnerBalance);
    }
}
