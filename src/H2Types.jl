module H2Types

using HPACK
using H2Frames: HTTP2Frame, FrameHeader
using Dates
using DataStructures
using UUIDs

using ..Exc, ..H2Settings, ..RateLimiter

# ============================================================================
# EXPORTS
# ============================================================================

export AbstractHTTP2Connection, HTTP2Stream, StreamState, HTTP2Connection, ConnectionState, StreamMultiplexer,
       StreamPriority, HTTP2Request, HTTP2Response, ConnectionRole,
       CONNECTION_PREFACE, CONNECTION_STREAM_ID, FRAME_HEADER_SIZE, MAX_FRAME_SIZE_UPPER_BOUND, MAX_STREAM_ID, STREAM_ID_MASK,
       MAX_WINDOW_SIZE, PSEUDO_HEADERS, FORBIDDEN_HEADERS, DEFAULT_WEIGHT, MIN_WEIGHT, MAX_WEIGHT, ALPN_HTTP2, ALPN_HTTP2_CLEARTEXT,
       MAX_PADDING_LENGTH, MAX_PRIORITY_WEIGHT, MAX_PROMISED_STREAM_ID, PING_FRAME_SIZE, GOAWAY_FRAME_MIN_SIZE, WINDOW_UPDATE_FRAME_SIZE,
       PRIORITY_FRAME_SIZE, RST_STREAM_FRAME_SIZE, HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE, TLS_MIN_VERSION,
       REQUIRED_TLS_CIPHER_SUITES, DEFAULT_PING_TIMEOUT, DEFAULT_SETTINGS_TIMEOUT, DEFAULT_CONNECTION_TIMEOUT, MAX_HEADER_NAME_LENGTH,
       MAX_HEADER_VALUE_LENGTH, MAX_URI_LENGTH, PUSH_PROMISE_MIN_FRAME_SIZE, GOAWAY_LAST_STREAM_ID_MASK,
       CLIENT, SERVER, STREAM_IDLE, STREAM_RESERVED_LOCAL, STREAM_RESERVED_REMOTE, STREAM_OPEN, STREAM_HALF_CLOSED_LOCAL,
       STREAM_HALF_CLOSED_REMOTE, STREAM_CLOSED, CONNECTION_IDLE, CONNECTION_OPEN, CONNECTION_CLOSING, CONNECTION_CLOSED,
       CONNECTION_GOAWAY_SENT, CONNECTION_GOAWAY_RECEIVED, CleanupStream,
       generate_unique_client_id, set_client_connection_id!, get_client_connection_id, has_client_connection_id, debug_connection_info,
       priority_weight, get_stream, has_stream, next_stream_id!,
       is_client, is_server, is_idle, is_open, is_closing, is_closed, is_going_away, is_active

# ============================================================================
# HTTP/2 PROTOCOL CONSTANTS
# ============================================================================

"""HTTP/2 connection preface that must be sent by clients (RFC 7540, Section 3.5)"""
const CONNECTION_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

"""Stream ID 0 is reserved for connection-level frames"""
const CONNECTION_STREAM_ID = 0x0

# Frame size constants
"""Size of HTTP/2 frame header in bytes"""
const FRAME_HEADER_SIZE = 9

"""Maximum allowed frame payload size (2^24 - 1 bytes)"""
const MAX_FRAME_SIZE_UPPER_BOUND = 16777215

"""Maximum valid stream ID (2^31 - 1)"""
const MAX_STREAM_ID = 2147483647

"""Bitmask for extracting stream ID from frame header"""
const STREAM_ID_MASK = 0x7FFFFFFF

"""Maximum flow control window size (2^31 - 1)"""
const MAX_WINDOW_SIZE = 2147483647

# ============================================================================
# HTTP HEADER CONSTANTS
# ============================================================================

"""Set of HTTP/2 pseudo-headers that must be prefixed with ':'"""
const PSEUDO_HEADERS = Set([":method", ":scheme", ":authority", ":path", ":status"])

"""HTTP/1.1 headers that are forbidden in HTTP/2"""
const FORBIDDEN_HEADERS = Set(["connection", "upgrade", "http2-settings", "te", "transfer-encoding", "proxy-connection"])

# ============================================================================
# STREAM PRIORITY CONSTANTS
# ============================================================================

