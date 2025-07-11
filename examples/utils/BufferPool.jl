# src/utils/BufferPool.jl

module BufferPool

using Base.Threads

export Pool, get_buffer, release_buffer


struct Pool
    channel::Channel{IOBuffer}
    buffer_size::Int
end

function Pool(max_size::Int = 100, buffer_size::Int = 16384) # 16KB default
    pool = Pool(Channel{IOBuffer}(max_size), buffer_size)
    for _ in 1:div(max_size, 2)
        put!(pool.channel, IOBuffer(sizehint=buffer_size))
    end
    return pool
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
