module Connection

using ..Events
using ..H2Exceptions 
using ..H2Errors
using ..H2Windows
using ..Config
using ..H2Settings

using H2Frames
using HPACK
using Logging
using Base64


export H2Connection, H2Stream, receive_data!, send_headers, send_data, 
data_to_send, send_settings, acknowledge_received_data!, initiate_connection!, prioritize!

const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

"""
    H2Stream

Represents an individual HTTP/2 stream within a connection.

# Fields
- `stream_id::UInt32`: The unique identifier for the stream (consistent with Events module)
- `state::Symbol`: Current state of the stream (`:idle`, `:open`, `:half_closed_local`, `:half_closed_remote`, `:closed`)
- `send_window::UInt32`: Flow control window for sending data
- `inbound_window_manager::WindowManager`: Manages the receive window
- `priority::Union{Events.Priority, Nothing}`: Stream priority information

# Usage
```julia
# Create a new stream
stream = H2Stream(UInt32(1))

# Create with custom settings
stream = H2Stream(
    UInt32(3), 
    :open, 
    UInt32(32768),  # send window
    UInt32(65535),  # receive window
    Events.Priority(UInt32(0), UInt8(16), false)  # priority
)

# Access stream properties
println("Stream ID: ", stream.stream_id)
println("State: ", stream.state)
println("Send window: ", stream.send_window)
```
"""
mutable struct H2Stream
    stream_id::UInt32 
    state::Symbol
    send_window::UInt32
    inbound_window_manager::WindowManager
    priority::Union{Events.Priority, Nothing}
    
    function H2Stream(stream_id::UInt32, state::Symbol = :idle, 
                     send_window::UInt32 = UInt32(65535), 
                     receive_window::UInt32 = UInt32(65535),
                     priority::Union{Events.Priority, Nothing} = nothing)
        Events.validate_stream_id(stream_id)
        new(stream_id, state, send_window, WindowManager(receive_window), priority)
    end
end

"""
    H2Connection

Represents an HTTP/2 connection that manages multiple streams and connection-level state.

# Fields
- `config::H2Config`: Configuration settings for the connection
- `hpack_encoder::HPACKEncoder`: HPACK encoder for header compression
- `hpack_decoder::HPACKDecoder`: HPACK decoder for header decompression
- `streams::Dict{UInt32, H2Stream}`: Dictionary of active streams (UInt32 keys for consistency)
- `next_stream_id::UInt32`: Next stream ID to use for new streams
- `last_processed_stream_id::UInt32`: Last processed stream ID
- `outbound_buffer::IOBuffer`: Buffer for outgoing data
- `inbound_buffer::IOBuffer`: Buffer for incoming data
- `local_settings::Settings`: Local connection settings
- `remote_settings::Settings`: Remote peer settings
- `preface_received::Bool`: Whether the connection preface has been received
- `send_window::UInt32`: Connection-level flow control window for sending
- `inbound_window_manager::WindowManager`: Connection-level receive window manager

# Usage
```julia
# Create a client connection
client_config = H2Config(client_side=true)
client_conn = H2Connection(config=client_config)

# Create a server connection
server_config = H2Config(client_side=false)
server_conn = H2Connection(config=server_config)

# Initialize the connection
initiate_connection!(client_conn)

# Send headers
headers = [":method" => "GET", ":path" => "/", ":scheme" => "https"]
send_headers(client_conn, UInt32(1), headers)

# Send data
data = Vector{UInt8}("Hello, world!")
send_data(client_conn, UInt32(1), data, end_stream=true)

# Get data to send over the network
outbound_data = data_to_send(client_conn)

# Process incoming data
incoming_data = Vector{UInt8}([...])  # data from network
events = receive_data!(client_conn, incoming_data)
```

# Stream Management
```julia
# Check stream state
state = get_stream_state(conn, UInt32(1))

# Get stream priority
priority = get_stream_priority(conn, UInt32(1))

# Set stream priority
prioritize!(conn, UInt32(1), weight=32, depends_on=UInt32(0), exclusive=false)
```

# Flow Control
```julia
# Acknowledge received data to update flow control windows
acknowledge_received_data!(conn, UInt32(1), UInt32(1024))
```

# Settings Management
```julia
# Send settings
settings = Dict(:max_concurrent_streams => UInt32(200))
send_settings(conn, settings)
```

# Connection Summary
```julia
# Get connection information
summary = connection_summary(conn)
println(summary)
```
"""
mutable struct H2Connection
    config::H2Config
    hpack_encoder::HPACKEncoder
    hpack_decoder::HPACKDecoder
    streams::Dict{UInt32, H2Stream} 
    next_stream_id::UInt32
    last_processed_stream_id::UInt32
    outbound_buffer::IOBuffer
    inbound_buffer::IOBuffer
    local_settings::Settings
    remote_settings::Settings
    preface_received::Bool
    send_window::UInt32
    inbound_window_manager::WindowManager

    function H2Connection(; config::H2Config)
        next_stream_id = config.client_side ? UInt32(1) : UInt32(2)
         initial_conn_settings = Dict(
            SETTINGS_MAX_CONCURRENT_STREAMS => UInt32(100)
        )
        new(
            config,
            HPACKEncoder(),
            HPACKDecoder(),
            Dict{UInt32, H2Stream}(),
            next_stream_id,
            UInt32(0),
            IOBuffer(),
            IOBuffer(),
            Settings(client=config.client_side, initial_values=initial_conn_settings),
            Settings(client=!config.client_side),
            false,
            UInt32(65535),
            WindowManager(UInt32(65535))
        )
    end
end


"""
    initiate_connection!(conn::H2Connection)

Prepares the initial data that must be sent when starting a connection 
(preface for client and initial SETTINGS frame).

# Usage
```julia
conn = H2Connection(config=H2Config(client_side=true))
initiate_connection!(conn)
data = data_to_send(conn)  # Get the preface and settings to send
```
"""
function initiate_connection!(conn::H2Connection)
    if conn.config.client_side
        write(conn.outbound_buffer, CONNECTION_PREFACE)
    end
    
    settings_dict = Dict{UInt16, UInt32}((UInt16(k) => v for (k, v) in conn.local_settings))
    settings_frame = H2Frames.SettingsFrame(settings_dict)
    serialized_bytes = H2Frames.serialize_frame(settings_frame)
    write(conn.outbound_buffer, serialized_bytes)
    
    @debug "Connection initiated. Preface and/or SETTINGS queued."