"""Default stream priority weight"""
const DEFAULT_WEIGHT = 16

"""Minimum stream priority weight"""
const MIN_WEIGHT = 1

"""Maximum stream priority weight"""
const MAX_WEIGHT = 256

# ============================================================================
# ALPN AND TLS CONSTANTS
# ============================================================================

"""HTTP/2 over TLS Application-Layer Protocol Negotiation identifier"""
const ALPN_HTTP2 = "h2"

"""HTTP/2 cleartext (without TLS) identifier"""
const ALPN_HTTP2_CLEARTEXT = "h2c"

"""Minimum required TLS version for HTTP/2"""
const TLS_MIN_VERSION = "TLSv1.2"

"""Required TLS cipher suites for HTTP/2 connections"""
const REQUIRED_TLS_CIPHER_SUITES = [
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384"
]

# ============================================================================
# FRAME SIZE CONSTANTS
# ============================================================================

"""Maximum padding length for padded frames"""
const MAX_PADDING_LENGTH = 255

"""Maximum priority weight value in priority frames"""
const MAX_PRIORITY_WEIGHT = 255

"""Maximum stream ID that can be promised in PUSH_PROMISE frames"""
const MAX_PROMISED_STREAM_ID = MAX_STREAM_ID

"""Fixed size of PING frame payload (8 bytes)"""
const PING_FRAME_SIZE = 8

"""Minimum size of GOAWAY frame payload"""
const GOAWAY_FRAME_MIN_SIZE = 8

"""Fixed size of WINDOW_UPDATE frame payload"""
const WINDOW_UPDATE_FRAME_SIZE = 4

"""Fixed size of PRIORITY frame payload"""
const PRIORITY_FRAME_SIZE = 5

"""Fixed size of RST_STREAM frame payload"""
const RST_STREAM_FRAME_SIZE = 4

"""Minimum size of PUSH_PROMISE frame payload"""
const PUSH_PROMISE_MIN_FRAME_SIZE = 4

"""Bitmask for extracting last stream ID from GOAWAY frame"""
const GOAWAY_LAST_STREAM_ID_MASK = 0x7fffffff

# ============================================================================
# HTTP STATUS CODES
# ============================================================================

"""HTTP 400 Bad Request status code"""
const HTTP_STATUS_BAD_REQUEST = 400

"""HTTP 431 Request Header Fields Too Large status code"""
const HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE = 431

# ============================================================================
# TIMEOUT CONSTANTS
# ============================================================================

"""Default timeout for PING frame responses (seconds)"""
const DEFAULT_PING_TIMEOUT = 60

"""Default timeout for SETTINGS frame acknowledgment (seconds)"""
const DEFAULT_SETTINGS_TIMEOUT = 10

"""Default general connection timeout (seconds)"""
const DEFAULT_CONNECTION_TIMEOUT = 300

# ============================================================================
# SIZE LIMIT CONSTANTS
# ============================================================================

"""Maximum allowed length of HTTP header names"""
const MAX_HEADER_NAME_LENGTH = 1024

"""Maximum allowed length of HTTP header values"""
const MAX_HEADER_VALUE_LENGTH = 8192

"""Maximum allowed length of URIs"""
const MAX_URI_LENGTH = 8192

# ============================================================================
# ENUMERATIONS
# ============================================================================

"""
Enumeration representing whether this connection is acting as a client or server.

# Values
- `CLIENT`: Connection is acting as a client
- `SERVER`: Connection is acting as a server
"""
@enum ConnectionRole CLIENT=0 SERVER=1

"""
Stream states as defined in RFC 7540, Section 5.1.

# Values
- `STREAM_IDLE`: Stream has not been used yet
- `STREAM_RESERVED_LOCAL`: Stream is reserved for local use
- `STREAM_RESERVED_REMOTE`: Stream is reserved for remote use  
- `STREAM_OPEN`: Stream is open for bidirectional communication
- `STREAM_HALF_CLOSED_LOCAL`: Local endpoint has sent END_STREAM
- `STREAM_HALF_CLOSED_REMOTE`: Remote endpoint has sent END_STREAM
- `STREAM_CLOSED`: Stream is completely closed
"""
@enum StreamState begin
    STREAM_IDLE
    STREAM_RESERVED_LOCAL
    STREAM_RESERVED_REMOTE
    STREAM_OPEN
    STREAM_HALF_CLOSED_LOCAL
    STREAM_HALF_CLOSED_REMOTE
    STREAM_CLOSED
