import "./message.tact";
import "./jetton.tact";
const minTonsForStorage: Int = ton("0.019");
const gasConsumption: Int = ton("0.013");

message JettonInitialize {
    royalty_params: RoyaltyParams;
}

message ReportTotalSupply {
    query_id: Int as uint64;
    item_index: Int as uint32;
}

message NftBurnRequest_and_Mint {
    query_id: Int as uint64;
    item_index: Int as uint32;
    original_sender: Address;
    new_owner: Address;
}

/*
    - 以 Jetton Root 為主體; NFT Collection 的功能遷移在這邊。 NFT Item 所綁定的持有訊息、也會連帶傳送到對應的 Jetton Wallet
    - 因為 Jetton Wallet 本質上是綁定 Owner 訊息的一個合約（1:1)
*/ 

contract Register with Jetton  {
    total_supply: Int as coins;
    owner: Address;
    content: Cell;
    mintable: Bool;

    max_supply: Int as coins; // Extract parameter we set here. The Jetton Standards doesn't have this parameter.
    item_index: Int as uint32 = 0;

    init(owner: Address, content: Cell, max_supply: Int) {
        self.total_supply = 0;
        self.owner = owner;
        self.mintable = true;
        self.content = content;
        self.max_supply = max_supply;
    }

    receive(msg: JettonInitialize) {
        require(sender() == self.owner, "only owner can deploy new Jetton & NFT 404");
        let initCode: StateInit = initOf NftCollection(myAddress());
        send(SendParameters{
                to: contractAddress(initCode), 
                value: 0, 
                bounce: false,
                mode: SendRemainingValue,
                code: initCode.code,
                data: initCode.data,
                body: NftCollectionInitialize { // 0x4ccea562
                    query_id: 0,
                    royalty_params: msg.royalty_params,
                    collection_content: self.content
                }.toCell()
            });
    }

    receive("Mint") { // Public Minting Jetton
        let ctx: Context = context();
        require(context().value >= ton("1"), "Not enough TON for Tx");
        require(self.mintable, "Not mintable");
        require(self.total_supply + BUFFER_JETTON_AMOUNT <= self.max_supply, "Max supply exceeded");

        let msgValue: Int = self.msgValue(ctx.value); // Send the remaining gas after keep some storage Fee 
        self.mintNFT(ctx.sender, self.owner);
        self.mintJetton(ctx.sender, BUFFER_JETTON_AMOUNT, self.owner, msgValue - ton("0.3"));  // 1 TON => 150 Token 
    }

    fun mintNFT(sender: Address, response_destination: Address?) {
        let nft_init: StateInit = initOf NftItem(self.get_collection_address(), self.item_index, myAddress());
        self.item_index = self.item_index + 1;
        send(SendParameters{
            to: contractAddress(nft_init), // NFT Item Address
            value: ton("0.15"), 
            bounce: false,
            mode: SendPayGasSeparately,
            body: NftTransfer {
                query_id: 0,
                new_owner: sender,
                response_destination: response_destination,
                custom_payload: emptyCell(),
                forward_amount: 0,
                forward_payload: beginCell().endCell().asSlice()
            }.toCell(),
            code: nft_init.code,
            data: nft_init.data
        });   
    }

    fun mintJetton(to: Address, amount: Int, response_destination: Address, msgValue: Int) {
        require(self.mintable, "Can't Mint Anymore");
        self.total_supply = self.total_supply + amount; // Update total supply
        let winit: StateInit = self.getJettonWalletInit(to);
        send(SendParameters{
            to: contractAddress(winit), // Create To New Owner's JettonWallet 
            value: msgValue, 
            bounce: true,
            mode: SendPayGasSeparately,
            body: TokenTransferInternal{  // 0x178d4519
                query_id: 0,
                transferJettonAmount: amount,
                from: myAddress(),
                response_destination: response_destination,
                forward_ton_amount: 0,
                forward_payload: beginCell().storeUint(self.item_index, 32).endCell().asSlice() // passing to the JettoWallet that "which" NFT Item this owner has.
            }.toCell(),
            code: winit.code,
            data: winit.data
        });
    }

    receive(msg: NftBurnRequest_and_Mint) { // 0xb609b568
        require(sender() == self.get_wallet_address(msg.original_sender), "not from correct jetton wallet"); // Check whether the sender is truely one of the Jetton Wallet
        self.mintNFT(msg.new_owner, msg.original_sender); // MintNFT cost 0.15 TON

        // Send the NFT to the null address
        let restGas: Int = self.msgValue(context().value - ton("0.15"));
        self.burnNFT(msg.item_index, restGas, msg.original_sender);
    }

    fun burnNFT(item_index: Int, restGas: Int, original_sender: Address) {
        send(SendParameters{
            to: self.get_nft_item_address(item_index),
            value: restGas,
            mode: SendPayGasSeparately,
            bounce: false,
            body: NftTransfer {
                query_id: 0,
                new_owner: newAddress(0, 0),
                response_destination: original_sender, // pay back Gas Fee
                custom_payload: emptyCell(),
                forward_amount: 0,
                forward_payload: emptySlice()
            }.toCell()
        });
    }

    fun msgValue(msgValue: Int ): Int { 
        let tonBalanceBeforeMsg: Int = myBalance() - msgValue;
        let storageFee: Int = minTonsForStorage - min(tonBalanceBeforeMsg, minTonsForStorage);
        return msgValue - (storageFee + gasConsumption);
    }

    receive("SyncTheIndex"){
        send(SendParameters{
            to: self.get_collection_address(),
            value: 0,
            mode: SendRemainingValue, 
            bounce: false,
            body: ReportTotalSupply {
                query_id: 0,
                item_index: self.item_index
            }.toCell()
        }); 
    }

    receive("Owner: MintClose") {
        let ctx: Context = context();
        require(ctx.sender == self.owner, "Not owner");
        self.mintable = false;
    }

    get fun get_nft_item_address(item_index: Int): Address {
        let nft_init: StateInit = initOf NftItem(
            self.get_collection_address(), item_index, myAddress());
        return contractAddress(nft_init);
    }

    get fun get_next_nft_item_index(): Int {
        return self.item_index;
    }
    
    get fun get_collection_address(): Address {
        let initCode: StateInit = initOf NftCollection(myAddress());
        return contractAddress(initCode);
    }
}

