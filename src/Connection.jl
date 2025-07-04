module Connection
# src/connection/connection.jl

using H2Frames: HTTP2Frame, RstStreamFrame, HeadersFrame, DataFrame, ContinuationFrame, WindowUpdateFrame, GoAwayFrame, PingFrame, PushPromiseFrame, SettingsFrame, PriorityFrame, serialize_payload, serialize_frame, stream_id
using HPACK
using H2Frames
using DataStructures
using Base.Threads: threadid


using ..Exc: ProtocolError, HTTP2Exception, exception_to_error_code
using ..H2Types, ..H2Settings, ..Exc, ..Streams, ....RateLimiter 



export is_client, is_server, next_stream_id, add_stream, get_stream, remove_stream,
       send_preface!, receive_preface!, process_received_frame, process_connection_frame,
       apply_settings, close_connection!, ping, update_window, create_client_stream!, send_goaway!, update_send_window!,
    consume_receive_window!, replenish_receive_window!, update_all_stream_send_windows!, send_headers!, send_data!,
    receive_headers!, receive_data!


function send_loop(mux::StreamMultiplexer)
    role = is_client(mux.conn) ? "CLIENT" : "SERVER" 
    @debug "[$role][T$(threadid())] SendLoop: Starting."
    try 
        while !is_closed(mux.conn)
            local item_to_send::Union{HTTP2Frame, CleanupStream, Nothing} = nothing
            local stream_id_to_process::Union{UInt32, Nothing} = nothing
            
            @lock mux.send_lock begin
                while isempty(mux.pending_streams) && !is_closed(mux.conn)
                    @debug "[$role][T$(threadid())] SendLoop: Queue empty, waiting on condition..."
                    wait(mux.send_condition)
                end

                if is_closed(mux.conn)
                    break
                end
                
                pair = dequeue_pair!(mux.pending_streams)
                stream_id_to_process = pair.first
                priority = pair.second
                
                channel = get(mux.frame_channels, stream_id_to_process, nothing)
                
                if channel !== nothing && isready(channel)
                    item_to_send = take!(channel)
                    if isopen(channel) && isready(channel)
                        enqueue!(mux.pending_streams, stream_id_to_process, priority)
                    end
                end
            end 

            if item_to_send isa HTTP2Frame
                @debug "[$role][T$(threadid())] SendLoop: Sending frame $(item_to_send)" 
                try
                    send_frame(mux.conn, serialize_frame(item_to_send))
                catch e
                    @error "[$role][T$(threadid())] SendLoop: Socket write error." exception=(e, catch_backtrace()) 
                    handle_connection_error!(mux.conn, :INTERNAL_ERROR, "Socket write failure")
                    break
                end
            elseif item_to_send isa CleanupStream
                @debug "[$role][T$(threadid())] SendLoop: Cleaning up stream $(stream_id_to_process)."
                @lock mux.send_lock begin
                    delete!(mux.conn.streams, stream_id_to_process)
                    channel_to_close = pop!(mux.frame_channels, stream_id_to_process, nothing)
                    if channel_to_close !== nothing && isopen(channel_to_close)
                        close(channel_to_close)
                    end
                end
            end
           
            yield()
        end
    catch ex
        if !(ex isa InvalidStateException)
            @error "[$role][T$(threadid())] SendLoop: Unhandled exception." exception=(ex, catch_backtrace())
        end
    finally
        @debug "[$role][T$(threadid())] SendLoop: Shutdown."
    end
end

function send_headers!(stream::HTTP2Stream, headers::Vector{<:Pair{<:AbstractString, <:AbstractString}}; end_stream::Bool=false)
    role = stream.connection.role
    @debug "[$role][T$(threadid())] Stream $(stream.id): Queueing HEADERS" headers=headers end_stream=end_stream

    final_headers = [lowercase(String(k)) => String(v) for (k, v) in headers]

    # Lock the stream only to perform the state transition
    @lock stream.lock begin
        transition_stream_state!(stream, :send_headers)
        if end_stream
            transition_stream_state!(stream, :send_end_stream)
        end
    end

    # HPACK encoding can happen outside the lock. The send_loop will serialize it.
    header_block = HPACK.encode_headers(stream.connection.hpack_encoder, final_headers)
    frame = HeadersFrame(stream.id, header_block; end_stream=end_stream)

    # Correctly queue the frame for the multiplexer's send_loop
    send_frame_on_stream(stream.connection.multiplexer, stream.id, frame)
    
    @debug "[$role][T$(threadid())] Stream $(stream.id): HEADERS frame queued."
end

function send_data!(stream::HTTP2Stream, data::Vector{UInt8}; end_stream::Bool=false)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Queueing DATA" bytes=length(data) end_stream=end_stream

    # Lock the stream only to perform the state transition
    @lock stream.lock begin
        transition_stream_state!(stream, :send_data)
    end
    
    max_frame_size = Int(stream.connection.remote_settings.max_frame_size)
    frames_to_send = create_data_frame(stream.id, data; end_stream=false, max_frame_size=max_frame_size)

    if isempty(frames_to_send) && end_stream
        empty_frame = DataFrame(stream.id, UInt8[]; end_stream=true)
        send_frame_on_stream(stream.connection.multiplexer, stream.id, empty_frame)
    else
        # Queue each DATA frame for the send_loop
        for (i, frame) in enumerate(frames_to_send)
            is_last_frame = (i == length(frames_to_send))
            final_end_stream = is_last_frame && end_stream
            
            final_frame = DataFrame(frame.stream_id, frame.data; end_stream=final_end_stream)
            send_frame_on_stream(stream.connection.multiplexer, stream.id, final_frame)
        end
    end

    if end_stream
        # Lock the stream again only for the final state transition
        @lock stream.lock begin
            transition_stream_state!(stream, :send_end_stream)
        end
    end
end


function receive_headers!(stream::HTTP2Stream, headers::Vector{<:Pair{<:AbstractString, <:AbstractString}}; end_stream::Bool=false)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(threadid())] Stream $(stream.id): Receiving HEADERS, acquiring lock..."
    
    @lock stream.lock begin
        @debug "[$role][T$(threadid())] Stream $(stream.id): Acquired lock. Setting headers."
        stream.headers = headers
        transition_stream_state!(stream, :recv_headers)
        if end_stream
            @debug "[$role][T$(threadid())] Stream $(stream.id): END_STREAM flag received with headers."
            stream.end_stream_received = true
        end
        @debug "[$role][T$(threadid())] Stream $(stream.id): Notifying headers_available (inside lock)."
        notify(stream.headers_available; all=true)
        @debug "[$role][T$(threadid())] Stream $(stream.id): Releasing lock after notify."
    end
    update_activity!(stream)