end

"""
Connection states for HTTP/2 connections.

# Values
- `CONNECTION_IDLE`: Connection is not yet established
- `CONNECTION_OPEN`: Connection is active and ready for streams
- `CONNECTION_CLOSING`: Connection is in the process of closing
- `CONNECTION_CLOSED`: Connection is completely closed
- `CONNECTION_GOAWAY_SENT`: A GOAWAY frame has been sent
- `CONNECTION_GOAWAY_RECEIVED`: A GOAWAY frame has been received
"""
@enum ConnectionState begin
    CONNECTION_IDLE
    CONNECTION_OPEN
    CONNECTION_CLOSING
    CONNECTION_CLOSED
    CONNECTION_GOAWAY_SENT
    CONNECTION_GOAWAY_RECEIVED
end

# ============================================================================
# ABSTRACT TYPES
# ============================================================================

"""
Abstract base type for all HTTP/2 connection implementations.
"""
abstract type AbstractHTTP2Connection end

# ============================================================================
# REQUEST AND RESPONSE TYPES
# ============================================================================

"""
    HTTP2Request

Represents an HTTP/2 request with method, URI, headers, and body.

# Fields
- `method::String`: HTTP method (GET, POST, etc.)
- `uri::String`: Request URI
- `headers::Vector{Pair{String, String}}`: HTTP headers as name-value pairs
- `body::Vector{UInt8}`: Request body as bytes
- `stream_id::Int32`: Associated stream ID

# Constructor
    HTTP2Request(method, uri, headers=[], body=UInt8[], stream_id=0)

Creates a new HTTP/2 request with validation of stream ID bounds.
"""
struct HTTP2Request
    method::String
    uri::String
    headers::Vector{Pair{String, String}}
    body::Vector{UInt8}
    stream_id::Int32

    function HTTP2Request(method::String, uri::String,
                         headers::Vector{Pair{String, String}} = Pair{String, String}[],
                         body::Union{String, Vector{UInt8}} = UInt8[],
                         stream_id::Integer = 0)
        body_bytes = body isa String ? Vector{UInt8}(body) : body
        if stream_id < 0 || stream_id > MAX_STREAM_ID
            throw(StreamError("Stream ID $stream_id out of valid range [0, $MAX_STREAM_ID]"))
        end
        new(method, uri, headers, body_bytes, Int32(stream_id))
    end
end

"""
    HTTP2Response

Represents an HTTP/2 response with status code, headers, and body.

# Fields
- `status::Int`: HTTP status code (200, 404, etc.)
- `headers::Vector{Pair{String, String}}`: HTTP headers as name-value pairs
- `body::Vector{UInt8}`: Response body as bytes
- `stream_id::Int32`: Associated stream ID

# Constructor
    HTTP2Response(status, headers=[], body=UInt8[], stream_id=0)

Creates a new HTTP/2 response with validation of status code and stream ID.
"""
struct HTTP2Response
    status::Int
    headers::Vector{Pair{String, String}}
    body::Vector{UInt8}
    stream_id::Int32

    function HTTP2Response(status::Integer,
                          headers::Vector{Pair{String, String}} = Pair{String, String}[],
                          body::Union{String, Vector{UInt8}} = UInt8[],
                          stream_id::Integer = 0)
        body_bytes = body isa String ? Vector{UInt8}(body) : body
        if status < 100 || status > 599
            throw(ProtocolError("Invalid HTTP status code: $status"))
        end
        if stream_id < 0 || stream_id > MAX_STREAM_ID
            throw(StreamError("Stream ID $stream_id out of valid range [0, $MAX_STREAM_ID]"))
        end
        new(Int(status), headers, body_bytes, Int32(stream_id))
    end
end

# ============================================================================
# STREAM PRIORITY MANAGEMENT
# ============================================================================

