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
   transition_stream_state!,update_activity!, replenish_receive_window!, apply_priority_frame!,
    wait_for_headers, wait_for_body, apply_rst_stream_frame!, CleanupStream,
    priority_weight,
    update_stream_dependency!,
    get_priority_tree,
    open_stream!,
    register_stream!,
    send_frame_on_stream,
    mux_close_stream!    




# --- Helper Functions ---
function update_activity!(stream::HTTP2Stream)
    stream.last_activity = Dates.now()
end

"""
    replenish_receive_window!(stream::HTTP2Stream, amount::Int)

Acknowledges that `amount` bytes have been consumed by the application,
and sends WINDOW_UPDATE H2Frames if necessary to replenish the windows.
"""
function replenish_receive_window!(stream::HTTP2Stream, amount::Int)
    conn = stream.connection
    
    stream.receive_window += amount
    conn.receive_window += amount

    maybe_send_window_update(stream)
    maybe_send_window_update(conn)
end

"""
    maybe_send_window_update(stream::HTTP2Stream)

Sends a stream-level WINDOW_UPDATE if the receive window is low.
"""
function maybe_send_window_update(stream::HTTP2Stream)
    threshold = stream.connection.settings.initial_window_size ÷ 2
    if stream.receive_window <= threshold
        increment = stream.connection.settings.initial_window_size - stream.receive_window
        if increment > 0
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
    threshold = conn.settings.initial_window_size ÷ 2
    if conn.receive_window <= threshold
        increment = conn.settings.initial_window_size - conn.receive_window
        if increment > 0
            wu_frame = create_connection_window_update(increment)
            send_frame_on_stream(conn.multiplexer, 0, wu_frame)
        end
    end
end

function wait_for_headers(stream::HTTP2Stream)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Called wait_for_headers. Acquiring lock..."
    
    @lock stream.connection.lock begin
        @debug "[$role][T$(threadid())] Stream $(stream.id): Acquired lock for wait_for_headers."
        while isempty(stream.headers) && !stream.end_stream_received && is_active(stream)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Headers not ready, now WAITING on condition..."
            wait(stream.headers_available)
            @debug "[$role][T$(threadid())] Stream $(stream.id): WOKE UP from wait. Re-checking condition."
        end
        
        @debug "[$role][T$(threadid())] Stream $(stream.id): Condition met. Returning from wait_for_headers."
        return stream.headers
    end
end

function wait_for_body(stream::HTTP2Stream)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Called wait_for_body. Acquiring lock..."
    local read_data

    @lock stream.connection.lock begin
        @debug "[$role][T$(threadid())] Stream $(stream.id): Acquired lock for wait_for_body."
        while bytesavailable(stream.data_buffer) == 0 && !stream.end_stream_received && is_active(stream)
            @debug "[$role][T$(threadid())] Stream $(stream.id): Body not ready, now WAITING on condition..."
            wait(stream.data_available)
            @debug "[$role][T$(threadid())] Stream $(stream.id): WOKE UP from wait. Re-checking condition."
        end
        
        @debug "[$role][T$(threadid())] Stream $(stream.id): Data available or stream ended. Reading buffer."
        seekstart(stream.data_buffer)
        read_data = read(stream.data_buffer)
    end
    
    if !isempty(read_data)
        replenish_receive_window!(stream, length(read_data))
    end
    
    @debug "[$role][T$(threadid())] Stream $(stream.id): Returning $(length(read_data)) bytes from wait_for_body."
    return read_data
end


function open_stream!(mux::StreamMultiplexer)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @lock mux.send_lock begin
        if !should_accept_new_streams(mux.conn)
            throw(ProtocolError("Cannot open new stream; connection is shutting down."))
        end
        if length(mux.conn.streams) >= mux.conn.remote_settings.max_concurrent_streams
            throw(StreamError(REFUSED_STREAM, "Maximum concurrent streams reached", 0))
        end
        stream_id = mux.next_stream_id
        mux.next_stream_id += 2
        stream = HTTP2Stream(stream_id, mux.conn)
        mux.conn.streams[stream_id] = stream
        mux.frame_channels[stream_id] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
        @debug "[$role][T$(threadid())] Mux: Stream $stream_id created and registered."
        return stream
    end
end

