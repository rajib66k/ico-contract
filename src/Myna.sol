// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MynaToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("Myna", "MYNA") {
        _mint(msg.sender, initialSupply);
    }
}
