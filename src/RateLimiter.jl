
module RateLimiter

export TokenBucket, consume_token!

"""
Αναπαριστά έναν "κουβά με μάρκες" για rate limiting.
"""
mutable struct TokenBucket
    capacity::Float64      
    tokens::Float64        
    refill_rate::Float64    
    last_refill_time::Float64 
end

"""
Δημιουργεί ένα νέο TokenBucket.
"""
TokenBucket(capacity::Real, refill_rate::Real) = TokenBucket(Float64(capacity), Float64(capacity), Float64(refill_rate), time())

"""
    consume_token!(bucket::TokenBucket, amount::Integer=1) -> Bool

Προσπαθεί να καταναλώσει 'amount' μάρκες. Επιστρέφει `true` αν υπάρχουν
αρκετές, αλλιώς `false`.
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