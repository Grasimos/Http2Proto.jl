module H2Types

using HPACK
using H2Frames: HTTP2Frame, FrameHeader
using Dates
using DataStructures
using UUIDs

using ..Exc, ..H2Settings, ..RateLimiter

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


# --- Connection & Lifecycle (RFC 7540, Section 3) ---
const CONNECTION_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
# Connection Flow Control (Section 5.2) #TODO: Move to Module
const CONNECTION_STREAM_ID = 0x0


# --- Frame Layout & Limits (RFC 7540, Section 4 & 6) ---
const FRAME_HEADER_SIZE = 9
const MAX_FRAME_SIZE_UPPER_BOUND = 16777215  # 2^24 - 1

# --- Stream Identifiers (RFC 7540, Section 5.1.1) ---
const MAX_STREAM_ID = 2147483647  # 2^31 - 1
const STREAM_ID_MASK = 0x7FFFFFFF

# --- Flow Control (RFC 7540, Section 5.2 & 6.9) ---
const MAX_WINDOW_SIZE = 2147483647  # 2^31 - 1



# --- HPACK & Header Semantics (RFC 7540, Section 8 & RFC 7541) ---
const PSEUDO_HEADERS = Set([":method", ":scheme", ":authority", ":path", ":status"])
const FORBIDDEN_HEADERS = Set(["connection", "upgrade", "http2-settings", "te", "transfer-encoding", "proxy-connection"])

# --- Priority Scheduling (RFC 7540, Section 5.3) ---
const DEFAULT_WEIGHT = 16 #TODO: Move to Module
const MIN_WEIGHT = 1        # Ελάχιστο βάρος
const MAX_WEIGHT = 256      # Μέγιστο βάρος

# ALPN Protocol Identifiers (Section 3.1) #TODO: Move to Module
const ALPN_HTTP2 = "h2"             # HTTP/2 over TLS
const ALPN_HTTP2_CLEARTEXT = "h2c"  # HTTP/2 χωρίς TLS


# Maximum values for various fields
const MAX_PADDING_LENGTH = 255          # Μέγιστο μήκος padding
const MAX_PRIORITY_WEIGHT = 255         # Μέγιστο βάρος προτεραιότητας
const MAX_PROMISED_STREAM_ID = MAX_STREAM_ID  # Μέγιστο promised stream ID

# Frame validation constants
const PING_FRAME_SIZE = 8                   # Σταθερό μέγεθος PING (8 bytes)
const GOAWAY_FRAME_MIN_SIZE = 8             # Ελάχιστο μέγεθος GOAWAY
const WINDOW_UPDATE_FRAME_SIZE = 4          # Σταθερό μέγεθος WINDOW_UPDATE
const PRIORITY_FRAME_SIZE = 5               # Σταθερό μέγεθος PRIORITY
const RST_STREAM_FRAME_SIZE = 4             # Σταθερό μέγεθος RST_STREAM

# HTTP Status Codes (Section 8.1.2.3)
const HTTP_STATUS_BAD_REQUEST = 400                         # Κακό αίτημα
const HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE = 431     # Επικεφαλίδες πολύ μεγάλες

# TLS/Security requirements (Appendix A)#TODO: Move to Module
const TLS_MIN_VERSION = "TLSv1.2"   # Ελάχιστη έκδοση TLS
const REQUIRED_TLS_CIPHER_SUITES = [ # Απαιτούμενα cipher suites
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384"
]

# Connection timeout defaults (in seconds)#TODO: Move to Module
const DEFAULT_PING_TIMEOUT = 60        # Timeout για PING response
const DEFAULT_SETTINGS_TIMEOUT = 10    # Timeout για SETTINGS ACK
const DEFAULT_CONNECTION_TIMEOUT = 300  # Γενικό timeout σύνδεσης

# HTTP/2 Protocol Requirements (Section 9)#TODO: Move to Module
const MAX_HEADER_NAME_LENGTH = 1024     # Μέγιστο μήκος ονόματος header
const MAX_HEADER_VALUE_LENGTH = 8192    # Μέγιστο μήκος τιμής header
const MAX_URI_LENGTH = 8192             # Μέγιστο μήκος URI

