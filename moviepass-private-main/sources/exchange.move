/// Exchange for to trade movie related tokens
/// Curve types have the following:
/// 1. Low Supply
/// 2. Medium Supply
/// 3. High Supply

module moviepass::exchange;

use moviepass::big_vector::{Self as bv, BigVector};
use sui::coin::{Self, CoinMetadata, TreasuryCap, Coin};
use sui::balance::{Self, Balance};
use sui::dynamic_field::{Self as df};
use sui::dynamic_object_field as dof;
use sui::vec_set::{Self, VecSet};
use sui::clock::{Clock};
use sui::url::Url;
use sui::event;
use std::u64::pow;
use sui::package;

use std::ascii::{String};
use std::type_name::{Self, TypeName};

// constants    
const FeeScaling: u128 = 1_000_000;
const DefaultPageSize: u64 = 1000;

// default values
const DefaultPresaleDuration: u64 = 60 * 60 * 24 * 1000;
const DefaultSwapFee: u64 = 10_000; // 1% fee
const DefaultBidPercentage: u64 = 10_000; // 10% max rate

const SLICE_SIZE: u64 = 1_000;
public fun slice_size(): u64 { SLICE_SIZE }

// error codes
const ETreasuryCapSupplyNonZero: u64 = 0;
const EPresaleEnded: u64 = 1;
const EAbovePresale: u64 = 2;
const ENotDispersable: u64 = 3;
const EPresaleCompleted: u64 = 4;
const EPresaleNotCompleted: u64 = 5;
const EInvalidPackageVersion: u64 = 6;
const ESenderIsNotAuthorized: u64 = 7;
const EClosedLoop: u64 = 8;
const EOutputZero: u64 = 9;
fun err_sender_is_not_authorized() { abort ESenderIsNotAuthorized }

// --------------- Version ---------------
const PACKAGE_VERSION: u64 = 1;

public struct CustodialPoolsIndex has key {
    id: UID,
    managers: VecSet<address>,
    version_set: VecSet<u64>,
    is_close_loop: bool
}

public struct CustodialPool has key, store {
    id: UID,
    owner: address,
}

public struct EXCHANGE has drop {} // otw

// Events

/// The `CurveCreatedEvent` will be utilized in the backend to store
/// and index the data for the curves specifically
/// quote_token_type - The type of the coin on Sui Network
/// quote_token_symbol - The symbol display name
/// quote_token_name - the name title: 'Venom: The Last Dance'
/// curve_type - a string that tells us if the curve is an ACTOR, MOVIE
/// curve_image - the image of the token
/// supply_amount - the original supply amount
/// virtual_a_amount - virtual MSX liquidity initalized at
/// time_created 
public struct CurveCreatedEvent has copy, drop {
    curve_id: ID,
    quote_token_type: String,
    quote_token_name: String,
    quote_token_symbol: String,
    curve_type: String,
    curve_image: Option<Url>,
    supply_amount: u64,
    virtual_a_amount: u64,
    presale_end_time: u64,
    time_created: u64
}

public struct SwapEvent has copy, drop {
    asset_id: ID,
    base_token_type: String,
    quote_token_type: String,
    is_buy: bool,
    input_amount: u64,
    output_amount: u64,
    base_reserve_val: u64,
    quote_reserve_val: u64,
    user: address
}

public struct BidEvent has copy, drop {
    asset_id: ID,
    quote_token_type: String,
    input_amount: u64,
    user: address
}

public struct FeeEvent has copy, drop {
    amount: u64,
    user: address,
    coin_type: String
}

public struct DisperseEvent has copy, drop, store {
    asset_id: ID,
    quote_token_type: String,
    input_amount: u64,
    output_amount: u64,
    user: address
}

public struct DisperseEvents has copy, drop {
    events: vector<DisperseEvent>
}

// Store each curve as a dynamic object field under the admin settings for easiest access
public struct AdminSettings has key {
    id: UID,
    default_presale_duration: u64,
    swap_fee: u64,
    default_bid_percentage: u64,
    version_set: VecSet<u64>,
}

public struct FeeCollector has key {
    id: UID,
}

