// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    constructor (uint256 initialSupply) ERC20("Token", "TK") {
        _mint(msg.sender, initialSupply);
    }
}