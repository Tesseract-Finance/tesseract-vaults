// SPDX-License-Identifier: GNU Affero

pragma solidity ^0.6.12;

interface ICurveFi {
    function add_liquidity(
        uint256[5] calldata amounts,
        uint256 min_mint_amount
    ) external payable returns (uint256);

    function add_liquidity(
        uint256[5] calldata amounts,
        uint256 min_mint_amount,
        address receiver
    ) external payable returns (uint256);

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    function balances(int128) external view returns (uint256);

    function get_virtual_price() external view returns (uint256);

    function pool() external view returns (address);
}