end



function receive_data!(stream::HTTP2Stream, data::Vector{UInt8}; end_stream::Bool=false)
    role = is_client(stream.connection) ? "CLIENT" : "SERVER" 
    @debug "[$role][T$(threadid())] Stream $(stream.id): Receiving DATA (bytes: $(length(data)))"

    if length(data) > stream.receive_window || length(data) > stream.connection.receive_window 
        throw(FlowControlError("Received more data than the advertised window size", stream.id))
    end
    
    consume_receive_window!(stream, length(data))

    @lock stream.lock begin
        write(stream.data_buffer, data)
        transition_stream_state!(stream, :recv_data)
        if end_stream
             @debug "[$role][T$(threadid())] Stream $(stream.id): END_STREAM flag received with data." 
             stream.end_stream_received = true
        end
        notify(stream.data_available; all=true)
    end
    
    replenish_receive_window!(stream, length(data))
    
    update_activity!(stream)
end
"""
    next_stream_id(conn::HTTP2Connection) -> UInt32

Get the next available stream ID for this connection.
Clients use odd numbers (1, 3, 5, ...), servers use even numbers (2, 4, 6, ...).
"""
function next_stream_id(conn::HTTP2Connection)
    @lock conn.streams_lock begin
        current = conn.last_stream_id
        conn.last_stream_id += 2  # Skip by 2 to maintain odd/even pattern
        return current
    end
end

"""
    add_stream(conn::HTTP2Connection, stream::HTTP2Stream)

Add a stream to the connection's stream table.
"""
function add_stream(conn::HTTP2Connection, stream::HTTP2Stream)
    @lock conn.streams_lock begin
        conn.streams[stream.id] = stream
        
        if (is_client(conn) && iseven(stream.id)) || (is_server(conn) && isodd(stream.id))
            conn.last_peer_stream_id = max(conn.last_peer_stream_id, stream.id)
        end
    end
end

"""
    get_stream(conn::HTTP2Connection, stream_id::UInt32) -> Union{HTTP2Stream, Nothing}

Get a stream by its ID, or nothing if it doesn't exist.
"""
function get_stream(conn::HTTP2Connection, stream_id::UInt32)
    @lock conn.streams_lock begin
        return get(conn.streams, stream_id, nothing)
    end
end

"""
    remove_stream(conn::HTTP2Connection, stream_id::UInt32)

Remove a stream from the connection's stream table.
"""
function remove_stream(conn::HTTP2Connection, stream_id::UInt32)
    @lock conn.streams_lock begin
        delete!(conn.streams, stream_id)
    end
end



function create_client_stream!(conn::HTTP2Connection)
    @lock conn.streams_lock begin
        # Έλεγχος αν μπορούμε να δημιουργήσουμε νέο stream
        if length(conn.streams) >= conn.remote_settings.max_concurrent_streams
            throw(StreamLimitError("Cannot create new stream, remote limit reached"))
        end

        new_id = conn.last_stream_id
        conn.last_stream_id += 2

        stream = HTTP2Stream(new_id, conn)
        add_stream(conn, stream)

        return stream
    end
end

"""
    start_connection_loops!(conn::HTTP2Connection)

Starts the asynchronous I/O and processing loops for the connection.
This is the main entry point for running the connection.
"""
function start_connection_loops!(conn::HTTP2Connection)
    conn_id = conn.id   
    
    @async io_loop_with_client_info(conn, conn_id)
    @async processing_loop_with_client_info(conn, conn_id)

    @async send_loop(conn.multiplexer)
end

function io_loop_with_client_info(conn::HTTP2Connection, conn_id::String)
    role = conn.role
    @debug "IO Loop: Starting for Role: $role, ID: $conn_id"

    try
        while isopen(conn.socket) && !eof(conn.socket)
            header_bytes = read(conn.socket, 9)
            if length(header_bytes) < 9; break; end
            
            header = H2Frames.deserialize_frame_header(header_bytes)
            @debug "IO Loop ($role): Received frame header - Type: $(header.frame_type)), Stream: $(header.stream_id), Length: $(header.length)"
            
            payload_bytes = read(conn.socket, header.length)
            if length(payload_bytes) < header.length; break; end
            
            frame = H2Frames.create_frame(header, payload_bytes)
            
            @debug "IO Loop ($role): Received full frame, queueing for processing -> Type: $(frame))"
            put!(conn.frame_channel, frame)
            
            yield()
        end
    catch e
        if !(e isa EOFError || (e isa Base.IOError && e.code in (-54, -32))) # -54: ECONNRESET, -32: EPIPE
            @error "IO Loop Exception ($role, ID: $conn_id)" exception=(e, catch_backtrace())
        else
            @debug "IO Loop ($role, ID: $conn_id): Connection closed by peer."
        end
    finally
        @debug "IO Loop ($role, ID: $conn_id): Shutting down."
        close(conn.frame_channel)
    end
end

function processing_loop_with_client_info(conn::HTTP2Connection, conn_id::String)
    role = conn.role
    @debug "Processing Loop: Starting for Role: $role, ID: $conn_id"
    
    try
        for frame in conn.frame_channel
            @debug "Processing Loop ($role): Dequeued frame -> Type: $(frame))"
            process_received_frame(conn, frame)
            @debug "Processing Loop ($role): Finished processing frame."
            yield()
        end
    catch e
        @error "Processing Loop Exception ($role, ID: $conn_id)" exception=(e, catch_backtrace())
        if e isa HTTP2Exception
            close_connection!(conn, exception_to_error_code(e), "Frame processing failed")
        else
            close_connection!(conn, :INTERNAL_ERROR, "Frame processing failed")
        end
    end
    
    @debug "Processing Loop ($role, ID: $conn_id): Shutting down."
end

function process_received_frame_with_client_info(conn::HTTP2Connection, frame::HTTP2Frame, conn_id::String, client_desc::String)
    
    println("[FrameProcessor] Processing $(typeof(frame)) from client $client_desc (ID: $conn_id)")
    
    try
        process_received_frame(conn, frame)
    catch e
        println("[FrameProcessor] Error processing frame from client $client_desc: $e")
        rethrow()
    end