public struct PresaleCommit has drop, store {
    user: address,
    amount: u64
}

public struct AdminCap has key, store {
    id: UID,
}

public struct Curve<phantom BASE, phantom QUOTE> has key, store {
    id: UID,
    a_balance: Balance<BASE>,
    b_balance: Balance<QUOTE>,
    virtual_a_amount: u64,
    swap_fee: u64,
    /// Presale variables that are unused once the curve goes live
    presale_bal: Balance<BASE>,
    presale_commits: BigVector<PresaleCommit>,
    b_inital_value: u64,
    presale_total_commits: u64,
    presale_max_a: u64,
    presale_end_time: u64,
    presale_completed: bool
}

fun init(otw: EXCHANGE, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
    let admin = tx_context::sender(ctx);
    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(admin_cap, admin);
    transfer::share_object(AdminSettings {
        id: object::new(ctx),
        default_presale_duration: DefaultPresaleDuration,
        swap_fee: DefaultSwapFee,
        default_bid_percentage: DefaultBidPercentage,
        version_set: vec_set::singleton(PACKAGE_VERSION),
    });

    transfer::share_object(CustodialPoolsIndex {
        id: object::new(ctx),
        managers: vec_set::empty(),
        is_close_loop: true,
        version_set: vec_set::singleton(PACKAGE_VERSION),
    });

    transfer::share_object(FeeCollector {
        id: object::new(ctx)
    });
}

// CustodialPoolsAdmin Functions
public fun add_manager(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    _cap: &AdminCap,
    manager: address,
) {
    custodial_pool_idx.managers.insert(manager);
}

public fun remove_manager(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    _cap: &AdminCap,
    manager: address,
) {
    custodial_pool_idx.managers.remove(&manager);
}

public fun set_is_closed(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    _cap: &AdminCap,
    is_close_loop: bool,
) {
    custodial_pool_idx.is_close_loop = is_close_loop;
}

fun assert_custodial_pools_open_loop(
    custodial_pool_idx: &CustodialPoolsIndex,
) {
   assert!(
        !custodial_pool_idx.is_close_loop,
        EClosedLoop,
    );
}

public fun add_version(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    _cap: &AdminCap,
    version: u64,
) {
    admin_settings.version_set.insert(version);
    custodial_pool_idx.version_set.insert(version);
}

public fun remove_version(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    _cap: &AdminCap,
    version: u64,
) {
    admin_settings.version_set.remove(&version);
    custodial_pool_idx.version_set.remove(&version);
}

public fun create_curve<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    mut tc: TreasuryCap<QUOTE>,
    coin_metadata: &CoinMetadata<QUOTE>,
    supply_amount: u64, // This is in the amount without decimal precision so we check with metadata
    virtual_a_amount: u64,
    mut bid_percentage: Option<u64>,
    mut presale_duration: Option<u64>,
    curve_type: String,
    curve_name: String,
    clock: &Clock,
    ctx: &mut TxContext
): ID {
    admin_settings.assert_valid_version();
    // total supply of treasury cap should be zero while listing a new token.
    assert!(coin::total_supply<QUOTE>(&tc) == 0, ETreasuryCapSupplyNonZero);
    let bid_percentage_extracted = if (option::is_some(&bid_percentage)) {
        option::extract(&mut bid_percentage)
    } else {
        admin_settings.default_bid_percentage
    };

    let presale_dur = if (option::is_some(&presale_duration)) {
        option::extract(&mut presale_duration)
    } else {
        admin_settings.default_presale_duration
    };

    // mint token coins max supply.
    let b_coin_decimals = (coin::get_decimals<QUOTE>(coin_metadata));
    let b_target_supply = (pow(10, b_coin_decimals) as u64) * supply_amount;
    let b_balance = coin::mint_balance<QUOTE>(&mut tc, b_target_supply);

    let end_time = clock.timestamp_ms() + presale_dur;

    let curve_uid = object::new(ctx);
    let curve_id = curve_uid.to_inner();
    let max_b_sold = safe_percentage(b_target_supply, bid_percentage_extracted);

    // This is the max amount of BASE coins that can be inputted
    let max_a_input = ((b_target_supply as u128) * (virtual_a_amount as u128) / ((b_target_supply - max_b_sold) as u128) as u64);
    let curve = Curve<BASE, QUOTE> {
        id: curve_uid,
        a_balance: balance::zero(),
        b_balance: b_balance,
        virtual_a_amount: virtual_a_amount,
        swap_fee: admin_settings.swap_fee,
        presale_bal: balance::zero(),
        presale_commits: bv::new(slice_size(), ctx),
        presale_total_commits: 0,
        b_inital_value: b_target_supply,
        presale_max_a: max_a_input,
        presale_end_time: end_time,
        presale_completed: false
    };

    // Only one coin type can be created for this type of quote
    let coin_type = type_name::into_string(type_name::get<QUOTE>());
    df::add(&mut admin_settings.id, coin_type, tc);
    dof::add(&mut admin_settings.id, curve_id, curve);

    event::emit(CurveCreatedEvent {
        curve_id,
        quote_token_type: coin_type,
        quote_token_name: curve_name,
        quote_token_symbol: coin_metadata.get_symbol(),
        curve_type,
        curve_image: coin_metadata.get_icon_url(),
        supply_amount,
        virtual_a_amount,
        presale_end_time: end_time,
        time_created: clock.timestamp_ms()
    });

    curve_id
}

