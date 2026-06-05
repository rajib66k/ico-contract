// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console, Test} from "forge-std/Test.sol";
import {MynaToken} from "../src/Myna.sol";
import {TokenICO} from "../src/TokenICO.sol";
import {DeployICO} from "../script/DeployICO.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./Mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MynaTest is Test {
    MynaToken public mynaToken;
    TokenICO public tokenIco;
    DeployICO public deployer;
    HelperConfig public config;
    HelperConfig.NetworkConfig public activeConfig;

    address public user = makeAddr("user");

    uint256 public constant STARTING_USER_BALANCE = 10 ether;

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
}