end





"""
    process_received_frame(conn::HTTP2Connection, frame::HTTP2Frame)

Process a received frame, dispatching to connection-level or stream-level handlers.
This is the main entry point for processing all incoming frames from the I/O loop.
"""
function process_received_frame(conn::HTTP2Connection, frame::HTTP2Frame)
    sid = stream_id(frame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(Threads.threadid())] Frame Processing: Starting for frame $(H2Frames.frame_summary(frame))" 

    # 1. Apply Rate Limiting
    if !consume_token!(conn.rate_limiter)
        @warn "[Conn] Rate limit exceeded for connection $(conn.id). Sending ENHANCE_YOUR_CALM." 
        last_stream = get_highest_stream_id(conn)
        @lock conn.state_lock begin
            send_goaway!(conn, last_stream, :ENHANCE_YOUR_CALM, "Rate limit exceeded")
        end
        close_connection!(conn, :ENHANCE_YOUR_CALM, "Rate limit exceeded") 
        return
    end

    # 2. Dispatch Connection-Level Frames (Stream ID 0)
    if sid == 0
        process_connection_frame(conn, frame) # This function should also be refactored (see step 3)
        @debug "[$role][T$(Threads.threadid())] Frame Processing: Finished connection-level frame." 
        return
    end

    # 3. Handle Stream-Level Frames
    if conn.continuation_stream_id != 0 && !(frame isa ContinuationFrame)
        @error "[$role][T$(Threads.threadid())] Protocol Error: Expected CONTINUATION frame, got $(typeof(frame))." 
        throw(ProtocolError("Invalid frame during continuation")) 
    end

    stream = get_stream(conn, sid)
    is_new_stream = (stream === nothing)

    # 4. Get or Create Stream
    if is_new_stream
        if !(frame isa HeadersFrame || frame isa PriorityFrame)
            @error "[$role][T$(Threads.threadid())] Protocol Error: Received invalid frame for new stream $sid. Expected HEADERS or PRIORITY." 
            throw(ProtocolError("Invalid frame type for new stream")) 
        end
        @debug "[$role][T$(Threads.threadid())] Frame Processing: Creating new stream $sid." 
        stream = HTTP2Stream(sid, conn) 
        add_stream(conn, stream) 
        Streams.register_stream!(conn.multiplexer, stream) 
    elseif !is_active(stream) && !(frame isa PriorityFrame)
        # Per RFC 7540, ignore frames for closed streams, except PRIORITY.
        @warn "Received frame for a closed stream. Ignoring." stream_id=sid frame_type=typeof(frame) 
        return
    end

    # 5. Lock and Dispatch to the appropriate stream_frame handler
    @lock conn.streams_lock begin
        try
            # The magic of multiple dispatch happens here!
            process_stream_frame(conn, stream, frame)

            # Spawn request handler if a new stream was just opened by receiving a complete HEADERS frame.
            if is_new_stream && is_server(conn) && conn.request_handler !== nothing && frame isa HeadersFrame && frame.end_headers
                @debug "[$role][T$(Threads.threadid())] ┗━ Spawning request handler for new stream $sid." 
                errormonitor(@async conn.request_handler(conn, stream)) 
            end
        catch e
            @error "[$role][T$(Threads.threadid())] Frame Processing -> ERROR during dispatch on stream $sid" exception=(e, catch_backtrace()) 
            if stream !== nothing && is_active(stream)
                # If something goes wrong, reset the specific stream.
                Streams.mux_close_stream!(conn.multiplexer, sid, :INTERNAL_ERROR)
            end
        end
    end
    @debug "[$role][T$(Threads.threadid())] Frame Processing: <<<< FINISHED >>>> for frame on stream $sid."
end

function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::HTTP2Frame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
   @warn "[$role][T$(Threads.threadid())] Frame Processing: Unhandled or invalid frame type $(typeof(frame)) on stream $(stream.id). Ignoring."
end

"""
Processes a HEADERS frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::HeadersFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    if !frame.end_headers
        @debug "[$role][T$(Threads.threadid())] ┣━ Buffering HEADERS fragment for stream $(stream.id)..."
        truncate(conn.header_buffer, 0)
        write(conn.header_buffer, frame.header_block_fragment)
        conn.continuation_stream_id = stream.id
        conn.continuation_end_stream = frame.end_stream 
    else
        @debug "[$role][T$(Threads.threadid())] ┣━ DECODING headers for stream $(stream.id)..."
        header_block = frame.header_block_fragment
        
        # Enforce MAX_HEADER_LIST_SIZE
        if length(header_block) > conn.remote_settings.max_header_list_size
            throw(ProtocolError("Header block size exceeds peer's MAX_HEADER_LIST_SIZE"))
        end
        local decoded_headers
        decoded_headers = HPACK.decode_headers(conn.hpack_decoder, frame.header_block_fragment)
        @debug "[$role][T$(Threads.threadid())] ┣━ CALLING receive_headers! for stream $(stream.id)..."
        receive_headers!(stream, decoded_headers; end_stream=frame.end_stream)
        @debug "[$role][T$(Threads.threadid())] ┣━ RETURNED from receive_headers! for stream $(stream.id)."
    end
end

"""
Processes a DATA frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::DataFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(Threads.threadid())] ┣━ CALLING receive_data! for stream $(stream.id)..."
    receive_data!(stream, frame.data; end_stream=frame.end_stream)
    @debug "[$role][T$(Threads.threadid())] ┗━ RETURNED from receive_data! for stream $(stream.id)."
end