/// Get output price for uncorrelated curve x*y = k
fun get_output_amount(
    input_amount: u64, 
    input_reserve: u64, 
    output_reserve: u64
): u64 {
    // up casts
    let (
        input_amount,
        input_reserve,
        output_reserve
    ) = (
        (input_amount as u128),
        (input_reserve as u128),
        (output_reserve as u128)
    );

    let numerator = input_amount * output_reserve;
    let denominator = input_reserve + input_amount;
    assert!(numerator/ denominator > 0, EOutputZero);
    (numerator / denominator as u64)
}

/// gets the percentage of the number given the fee scaling
fun safe_percentage(
    number: u64,
    percentage: u64,
): u64 {
    (((number as u128) * (percentage as u128) / FeeScaling) as u64)
}

/// ---  Below here are the closed loop variants of the functions  ---///
public fun bid_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();

    let current_time = clock.timestamp_ms();
    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);

    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, ctx.sender());
    let coin_type = type_name::get<BASE>();
    let target = df::borrow_mut<TypeName, Balance<BASE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    assert!(current_time < curve.presale_end_time, EPresaleEnded);

    let coin_value = coin.value();
    let committed_capital_value = curve.presale_total_commits;
    let updated_commited_value = coin_value + committed_capital_value;

    assert!(updated_commited_value < curve.presale_max_a, EAbovePresale);
    assert!(!curve.presale_completed, EPresaleCompleted);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());

    event::emit(BidEvent {
        asset_id,
        quote_token_type,
        input_amount: coin_value,
        user: ctx.sender()
    });

    curve.presale_bal.join(coin.into_balance());
    curve.presale_total_commits = updated_commited_value;
    curve.presale_commits.push_back(PresaleCommit {
        user: ctx.sender(),
        amount: coin_value
    });
}

public fun swap_a_to_b_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    amount: u64,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, ctx.sender());
    let coin_type = type_name::get<BASE>();
    let target = df::borrow_mut<TypeName, Balance<BASE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    assert!(curve.presale_completed, EPresaleNotCompleted);
    let mut base_balance = coin::into_balance(coin);

    take_fee<BASE>(fee_collector, curve.swap_fee, &mut base_balance, ctx.sender());
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = base_balance.value();

    let output_amount = get_output_amount(
        amount,
        a_balance_value + curve.virtual_a_amount, 
        b_balance_value
    );

    curve.a_balance.join(base_balance);
    let result_bal = curve.b_balance.split(output_amount);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: true,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: ctx.sender()
    });

    let result_coin = result_bal.into_coin(ctx);
    deposit_custodial_pool<QUOTE>(
        custodial_pool_idx,
        ctx.sender(),
        result_coin,
        ctx
    );
}

