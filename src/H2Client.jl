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

mutable struct HTTP2Client
    conn::HTTP2Connection
end

"""
    connect(host, port; ...) -> HTTP2Client
"""
function connect(host::String, port::Int64; is_tls=true, timeout=10.0, kwargs...)
    local socket::IO
    
    if is_tls
        socket = H2TLSIntegration.tls_connect(host, port; verify_peer=get(kwargs, :verify_peer, false))
    else
        socket = Sockets.connect(host, port)
    end
    
    settings = H2Settings.create_client_settings()
    @info "Client: Connecting to $host:$port (TLS: $is_tls)"
    
    conn = HTTP2Connection(socket, CLIENT, settings, host, port)
    
    Connection.start_connection_loops!(conn)
    send_preface!(conn)
    ensure_connection_ready(conn; timeout=timeout)
    
    return HTTP2Client(conn)
end

function ensure_connection_ready(conn::HTTP2Connection; timeout=10.0)
    @lock conn.lock begin
        if conn.preface_received
            return
        end
        status = timedwait(() -> conn.preface_received, timeout)
        if status == :timeout
            close_connection!(conn, :PROTOCOL_ERROR, "Handshake timeout")
            throw(ErrorException("HTTP/2 connection handshake timeout after $(timeout)s"))
        end
    end
end

function request(client::HTTP2Client, method::String, path::String;
                 headers::Vector{Pair{String,String}} = Pair{String,String}[],
                 body::Union{Vector{UInt8},Nothing} = nothing)
    conn = client.conn

    @lock conn.lock begin
        if conn.goaway_received
            throw(ProtocolError("Cannot send new request; GOAWAY received from peer."))
        end
    end

    ensure_connection_ready(conn)
    stream = Streams.open_stream!(conn.multiplexer)
    scheme = isa(conn.socket, MbedTLS.SSLContext) ? "https" : "http"
    all_headers = [
        ":method" => method,
        ":scheme" => scheme,
        ":authority" => conn.host,
        ":path" => path
    ]
    append!(all_headers, headers)
    send_headers!(stream, all_headers; end_stream = isnothing(body))
    if !isnothing(body)
        send_data!(stream, body; end_stream = true)
    end
    resp_headers = wait_for_headers(stream)
    if !is_active(stream) && isempty(resp_headers)
        # Απλώς περνάμε το Symbol 'CANCEL' απευθείας.
        throw(StreamError(CANCEL, "Stream was reset by the peer.", stream.id))
    end
    resp_body = wait_for_body(stream)
    status_str = get(Dict(resp_headers), ":status", "0")
    return HTTP2Response(
        parse(Int, status_str),
        filter(h -> !startswith(h.first, ":"), resp_headers),
        resp_body
    )
end

function close(client::HTTP2Client)
    if client.conn.state != CONNECTION_CLOSED
        close_connection!(client.conn)
    end
end

"""
    ping(client::HTTP2Client; timeout=10.0) -> Float64

Sends a PING frame to the server and waits for the acknowledgment,
returning the round-trip time (RTT) in seconds.
Throws an error on timeout.
"""

function ping(client::HTTP2Client; timeout::Float64=10.0)
    conn = client.conn
    if !is_open(conn)
        error("Connection is not open")
    end

    ping_id = rand(UInt64)
    response_channel = Channel{Float64}(1)

    @lock conn.lock begin
        conn.pending_pings[ping_id] = (time(), response_channel)
    end

    ping_frame = PingFrame(ping_id)
    send_frame_on_stream(conn.multiplexer, UInt32(0), ping_frame)
    @info "[Client] Sent PING with id: $ping_id"

    status = timedwait(() -> isready(response_channel), timeout)

    if status == :timeout
        @lock conn.lock begin
            pop!(conn.pending_pings, ping_id, nothing)
        end
        throw(ErrorException("PING timed out after $timeout seconds."))
    end

    rtt = take!(response_channel)
    
    @lock conn.lock begin
        pop!(conn.pending_pings, ping_id, nothing)
    end

    return rtt
end

"""
    build_response(stream::HTTP2Stream) -> HTTP2Response

Build an HTTP2Response object from the stream's state.
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
                  headers::Vector{Pair{String, String}} = Pair{String, String}[],
                  body::Union{Vector{UInt8}, String, Nothing} = nothing) -> HTTP2Request

Construct an HTTP/2 request object with pseudo-headers and user headers.
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