end

function receive_data!(conn::H2Connection, data::Vector{UInt8})::Vector{Events.Event}
    seekend(conn.inbound_buffer)
    write(conn.inbound_buffer, data)
    seekstart(conn.inbound_buffer)

    if !conn.config.client_side && !conn.preface_received
        if _is_http11_upgrade_request(conn.inbound_buffer)
            events = _handle_h2c_upgrade(conn)
            if !isempty(events)
                return events
            end
        end
        
        preface_len = length(CONNECTION_PREFACE)
        if bytesavailable(conn.inbound_buffer) >= preface_len
            received_preface = read(conn.inbound_buffer, preface_len)
            if received_preface != Vector{UInt8}(CONNECTION_PREFACE)
                throw(H2Exceptions.ProtocolError("Invalid connection preface"))
            end
            conn.preface_received = true
        else
            return Events.Event[]
        end
    end

    events = Events.Event[]
    last_successful_position = position(conn.inbound_buffer)

    while bytesavailable(conn.inbound_buffer) >= H2Frames.FRAME_HEADER_SIZE
        mark(conn.inbound_buffer)
        header_bytes = read(conn.inbound_buffer, H2Frames.FRAME_HEADER_SIZE)
        header = H2Frames.deserialize_frame_header(header_bytes)
        frame_length = H2Frames.FRAME_HEADER_SIZE + header.length
        reset(conn.inbound_buffer)

        max_size = get(conn.local_settings, SETTINGS_MAX_FRAME_SIZE, 16384)
        if header.length > max_size
            throw(FrameTooLargeError("Received frame of size $(header.length) exceeds max frame size $max_size"))
        end

        if bytesavailable(conn.inbound_buffer) < frame_length
            break
        end

        unmark(conn.inbound_buffer)
        read(conn.inbound_buffer, H2Frames.FRAME_HEADER_SIZE)
        payload_bytes = read(conn.inbound_buffer, header.length)
        
        try
            frame_obj = H2Frames.create_frame(header, payload_bytes)
            new_events = process_frame(conn, frame_obj)
            if !isnothing(new_events) && !isempty(new_events)
                append!(events, new_events)
            end
        catch e
            if e isa H2Error
                rethrow()
            else
                throw(H2Exceptions.ProtocolError("Failed to parse frame: $e"))
            end
        end

        last_successful_position = position(conn.inbound_buffer)
    end
    
    seek(conn.inbound_buffer, last_successful_position)
    remaining_bytes = readavailable(conn.inbound_buffer)
    truncate(conn.inbound_buffer, 0)
    write(conn.inbound_buffer, remaining_bytes)

    return events
end

function _is_http11_upgrade_request(buffer::IOBuffer)::Bool
    """Check if buffer starts with HTTP/1.1 request line"""
    original_pos = position(buffer)
    
    try
        seekstart(buffer)
        if bytesavailable(buffer) < 14  # Minimum for "GET / HTTP/1.1"
            return false
        end
        
        first_bytes = read(buffer, min(100, bytesavailable(buffer)))
        first_line = String(first_bytes)
        
        return occursin(r"^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+.+\s+HTTP/1\.1\r?\n", first_line)
    finally
        seek(buffer, original_pos)
    end
end

function _handle_h2c_upgrade(conn::H2Connection)::Vector{Events.Event}
    seekstart(conn.inbound_buffer)
    request_data = readavailable(conn.inbound_buffer)
    request_str = String(request_data)
    
    if !occursin(r"Upgrade:\s*h2c", request_str) || !occursin(r"Connection:.*Upgrade", request_str)
        truncate(conn.inbound_buffer, 0)
        write(conn.inbound_buffer, request_data)
        return Events.Event[]
    end
    
    http2_settings = Dict{UInt16, UInt32}()
    settings_match = match(r"HTTP2-Settings:\s*([A-Za-z0-9+/=]+)", request_str)
    if !isnothing(settings_match)
        try
            settings_b64 = settings_match.captures[1]
            settings_bytes = Base64.base64decode(settings_b64)
            if length(settings_bytes) >= H2Frames.FRAME_HEADER_SIZE + 6 
                header_bytes = settings_bytes[1:H2Frames.FRAME_HEADER_SIZE]
                header = H2Frames.deserialize_frame_header(header_bytes)
                
                if header.frame_type == H2Frames.SETTINGS_FRAME
                    payload_bytes = settings_bytes[H2Frames.FRAME_HEADER_SIZE+1:end]
                    settings_frame = H2Frames.deserialize_settings_frame(header, payload_bytes)
                    
                    for (key, value) in settings_frame.parameters
                        try
                            setting_param = H2Frames.SettingsParameter(key)
                            conn.remote_settings[setting_param] = value
                            http2_settings[key] = value
                        catch e
                            @debug "Unknown or invalid setting key: $key"
                        end
                    end
                end
            else
                if length(settings_bytes) >= 6 
                    i = 1
                    while i + 5 <= length(settings_bytes)
                        setting_id = (UInt16(settings_bytes[i]) << 8) | UInt16(settings_bytes[i+1])
                        setting_value = (UInt32(settings_bytes[i+2]) << 24) | 
                                       (UInt32(settings_bytes[i+3]) << 16) | 
                                       (UInt32(settings_bytes[i+4]) << 8) | 
                                       UInt32(settings_bytes[i+5])
                        
                        http2_settings[setting_id] = setting_value
                        
                        try
                            setting_param = H2Frames.SettingsParameter(setting_id)
                            conn.remote_settings[setting_param] = setting_value
                        catch e
                            @debug "Unknown or invalid setting key: $setting_id"
                        end
                        
                        i += 6
                    end
                end
            end
        catch e
            @debug "Failed to parse HTTP2-Settings header: $e"
        end
    end
    
    switching_response = join([
        "HTTP/1.1 101 Switching Protocols",
        "Connection: Upgrade", 
        "Upgrade: h2c",
        "", "" 
    ], "\r\n")
    
    write(conn.outbound_buffer, switching_response)
    truncate(conn.inbound_buffer, 0)
    return [Events.H2CUpgradeReceived(http2_settings)]
