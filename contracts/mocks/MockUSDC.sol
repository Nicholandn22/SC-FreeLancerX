// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token untuk testing di testnet
 * @dev Menggunakan 6 decimals seperti USDC asli
 */
contract MockUSDC is ERC20, Ownable {
    
    constructor() ERC20("Mock USDC", "mUSDC") {
        // Mint 1 juta USDC ke deployer
        _mint(msg.sender, 1_000_000 * 10**6);
    }
    
    /**
     * @notice Override decimals untuk match USDC (6 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    /**
     * @notice Public mint function untuk testing
     * @param to Address tujuan
     * @param amount Amount dalam base unit (1 USDC = 1e6)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    /**
     * @notice Faucet function - setiap orang bisa claim 1000 USDC
     */
    function faucet() external {
        _mint(msg.sender, 1000 * 10**6); // 1000 USDC
    }
}