// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {MynaToken} from "../src/Myna.sol";
import {TokenICO} from "../src/TokenICO.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployICO is Script {
    function run() external returns (MynaToken, TokenICO, HelperConfig) {
        HelperConfig config = new HelperConfig();
        HelperConfig.NetworkConfig memory netConfig = config.getActiveNetworkConfig();

        vm.startBroadcast(netConfig.deployerKey);
        MynaToken mynaToken = new MynaToken(netConfig.totalSupply);
        TokenICO tokenIco = new TokenICO(
            netConfig.weth,
            netConfig.wethUsdPriceFeed,
            netConfig.saleTokenPrice,
            netConfig.saleEndTime,
            netConfig.maxTokenForSale,
            netConfig.softCap,
            netConfig.maxTokenPerUser,
            netConfig.vestingDuration,
            netConfig.cliffDuration,
            netConfig.initialUnlockPercentage
        );
        vm.stopBroadcast();

        return (mynaToken, tokenIco, config);
    }
}
