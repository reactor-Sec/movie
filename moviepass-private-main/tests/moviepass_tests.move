#[test_only]
module moviepass::meme {
    use sui::coin::{Self};
    use sui::url;

    public struct MEME has drop {}

    fun init(otw: MEME, ctx: &mut TxContext) {
        let (meme_treasury_cap, meme_metadata) = coin::create_currency(
            otw,
            9,
            b"MEME",
            b"MEME USD",
            b"the meme used to mint",
            option::some(url::new_unsafe_from_bytes(
                b"https://ipfs.io/ipfs/QmYH4seo7K9CiFqHGDmhbZmzewHEapAhN9aqLRA7af2vMW"),
            ),
            ctx,
        );
        transfer::public_share_object(meme_metadata);
        transfer::public_transfer(meme_treasury_cap, ctx.sender());
    }

    public fun init_for_testing(ctx: &mut TxContext) {
        init(MEME {}, ctx)
    }
}

#[test_only]
module moviepass::moviepass_tests {

    use sui::test_scenario::{Self as ts, Scenario};
    use moviepass::msx::{Self, MSX};
    use moviepass::meme::{Self, MEME};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use std::string::{Self, String};
    use moviepass::exchange::{Self, CustodialPoolsIndex, AdminCap, FeeCollector, AdminSettings, EClosedLoop, EPresaleNotCompleted};

    const ADMIN: address = @0xA11CE;
    const USER_1: address = @0xB0B;
    const USER_2: address = @0xCAC;
    const ONE_DAY_MS: u64 = 86400;

    fun setup_for_testing(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        exchange::init_for_testing(scenario.ctx());
        msx::init_for_testing(scenario.ctx());
        meme::init_for_testing(scenario.ctx());
        
        // create clock
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(0);
        clock.share_for_testing();
        scenario
    }

    fun setup_curve_for_testing(scenario: &mut Scenario): ID {
        scenario.next_tx(ADMIN);
        let mut admin_setttings = scenario.take_shared<AdminSettings>();
        let clock = scenario.take_shared<Clock>();
        let treasury_cap = scenario.take_from_sender<TreasuryCap<MEME>>();
        let coin_metadata = scenario.take_shared<CoinMetadata<MEME>>();
        let mut custodial_pool_idx = scenario.take_shared<CustodialPoolsIndex>();
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let id = exchange::create_curve<MSX, MEME>(
            &mut admin_setttings,
            treasury_cap,
            &coin_metadata,
            1000000000,
            4000000 * 1_000_000,
            option::some(100_000),
            option::some(ONE_DAY_MS),
            string::utf8(b"ACTOR").to_ascii(),
            &clock,
            scenario.ctx()
        );
        exchange::add_manager(
            &mut custodial_pool_idx,
            &admin_cap,
            ADMIN
        );
        ts::return_shared(custodial_pool_idx);
        ts::return_shared(admin_setttings);
        ts::return_shared(clock);
        ts::return_shared(coin_metadata);
        scenario.return_to_sender(admin_cap);
        id
    }

    fun setup_user_custodial_accounts(
        scenario: &mut Scenario,
        user: address,
        amount: u64
    ) {
        scenario.next_tx(user);
        {
            let mut custodial_pool_idx = scenario.take_shared<CustodialPoolsIndex>();
            exchange::create_custodial_pool(
                &mut custodial_pool_idx,
                scenario.ctx()
            );
            ts::return_shared(custodial_pool_idx);
        };
        scenario.next_tx(user);
        let test_coin = coin::mint_for_testing<MSX>(amount * 1_000_000, scenario.ctx());
        let mut custodial_pool_idx = scenario.take_shared<CustodialPoolsIndex>();
        exchange::deposit_custodial_pool<MSX>(
            &mut custodial_pool_idx,
            user,
            test_coin,
            scenario.ctx()
        );
        ts::return_shared(custodial_pool_idx);
    }

    #[test]
    fun test_create_curve() {
        let mut ts = setup_for_testing();
        let id = setup_curve_for_testing(&mut ts);
        ts.next_tx(USER_1);
        let admin_setttings = ts.take_shared<AdminSettings>();
        let _curve = exchange::get_curve<MSX, MEME>(
            &admin_setttings,
            id
        );
        ts::return_shared(admin_setttings);
        ts.end();
    }

