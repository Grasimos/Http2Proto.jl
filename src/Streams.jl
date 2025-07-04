module Streams

using HPACK
using H2Frames
using H2Frames.RstStream
using Base.Threads: threadid
using DataStructures
using Dates

using ..Exc, ..H2Types
using ..Exc: ProtocolError

export
    transition_stream_state!, update_activity!, replenish_receive_window!, apply_priority_frame!,
    wait_for_headers, wait_for_body, apply_rst_stream_frame!, CleanupStream,
    priority_weight, update_stream_dependency!, get_priority_tree,
    open_stream!, register_stream!, send_frame_on_stream, mux_close_stream!

# =============================================================================
# STREAM LIFECYCLE MANAGEMENT
# =============================================================================

"""
    open_stream!(mux::StreamMultiplexer) -> HTTP2Stream

Creates a new HTTP/2 stream with the next available stream ID.
Throws ProtocolError if connection is shutting down or maximum concurrent streams reached.
"""
function open_stream!(mux::StreamMultiplexer)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Attempting to open new stream"
    
    @lock mux.send_lock begin
        if !should_accept_new_streams(mux.conn)
            @warn "[$role][T$(threadid())] Cannot open new stream: connection shutting down"
            throw(ProtocolError("Cannot open new stream; connection is shutting down."))
        end
        
        current_streams = length(mux.conn.streams)
        max_streams = mux.conn.remote_settings.max_concurrent_streams
        if current_streams >= max_streams
            @warn "[$role][T$(threadid())] Cannot open new stream: max concurrent streams reached ($current_streams/$max_streams)"
            throw(StreamError(REFUSED_STREAM, "Maximum concurrent streams reached", 0))
        end
        
        stream_id = mux.next_stream_id
        mux.next_stream_id += 2
        stream = HTTP2Stream(stream_id, mux.conn)
        mux.conn.streams[stream_id] = stream
        mux.frame_channels[stream_id] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
        
        @info "[$role][T$(threadid())] Stream $stream_id created and registered (active: $(current_streams + 1)/$max_streams)"
        return stream
    end
end

"""
    register_stream!(mux::StreamMultiplexer, stream::HTTP2Stream)

Registers a peer-initiated stream with the multiplexer by creating its frame channel.
"""
function register_stream!(mux::StreamMultiplexer, stream::HTTP2Stream)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Registering peer-initiated stream $(stream.id)"
    
    @lock mux.send_lock begin
        if !haskey(mux.frame_channels, stream.id)
            mux.frame_channels[stream.id] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
            @debug "[$role][T$(threadid())] Created frame channel for stream $(stream.id)"
        else
            @debug "[$role][T$(threadid())] Frame channel already exists for stream $(stream.id)"
        end
    end
end

"""
    mux_close_stream!(mux::StreamMultiplexer, stream_id::UInt32, error_code::Union{Symbol, Nothing}=nothing)

Closes a stream, optionally sending an RST_STREAM frame with the specified error code.
"""
function mux_close_stream!(mux::StreamMultiplexer, stream_id::UInt32, error_code::Union{Symbol, Nothing}=nothing)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    stream = get(mux.conn.streams, stream_id, nothing)
    
    if stream === nothing
        @debug "[$role][T$(threadid())] Attempted to close non-existent stream $stream_id"
        return
    end
    
    if !is_active(stream)
        @debug "[$role][T$(threadid())] Attempted to close already inactive stream $stream_id"
        return
    end

    if error_code !== nothing
        @info "[$role][T$(threadid())] Closing stream $stream_id with error: $error_code"
        numeric_error_code = Exc.error_code_value(error_code)
        rst_frame = RstStreamFrame(stream_id, numeric_error_code)
        send_frame_on_stream(mux, stream_id, rst_frame)
    else
        @debug "[$role][T$(threadid())] Gracefully closing stream $stream_id"
    end
    
    send_frame_on_stream(mux, stream_id, CleanupStream())
    close(stream)
    @debug "[$role][T$(threadid())] Stream $stream_id closed successfully"