public fun swap_b_to_a_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    amount: u64,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    assert!(curve.presale_completed, EPresaleNotCompleted);

    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, ctx.sender());
    let coin_type = type_name::get<QUOTE>();
    let target = df::borrow_mut<TypeName, Balance<QUOTE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    let mut quote_balance = coin::into_balance(coin);    

    take_fee<QUOTE>(fee_collector, curve.swap_fee, &mut quote_balance, ctx.sender());
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = quote_balance.value();

    let output_amount = get_output_amount(
        amount,
        b_balance_value,
        a_balance_value + curve.virtual_a_amount, 
    );

    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    curve.b_balance.join(quote_balance);
    let result_bal = curve.a_balance.split(output_amount);

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: false,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: ctx.sender()
    });
    let result_coin = result_bal.into_coin(ctx);
    deposit_custodial_pool<BASE>(
        custodial_pool_idx,
        ctx.sender(),
        result_coin,
        ctx
    );
}

/// ---  Below here are the closed loop with admin variants of the functions  ---///
public fun admin_bid_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    amount: u64,
    clock: &Clock,
    user: address,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_is_manager(ctx);

    let current_time = clock.timestamp_ms();
    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);

    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let coin_type = type_name::get<BASE>();
    let target = df::borrow_mut<TypeName, Balance<BASE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    assert!(current_time < curve.presale_end_time, EPresaleEnded);

    let coin_value = coin.value();
    let committed_capital_value = curve.presale_total_commits;
    let updated_commited_value = coin_value + committed_capital_value;

    assert!(updated_commited_value < curve.presale_max_a, EAbovePresale);
    assert!(!curve.presale_completed, EPresaleCompleted);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());

    event::emit(BidEvent {
        asset_id,
        quote_token_type,
        input_amount: coin_value,
        user: user
    });

    curve.presale_bal.join(coin.into_balance());
    curve.presale_total_commits = updated_commited_value;
    curve.presale_commits.push_back(PresaleCommit {
        user: user,
        amount: coin_value
    });
}

public fun admin_swap_a_to_b_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    amount: u64,
    user: address,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_is_manager(ctx);

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let coin_type = type_name::get<BASE>();
    let target = df::borrow_mut<TypeName, Balance<BASE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    assert!(curve.presale_completed, EPresaleNotCompleted);
    let mut base_balance = coin::into_balance(coin);

    take_fee<BASE>(fee_collector, curve.swap_fee, &mut base_balance, user);
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = base_balance.value();

    let output_amount = get_output_amount(
        amount,
        a_balance_value + curve.virtual_a_amount, 
        b_balance_value
    );

    curve.a_balance.join(base_balance);
    let result_bal = curve.b_balance.split(output_amount);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: true,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: user
    });

    let result_coin = result_bal.into_coin(ctx);
    deposit_custodial_pool<QUOTE>(
        custodial_pool_idx,
        user,
        result_coin,
        ctx
    );
}

public fun admin_swap_b_to_a_with_custodial_account<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    amount: u64,
    user: address,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_is_manager(ctx);

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    assert!(curve.presale_completed, EPresaleNotCompleted);

    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let coin_type = type_name::get<QUOTE>();
    let target = df::borrow_mut<TypeName, Balance<QUOTE>>(&mut custodial_pool.id, coin_type);
    let coin = target.split(amount).into_coin(ctx);

    let mut quote_balance = coin::into_balance(coin);    

    take_fee<QUOTE>(fee_collector, curve.swap_fee, &mut quote_balance, user);
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = quote_balance.value();

    let output_amount = get_output_amount(
        amount,
        b_balance_value,
        a_balance_value + curve.virtual_a_amount, 
    );

    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    curve.b_balance.join(quote_balance);
    let result_bal = curve.a_balance.split(output_amount);

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: false,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: user
    });
    let result_coin = result_bal.into_coin(ctx);
    deposit_custodial_pool<BASE>(
        custodial_pool_idx,
        user,
        result_coin,
        ctx
    );
}

/// ---  Below here are the open loop variants of the functions  ---///