"""
    StreamPriority

Represents stream priority information including dependency and weight.

# Fields
- `exclusive::Bool`: Whether this stream exclusively depends on parent
- `stream_dependency::Int32`: Stream ID this stream depends on
- `weight::UInt8`: Priority weight (internally stored as weight-1)

# Constructor
    StreamPriority(exclusive, stream_dependency, weight)

Creates stream priority with validation of weight and dependency bounds.

    StreamPriority()

Creates default priority (non-exclusive, no dependency, default weight).
"""
struct StreamPriority
    exclusive::Bool
    stream_dependency::Int32
    weight::UInt8

    function StreamPriority(exclusive::Bool, stream_dependency::Integer, weight::Integer)
        if weight < MIN_WEIGHT || weight > MAX_WEIGHT
            throw(PriorityError("Priority weight $weight not in valid range [$MIN_WEIGHT, $MAX_WEIGHT]", weight))
        end
        if stream_dependency < 0 || stream_dependency > MAX_STREAM_ID
            throw(PriorityError("Stream dependency $stream_dependency out of valid range [0, $MAX_STREAM_ID]", stream_dependency))
        end
        new(exclusive, Int32(stream_dependency), UInt8(weight - 1))
    end
end

"""Default priority constructor - non-exclusive, no dependency, default weight"""
StreamPriority() = StreamPriority(false, 0, DEFAULT_WEIGHT)

"""
    priority_weight(p::StreamPriority) -> Int

Get the actual priority weight (1-256) from a StreamPriority object.
"""
priority_weight(p::StreamPriority) = Int(p.weight) + 1

# ============================================================================
# STREAM MANAGEMENT
# ============================================================================

"""
Special message type used to instruct the send_loop to clean up a stream.
"""
struct CleanupStream end

"""
    HTTP2Stream <: IO

Represents an HTTP/2 stream with state management, flow control, and data buffering.
Implements the IO interface for reading stream data.

# Fields
- `id::UInt32`: Unique stream identifier
- `connection::AbstractHTTP2Connection`: Parent connection
- `state::StreamState`: Current stream state
- `receive_window::Int32`: Flow control receive window
- `send_window::Int32`: Flow control send window
- `parent::Union{HTTP2Stream, Nothing}`: Parent stream for dependencies
- `children::Vector{HTTP2Stream}`: Child streams depending on this stream
- `priority::StreamPriority`: Stream priority information
- `headers::Vector{Pair{String, String}}`: Received headers
- `data_buffer::IOBuffer`: Buffer for incoming data
- `end_stream_received::Bool`: Whether END_STREAM flag was received
- `end_stream_sent::Bool`: Whether END_STREAM flag was sent
- `created_at::DateTime`: Stream creation timestamp
- `last_activity::DateTime`: Last activity timestamp
- `buffer_lock::ReentrantLock`: Lock for thread-safe buffer access
- `data_available::Base.GenericCondition`: Condition for data availability
- `headers_available::Base.GenericCondition`: Condition for header availability
"""
mutable struct HTTP2Stream <: IO
    const lock::ReentrantLock 
    const id::UInt32
    const connection::AbstractHTTP2Connection
    state::StreamState
    receive_window::Int32
    send_window::Int32
    parent::Union{HTTP2Stream, Nothing}
    children::Vector{HTTP2Stream}
    priority::StreamPriority
    headers::Vector{Pair{String, String}}
    const data_buffer::IOBuffer
    end_stream_received::Bool
    end_stream_sent::Bool
    const created_at::DateTime
    last_activity::DateTime
    const buffer_lock::ReentrantLock
    const data_available::Base.GenericCondition{ReentrantLock}
    const headers_available::Base.GenericCondition{ReentrantLock}
end

"""
    StreamMultiplexer

Manages the set of active HTTP/2 streams for a connection, enforcing stream limits,
priorities, and correct stream opening/closing according to RFC 7540. Supports
concurrent frame transmission with stream prioritization.

# Fields
- `conn::AbstractHTTP2Connection`: Parent connection
- `frame_channels::Dict{UInt32, Channel}`: Per-stream frame channels
- `pending_streams::PriorityQueue{UInt32, Int}`: Queue of pending streams by priority
- `role::ConnectionRole`: Connection role (client or server)
- `next_stream_id::UInt32`: Next stream ID to assign
- `max_concurrent_streams::UInt32`: Maximum allowed concurrent streams
- `send_condition::Base.GenericCondition`: Condition for send synchronization
- `send_lock::ReentrantLock`: Lock for send operations
- `send_task::Union{Task, Nothing}`: Background send task
"""
mutable struct StreamMultiplexer
    conn::AbstractHTTP2Connection
    frame_channels::Dict{UInt32, Channel{Union{HTTP2Frame, CleanupStream}}}
    pending_streams::PriorityQueue{UInt32, Int}
    role::ConnectionRole
    next_stream_id::UInt32
    max_concurrent_streams::UInt32
    send_condition::Base.GenericCondition{ReentrantLock}
    send_lock::ReentrantLock
    send_task::Union{Task, Nothing}