end

"""
    should_accept_new_streams(conn::HTTP2Connection) -> Bool

Checks if the connection is in a state that can accept new streams.
Returns false if GOAWAY has been sent or received.
"""
function should_accept_new_streams(conn::HTTP2Connection)
    return !(conn.goaway_sent || conn.goaway_received)
end

"""
    is_stream_allowed(conn::HTTP2Connection, stream_id::UInt32) -> Bool

Checks if a stream with the specified ID is allowed to continue processing,
based on the last_stream_id that may have been received in a GOAWAY frame.
"""
function is_stream_allowed(conn::HTTP2Connection, stream_id::UInt32)
    if conn.goaway_received
        return stream_id <= conn.last_peer_stream_id
    end
    return true
end

"""
    can_create_stream(conn::HTTP2Connection) -> Bool

Check if a new stream can be created based on max concurrent streams setting.
"""
function can_create_stream(conn::HTTP2Connection)
    active_streams = length(conn.streams)
    max_streams = conn.remote_settings.max_concurrent_streams
    
    return max_streams == typemax(UInt32) || active_streams < max_streams
end

"""
    update_activity!(stream::HTTP2Stream)

Updates the last activity timestamp for the stream.
"""
function update_activity!(stream::HTTP2Stream)
    stream.last_activity = Dates.now()
end

# =============================================================================
# FRAME TRANSMISSION
# =============================================================================

"""
    send_frame_on_stream(mux::StreamMultiplexer, stream_id::UInt32, frame::Union{HTTP2Frame, CleanupStream})

Queues a frame to be sent on the specified stream and updates the pending streams queue.
"""
function send_frame_on_stream(mux::StreamMultiplexer, stream_id::UInt32, frame::Union{HTTP2Frame, CleanupStream})
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Queueing frame $(typeof(frame)) on stream $stream_id"

    @lock mux.send_lock begin
        channel = get(mux.frame_channels, stream_id, nothing)
        if channel === nothing || !isopen(channel)
            @warn "[$role][T$(threadid())] Cannot send frame on closed/missing stream $stream_id"
            throw(StreamError(:STREAM_CLOSED_ERROR, "Cannot send frame on closed stream $stream_id", stream_id))
        end
        
        put!(channel, frame)
        @debug "[$role][T$(threadid())] Frame queued successfully on stream $stream_id"
        
        if !haskey(mux.pending_streams, stream_id)
            stream = get(mux.conn.streams, stream_id, nothing)
            priority = stream !== nothing ? Int(stream.priority.weight) : Int(DEFAULT_WEIGHT)
            DataStructures.enqueue!(mux.pending_streams, stream_id, priority)
            @debug "[$role][T$(threadid())] Added stream $stream_id to pending queue with priority $priority"
        end
        notify(mux.send_condition)
    end
end

send_frame_on_stream(mux::StreamMultiplexer, stream_id::Integer, frame::Union{HTTP2Frame, CleanupStream}) = 
    send_frame_on_stream(mux, UInt32(stream_id), frame)

# =============================================================================
# FLOW CONTROL
# =============================================================================

"""
    replenish_receive_window!(stream::HTTP2Stream, amount::Int)

Acknowledges that `amount` bytes have been consumed by the application,
and sends WINDOW_UPDATE frames if necessary to replenish the windows.
"""
function replenish_receive_window!(stream::HTTP2Stream, amount::Int)
    conn = stream.connection
    role = is_client(conn) ? "CLIENT" : "SERVER"
    
    @debug "[$role][T$(threadid())] Replenishing receive window by $amount bytes for stream $(stream.id)"
    
    stream.receive_window += amount
    conn.receive_window += amount

    @debug "[$role][T$(threadid())] Stream $(stream.id) window: $(stream.receive_window), Connection window: $(conn.receive_window)"

    maybe_send_window_update(stream)
    maybe_send_window_update(conn)