/// Users will be able to bid the presale curve up to 10% of the tokens. For the first 24 hours, the initial portion of the curve will be distributed
/// in a fair launch manner
public fun bid<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    asset_id: ID,
    clock: &Clock,
    coin: Coin<BASE>,
    ctx: &TxContext
) {
    admin_settings.assert_valid_version();
    let current_time = clock.timestamp_ms();
    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);

    assert!(current_time < curve.presale_end_time, EPresaleEnded);

    let coin_value = coin.value();
    let committed_capital_value = curve.presale_total_commits;
    let updated_commited_value = coin_value + committed_capital_value;

    assert!(updated_commited_value < curve.presale_max_a, EAbovePresale);
    assert!(!curve.presale_completed, EPresaleCompleted);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());

    event::emit(BidEvent {
        asset_id,
        quote_token_type,
        input_amount: coin_value,
        user: ctx.sender()
    });

    curve.presale_bal.join(coin.into_balance());
    curve.presale_total_commits = updated_commited_value;
    curve.presale_commits.push_back(PresaleCommit {
        user: ctx.sender(),
        amount: coin_value
    });
}

/// take each amount and disperse to users
public fun disperse<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    page_size: Option<u64>,
    clock: &Clock,
    is_closed_loop: bool,
    ctx: &mut TxContext
) {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);

    // Check that the curve is either fully sold out or time is passed
    assert!(
        clock.timestamp_ms() > curve.presale_end_time || curve.presale_max_a == curve.presale_bal.value(), ENotDispersable
    );
    assert!(!curve.presale_completed, EPresaleCompleted);

    let committed_capital_value = curve.presale_total_commits;

    // All of these are initalized parameters that don't change for the duration of the bid
    let output_amount = get_output_amount(
        committed_capital_value,
        curve.virtual_a_amount, 
        curve.b_inital_value
    );

    let swap_fee = curve.swap_fee;
    // Will only do this one time even if this call is paginated
    let mut presale_a_balance = curve.presale_bal.split(committed_capital_value);
    take_fee<BASE>(fee_collector, swap_fee, &mut presale_a_balance, ctx.sender());
    curve.a_balance.join(presale_a_balance);

    let end_target;
    let page = if (page_size.is_some()) {
        *option::borrow(&page_size)
    } else {
        DefaultPageSize
    };

    end_target = if (curve.presale_commits.length() > page) {
        curve.presale_commits.length() - page
    } else {
        0
    };

    let mut disperse_events = vector::empty();
    let coin_type = type_name::into_string(type_name::get<QUOTE>());

    while (curve.presale_commits.length() > end_target) {
        let presale_commit = curve.presale_commits.pop_back();
        let amount_b_received = ((presale_commit.amount as u128) * (output_amount as u128) / (curve.presale_total_commits as u128) as u64);
        let coin_b = curve.b_balance.split(amount_b_received).into_coin(ctx);
        disperse_events.push_back(DisperseEvent {
            asset_id,
            quote_token_type: coin_type,
            input_amount: presale_commit.amount,
            output_amount: amount_b_received,
            user: presale_commit.user
        });
        if (is_closed_loop) {
            deposit_custodial_pool<QUOTE>(
                custodial_pool_idx,
                presale_commit.user,
                coin_b,
                ctx
            );
        } else {
            custodial_pool_idx.assert_custodial_pools_open_loop();
            transfer::public_transfer(coin_b, presale_commit.user);
        };
    };

    event::emit(DisperseEvents {
        events: disperse_events
    });

    if (curve.presale_commits.length() == 0) {
        curve.presale_completed = true;
    };
}

public fun swap_a_to_b<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    coin: Coin<BASE>,
    ctx: &mut TxContext
): Coin<QUOTE> {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_custodial_pools_open_loop();

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    assert!(curve.presale_completed, EPresaleNotCompleted);
    let mut base_balance = coin::into_balance(coin);

    take_fee<BASE>(fee_collector, curve.swap_fee, &mut base_balance, ctx.sender());
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = base_balance.value();

    let output_amount = get_output_amount(
        amount,
        a_balance_value + curve.virtual_a_amount, 
        b_balance_value
    );

    curve.a_balance.join(base_balance);
    let result_bal = curve.b_balance.split(output_amount);
    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: true,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: ctx.sender()
    });

    result_bal.into_coin(ctx)
}