"""
    should_accept_new_streams(conn::HTTP2Connection) -> Bool

Ελέγχει αν η σύνδεση είναι σε κατάσταση που μπορεί να δεχτεί νέα streams.
Επιστρέφει `false` αν έχει σταλεί ή ληφθεί GOAWAY.
"""
function should_accept_new_streams(conn::HTTP2Connection)
    return !(conn.goaway_sent || conn.goaway_received)
end

"""
    is_stream_allowed(conn::HTTP2Connection, stream_id::UInt32) -> Bool

Ελέγχει αν ένα stream με το συγκεκριμένο ID επιτρέπεται να συνεχίσει
να επεξεργάζεται, με βάση το `last_stream_id` που έχει ενδεχομένως
ληφθεί σε ένα GOAWAY frame.
"""
function is_stream_allowed(conn::HTTP2Connection, stream_id::UInt32)
    if conn.goaway_received
        return stream_id <= conn.last_peer_stream_id
    end
    return true
end

function send_frame_on_stream(mux::StreamMultiplexer, stream_id::UInt32, frame::Union{HTTP2Frame, CleanupStream})
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Mux: Queueing frame $(frame) on stream $stream_id"

    @lock mux.send_lock begin
        channel = get(mux.frame_channels, stream_id, nothing)
        if channel === nothing || !isopen(channel)
            throw(StreamError(UInt32(STREAM_CLOSED), "Cannot send frame on closed stream $stream_id", stream_id))
        end
        
        put!(channel, frame)
        
        if !haskey(mux.pending_streams, stream_id)
            stream = get(mux.conn.streams, stream_id, nothing)
            priority = stream !== nothing ? Int(stream.priority.weight) : Int(DEFAULT_WEIGHT)
            DataStructures.enqueue!(mux.pending_streams, stream_id, priority)
        end
        notify(mux.send_condition)
    end
end

send_frame_on_stream(mux::StreamMultiplexer, stream_id::Integer, frame::Union{HTTP2Frame, CleanupStream}) =  send_frame_on_stream(mux, UInt32(stream_id), frame) 


function register_stream!(mux::StreamMultiplexer, stream::HTTP2Stream)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER"
    @lock mux.send_lock begin
        if !haskey(mux.frame_channels, stream.id)
            mux.frame_channels[stream.id] = Channel{Union{HTTP2Frame, CleanupStream}}(32)
            @debug "[$role][T$(threadid())] Mux: Created new frame_channel for peer-initiated stream $(stream.id)."
        end
    end
end

"""
    apply_rst_stream_frame!(connection_state, frame::RstStreamFrame)

Complete implementation for applying RST_STREAM frame to connection state.
"""
function apply_rst_stream_frame!(connection_state, frame::RstStreamFrame)
    stream = get(connection_state.streams, frame.stream_id, nothing)
    if stream !== nothing && is_active(stream)
        close(stream)
        @debug "Applied RST_STREAM frame and closed stream" stream_id=frame.stream_id error_code=error_code_name(Symbol(frame.error_code))
    else
        @debug "RST_STREAM received for unknown ή already closed stream" stream_id=frame.stream_id
    end
end

"""
    apply_priority_frame!(conn::HTTP2Connection, frame::PriorityFrame)

Εφαρμόζει τις πληροφορίες προτεραιότητας από ένα PRIORITY frame σε ένα stream.
Ενημερώνει την προτεραιότητα του stream, το δέντρο εξαρτήσεων, και την ουρά
προτεραιότητας του multiplexer.
"""
function apply_priority_frame!(conn::HTTP2Connection, frame::PriorityFrame)
    @lock conn.lock begin
        stream = get_stream(conn, frame.stream_id)
        if stream === nothing
            @debug "Received PRIORITY for idle/unknown stream $(frame.stream_id). Ignoring."
            return
        end

        new_weight = H2Frames.Priority.actual_weight(frame) # Παίρνουμε το 1-256
        stream.priority = StreamPriority(frame.exclusive, frame.stream_dependency, new_weight)
        
        update_stream_dependency!(
            conn.streams,
            frame.stream_id,
            frame.stream_dependency,
            frame.exclusive
        )
        mux = conn.multiplexer
        if haskey(mux.pending_streams, stream.id)
            mux.pending_streams[stream.id] = new_weight
            @debug "Updated priority for stream $(stream.id) in queue to $(new_weight)."
        end
    end
end


