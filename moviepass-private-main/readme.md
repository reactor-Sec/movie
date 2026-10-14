## MoviePass Exchange

The following APIs will be supported in the moviepass exchange

We will also support create in 3 different configurations, not hard coded into the smart contract but instead in the backend configuration layer

- 1 billion tokens (most popular)
- 500 million tokens (middle)
- 250 million tokens (least popular)

In this repo, we also publish the MSX base token so that we can tie the package from moviepass into this given token.

The following operations are supported on the smart contract:

```
create_curve<BASE, QUOTE>
```
We create can create a curve here with a configurable virtual amount of liquidity and different supplies to be discussed later. The curve that is created will have a set duration (defaulted to 24 hours) for users on MSX to bid on the curves. Note that there is a maximum presale value still.

@Nico what amount of presale would you like to set? we can go over some of the math here.

```
disperse
```
Disperse is an admin function that settles all bids at an equal price

```
bid
```
Bid is a function for users to bid on the different tokens

```
swap_a_to_b, swap_b_to_a
```
Swap functions for the base tokens

We will include limit orders inside another contract where we get access to custodial funds for a user to trade or they can deposit so that we can trade on their behalf