module Server

using Sockets, MbedTLS, Dates, Logging
using Http2Frames, Http2Proto
using Http2Proto.Connection: H2Connection, receive_data!, send_headers, send_data, data_to_send, initiate_connection!
using Http2Proto.Config: H2Config
using Http2Proto.Events

include("integrations/Routing.jl"); using .Routing
include("integrations/tls.jl");      using .H2TLSIntegration

# ============= THREAD-SAFE GLOBAL ROUTER =============
# One router **per thread** via `Threads.@spawn` partitioning
const ROUTERS = Vector{Routing.Router}()
function _router()
    tid = Threads.threadid()
    tid > length(ROUTERS) && resize!(ROUTERS, Threads.nthreads())
    if @inbounds ROUTERS[tid] === nothing
        @inbounds ROUTERS[tid] = setup_default_routes()
    end
    return @inbounds ROUTERS[tid]
end
set_router!(r::Routing.Router) = (ROUTERS[Threads.threadid()] = r)


const DEFAULT_CERT = expanduser("~/.mbedtls/cert.pem")
const DEFAULT_KEY  = expanduser("~/.mbedtls/key.pem")


struct ConnCtx
    socket::IO
    conn::H2Connection
    router::Routing.Router
end


"""
    start_secure_server(
        host::IPAddr, port::Int;
        threads::Int = Threads.nthreads(),
        backlog::Int = 1024,
        reuseaddr::Bool = true,
        cert_file = DEFAULT_CERT,
        key_file  = DEFAULT_KEY,
        alpn      = ["h2", "http/1.1"],
        kwargs...
    ) -> Vector{Task}

Start a **multi-threaded** HTTPS/HTTP-2 server that scales to **all cores**.

- `threads`: number of acceptor threads (default = all available).
- `backlog`: per-listener TCP backlog.
- Other kwargs forwarded to `tls_accept`.

Returns a vector of acceptor tasks so you can `wait.(tasks)` or schedule more.
"""

function start_secure_server(
        host::IPAddr, port::Int;
        threads::Int = Threads.nthreads(),
        backlog::Int = 1024,
        reuseaddr::Bool = true,
        cert_file = DEFAULT_CERT,
        key_file  = DEFAULT_KEY,
        alpn      = ["h2", "http/1.1"],
        kwargs...
    )

    # Pre-warm router pool
    resize!(ROUTERS, threads)
    for i in 1:threads
        ROUTERS[i] = setup_default_routes()
    end

    tcp = listen(host, port; backlog=backlog)
    @info Logging.Info "⚡ Concurrent HTTPS/2 server on https://$host:$port  ($threads acceptor threads)"

    tasks = map(1:threads) do _
        errormonitor(Threads.@spawn begin
            try
                while isopen(tcp)
                    sock = accept(tcp)
                    # One lightweight task per connection
                    Threads.@spawn handle_tcp(sock, cert_file, key_file, alpn; kwargs...)
                end
            catch e
                if e isa Base.IOError && e.code ∈ (Base.UV_ECONNABORTED, Base.UV_EBADF)
                    @info Logging.Info "Listener shutting down"
                else
                    @info Logging.Error "Acceptor error" exception=e
                end
            end
        end)
    end
    return tasks
end



function handle_tcp(tcp::TCPSocket, cert, key, alpn; kwargs...)
    peer = getpeername(tcp)
    try
        ssl = H2TLSIntegration.tls_accept(
            tcp; cert_file=cert, key_file=key, alpn_protocols=alpn, kwargs...
        )
        cfg   = H2Config(client_side=false)
        conn  = H2Connection(config=cfg)
        handle_http2(ConnCtx(ssl, conn, _router()))
    catch e
        @info Logging.Warn "TLS/handshake failed" peer exception=e
    finally
        close(tcp)
    end
end