"""
Processes a CONTINUATION frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::ContinuationFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    if frame.stream_id != conn.continuation_stream_id
        throw(ProtocolError("CONTINUATION frame on wrong stream"))
    end
    @debug "[$role][T$(Threads.threadid())] ┣━ Buffering CONTINUATION fragment for stream $(stream.id)..."
    write(conn.header_buffer, frame.header_block_fragment)
   if frame.end_headers
        full_header_block = take!(conn.header_buffer)
        promised_id = conn.pending_push_promise_id
        continuation_end_stream_flag = conn.continuation_end_stream
        conn.continuation_stream_id = 0
        conn.pending_push_promise_id = 0

        decoded_headers = HPACK.decode_headers(conn.hpack_decoder, full_header_block)

        if promised_id != 0
            promised_stream = get_stream(conn, promised_id)
            if promised_stream !== nothing
                receive_headers!(promised_stream, decoded_headers; end_stream=false)
                @debug "[CLIENT] Finished PUSH_PROMISE continuation for stream $(promised_id)."
            end
        else
            # No, it was a regular HEADERS continuation.
            # 'stream' is the correct target for the response headers.
            receive_headers!(stream, decoded_headers; end_stream=continuation_end_stream_flag)
        end
    end
end

"""
Processes a WINDOW_UPDATE frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::WindowUpdateFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(Threads.threadid())] ┣━ Applying WINDOW_UPDATE for stream $(stream.id)..."
    apply_flow_control_update(frame, conn) 
    @debug "[$role][T$(Threads.threadid())] ┗━ Send window for stream $(stream.id) updated." 
end

"""
Processes an RST_STREAM frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::RstStreamFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(Threads.threadid())] ┣━ Processing RST_STREAM for stream $(stream.id)..." 
    Streams.apply_rst_stream_frame!(conn, frame)
    @debug "[$role][T$(Threads.threadid())] ┗━ Stream $(stream.id) has been reset." 
end

"""
Processes a PRIORITY frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::PriorityFrame)
    role = is_client(conn) ? "CLIENT" : "SERVER"
    @debug "[$role][T$(Threads.threadid())] ┣━ Applying PRIORITY update for stream $(stream.id)..." 
    Streams.apply_priority_frame!(conn, frame)
    @debug "[$role][T$(Threads.threadid())] ┗━ Stream $(stream.id) priority updated." 
end

"""
Processes a PUSH_PROMISE frame.
"""
function process_stream_frame(conn::HTTP2Connection, stream::HTTP2Stream, frame::PushPromiseFrame)
    if is_client(conn)
        role = "CLIENT"
        @debug "[$role][T$(Threads.threadid())] ┣━ Processing PUSH_PROMISE for associated stream $(stream.id)..." 
        process_push_promise(conn, frame)
        @debug "[$role][T$(Threads.threadid())] ┗━ PUSH_PROMISE for stream $(frame.promised_stream_id) processed." 
    else
        throw(ProtocolError("Server received a PUSH_PROMISE frame on stream $(stream.id)"))
    end
    @debug "[$role][T$(Threads.threadid())] Frame Processing: <<<< FINISHED >>>> for frame on stream $sid."
end

"""
    send_preface!(conn::HTTP2Connection)

Send the HTTP/2 connection preface.
For clients, this is the magic string followed by a SETTINGS frame.
For servers, this is just a SETTINGS frame.
"""

function send_preface!(conn::HTTP2Connection)
    @lock conn.state_lock begin
        if conn.preface_sent || conn.state != CONNECTION_IDLE
            return
        end

        try
            if is_client(conn)
                println("[Conn] Client: Sending raw preface string.")
                write(conn.socket, CONNECTION_PREFACE)
            end
            println("[Conn] $(conn.role): Sending initial SETTINGS frame.")
            settings_frame = H2Settings.create_settings_frame(conn.settings)
            
            send_frame(conn, serialize_frame(settings_frame))
            
            flush(conn.socket)

            conn.preface_sent = true
            
            transition_state!(conn, CONNECTION_OPEN)
            println("[Conn] Preface sent successfully, state transitioned to OPEN.")

        catch e
            @error "Failed to send preface: $e"
            handle_connection_error!(conn, :INTERNAL_ERROR, "Failed to send preface")
        end
    end
end

"""
    receive_preface!(conn::HTTP2Connection)

Blocks to read and validate the client's connection preface. This is a critical
step for the server to synchronize with the client before frame processing begins.
"""


function receive_preface!(conn::HTTP2Connection)
    try
        if is_server(conn)
            preface_bytes = read(conn.socket, length(CONNECTION_PREFACE))
            if preface_bytes != CONNECTION_PREFACE
                throw(ProtocolError("Invalid connection preface"))
            end
        end
        
        header_bytes = read(conn.socket, FRAME_HEADER_SIZE)
        header = H2Frames.deserialize_frame_header(header_bytes)

        if header.frame_type != SETTINGS_FRAME || (header.flags & SETTINGS_ACK) != 0
            throw(ProtocolError("Expected first frame to be a non-ACK SETTINGS frame."))
        end
        
        payload = read(conn.socket, header.length)
        settings_frame = create_frame(header, payload)
        
        process_settings_frame(conn, settings_frame)
        
        conn.preface_received = true
        @debug  "[Conn] Peer preface received and processed successfully."
        return

    catch e
        if e isa HTTP2Exception
            close_connection!(conn, exception_to_error_code(e), "Failed to receive preface: $e")
        else
            close_connection!(conn, :INTERNAL_ERROR, "Failed to receive preface: $e")
        end
        rethrow(e)
    end
end



# src/Connection.jl

"""
Fallback for invalid frame types on the connection stream (ID 0).
"""
function process_connection_frame(conn::HTTP2Connection, frame::HTTP2Frame)
    throw(ProtocolError("Invalid frame type $(typeof(frame)) for stream 0"))
end

"""
Processes a connection-level SETTINGS frame.
"""
function process_connection_frame(conn::HTTP2Connection, frame::SettingsFrame)
    if is_ack(frame)
        @debug  "[Conn] Received SETTINGS ACK from peer."
    else
        process_settings_frame(conn, frame)
            
        if is_client(conn)
            # Atomically check and set the preface flag under the state_lock
            @lock conn.state_lock begin
                if !conn.preface_received
                    conn.preface_received = true
                    # The notify is for more advanced waiting patterns,
                    # but it's good to keep it here under the correct lock.
                    notify(conn.preface_handshake_done)
                end
            end
            @debug "[Client] Handshake complete: Received server SETTINGS."
        end
    end
end

"""
Processes a connection-level PING frame.
"""
function process_connection_frame(conn::HTTP2Connection, frame::PingFrame)
    process_ping_frame(conn, frame) 
end

"""
Processes a GOAWAY frame.
"""
function process_connection_frame(conn::HTTP2Connection, frame::GoAwayFrame)
    process_goaway_frame(conn, frame)
end

"""
Processes a connection-level WINDOW_UPDATE frame.
"""
function process_connection_frame(conn::HTTP2Connection, frame::WindowUpdateFrame)
    apply_flow_control_update(frame, conn)