end

# ============================================================================
# CONNECTION MANAGEMENT
# ============================================================================

"""
    HTTP2Connection <: AbstractHTTP2Connection

Main connection type that manages an HTTP/2 connection with full state tracking,
stream multiplexing, HPACK compression, and flow control.

# Constant Fields
- `id::String`: Unique connection identifier
- `socket::IO`: Underlying network socket
- `role::ConnectionRole`: Connection role (client or server)
- `settings::HTTP2Settings`: Local connection settings
- `streams::Dict{UInt32, HTTP2Stream}`: Active streams by ID
- `hpack_encoder::HPACKEncoder`: HPACK header compressor
- `hpack_decoder::HPACKDecoder`: HPACK header decompressor
- `frame_channel::Channel{HTTP2Frame}`: Channel for incoming frames
- `preface_handshake_done::Condition`: Condition for preface completion
- `header_buffer::IOBuffer`: Buffer for header processing

# Mutable Fields
- `host::String`: Remote host address
- `port::Int64`: Remote port number
- `state::ConnectionState`: Current connection state
- `remote_settings::HTTP2Settings`: Remote peer settings
- `last_stream_id::UInt32`: Last locally-initiated stream ID
- `last_peer_stream_id::UInt32`: Last peer-initiated stream ID
- `receive_window::Int32`: Connection-level receive window
- `send_window::Int32`: Connection-level send window
- `preface_sent::Bool`: Whether connection preface was sent
- `preface_received::Bool`: Whether connection preface was received
- `goaway_sent::Bool`: Whether GOAWAY frame was sent
- `goaway_received::Bool`: Whether GOAWAY frame was received
- `last_error::Union{Nothing, ConnectionError}`: Last connection error
- `continuation_stream_id::UInt32`: Stream ID for CONTINUATION frames
- `continuation_end_stream::Bool`: END_STREAM flag for CONTINUATION
- `lock::ReentrantLock`: Main connection lock
- `decoder_lock::ReentrantLock`: HPACK decoder lock
- `pending_pings::Dict{UInt64, Tuple{Float64, Channel{Float64}}}`: Pending PING frames
- `callbacks::Dict{Symbol, Function}`: Event callbacks
- `request_handler::Union{Any, Nothing}`: Request handler function
- `multiplexer::StreamMultiplexer`: Stream multiplexer
- `done_condition::Condition`: Condition for connection completion
- `client_connection_id::Union{String, Nothing}`: Client-specific connection ID
- `rate_limiter::TokenBucket`: Rate limiter for connection
"""
mutable struct HTTP2Connection <: AbstractHTTP2Connection
    # Constant fields
    const id::String
    const socket::IO
    const role::ConnectionRole
    const settings::HTTP2Settings
    const streams::Dict{UInt32, HTTP2Stream}
    const hpack_encoder::HPACKEncoder
    const hpack_decoder::HPACKDecoder
    const frame_channel::Channel{HTTP2Frame}
    const preface_handshake_done::Condition
    const header_buffer::IOBuffer

    # Mutable fields
    host::String
    port::Int64
    state::ConnectionState
    remote_settings::HTTP2Settings
    last_stream_id::UInt32
    last_peer_stream_id::UInt32
    receive_window::Int32
    send_window::Int32
    preface_sent::Bool
    preface_received::Bool
    goaway_sent::Bool
    goaway_received::Bool
    last_error::Union{Nothing, ConnectionError}
    continuation_stream_id::UInt32
    continuation_end_stream::Bool
    pending_push_promise_id::UInt32
  # --- New Granular Locks ---
    state_lock::ReentrantLock           # Protects connection state (state, goaway_sent, etc.)
    streams_lock::ReentrantLock         # Protects the streams dictionary and stream IDs
    flow_control_lock::ReentrantLock    # Protects connection-level window sizes
    pings_lock::ReentrantLock 
    socket_lock::ReentrantLock           # Protects the pending_pings dictionary
    decoder_lock::ReentrantLock         # Unchanged: specific to the HPACK decoder
    # ---
    pending_pings::Dict{UInt64, Tuple{Float64, Channel{Float64}}}
    callbacks::Dict{Symbol, Function}
    request_handler::Union{Any, Nothing}
    multiplexer::StreamMultiplexer
    done_condition::Condition
    client_connection_id::Union{String, Nothing}
    rate_limiter::TokenBucket

    function HTTP2Connection(socket::IO, role::ConnectionRole, settings::HTTP2Settings, host::String, port::Int64; 
                        request_handler::Union{Any, Nothing}=nothing,
                        client_connection_id::Union{String, Nothing}=nothing)
    
        # Create basic components
        conn_id = string(uuid4())
        streams = Dict{UInt32, HTTP2Stream}()
        encoder = HPACKEncoder(settings.header_table_size)
        decoder = HPACKDecoder(
            settings.header_table_size, 
            Int(settings.max_header_list_size)
        )
        frame_channel = Channel{HTTP2Frame}(128)
        preface_handshake_done = Condition()
        header_buffer = IOBuffer()

        # Create connection with basic fields
        conn = new(conn_id, socket, role, settings, streams, encoder, decoder,
                   frame_channel, preface_handshake_done, header_buffer, host, port)

        # Initialize state fields
        conn.state = CONNECTION_IDLE
        conn.remote_settings = HTTP2Settings()
        conn.last_stream_id = role == CLIENT ? UInt32(1) : UInt32(2)
        conn.last_peer_stream_id = UInt32(0)
        conn.receive_window = Int32(settings.initial_window_size)
        conn.send_window = Int32(DEFAULT_WINDOW_SIZE)
        conn.preface_sent = false
        conn.preface_received = false
        conn.goaway_sent = false
        conn.goaway_received = false
        conn.last_error = nothing
        conn.continuation_stream_id = UInt32(0)
        conn.continuation_end_stream = false
        conn.pending_push_promise_id = UInt32(0)
        conn.state_lock = ReentrantLock()
        conn.streams_lock = ReentrantLock()
        conn.flow_control_lock = ReentrantLock()
        conn.pings_lock = ReentrantLock()
        conn.socket_lock = ReentrantLock()
        conn.decoder_lock = ReentrantLock()
        conn.pending_pings = Dict{UInt64, Tuple{Float64, Channel{Float64}}}()
        conn.callbacks = Dict{Symbol, Function}()
        conn.request_handler = request_handler
        conn.client_connection_id = client_connection_id

        # Create multiplexer
        mux = StreamMultiplexer(conn, role, settings)
        conn.multiplexer = mux
        conn.done_condition = Condition()
        conn.rate_limiter = TokenBucket(100, 10)
        
        return conn
    end