function mux_close_stream!(mux::StreamMultiplexer, stream_id::UInt32, error_code::Union{Symbol, Nothing}=nothing)
    stream = get(mux.conn.streams, stream_id, nothing)
    if stream === nothing || !is_active(stream)
        return
    end

    if error_code !== nothing
        numeric_error_code = Exc.error_code_value(error_code)
        rst_frame = RstStreamFrame(stream_id, numeric_error_code)
        send_frame_on_stream(mux, stream_id, rst_frame)
    end
    
    send_frame_on_stream(mux, stream_id, CleanupStream())

    close(stream)
end

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
    if stream_id == dependency_id
        throw(ArgumentError("A stream cannot depend on itself"))
    end
    stream = get(streams, stream_id, nothing)
    dependency = get(streams, dependency_id, nothing)
    if stream === nothing
        throw(ArgumentError("Stream $stream_id does not exist"))
    end
    if stream.parent !== nothing
        deleteat!(stream.parent.children, findfirst(==(stream), stream.parent.children))
    end
    stream.parent = dependency
    if dependency !== nothing
        if exclusive
            old_children = copy(dependency.children)
            dependency.children = [stream]
            for child in old_children
                if child !== stream
                    child.parent = stream
                    push!(stream.children, child)
                end
            end
        else
            push!(dependency.children, stream)
        end
    end
end

"""
    get_priority_tree(streams::Dict{Int32, HTTP2Stream})

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

"""
    can_create_stream(conn::HTTP2Connection)

Check if a new stream can be created based on max concurrent streams setting.
"""
function can_create_stream(conn::HTTP2Connection)
    active_streams = length(conn.streams)
    max_streams = conn.remote_settings.max_concurrent_streams
    
    return max_streams == typemax(UInt32) || active_streams < max_streams
end

# ============================================================================= 
# Stream State Machine 
# ============================================================================= 
"""
    transition_stream_state!(stream::HTTP2Stream, event::Symbol)

Transition the stream state according to RFC 7540 §5.1.
The event can be:
- :send_headers, :recv_headers
- :send_push_promise, :recv_push_promise
- :send_data, :recv_data
- :send_rst_stream, :recv_rst_stream
- :send_end_stream, :recv_end_stream
"""
function transition_stream_state!(stream::HTTP2Stream, event::Symbol)
    state = stream.state
    new_state = nothing

    if state == STREAM_IDLE
        if event == :send_headers || event == :recv_headers
            new_state = STREAM_OPEN
        elseif event == :send_push_promise
            new_state = STREAM_RESERVED_LOCAL
        elseif event == :recv_push_promise
            new_state = STREAM_RESERVED_REMOTE
        end
    elseif state == STREAM_RESERVED_LOCAL
        if event == :send_headers
            new_state = STREAM_HALF_CLOSED_REMOTE
        elseif event == :recv_rst_stream
            new_state = STREAM_CLOSED
        end
    elseif state == STREAM_RESERVED_REMOTE
        if event == :send_headers
            new_state = STREAM_HALF_CLOSED_LOCAL
        elseif event == :recv_rst_stream
            new_state = STREAM_CLOSED
        end
    elseif state == STREAM_OPEN
        if event == :send_data || event == :recv_data || event == :send_headers || event == :recv_headers
            # It's valid to send/receive data or headers in OPEN state; state does not change.
            return
        elseif event == :send_end_stream
            new_state = STREAM_HALF_CLOSED_LOCAL
        elseif event == :recv_end_stream
            new_state = STREAM_HALF_CLOSED_REMOTE
        elseif event == :send_rst_stream || event == :recv_rst_stream
            new_state = STREAM_CLOSED
        end
    elseif state == STREAM_HALF_CLOSED_LOCAL
        if event == :recv_data || event == :recv_headers
            return
        elseif event == :recv_end_stream
            new_state = STREAM_CLOSED
        elseif event == :send_rst_stream || event == :recv_rst_stream
            new_state = STREAM_CLOSED
        end
    elseif state == STREAM_HALF_CLOSED_REMOTE
        if event == :send_data || event == :send_headers
            return
        elseif event == :send_end_stream
            new_state = STREAM_CLOSED
        elseif event == :send_rst_stream || event == :recv_rst_stream
            new_state = STREAM_CLOSED
        end
    end

    if new_state !== nothing
        @debug "Stream $(stream.id): State $state → $new_state (event: $event)"
        stream.state = new_state
    else
        throw(Exc.ProtocolError("Invalid stream state transition: $state + $event"))
    end
end

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

# Pretty print
function Base.show(io::IO, state::StreamState)
    println(io, "HTTP/2 Stream State: $(state)")
end

end