end

"""
A PUSH_PROMISE frame MUST be associated with an existing, open stream.
Receiving one on stream 0 is a connection error.
"""
function process_connection_frame(conn::HTTP2Connection, frame::PushPromiseFrame)
    throw(ProtocolError("Received PUSH_PROMISE frame on connection stream 0")) 
end

"""
    process_goaway_frame(connection::HTTP2Connection, frame::GoAwayFrame)

Process a received GOAWAY frame on the given connection.

This will:
1. Mark the connection as closing/closed
2. Cancel streams higher than last_stream_id
3. Prevent new streams from being created
4. Call user callbacks if registered
"""

function process_goaway_frame(conn::HTTP2Connection, frame::GoAwayFrame)
    @debug "[Conn] Received GOAWAY" last_stream_id=frame.last_stream_id error_code=Exc.error_code_name(frame.error_code)
    streams_to_cancel = HTTP2Stream[]

    @lock conn.state_lock begin
        if conn.goaway_received
            return
        end

        conn.goaway_received = true
        conn.last_peer_stream_id = frame.last_stream_id
        transition_state!(conn, CONNECTION_GOAWAY_RECEIVED)

        for (sid, stream) in conn.streams
            if sid > frame.last_stream_id && is_client(conn) == isodd(sid)
                push!(streams_to_cancel, stream)
            end
        end
    end 

    for stream in streams_to_cancel
        @debug "[Conn] Closing stream $(stream.id) due to GOAWAY"
        mux_close_stream!(conn.multiplexer, stream.id, :REFUSED_STREAM)
    end
end

"""
    process_ping_frame(connection::HTTP2Connection, frame::PingFrame)

Process a received PING frame on the given connection.

If the frame is a PING request, automatically sends a PING ACK response.
If the frame is a PING ACK, processes it as a response to an outstanding PING.
"""


function process_ping_frame(connection::HTTP2Connection, frame::PingFrame)
    if !H2Frames.Ping.is_ping_ack(frame)
        @debug "[Conn] Received PING request, queuing ACK."
        
        ack_frame = H2Frames.Ping.PingAckFrame(frame)
    
        send_frame_on_stream(connection.multiplexer, UInt32(0), ack_frame)
        
    else
        @debug "[Conn] Received PING ACK."
        ping_id = get_ping_data_as_uint64(frame)
        
        entry = @lock connection.pings_lock begin
            pop!(connection.pending_pings, ping_id, nothing)
        end

        if entry !== nothing
            start_time, response_channel = entry
            if isopen(response_channel)
                rtt = time() - start_time
                @debug "[Conn] PING RTT calculated: $rtt. Notifying waiting task."
                put!(response_channel, rtt)
            end
        else
            @warn "[Conn] Received PING ACK for unknown id: $ping_id (likely timed out)."
        end
    end
end


"""
    get_debug_message(frame::GoAwayFrame) -> String

Get the debug data as a UTF-8 string from a GOAWAY frame.
"""
function get_debug_message(frame::GoAwayFrame)
    try
        return String(frame.debug_data)
    catch
        return "0x" * bytes2hex(frame.debug_data)
    end
end

"""
Handles a received PUSH_PROMISE frame.
"""
function process_push_promise(conn::HTTP2Connection, frame::PushPromiseFrame)
    original_stream = get_stream(conn, frame.stream_id)
    if original_stream === nothing || !is_active(original_stream)
        @warn "Received PUSH_PROMISE on a non-existent or inactive stream $(frame.stream_id). Ignoring."
        return
    end

    # Step 1: ALWAYS create and register the promised stream locally first.
    promised_stream = HTTP2Stream(frame.promised_stream_id, conn)
    add_stream(conn, promised_stream)
    Streams.register_stream!(conn.multiplexer, promised_stream)
    transition_stream_state!(promised_stream, :recv_push_promise)

    # Step 2: Decide whether to keep or reject the stream.
    if !conn.settings.enable_push
        @debug "[CLIENT] Push is disabled. Rejecting promised stream $(frame.promised_stream_id)."
        error_val = Exc.error_code_value(REFUSED_STREAM)
        rst = RstStreamFrame(frame.promised_stream_id, error_val)
        send_frame_on_stream(conn.multiplexer, frame.promised_stream_id, rst)
        return
    end

    # Step 3: Handle the header block, now with CONTINUATION support.
    if !frame.end_headers
        # The header block is fragmented. Start the continuation sequence.
        @debug "[CLIENT] Buffering PUSH_PROMISE fragment for promised stream $(frame.promised_stream_id)..."
        truncate(conn.header_buffer, 0)
        write(conn.header_buffer, frame.header_block_fragment)
        
        # Track the stream whose headers are being continued (the original stream)
        conn.continuation_stream_id = frame.stream_id 
        # Track the target stream for these headers (the new pushed stream)
        conn.pending_push_promise_id = frame.promised_stream_id
    else
        # The header block is complete. Decode and assign.
        decoded_headers = HPACK.decode_headers(conn.hpack_decoder, frame.header_block_fragment)
        promised_stream.headers = decoded_headers
        @debug "[CLIENT] Processed complete PUSH_PROMISE for stream $(promised_stream.id)."
    end
end

"""
    process_initial_push_promise(conn::HTTP2Connection, frame::PushPromiseFrame)

Handles the initial receipt of a PUSH_PROMISE frame. This function is responsible
for validating the push and creating the new stream in a 'reserved (remote)' state.
The header block itself will be processed once the full sequence is received.
"""
function process_initial_push_promise(conn::HTTP2Connection, frame::PushPromiseFrame)
    if is_server(conn) || iseven(frame.stream_id)
        throw(ProtocolError("Server cannot receive PUSH_PROMISE H2Frames."))
    end

    if !conn.settings.enable_push
        rst_frame = create_rst_stream_response(frame.promised_stream_id, REFUSED_STREAM)
        send_frame_on_stream(conn.multiplexer, frame.promised_stream_id, rst_frame)
        return
    end

    if isodd(frame.promised_stream_id) || has_stream(conn, frame.promised_stream_id)
        throw(ProtocolError("PUSH_PROMISE received with invalid or duplicate promised stream ID.", frame.stream_id))
    end

    promised_stream = HTTP2Stream(frame.promised_stream_id, conn)
    add_stream(conn, promised_stream)
    Streams.register_stream!(conn.multiplexer, promised_stream)

    transition_stream_state!(promised_stream, :recv_push_promise)