end

# ============================================================================
# CONSTRUCTOR FUNCTIONS
# ============================================================================

"""
    HTTP2Stream(id::Integer, conn::HTTP2Connection) -> HTTP2Stream

Create a new HTTP/2 stream with the given ID and parent connection.
Initializes the stream in IDLE state with default flow control windows.
"""
function HTTP2Stream(id::Integer, conn::HTTP2Connection)
    initial_window_size = conn.settings.initial_window_size
    the_buffer = IOBuffer()
    stream_lock = ReentrantLock() # Create the stream's own lock

    stream = HTTP2Stream(
        stream_lock, # Pass the new lock to the struct
        UInt32(id),
        conn,
        STREAM_IDLE,
        Int32(initial_window_size),
        Int32(initial_window_size),
        nothing,
        HTTP2Stream[],
        StreamPriority(),
        Pair{String, String}[],
        the_buffer,
        false,
        false,
        now(),
        now(),
        ReentrantLock(), # This is the old buffer_lock
        Base.GenericCondition(stream_lock), # Use the new stream_lock
        Base.GenericCondition(stream_lock)  # Use the new stream_lock
    )

    return stream
end

"""
    StreamMultiplexer(conn::HTTP2Connection, role::ConnectionRole, settings::HTTP2Settings) -> StreamMultiplexer

Create a new stream multiplexer for the given connection.
"""
function StreamMultiplexer(conn::HTTP2Connection, role::ConnectionRole, settings::HTTP2Settings)
    lock = ReentrantLock()
    channels = Dict{UInt32, Channel{Union{HTTP2Frame, CleanupStream}}}()
    channels[0] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
    
    StreamMultiplexer(
        conn,
        channels,
        PriorityQueue{UInt32, Int}(Base.Order.Reverse),
        role,
        role == CLIENT ? UInt32(1) : UInt32(2),
        settings.max_concurrent_streams,
        Base.GenericCondition(lock),
        lock,
        nothing
    )
