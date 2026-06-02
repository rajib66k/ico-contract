// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/Mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address weth;
        address wethUsdPriceFeed;
        uint256 saleTokenPrice;
        uint256 saleEndTime;
        uint256 maxTokenForSale;
        uint256 softCap;
        uint256 maxTokenPerUser;
        uint256 vestingDuration;
        uint256 cliffDuration;
        uint256 initialUnlockPercentage;
        uint256 totalSupply;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 public constant SEPOLIA_CHAINID = 11155111;
    uint256 public constant SALE_TOKEN_PRICE = 1e18;
    uint256 public constant SALE_END_AFTER_LUNCH = 15 days;
    uint256 public constant MAX_TOKEN_FOR_SALE = 100_000_000e18;
    uint256 public constant SOFT_CAP = 30_000_000e18;
    uint256 public constant MAX_TOKEN_PER_USER = 500_000e18;
    uint256 public constant VESTING_DURATION = 360 days;
    uint256 public constant CLIFF_DURATION = 30 days;
    uint256 public constant INITIAL_UNLOCK_PERCENTAGE = 20e18;
    uint256 public constant TOTAL_SUPPLY = 1000_000_000e18;

    constructor() {
        if (block.chainid == SEPOLIA_CHAINID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            saleTokenPrice: SALE_TOKEN_PRICE,
            saleEndTime: block.timestamp + SALE_END_AFTER_LUNCH,
            maxTokenForSale: MAX_TOKEN_FOR_SALE,
            softCap: SOFT_CAP,
            maxTokenPerUser: MAX_TOKEN_PER_USER,
            vestingDuration: VESTING_DURATION,
            cliffDuration: CLIFF_DURATION,
            initialUnlockPercentage: INITIAL_UNLOCK_PERCENTAGE,
            totalSupply: TOTAL_SUPPLY,
            deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        ERC20Mock weth = new ERC20Mock();
        MockV3Aggregator wethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        vm.stopBroadcast();

        return NetworkConfig({
            weth: address(weth),
            wethUsdPriceFeed: address(wethUsdPriceFeed),
            saleTokenPrice: SALE_TOKEN_PRICE,
            saleEndTime: block.timestamp + SALE_END_AFTER_LUNCH,
            maxTokenForSale: MAX_TOKEN_FOR_SALE,
            softCap: SOFT_CAP,
            maxTokenPerUser: MAX_TOKEN_PER_USER,
            vestingDuration: VESTING_DURATION,
            cliffDuration: CLIFF_DURATION,
            initialUnlockPercentage: INITIAL_UNLOCK_PERCENTAGE,
            totalSupply: TOTAL_SUPPLY,
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }

    function getActiveNetworkConfig() external view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