end

"""
    maybe_send_window_update(stream::HTTP2Stream)

Sends a stream-level WINDOW_UPDATE if the receive window is low.
"""
function maybe_send_window_update(stream::HTTP2Stream)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    threshold = stream.connection.settings.initial_window_size ÷ 2
    
    if stream.receive_window <= threshold
        increment = stream.connection.settings.initial_window_size - stream.receive_window
        if increment > 0
            @debug "[$role][T$(threadid())] Sending WINDOW_UPDATE for stream $(stream.id): increment=$increment"
            wu_frame = create_stream_window_update(stream.id, increment)
            send_frame_on_stream(stream.connection.multiplexer, stream.id, wu_frame)
        end
    end
end

"""
    maybe_send_window_update(conn::HTTP2Connection)

Sends a connection-level WINDOW_UPDATE if the receive window is low.
"""
function maybe_send_window_update(conn::HTTP2Connection)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    threshold = conn.settings.initial_window_size ÷ 2
    
    if conn.receive_window <= threshold
        increment = conn.settings.initial_window_size - conn.receive_window
        if increment > 0
            @debug "[$role][T$(threadid())] Sending connection-level WINDOW_UPDATE: increment=$increment"
            wu_frame = create_connection_window_update(increment)
            send_frame_on_stream(conn.multiplexer, 0, wu_frame)
        end
    end
end

# =============================================================================
# DATA AND HEADER WAITING
# =============================================================================

"""
    wait_for_headers(stream::HTTP2Stream) -> Vector

Blocks until headers are available on the stream or the stream ends.
Returns the headers when available.
"""
function wait_for_headers(stream::HTTP2Stream)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Called wait_for_headers, acquiring lock..."
    
    @lock stream.lock begin
        @debug "[$role][T$(threadid())] Stream $(stream.id): Acquired lock for wait_for_headers"
        
        while isempty(stream.headers) && !stream.end_stream_received && is_active(stream)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Headers not ready, waiting on condition..."
            wait(stream.headers_available)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Woke up from wait, re-checking condition"
        end
        
        @debug "[$role][T$(threadid())] Stream $(stream.id): Headers available or stream ended, returning $(length(stream.headers)) headers"
        return stream.headers
    end
end

"""
    wait_for_body(stream::HTTP2Stream) -> Vector{UInt8}

Blocks until body data is available on the stream or the stream ends.
Returns the available body data and replenishes the receive window.
"""
function wait_for_body(stream::HTTP2Stream)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Called wait_for_body, acquiring lock..."
    local read_data

    @lock stream.lock begin
        @debug "[$role][T$(threadid())] Stream $(stream.id): Acquired lock for wait_for_body"
        
        while bytesavailable(stream.data_buffer) == 0 && !stream.end_stream_received && is_active(stream)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Body not ready, waiting on condition..."
            wait(stream.data_available)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Woke up from wait, re-checking condition"
        end
        
        @debug "[$role][T$(threadid())] Stream $(stream.id): Data available or stream ended, reading buffer"
        seekstart(stream.data_buffer)
        read_data = read(stream.data_buffer)
    end
    
    if !isempty(read_data)
        @debug "[$role][T$(threadid())] Stream $(stream.id): Read $(length(read_data)) bytes, replenishing window"
        replenish_receive_window!(stream, length(read_data))
    end
    
    @debug "[$role][T$(threadid())] Stream $(stream.id): Returning $(length(read_data)) bytes from wait_for_body"
    return read_data
end

# =============================================================================
# PRIORITY MANAGEMENT
# =============================================================================

"""
    priority_weight(priority::StreamPriority) -> Int

Get the effective weight (1-256) for a stream's priority.
"""
priority_weight(priority::StreamPriority) = Int(priority.weight) + 1