end



function process_frame(conn::H2Connection, frame::H2Frames.HTTP2Frame)
    sid = UInt32(H2Frames.stream_id(frame))

    if sid == 0
        if frame isa H2Frames.FrameSettings.SettingsFrame
            if H2Frames.is_ack(frame)
                return Events.Event[]
            end
            changed_settings = Dict{Symbol, UInt32}()
            for (key, value) in frame.parameters
                param = H2Frames.setting_name(key)
                const_key = getfield(H2Frames, param)
                conn.remote_settings[const_key] = value
                changed_settings[Symbol(param)] = value
            end
            events = Events.Event[]
            push!(events, Events.SettingsChanged(changed_settings))
            ack_frame = H2Frames.SettingsFrame(Dict{UInt16, UInt32}(); ack=true)
            serialized_ack = H2Frames.serialize_frame(ack_frame)
            write(conn.outbound_buffer, serialized_ack)
            return events
        elseif frame isa H2Frames.PingFrame
            if H2Frames.is_ping_ack(frame)
                return [Events.PingAck(Vector{UInt8}(frame.data))]
            else
                pong_frame = H2Frames.PingFrame(frame.data; ack=true)
                write(conn.outbound_buffer, H2Frames.serialize_frame(pong_frame))
                return [Events.PingReceived(Vector{UInt8}(frame.data))]
            end

        elseif frame isa H2Frames.GoAwayFrame
            last_stream_id = UInt32(frame.last_stream_id)
            error_code = UInt32(frame.error_code)
            debug_data = Vector{UInt8}(frame.debug_data)
            return [Events.ConnectionTerminated(last_stream_id, error_code, debug_data)]

        elseif frame isa H2Frames.WindowUpdateFrame
            increment = UInt32(frame.window_size_increment)
            if increment == 0
                throw(ProtocolError("WINDOW_UPDATE increment on connection cannot be zero"))
            end
            new_window = conn.send_window + increment 
            if new_window > 2^31 - 1
                throw(FlowControlError("Connection flow control window overflow"))
            end
            conn.send_window = new_window
            return [Events.WindowUpdated(sid, increment)]
            
        else
            throw(ProtocolError("Invalid frame type $(typeof(frame)) on stream 0"))
        end
    end
    if frame isa H2Frames.PriorityFrame
        if frame.stream_dependency == sid
            throw(ProtocolError("Stream $sid cannot depend on itself"))
        end
        stream = _get_or_create_stream(conn, sid) # Priority is allowed to create idle stream
        priority = Events.Priority(UInt32(frame.stream_dependency), UInt8(frame.weight), frame.exclusive)
        stream.priority = priority
        return [Events.PriorityChanged(sid, priority)]
    end


    can_create_stream = frame isa H2Frames.Headers.HeadersFrame || frame isa H2Frames.PushPromiseFrame
    stream = _get_stream(conn, sid, can_create=can_create_stream)

    if isnothing(stream)
        if !(frame isa H2Frames.WindowUpdateFrame || frame isa H2Frames.PriorityFrame || frame isa H2Frames.RstStreamFrame)
            write(conn.outbound_buffer, H2Frames.serialize_frame(reset_frame))
        end
        return nothing
    end

        if frame isa H2Frames.RstStreamFrame
        stream.state = :closed
        return [Events.StreamReset(sid, UInt32(frame.error_code))]
    end

    if frame isa H2Frames.FrameData.DataFrame
        data_len = UInt32(length(frame.data))
        window_consumed!(stream.inbound_window_manager, data_len)
        window_consumed!(conn.inbound_window_manager, data_len)

        if stream.state != :open && stream.state != :half_closed_remote
            throw(ProtocolError("Received DATA on stream $sid in state $(stream.state)"))
        end

        events = Events.Event[]
        push!(events, Events.DataReceived(sid, frame.data, data_len, frame.end_stream))
        if frame.end_stream
            push!(events, Events.StreamEnded(sid))
            stream.state = :half_closed_remote
        end
        return events

    elseif frame isa H2Frames.Headers.HeadersFrame
        stream.state = :open
        events = Events.Event[]
        headers = Vector{Pair{String, String}}()
        try
            headers = HPACK.decode_headers(conn.hpack_decoder, frame.header_block_fragment)
        catch e
            throw(ProtocolError("HPACK decoding failed: $e"))
        end
        _validate_received_headers(headers)
        
        method_idx = findfirst(h -> h.first == ":method", headers)
        status_idx = findfirst(h -> h.first == ":status", headers)
        
        priority = nothing
        if hasproperty(frame, :priority) && !isnothing(frame.priority)
            if !(frame.priority isa Bool) && hasproperty(frame.priority, :stream_dependency)
                priority = Events.Priority(UInt32(frame.priority.stream_dependency), UInt8(frame.priority.weight), frame.priority.exclusive)
                stream.priority = priority
            end
        end

        if !isnothing(method_idx)
            push!(events, Events.RequestReceived(sid, headers, priority))
        elseif !isnothing(status_idx)
            status_val = headers[status_idx].second
            if occursin(r"^1\d\d$", status_val)
                push!(events, Events.InformationalResponseReceived(sid, headers))
            else
                push!(events, Events.ResponseReceived(sid, headers))
            end
        else
            push!(events, Events.RequestReceived(sid, headers, priority))
        end
        if frame.end_stream
            push!(events, Events.StreamEnded(sid))
            stream.state = :half_closed_remote
        end
        return events

    elseif frame isa H2Frames.WindowUpdateFrame
        increment = UInt32(frame.window_size_increment)
        if increment == 0
            reset_frame = H2Frames.RstStreamFrame(sid, PROTOCOL_ERROR)
            write(conn.outbound_buffer, H2Frames.serialize_frame(reset_frame))
            return nothing
        end
        
        new_window = stream.send_window + increment
        if new_window > 2^31 - 1
            reset_frame = H2Frames.RstStreamFrame(sid, FLOW_CONTROL_ERROR)
            write(conn.outbound_buffer, H2Frames.serialize_frame(reset_frame))
            return nothing
        end
        stream.send_window = new_window
        return [Events.WindowUpdated(sid, increment)]

    elseif frame isa H2Frames.RstStreamFrame
        error_code = UInt32(frame.error_code)
        stream.state = :closed
        return [Events.StreamReset(sid, error_code)]

    elseif frame isa H2Frames.PriorityFrame
        if frame.stream_dependency == sid
            throw(ProtocolError("Stream $sid cannot depend on itself"))
        end
        priority = Events.Priority(UInt32(frame.stream_dependency), UInt8(frame.weight), frame.exclusive)
        stream.priority = priority
        return [Events.PriorityChanged(sid, priority)]
    end

    return nothing
