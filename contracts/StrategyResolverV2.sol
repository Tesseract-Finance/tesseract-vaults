// SPDX-License-Identifier: GNU Affero
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import {StrategyAPI} from "./BaseStrategy.sol";

/// @title Resolver contract for Gelato harvest bot, for One Task Per Strategy solution with no need for StrategyFacade
/// @author Tesseract Finance
contract StrategyResolverV2 is Ownable {
    address public strategy; // Action contract for the Gelato bot

    constructor(address _strategy) public {
        setStrategy(_strategy);
    }

    function setStrategy(address _strategy) public onlyOwner {
        strategy = _strategy;
    }

    function check(uint256 _callCost) external view returns (bool canExec, bytes memory execPayload) {
        canExec = StrategyAPI(strategy).harvestTrigger(_callCost);

        execPayload = abi.encodeWithSelector(StrategyAPI.harvest.selector);
    }
}
