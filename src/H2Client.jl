module H2Client

using Sockets, MbedTLS, HPACK, H2Frames
using Base: @lock
using Base.Threads: @spawn
using ..Exc,..H2Settings, ..H2Types, ..Connection, ..H2TLSIntegration, ..Streams
using ..H2Types: ConnectionRole, CLIENT, ConnectionState
using ..Exc: CANCEL, StreamError, ProtocolError, StreamLimitError

export
    HTTP2Client,
    connect,
    request,
    close

"""
    HTTP2Client

A client object for managing an HTTP/2 connection.
Holds the underlying `HTTP2Connection` and provides methods for sending requests, closing, and pinging the server.
"""
mutable struct HTTP2Client
    conn::HTTP2Connection
end

"""
    connect(host, port; is_tls=true, timeout=10.0, kwargs...) -> HTTP2Client

Establish a new HTTP/2 client connection to the given `host` and `port`.

Arguments:
- `host::String`: The server hostname or IP address.
- `port::Int64`: The server port.

Keyword Arguments:
- `is_tls::Bool=true`: Use TLS (HTTPS) if true, plain TCP if false.
- `timeout::Float64=10.0`: Timeout in seconds for the HTTP/2 handshake.
- `verify_peer::Bool=false`: Whether to verify the server's TLS certificate (default: false for testing).
- `kwargs...`: Additional keyword arguments passed to the TLS or socket layer.

Returns:
- `HTTP2Client`: A client object ready to send requests.

Throws:
- `ErrorException` if the handshake times out or connection fails.
"""
function connect(host::String, port::Int64; is_tls=true, timeout=10.0,max_concurrent_streams::Union{Integer, Nothing}=nothing,
                 initial_window_size::Union{Integer, Nothing}=nothing,
                 max_frame_size::Union{Integer, Nothing}=nothing,
                 # Keep the original for advanced use
                 settings::Union{HTTP2Settings, Nothing}=nothing, 
                 kwargs...)

    local socket::IO
    
    if is_tls
        socket = H2TLSIntegration.tls_connect(host, port; verify_peer=get(kwargs, :verify_peer, false))
    else
        socket = Sockets.connect(host, port)
    end

    local client_settings::HTTP2Settings
    if settings !== nothing
        client_settings = settings
    else
        client_settings = H2Settings.create_client_settings()
    end

    if max_concurrent_streams !== nothing; client_settings.max_concurrent_streams = UInt32(max_concurrent_streams); end
    if initial_window_size !== nothing; client_settings.initial_window_size = UInt32(initial_window_size); end
    if max_frame_size !== nothing; client_settings.max_frame_size = UInt32(max_frame_size); end

    @info "Client: Connecting to $host:$port (TLS: $is_tls)"
    
    conn = HTTP2Connection(socket, CLIENT, client_settings, host, port)
    
    Connection.start_connection_loops!(conn)
    send_preface!(conn)
    ensure_connection_ready(conn; timeout=timeout)
    
    return HTTP2Client(conn)
end

"""
    ensure_connection_ready(conn::HTTP2Connection; timeout=10.0)

Wait until the HTTP/2 connection preface is received, or throw on timeout.

Arguments:
- `conn::HTTP2Connection`: The connection to check.
- `timeout::Float64`: Maximum time to wait in seconds.

Throws:
- `ErrorException` if the handshake does not complete in time.
"""
function ensure_connection_ready(conn::HTTP2Connection; timeout=10.0)
    start_time = time()
    while (time() - start_time) < timeout
        @lock conn.state_lock begin
            # Check if the preface has been received
            if conn.preface_received
                return # Success!
            end
        end
        # Don't hold the lock while sleeping
        sleep(0.01)
    end
    
    # If the loop finishes, we have timed out
    close_connection!(conn, :PROTOCOL_ERROR, "Handshake timeout")
    throw(ErrorException("HTTP/2 connection handshake timeout after $(timeout)s"))
end

"""
    request(client::HTTP2Client, method::String, path::String; headers=[], body=nothing, timeout=30.0) -> HTTP2Response

Send an HTTP/2 request and wait for the response.

Arguments:
- `client::HTTP2Client`: The client object.
- `method::String`: HTTP method (e.g. "GET", "POST").
- `path::String`: The request path (e.g. "/api").
- `timeout::Float64`: Time in seconds to wait for the full response before throwing a timeout error. A value of 0 means no timeout.

Keyword Arguments:
- `headers::Vector{Pair{String,String}}=[]`: Additional request headers.
- `body::Union{Vector{UInt8},Nothing}=nothing`: Optional request body.

Returns:
- `HTTP2Response`: The server's response, including status, headers, and body.

Throws:
- `ProtocolError` if the connection is shutting down.
- `StreamError` if the stream is reset by the peer.
"""

