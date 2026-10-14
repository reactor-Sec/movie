module moviepass::msx;

use sui::coin::{Self};
use sui::url;

public struct MSX has drop {}

fun init(witness: MSX, ctx: &mut TxContext) {
    let url = url::new_unsafe_from_bytes(b"https://d1fvsuv3rrz9o2.cloudfront.net/dogs/bone.png");
    let (treasury, metadata) = coin::create_currency(
            witness,
            6,
            b"MSX",
            b"MSX Coin",
            b"Moviepass Stock Exchange Coin",
            option::some(url),
            ctx,
    );
    transfer::public_share_object(metadata);
    transfer::public_transfer(treasury, ctx.sender())
}

#[test_only]
public fun init_for_testing(
    ctx: &mut TxContext,
) {
    init(MSX {}, ctx);
}