end


"""
    prioritize!(conn::H2Connection, stream_id::UInt32;
                weight::Int=16, depends_on::UInt32=0, exclusive::Bool=false)

Updates the server about the priority of a stream.

# Arguments
- `conn::H2Connection`: The connection
- `stream_id::UInt32`: The stream ID to prioritize
- `weight::Int=16`: Priority weight (1-256)
- `depends_on::Integer=0`: Stream ID this stream depends on
- `exclusive::Bool=false`: Whether this is an exclusive dependency

# Usage
```julia
# Set high priority
prioritize!(conn, UInt32(1), weight=256, depends_on=UInt32(0), exclusive=true)

# Set low priority depending on another stream
prioritize!(conn, UInt32(3), weight=1, depends_on=UInt32(1), exclusive=false)
```
"""
function prioritize!(conn::H2Connection, stream_id::UInt32;
                     weight::Int=16, depends_on::Integer=0, exclusive::Bool=false)
    
    if !(1 <= weight <= 256)
        throw(ArgumentError("Weight must be between 1 and 256"))
    end
    if depends_on == stream_id
        throw(H2Exceptions.ProtocolError("A stream cannot depend on itself"))
    end
    
    priority_frame = H2Frames.PriorityFrame(Int(stream_id), exclusive, Int(depends_on), weight - 1)
    
    serialized_bytes = H2Frames.serialize_frame(priority_frame)
    write(conn.outbound_buffer, serialized_bytes)
    
    @debug "Queued PRIORITY frame for stream $stream_id"
end

"""
    send_headers(conn::H2Connection, stream_id::UInt32, headers; 
                 end_stream=false, priority_weight=nothing, 
                 priority_depends_on=nothing, priority_exclusive=nothing)

Sends HTTP headers on a stream.

# Arguments
- `conn::H2Connection`: The connection
- `stream_id::UInt32`: The stream ID
- `headers`: Vector of header pairs or any iterable of pairs
- `end_stream::Bool=false`: Whether this closes the stream
- `priority_weight::Union{Int, Nothing}=nothing`: Priority weight (1-256)
- `priority_depends_on::Union{Integer, Nothing}=nothing`: Stream dependency
- `priority_exclusive::Union{Bool, Nothing}=nothing`: Exclusive dependency

# Usage
```julia
# Send request headers
headers = [":method" => "GET", ":path" => "/", ":scheme" => "https", ":authority" => "example.com"]
send_headers(conn, UInt32(1), headers)

# Send response headers
headers = [":status" => "200", "content-type" => "text/html"]
send_headers(conn, UInt32(1), headers, end_stream=true)

# Send headers with priority
send_headers(conn, UInt32(3), headers, priority_weight=32, priority_depends_on=UInt32(1))
```
"""
function send_headers(conn::H2Connection, stream_id::UInt32, headers; 
                      end_stream=false, 
                      priority_weight::Union{Int, Nothing}=nothing,
                      priority_depends_on::Union{Integer, Nothing}=nothing,
                      priority_exclusive::Union{Bool, Nothing}=nothing)
    
    @info "Queuing HEADERS for stream $stream_id"
    Events.validate_stream_id(stream_id)
    if conn.config.client_side && stream_id < conn.next_stream_id
        throw(StreamIDTooLowError(stream_id, conn.next_stream_id))
    end
    
    priority_info = nothing
    if !isnothing(priority_weight) || !isnothing(priority_depends_on) || !isnothing(priority_exclusive)
        weight = !isnothing(priority_weight) ? priority_weight : 16
        depends_on = !isnothing(priority_depends_on) ? priority_depends_on : 0
        exclusive = !isnothing(priority_exclusive) ? priority_exclusive : false

        if !(1 <= weight <= 256) throw(ArgumentError("Weight must be between 1 and 256")) end
        if depends_on == stream_id throw(H2Exceptions.ProtocolError("A stream cannot depend on itself")) end
        
        priority_info = H2Frames.Headers.PriorityInfo(exclusive, UInt32(depends_on), weight)
    end

    frame = H2Frames.create_headers_frame(Int(stream_id), headers, conn.hpack_encoder, 
                                         end_stream=end_stream, priority_info=priority_info)

    serialized_bytes = H2Frames.serialize_frame(frame)
    write(conn.outbound_buffer, serialized_bytes)
    
    stream = _get_or_create_stream(conn, stream_id)
    stream.state = end_stream ? :half_closed_local : :open
    
    if conn.config.client_side && stream_id >= conn.next_stream_id
        conn.next_stream_id = stream_id + 2
    end
    
    if !isnothing(priority_info)
        stream.priority = Events.Priority(priority_info.stream_dependency, priority_info.weight, priority_info.exclusive)
    end
end

"""
HTTP/2 Connection Management Module

This module provides functions for managing HTTP/2 connections, streams, and protocol operations.
It handles data transmission, flow control, settings management, and connection lifecycle.
"""