function handle_http2(ctx::ConnCtx)
    cfg  = H2Config(client_side=false)
    conn = H2Connection(config=cfg)
    initiate_connection!(conn)
    flush_out(ctx.socket, conn)

    bodies   = Dict{Int,Vector{UInt8}}()
    requests = Dict{Int,Events.RequestReceived}()

    try
        while !eof(ctx.socket)
            buf = readavailable(ctx.socket)
            isempty(buf) && continue

            events = receive_data!(conn, buf)
            for ev in events
                handle_event!(ctx, ev, bodies, requests)
            end
            flush_out(ctx.socket, conn)
        end
    catch e
        if e isa EOFError || (e isa Base.IOError && e.code == Base.UV_ECONNRESET)
            @info Logging.Info "Connection closed by peer"
        else
            @info Logging.Error "Connection error" exception=e
        end
    end
end

function flush_out(sock, conn)
    bytes = data_to_send(conn)
    isempty(bytes) && return
    write(sock, bytes)
    flush(sock)
end

function get_header(headers::Vector{Pair{String,String}}, key::String, default="")
    for (k, v) in headers
        k == key && return v
    end
    return default
end

handle_event!(ctx::ConnCtx, ev::Events.RequestReceived, b, r) = (r[ev.stream_id] = ev; maybe_handle(ctx, ev.stream_id, b, r))
handle_event!(ctx::ConnCtx, ev::Events.DataReceived,     b, r) = (append!(get!(b, ev.stream_id, UInt8[]), ev.data); maybe_handle(ctx, ev.stream_id, b, r))
handle_event!(ctx::ConnCtx, ev::Events.StreamEnded,      b, r) = maybe_handle(ctx, ev.stream_id, b, r)
handle_event!(::ConnCtx, _, _, _) = nothing   # ignore the rest

function maybe_handle(ctx::ConnCtx, sid, bodies, requests)
    haskey(requests, sid) || return
    req  = requests[sid]
    body = get(bodies, sid, UInt8[])
    if req_is_complete(req, body)
        Routing.handle_request(ctx.router, ctx.conn, req, ctx.socket, body)
        delete!(bodies, sid)
        delete!(requests, sid)
    end
end

req_is_complete(req, body) =
    lowercase(get_header(req.headers, ":method", "")) ∉ ("post","put","patch") || !isempty(body)


function setup_default_routes()
    router = Routing.start_router()
    Routing.use_middleware!(router, Routing.cors_middleware)

    Routing.@get router "/simple" function(ctx)
        Routing.text_response!(ctx, "Γειά σου, κόσμε! Απάντηση στο stream $(ctx.request.stream_id).")
    end

    Routing.@get router "/json" function(ctx)
        data = Dict(
            "message" => "Hello from Julia H2 server!",
            "stream_id" => ctx.request.stream_id,
            "timestamp" => string(now())
        )
        Routing.json_response!(ctx, data)
    end

    Routing.@get router "/users/:id" function(ctx)
        user_id = ctx.request.path_params["id"]
        data = Dict(
            "user_id" => user_id,
            "name" => "User $user_id",
            "stream_id" => ctx.request.stream_id
        )
        Routing.json_response!(ctx, data)
    end

    Routing.@post router "/users" function(ctx)
        try
            user_data = Routing.get_json_body(ctx.request)
            response_data = Dict(
                "message" => "User created successfully",
                "user_data" => user_data,
                "stream_id" => ctx.request.stream_id
            )
            Routing.json_response!(ctx, response_data, 201)
        catch e
            Routing.json_response!(ctx, Dict("error" => "Invalid request body"), 400)
        end
    end

    Routing.@get router "/echo-headers" function(ctx)
        headers_to_echo = Dict(
            h.first => h.second for h in ctx.request.headers if !startswith(h.first, ":")
        )
        Routing.json_response!(ctx, Dict("received_headers" => headers_to_echo))
    end

    Routing.@put router "/update/:id" function(ctx)
        item_id = ctx.request.path_params["id"]
        update_data = Routing.get_json_body(ctx.request)
        Routing.json_response!(ctx, Dict(
            "message" => "Item $item_id updated",
            "update_data" => update_data,
            "stream_id" => ctx.request.stream_id
        ))
    end

    Routing.@delete router "/items/:id" function(ctx)
        item_id = ctx.request.path_params["id"]
        Routing.text_response!(ctx, "Item $item_id deleted", 204)
    end

    return router
end

end # module