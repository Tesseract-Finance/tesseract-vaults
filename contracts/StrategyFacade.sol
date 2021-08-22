// SPDX-License-Identifier: GNU Affero
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import {StrategyAPI} from "./BaseStrategy.sol";

/// @title Facade contract for Gelato Resolver contract
/// @author Tesseract Finance
contract StrategyFacade {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet internal availableStrategies;
    address public immutable multiSig;

    event StrategyAdded(address strategy);
    event StrategyRemoved(address strategy);

    modifier onlyMultiSig {
        require(msg.sender == multiSig, "Only MultiSig can call");
        _;
    }

    constructor(address _multiSig) public {
        multiSig = _multiSig;
    }

    function addStrategy(address _strategy) public onlyMultiSig {
        require(!availableStrategies.contains(_strategy), "StrategyResolver::addStrategy: Strategy already added");

        availableStrategies.add(_strategy);

        emit StrategyAdded(_strategy);
    }

    function removeStrategy(address _strategy) public onlyMultiSig {
        require(!!availableStrategies.contains(_strategy), "StrategyResolver::removeStrategy: Strategy already removed");

        availableStrategies.remove(_strategy);

        emit StrategyRemoved(_strategy);
    }

    function checkHarvest(uint256 _callCost) public view returns (bool canExec, address strategy) {
        for (uint256 i; i < availableStrategies.length(); i++) {
            address currentStrategy = availableStrategies.at(i);
            if (StrategyAPI(currentStrategy).harvestTrigger(_callCost)) {
                return (canExec = true, strategy = currentStrategy);
            }
        }

        return (canExec = false, strategy = address(0));
    }

    function harvest(address _strategy) public {
        StrategyAPI(_strategy).harvest();
    }
}