# Push Promise Constants (Section 8.2)#TODO: Move to Module
const PUSH_PROMISE_MIN_FRAME_SIZE = 4   # Ελάχιστο μέγεθος PUSH_PROMISE

# Connection Management (Section 6.8)#TODO: Move to Module
const GOAWAY_LAST_STREAM_ID_MASK = 0x7fffffff  # Μάσκα για last stream ID στο GOAWAY

"""
    ConnectionRole

Enum representing whether this connection is acting as a client or server.
"""
@enum ConnectionRole CLIENT=0 SERVER=1 # Enum που ορίζει τον ρόλο της σύνδεσης

# --- Stream & Connection States (RFC 7540, Section 5.1) ---
@enum StreamState begin
    STREAM_IDLE
    STREAM_RESERVED_LOCAL
    STREAM_RESERVED_REMOTE
    STREAM_OPEN
    STREAM_HALF_CLOSED_LOCAL
    STREAM_HALF_CLOSED_REMOTE
    STREAM_CLOSED
end

@enum ConnectionState begin
    CONNECTION_IDLE
    CONNECTION_OPEN
    CONNECTION_CLOSING
    CONNECTION_CLOSED
    CONNECTION_GOAWAY_SENT
    CONNECTION_GOAWAY_RECEIVED
end

abstract type AbstractHTTP2Connection end 

"""
    HTTP2Request

Represents an HTTP/2 request with headers and body.
"""
struct HTTP2Request # Struct για αίτημα HTTP/2
    method::String # Μέθοδος HTTP (GET, POST, κλπ)
    uri::String # URI προορισμού
    headers::Vector{Pair{String, String}} # Διάνυσμα headers
    body::Vector{UInt8} # Σώμα αιτήματος σε bytes
    stream_id::Int32 # Αναγνωριστικό stream
    
    function HTTP2Request(method::String, uri::String, # Constructor με πλήρεις παραμέτρους
                         headers::Vector{Pair{String, String}} = Pair{String, String}[], # Προεπιλεγμένα κενά headers
                         body::Union{String, Vector{UInt8}} = UInt8[], # Προεπιλεγμένο κενό σώμα
                         stream_id::Integer = 0) # Προεπιλεγμένο stream ID
        body_bytes = body isa String ? Vector{UInt8}(body) : body # Μετατροπή σε bytes αν χρειάζεται
        if stream_id < 0 || stream_id > MAX_STREAM_ID # Έλεγχος έγκυρου stream ID
            throw(StreamError("Stream ID $stream_id out of valid range [0, $MAX_STREAM_ID]")) # Σφάλμα stream ID
        end
        new(method, uri, headers, body_bytes, Int32(stream_id)) # Δημιουργεί νέο αίτημα
    end
end

"""
    HTTP2Response

Represents an HTTP/2 response with status, headers and body.
"""
struct HTTP2Response # Struct για απάντηση HTTP/2
    status::Int # Κωδικός κατάστασης HTTP
    headers::Vector{Pair{String, String}} # Διάνυσμα headers απάντησης
    body::Vector{UInt8} # Σώμα απάντησης σε bytes
    stream_id::Int32 # Αναγνωριστικό stream
    
    function HTTP2Response(status::Integer, # Constructor με κωδικό κατάστασης
                          headers::Vector{Pair{String, String}} = Pair{String, String}[], # Προεπιλεγμένα κενά headers
                          body::Union{String, Vector{UInt8}} = UInt8[], # Προεπιλεγμένο κενό σώμα
                          stream_id::Integer = 0) # Προεπιλεγμένο stream ID
        body_bytes = body isa String ? Vector{UInt8}(body) : body # Μετατροπή σε bytes αν χρειάζεται
        if status < 100 || status > 599 # Έλεγχος έγκυρου κωδικού κατάστασης
            throw(ProtocolError("Invalid HTTP status code: $status")) # Σφάλμα κωδικού κατάστασης
        end
        if stream_id < 0 || stream_id > MAX_STREAM_ID # Έλεγχος έγκυρου stream ID
            throw(StreamError("Stream ID $stream_id out of valid range [0, $MAX_STREAM_ID]")) # Σφάλμα stream ID
        end
        new(Int(status), headers, body_bytes, Int32(stream_id)) # Δημιουργεί νέα απάντηση
    end