public fun swap_b_to_a<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    custodial_pool_idx: &mut CustodialPoolsIndex,
    asset_id: ID,
    fee_collector: &mut FeeCollector,
    coin: Coin<QUOTE>,
    ctx: &mut TxContext
): Coin<BASE> {
    admin_settings.assert_valid_version();
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_custodial_pools_open_loop();

    let curve = get_curve_mut<BASE, QUOTE>(admin_settings, asset_id);
    assert!(curve.presale_completed, EPresaleNotCompleted);
    let mut quote_balance = coin::into_balance(coin);    

    take_fee<QUOTE>(fee_collector, curve.swap_fee, &mut quote_balance, ctx.sender());
    let (a_balance_value, b_balance_value) = curve.get_reserves();

    let amount = quote_balance.value();

    let output_amount = get_output_amount(
        amount,
        b_balance_value,
        a_balance_value + curve.virtual_a_amount, 
    );

    let quote_token_type = type_name::into_string(type_name::get<QUOTE>());
    let base_token_type = type_name::into_string(type_name::get<BASE>());

    curve.b_balance.join(quote_balance);
    let result_bal = curve.a_balance.split(output_amount);

    let (a_balance_value_after, b_balance_value_after) = curve.get_reserves();
    event::emit(SwapEvent {
        asset_id,
        base_token_type,
        quote_token_type,
        is_buy: false,
        input_amount: amount,
        output_amount,
        base_reserve_val: a_balance_value_after,
        quote_reserve_val: b_balance_value_after,
        user: ctx.sender()
    });
    result_bal.into_coin(ctx)
}

fun get_reserves<BASE, QUOTE>(self: &Curve<BASE, QUOTE>): (u64, u64) {
    (self.a_balance.value(), self.b_balance.value())
}

public fun package_version(): u64 { PACKAGE_VERSION }

fun assert_valid_version(admin_settings: &AdminSettings) {
    assert!(
        admin_settings.version_set.contains(&package_version()),
        EInvalidPackageVersion,
    );
}

fun assert_valid_custodial_version(custodial_pool_idx: &CustodialPoolsIndex) {
    assert!(
        custodial_pool_idx.version_set.contains(&package_version()),
        EInvalidPackageVersion,
    );
}

fun get_curve_mut<BASE, QUOTE>(
    admin_settings: &mut AdminSettings,
    curve_id: ID
): &mut Curve<BASE, QUOTE> {
    dof::borrow_mut<ID, Curve<BASE, QUOTE>>(&mut admin_settings.id, curve_id)
}

public fun get_curve<BASE, QUOTE>(
    admin_settings: &AdminSettings,
    curve_id: ID
): &Curve<BASE, QUOTE> {
    dof::borrow<ID, Curve<BASE, QUOTE>>(&admin_settings.id, curve_id)
}

fun take_fee<T>(
    fee_collector: &mut FeeCollector,
    swap_fee: u64, 
    bal: &mut Balance<T>,
    user: address
) {
    let amount = ((((swap_fee as u128) * (bal.value() as u128)) / FeeScaling) as u64);
    let fee_bal = balance::split(bal, amount);
    let coin_type = type_name::into_string(type_name::get<T>());
    event::emit(FeeEvent {
        amount,
        user,
        coin_type
    });
    store_fee<T>(fee_collector, fee_bal)
}

public fun store_fee<T>(
    fee_collector: &mut FeeCollector,
    balance_fee: Balance<T>
) {
    let coin_type = type_name::get<T>();
    if (!df::exists_with_type<TypeName, Balance<T>>(&fee_collector.id, coin_type)) {
        df::add(&mut fee_collector.id, coin_type, balance::zero<T>());
    };
    let target = df::borrow_mut<TypeName, Balance<T>>(&mut fee_collector.id, coin_type);
    target.join(balance_fee);
}

public fun withdraw_fees<T>(
    fee_collector: &mut FeeCollector,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext
): Coin<T> {
    let coin_type = type_name::get<T>();
    let target = df::borrow_mut<TypeName, Balance<T>>(&mut fee_collector.id, coin_type);
    let value = target.value();
    target.split(value).into_coin(ctx)
}

