module RateLimiter

export TokenBucket, consume_token!

"""
    TokenBucket

A simple token bucket rate limiter.

Fields:
- `capacity::Float64`: The maximum number of tokens the bucket can hold.
- `tokens::Float64`: The current number of tokens available.
- `refill_rate::Float64`: The rate (tokens per second) at which the bucket refills.
- `last_refill_time::Float64`: The last time the bucket was refilled (in seconds, as returned by `time()`).

The token bucket allows for bursty traffic up to `capacity`, and then enforces a steady rate limit defined by `refill_rate`.
"""
mutable struct TokenBucket
    capacity::Float64      
    tokens::Float64        
    refill_rate::Float64   
    last_refill_time::Float64 
end

"""
    TokenBucket(capacity::Real, refill_rate::Real) -> TokenBucket

Construct a new `TokenBucket` with the given capacity and refill rate.

Arguments:
- `capacity::Real`: Maximum number of tokens in the bucket.
- `refill_rate::Real`: Number of tokens added per second.

Returns:
- `TokenBucket`: A new token bucket, initially full.
"""
TokenBucket(capacity::Real, refill_rate::Real) = TokenBucket(Float64(capacity), Float64(capacity), Float64(refill_rate), time())

"""
    consume_token!(bucket::TokenBucket, amount::Integer=1) -> Bool

Attempt to consume `amount` tokens from the bucket.

Arguments:
- `bucket::TokenBucket`: The token bucket to consume from.
- `amount::Integer=1`: The number of tokens to consume (default: 1).

Returns:
- `Bool`: `true` if enough tokens were available and consumed, `false` otherwise.

Notes:
- The bucket is automatically refilled based on elapsed time and `refill_rate` before consumption.
- If the bucket exceeds its capacity after refill, it is capped at `capacity`.
"""
function consume_token!(bucket::TokenBucket, amount::Integer = 1)
    now = time()
    elapsed = now - bucket.last_refill_time
    bucket.tokens += elapsed * bucket.refill_rate
    bucket.last_refill_time = now

    if bucket.tokens > bucket.capacity
        bucket.tokens = bucket.capacity
    end

    if bucket.tokens >= amount
        bucket.tokens -= amount
        return true 
    else
        return false 
    end
end

end