end


# ============================================================================= # Διαχωριστική γραμμή
# Stream Priority # Προτεραιότητα Stream
# ============================================================================= # Διαχωριστική γραμμή

"""
    StreamPriority

Stream priority information including dependency and weight.
"""
struct StreamPriority # Struct για πληροφορίες προτεραιότητας stream
    exclusive::Bool # Αποκλειστική προτεραιότητα
    stream_dependency::Int32 # Εξάρτηση από άλλο stream
    weight::UInt8 # Βάρος προτεραιότητας

    function StreamPriority(exclusive::Bool, stream_dependency::Integer, weight::Integer) # Constructor με validation
        if weight < MIN_WEIGHT || weight > MAX_WEIGHT # Έλεγχος έγκυρου βάρους
            throw(PriorityError("Priority weight $weight not in valid range [$MIN_WEIGHT, $MAX_WEIGHT]", weight)) # Σφάλμα βάρους προτεραιότητας
        end
        if stream_dependency < 0 || stream_dependency > MAX_STREAM_ID # Έλεγχος έγκυρης εξάρτησης
            throw(PriorityError("Stream dependency $stream_dependency out of valid range [0, $MAX_STREAM_ID]", stream_dependency)) # Σφάλμα εξάρτησης stream
        end
        new(exclusive, Int32(stream_dependency), UInt8(weight - 1)) # Δημιουργεί νέο instance (βάρος - 1)
    end
end

# Default priority # Προεπιλεγμένη προτεραιότητα
StreamPriority() = StreamPriority(false, 0, DEFAULT_WEIGHT) # Constructor χωρίς παραμέτρους

# Get actual weight (1-256) # Παίρνει το πραγματικό βάρος
priority_weight(p::StreamPriority) = Int(p.weight) + 1 # Επιστρέφει βάρος + 1

"""
    HTTP2Stream

Represents an HTTP/2 stream with state management and flow control.
"""
mutable struct HTTP2Stream <: IO# Mutable struct για HTTP/2 stream
    const id::UInt32 # Σταθερό αναγνωριστικό stream
    const connection::AbstractHTTP2Connection # Αναφορά πίσω στη σύνδεση # Σταθερή αναφορά στη σύνδεση
    state::StreamState # Κατάσταση του stream
    receive_window::Int32 # Παράθυρο λήψης για flow control
    send_window::Int32 # Παράθυρο αποστολής για flow control
    parent::Union{HTTP2Stream, Nothing} # Γονικό stream για εξαρτήσεις
    children::Vector{HTTP2Stream} # Παιδικά streams
    priority::StreamPriority # Πληροφορίες προτεραιότητας
    headers::Vector{Pair{String, String}} # Headers του stream
    const data_buffer::IOBuffer # Σταθερό buffer για δεδομένα
    end_stream_received::Bool # Flag για λήψη τέλους stream
    end_stream_sent::Bool # Flag για αποστολή τέλους stream
    const created_at::DateTime # Σταθερή ημερομηνία δημιουργίας
    last_activity::DateTime # Τελευταία δραστηριότητα
    const buffer_lock::ReentrantLock # Σταθερό lock για thread safety
    const data_available::Base.GenericCondition{ReentrantLock}
    const headers_available::Base.GenericCondition{ReentrantLock}
end

# ============================================================================= 
# Stream Multiplexer 
# ============================================================================= 
"""Ειδικός τύπος-μήνυμα για να δώσει εντολή στον send_loop να καθαρίσει ένα stream."""
struct CleanupStream end

