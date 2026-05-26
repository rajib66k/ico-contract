// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenICO (Token Sale)
 * @author Rajib Kumar Pradhan
 *
 * The system is designed to be simple, transparent, and fair, allowing participants to
 * purchase tokens during an Initial Coin Offering (ICO) with built-in vesting mechanisms
 * to prevent immediate token dumps and encourage long-term alignment.
 *
 * @notice This contract is the core of the Initial Coin Offering system. It handles all
 * logic for contributing funds, allocating tokens, and managing vesting-based claims.
 *
 */
contract TokenICO is Ownable {
    /////////////////////
    // Data Types      //
    /////////////////////
    /**
     * @dev Stores per-user ICO participation and claim data
     * @param saleTokenAmount Amount of sale tokens allocated to the user
     * @param claimedAmount Amount of tokens already claimed by the user
     * @param paymentTokenAmount Amount of payment tokens contributed by the user
     */
    struct UserData {
        uint256 saleTokenAmount;
        uint256 claimedAmount;
        uint256 paymentTokenAmount;
    }

    /**
     * @dev Represents the final state of the token sale
     * @param PENDING Sale is not finalized
     * @param SUCCESSFUL Sale completed successfully and tokens are claimable
     * @param REFUND Sale failed and users are eligible for refunds
     */
    enum SaleFinalized {
        PENDING,
        SUCCESSFUL,
        REFUND
    }

    ///////////////////////
    // State Variables   //
    ///////////////////////

    /// @dev Address of the token being sold
    address public sSaleToken;

    /// @dev Total amount of sale tokens purchased by users
    uint256 public sTokensSold;

    /// @dev Total amount of vested tokens claimed by users
    uint256 public sTokensClaimed;

    /// @dev Current sale finalization status
    SaleFinalized public sSaleFinalized;

    /// @dev Stores purchase and vesting data for each user
    mapping(address user => UserData data) public sUserData;

    ///////////////////////////
    // Immutable Variables   //
    ///////////////////////////

    /// @dev Address of the payment token
    address public immutable I_PAYMENT_TOKEN;

    /// @dev Address of the Chainlink price feed contract
    address public immutable I_PRICE_FEED;

    /// @dev Price per sale token denominated in payment token units
    uint256 public immutable I_SALE_TOKEN_PRICE;

    /// @dev Timestamp when the token sale ends
    uint256 public immutable I_SALE_END_TIME;

    /// @dev Maximum number of tokens allocated for the sale
    uint256 public immutable I_MAX_TOKEN_FOR_SALE;

    /// @dev Minimum funding goal in usd required for a successful sale
    uint256 public immutable I_SOFT_CAP;

    /// @dev Maximum number of tokens a single user can purchase
    uint256 public immutable I_MAX_TOKEN_PER_USER;

    /////////////////
    // Functions   //
    /////////////////
    /**
     * @notice Initializes the TokenICO contract with sale, pricing, and vesting parameters
     * @param paymentTokenAddress The ERC20 token used for payments
     * @param priceFeedAddress Chainlink price feed used for token pricing validation
     * @param saleTokenPrice Price per sale token in payment token units
     * @param saleEndTime Timestamp when the token sale ends
     * @param maxTokenForSale Maximum number of tokens available for sale
     * @param softCap Minimum amount of funds in usd required for a successful sale
     * @param maxTokenPerUser Maximum number of tokens a single user can purchase
     * @dev Sets initial sale state to PENDING
     */
    constructor(
        address paymentTokenAddress,
        address priceFeedAddress,
        uint256 saleTokenPrice,
        uint256 saleEndTime,
        uint256 maxTokenForSale,
        uint256 softCap,
        uint256 maxTokenPerUser
    ) Ownable(msg.sender) {
        I_PAYMENT_TOKEN = paymentTokenAddress;
        I_PRICE_FEED = priceFeedAddress;
        I_SALE_TOKEN_PRICE = saleTokenPrice;
        I_SALE_END_TIME = saleEndTime;
        I_MAX_TOKEN_FOR_SALE = maxTokenForSale;
        I_SOFT_CAP = softCap;
        I_MAX_TOKEN_PER_USER = maxTokenPerUser;

        sSaleFinalized = SaleFinalized.PENDING;
    }
}