end

"""
    process_settings_frame(frame::SettingsFrame, connection) -> Nothing

Process a received SETTINGS frame and update connection state.
"""


function process_settings_frame(conn::HTTP2Connection, frame::SettingsFrame)
    if is_ack(frame)
        @debug  "[Conn] Received SETTINGS ACK."
        return
    end

    H2Settings.apply_settings!(conn.remote_settings, frame)
    @debug  "[Conn] Applied peer settings: $(settings_to_string(frame.parameters))"
    ack_frame = create_settings_ack()
    send_frame(conn, serialize_payload(ack_frame))
    @debug  "[Conn] Sent SETTINGS ACK."
end

"""
    apply_flow_control_update(frame::WindowUpdateFrame, connection_state) -> Nothing

Applies the flow control window update to the appropriate window.

This function should be called when processing received WINDOW_UPDATE H2Frames
to update the local flow control windows.
"""
# Connection Logic
function apply_flow_control_update(frame::WindowUpdateFrame, conn::HTTP2Connection)
    if frame.stream_id == 0
        update_send_window!(conn, frame.window_size_increment)
    else
        stream = get_stream(conn, frame.stream_id)
        if stream !== nothing
            update_send_window!(stream, frame.window_size_increment)
        else
           # Per RFC 7540, 6.9: A receiver MUST treat the receipt of a
           # WINDOW_UPDATE frame on a closed stream as a connection error.
           throw(ProtocolError("Received WINDOW_UPDATE for closed or non-existent stream $(frame.stream_id)"))
        end
    end
end


"""
    apply_settings(conn::HTTP2Connection, settings::Dict{UInt16, UInt32})

Apply settings received from the remote peer.
"""
function apply_settings(conn::HTTP2Connection, settings::Dict{UInt16, UInt32})
    for (setting_id, value) in settings
        if setting_id == SETTINGS_HEADER_TABLE_SIZE
            resize_hpack_table(conn.hpack_encoder, value)
        elseif setting_id == SETTINGS_ENABLE_PUSH
            conn.remote_settings.enable_push = value != 0
        elseif setting_id == SETTINGS_MAX_CONCURRENT_STREAMS
            conn.remote_settings.max_concurrent_streams = value
        elseif setting_id == SETTINGS_INITIAL_WINDOW_SIZE
            old_window_size = conn.remote_settings.initial_window_size
            conn.remote_settings.initial_window_size = value
            
            window_diff = Int32(value - old_window_size)
            for stream in values(conn.streams)
                stream.remote_window_size += window_diff
            end
        elseif setting_id == SETTINGS_MAX_FRAME_SIZE
            conn.remote_settings.max_frame_size = value
        elseif setting_id == SETTINGS_MAX_HEADER_LIST_SIZE
            conn.remote_settings.max_header_list_size = value
        end
    end
end


"""
    close_connection!(conn::HTTP2Connection, error_code::Symbol = :NO_ERROR, 
debug_message::String = ""; grace_period::Float64 = 5.0)

Shuts down the connection. Sends a GOAWAY frame with an optional debug message
if the connection is currently open, and then closes all streams and the underlying socket.
This function is thread-safe.

Arguments:
- `conn::HTTP2Connection`: The connection to close.
- `error_code::Symbol`: The error code for the GOAWAY frame.
- `debug_message::String`: An optional debug message.
- `grace_period::Float64`: Time in seconds to wait for active streams to complete before force-closing.
"""
function close_connection!(conn::HTTP2Connection, error_code::Symbol = :NO_ERROR, debug_message::String = ""; grace_period::Float64 = 5.0)
    # Acquire locks in a consistent order to prevent deadlock.
    @lock conn.state_lock begin
        if conn.state == CONNECTION_CLOSED
            return
        end

        local streams_to_watch::Vector{HTTP2Stream}

        @lock conn.streams_lock begin
            # Identify streams that should be allowed to finish.
            streams_to_watch = [s for s in values(conn.streams) if is_active(s)]

            if isopen(conn.socket)
    
            last_stream_id = get_highest_stream_id(conn) |> UInt32
                send_goaway!(conn, last_stream_id, error_code, debug_message)
            end
        end # Release streams_lock

        # Graceful wait period (occurs outside the streams_lock)
        if !isempty(streams_to_watch) && grace_period > 0
            @info "[Conn] Graceful shutdown initiated. Waiting up to $(grace_period)s for $(length(streams_to_watch)) active streams."
            start_time = time()
            while (time() - start_time) < grace_period
                # Remove streams that have closed.
                filter!(is_active, streams_to_watch)
                if isempty(streams_to_watch)
                    @info "[Conn] All active streams closed gracefully."
                    break
                end
                sleep(0.1) # Check every 100ms
            end

            if !isempty(streams_to_watch)
                @warn "[Conn] Grace period ended. $(length(streams_to_watch)) streams still active. Force-closing."
            end
        end
        
        # Final cleanup (re-acquire streams_lock)
        @lock conn.streams_lock begin
            for stream in values(conn.streams)
        
        Streams.mux_close_stream!(conn.multiplexer, stream.id, error_code)
            end

            empty!(conn.streams)

            try
                if isopen(conn.socket)
                    close(conn.socket)
                end
            catch
                # Ignore errors on close
      
      end
            
    transition_state!(conn, CONNECTION_CLOSED)
        end # Release streams_lock
    end # Release state_lock
end

"""
    is_graceful_shutdown(frame::GoAwayFrame) -> Bool

Check if this GOAWAY frame indicates a graceful shutdown (NO_ERROR).
"""
is_graceful_shutdown(frame::GoAwayFrame) = frame.error_code == UInt32(NO_ERROR)

"""
    is_error_shutdown(frame::GoAwayFrame) -> Bool

Check if this GOAWAY frame indicates an error condition.
"""
is_error_shutdown(frame::GoAwayFrame) = frame.error_code != UInt32(NO_ERROR)