"""
    send_data(conn::H2Connection, stream_id::UInt32, data::Vector{UInt8}; end_stream=false)

Sends data on a specific HTTP/2 stream with flow control validation.

This function queues data to be sent on the specified stream, validates flow control limits,
and handles frame size constraints. It automatically updates the stream's send window and
can mark the stream as half-closed if this is the final data frame.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream identifier (must be valid)
- `data::Vector{UInt8}`: The data bytes to send
- `end_stream::Bool=false`: Whether this is the last data frame for the stream

# Throws
- `FlowControlError`: If data size exceeds stream's send window
- `FrameTooLargeError`: If data size exceeds maximum frame size

# Examples
```julia
# Send data on stream 1
data = Vector{UInt8}("Hello, HTTP/2!")
send_data(conn, UInt32(1), data)

# Send final data frame and close stream
send_data(conn, UInt32(1), data, end_stream=true)

# Send JSON response
json_data = Vector{UInt8}("{\"status\": \"ok\", \"data\": [1,2,3]}")
send_data(conn, UInt32(3), json_data, end_stream=true)
```
"""
function send_data(conn::H2Connection, stream_id::UInt32, data::Vector{UInt8}; end_stream=false)
    @info "Queuing DATA for stream $stream_id"
    Events.validate_stream_id(stream_id)
    
    stream = _get_or_create_stream(conn, stream_id)
    if length(data) > stream.send_window
        throw(H2Exceptions.FlowControlError("Data size $(length(data)) exceeds stream window $(stream.send_window)"))
    end

    max_frame_size = get(conn.remote_settings, SETTINGS_MAX_FRAME_SIZE, UInt32(16384))
    if length(data) > max_frame_size
        throw(FrameTooLargeError("Data size $(length(data)) exceeds max frame size $(max_frame_size)"))
    end
    
    frames = H2Frames.create_data_frame(Int(stream_id), data; end_stream=end_stream)
    for frame in frames
        serialized_bytes = H2Frames.serialize_frame(frame)
        write(conn.outbound_buffer, serialized_bytes)
    end
    stream.send_window -= UInt32(length(data))
    if end_stream
        stream.state = :half_closed_local
    end
end

"""
    send_settings(conn::H2Connection, settings::Dict{Symbol, UInt32})

Sends HTTP/2 settings to the peer and updates local settings.

This function converts symbolic setting names to their numeric identifiers,
creates a SETTINGS frame, and queues it for transmission. Local settings
are immediately updated to reflect the new values.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `settings::Dict{Symbol, UInt32}`: Settings to send with symbol keys

# Available Settings
- `:header_table_size`: HPACK header table size
- `:enable_push`: Enable/disable server push (0 or 1)
- `:max_concurrent_streams`: Maximum concurrent streams
- `:initial_window_size`: Initial flow control window size
- `:max_frame_size`: Maximum frame size
- `:max_header_list_size`: Maximum header list size

# Examples
```julia
# Configure basic settings
settings = Dict(
    :max_concurrent_streams => UInt32(100),
    :initial_window_size => UInt32(65535)
)
send_settings(conn, settings)

# Configure all settings
settings = Dict(
    :header_table_size => UInt32(4096),
    :enable_push => UInt32(1),
    :max_concurrent_streams => UInt32(100),
    :initial_window_size => UInt32(65535),
    :max_frame_size => UInt32(16384),
    :max_header_list_size => UInt32(8192)
)
send_settings(conn, settings)

# Disable server push
send_settings(conn, Dict(:enable_push => UInt32(0)))
```
"""
function send_settings(conn::H2Connection, settings::Dict{Symbol, UInt32})
    settings_dict = Dict{UInt16, UInt32}(
        UInt16(H2Frames.setting_from_symbol(k)) => v for (k, v) in settings
    )
    
    frame = H2Frames.SettingsFrame(settings_dict)
    serialized_bytes = H2Frames.serialize_frame(frame)
    write(conn.outbound_buffer, serialized_bytes)
    
    # Update local settings
    merge!(conn.local_settings, settings)
end

"""
    send_ping(conn::H2Connection, data::Vector{UInt8} = rand(UInt8, 8))

Sends a PING frame for connection health checking and round-trip time measurement.

PING frames are used to test the connection's liveness and measure round-trip time.
The peer should respond with a PING frame containing the same 8-byte payload.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `data::Vector{UInt8}`: 8-byte ping payload (default: random bytes)

# Throws
- `ArgumentError`: If data is not exactly 8 bytes

# Examples
```julia
# Send ping with random data
send_ping(conn)

# Send ping with specific data for RTT measurement
ping_data = Vector{UInt8}([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
send_ping(conn, ping_data)

# Send ping with timestamp for precise RTT
timestamp = reinterpret(UInt8, [time_ns()])
send_ping(conn, timestamp[1:8])
```
"""
function send_ping(conn::H2Connection, data::Vector{UInt8} = rand(UInt8, 8))
    if length(data) != 8
        throw(ArgumentError("PING data must be exactly 8 bytes"))
    end
    
    ping_frame = H2Frames.create_ping_frame(data)
    serialized_bytes = H2Frames.serialize_frame(ping_frame)
    write(conn.outbound_buffer, serialized_bytes)
end