end

"""
    HTTP2Connection(socket::IO, role::ConnectionRole, settings::HTTP2Settings, auto_generate_client_id::Bool; request_handler=nothing) -> HTTP2Connection

Create a new HTTP/2 connection with optional automatic client ID generation.
"""
function HTTP2Connection(socket::IO, role::ConnectionRole, settings::HTTP2Settings, auto_generate_client_id::Bool; request_handler::Union{Any, Nothing}=nothing)
    client_id = auto_generate_client_id ? generate_unique_client_id() : nothing
    return HTTP2Connection(socket, role, settings; request_handler=request_handler, client_connection_id=client_id)
end

# ============================================================================
# CLIENT CONNECTION ID MANAGEMENT
# ============================================================================

"""
    generate_unique_client_id() -> String

Generate a unique client connection identifier using timestamp and random components.
"""
function generate_unique_client_id()
    timestamp = string(Dates.now())
    random_part = string(rand(UInt32), base=16)
    return "client_$(timestamp)_$(random_part)"
end

"""
    set_client_connection_id!(conn::HTTP2Connection, client_id::String)

Set the client connection ID for the given connection.
"""
function set_client_connection_id!(conn::HTTP2Connection, client_id::String)
    conn.client_connection_id = client_id
end

"""
    get_client_connection_id(conn::HTTP2Connection) -> Union{String, Nothing}

Get the client connection ID for the given connection, or nothing if not set.
"""
function get_client_connection_id(conn::HTTP2Connection)
    return conn.client_connection_id
end

"""
    has_client_connection_id(conn::HTTP2Connection) -> Bool

Check whether the connection has a client connection ID set.
"""
function has_client_connection_id(conn::HTTP2Connection)
    return !isnothing(conn.client_connection_id)
end

"""
    debug_connection_info(conn::HTTP2Connection)

Print detailed debug information about the connection state and associated client.
"""
function debug_connection_info(conn::HTTP2Connection)
    client_id = get_client_connection_id(conn)
    @info ("=== HTTP2Connection Debug Info ===")
    @info ("Role: $(conn.role)")
    @info ("State: $(conn.state)")
    @info ("Client ID: $(client_id)")
    @info ("Last Stream ID: $(conn.last_stream_id)")
    @info ("Active Streams: $(length(conn.streams))")
    
    if !isnothing(client_id)
        client_info = H2Server.get_connection_info(client_id)
        if !isnothing(client_info)
            @info ("Client Address: $(client_info.remote_addr):$(client_info.remote_port)")
            @info ("Connect Time: $(client_info.connect_time)")
            @info ("User Agent: $(client_info.user_agent)")
            @info ("ALPN Protocol: $(client_info.alpn_protocol)")
        end
    end
    @info ("=================================")
end

# ============================================================================
# DISPLAY METHODS
# ============================================================================

"""
    show(io::IO, header::FrameHeader)

Pretty print frame header information with length, type, flags, and stream ID.
"""
function Base.show(io::IO, header::FrameHeader)
    print(io, "FrameHeader(length=$(header.length), type=$(header.frame_type), " *
              "flags=0x$(string(header.flags, base=16, pad=2)), " *
              "stream_id=$(header.stream_id))")
end

"""
    show(io::IO, stream::HTTP2Stream)

Pretty print stream information including ID, state, and flow control windows.
"""
function Base.show(io::IO, stream::HTTP2Stream)
    print(io, "HTTP2Stream(id=$(stream.id), state=$(stream.state), " *
              "receive_window=$(stream.receive_window), " *
              "send_window=$(stream.send_window))")
end

