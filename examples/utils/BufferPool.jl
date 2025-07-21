# src/utils/BufferPool.jl

module BufferPool

using Base.Threads

export Pool, get_buffer, release_buffer


struct Pool
    channel::Channel{IOBuffer}
    buffer_size::Int
end

function Pool(max_size::Int = 200, buffer_size::Int = 32768)  # Double buffers, 32KB
    pool = Pool(Channel{IOBuffer}(max_size), buffer_size)
    for _ in 1:max_size
        put!(pool.channel, IOBuffer(sizehint=buffer_size))
    end
    return pool
end

function grow_pool!(pool::Pool, additional::Int)
    for _ in 1:additional
        isfull(pool.channel) && break
        put!(pool.channel, IOBuffer(sizehint=pool.buffer_size))
    end
end

function get_buffer(pool::Pool)

    buffer = fetch(pool.channel)
    if buffer === pool.channel # Check if channel was empty
        return IOBuffer(sizehint=pool.buffer_size)
    else
        return buffer
    end
end

function release_buffer(pool::Pool, buffer::IOBuffer)
    seekstart(buffer)
    truncate(buffer, 0)

    put!(pool.channel, buffer)
    return
end

end
