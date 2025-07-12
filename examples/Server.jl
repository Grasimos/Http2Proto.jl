module Server

using Sockets
using Logging

# Import the necessary modules and types
using H2.Connection: H2Connection, receive_data!, send_headers, send_data, data_to_send, initiate_connection!
using H2.Config: H2Config
using H2.Events
using H2Frames

include("integrations/tls.jl")
using .H2TLSIntegration

const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

"""
    start_secure_server(host::IPAddr, port::Int; ready_channel=nothing)
"""
function start_secure_server(host::IPAddr, port::Int; ready_channel=nothing)
    cert_file = expanduser("~/.mbedtls/cert.pem")
    key_file = expanduser("~/.mbedtls/key.pem")

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
"""
function handle_http2_connection(socket::IO)
    @info "Starting HTTP/2 protocol handling."

    # Create server-side H2Connection with proper config
    config = H2Config(client_side=false)
    conn = H2Connection(config=config)
    initiate_connection!(conn)
    initial_data = data_to_send(conn)
    if !isempty(initial_data)
        write(socket, initial_data)
        @debug "Sent initial SETTINGS frame."
    end

    try
        while !eof(socket)
            incoming_data = readavailable(socket)
            if isempty(incoming_data)
                sleep(0.01) 
                continue
            end
            @debug "Received $(length(incoming_data)) bytes from peer."

            events = receive_data!(conn, incoming_data)
            @debug "Processed $(length(events)) events."

            for event in events
                handle_event(conn, event, socket)
            end

            bytes_to_send = data_to_send(conn)
            if !isempty(bytes_to_send)
                @debug "Sending $(length(bytes_to_send)) bytes to peer."
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
    handle_event(conn::H2Connection, event::Events.Event, socket::IO)

Η συνάρτηση αυτή είναι ο "dispatcher". Παίρνει ένα event και αποφασίζει
τι θα κάνει η εφαρμογή μας. Εδώ είναι η "επιχειρησιακή λογική".
"""
function handle_event(conn::H2Connection, event::Events.Event, socket::IO)
    @info "Handling event: $(typeof(event))"
    _handle(conn, event, socket)
end

function _handle(conn, event, socket)
    @warn "No handler for event $(typeof(event))"
end

function _handle(conn::H2Connection, event::Events.RequestReceived, socket::IO)
    @info "Received request on stream $(event.stream_id): $(event.headers)"

    # Extract request path for routing
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
        "server" => "Julia-H2-Refactored"
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
end

function _handle(conn::H2Connection, event::Events.DataReceived, socket::IO)
    @info "Received $(length(event.data)) bytes of data on stream $(event.stream_id)."
    # Handle request body data if needed
    # For POST/PUT requests, accumulate the data and process when stream ends
end

function _handle(conn::H2Connection, event::Events.StreamEnded, socket::IO)
    @info "Stream $(event.stream_id) ended by peer."
    # Clean up any stream-specific resources
end

function _handle(conn::H2Connection, event::Events.SettingsChanged, socket::IO)
    @info "Settings changed: $(event.changed_settings)"
    # Settings are automatically acknowledged by the H2Connection
end

function _handle(conn::H2Connection, event::Events.PriorityChanged, socket::IO)
    @info "Priority changed for stream $(event.stream_id)"
    # Handle priority changes if needed for scheduling
end

function _handle(conn::H2Connection, event::Events.StreamReset, socket::IO)
    @info "Stream $(event.stream_id) reset with error code $(event.error_code)"
    # Clean up any resources for the reset stream
end

function _handle(conn::H2Connection, event::Events.PingReceived, socket::IO)
    @debug "Received PING with data: $(event.data)"
    # PING responses are handled automatically by H2Connection
end

function _handle(conn::H2Connection, event::Events.ConnectionTerminated, socket::IO)
    @info "Connection terminated: last_stream_id=$(event.last_stream_id), error_code=$(event.error_code)"
    # Clean up connection resources
end

function _handle(conn::H2Connection, event::Events.H2CUpgradeReceived, socket::IO)
    @info "HTTP/1.1 to HTTP/2 upgrade received"
    # Handle h2c upgrade 
end

function _handle(conn::H2Connection, event::Events.WindowUpdated, socket::IO)
    @info "Window Updated!"
    # Handle window update 
end

end