"""
    show(io::IO, conn::HTTP2Connection)

Pretty print connection information including role, state, active streams, and send window.
"""
function Base.show(io::IO, conn::HTTP2Connection)
    role = (conn.role == SERVER) ? "server" : "client"
    print(io, "HTTP2Connection($role, state=$(conn.state), " *
              "streams=$(length(conn.streams)), " *
              "window=$(conn.send_window))")
end

# ============================================================================
# STREAM ACCESS METHODS
# ============================================================================

"""
    get_stream(conn::HTTP2Connection, stream_id::Integer) -> Union{HTTP2Stream, Nothing}

Get stream by ID from connection, returns nothing if not found.
"""
function get_stream(conn::HTTP2Connection, stream_id::Integer)
    return get(conn.streams, UInt32(stream_id), nothing)
end

"""
    has_stream(conn::HTTP2Connection, stream_id::Integer) -> Bool

Check if connection has stream with given ID.
"""
function has_stream(conn::HTTP2Connection, stream_id::Integer)
    return haskey(conn.streams, UInt32(stream_id))
end

"""
    next_stream_id!(conn::HTTP2Connection) -> UInt32

Generate next valid stream ID for this connection.
Increments by 2 to maintain client/server stream ID separation.
"""
function next_stream_id!(conn::HTTP2Connection)
    current = conn.next_stream_id
    conn.next_stream_id += 2
    return current
end

# ============================================================================
# IO INTERFACE FOR STREAMS
# ============================================================================


"""
    Base.read(s::HTTP2Stream, nb::Integer)

Διαβάζει έως `nb` bytes από το data_buffer του stream.
Αν το buffer είναι άδειο, περιμένει στη συνθήκη `data_available` μέχρι
να έρθουν νέα DATA frames ή να κλείσει το stream.
"""
function Base.read(s::HTTP2Stream, nb::Integer)
    lock(s.buffer_lock)
    try
        while !eof(s.data_buffer) && bytesavailable(s.data_buffer) == 0 && !s.end_stream_received
            # Περίμενε εδώ μέχρι να ειδοποιηθείς ότι ήρθαν νέα δεδομένα
            wait(s.data_available)
        end
        
        # Διάβασε τα διαθέσιμα δεδομένα από το buffer
        return read(s.data_buffer, min(nb, bytesavailable(s.data_buffer)))
    finally
        unlock(s.buffer_lock)
    end
end

"""
    Base.eof(s::HTTP2Stream)

Επιστρέφει true αν έχουμε λάβει το flag END_STREAM από τον client
ΚΑΙ το buffer με τα δεδομένα έχει αδειάσει τελείως.
"""
function Base.eof(s::HTTP2Stream)
    lock(s.buffer_lock)
    try
        return s.end_stream_received && eof(s.data_buffer)
    finally
        unlock(s.buffer_lock)
    end
end

"""
    Base.bytesavailable(s::HTTP2Stream)

Επιστρέφει τον αριθμό των bytes που είναι άμεσα διαθέσιμα για ανάγνωση
στο buffer του stream.
"""
function Base.bytesavailable(s::HTTP2Stream)
    lock(s.buffer_lock)
    try
        return bytesavailable(s.data_buffer)
    finally
        unlock(s.buffer_lock)
    end
end

function Base.close(s::HTTP2Stream)
    @lock s.lock begin
        if s.state != STREAM_CLOSED
            s.state = STREAM_CLOSED
            notify(s.data_available; all=true)
            notify(s.headers_available; all=true)
        end
    end
end

is_client(conn::AbstractHTTP2Connection) = conn.role == CLIENT
is_server(conn::AbstractHTTP2Connection) = conn.role == SERVER
is_idle(conn::AbstractHTTP2Connection) = conn.state == CONNECTION_IDLE
is_open(conn::AbstractHTTP2Connection) = conn.state == CONNECTION_OPEN
is_closing(conn::AbstractHTTP2Connection) = conn.state == CONNECTION_CLOSING
is_closed(conn::AbstractHTTP2Connection) = conn.state == CONNECTION_CLOSED
is_going_away(conn::AbstractHTTP2Connection) = conn.state in (CONNECTION_GOAWAY_SENT, CONNECTION_GOAWAY_RECEIVED)
is_active(stream::HTTP2Stream) = stream.state != STREAM_CLOSED

end