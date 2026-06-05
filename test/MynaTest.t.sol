// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MynaToken} from "../src/Myna.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MynaTest is Test {
    address public addr = makeAddr("addr");

    function testMintedTokenTransferToOwner(uint256 amount) public {
        amount = bound(amount, 0, type(uint96).max);

        vm.prank(addr);
        MynaToken myna = new MynaToken(amount);

        assertEq(IERC20(myna).balanceOf(addr), amount);
    }
}