"""
    send_goaway!(conn::HTTP2Connection, last_stream_id::UInt32, error_code::Symbol=:NO_ERROR, debug_message::String="")

Queues a GOAWAY frame for sending via the multiplexer and transitions the connection state.
This is the single, correct way to send a GOAWAY frame.
"""
function send_goaway!(conn::HTTP2Connection, last_stream_id::UInt32, error_code::Symbol=:NO_ERROR, debug_message::String="")
    @lock conn.state_lock begin
        if conn.goaway_sent
            return
        end
        
        @debug "Queueing GOAWAY frame" last_stream_id=last_stream_id error_code=error_code debug_message=debug_message
        
        frame = GoAwayFrame(last_stream_id, Exc.error_code_value(error_code), Vector{UInt8}(debug_message))
        
        send_frame_on_stream(conn.multiplexer, 0, frame)
        
        conn.goaway_sent = true
        transition_state!(conn, CONNECTION_GOAWAY_SENT)
    end
end

"""
    get_highest_stream_id(connection::HTTP2Connection) -> UInt32

Get the highest stream ID that has been processed on this connection.
"""
function get_highest_stream_id(connection::HTTP2Connection)
    @lock connection.streams_lock begin # <-- Ensure this uses "connection"
        if !isempty(connection.streams)
            return maximum(keys(connection.streams))
        else
            return 0
        end
    end
end


"""
    update_window(conn::HTTP2Connection, increment::UInt32)

Send a connection-level WINDOW_UPDATE frame.
"""
function update_window(conn::HTTP2Connection, increment::UInt32)
    if increment == 0
        throw(ProtocolError("WINDOW_UPDATE increment cannot be zero"))
    end
    window_update = WindowUpdateFrame(0, increment)
    send_frame(conn, window_update)
    conn.window_size += Int32(increment)
end


"""
    update_send_window!(conn::HTTP2Connection, increment::UInt32)

Increases the connection-level send window. Called on receipt of a WINDOW_UPDATE.
"""
function update_send_window!(conn::HTTP2Connection, increment::UInt32)
    @lock conn.flow_control_lock begin
        new_window = Int64(conn.send_window) + Int64(increment)
        if new_window > MAX_WINDOW_SIZE
            throw(FlowControlError("Connection send window overflow", 0))
        end
        conn.send_window = Int32(new_window)
    end
end

"""
    update_send_window!(stream::HTTP2Stream, increment::UInt32)

Increases the stream-level send window. Called on receipt of a WINDOW_UPDATE.
"""
function update_send_window!(stream::HTTP2Stream, increment::UInt32)
    new_window = Int64(stream.send_window) + Int64(increment)
    if new_window > MAX_WINDOW_SIZE
        throw(FlowControlError("Stream send window overflow", stream.id))
    end
    stream.send_window = Int32(new_window)
end

"""
    consume_receive_window!(stream::HTTP2Stream, amount::Int)

Consumes bytes from the receive windows. Called on receipt of a DATA frame.
"""
function consume_receive_window!(stream::HTTP2Stream, amount::Int)
    conn = stream.connection
    if amount > stream.receive_window || amount > conn.receive_window
        throw(FlowControlError("Received more data than the advertised window size", stream.id))
    end
    stream.receive_window -= amount
    @lock conn.flow_control_lock begin
        conn.receive_window -= amount
    end
end


"""
    reset_connection_window!(conn::HTTP2Connection)

Reset the connection-level window to the initial value.
"""
function reset_connection_window!(conn::HTTP2Connection)
    conn.receive_window = Int32(conn.settings.initial_window_size)
    conn.send_window = Int32(conn.settings.initial_window_size)
end

"""
    reset_stream_window!(conn::HTTP2Connection, stream_id::UInt32)

Reset a stream's window to the initial value.
"""
function reset_stream_window!(stream::HTTP2Stream)
    stream.receive_window = Int32(stream.connection.settings.initial_window_size)
    stream.send_window = Int32(stream.connection.settings.initial_window_size)
end

"""
    update_all_stream_send_windows!(conn::HTTP2Connection, difference::Int64)

Applies a change to the initial window size to all active streams.
This is called when SETTINGS_INITIAL_WINDOW_SIZE is changed by the remote peer,
adjusting each stream's `send_window`. Throws a FlowControlError on overflow.
"""
function _update_all_stream_send_windows_unsafe!(conn::HTTP2Connection, difference::Int64)
    println("[FlowControl] Updating all stream send windows by: $difference (unsafe version)")
    @lock conn.flow_control_lock begin
    for stream in values(conn.streams)
            new_window = Int64(stream.send_window) + difference
            
            if new_window > MAX_WINDOW_SIZE
                throw(FlowControlError("Stream send window overflow due to SETTINGS update", stream.id))
            end
            
            stream.send_window = Int32(new_window)
            println("[FlowControl] Updated stream $(stream.id) send window to: $(stream.send_window)")
        end
    end
    println("[FlowControl] All stream send windows updated successfully")
end

function update_all_stream_send_windows!(conn::HTTP2Connection, difference::Int64)
    @lock conn.streams_lock begin
        _update_all_stream_send_windows_unsafe!(conn, difference)
    end
end

"""
    apply_settings_dict!(settings::HTTP2Settings, dict::Dict{UInt16, UInt32})

Apply settings from a dictionary (typically from a received SETTINGS frame).
Validates each setting before applying.
"""
function apply_settings_dict!(conn::HTTP2Connection, dict::Dict{UInt16, UInt32})
    settings = conn.remote_settings
    for (setting_id, value) in dict
        apply_setting!(conn, setting_id, value)
    end
    validate_settings(settings)
end

"""
    update_initial_window_size!(conn::HTTP2Connection, old_size::UInt32, new_size::UInt32)

Update the initial window size setting and adjust all existing streams' flow control windows.
This is called when SETTINGS_INITIAL_WINDOW_SIZE changes.
"""
function update_initial_window_size!(conn::HTTP2Connection, old_size::UInt32, new_size::UInt32)
    window_diff = Int64(new_size) - Int64(old_size)
    
    for stream in values(conn.streams)
        new_window = Int64(stream.receive_window) + window_diff
        
        if new_window > MAX_WINDOW_SIZE
            throw(HTTP2Error(UInt32(FLOW_CONTROL_ERROR), "Window size overflow for stream $(stream.id)"))
        elseif new_window < -MAX_WINDOW_SIZE
            throw(HTTP2Error(UInt32(FLOW_CONTROL_ERROR), "Window size underflow for stream $(stream.id)"))
        end
        
        stream.receive_window = Int32(new_window)
    end
