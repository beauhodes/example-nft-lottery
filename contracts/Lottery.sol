// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

contract Lottery is IERC721Receiver, VRFConsumerBase, Ownable {

    //======================================== VARIABLES ========================================

    //token used for all sales
    address base;

    /*
    Information for a sale:
    @nftContract address of the nft's ERC721 contract
    @tokenId tokenId of the ERC721
    @sellerAddress address of the seller
    @depositAmount required bid amount allowed for sale participants
        clarificaton: necessary to keep constant in order to efficiently select a random winner
    @currentAmount current amount deposited
    @maxAmount maximum amount allowed for the sale 
    @state current state of the sale
        clarification: possible states are:
        0. NFT deposited but sale not started by the depositor
        1. Sale has been started by the depositor and is live
        2. Sale has been cancelled prior to completion AND NFT has not yet been withdrawn
        3. Sale has been cancelled prior to completion AND NFT has been withdrawn
        4. Sale is complete
    @sellerWithdrawn false until seller has withdrawn proceeds
    @ownerWithdrawn false until owner has withdrawn proceeds
    @winner address of winner, starts at 0 address
    @expirationBlocks blocks since last deposit that will allow ANYONE to cancel the sale
        clarification: must be passed in as a number of blocks
    @lastDepositBlock time of the last deposit
        clarification: if the current block's timestamp is > expirationBlocks + lastDepositBlock,
        anyone can call the stopSale function to cancel the sale
        which sets isComplete to true and allows the seller to withdraw the NFT and all depositors to 
        withdraw their deposits
    @depositors dynamic array of depositors' addresses
    @depositsWithdrawn dynamic array to tell whether a deposit has been withdrawn
        clarification: will be same length as depositors, as entry indices correspond
    */
    struct SaleInfo {
        address nftContract;
        uint256 tokenId;
        address sellerAddress;
        uint256 depositAmount;
        uint256 currentAmount;
        uint256 maxAmount;
        bool sellerWithdrawn;
        bool ownerWithdrawn;
        uint8 state;
        address winner;
        uint256 expirationBlocks;
        uint256 lastDepositBlock;
        address[] depositors;
        bool[] depositsWithdrawn;
    }

    //Chainlink vars:
    bytes32 internal keyHash;
    uint256 linkFee;
    uint256 public randomResult;
    address public VRFCoordinator; // rinkeby: 0xb3dCcb4Cf7a26f6cf6B120Cf5A73875B7BBc655B
    address public LinkToken; // rinkeby: 0x01BE23585060835E02B77ef475b0Cc51aA1e0709a
    mapping(bytes32 => uint256) requestToSaleId;

    //latest sale id, accumulatoooor
        //will begin at 1, 0 is not used
    uint256 public currentSaleId;

    //optional owner percentage for all completed sales, only allows 0-10 values
    uint256 private ownerPercentage;

    //mapping from sale id to sale's struct
    mapping(uint256 => SaleInfo) sales;

    //events
    event NFTDeposit(uint256 indexed saleId, address indexed nftContract, address indexed user, uint256 nftId);
    event SaleStarted(uint256 indexed saleId);
    event SaleEnded(uint256 indexed saleId, address winner);
    event SaleCancelled(uint256 indexed saleId);
    event Deposit(uint256 indexed sale, address indexed user);
    event WithdrawDeposit(uint256 indexed sale, address user);
    event WithdrawNFT(uint256 indexed sale, address user);
    event WithdrawProceeds(uint256 indexed sale, uint256 amount, address user);

    //======================================== FUNCTIONS ========================================

    //======================================== CONSTRUCTOR ========================================

    constructor(address _baseToken, address _VRFCoordinator, address _LinkToken, bytes32 _keyHash) 
        VRFConsumerBase(_VRFCoordinator, _LinkToken) {
        base = _baseToken;
        ownerPercentage = 5;
        VRFCoordinator = _VRFCoordinator; //change by network, store to ensure correctness
        LinkToken = _LinkToken; //change by network
        keyHash = _keyHash;
        linkFee = 0.1 * 10**18; //change by network
    }

    //======================================== SALE CREATION ========================================

    //seller deposits NFT
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) public virtual override returns (bytes4) {
        currentSaleId += 1;
        sales[currentSaleId] = SaleInfo({
            nftContract: msg.sender,
            tokenId: tokenId,
            sellerAddress: from,
            depositAmount: 0,
            currentAmount: 0,
            maxAmount: 0,
            sellerWithdrawn: false,
            ownerWithdrawn: false,
            state: 0,
            winner: address(0),
            expirationBlocks: 0,
            lastDepositBlock: 0,
            depositors: new address[](0),
            depositsWithdrawn: new bool[](0)
        });
        emit NFTDeposit(currentSaleId, msg.sender, from, tokenId);
        return this.onERC721Received.selector;
    }

    //withdraw NFT if seller changes mind
    function withdrawNFTPresale(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(msg.sender == sale.sellerAddress, "Only the seller can withdraw");
        require(sale.state == 0, "Sale has been started");
        sale.state = 4;
        emit WithdrawNFT(_saleId, msg.sender);
        IERC721(sale.nftContract).transferFrom(address(this), msg.sender, sale.tokenId);
    }

    /*
    NFT depositor starts sale with specified parameters:
    @_saleId id of the sale; caller must be seller
    @_depositAmount amount per deposit
    @_maxAmount amount the seller wants to raise total
    @_expirationBlocks amount of blocks that can pass from the last deposit until seller can cancel the sale
    */
    function beginSale(uint256 _saleId, uint256 _depositAmount, uint256 _maxAmount, uint256 _expirationBlocks) public {
        SaleInfo storage sale = sales[_saleId];
        require(msg.sender == sale.sellerAddress, "Seller must begin the sale");
        sale.depositAmount = _depositAmount;
        sale.maxAmount = _maxAmount; //if maxAmount is not directly divisible by depositAmount, the final deposit will necessarily go over the maxAmount
        sale.state = 1;
        sale.expirationBlocks = _expirationBlocks;
        sale.lastDepositBlock = block.number;
        emit SaleStarted(_saleId);
    }

    //======================================== ON-GOING SALE ACTIONS ========================================

    //contribute to a sale
    function deposit(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(sale.state == 1, "Sale is not in progress");
        require(sale.currentAmount <= sale.maxAmount, "Sale is already full");

        sale.currentAmount += sale.depositAmount;
        sale.lastDepositBlock = block.number;
        sale.depositors.push(msg.sender);
        sale.depositsWithdrawn.push(false);
        emit Deposit(_saleId, msg.sender);

        bool success = IERC20(base).transferFrom(msg.sender, address(this), sale.depositAmount);
        require(success, "Failed transfer");
    }

    //end the sale (anyone can do this)
    function completeSale(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(sale.state == 1, "Sale is not in progress");
        require(sale.currentAmount >= sale.maxAmount, "Sale is not yet full");
        require(LINK.balanceOf(address(this)) >= linkFee, "Not enough LINK for fee");

        //contact chainlink VRF to get random number and safeTransferFrom to a random depositor for the sale
        bytes32 requestId = requestRandomness(keyHash, linkFee);
        requestToSaleId[requestId] = _saleId;
    }

    //callback to end sale with randomness
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        uint256 saleId = requestToSaleId[requestId];
        SaleInfo storage sale = sales[saleId];
        require(sale.state == 1, "State is wrong");
        uint256 arrayLength = sale.depositors.length;
        address winner = sale.depositors[randomness % arrayLength];

        sale.winner = winner;
        sale.state = 4;

        emit SaleEnded(saleId, winner);
    }

    //======================================== COMPLETED SALE ACTIONS ========================================

    function withdrawWinner(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(sale.state == 4, "Sale is not complete");
        require(sale.winner == msg.sender, "Must be winner to withdraw NFT");

        emit WithdrawNFT(_saleId, msg.sender);
        IERC721(sale.nftContract).transferFrom(address(this), sale.winner, sale.tokenId); //todo: prevent replay
    }

    //withdraw tokens for seller after sale is complete
    function withdrawSeller(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(sale.state == 4, "Sale is not complete");
        require(sale.sellerAddress == msg.sender, "Must be seller to withdraw proceeds");
        require(!sale.sellerWithdrawn, "Already withdrawn"); //prevent replay
        sale.sellerWithdrawn = true;
        uint256 withdrawAmount = (sale.currentAmount * (100 - ownerPercentage)) / 100;
        IERC20(base).transfer(msg.sender, withdrawAmount); //todo: check
        emit WithdrawProceeds(_saleId, withdrawAmount, msg.sender);
    }

    //withdraw tokens for owner after sale is complete
    function withdrawOwner(uint256 _saleId) public onlyOwner {
        SaleInfo storage sale = sales[_saleId];
        require(sale.state == 4, "Sale is not complete");
        require(!sale.ownerWithdrawn, "Already withdrawn"); //prevent replay
        sale.ownerWithdrawn = true;
        uint256 withdrawAmount = (sale.currentAmount * ownerPercentage) / 100;
        IERC20(base).transfer(msg.sender, withdrawAmount); //todo: check
        emit WithdrawProceeds(_saleId, withdrawAmount, msg.sender);
    }

    //======================================== FAILED SALE ACTIONS ========================================

    //cancel the sale
    function cancelSale(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        uint256 checkTime = block.number - sale.lastDepositBlock;
        require(sale.expirationBlocks > checkTime, "Enough time has not elapsed since last deposit");
        sale.state = 2;
        emit SaleCancelled(_saleId);
    }

    //withdraw NFT if sale has been cancelled
    function withdrawNFT(uint256 _saleId) public {
        SaleInfo storage sale = sales[_saleId];
        require(msg.sender == sale.sellerAddress, "Only the seller can withdraw");
        require(sale.state == 2, "Sale has not been cancelled");
        sale.state = 3;
        emit WithdrawNFT(_saleId, msg.sender);
        IERC721(sale.nftContract).transferFrom(address(this), msg.sender, sale.tokenId);
    }

    //withdraw deposit if sale has been cancelled
    function withdrawDeposit(uint256 _saleId, uint256 _index) public {
        SaleInfo storage sale = sales[_saleId];
        require(sale.depositors[_index] == msg.sender, "Only depositor can withdraw");
        require(!sale.depositsWithdrawn[_index], "Deposit already withdrawn"); //prevent replays
        require(sale.state == 2 || sale.state == 3, "Sale has not been cancelled");
        IERC20(base).transfer(msg.sender, sale.depositAmount);
        emit WithdrawDeposit(_saleId, msg.sender);
    }

    //withdraw LINK

    //======================================== READERS ========================================

    //get current sale id
    function getCurrentSaleId() public view returns (uint256) {
        return currentSaleId;
    }

    //get sale
    function getSale(uint256 _saleId) public view returns (SaleInfo memory) {
        if(_saleId > currentSaleId || _saleId == 0) {
            revert("Not found");
        }
        return sales[_saleId];
    }

    function getSaleState(uint256 _saleId) public view returns (uint8) {
        if(_saleId > currentSaleId || _saleId == 0) {
            revert("Not found");
        }
        return sales[_saleId].state;
    }

    // //view total amount deposited in a sale
    // function getAmount(uint256 _saleId) public view returns (uint256) {
    //     return sales[_saleId].currentAmount;
    // }

    //inherited, use to set new contract owner
    //function transferOwnership(address _newOwner) public onlyOwner

    //change owner percentage
    function setOwnerPercentage(uint8 _newPercentage) public onlyOwner {
        require(_newPercentage < 10, "Bad percentage");
        ownerPercentage = _newPercentage;
    }
}