"""
    StreamMultiplexer

Manages the set of active HTTP/2 streams for a connection, enforcing stream limits,
priorities, and correct stream opening/closing according to RFC 7540. Supports
concurrent frame transmission with stream prioritization.
"""
mutable struct StreamMultiplexer
    conn::AbstractHTTP2Connection
    frame_channels::Dict{UInt32, Channel{Union{HTTP2Frame, CleanupStream}}} # <--- ΑΛΛΑΓΗ ΤΥΠΟΥ
    pending_streams::PriorityQueue{UInt32, Int}
    role::ConnectionRole
    next_stream_id::UInt32
    max_concurrent_streams::UInt32
    
    # ΔΙΟΡΘΩΣΗ: Δηλώνουμε τον ακριβή, παραμετρικό τύπο.
    send_condition::Base.GenericCondition{ReentrantLock}
    
    send_lock::ReentrantLock
    send_task::Union{Task, Nothing}
end

"""
    HTTP2Connection

Main connection type that manages an HTTP/2 connection.
"""

mutable struct HTTP2Connection <: AbstractHTTP2Connection # Mutable struct για κύρια σύνδεση HTTP/2
    # --- Const Fields --- # Σταθερά πεδία
    const id::String # <--- ΝΕΟ ΠΕΔΙΟ
    const socket::IO # Σταθερό socket για I/O
    const role::ConnectionRole # Σταθερός ρόλος σύνδεσης
    const settings::HTTP2Settings # Σταθερές ρυθμίσεις σύνδεσης
    const streams::Dict{UInt32, HTTP2Stream} # Σταθερό dictionary των streams
    const hpack_encoder::HPACKEncoder
    const hpack_decoder::HPACKDecoder
    const frame_channel::Channel{HTTP2Frame} # Σταθερό κανάλι για frames
    const preface_handshake_done::Condition # Σταθερή συνθήκη για handshake
    const header_buffer::IOBuffer # Σταθερό buffer για headers


    # --- Mutable Fields --- # Μεταβλητά πεδία
    host::String  # <--- NEW FIELD
    port::Int64     # <--- NEW FIELD
    state::ConnectionState # Κατάσταση σύνδεσης
    remote_settings::HTTP2Settings # Ρυθμίσεις του remote peer
    last_stream_id::UInt32 # Τελευταίο χρησιμοποιημένο stream ID
    last_peer_stream_id::UInt32 # Τελευταίο stream ID από peer
    receive_window::Int32 # Παράθυρο λήψης σύνδεσης
    send_window::Int32 # Παράθυρο αποστολής σύνδεσης
    preface_sent::Bool # Flag για αποστολή preface
    preface_received::Bool # Flag για λήψη preface
    goaway_sent::Bool # Flag για αποστολή GOAWAY
    goaway_received::Bool # Flag για λήψη GOAWAY
    last_error::Union{Nothing, ConnectionError} # Τελευταίο σφάλμα ή Nothing
    continuation_stream_id::UInt32 # Stream ID για CONTINUATION frames
    continuation_end_stream::Bool # Flag για τέλος CONTINUATION
    lock::ReentrantLock # Lock για thread safety
    decoder_lock::ReentrantLock # Lock για thread safety
    pending_pings::Dict{UInt64, Tuple{Float64, Channel{Float64}}} # Dictionary για pending PINGs
    callbacks::Dict{Symbol, Function} # Dictionary για callbacks
    request_handler::Union{Any, Nothing} # Handler για αιτήματα ή Nothing
    multiplexer::StreamMultiplexer # Πολυπλέκτης streams
    done_condition::Condition
    client_connection_id::Union{String, Nothing}
    rate_limiter::TokenBucket
    

    function HTTP2Connection(socket::IO, role::ConnectionRole, settings::HTTP2Settings, host::String, port::Int64; 
                        request_handler::Union{Any, Nothing}=nothing,
                        client_connection_id::Union{String, Nothing}=nothing)
    
    # Δημιουργία βασικών στοιχείων
    conn_id = string(uuid4())
    streams = Dict{UInt32, HTTP2Stream}()
    encoder = HPACKEncoder(settings.header_table_size)
    decoder = HPACKDecoder(UInt32(DEFAULT_HEADER_TABLE_SIZE)) 
    frame_channel = Channel{HTTP2Frame}(128)
    preface_handshake_done = Condition()
    header_buffer = IOBuffer()

    # Δημιουργία σύνδεσης με τα βασικά πεδία
    conn = new(conn_id, socket, role, settings, streams,encoder, decoder,
               frame_channel, preface_handshake_done, header_buffer, host, port)

    # Αρχικοποίηση state fields
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
    conn.lock = ReentrantLock()
    conn.decoder_lock = ReentrantLock()
    conn.pending_pings = Dict{UInt64, Tuple{Float64, Channel{Float64}}}()
    conn.callbacks = Dict{Symbol, Function}()
    conn.request_handler = request_handler
    
    # ΝΕΟ: Αρχικοποίηση client connection ID
    conn.client_connection_id = client_connection_id

    # Δημιουργία multiplexer
    mux = StreamMultiplexer(conn, role, settings)
    conn.multiplexer = mux
    conn.done_condition = Condition()
    conn.rate_limiter = TokenBucket(100, 10)
    
    return conn
        end
    end

