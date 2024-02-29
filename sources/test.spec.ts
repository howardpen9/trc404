import { toNano, beginCell, fromNano } from "@ton/core";
import {
    Blockchain,
    SandboxContract,
    TreasuryContract,
    printTransactionFees,
    prettyLogTransactions,
} from "@ton/sandbox";
import "@ton/test-utils";
import { printSeparator } from "./utils/print";

// -------
import { buildOnchainMetadata } from "./utils/buildData";
import { Register } from "./output/sample_Register";
import { JettonDefaultWallet, JettonTokenTransfer } from "./output/sample_JettonDefaultWallet";

import { NftCollection, RoyaltyParams } from "./output/sample_NftCollection";
import { NftItem } from "./output/sample_NftItem";

const jettonParams = {
    name: "Token Name is here",
    description: "This is description of Test Jetton Token in Tact-lang",
    symbol: "TNTT",
    image: "https://avatars.githubusercontent.com/u/104382459?s=200&v=4",
    network: "brc20",
    tick_ton20: "nono.com",
};
let tokenContent = buildOnchainMetadata(jettonParams);

describe("contract", () => {
    const OFFCHAIN_CONTENT_PREFIX = 0x01;
    const string_first = "https://s.getgems.io/nft-staging/c/628f6ab8077060a7a8d52d63/";
    let newContent = beginCell().storeInt(OFFCHAIN_CONTENT_PREFIX, 8).storeStringRefTail(string_first).endCell();

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let player: SandboxContract<TreasuryContract>;

    let jetton: SandboxContract<Register>;
    let jettonWallet_1: SandboxContract<JettonDefaultWallet>;
    let jettonWallet_2: SandboxContract<JettonDefaultWallet>;

    let collection: SandboxContract<NftCollection>;
    let nft_item1: SandboxContract<NftItem>;

    beforeAll(async () => {
        blockchain = await Blockchain.create();
        deployer = await blockchain.treasury("deployer");
        player = await blockchain.treasury("player");

        let royaltiesParam: RoyaltyParams = {
            $$type: "RoyaltyParams",
            numerator: 350n, // 350n = 35%
            denominator: 1000n,
            destination: deployer.address,
        };

        let max_supply = toNano("1000000000");

        jetton = blockchain.openContract(await Register.fromInit(deployer.address, tokenContent, max_supply));
        jettonWallet_1 = blockchain.openContract(await JettonDefaultWallet.fromInit(deployer.address, jetton.address));
        jettonWallet_2 = blockchain.openContract(await JettonDefaultWallet.fromInit(player.address, jetton.address));

        collection = blockchain.openContract(await NftCollection.fromInit(jetton.address));
        nft_item1 = blockchain.openContract(await NftItem.fromInit(collection.address, 0n, jetton.address));

        const deploy_result = await jetton.send(
            deployer.getSender(),
            { value: toNano(1) },
            {
                $$type: "JettonInitialize",
                royalty_params: royaltiesParam,
            }
        );
        expect(deploy_result.transactions).toHaveTransaction({
            from: deployer.address,
            to: jetton.address,
            deploy: true,
            success: true,
        });
        // printTransactionFees(deploy_result.transactions);
        // prettyLogTransactions(deploy_result.transactions);
    });

    it("Test", async () => {
        console.log("JettonRoot Address: " + jetton.address);
        console.log("Collection Address: " + collection.address);
        console.log("JettonWallet_1: " + (await jettonWallet_1.address));
    });

    it("Mint Jetton", async () => {
        const mintingTx = await jetton.send(deployer.getSender(), { value: toNano(2.1) }, "Mint"); // Send Mint Transaction
        expect(mintingTx.transactions).toHaveTransaction({
            from: deployer.address,
            to: jetton.address,
            success: true,
        });
        // printTransactionFees(mintingTx.transactions);
        // prettyLogTransactions(mintingTx.transactions);

        let total_supply = (await jetton.getGetJettonData()).total_supply;
        expect(total_supply).toBeGreaterThan(0n);

        // 確認 NFT Item 地址是否正確
        let nft_item_addr = await jetton.getGetNftItemAddress(0n);
        let nft_item_get = await collection.getGetNftAddressByIndex(0n);
        expect(nft_item_get).toEqualAddress(nft_item_addr);

        let ownerNft = await nft_item1.getGetOwner();
        expect(ownerNft).toEqualAddress(deployer.address);

        // check JettonWallet 是否有安排上
        let id = await jettonWallet_1.getGetSeriesId();
        expect(id).toBeGreaterThan(0n);
    });

    it("JettonWallet: Basic Transfer", async () => {
        let transferJettonAmt = toNano("0.1");
        let transferParam: JettonTokenTransfer = {
            $$type: "JettonTokenTransfer", // 0xf8a7ea5
            query_id: 0n,
            transferJettonAmount: transferJettonAmt,
            sender: deployer.address,
            response_destination: player.address,
            custom_payload: null,
            forward_ton_amount: toNano("0.0012"),
            forward_payload: beginCell().endCell(),
        };
        const transfer_result = await jettonWallet_1.send(deployer.getSender(), { value: toNano(1) }, transferParam); // Send Mint Transaction
        expect(transfer_result.transactions).toHaveTransaction({
            from: deployer.address,
            to: jettonWallet_1.address,
            success: true,
        });

        // printTransactionFees(transfer_result.transactions);
        // prettyLogTransactions(transfer_result.transactions);

        let playerBalance = (await jettonWallet_2.getGetWalletData()).balance;
        expect(playerBalance).toEqual(transferJettonAmt);
    });

    it("JettonWallet: Mint, then transfer more than the breakpoint", async () => {
        let next_item_id = await jetton.getGetNextNftItemIndex();
        await jetton.send(deployer.getSender(), { value: toNano(1) }, "Mint");
        console.log(
            "✅✅✅ ------ Check: Mint then Transfer Jetton Token(JettonTransfer + NFT Burn / Minting New NFT) ------"
        );

        let transferJettonAmt = toNano("10");
        let transferParam: JettonTokenTransfer = {
            $$type: "JettonTokenTransfer", // 0xf8a7ea5
            query_id: 0n,
            transferJettonAmount: transferJettonAmt,
            sender: deployer.address,
            response_destination: player.address,
            custom_payload: null,
            forward_ton_amount: toNano("0.0012"),
            forward_payload: beginCell().endCell(),
        };
        const transfer_result = await jettonWallet_1.send(deployer.getSender(), { value: toNano(1) }, transferParam); // Send Mint Transaction
        printTransactionFees(transfer_result.transactions);
        prettyLogTransactions(transfer_result.transactions);
        console.log("------------------------------------------------------------------------------------------------");

        // check NFT Item 總數
        let next_item_id_Later = await jetton.getGetNextNftItemIndex();

        expect(next_item_id_Later).toBeGreaterThan(next_item_id);
        console.log("Current NFT Next Item ID: " + next_item_id_Later);
    });

    it("NFT Item: Transfer NFT then burn the JettonToken", async () => {
        await jetton.send(deployer.getSender(), { value: toNano(2.1) }, "Mint");
        await jetton.send(deployer.getSender(), { value: toNano(2.1) }, "Mint");

        console.log("===== ✅ Transfer NFT, will burn the JettonToken =====");
        let ownerOfNft = await nft_item1.getGetOwner();
        expect(ownerOfNft).toEqualAddress(deployer.address);

        let getJettonWalletAddr = await nft_item1.getGetWalletAddress(deployer.address);
        expect(getJettonWalletAddr).toEqualAddress(jettonWallet_1.address);

        let getNftItemListFromJetton = await jettonWallet_1.getGetNftItemRecord();
        // Iterate over each entry in the dictionary
        for (const [key, value] of Object.entries(getNftItemListFromJetton)) {
            if (value instanceof Map) {
                // Explicitly type 'entries' as an array of strings
                const entries: string[] = [];

                value.forEach((mapValue, mapKey) => {
                    entries.push(`${mapKey} => ${mapValue}`);
                });

                console.log(`Key: ${key} { ${entries.join(", ")} }`);
            }
        }

        // Check the latest Series ID in JettonWallet (before transfer)
        let seriesId = await jettonWallet_1.getGetSeriesId();
        console.log("Current Series ID: " + seriesId);

        let previousBalanceInJetton = (await jettonWallet_1.getGetWalletData()).balance;

        let getNftItemAddress_0 = await jettonWallet_1.getGetNftItemAddressByItemIndex(1n);
        let nft_item_1 = blockchain.openContract(await NftItem.fromAddress(getNftItemAddress_0!!));
        let transfer_result = await nft_item_1.send(
            deployer.getSender(),
            { value: toNano(1) },
            {
                $$type: "NftTransfer",
                query_id: 123n,
                new_owner: player.address,
                response_destination: null,
                custom_payload: null,
                forward_amount: 0n,
                forward_payload: beginCell().endCell(),
            }
        );
        printTransactionFees(transfer_result.transactions);
        prettyLogTransactions(transfer_result.transactions);

        let laterBalanceInJetton = (await jettonWallet_1.getGetWalletData()).balance;
        expect(laterBalanceInJetton).toBeLessThan(previousBalanceInJetton);
    });
});