    #[test]
    #[expected_failure(abort_code = EPresaleNotCompleted)]
    fun test_create_token_and_buy_before_disperse_fail() {
        let mut ts = setup_for_testing();
        let id = setup_curve_for_testing(&mut ts);
        ts.next_tx(USER_1);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_1,
                200000
            );
            ts.next_tx(USER_1);
        };
        ts.next_tx(USER_1);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let mut fee_collector = ts.take_shared<FeeCollector>();
            {
                exchange::swap_a_to_b_with_custodial_account<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    &mut fee_collector,
                    100,
                    ts.ctx()
                );
            };
            ts::return_shared(fee_collector);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.end();
    }

    #[test]
    #[expected_failure(abort_code = EClosedLoop)]
    fun test_create_token_and_trade_open_loop_fail() {
        let mut ts = setup_for_testing();
        let id = setup_curve_for_testing(&mut ts);
        ts.next_tx(USER_1);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_1,
                200000
            );
            ts.next_tx(USER_1);
        };
        ts.next_tx(USER_1);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let mut fee_collector = ts.take_shared<FeeCollector>();
            let test_coin = coin::mint_for_testing<MSX>(1_000_000, ts.ctx());
            {
                let result_coin = exchange::swap_a_to_b<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    &mut fee_collector,
                    test_coin,
                    ts.ctx()
                );
                transfer::public_transfer(result_coin, USER_1);
            };
            ts::return_shared(fee_collector);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.end();
    }

    #[test]
    fun test_dutch_auction_multiple_users() {
        let mut ts = setup_for_testing();
        let id = setup_curve_for_testing(&mut ts);
        ts.next_tx(USER_1);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_1,
                200000
            );
        };
        ts.next_tx(USER_2);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_2,
                200000
            );
        };
        ts.next_tx(USER_1);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            {
                exchange::bid_with_custodial_account<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    1000000,
                    &clock,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(USER_2);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            {
                exchange::bid_with_custodial_account<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    1000000,
                    &clock,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(ADMIN);
        {
            let mut clock = ts.take_shared<Clock>();
            clock.set_for_testing(ONE_DAY_MS + 1);
            ts::return_shared(clock);
        };
        ts.next_tx(ADMIN);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            let mut fee_collector = ts.take_shared<FeeCollector>();
            {
                exchange::disperse<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    &mut fee_collector,
                    option::some(1000),
                    &clock,
                    true,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(fee_collector);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(ADMIN);
        {
            let custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let user_1_bal = exchange::get_custodial_pool_balanace<MEME>(
                &custodial_pool_idx,
                USER_1
            );
            let user_2_bal = exchange::get_custodial_pool_balanace<MEME>(
                &custodial_pool_idx,
                USER_2
            );
            assert!(user_1_bal == user_2_bal);
            ts::return_shared(custodial_pool_idx);
        };
        ts.end();
    }

 #[test]
    fun test_dutch_auction_multiple_users_strange_amounts() {
        let mut ts = setup_for_testing();
        let id = setup_curve_for_testing(&mut ts);
        ts.next_tx(USER_1);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_1,
                200000
            );
        };
        ts.next_tx(USER_2);
        {
            setup_user_custodial_accounts(
                &mut ts,
                USER_2,
                200000
            );
        };
        ts.next_tx(USER_1);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            {
                exchange::bid_with_custodial_account<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    13_000_000,
                    &clock,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(USER_2);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            {
                exchange::bid_with_custodial_account<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    43_000_000,
                    &clock,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(ADMIN);
        {
            let mut clock = ts.take_shared<Clock>();
            clock.set_for_testing(ONE_DAY_MS + 1);
            ts::return_shared(clock);
        };
        ts.next_tx(ADMIN);
        {
            let mut admin_settings = ts.take_shared<AdminSettings>();
            let mut custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let clock = ts.take_shared<Clock>();
            let mut fee_collector = ts.take_shared<FeeCollector>();
            {
                exchange::disperse<MSX, MEME>(
                    &mut admin_settings,
                    &mut custodial_pool_idx,
                    id,
                    &mut fee_collector,
                    option::some(1000),
                    &clock,
                    true,
                    ts.ctx()
                );
            };
            ts::return_shared(clock);
            ts::return_shared(admin_settings);
            ts::return_shared(fee_collector);
            ts::return_shared(custodial_pool_idx);
        };
        ts.next_tx(ADMIN);
        {
            let custodial_pool_idx = ts.take_shared<CustodialPoolsIndex>();
            let user_1_bal = exchange::get_custodial_pool_balanace<MEME>(
                &custodial_pool_idx,
                USER_1
            );
            let user_2_bal = exchange::get_custodial_pool_balanace<MEME>(
                &custodial_pool_idx,
                USER_2
            );
            std::debug::print(&user_1_bal);
            std::debug::print(&user_2_bal);
            ts::return_shared(custodial_pool_idx);
        };
        ts.end();
    }
}