// ================== NFT Collection ================== //
message NftCollectionInitialize {
    query_id: Int as uint64;
    royalty_params: RoyaltyParams;
    collection_content: Cell;
}

contract NftCollection {
    owner_address: Address;
    next_item_index: Int as uint32 = 0;
    collection_content: Cell?;   
    royalty_params: RoyaltyParams?;        

    init(owner_address: Address) {
        require(sender() == owner_address, "not from the owner address");
        self.owner_address = owner_address;
    }

    receive(msg: ReportTotalSupply) {
        require(sender() == self.owner_address, "not from the owner address");
        self.next_item_index = msg.item_index;
        self.reply("Success".asComment()); // TODO:
    }

    receive(msg: NftCollectionInitialize) {
        require(sender() == self.owner_address, "not from the owner address");
        self.royalty_params = msg.royalty_params;
        self.collection_content = msg.collection_content;
        send(SendParameters{to: sender(), value: 0, mode: 64, bounce: false, body: "1234".asComment() }); // TODO:
    }

    receive(msg: GetRoyaltyParams) {   
        let ctx: Context = context(); // get sender Info
        send(SendParameters{
            to: ctx.sender,
            value: 0,
            mode: 64, 
            bounce: false,
            body: ReportRoyaltyParams {
                query_id: msg.query_id,
                numerator:  (self.royalty_params!!).numerator,
                denominator: (self.royalty_params!!).denominator,
                destination: self.owner_address
            }.toCell()
        });        
    }

    // ------------------ Get Function  ------------------ //
    get fun get_collection_data(): CollectionData {     
        let b: StringBuilder = beginString();
        let collectionDataString: String = (self.collection_content!!).asSlice().asString();
        b.append(collectionDataString);
        b.append("meta.json"); // You can changed this your self.
        return CollectionData{
            next_item_index: self.next_item_index, 
            collection_content: b.toCell(), 
            owner_address: self.owner_address
        };
    }

    get fun get_nft_address_by_index(item_index: Int): Address?{      
        let initCode: StateInit = self.getNftItemInit(item_index);
        return contractAddress(initCode);
    }

    get fun getNftItemInit(item_index: Int): StateInit {
        return initOf NftItem(myAddress(), item_index, self.owner_address);
    }
    
    get fun get_nft_content(index: Int, individual_content: Cell): Cell { 
        let b: StringBuilder = beginString();
        let ic: String = individual_content.asSlice().asString();
        b.append(ic);
        return b.toCell();
    }

    get fun royalty_params(): RoyaltyParams {
        return self.royalty_params!!;
    }
}

