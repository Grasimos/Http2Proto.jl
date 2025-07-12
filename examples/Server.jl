
module Server

using Sockets
using Logging
using H2Frames
using MbedTLS
using Dates

using H2
using H2.Connection: H2Connection, receive_data!, send_headers, send_data, data_to_send, initiate_connection!
using H2.Config: H2Config
using H2.Events


include("integrations/Routing.jl")
using .Routing

include("integrations/tls.jl")
using .H2TLSIntegration

const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# Global router instance
const GLOBAL_ROUTER = Ref{Union{Routing.Router, Nothing}}(nothing)

"""
    set_router!(router::Routing.Router)

Set the global router instance for the server.
"""
function set_router!(router::Routing.Router)
    GLOBAL_ROUTER[] = router
end

"""
    get_router() -> Union{Routing.Router, Nothing}

Get the current global router instance.
"""
function get_router()
    return GLOBAL_ROUTER[]
end

"""
    start_secure_server(host::IPAddr, port::Int; ready_channel=nothing, router=nothing)

Start a secure HTTP/2 server with optional router.
"""
function start_secure_server(host::IPAddr, port::Int; ready_channel=nothing, router=nothing)
    cert_file = expanduser("~/.mbedtls/cert.pem")
    key_file = expanduser("~/.mbedtls/key.pem")

    if router !== nothing
        set_router!(router)
    elseif GLOBAL_ROUTER[] === nothing
        default_router = setup_default_routes()
        set_router!(default_router)
    end

    @info "✅ Secure Server is starting on https://$host:$port"

    server_task = errormonitor(@async begin
        tcp_server = listen(host, port)
        !isnothing(ready_channel) && put!(ready_channel, tcp_server)

        while isopen(tcp_server)
            try
                tcp_sock = accept(tcp_server)
                @info "Accepted new connection from $(getpeername(tcp_sock))"

                errormonitor(@async begin
                    try
                        ssl_socket = H2TLSIntegration.tls_accept(tcp_sock; cert_file=cert_file, key_file=key_file)
                        handle_http2_connection(ssl_socket)
                    catch e
                        @error "Error during TLS handshake or connection handling: $e"
                    finally
                        !isopen(tcp_sock) || close(tcp_sock)
                    end
                end)
            catch ex
                if ex isa Base.IOError && (ex.code == Base.UV_ECONNABORTED || ex.code == Base.UV_EBADF)
                    @info "Server shutting down."
                    break
                else
                    @error "Server Accept Error: $ex"
                    rethrow()
                end
            end
        end
        @info "👋 Server has shut down."
    end)
    return server_task
end

"""
    handle_http2_connection(socket::IO)

Handle HTTP/2 protocol communication with integrated routing.
"""
function handle_http2_connection(socket::IO)
    @info "Starting HTTP/2 protocol handling."

    config = H2Config(;client_side=false)
    conn = H2Connection(config=config)
    initiate_connection!(conn)
    initial_data = data_to_send(conn)
    if !isempty(initial_data)
        write(socket, initial_data)
        flush(socket)
        @info "Sent initial SETTINGS frame."
    end

    original_requests = Dict{Int, Events.RequestReceived}()
    request_bodies = Dict{Int, Vector{UInt8}}()

    try
        while !eof(socket)
            incoming_data = readavailable(socket)
            if isempty(incoming_data)
                sleep(0.01)
                continue
            end
            @info "Received $(length(incoming_data)) bytes from peer."

            events = receive_data!(conn, incoming_data)
            @info "Processed $(length(events)) events."

            for event in events
                handle_event(conn, event, socket, request_bodies, original_requests) 
            end


            bytes_to_send = data_to_send(conn)
            if !isempty(bytes_to_send)
                @info "Sending $(length(bytes_to_send)) bytes to peer."
                write(socket, bytes_to_send)
            end
        end
    catch e
        if e isa EOFError || (e isa Base.IOError && e.code == Base.UV_ECONNRESET)
            @info "Connection closed by peer."
        else
            @error "Connection error: $e"
            showerror(stdout, e, catch_backtrace())
        end
    finally
        close(socket)
        @info "Connection handling finished."
    end
end

"""
    handle_event(conn::H2Connection, event::Events.Event, socket::IO, request_bodies::Dict{Int, Vector{UInt8}})

Enhanced event dispatcher with routing support.
"""
function handle_event(conn::H2Connection, event::Events.Event, socket::IO, 
                      request_bodies::Dict{Int, Vector{UInt8}}, 
                      original_requests::Dict{Int, Events.RequestReceived}) 
    @info "Handling event: $(typeof(event))"
    _handle(conn, event, socket, request_bodies, original_requests) 
end

function _handle(conn, event, socket, request_bodies, original_requests) 
    @warn "No handler for event $(typeof(event))"
end

function _handle(conn::H2Connection, event::Events.RequestReceived, socket::IO, 
                 request_bodies::Dict{Int, Vector{UInt8}}, 
                 original_requests::Dict{Int, Events.RequestReceived})
    @info "Received request on stream $(event.stream_id): $(event.headers)"
    
    router = get_router()
    if router !== nothing
        request_bodies[event.stream_id] = UInt8[]
        original_requests[event.stream_id] = event 
        
        method = ""
        for (name, value) in event.headers
            if name == ":method"
                method = value
                break
            end
        end
        
        if method in ["GET", "HEAD", "OPTIONS", "DELETE"]
            body = get(request_bodies, event.stream_id, UInt8[])
            Routing.handle_request(router, conn, event, socket, body) 
            delete!(request_bodies, event.stream_id)
            delete!(original_requests, event.stream_id) 
        end
        # For POST, PUT, PATCH, etc., wait for body data or stream end
    else
        fallback_request_handler(conn, event, socket)
    end