"""
    send_goaway(conn::H2Connection, last_stream_id::UInt32, error_code::UInt32, debug_data::Vector{UInt8} = UInt8[])

Gracefully terminates the HTTP/2 connection with optional debug information.

GOAWAY frames are used to initiate connection shutdown or signal serious error conditions.
After sending GOAWAY, no new streams should be created, but existing streams can complete.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `last_stream_id::UInt32`: Highest stream ID that will be processed
- `error_code::UInt32`: Error code indicating termination reason
- `debug_data::Vector{UInt8}`: Optional debug information (default: empty)

# Common Error Codes
- `0x00`: NO_ERROR - Graceful shutdown
- `0x01`: PROTOCOL_ERROR - Protocol violation
- `0x02`: INTERNAL_ERROR - Internal error
- `0x03`: FLOW_CONTROL_ERROR - Flow control violation
- `0x04`: SETTINGS_TIMEOUT - Settings timeout
- `0x05`: STREAM_CLOSED - Frame on closed stream
- `0x06`: FRAME_SIZE_ERROR - Frame size error
- `0x07`: REFUSED_STREAM - Stream refused
- `0x08`: CANCEL - Stream cancelled
- `0x09`: COMPRESSION_ERROR - Compression error
- `0x0A`: CONNECT_ERROR - Connection error
- `0x0B`: ENHANCE_YOUR_CALM - Excessive resource use
- `0x0C`: INADEQUATE_SECURITY - Inadequate security
- `0x0D`: HTTP_1_1_REQUIRED - HTTP/1.1 required

# Examples
```julia
# Graceful shutdown
send_goaway(conn, UInt32(5), UInt32(0x00))

# Send GOAWAY due to protocol error
send_goaway(conn, UInt32(3), UInt32(0x01))

# Send GOAWAY with debug info
debug_info = Vector{UInt8}("Connection timeout after 30 seconds")
send_goaway(conn, UInt32(7), UInt32(0x02), debug_info)

# Enhanced your calm (rate limiting)
send_goaway(conn, UInt32(1), UInt32(0x0B), Vector{UInt8}("Rate limit exceeded"))
```
"""
function send_goaway(conn::H2Connection, last_stream_id::UInt32, error_code::UInt32, 
                    debug_data::Vector{UInt8} = UInt8[])
    Events.validate_stream_id(last_stream_id)
    Events.validate_error_code(error_code)
    
    goaway_frame = H2Frames.create_goaway_frame(Int(last_stream_id), Int(error_code), debug_data)
    serialized_bytes = H2Frames.serialize_frame(goaway_frame)
    write(conn.outbound_buffer, serialized_bytes)
end

"""
    send_rst_stream(conn::H2Connection, stream_id::UInt32, error_code::UInt32)

Terminates a specific stream immediately with an error code.

RST_STREAM frames are used to abnormally terminate a stream. Unlike GOAWAY,
this affects only a single stream and allows the connection to continue.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream to terminate
- `error_code::UInt32`: Error code for termination reason

# Common Error Codes
- `0x00`: NO_ERROR - No error
- `0x01`: PROTOCOL_ERROR - Protocol violation
- `0x02`: INTERNAL_ERROR - Internal error
- `0x03`: FLOW_CONTROL_ERROR - Flow control violation
- `0x04`: SETTINGS_TIMEOUT - Settings timeout
- `0x05`: STREAM_CLOSED - Stream was closed
- `0x06`: FRAME_SIZE_ERROR - Frame size error
- `0x07`: REFUSED_STREAM - Stream refused before processing
- `0x08`: CANCEL - Stream cancelled by user
- `0x09`: COMPRESSION_ERROR - Compression error
- `0x0A`: CONNECT_ERROR - Connection error for CONNECT method
- `0x0B`: ENHANCE_YOUR_CALM - Excessive resource use
- `0x0C`: INADEQUATE_SECURITY - Inadequate security
- `0x0D`: HTTP_1_1_REQUIRED - HTTP/1.1 required

# Examples
```julia
# Cancel a stream (user requested)
send_rst_stream(conn, UInt32(3), UInt32(0x08))

# Refuse a stream due to resource limits
send_rst_stream(conn, UInt32(5), UInt32(0x07))

# Reset due to protocol error
send_rst_stream(conn, UInt32(1), UInt32(0x01))

# Reset due to flow control violation
send_rst_stream(conn, UInt32(7), UInt32(0x03))
```
"""
function send_rst_stream(conn::H2Connection, stream_id::UInt32, error_code::UInt32)
    Events.validate_stream_id(stream_id)
    Events.validate_error_code(error_code)
    
    rst_frame = H2Frames.create_rst_stream_frame(Int(stream_id), Int(error_code))
    serialized_bytes = H2Frames.serialize_frame(rst_frame)
    write(conn.outbound_buffer, serialized_bytes)
    
    if haskey(conn.streams, stream_id)
        conn.streams[stream_id].state = :closed
    end
end

"""
    data_to_send(conn::H2Connection)::Vector{UInt8}

Retrieves all queued outbound data for network transmission.

This function empties the outbound buffer and returns all serialized frames
that are ready to be sent over the network connection. This should be called
after performing operations that queue frames for transmission.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object

# Returns
- `Vector{UInt8}`: Serialized frames ready for network transmission

# Examples
```julia
# Send data and retrieve outbound bytes
send_data(conn, UInt32(1), Vector{UInt8}("Hello"))
outbound_data = data_to_send(conn)
if !isempty(outbound_data)
    write(socket, outbound_data)
end

# Process multiple operations and send all at once
send_settings(conn, Dict(:max_concurrent_streams => UInt32(100)))
send_ping(conn)
send_data(conn, UInt32(3), Vector{UInt8}("Response data"))

# Get all queued frames
all_frames = data_to_send(conn)
write(socket, all_frames)

# Check if there's data to send
if !isempty(data_to_send(conn))
    # Handle transmission
end
```
"""
function data_to_send(conn::H2Connection)::Vector{UInt8}
    data = take!(conn.outbound_buffer)
    @debug "Dequeuing $(length(data)) bytes to send."
    return data
end

"""
    _get_stream(conn::H2Connection, stream_id::UInt32; can_create::Bool=false)

Retrieves an existing stream or optionally creates a new one.

This is an internal function used to access stream objects. It can optionally
create a new stream if it doesn't exist and can_create is true.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream identifier
- `can_create::Bool=false`: Whether to create stream if it doesn't exist

# Returns
- `H2Stream` or `nothing`: The stream object if found/created, nothing otherwise

# Examples
```julia
# Get existing stream (returns nothing if not found)
stream = _get_stream(conn, UInt32(1))
if isnothing(stream)
    println("Stream 1 does not exist")
end

# Get stream and create if needed
stream = _get_stream(conn, UInt32(3), can_create=true)

# Check stream existence
existing_stream = _get_stream(conn, UInt32(5))
if !isnothing(existing_stream)
    println("Stream 5 exists with state: \$(existing_stream.state)")
end
```
"""
function _get_stream(conn::H2Connection, stream_id::UInt32; can_create::Bool=false)
    if haskey(conn.streams, stream_id)
        return conn.streams[stream_id]
    elseif can_create
        return _get_or_create_stream(conn, stream_id)
    else
        return nothing
    end