/// ------------- NFT Collection -------------
// const minTonsForStorage: Int = ton("0.03");
// const gasConsumption: Int = ton("0.03");
contract NftItem {
    is_initialized: Bool;
    item_index: Int as uint32; 
    collection_address: Address;
    owner: Address?;
    individual_content: Cell?;

    jetton_root: Address;

    init(collection_address: Address, item_index: Int, jetton_root: Address) {
        require(sender() == jetton_root || sender() == collection_address, "not from collection");
        self.collection_address = collection_address;
        self.item_index = item_index;
        self.is_initialized = false;
        self.jetton_root = jetton_root;
    }

    receive(msg: NftTransfer) { // 0x5fcc3d14
        let ctx: Context = context();
        require(context().value >= ton("0.1"), "not enough TonCoin for Tx");

        let msgValue: Int = ctx.value; // Check the gasCost for storage
        let tonBalanceBeforeMsg: Int = myBalance() - msgValue;
        let storageFee: Int = minTonsForStorage - min(tonBalanceBeforeMsg, minTonsForStorage);
        msgValue = msgValue - (storageFee + gasConsumption);
        
        if (self.is_initialized == false) {  // Initial Transfer, aka the "Minting" of the NFT
            require(ctx.sender == self.jetton_root || ctx.sender == self.collection_address, "initialized tx need from collection");
            self.is_initialized = true;
            self.owner = msg.new_owner;
            send(SendParameters{
                to: self.owner!!,
                value: 0,
                mode: SendRemainingValue,
                body: Excesses { query_id: msg.query_id }.toCell()
            });
        } else {
            require(ctx.sender == self.owner || ctx.sender == self.jetton_root, "not from owner");
            // ----- 特殊案例：Send the Burn Information to the Jetton Wallet ------- //
            // 1/ 正常的 NFT 轉移: 新接收者不是空地址、要燒 JettonToken  
            // 2/ From Jetton Root: 代表是 NFT 轉移給新的接收者, 要鑄造新的 NFT 給新的 JettonToken Receiver
            if (msg.new_owner != newAddress(0, 0)) {
                send(SendParameters{
                    to: self.get_wallet_address(self.owner!!),
                    value: ton("0.5"),
                    mode: SendPayGasSeparately,
                    body: JettonTokenTransfer { // 0xf8a7ea5
                        query_id: msg.query_id,
                        transferJettonAmount: BUFFER_JETTON_AMOUNT,
                        sender: self.owner!!,
                        response_destination: msg.new_owner,
                        custom_payload: emptyCell(),
                        forward_ton_amount: 1,
                        forward_payload: beginCell().storeUint(self.item_index, 32).endCell().asSlice()
                    }.toCell()
                });
            }
            
            // ---------------------------------------------------------- //
            self.owner = msg.new_owner;  // change current owner to the new_owner
            if (msg.forward_amount > 0) {
                send(SendParameters{
                    to: msg.new_owner,
                    value: msg.forward_amount,
                    mode: SendPayGasSeparately, 
                    bounce: true,
                    body: OwnershipAssigned{
                        query_id: msg.query_id,
                        prev_owner: ctx.sender,
                        forward_payload: msg.forward_payload
                    }.toCell()
                }); 
            }
            msgValue = msgValue - ctx.readForwardFee(); 
            if (msg.response_destination != null) { 
                send(SendParameters{ 
                    to: msg.response_destination!!,
                    value: msgValue - msg.forward_amount,
                    mode: SendPayGasSeparately,
                    bounce: true,
                    body: Excesses { query_id: msg.query_id }.toCell()
                });
            } 
        }
    }
    
    receive(msg: GetStaticData){ 
        let ctx: Context = context();
        send(SendParameters {
            to: ctx.sender,
            value: 0,
            mode: 64,  // (return msg amount except gas fees) 
            bounce: true,
            body: ReportStaticData{
                query_id: msg.query_id,
                index_id: self.item_index,
                collection: self.collection_address
            }.toCell()
        });
    }

    // --------- Get Function  --------- //
    get fun get_nft_data(): GetNftData {
        let b: StringBuilder = beginString();
        let collectionData: String = (self.individual_content!!).asSlice().asString();
        b.append(collectionData);
        b.append(self.item_index.toString());
        b.append(".json");

        return GetNftData { is_initialized: self.is_initialized, index: self.item_index, collection_address: self.collection_address, owner_address: self.owner!!, individual_content: b.toCell() };
    }

    get fun get_owner(): Address {
        return self.owner!!;
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf JettonDefaultWallet(owner, self.jetton_root));
    }
}