"""
    update_stream_dependency!(streams::Dict{Int32, HTTP2Stream}, stream_id::Int32, dependency_id::Int32, exclusive::Bool)

Update the stream dependency tree according to RFC 7540 §5.3.3.
If exclusive is true, the dependent stream becomes the sole child of its parent.
"""
function update_stream_dependency!(streams::Dict{Int32, HTTP2Stream}, stream_id::Int32, dependency_id::Int32, exclusive::Bool)
    @debug "Updating stream dependency: stream=$stream_id depends on $dependency_id (exclusive=$exclusive)"
    
    if stream_id == dependency_id
        @warn "Stream $stream_id cannot depend on itself, ignoring dependency update"
        throw(ArgumentError("A stream cannot depend on itself"))
    end
    
    stream = get(streams, stream_id, nothing)
    dependency = get(streams, dependency_id, nothing)
    
    if stream === nothing
        @warn "Cannot update dependency: stream $stream_id does not exist"
        throw(ArgumentError("Stream $stream_id does not exist"))
    end
    
    @debug "Removing stream $stream_id from current parent (if any)"
    if stream.parent !== nothing
        deleteat!(stream.parent.children, findfirst(==(stream), stream.parent.children))
    end
    
    stream.parent = dependency
    
    if dependency !== nothing
        if exclusive
            @debug "Exclusive dependency: making stream $stream_id sole child of $dependency_id"
            old_children = copy(dependency.children)
            dependency.children = [stream]
            for child in old_children
                if child !== stream
                    @debug "Moving child $(child.id) under stream $stream_id"
                    child.parent = stream
                    push!(stream.children, child)
                end
            end
        else
            @debug "Non-exclusive dependency: adding stream $stream_id as child of $dependency_id"
            push!(dependency.children, stream)
        end
    else
        @debug "Stream $stream_id now depends on connection root"
    end
end

function update_stream_dependency!(streams::Dict{UInt32, HTTP2Stream}, stream_id::UInt32, dependency_id::UInt32, exclusive::Bool)
    int_streams = Dict{Int32, HTTP2Stream}((Int32(k), v) for (k, v) in streams)
    update_stream_dependency!(int_streams, Int32(stream_id), Int32(dependency_id), exclusive)
    
    for (k, v) in int_streams
        if haskey(streams, UInt32(k))
            streams[UInt32(k)] = v
        end
    end
end

"""
    get_priority_tree(streams::Dict{Int32, HTTP2Stream}) -> Dict

Return a representation of the stream dependency tree for debugging or visualization.
"""
function get_priority_tree(streams::Dict{Int32, HTTP2Stream})
    tree = Dict{Int32, Any}()
    for (id, stream) in streams
        parent_id = hasproperty(stream, :parent) && stream.parent !== nothing ? stream.parent.id : nothing
        children_ids = hasproperty(stream, :children) ? [child.id for child in stream.children] : Int32[]
        tree[id] = (parent=parent_id, children=children_ids, weight=priority_weight(stream.priority))
    end
    return tree
end

# =============================================================================
# FRAME PROCESSING
# =============================================================================

"""
    apply_rst_stream_frame!(connection_state, frame::RstStreamFrame)

Complete implementation for applying RST_STREAM frame to connection state.
Closes the specified stream if it exists and is active.
"""
function apply_rst_stream_frame!(connection_state, frame::RstStreamFrame)
    stream = get(connection_state.streams, frame.stream_id, nothing)
    if stream !== nothing && is_active(stream)
        @info "Applied RST_STREAM frame and closed stream $(frame.stream_id) with error code $(frame.error_code)"
        close(stream)
    else
        @debug "RST_STREAM received for unknown or already closed stream $(frame.stream_id)"
    end
end