end

"""
    handle_connection_error!(conn::HTTP2Connection, error_code::ErrorCode, msg::AbstractString = "")

Handle a connection-level error: send GOAWAY, close streams, and transition to CLOSED.
"""

function handle_connection_error!(conn::HTTP2Connection, error_code::Symbol, msg::AbstractString = "")
    @lock conn.state_lock begin
        if conn.state == CONNECTION_CLOSED 
            return
        end
        @error "Connection Error" msg error_code

        if conn.state == CONNECTION_IDLE
            transition_state!(conn, CONNECTION_CLOSED)
        else
            transition_state!(conn, CONNECTION_CLOSING)
        end
    end
end

# ============================================================================= 
# Connection State Machine 
# ============================================================================= 

"""
    transition_state!(conn::HTTP2Connection, new_state::ConnectionState)

Transition the connection to a new state, enforcing valid transitions.
Throws if the transition is invalid.
"""
function transition_state!(conn::AbstractHTTP2Connection, new_state::ConnectionState)
    @lock conn.state_lock begin
        old_state = conn.state
        if old_state == new_state
            return
        end

        if !is_valid_transition(Val(old_state), Val(new_state))
            throw(ProtocolError("Invalid connection state transition: $old_state → $new_state"))
        end
        
        @debug "State Transition: $old_state → $new_state"
        conn.state = new_state
    end
    end

is_valid_transition(from::ConnectionState, to::ConnectionState) = false

is_valid_transition(::Val{CONNECTION_IDLE}, ::Val{CONNECTION_OPEN}) = true
is_valid_transition(::Val{CONNECTION_IDLE}, ::Val{CONNECTION_CLOSED}) = true
is_valid_transition(::Val{CONNECTION_IDLE}, ::Val{CONNECTION_GOAWAY_SENT}) = true

# Από κατάσταση OPEN
is_valid_transition(::Val{CONNECTION_OPEN}, ::Val{CONNECTION_CLOSING}) = true
is_valid_transition(::Val{CONNECTION_OPEN}, ::Val{CONNECTION_GOAWAY_SENT}) = true
is_valid_transition(::Val{CONNECTION_OPEN}, ::Val{CONNECTION_GOAWAY_RECEIVED}) = true
is_valid_transition(::Val{CONNECTION_OPEN}, ::Val{CONNECTION_CLOSED}) = true

# Από κατάσταση CLOSING
is_valid_transition(::Val{CONNECTION_CLOSING}, ::Val{CONNECTION_CLOSED}) = true

# Από κατάσταση GOAWAY_SENT
is_valid_transition(::Val{CONNECTION_GOAWAY_SENT}, ::Val{CONNECTION_CLOSING}) = true
is_valid_transition(::Val{CONNECTION_GOAWAY_SENT}, ::Val{CONNECTION_CLOSED}) = true
is_valid_transition(::Val{CONNECTION_GOAWAY_SENT}, ::Val{CONNECTION_GOAWAY_RECEIVED}) = true

# Από κατάσταση GOAWAY_RECEIVED
is_valid_transition(::Val{CONNECTION_GOAWAY_RECEIVED}, ::Val{CONNECTION_CLOSING}) = true
is_valid_transition(::Val{CONNECTION_GOAWAY_RECEIVED}, ::Val{CONNECTION_CLOSED}) = true


"""
    send_frame(conn::HTTP2Connection, frame_bytes::Vector{UInt8})

Writes a pre-serialized frame (as bytes) to the connection's socket.
This is the lowest-level sending function.
"""
function send_frame(conn::HTTP2Connection, frame_bytes::Vector{UInt8})
    if is_closed(conn)
        return
    end
    try
        @lock conn.socket_lock begin # <-- Use the new socket_lock
            write(conn.socket, frame_bytes)
            flush(conn.socket)
        end
    catch e
        handle_connection_error!(conn, :INTERNAL_ERROR, "Socket write failure: $e")
    end
end





"""
    send_goaway!(conn::HTTP2Connection, error_code::Symbol=:NO_ERROR, msg::AbstractString="")

Send a GOAWAY frame and transition to GOAWAY_SENT.
"""
function send_goaway!(conn::HTTP2Connection, error_code::Symbol=:NO_ERROR, msg::AbstractString="")
    if conn.state in (CONNECTION_CLOSED, CONNECTION_GOAWAY_SENT)
        return
    end
    @lock conn.state_lock begin
        goaway = GoAwayFrame(conn.last_peer_stream_id, error_code, Vector{UInt8}(msg))
        send_frame(conn, serialize_payload(goaway))
        conn.goaway_sent = true
        transition_state!(conn, CONNECTION_GOAWAY_SENT)
    end
end

"""
    receive_goaway!(conn::HTTP2Connection, last_stream_id::UInt32, error_code::Symbol, debug_data::Vector{UInt8})

Handle receipt of a GOAWAY frame and transition to GOAWAY_RECEIVED.
"""
function receive_goaway!(conn::HTTP2Connection, last_stream_id::UInt32, error_code::Symbol, debug_data::Vector{UInt8})
    if conn.state in (CONNECTION_CLOSED, CONNECTION_GOAWAY_RECEIVED)
        return
    end
    conn.goaway_received = true
    conn.last_peer_stream_id = last_stream_id
    transition_state!(conn, CONNECTION_GOAWAY_RECEIVED)
    # Optionally, close streams with id > last_stream_id
    for (sid, stream) in conn.streams
        if sid > last_stream_id
            close_stream(stream, error_code)
            delete!(conn.streams, sid)
        end
    end
end


"""
    can_send_frame(conn::HTTP2Connection) -> Bool

Return true if the connection is in a state where H2Frames can be sent.
"""
can_send_frame(conn::HTTP2Connection) = conn.state in (ConnectionState.connOpen, ConnectionState.connGoawaySent, ConnectionState.connGoawayReceived)

"""
    can_receive_frame(conn::HTTP2Connection) -> Bool

Return true if the connection is in a state where H2Frames can be received.
"""
can_receive_frame(conn::HTTP2Connection) = conn.state in (ConnectionState.connOpen, ConnectionState.connGoawaySent, ConnectionState.connGoawayReceived)



# Pretty print for debugging
function Base.show(io::IO, ::MIME"text/plain", state::ConnectionState)
    println(io, "HTTP/2 Connection State: $(state)")
end

end