end

"""
    _get_or_create_stream(conn::H2Connection, stream_id::UInt32)

Gets an existing stream or creates a new one with proper initialization.

This function ensures that a stream exists, creating it if necessary. It validates
stream limits, initializes flow control windows, and sets appropriate initial state.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream identifier

# Returns
- `H2Stream`: The stream object (existing or newly created)

# Throws
- `TooManyStreamsError`: If creating the stream would exceed concurrent stream limits

# Examples
```julia
# Get or create stream 1
stream = _get_or_create_stream(conn, UInt32(1))
println("Stream 1 state: \$(stream.state)")

# Create multiple streams
for i in 1:2:10  # Client streams (odd numbers)
    stream = _get_or_create_stream(conn, UInt32(i))
    println("Created stream \$i")
end

# Handle stream creation with error handling
try
    stream = _get_or_create_stream(conn, UInt32(101))
catch e
    if e isa TooManyStreamsError
        println("Cannot create stream: \$(e.message)")
    end
end
```
"""
function _get_or_create_stream(conn::H2Connection, stream_id::UInt32)
    if !haskey(conn.streams, stream_id)
        max_streams = get(conn.local_settings, SETTINGS_MAX_CONCURRENT_STREAMS, typemax(UInt32))
        stream_type_is_client = conn.config.client_side ? (stream_id % 2 != 0) : (stream_id % 2 == 0)
        
        if stream_type_is_client
        else
            inbound_streams = count(s -> !conn.config.client_side ? (s % 2 != 0) : (s % 2 == 0) && conn.streams[s].state != :closed, keys(conn.streams))
            if inbound_streams >= max_streams
                throw(TooManyStreamsError("Peer tried to open stream $stream_id, exceeding limit of $max_streams"))
            end
        end
        
        @info "Creating new stream: $stream_id"
        # ---> CORRECTION: Using the ENUM
        initial_window = get(conn.remote_settings, SETTINGS_INITIAL_WINDOW_SIZE, UInt32(65535))
        conn.streams[stream_id] = H2Stream(stream_id, :idle, initial_window, initial_window)
        conn.last_processed_stream_id = max(conn.last_processed_stream_id, stream_id)
    end
    return conn.streams[stream_id]
end

"""
    acknowledge_received_data!(conn::H2Connection, stream_id::UInt32, size::UInt32)

Processes received data and sends WINDOW_UPDATE frames when necessary.

This function handles flow control for received data by updating both stream-level
and connection-level flow control windows. It automatically sends WINDOW_UPDATE
frames when thresholds are met to allow the peer to send more data.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream that received data
- `size::UInt32`: Number of bytes received

# Examples
```julia
# Acknowledge 1024 bytes received on stream 1
acknowledge_received_data!(conn, UInt32(1), UInt32(1024))

# Process received HTTP response
response_size = UInt32(2048)
acknowledge_received_data!(conn, UInt32(3), response_size)

# Handle large data reception
chunk_size = UInt32(8192)
acknowledge_received_data!(conn, UInt32(5), chunk_size)

# Get any window updates to send
window_updates = data_to_send(conn)
if !isempty(window_updates)
    write(socket, window_updates)
end
```
"""
function acknowledge_received_data!(conn::H2Connection, stream_id::UInt32, size::UInt32)
    Events.validate_stream_id(stream_id)

    stream = _get_stream(conn, stream_id)
    if isnothing(stream) return end 
    
    stream_increment = process_bytes!(stream.inbound_window_manager, size)
    if !isnothing(stream_increment) && stream_increment > 0
        update_frame = H2Frames.WindowUpdateFrame(Int(stream_id), Int(stream_increment))
        write(conn.outbound_buffer, H2Frames.serialize_frame(update_frame))
        @debug "Queued WINDOW_UPDATE for stream $stream_id, increment $stream_increment."
    end

    conn_increment = process_bytes!(conn.inbound_window_manager, size)
    if !isnothing(conn_increment) && conn_increment > 0
        update_frame = H2Frames.WindowUpdateFrame(0, Int(conn_increment))
        write(conn.outbound_buffer, H2Frames.serialize_frame(update_frame))
        @debug "Queued WINDOW_UPDATE for connection, increment $conn_increment."
    end
end

"""
    get_stream_state(conn::H2Connection, stream_id::UInt32)

Returns the current state of a stream.

HTTP/2 streams have a defined lifecycle with specific states. This function
provides the current state of a stream, which is useful for determining
what operations are valid.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream identifier

# Returns
- `Symbol`: Stream state (`:idle`, `:open`, `:half_closed_local`, `:half_closed_remote`, `:closed`)

# Stream States
- `:idle`: Stream has not been used yet
- `:open`: Stream is active and can send/receive data
- `:half_closed_local`: Local side has finished sending
- `:half_closed_remote`: Remote side has finished sending
- `:closed`: Stream is completely closed

# Examples
```julia
# Check stream state before sending data
state = get_stream_state(conn, UInt32(1))
if state == :open || state == :half_closed_remote
    send_data(conn, UInt32(1), data)
else
    println("Cannot send data on stream in state: \$state")
end

# Monitor stream lifecycle
stream_id = UInt32(3)
println("Stream \$stream_id state: \$(get_stream_state(conn, stream_id))")

# Check multiple streams
for id in [1, 3, 5, 7]
    state = get_stream_state(conn, UInt32(id))
    println("Stream \$id: \$state")
end
```
"""
function get_stream_state(conn::H2Connection, stream_id::UInt32)
    stream = get(conn.streams, stream_id, nothing)
    return isnothing(stream) ? :idle : stream.state
end