"""
    apply_priority_frame!(conn::HTTP2Connection, frame::PriorityFrame)

Applies priority information from a PRIORITY frame to a stream.
Updates the stream's priority, dependency tree, and multiplexer priority queue.
"""
function apply_priority_frame!(conn::HTTP2Connection, frame::PriorityFrame)
    @debug "Applying PRIORITY frame for stream $(frame.stream_id)"
    
    # The conn.streams_lock is already held by the calling function.
    # We only need to lock the multiplexer to update its queue.
    stream = get_stream(conn, frame.stream_id)
    if stream === nothing
        @debug "Received PRIORITY for idle/unknown stream $(frame.stream_id), ignoring"
        return
    end

    new_weight = H2Frames.Priority.actual_weight(frame)
    stream.priority = StreamPriority(frame.exclusive, frame.stream_dependency, new_weight)
    
    update_stream_dependency!(
        conn.streams,
        frame.stream_id,
        frame.stream_dependency,
        frame.exclusive
    )
    
    mux = conn.multiplexer
    @lock mux.send_lock begin
        if haskey(mux.pending_streams, stream.id)
            mux.pending_streams[stream.id] = new_weight
            @debug "Updated priority for stream $(stream.id) in pending queue to $new_weight"
        end
    end
end

# =============================================================================
# STREAM STATE MACHINE
# =============================================================================

"""
    transition_stream_state!(stream::HTTP2Stream, event::Symbol)

Transitions the stream state according to RFC 7540 §5.1 by dispatching
to a helper function based on the current state and the event.
"""
function transition_stream_state!(stream::HTTP2Stream, event::Symbol)
    old_state = stream.state
    new_state = _get_next_state(Val(old_state), Val(event))

    if new_state !== nothing && new_state != old_state
        stream.state = new_state
        @debug "Stream $(stream.id) state transition: $old_state -> $new_state (on :$event)"
    end
end

# --- State Machine Helper Functions ---
function _get_next_state(from::Val{S}, on::Val{E}) where {S, E}
    throw(Exc.ProtocolError("Invalid stream state transition from $S on event $E"))
end

# --- Transitions from 'idle' state ---
_get_next_state(::Val{STREAM_IDLE}, ::Val{:send_headers}) = STREAM_OPEN
_get_next_state(::Val{STREAM_IDLE}, ::Val{:recv_headers}) = STREAM_OPEN
_get_next_state(::Val{STREAM_IDLE}, ::Val{:send_push_promise}) = STREAM_RESERVED_LOCAL 
_get_next_state(::Val{STREAM_IDLE}, ::Val{:recv_push_promise}) = STREAM_RESERVED_REMOTE 

# --- Transitions from 'reserved_local' state ---
_get_next_state(::Val{STREAM_RESERVED_LOCAL}, ::Val{:send_headers}) = STREAM_HALF_CLOSED_REMOTE 
_get_next_state(::Val{STREAM_RESERVED_LOCAL}, ::Val{:send_rst_stream}) = STREAM_CLOSED
_get_next_state(::Val{STREAM_RESERVED_LOCAL}, ::Val{:recv_rst_stream}) = STREAM_CLOSED

# --- Transitions from 'reserved_remote' state ---
_get_next_state(::Val{STREAM_RESERVED_REMOTE}, ::Val{:recv_headers}) = STREAM_HALF_CLOSED_LOCAL
_get_next_state(::Val{STREAM_RESERVED_REMOTE}, ::Val{:send_rst_stream}) = STREAM_CLOSED
_get_next_state(::Val{STREAM_RESERVED_REMOTE}, ::Val{:recv_rst_stream}) = STREAM_CLOSED 

