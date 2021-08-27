// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; //for reference
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
//need chainlink VRF

contract Raffle is IERC721Receiver, Ownable {
    using SafeMath for uint256;

    //======================================== VARIABLES ========================================

    /*
    Information for a sale
    @nftContract address of the nft's ERC721 contract
    @tokenId tokenId of the ERC721
    @sellerAddress address of the seller
    @depositAmount requiried bid amount, in ether, allowed for raffle participants
        clarification: ie, if it should be .5 ETH, it should be 500000000000000000
        clarificaton: each address can only deposit once per sale
    @totalAmount current amount deposited
    @maxAmount maximum amount, in ether, allowed for the raffle 
    @canWithdraw false unless the raffle has failed
    @isComplete false unless the raffle succeeds
    @isStarted false unless the raffle has started
    @deposits mapping of addresses to amount deposited
        clarification: each address can only deposit once per sale
    @winner address of winner, starts at 0x0
    @expirationTime time since last deposit that will allow the seller to cancel the raffle
    @lastDepositTime time of the last deposit
        clarification: if the current time is > expirationTime since the last
        deposit, the seller can call the stopRaffle function to cancel the raffle
        which allows the seller to withdraw the NFT and all depositors to 
        withdraw their ETH
    */
    struct SaleInfo {
        ERC721 nftContract;
        uint256 tokenId;
        address sellerAddress;
        uint256 depositAmount;
        uint256 totalAmount;
        uint256 maxAmount;
        bool canWithdraw;
        bool isComplete;
        bool isStarted;
        address winner;
        uint256 expirationTime;
        uint256 lastDepositTime;
    }

    uint256 public currentSaleId;

    uint256 private ownerPercentage;

    mapping(uint256 => SaleInfo) sales;

    mapping(uint256 => mapping(address => uint256)) deposits;

    event NFTDeposit(uint256 indexed saleId);
    event SaleStarted(uint256 indexed saleId);
    event SaleEnded(uint256 indexed saleId, address winner);
    event Deposit(address indexed user, uint256 sale, uint256 amount);
    event WithdrawDeposit(address indexed user, uint256 sale, uint256 amount);
    event WithdrawNFT(address indexed user, uint256 sale, uint256 tokenId);

    //======================================== FUNCTIONS ========================================

    constructor() {
        ownerPercentage = 5; //5%
        //may need to register interface
    }

    //receive NFT
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) public virtual override returns (bytes4) {
        uint256 _saleId = currentSaleId;
        sales[currentSaleId] = SaleInfo({
            nftContract: ERC721(from),
            tokenId: tokenId,
            sellerAddress: operator,
            depositAmount: 0,
            totalAmount: 0,
            maxAmount: 0,
            canWithdraw: false,
            isComplete: false,
            isStarted: false,
            winner: address(0),
            expirationTime: 0,
            lastDepositTime: 0
        });
        currentSaleId.add(1);
        emit NFTDeposit(_saleId);
        return this.onERC721Received.selector;
    }

    //start the sale
    function beginSale(uint256 _saleId, uint256 _depositAmount, uint256 _maxAmount, uint256 _expirationTime) public {
        require(msg.sender == sales[_saleId].sellerAddress, "Seller must begin the sale");
        sales[_saleId].depositAmount = _depositAmount; //would need to check for divisibility 
        sales[_saleId].maxAmount = _maxAmount;
        sales[_saleId].isStarted = true;
        sales[_saleId].expirationTime = _expirationTime;
        sales[_saleId].lastDepositTime = block.timestamp;
        emit SaleStarted(_saleId);
    }

    //end the sale (anyone can do this)
    function endSale(uint256 _saleId) public {
        require(sales[_saleId].totalAmount == sales[_saleId].maxAmount, "Sale is not over yet");
        //additional checks
        //contact chainlink VRF to get random number and safeTransferFrom to a random depositor for the sale
        address placeholderWinner = address(0);
        sales[_saleId].isComplete = true;
        emit SaleEnded(_saleId, placeholderWinner);
    }

    //cancel the sale
    function cancelSale(uint256 _saleId) public {
        require(msg.sender == sales[_saleId].sellerAddress, "Only the seller can cancel the sale");
        uint256 checkTime = block.timestamp.sub(sales[_saleId].lastDepositTime);
        require(sales[_saleId].expirationTime > checkTime, "Enough time has not elapsed since last deposit");
        sales[_saleId].canWithdraw = true;
    }

    //getSale by emitting event
    function getSale(uint256 _saleId) public view returns (SaleInfo memory) {
        return sales[_saleId];
    }

    //withdraw NFT
    function withdrawNFT(uint256 _saleId) public {
        require(msg.sender == sales[_saleId].sellerAddress, "Only the seller can withdraw");
        require(sales[_saleId].canWithdraw, "Seller cannot currently withdraw, sale is not cancelled.");
        sales[_saleId].nftContract.safeTransferFrom(address(this), msg.sender, sales[_saleId].tokenId);
    }

    //deposit ETH for a sale
    function deposit(uint256 _saleId) external payable {
        require(sales[_saleId].isStarted, "Sale has not yet started");
        require(!sales[_saleId].canWithdraw, "Sale has been cancelled");
        require(!sales[_saleId].isComplete, "Sale is complete");
        require(deposits[_saleId][msg.sender] == 0, "Already deposited for this sale");
        require(msg.value == sales[_saleId].depositAmount, "Wrong amount to deposit");
        uint256 newAmount = sales[_saleId].totalAmount.add(msg.value);
        require(newAmount <= sales[_saleId].maxAmount, "Would deposit too much ETH");
        deposits[_saleId][msg.sender] = msg.value;
        sales[_saleId].totalAmount = sales[_saleId].totalAmount.add(msg.value);
        sales[_saleId].lastDepositTime = block.timestamp;
        emit Deposit(msg.sender, _saleId, msg.value);
    }

    //view deposit
    function getDeposit(uint256 _saleId) public view returns (uint256) { 
        return deposits[_saleId][msg.sender];
    }

    //view total amount deposited in a sale
    function getAmount(uint256 _saleId) public view returns (uint256) {
        return sales[_saleId].totalAmount;
    }

    function withdrawDeposit(address payable _caller, uint256 _saleId) public {
        require(_caller == msg.sender, "Must call withdraw for yourself");
        uint256 amountToTransfer = deposits[_saleId][msg.sender];
        require(amountToTransfer == sales[_saleId].depositAmount, "Depositor has not bid on this sale");
        _caller.transfer(amountToTransfer);
        emit WithdrawDeposit(msg.sender, _saleId, amountToTransfer);
    }

    //withdraw ETH for seller
    function withdrawSeller(uint256 _saleId) public {
        require(sales[_saleId].isComplete, "Sale is not complete");
        require(msg.sender == sales[_saleId].sellerAddress);
        //transfer 99.5% of sale's ETH to seller
        uint256 placeholder99point5ETH = 0;
        emit WithdrawNFT(msg.sender, _saleId, placeholder99point5ETH);
    }

    //inherited, use to set new contract owner
    //function transferOwnership(address _newOwner) public onlyOwner

    //withdraw ETH for owner
    function withdrawOwner(uint256 _saleId) public onlyOwner {
        require(sales[_saleId].isComplete, "Sale is not complete");
        uint256 totalAmount = sales[_saleId].totalAmount;
        //transfer .5% of sale's ETH to owner
    }

    //change owner percentage
    function setOwnerPercentage(uint8 _newPercentage) public onlyOwner {
        require(_newPercentage < 100, "Bad percentage");
        ownerPercentage = _newPercentage;
    }
}