// TODO on republish we should remove mut
public fun managers(custodial_pool_idx: &mut CustodialPoolsIndex): VecSet<address> {
    custodial_pool_idx.managers
}

public fun admin_create_custodial_pool(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    user: address,
    ctx: &mut TxContext
) {
    let approved_managers = custodial_pool_idx.managers();
    let sender = ctx.sender();
    if (!approved_managers.contains(&sender)) {
        err_sender_is_not_authorized();
    };

    let custodial_pool = CustodialPool {
        id: object::new(ctx),
        owner: user
    };
    dof::add(&mut custodial_pool_idx.id, user, custodial_pool);
}

public fun create_custodial_pool(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    ctx: &mut TxContext
) {
    let custodial_pool = CustodialPool {
        id: object::new(ctx),
        owner: ctx.sender()
    };
    dof::add(&mut custodial_pool_idx.id, ctx.sender(), custodial_pool);
}

fun get_custodial_pool_mut(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    user: address
): &mut CustodialPool {
    dof::borrow_mut<address, CustodialPool>(&mut custodial_pool_idx.id, user)
}

public fun get_custodial_pool_balanace<T>(
    custodial_pool_idx: &CustodialPoolsIndex,
    user: address
): u64 {
    let custodial_pool = dof::borrow<address, CustodialPool>(&custodial_pool_idx.id, user);
    let coin_type = type_name::get<T>();
    let target = df::borrow<TypeName, Balance<T>>(&custodial_pool.id, coin_type);
    target.value()
}

public fun deposit_custodial_pool<T>(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    user: address,
    target_coin: Coin<T>,
    ctx: &mut TxContext
) {
    let approved_managers = custodial_pool_idx.managers();
    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let sender = ctx.sender();
    if (!approved_managers.contains(&sender) && sender != custodial_pool.owner) {
        err_sender_is_not_authorized();
    };

    let coin_type = type_name::get<T>();
    if (!df::exists_with_type<TypeName, Balance<T>>(&custodial_pool.id, coin_type)) {
        df::add(&mut custodial_pool.id, coin_type, balance::zero<T>());
    };
    let target = df::borrow_mut<TypeName, Balance<T>>(&mut custodial_pool.id, coin_type);
    target.join(target_coin.into_balance());
}

public fun admin_withdraw_custodial_pool<T>(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    user: address,
    ctx: &mut TxContext
): Coin<T> {
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_custodial_pools_open_loop();
    let approved_managers = custodial_pool_idx.managers();
    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let sender = ctx.sender();
    if (!approved_managers.contains(&sender) && sender != custodial_pool.owner) {
        err_sender_is_not_authorized();
    };

    let coin_type = type_name::get<T>();
    let target = df::borrow_mut<TypeName, Balance<T>>(&mut custodial_pool.id, coin_type);
    let value = target.value();
    target.split(value).into_coin(ctx)
}

public fun withdraw_custodial_pool<T>(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    user: address,
    ctx: &mut TxContext
): Coin<T> {
    custodial_pool_idx.assert_valid_custodial_version();
    custodial_pool_idx.assert_custodial_pools_open_loop();
    let approved_managers = custodial_pool_idx.managers();
    let custodial_pool = get_custodial_pool_mut(custodial_pool_idx, user);
    let sender = ctx.sender();
    if (!approved_managers.contains(&sender) && sender != custodial_pool.owner) {
        err_sender_is_not_authorized();
};

    let coin_type = type_name::get<T>();
    let target = df::borrow_mut<TypeName, Balance<T>>(&mut custodial_pool.id, coin_type);
    let value = target.value();
    target.split(value).into_coin(ctx)
}

fun assert_is_manager(
    custodial_pool_idx: &mut CustodialPoolsIndex,
    ctx: &TxContext
) {
    let sender = ctx.sender();
    let approved_managers = custodial_pool_idx.managers();
    if (!approved_managers.contains(&sender)) {
        err_sender_is_not_authorized();
    };
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(EXCHANGE {}, ctx);
}