# --- Transitions from 'open' state ---
_get_next_state(::Val{STREAM_OPEN}, ::Val{:send_end_stream}) = STREAM_HALF_CLOSED_LOCAL 
_get_next_state(::Val{STREAM_OPEN}, ::Val{:recv_end_stream}) = STREAM_HALF_CLOSED_REMOTE 
_get_next_state(::Val{STREAM_OPEN}, ::Val{:send_rst_stream}) = STREAM_CLOSED 
_get_next_state(::Val{STREAM_OPEN}, ::Val{:recv_rst_stream}) = STREAM_CLOSED
# No-op transitions (valid but do not change state)
_get_next_state(::Val{STREAM_OPEN}, ::Val{:send_data}) = nothing
_get_next_state(::Val{STREAM_OPEN}, ::Val{:recv_data}) = nothing
_get_next_state(::Val{STREAM_OPEN}, ::Val{:send_headers}) = nothing
_get_next_state(::Val{STREAM_OPEN}, ::Val{:recv_headers}) = nothing


# --- Transitions from 'half_closed_local' state ---
_get_next_state(::Val{STREAM_HALF_CLOSED_LOCAL}, ::Val{:recv_end_stream}) = STREAM_CLOSED 
_get_next_state(::Val{STREAM_HALF_CLOSED_LOCAL}, ::Val{:send_rst_stream}) = STREAM_CLOSED 
_get_next_state(::Val{STREAM_HALF_CLOSED_LOCAL}, ::Val{:recv_rst_stream}) = STREAM_CLOSED 
# No-op transitions
_get_next_state(::Val{STREAM_HALF_CLOSED_LOCAL}, ::Val{:recv_data}) = nothing 
_get_next_state(::Val{STREAM_HALF_CLOSED_LOCAL}, ::Val{:recv_headers}) = nothing 

# --- Transitions from 'half_closed_remote' state ---
_get_next_state(::Val{STREAM_HALF_CLOSED_REMOTE}, ::Val{:send_end_stream}) = STREAM_CLOSED 
_get_next_state(::Val{STREAM_HALF_CLOSED_REMOTE}, ::Val{:send_rst_stream}) = STREAM_CLOSED 
_get_next_state(::Val{STREAM_HALF_CLOSED_REMOTE}, ::Val{:recv_rst_stream}) = STREAM_CLOSED 
# No-op transitions
_get_next_state(::Val{STREAM_HALF_CLOSED_REMOTE}, ::Val{:send_data}) = nothing 
_get_next_state(::Val{STREAM_HALF_CLOSED_REMOTE}, ::Val{:send_headers}) = nothing 

# --- Final 'closed' state ---
_get_next_state(::Val{STREAM_CLOSED}, ::Val{:any_late_frame_event}) = nothing

# =============================================================================
# STATE QUERY FUNCTIONS
# =============================================================================

"""
    stream_is_open(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the OPEN state.
"""
stream_is_open(stream::HTTP2Stream) = stream.state == StreamState.streamOpen

"""
    stream_is_closed(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the CLOSED state.
"""
stream_is_closed(stream::HTTP2Stream) = stream.state == StreamState.streamClosed

"""
    is_half_closed_local(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the HALF_CLOSED_LOCAL state.
"""
is_half_closed_local(stream::HTTP2Stream) = stream.state == StreamState.streamHalfClosedLocal

"""
    is_half_closed_remote(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the HALF_CLOSED_REMOTE state.
"""
is_half_closed_remote(stream::HTTP2Stream) = stream.state == StreamState.streamHalfClosedRemote

"""
    is_idle(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the IDLE state.
"""
is_idle(stream::HTTP2Stream) = stream.state == StreamState.streamIdle

"""
    is_reserved_local(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the RESERVED_LOCAL state.
"""
is_reserved_local(stream::HTTP2Stream) = stream.state == StreamState.streamReservedLocal

"""
    is_reserved_remote(stream::HTTP2Stream) -> Bool

Returns true if the stream is in the RESERVED_REMOTE state.
"""
is_reserved_remote(stream::HTTP2Stream) = stream.state == StreamState.streamReservedRemote

function Base.show(io::IO, state::StreamState)
    println(io, "HTTP/2 Stream State: $(state)")
end

end