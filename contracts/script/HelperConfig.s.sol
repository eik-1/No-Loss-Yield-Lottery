// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

abstract contract CodeConstants {
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant AVAX_FUJI_CHAIN_ID = 43113;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
}

contract HelperConfig is Script {
    struct NetworkConfig {
        
    }
}