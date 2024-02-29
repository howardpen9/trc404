import "@stdlib/ownable";
import "./jetton_messages";

const BUFFER_JETTON_AMOUNT: Int = ton("10");

// ============================================================================================================ //
@interface("org.ton.jetton.master")
trait Jetton with Ownable {

    total_supply: Int; 
    mintable: Bool;
    owner: Address;
    content: Cell;
    
    receive(msg: TokenUpdateContent) {
        self.requireOwner();                // Allow changing content only by owner
        self.content = msg.content;         // Update content
    }

    receive(msg: TokenBurnNotification) {
        self.requireSenderAsWalletOwner(msg.response_destination!!);       // Check wallet
        self.total_supply = self.total_supply - msg.amount; // Update supply
        if (msg.response_destination != null) { // Cashback
            send(SendParameters{
                to: msg.response_destination!!, 
                value: 0,
                bounce: false,
                mode: SendRemainingValue,
                body: TokenExcesses{ query_id: msg.query_id }.toCell()
            });
        }
    }

    // https://github.com/ton-blockchain/TEPs/blob/master/text/0089-jetton-wallet-discovery.md
    receive(msg: ProvideWalletAddress) { // 0x2c76b973
        require(context().value >= ton("0.0061"), "Insufficient gas");
        let init: StateInit = initOf JettonDefaultWallet(msg.owner_address, myAddress());
        if (msg.include_address) {
            send(SendParameters{
                to: sender(),
                value: 0,
                mode: SendRemainingValue,
                body: TakeWalletAddress{
                    query_id: msg.query_id,
                    wallet_address: contractAddress(init),
                    owner_address: beginCell().storeBool(true).storeAddress(msg.owner_address).endCell().asSlice()
                }.toCell()
            });
        } else {
            send(SendParameters{
                to: sender(),
                value: 0,
                mode: SendRemainingValue,
                body: TakeWalletAddress { // 0xd1735400
                    query_id: msg.query_id,
                    wallet_address: contractAddress(init),
                    owner_address: beginCell().storeBool(false).endCell().asSlice()
                }.toCell()
            });
        }
    }

    fun requireSenderAsWalletOwner(owner: Address) {
        let ctx: Context = context();
        let winit: StateInit = self.getJettonWalletInit(owner);
        require(contractAddress(winit) == ctx.sender, "Invalid sender");
    }

    fun getJettonWalletInit(address: Address): StateInit {
        return initOf JettonDefaultWallet(address, myAddress());
    }

    // ====== Get Methods ====== //
    get fun get_jetton_data(): JettonData {
        return JettonData{ 
            total_supply: self.total_supply, 
            mintable: self.mintable, 
            owner: self.owner, 
            content: self.content, 
            wallet_code: initOf JettonDefaultWallet(self.owner, myAddress()).code
        };
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf JettonDefaultWallet(owner, myAddress()));
    }
}