"""
    get_stream_priority(conn::H2Connection, stream_id::UInt32)

Returns the priority information for a stream.

HTTP/2 supports stream prioritization to optimize resource allocation.
This function retrieves the priority settings for a stream if it exists.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object
- `stream_id::UInt32`: The stream identifier

# Returns
- Priority object or `nothing`: Priority information if stream exists, nothing otherwise

# Examples
```julia
# Get priority for a stream
priority = get_stream_priority(conn, UInt32(1))
if !isnothing(priority)
    println("Stream 1 priority: \$priority")
else
    println("Stream 1 has no priority information")
end

# Check priorities for multiple streams
for id in [1, 3, 5]
    priority = get_stream_priority(conn, UInt32(id))
    if !isnothing(priority)
        println("Stream \$id priority: \$priority")
    end
end
```
"""
function get_stream_priority(conn::H2Connection, stream_id::UInt32)
    stream = get(conn.streams, stream_id, nothing)
    return isnothing(stream) ? nothing : stream.priority
end

"""
    connection_summary(conn::H2Connection)

Returns a formatted summary of the connection state.

This function provides a comprehensive overview of the HTTP/2 connection,
including configuration, active streams, and current settings. Useful
for debugging and monitoring.

# Arguments
- `conn::H2Connection`: The HTTP/2 connection object

# Returns
- `String`: Formatted connection summary

# Examples
```julia
# Get connection summary
summary = connection_summary(conn)
println(summary)

# Log connection state periodically
@info connection_summary(conn)

# Include in debug output
function debug_connection(conn)
    println("=== Connection Debug Info ===")
    println(connection_summary(conn))
    println("=============================")
end
```
"""
function connection_summary(conn::H2Connection)
    return """
    H2Connection Summary:
    - Client: $(conn.config.client_side)
    - Active streams: $(length(conn.streams))
    - Next stream ID: $(conn.next_stream_id)
    - Connection window: $(conn.connection_window)
    - Local settings: $(conn.local_settings)
    - Remote settings: $(conn.remote_settings)
    """
end

"""
    _validate_received_headers(headers::Vector{Pair{String, String}})

Validates HTTP/2 header compliance according to RFC 7540.

HTTP/2 has specific rules for headers that differ from HTTP/1.1. This function
ensures that received headers conform to HTTP/2 requirements.

# Arguments
- `headers::Vector{Pair{String, String}}`: Headers to validate

# Throws
- `ProtocolError`: If headers violate HTTP/2 rules

# Validation Rules
- Header names must be lowercase
- Connection-specific headers are forbidden
- Certain HTTP/1.1 headers are not allowed

# Examples
```julia
# Validate compliant headers
headers = [
    "content-type" => "application/json",
    "content-length" => "100",
    ":method" => "GET",
    ":path" => "/api/data"
]
_validate_received_headers(headers)

# This would throw ProtocolError
bad_headers = [
    "Content-Type" => "text/html",  # Uppercase not allowed
    "Connection" => "close"         # Connection header forbidden
]
try
    _validate_received_headers(bad_headers)
catch e
    println("Header validation failed: \$(e.message)")
end

# Validate headers from incoming request
function process_request_headers(headers)
    try
        _validate_received_headers(headers)
        # Process valid headers
    catch e
        send_rst_stream(conn, stream_id, UInt32(0x01))  # PROTOCOL_ERROR
    end
end
```
"""
function _validate_received_headers(headers::Vector{Pair{String, String}})
    connection_specific = ["Connection", "Proxy-Connection", "Keep-Alive", "Transfer-Encoding", "Upgrade"]
    for (name, value) in headers
        if name != lowercase(name)
            throw(H2Exceptions.ProtocolError("Received uppercase header name: $name"))
        end
        if name in connection_specific
            throw(H2Exceptions.ProtocolError("Received connection-specific header: $name"))
        end
    end
end

"""
    _validate_setting(conn::H2Connection, key::UInt16, value::UInt32)

Validates HTTP/2 setting values according to specification limits.

HTTP/2 settings have specific valid ranges and constraints. This function
ensures that setting values are within acceptable limits before applying them.

# Arguments
- `conn::H2Connection`: The connection object
- `key::UInt16`: Setting identifier
- `value::UInt32`: Setting value to validate

# Throws
- `InvalidSettingsValueError`: If setting value is invalid

# Validated Settings
- `SETTINGS_ENABLE_PUSH`: Must be 0 or 1
- `SETTINGS_INITIAL_WINDOW_SIZE`: Must not exceed 2^31 - 1
- `SETTINGS_MAX_FRAME_SIZE`: Must be between 2^14 and 2^24 - 1

# Examples
```julia
# Validate enable push setting
try
    _validate_setting(conn, H2Frames.SETTINGS_ENABLE_PUSH, UInt32(1))
    println("Valid ENABLE_PUSH setting")
catch e
    println("Invalid setting: \$(e.message)")
end

# Validate window size
try
    _validate_setting(conn, H2Frames.SETTINGS_INITIAL_WINDOW_SIZE, UInt32(65535))
    println("Valid window size")
catch e
    println("Invalid window size: \$(e.message)")
end

# Validate frame size
try
    _validate_setting(conn, H2Frames.SETTINGS_MAX_FRAME_SIZE, UInt32(32768))
    println("Valid frame size")
catch e
    println("Invalid frame size: \$(e.message)")
end

# Use in settings processing
function process_received_settings(conn, settings)
    for (key, value) in settings
        try
            _validate_setting(conn, key, value)
            # Apply valid setting
        catch e
            send_goaway(conn, UInt32(0), UInt32(0x01))  # PROTOCOL_ERROR
            return
        end
    end
end
```
"""
function _validate_setting(conn::H2Connection, key::UInt16, value::UInt32)
    if key == H2Frames.SETTINGS_ENABLE_PUSH && !(value in [0, 1])
        throw(InvalidSettingsValueError("ENABLE_PUSH must be 0 or 1", PROTOCOL_ERROR))
    elseif key == H2Frames.SETTINGS_INITIAL_WINDOW_SIZE && value > 2^31 - 1
        throw(InvalidSettingsValueError("INITIAL_WINDOW_SIZE exceeds maximum value", FLOW_CONTROL_ERROR))
    elseif key == H2Frames.SETTINGS_MAX_FRAME_SIZE && !(16384 <= value <= 16777215)
        throw(InvalidSettingsValueError("MAX_FRAME_SIZE must be between 2^14 and 2^24-1", PROTOCOL_ERROR))
    end
end
end # module Connection