# Constructor για το HTTP2Stream # Constructor για HTTP2Stream
function HTTP2Stream(id::Integer, conn::HTTP2Connection) # Συνάρτηση constructor με ID και connection
        initial_window_size = conn.settings.initial_window_size # Παίρνει το αρχικό μέγεθος παραθύρου

        # 1. Δημιουργούμε τον buffer ΡΗΤΑ και ΑΝΕΞΑΡΤΗΤΑ 
        the_buffer = IOBuffer() # Δημιουργεί νέο IOBuffer

        # 2. Καλούμε τη περνώντας το αντικείμενο που ήδη φτιάξαμε # Καλούμε constructor με έτοιμο αντικείμενο
        stream = HTTP2Stream( # Δημιουργεί νέο stream
            UInt32(id),                 # id # Μετατρέπει ID σε UInt32
            conn,                       # connection # Περνάει τη σύνδεση
            STREAM_IDLE,                # state # Αρχική κατάσταση IDLE
            Int32(initial_window_size), # receive_window # Παράθυρο λήψης
            Int32(initial_window_size), # send_window # Παράθυρο αποστολής
            nothing,                    # parent # Κανένα γονικό stream
            HTTP2Stream[],              # children # Κενό διάνυσμα παιδιών
            StreamPriority(),           # priority # Προεπιλεγμένη προτεραιότητα
            Pair{String, String}[],     # headers # Κενό διάνυσμα headers
            the_buffer,                 # data_buffer (το έτοιμο αντικείμενο) # Το έτοιμο buffer
            false,                      # end_stream_received # Flag για λήψη τέλους
            false,                      # end_stream_sent # Flag για αποστολή τέλους
            now(),                      # created_at # Τρέχουσα ημερομηνία δημιουργίας
            now(),                      # last_activity # Τρέχουσα ημερομηνία δραστηριότητας
            ReentrantLock(),            # buffer_lock # Lock για το buffer
            Base.GenericCondition(conn.lock),                # data_available # Συνθήκη για δεδομένα
            Base.GenericCondition(conn.lock)                # headers_available # Συνθήκη για headers
        )

        return stream # Επιστρέφει το νέο stream
end


function StreamMultiplexer(conn::HTTP2Connection, role::ConnectionRole, settings::HTTP2Settings)
    lock = ReentrantLock()
    channels = Dict{UInt32, Channel{Union{HTTP2Frame, CleanupStream}}}()
    channels[0] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
    
    StreamMultiplexer(
        conn,
        channels, # <--- Η αλλαγή είναι εδώ
        PriorityQueue{UInt32, Int}(Base.Order.Reverse),
        role,
        role == CLIENT ? UInt32(1) : UInt32(2),
        settings.max_concurrent_streams,
        Base.GenericCondition(lock),
        lock,
        nothing
    )
end

