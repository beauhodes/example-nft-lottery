const { ethers } = require('hardhat');
const { expect } = require('chai');
const web3 = require('web3');
const { BigNumber } = require("ethers");

const zero_addr = "0x0000000000000000000000000000000000000000"

function getBigNumber(amount, decimals = 18) {
    return BigNumber.from(amount).mul(BigNumber.from(10).pow(decimals))
}

describe("Lottery", function () {

    before(async function () {
        this.signers = await ethers.getSigners()
        this.owner = this.signers[0]
        this.alice = this.signers[1]
        this.bob = this.signers[2]
        this.carol = this.signers[3]

        this.LotteryContract = await ethers.getContractFactory("Lottery")
        this.Stablecoin = await ethers.getContractFactory("MockUSDC")
        this.BoredApeNFT = await ethers.getContractFactory("MockBAYC")
        this.LinkToken = await ethers.getContractFactory("LinkToken")
        this.VRFCoord = await ethers.getContractFactory("VRFCoordinatorMock") //rinkeby: 0xb3dCcb4Cf7a26f6cf6B120Cf5A73875B7BBc655B

        this.keyHash = "0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4" //rinkeby: 0x2ed0feb3e7fd2022120aa84fab1945545a9f2ffc9076fd6156fa96eaff4c1311
    })

    beforeEach(async function () { //deploy all mocks
        this.currency = await this.Stablecoin.deploy() //gives owner 10 USDC
        await this.currency.deployed()
        this.nft = await this.BoredApeNFT.deploy() //gives owner tokenId 0
        await this.nft.deployed()
        this.linkToken = await this.LinkToken.deploy() //gives owner 10 LINK
        await this.linkToken.deployed()
        this.vrfCoordinator = await this.VRFCoord.deploy(this.linkToken.address)
        await this.vrfCoordinator.deployed()
    })

    it("base token setup: owner should have 10 USDC, alice should have 0, and USDC should have 18 decimals", async function () {
        expect(await this.currency.decimals()).to.equal(18)
        expect(await this.currency.balanceOf(this.owner.address)).to.equal(getBigNumber(10))
        expect(await this.currency.balanceOf(this.alice.address)).to.equal(0)
    })

    it("NFT setup: owner should own the NFT with tokenId 0", async function () {
        expect(await this.nft.ownerOf(0)).to.equal(this.owner.address)
    })

    it("NFT setup: should be able to mint alice an NFT", async function () {
        await this.nft.connect(this.alice).simulateAirdrop(1)
        expect(await this.nft.ownerOf(1)).to.equal(this.alice.address)
    })

    it("lottery should deploy correctly and be owned by owner", async function () {
        this.lottery = await this.LotteryContract.deploy(this.currency.address, this.vrfCoordinator.address, this.linkToken.address, this.keyHash)
        expect(await this.lottery.owner()).to.equal(this.owner.address)
    })

    context("With Lottery already deployed", function () {
        beforeEach(async function () {
            this.lottery = await this.LotteryContract.deploy(this.currency.address, this.vrfCoordinator.address, this.linkToken.address, this.keyHash)
        })

        it("ownership can only be changed by owner", async function () {
            await expect(this.lottery.connect(this.alice).transferOwnership(this.bob.address, { from: this.alice.address }))
                .to.be.revertedWith("Ownable: caller is not the owner")
        })

        it("should be able to transfer in an NFT", async function () {
            //mint alice an NFT
            await this.nft.connect(this.alice).simulateAirdrop(1)
            expect(await this.nft.ownerOf(1)).to.equal(this.alice.address)

            //ensure sale id is 0
            expect(await this.lottery.getCurrentSaleId()).to.equal(0)
            await expect(this.lottery.getSale(1)).to.be.revertedWith("Not found")

            //transfer NFT from alice to lottery contract. overloaded function means call syntax changes
            expect(await this.nft.connect(this.alice)["safeTransferFrom(address,address,uint256)"](this.alice.address, this.lottery.address, 1))
                .to.emit(this.lottery, "NFTDeposit")
                .withArgs(1, this.nft.address, this.alice.address, 1)

            //ensure sale id is now 1
            expect(await this.lottery.getCurrentSaleId()).to.equal(1)
        })

    })

    context("With Lottery already deployed, NFT minted, and NFT deposited", function () {
        beforeEach(async function () {
            this.lottery = await this.LotteryContract.deploy(this.currency.address, this.vrfCoordinator.address, this.linkToken.address, this.keyHash)
            await this.nft.connect(this.alice).simulateAirdrop(1)
            await this.nft.connect(this.alice)["safeTransferFrom(address,address,uint256)"](this.alice.address, this.lottery.address, 1)
        })

        it("ensure sale info is correct", async function () {
            const newSale = await this.lottery.getSale(1)
            /*
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
            */
            expect(newSale[0]).to.equal(this.nft.address)
            expect(newSale[1]).to.equal(1)
            expect(newSale[2]).to.equal(this.alice.address)
            expect(newSale[3]).to.equal(0)
            expect(newSale[4]).to.equal(0)
            expect(newSale[5]).to.equal(0)
            expect(newSale[6]).to.equal(false)
            expect(newSale[7]).to.equal(false)
            expect(newSale[8]).to.equal(0)
            expect(newSale[9]).to.equal(zero_addr)
            expect(newSale[10]).to.equal(0)
            expect(newSale[11]).to.equal(0)
            expect(Object.values(newSale[12]).length).to.equal(0)
            expect(Object.values(newSale[13]).length).to.equal(0)
        })

        it("seller should be able to withdraw before beginSale", async function () {
            expect(await this.lottery.getSaleState(1)).to.equal(0)
            expect(await this.lottery.connect(this.alice).withdrawNFTPresale(1))
                .to.emit(this.lottery, "WithdrawNFT")
                .withArgs(1, this.alice.address)

            expect(await this.lottery.getSaleState(1)).to.equal(4)
        })

        it("non-seller should not be able to beginSale", async function () {
            await expect(this.lottery.connect(this.bob).beginSale(1, getBigNumber(100), getBigNumber(1050), 5760))
                .to.be.revertedWith("Seller must begin the sale")
        })

        it("initialize sale and make sure values are correct", async function () {
            //begin sale with 100 per deposit, 1050 max amount, 5760 expiration blocks (1 day)
            expect(await this.lottery.connect(this.alice).beginSale(1, getBigNumber(100), getBigNumber(1050), 5760))
                .to.emit(this.lottery, "SaleStarted")
                .withArgs(1)
            const newSale = await this.lottery.getSale(1)
            expect(newSale[0]).to.equal(this.nft.address)
            expect(newSale[1]).to.equal("1")
            expect(newSale[2]).to.equal(this.alice.address)
            expect(newSale[3]).to.equal(getBigNumber(100))
            expect(newSale[4]).to.equal(0)
            expect(newSale[5]).to.equal(getBigNumber(1050))
            expect(newSale[6]).to.equal(false)
            expect(newSale[7]).to.equal(false)
            expect(newSale[8]).to.equal(1)
            expect(newSale[9]).to.equal(zero_addr)
            expect(newSale[10]).to.equal(5760)
            const block = await ethers.provider.getBlock()
            expect(newSale[11]).to.equal(block.number)
            expect(Object.values(newSale[12]).length).to.equal(0)
            expect(Object.values(newSale[13]).length).to.equal(0)
        })

    })

    context("With Lottery already deployed, NFT minted, NFT deposited, and sale started", function () {
        beforeEach(async function () {
            this.lottery = await this.LotteryContract.deploy(this.currency.address, this.vrfCoordinator.address, this.linkToken.address, this.keyHash)
            await this.nft.connect(this.alice).simulateAirdrop(1)
            await this.nft.connect(this.alice)["safeTransferFrom(address,address,uint256)"](this.alice.address, this.lottery.address, 1)
            await this.lottery.connect(this.alice).beginSale(1, getBigNumber(100), getBigNumber(1050), 5760)
        })

        it("should fail to deposit without enough USDC", async function () {
            await this.currency.connect(this.bob).simulateAirdrop(getBigNumber(10))
            await this.currency.connect(this.bob).approve(this.lottery.address, getBigNumber(100))

            await expect(this.lottery.connect(this.bob).deposit(1))
                .to.be.revertedWith("ERC20: transfer amount exceeds balance")
        })

        it("should be able to deposit with enough USDC", async function () {
            await this.currency.connect(this.bob).simulateAirdrop(getBigNumber(100))
            await this.currency.connect(this.bob).approve(this.lottery.address, getBigNumber(100))
            expect(await this.currency.balanceOf(this.lottery.address)).to.equal(0)
            
            expect(await this.lottery.connect(this.bob).deposit(1))
                .to.emit(this.lottery, "Deposit")
                .withArgs(1, this.bob.address)
            
            expect(await this.currency.balanceOf(this.lottery.address)).to.equal(getBigNumber(100))
            const saleInfo = await this.lottery.getSale(1)
            expect(Object.values(saleInfo[12]).length).to.equal(1)
            expect(Object.values(saleInfo[13]).length).to.equal(1)
            expect(Object.values(saleInfo[12])[0]).to.equal(this.bob.address)
            expect(Object.values(saleInfo[13])[0]).to.equal(false)
        })

        it("should be able to deposit up to the maximum allowed for the sale", async function () {
            await this.currency.connect(this.bob).simulateAirdrop(getBigNumber(600))
            await this.currency.connect(this.bob).approve(this.lottery.address, getBigNumber(600))
            await this.currency.connect(this.carol).simulateAirdrop(getBigNumber(500))
            await this.currency.connect(this.carol).approve(this.lottery.address, getBigNumber(500))
            expect(await this.currency.balanceOf(this.lottery.address)).to.equal(0)

            //max deposit amount is 1050, but each deposit is 100
            //so, we should be able to hit 1100 (11 deposits) but not any more
            //we'll switch off between bob and carol
            for (let i = 0; i < 11; i++) {
                if(i % 2 == 0) {
                    await this.lottery.connect(this.bob).deposit(1)
                }
                else {
                    await this.lottery.connect(this.carol).deposit(1)
                }
              }
            
            expect(await this.currency.balanceOf(this.lottery.address)).to.equal(getBigNumber(1100))
            const saleInfo = await this.lottery.getSale(1)
            expect(Object.values(saleInfo[12]).length).to.equal(11)
            expect(Object.values(saleInfo[13]).length).to.equal(11)
            expect(Object.values(saleInfo[12])[1]).to.equal(this.carol.address)
            expect(Object.values(saleInfo[13])[1]).to.equal(false)
        })

        it("should fail if an extra deposit comes in", async function () {
            await this.currency.connect(this.bob).simulateAirdrop(getBigNumber(700))
            await this.currency.connect(this.bob).approve(this.lottery.address, getBigNumber(700))
            await this.currency.connect(this.carol).simulateAirdrop(getBigNumber(500))
            await this.currency.connect(this.carol).approve(this.lottery.address, getBigNumber(500))
            expect(await this.currency.balanceOf(this.lottery.address)).to.equal(0)

            //max deposit amount is 1050, but each deposit is 100
            //so, we should be able to hit 1100 (11 deposits) but not any more
            //we'll switch off between bob and carol
            for (let i = 0; i < 11; i++) {
                if(i % 2 == 0) {
                    await this.lottery.connect(this.bob).deposit(1)
                }
                else {
                    await this.lottery.connect(this.carol).deposit(1)
                }
              }
            
            await expect(this.lottery.connect(this.bob).deposit(1))
              .to.be.revertedWith("Sale is already full")
        })

    })

    context("With Lottery already deployed, NFT minted, NFT deposited, sale started, and sale full", function () {
        beforeEach(async function () {
            this.lottery = await this.LotteryContract.deploy(this.currency.address, this.vrfCoordinator.address, this.linkToken.address, this.keyHash)
            await this.nft.connect(this.alice).simulateAirdrop(1)
            await this.nft.connect(this.alice)["safeTransferFrom(address,address,uint256)"](this.alice.address, this.lottery.address, 1)
            await this.lottery.connect(this.alice).beginSale(1, getBigNumber(100), getBigNumber(1050), 5760)

            await this.currency.connect(this.bob).simulateAirdrop(getBigNumber(600))
            await this.currency.connect(this.bob).approve(this.lottery.address, getBigNumber(600))
            await this.currency.connect(this.carol).simulateAirdrop(getBigNumber(500))
            await this.currency.connect(this.carol).approve(this.lottery.address, getBigNumber(500))
            for (let i = 0; i < 11; i++) {
                if(i % 2 == 0) {
                    await this.lottery.connect(this.bob).deposit(1)
                }
                else {
                    await this.lottery.connect(this.carol).deposit(1)
                }
            }
        })

        it("should be able to determine a winner", async function () {
            //transfer LINK to contract to pay fee
            await this.linkToken.connect(this.owner).transfer(this.lottery.address, getBigNumber(1))

            //make the request and grab the id
            const request = await this.lottery.connect(this.alice).completeSale(1)
            const requestReceipt = await request.wait(1)
            const requestId = await this.lottery.getLastRequestId()

            //fulfill the request
            const randomVal = 892
            const callback = await this.vrfCoordinator.callBackWithRandomness(requestId, randomVal, this.lottery.address)

            //ensure result is correct
            const saleInfoPost = await this.lottery.getSale(1)
            expect(saleInfoPost[8]).to.equal(4)
            if(randomVal % 2) {
                expect(saleInfoPost[9]).to.equal(this.bob.address)
            }
            else {
                expect(saleInfoPost[9]).to.equal(this.carol.address)
            }
        })
    })
})