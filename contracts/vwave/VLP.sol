// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../tokens/MintableBaseToken.sol"; // TODO

contract VLP is MintableBaseToken {
    constructor() MintableBaseToken("VWAVE LP", "VLP", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "VLP";
    }
}