// ============================================================ //
@interface("org.ton.jetton.wallet")
contract JettonDefaultWallet {
    const minTonsForStorage: Int = ton("0.019");
    const gasConsumption: Int = ton("0.08"); // ❗

    balance: Int as coins = 0;
    owner: Address;
    master: Address;

    series_id: Int as uint32 = 0; // 次序 ID
    nft_item_record: map<Int, Int as uint32>; // [次序 ID -> NFT ID]
    nft_item_address_to_id: map<Address, Bool>; // [NFT Address -> 次序 ID] (b/c 為了確保知道哪些 NFT Item 能夠傳入訊息)

    init(owner: Address, master: Address) {
        self.balance = 0;
        self.owner = owner;
        self.master = master;
    }

    receive(msg: JettonTokenTransfer) { // 0xf8a7ea5
        let ctx: Context = context();

        // *One other cases: Need to check whether the sender address is from the NFT Item Address
        // Case when NFT Transfer, the NFT Item will send the tx request to here(that's why we need to check the sender address is from the NFT Item Address or not)
        let result: Bool? = self.nft_item_address_to_id.get(ctx.sender);
        if (result == true) {
            // ----- When NFT being transferred, NFT Item send message to here -----
            // then sender is the NFT Item
            dump(8888888888);
            // require(ctx.sender == self.owner || ctx.sender == sender_nft_item_addr, "Invalid sender"); // ❗
            // let sender_nft_item_addr: Address? = self.get_nft_item_address_by_itemIndex(sender_nft_series_id); // ❗
        } else {
            require(ctx.sender == self.owner, "Invalid sender");
        }
    
        let final: Int = ctx.readForwardFee() * 2 + 2 * self.gasConsumption + self.minTonsForStorage + msg.forward_ton_amount;   // Gas checks, forward_ton = 0.152
        require(ctx.value > final, "Invalid value"); 

        // Sepcial Cases::
        // 1/ Transfer Jetton Token: the Owner of this Jetton Wallet -> (Burn the extract NFT)
        // 2/ Initial Minting, from Jetton Master
        if (msg.transferJettonAmount >= BUFFER_JETTON_AMOUNT) {
            self.series_id = self.series_id - 1;
            let latest_nft_item_id: Int? = self.nft_item_record.get(self.series_id)!!;
            self.nft_item_record.set(self.series_id, null);
            self.nft_item_address_to_id.set(self.get_nft_item_address_by_itemIndex(latest_nft_item_id)!!, null);
            
            send(SendParameters{
                    to: self.master,
                    value: ton("0.3"),
                    mode: SendPayGasSeparately,
                    bounce: false,
                    body: NftBurnRequest_and_Mint{ // 0xb609b568
                        query_id: msg.query_id,
                        item_index: latest_nft_item_id!!, // The NFT Item ID that need to be burn
                        original_sender: self.owner,
                        new_owner: msg.response_destination!!
                    }.toCell()
                });
            let remainingGas: Int = self.msg_value(ctx.value) - ton("0.3") - ctx.readForwardFee();
            self.sendTokenInternal(msg, remainingGas);
        } else { 
            // General Jetton Token Transfer
            let remainingGas: Int = self.msg_value(ctx.value);
            self.sendTokenInternal(msg, remainingGas);
        } 
    }

    fun sendTokenInternal(msg: JettonTokenTransfer, remainingGas: Int) {
        self.balance = self.balance - msg.transferJettonAmount; 
        require(self.balance >= 0, "Invalid balance");
        require(msg.response_destination != null, "Invalid response destination");
        let init: StateInit = initOf JettonDefaultWallet(msg.response_destination!!, self.master);  
        let wallet_address: Address = contractAddress(init);
        send(SendParameters{
            to: wallet_address, 
            value: remainingGas,
            mode: SendPayGasSeparately,
            bounce: false,
            body: TokenTransferInternal {
                query_id: msg.query_id,
                transferJettonAmount: msg.transferJettonAmount,
                from: self.owner,
                response_destination: msg.response_destination!!,
                forward_ton_amount: msg.forward_ton_amount,
                forward_payload:  msg.forward_payload
            }.toCell(),
            code: init.code,
            data: init.data
        });
    }

    receive(msg: TokenTransferInternal) { // 0x178d4519
        let ctx: Context = context();
        if (ctx.sender != self.master) {
            let sinit: StateInit = initOf JettonDefaultWallet(msg.from, self.master);
            require(contractAddress(sinit) == ctx.sender, "Invalid sender!");
        }

        if (ctx.sender == self.master && msg.transferJettonAmount >= BUFFER_JETTON_AMOUNT) { // Only from Jetton Master, initial Mint 
            let item_id: Int = msg.forward_payload.loadUint(32);
            self.nft_item_record.set(self.series_id, item_id);
            self.nft_item_address_to_id.set(self.get_nft_item_address_by_itemIndex(item_id)!!, true);
            self.series_id = self.series_id + 1;
        }

        // Update balance
        self.balance = self.balance + msg.transferJettonAmount;
        require(self.balance >= 0, "Invalid balance"); 

        // Get value for gas
        let msg_value: Int = self.msg_value(ctx.value);  
        let fwd_fee: Int = ctx.readForwardFee();

        // 0x7362d09c -- Send Notification for the new owner
        if (msg.forward_ton_amount > 0) { 
                    msg_value = msg_value - msg.forward_ton_amount - fwd_fee;
                    send(SendParameters{
                        to: self.owner,
                        value: msg.forward_ton_amount,
                        mode: SendPayGasSeparately,
                        bounce: false,
                        body: TokenNotification {
                            query_id: msg.query_id,
                            amount: msg.transferJettonAmount,
                            from: msg.from,
                            forward_payload: msg.forward_payload
                        }.toCell()
                    });
        }
        // 0xd53276db -- Cashback to the original Sender
        if (msg.response_destination != null && msg_value > 0) { 
                send(SendParameters {
                    to: msg.response_destination!!, 
                    value: msg_value,
                    bounce: false,
                    body: TokenExcesses { query_id: msg.query_id }.toCell(),
                    mode: SendPayGasSeparately
                });
        }
    }

    receive(msg: TokenBurn) {
        let ctx: Context = context();

        let ds: Slice = (msg.custom_payload!!).beginParse();
        let item_index: Int = ds.loadUint(32);
        require(ctx.sender == self.owner || ctx.sender == self.master || ctx.sender == self.get_nft_item_address_by_itemIndex(item_index), "Invalid sender");

        self.balance = self.balance - msg.amount; // Update balance
        require(self.balance >= 0, "Invalid balance");

        let fwd_fee: Int = ctx.readForwardFee(); // Gas checks
        require(ctx.value > fwd_fee + 2 * self.gasConsumption + self.minTonsForStorage, "Invalid value - Burn");

        // Burn tokens
        send(SendParameters{  
            to: self.master,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: TokenBurnNotification{
                query_id: msg.query_id,
                amount: msg.amount,
                sender: self.owner,
                response_destination: msg.response_destination!!
            }.toCell()
        });
    }


    fun msg_value(value: Int): Int {
        let msg_value: Int = value;
        let ton_balance_before_msg: Int = myBalance() - msg_value;
        let storage_fee: Int = self.minTonsForStorage - min(ton_balance_before_msg, self.minTonsForStorage);
        msg_value = msg_value - (storage_fee + self.gasConsumption);
        return msg_value;
    }

    bounced(msg: bounced<TokenTransferInternal>) {
        self.balance = self.balance + msg.transferJettonAmount;
    }

    bounced(msg: bounced<TokenBurnNotification>) {
        self.balance = self.balance + msg.amount;
    }

    get fun get_wallet_data(): JettonWalletData {
        return JettonWalletData{
            balance: self.balance,
            owner: self.owner,
            master: self.master,
            code: (initOf JettonDefaultWallet(self.owner, self.master)).code
        };
    }

    get fun get_series_id(): Int {
        return self.series_id;
    }

    get fun get_nft_item_record(): map<Int, Int as uint32> {
        return self.nft_item_record;
    }

    get fun get_collection_address(): Address {
        let initCode: StateInit = initOf NftCollection(self.master);
        return contractAddress(initCode);
    }

    get fun get_nft_item_address_by_itemIndex(item_index: Int?): Address? {
        let nft_init: StateInit = initOf NftItem(self.get_collection_address(), item_index!!, self.master);
        return contractAddress(nft_init);
    }

    get fun get_nft_address_to_id(nft_address: Address): Bool {
        return self.nft_item_address_to_id.get(nft_address)!!;
    }
}