function HTTP2Connection(socket::IO, role::ConnectionRole, settings::HTTP2Settings, 
                        auto_generate_client_id::Bool; 
                        request_handler::Union{Any, Nothing}=nothing)
    
    client_id = auto_generate_client_id ? generate_unique_client_id() : nothing
    
    return HTTP2Connection(socket, role, settings; 
                          request_handler=request_handler,
                          client_connection_id=client_id)
end

# ============================================================================= 
# Utility Functions # Βοηθητικές συναρτήσεις
# ============================================================================= 


function generate_unique_client_id()
    timestamp = string(Dates.now())  # milliseconds
    random_part = string(rand(UInt32), base=16)
    return "client_$(timestamp)_$(random_part)"
end

function set_client_connection_id!(conn::HTTP2Connection, client_id::String)
    conn.client_connection_id = client_id
end

function get_client_connection_id(conn::HTTP2Connection)
    return conn.client_connection_id
end

function has_client_connection_id(conn::HTTP2Connection)
    return !isnothing(conn.client_connection_id)
end

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

"""
    show(io::IO, header::FrameHeader)

Pretty print frame header information.
"""
function Base.show(io::IO, header::FrameHeader) # Συνάρτηση για εμφάνιση FrameHeader
    print(io, "FrameHeader(length=$(header.length), type=$(header.frame_type), " * # Τυπώνει length και type
              "flags=0x$(string(header.flags, base=16, pad=2)), " * # Τυπώνει flags σε hex
              "stream_id=$(header.stream_id))") # Τυπώνει stream ID
end

"""
    show(io::IO, stream::HTTP2Stream)

Pretty print stream information.
"""
function Base.show(io::IO, stream::HTTP2Stream) # Συνάρτηση για εμφάνιση HTTP2Stream
    print(io, "HTTP2Stream(id=$(stream.id), state=$(stream.state), " * # Τυπώνει ID και κατάσταση
              "receive_window=$(stream.receive_window), " * # Τυπώνει τοπικό παράθυρο
              "send_window=$(stream.send_window))") # Τυπώνει απομακρυσμένο παράθυρο
end

"""
    show(io::IO, conn::HTTP2Connection)

Pretty print connection information.
"""
function Base.show(io::IO, conn::HTTP2Connection) # Συνάρτηση για εμφάνιση HTTP2Connection
    role = (conn.role == SERVER) ? "server" : "client" # Καθορίζει το string του ρόλου
    print(io, "HTTP2Connection($role, state=$(conn.state), " * # Τυπώνει ρόλο και κατάσταση
              "streams=$(length(conn.streams)), " * # Τυπώνει αριθμό streams
              "window=$(conn.send_window))") # Τυπώνει μέγεθος παραθύρου
end

"""
    get_stream(conn::HTTP2Connection, stream_id::Integer)

Get stream by ID from connection, returns nothing if not found.
"""
function get_stream(conn::HTTP2Connection, stream_id::Integer) # Συνάρτηση για λήψη stream από σύνδεση
    return get(conn.streams, UInt32(stream_id), nothing) # Επιστρέφει stream ή nothing
end

"""
    has_stream(conn::HTTP2Connection, stream_id::Integer) -> Bool

Check if connection has stream with given ID.
"""
function has_stream(conn::HTTP2Connection, stream_id::Integer) # Συνάρτηση για έλεγχο ύπαρξης stream
    return haskey(conn.streams, UInt32(stream_id)) # Επιστρέφει true αν υπάρχει το stream
end

"""
    next_stream_id!(conn::HTTP2Connection) -> Int32

Generate next valid stream ID for this connection.
"""
function next_stream_id!(conn::HTTP2Connection) # Συνάρτηση για δημιουργία επόμενου stream ID
    current = conn.next_stream_id # Παίρνει το τρέχον stream ID
    conn.next_stream_id += 2   # Προσθέτει 2 για διατήρηση μονού/ζυγού pattern
    return current # Επιστρέφει το τρέχον ID
end

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
    @lock s.connection.lock begin
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