function request(client::HTTP2Client, method::String, path::String;
                 headers::Vector{Pair{String,String}} = Pair{String,String}[],
                 body::Union{Vector{UInt8}, IO, Nothing} = nothing,
                 timeout::Float64 = 30.0)
    conn = client.conn

    @lock conn.state_lock begin
        if conn.goaway_received
            throw(ProtocolError("Cannot send new request; GOAWAY received from peer."))
        end
    end

    ensure_connection_ready(conn)
   
    stream = Streams.open_stream!(conn.multiplexer)
    
    function cleanup_on_timeout()
        if is_active(stream)
            @warn "[Client] Request for stream $(stream.id) timed out after $(timeout)s."
            Streams.mux_close_stream!(conn.multiplexer, stream.id, :CANCEL)
        end
    end

    request_timer = timeout > 0 ? Timer(_ -> cleanup_on_timeout(), timeout) : nothing

    try
        scheme = isa(conn.socket, MbedTLS.SSLContext) ? "https" : "http"
        all_headers = [
            ":method" => method,
            ":scheme" => scheme,
            ":authority" => conn.host,
            ":path" => path
        ]
        append!(all_headers, headers)
        
        send_headers!(stream, all_headers; end_stream=isnothing(body))

        if body isa Vector{UInt8}
            send_data!(stream, body; end_stream=true)
        elseif body isa IO
            @info "[Client] Streaming request body for stream $(stream.id)"
            
            buffer_size = Int(conn.remote_settings.max_frame_size)
            
            while !eof(body)
                chunk = read(body, buffer_size)
                is_last_chunk = eof(body)
                send_data!(stream, chunk; end_stream=is_last_chunk)
            end
        end
      
        resp_headers = wait_for_headers(stream) 

        # The stream might have been closed by the timeout
        if !is_active(stream) && isempty(resp_headers)
            throw(StreamError(CANCEL, "Request timed out or was reset by peer.", stream.id))
        end

        resp_body = wait_for_body(stream)
        status_str = get(Dict(resp_headers), ":status", "0")
        
        return HTTP2Response(
            parse(Int, status_str),
            filter(h -> !startswith(h.first, ":"), resp_headers),
            resp_body
        )
    finally
        # Always ensure the timer is closed
        if request_timer !== nothing
            # Correction 2: More idiomatic close.
            Base.close(request_timer)
        end
    end
end

"""
    close(client::HTTP2Client)

Gracefully close the HTTP/2 client connection.
If the connection is already closed, does nothing.
"""
function close(client::HTTP2Client)
    if client.conn.state != CONNECTION_CLOSED
        close_connection!(client.conn)
    end
end

"""
    ping(client::HTTP2Client; timeout=10.0) -> Float64

Send a PING frame to the server and wait for the acknowledgment.
Returns the round-trip time (RTT) in seconds.

Arguments:
- `client::HTTP2Client`: The client object.
- `timeout::Float64=10.0`: Timeout in seconds to wait for the PING ACK.

Returns:
- `Float64`: The measured RTT in seconds.

Throws:
- `ErrorException` if the connection is not open or the PING times out.
"""
function ping(client::HTTP2Client; timeout::Float64=10.0)
    conn = client.conn
    if !is_open(conn)
        error("Connection is not open")
    end

    ping_id = rand(UInt64)
    response_channel = Channel{Float64}(1)

    @lock conn.pings_lock begin
        conn.pending_pings[ping_id] = (time(), response_channel)
    end

    ping_frame = PingFrame(ping_id)
    send_frame_on_stream(conn.multiplexer, UInt32(0), ping_frame)
    @info "[Client] Sent PING with id: $ping_id"

    status = timedwait(() -> isready(response_channel), timeout)

    if status == :timeout
        @lock conn.pings_lock begin
            pop!(conn.pending_pings, ping_id, nothing)
        end
        throw(ErrorException("PING timed out after $timeout seconds."))
    end

    rtt = take!(response_channel)
    
    @lock conn.pings_lock begin
        pop!(conn.pending_pings, ping_id, nothing)
    end

    return rtt
end

"""
    build_response(stream::HTTP2Stream) -> HTTP2Response

Build an `HTTP2Response` object from the stream's state.
Waits for headers and body to be available.

Arguments:
- `stream::HTTP2Stream`: The stream to read from.

Returns:
- `HTTP2Response`: The constructed response object.
"""
function build_response(stream::HTTP2Stream)
    headers = wait_for_headers(stream)
    body = wait_for_body(stream)
    status = parse(Int, get(headers, ":status", "0"))
    filtered_headers = filter(h -> !startswith(h.first, ":"), headers)
    return HTTP2Response(
        status = status,
        headers = filtered_headers,
        body = body,
        stream_id = stream.id
    )
end

"""
    build_request(method::String, scheme::String, authority::String, path::String;
                  headers=[], body=nothing) -> HTTP2Request

Construct an HTTP/2 request object with pseudo-headers and user headers.

Arguments:
- `method::String`: HTTP method (e.g. "GET").
- `scheme::String`: URI scheme ("http" or "https").
- `authority::String`: Host and port (e.g. "localhost:8000").
- `path::String`: Request path (e.g. "/api").

Keyword Arguments:
- `headers::Vector{Pair{String, String}}=[]`: Additional headers.
- `body::Union{Vector{UInt8}, String, Nothing}=nothing`: Optional request body.

Returns:
- `HTTP2Request`: The constructed request object.
"""
function build_request(method::String, scheme::String, authority::String, path::String;
                       headers::Vector{Pair{String, String}} = Pair{String, String}[],
                       body::Union{Vector{UInt8}, String, Nothing} = nothing)
    pseudo_headers = [
        ":method" => method,
        ":scheme" => scheme,
        ":authority" => authority,
        ":path" => path
    ]
    all_headers = vcat(pseudo_headers, headers)
    return HTTP2Request(method, scheme, authority, path, all_headers, body)
end


end # module