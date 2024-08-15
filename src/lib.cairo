use ekubo::router_lite::{RouteNode, TokenAmount, Swap};
use starknet::ContractAddress;

#[starknet::interface]
pub trait IArbitrageur<TContractState> {
    // Does a multihop swap, where the output/input of each hop is passed as input/output of the
    // next swap Note to do exact output swaps, the route must be given in reverse
    fn multihop_swap(ref self: TContractState, route: Array<RouteNode>, token_amount: TokenAmount);

    // Does multiple multihop swaps
    fn multi_multihop_swap(ref self: TContractState, swaps: Array<Swap>);

    // Get the owner of the bot, read-only (view) function
    fn get_owner(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
pub mod arbitrage {
    use ekubo::types::delta::Delta;
    use ekubo::router_lite::{RouteNode, TokenAmount, Swap};
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use core::num::traits::Zero;
    use ekubo::interfaces::core as ekubo_core;
    use ekubo::interfaces::core::ICoreDispatcherTrait;
    use ekubo::components::shared_locker;
    use ekubo::types::i129::{i129, i129Trait};

    #[storage]
    struct Storage {
        core: ekubo_core::ICoreDispatcher,
        owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ContractAddress) {
        let core = ekubo_core::ICoreDispatcher { contract_address: core };
        self.core.write(core);
        let caller: ContractAddress = get_caller_address();
        assert(!caller.is_zero(), 'caller is the zero address');
        self.owner.write(caller);
    }

    #[abi(embed_v0)]
    impl LockerImpl of ekubo_core::ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            // we minimize interactions with the state
            // so we read necessary data once at the start
            let core = self.core.read();
            let recipient = self.owner.read();

            // deserialize the raw input into defined data structures
            let mut swaps = shared_locker::consume_callback_data::<Array<Swap>>(core, data);
            let mut total_profit: i129 = Zero::zero();
            let mut token: ContractAddress = Zero::zero();

            // for every swap (when an input amount is splitted between several swaps)
            while let Option::Some(swap) = swaps.pop_front() {
                let mut route = swap.route;
                // if token amount is positive it is an exact input
                // otherwise it is an exact output
                let mut token_amount = swap.token_amount;
                token = swap.token_amount.token;

                // flash loan: we have not yet enough funds but we can make a swap in advance
                // we don't care here either it is an exact input or an exact output
                // for the exact input - we loan the whole investment
                // for the exact output - we loan the investment (yet unknown) + profit (if any)
                // In both cases the loan should cover the investment
                let loaned_amount = swap.token_amount;

                //we unwind the swap route - a path of interrelated token exchanges
                while let Option::Some(node) = route.pop_front() {
                    // is_token1 indicates whether the amount is in terms of token0 or token1.
                    // it used to setup the proper direction of a swap
                    let is_token1 = token_amount.token == node.pool_key.token1;

                    // [Delta](https://github.com/EkuboProtocol/abis/blob/main/src/types/delta.cairo)
                    // represents a change in balances of Core contract
                    // e.g swap 20 token0 for 30 token1 if is_token1 == false results
                    // in delta (20, -30)
                    // so we as a trader get 30 units of token1 and lose 20 units of token0

                    let delta = core
                        .swap(
                            node.pool_key,
                            ekubo_core::SwapParameters {
                                amount: token_amount.amount,
                                is_token1: is_token1,
                                sqrt_ratio_limit: node.sqrt_ratio_limit,
                                skip_ahead: node.skip_ahead,
                            }
                        );

                    // the delta from the current swap serves as an input for the next swap
                    // from the trader's (ours) perspective
                    token_amount =
                        if (is_token1) {
                            // we swapped token1 for token0
                            // as a trader we have now token0
                            // in this case delta is (-token0, token1)
                            // (change in the balances of Core)
                            // so for the next swap the input is token0 and
                            // we should flip the sign (-(-token0))
                            TokenAmount { amount: -delta.amount0, token: node.pool_key.token0 }
                        } else {
                            // we swapped token0 for token1
                            // as a trader we have now token1
                            // core balances delta (token0, -token1)
                            // so we for the next swap we offer -(-token1)
                            // as the exact input amount
                            // for the case when we specified -token0 as an exact output amount
                            // delta is (-token0, token1)
                            // we provide -token1 as an exact output for the previous(!) hop - for
                            // exact output swaps, the route must be given in reverse
                            TokenAmount { amount: -delta.amount1, token: node.pool_key.token1 }
                        };
                };

                assert(token_amount.token == loaned_amount.token, 'the same token');
                // Exact input case: `token_amount` (contains the last output) and `loaned_amount`
                // (contains the first input) are positive
                // Exact output case: `token_amount` (contains the last input) and `loaned_amount`
                // (contains the last output) are negative
                // In both cases the difference is our actual net profit
                total_profit += token_amount.amount - loaned_amount.amount;
            };

            // The most important check we have
            assert(total_profit > Zero::zero(), 'unprofitable swap');

            // Withdraw profits
            core.withdraw(token, recipient, total_profit.try_into().unwrap());

            // as we don't care of the actual deltas
            // just return an empty array to reduce gas costs
            let mut serialized: Array<felt252> = array![];
            let mut outputs: Array<Array<Delta>> = ArrayTrait::new();
            Serde::serialize(@outputs, ref serialized);
            serialized.span()
        }
    }

    #[abi(embed_v0)]
    impl ArbitrageImpl of super::IArbitrageur<ContractState> {
        #[inline(always)]
        fn multihop_swap(
            ref self: ContractState, route: Array<RouteNode>, token_amount: TokenAmount
        ) {
            self.multi_multihop_swap(array![Swap { route, token_amount }]);
        }

        #[inline(always)]
        fn multi_multihop_swap(ref self: ContractState, swaps: Array<Swap>) {
            assert(self.owner.read() == get_caller_address(), 'unauthorized');
            let _arr: Span<felt252> = shared_locker::call_core_with_callback(
                self.core.read(), @swaps
            );
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
    }
}