end

function _handle(conn::H2Connection, event::Events.StreamEnded, socket::IO, 
                 request_bodies::Dict{Int, Vector{UInt8}}, 
                 original_requests::Dict{Int, Events.RequestReceived}) 
    @info "Stream $(event.stream_id) ended by peer."
    
    router = get_router()
    if router !== nothing && haskey(request_bodies, event.stream_id)
        if haskey(original_requests, event.stream_id)
            original_request_event = original_requests[event.stream_id]
            body = request_bodies[event.stream_id]
            
            Routing.handle_request(router, conn, original_request_event, socket, body)
            
            delete!(original_requests, event.stream_id)
        else
            @warn "StreamEnded for stream $(event.stream_id) but no original RequestReceived event found!"
            #TODO: send an RST_STREAM?
        end
        delete!(request_bodies, event.stream_id) 
    end
end

function _handle(conn::H2Connection, event::Events.DataReceived, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Received $(length(event.data)) bytes of data on stream $(event.stream_id)."
    if haskey(request_bodies, event.stream_id)
        append!(request_bodies[event.stream_id], event.data)
    else
        request_bodies[event.stream_id] = copy(event.data)
    end
end

function _handle(conn::H2Connection, event::Events.SettingsChanged, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Settings changed: $(event.changed_settings)"
end

function _handle(conn::H2Connection, event::Events.PriorityChanged, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Priority changed for stream $(event.stream_id)"
end

function _handle(conn::H2Connection, event::Events.StreamReset, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Stream $(event.stream_id) reset with error code $(event.error_code)"
    delete!(request_bodies, event.stream_id)
    delete!(original_requests, event.stream_id) 
end

function _handle(conn::H2Connection, event::Events.PingReceived, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Received PING with data: $(event.data)"
    Routing.handle_ping(conn, event, socket)
end

function _handle(conn::H2Connection, event::Events.ConnectionTerminated, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "Connection terminated: last_stream_id=$(event.last_stream_id), error_code=$(event.error_code)"
    empty!(request_bodies)
    empty!(original_requests) 
end

function _handle(conn::H2Connection, event::Events.H2CUpgradeReceived, socket::IO, request_bodies::Dict{Int, Vector{UInt8}}, original_requests::Dict{Int, Events.RequestReceived})
    @info "HTTP/1.1 to HTTP/2 upgrade received"
    Routing.handle_upgrade(conn, event, socket)
end

function _handle(conn::H2.Connection.H2Connection, event::H2.Events.WindowUpdated, socket::MbedTLS.SSLContext, request_bodies::Dict{Int64, Vector{UInt8}}, original_requests::Dict{Int64, H2.Events.RequestReceived})
    @info "Window Updated!"
end
"""
    fallback_request_handler(conn::H2Connection, event::Events.RequestReceived, socket::IO)

Fallback request handler when no router is configured.
"""
function fallback_request_handler(conn::H2Connection, event::Events.RequestReceived, socket::IO)
    path = ""
    for (name, value) in event.headers
        if name == ":path"
            path = value
            break
        end
    end

    response_headers = [
        ":status" => "200",
        "content-type" => "text/plain; charset=utf-8",
        "server" => "Julia-H2-Server"
    ]
    
    response_body = if path == "/simple"
        "Γειά σου, κόσμε! Απάντηση στο stream $(event.stream_id)."
    elseif path == "/json"
        response_headers[2] = "content-type" => "application/json"
        """{"message": "Hello from Julia H2 server!", "stream_id": $(event.stream_id)}"""
    else
        response_headers[1] = ":status" => "404"
        "Not Found: $(path)"
    end

    send_headers(conn, event.stream_id, response_headers)
    send_data(conn, event.stream_id, Vector{UInt8}(response_body), end_stream=true)
    bytes_to_send = data_to_send(conn)
    if !isempty(bytes_to_send)
        write(socket, bytes_to_send)
        flush(socket)
    end
end

"""
    setup_default_routes() -> Routing.Router

Create a default router with basic routes for demonstration.
"""
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
            @error "Error parsing request body for /users POST: $e"
            Routing.json_response!(ctx, Dict("error" => "Invalid request body or internal server error"), 400)
        end
    end

    Routing.@get router "/echo-headers" function(ctx)
        headers_to_echo = Dict(
            header.first => header.second
            for header in ctx.request.headers
            if !startswith(header.first, ":")
        )
        Routing.json_response!(ctx, Dict("received_headers" => headers_to_echo), 200)
    end

    Routing.@put router "/update/:id" function(ctx)
        item_id = ctx.request.path_params["id"]
        try
            update_data = Routing.get_json_body(ctx.request)
            response_data = Dict(
                "message" => "Item $item_id updated",
                "update_data" => update_data,
                "stream_id" => ctx.request.stream_id
            )
            Routing.json_response!(ctx, response_data)
        catch e
            @error "Error updating item $item_id: $e"
            Routing.json_response!(ctx, Dict("error" => "Failed to update item", "details" => string(e)), 400)
        end
    end

    Routing.@delete router "/items/:id" function(ctx)
        item_id = ctx.request.path_params["id"]
        @info "Attempting to delete item with ID: $item_id"
        Routing.text_response!(ctx, "Item $item_id deleted successfully", 204)
    end

    return router
end

end
