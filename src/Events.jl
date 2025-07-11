"""
    Events

HTTP/2 event system for connection and stream lifecycle management.

This module defines the event types that represent various HTTP/2 protocol
events such as requests, responses, data transfers, settings changes, and
connection management. Events are used to communicate protocol state changes
between different components of the HTTP/2 implementation.

The event system provides:
- Type-safe event definitions for all HTTP/2 protocol events
- Automatic timestamp tracking for debugging and monitoring
- Validation of protocol-specific constraints
- Stream and connection lifecycle management
"""
module Events

using ..H2Errors
using Dates

export Event, RequestReceived, ResponseReceived, DataReceived, StreamEnded,
       SettingsChanged, WindowUpdated, StreamReset, ConnectionTerminated,
       PriorityChanged, PingReceived, PingAck, InformationalResponseReceived, H2CUpgradeReceived

"""
    Event

Abstract base type for all HTTP/2 protocol events.

All specific event types inherit from this abstract type, allowing for
type-safe event handling and dispatch.
"""
abstract type Event end

"""
    Priority

Represents HTTP/2 stream priority information.

# Fields
- `stream_dependency::UInt32`: The stream ID this stream depends on
- `weight::UInt8`: The weight of this stream (1-256, stored as 0-255)
- `exclusive::Bool`: Whether this dependency is exclusive
"""
struct Priority
    stream_dependency::UInt32
    weight::UInt8
    exclusive::Bool
end

"""
    validate_stream_id(stream_id::UInt32) -> UInt32

Validate that a stream ID is within the valid range.

# Arguments
- `stream_id::UInt32`: The stream ID to validate

# Returns
- `UInt32`: The validated stream ID

# Throws
- `ArgumentError`: If the stream ID exceeds 2^31 - 1
"""
function validate_stream_id(stream_id::UInt32)
    if stream_id > 0x7FFFFFFF  # 2^31 - 1
        throw(ArgumentError("Stream ID must be ≤ 2^31 - 1, got $stream_id"))
    end
    return stream_id
end

"""
    validate_error_code(error_code::UInt32) -> UInt32

Validate that an error code is a valid UInt32.

# Arguments
- `error_code::UInt32`: The error code to validate

# Returns
- `UInt32`: The validated error code

# Throws
- `ArgumentError`: If the error code is invalid
"""
function validate_error_code(error_code::UInt32)
    if error_code > 0xFFFFFFFF
        throw(ArgumentError("Error code must be a valid UInt32, got $error_code"))
    end
    return error_code
end

"""
    add_timestamp() -> Float64

Add a timestamp to an event.

# Returns
- `Float64`: Current Unix timestamp
"""
function add_timestamp()
    return time()
end

"""
    RequestReceived <: Event

Event indicating that a client sent a complete request (headers).

This event is fired when a complete HTTP/2 request has been received,
including all necessary headers to process the request.

# Fields
- `stream_id::UInt32`: The stream ID for this request
- `headers::Vector{Pair{String, String}}`: The request headers
- `priority::Union{Priority, Nothing}`: Optional priority information
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> headers = ["method" => "GET", "path" => "/api/data"]
julia> event = RequestReceived(UInt32(1), headers)
RequestReceived(0x00000001, [...], nothing, 1.234567e9)
```
"""
struct RequestReceived <: Event
    stream_id::UInt32
    headers::Vector{Pair{String, String}}
    priority::Union{Priority, Nothing}
    timestamp::Float64
    
    function RequestReceived(stream_id::UInt32, headers::Vector{Pair{String, String}}, 
                           priority::Union{Priority, Nothing} = nothing)
        validate_stream_id(stream_id)
        new(stream_id, headers, priority, add_timestamp())
    end
end

"""
    ResponseReceived <: Event

Event indicating that a server sent a complete response (headers).

This event is fired when a complete HTTP/2 response has been received,
including all necessary headers to process the response.

# Fields
- `stream_id::UInt32`: The stream ID for this response
- `headers::Vector{Pair{String, String}}`: The response headers
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> headers = ["status" => "200", "content-type" => "application/json"]
julia> event = ResponseReceived(UInt32(1), headers)
ResponseReceived(0x00000001, [...], 1.234567e9)
```
"""
struct ResponseReceived <: Event
    stream_id::UInt32
    headers::Vector{Pair{String, String}}
    timestamp::Float64
    
    function ResponseReceived(stream_id::UInt32, headers::Vector{Pair{String, String}})
        validate_stream_id(stream_id)
        new(stream_id, headers, add_timestamp())
    end
end

"""
    DataReceived <: Event

Event indicating that we received data (a DATA frame) for a stream.

This event is fired when HTTP/2 DATA frames are received, containing
the actual payload data for a request or response.

# Fields
- `stream_id::UInt32`: The stream ID for this data
- `data::Vector{UInt8}`: The received data bytes
- `flow_controlled_length::UInt32`: The length for flow control purposes
- `end_stream::Bool`: Whether this data ends the stream
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> data = Vector{UInt8}("Hello, World!")
julia> event = DataReceived(UInt32(1), data, UInt32(13), false)
DataReceived(0x00000001, [...], 0x0000000d, false, 1.234567e9)
```
"""
struct DataReceived <: Event
    stream_id::UInt32
    data::Vector{UInt8}
    flow_controlled_length::UInt32
    end_stream::Bool
    timestamp::Float64
    
    function DataReceived(stream_id::UInt32, data::Vector{UInt8}, 
                         flow_controlled_length::UInt32, end_stream::Bool = false)
        validate_stream_id(stream_id)
        new(stream_id, data, flow_controlled_length, end_stream, add_timestamp())
    end
end

"""
    StreamEnded <: Event

Event indicating that a stream completed normally.

This event is fired when an HTTP/2 stream reaches its natural end,
either through END_STREAM flags or successful completion.

# Fields
- `stream_id::UInt32`: The stream ID that ended
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> event = StreamEnded(UInt32(1))
StreamEnded(0x00000001, 1.234567e9)
```
"""
struct StreamEnded <: Event
    stream_id::UInt32
    timestamp::Float64
    
    function StreamEnded(stream_id::UInt32)
        validate_stream_id(stream_id)
        new(stream_id, add_timestamp())
    end
end

"""
    SettingsChanged <: Event

Event indicating that the remote peer changed its settings.

This event is fired when SETTINGS frames are received and acknowledged,
indicating changes to the connection's operational parameters.

# Fields
- `changed_settings::Dict{Symbol, UInt32}`: The settings that changed
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> settings = Dict(:max_frame_size => UInt32(32768))
julia> event = SettingsChanged(settings)
SettingsChanged(Dict(:max_frame_size => 0x00008000), 1.234567e9)
```
"""
struct SettingsChanged <: Event
    changed_settings::Dict{Symbol, UInt32}
    timestamp::Float64
    
    function SettingsChanged(changed_settings::Dict{Symbol, UInt32})
        new(changed_settings, add_timestamp())
    end
end

"""
    WindowUpdated <: Event

Event indicating that a flow-control window was updated.

This event is fired when WINDOW_UPDATE frames are received, indicating
changes to stream or connection flow control windows.

# Fields
- `stream_id::UInt32`: The stream ID (0 for connection-level window)
- `increment::UInt32`: The window increment value
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> event = WindowUpdated(UInt32(1), UInt32(1024))  # Stream window
WindowUpdated(0x00000001, 0x00000400, 1.234567e9)

julia> event = WindowUpdated(UInt32(0), UInt32(65536))  # Connection window
WindowUpdated(0x00000000, 0x00010000, 1.234567e9)
```
"""
struct WindowUpdated <: Event
    stream_id::UInt32  # 0 for connection-level window
    increment::UInt32
    timestamp::Float64
    
    function WindowUpdated(stream_id::UInt32, increment::UInt32)
        # Stream ID 0 is valid for connection-level updates
        if stream_id != 0
            validate_stream_id(stream_id)
        end
        new(stream_id, increment, add_timestamp())
    end
end

"""
    StreamReset <: Event

Event indicating that a stream was terminated abruptly.

This event is fired when RST_STREAM frames are received, indicating
that a stream has been reset due to an error or cancellation.

# Fields
- `stream_id::UInt32`: The stream ID that was reset
- `error_code::UInt32`: The error code indicating why the stream was reset
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> event = StreamReset(UInt32(1), CANCEL)
StreamReset(0x00000001, 0x00000008, 1.234567e9)
```
"""
struct StreamReset <: Event
    stream_id::UInt32
    error_code::UInt32
    timestamp::Float64
    
    function StreamReset(stream_id::UInt32, error_code::UInt32)
        validate_stream_id(stream_id)
        validate_error_code(error_code)
        new(stream_id, error_code, add_timestamp())
    end
end

"""
    ConnectionTerminated <: Event

Event indicating that the connection should be terminated (GOAWAY).

This event is fired when GOAWAY frames are received, indicating that
the connection is being closed and no new streams should be created.

# Fields
- `last_stream_id::UInt32`: The highest stream ID that will be processed
- `error_code::UInt32`: The error code indicating why the connection is closing
- `additional_debug_data::Vector{UInt8}`: Optional debug information
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> event = ConnectionTerminated(UInt32(5), NO_ERROR)
ConnectionTerminated(0x00000005, 0x00000000, UInt8[], 1.234567e9)
```
"""
struct ConnectionTerminated <: Event
    last_stream_id::UInt32
    error_code::UInt32
    additional_debug_data::Vector{UInt8}
    timestamp::Float64
    
    function ConnectionTerminated(last_stream_id::UInt32, error_code::UInt32, 
                                additional_debug_data::Vector{UInt8} = UInt8[])
        validate_stream_id(last_stream_id)
        validate_error_code(error_code)
        new(last_stream_id, error_code, additional_debug_data, add_timestamp())
    end
end

"""
    PriorityChanged <: Event

Event indicating that a stream's priority changed.

This event is fired when PRIORITY frames are received, indicating
changes to the stream dependency tree and prioritization.

# Fields
- `stream_id::UInt32`: The stream ID whose priority changed
- `priority::Priority`: The new priority information
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> priority = Priority(UInt32(0), UInt8(15), false)
julia> event = PriorityChanged(UInt32(1), priority)
PriorityChanged(0x00000001, Priority(...), 1.234567e9)
```
"""
struct PriorityChanged <: Event
    stream_id::UInt32
    priority::Priority
    timestamp::Float64
    
    function PriorityChanged(stream_id::UInt32, priority::Priority)
        validate_stream_id(stream_id)
        new(stream_id, priority, add_timestamp())
    end
end

"""
    PingReceived <: Event

Event indicating that we received a PING frame.

This event is fired when PING frames are received, which are used
for connection liveness testing and round-trip time measurement.

# Fields
- `data::Vector{UInt8}`: The 8-byte ping data
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> data = rand(UInt8, 8)
julia> event = PingReceived(data)
PingReceived([...], 1.234567e9)
```
"""
struct PingReceived <: Event
    data::Vector{UInt8}  # 8 bytes
    timestamp::Float64
    
    function PingReceived(data::Vector{UInt8})
        if length(data) != 8
            throw(ArgumentError("PING data must be exactly 8 bytes, got $(length(data))"))
        end
        new(data, add_timestamp())
    end
end

"""
    PingAck <: Event

Event indicating that we received a PING ACK frame.

This event is fired when PING frames with the ACK flag are received,
indicating a response to a previously sent PING.

# Fields
- `data::Vector{UInt8}`: The 8-byte ping data (should match the original PING)
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> data = rand(UInt8, 8)
julia> event = PingAck(data)
PingAck([...], 1.234567e9)
```
"""
struct PingAck <: Event
    data::Vector{UInt8}  # 8 bytes
    timestamp::Float64
    
    function PingAck(data::Vector{UInt8})
        if length(data) != 8
            throw(ArgumentError("PING ACK data must be exactly 8 bytes, got $(length(data))"))
        end
        new(data, add_timestamp())
    end
end

"""
    InformationalResponseReceived <: Event

Event indicating that we received a 1xx (informational) response.

This event is fired when informational responses (100 Continue, 
103 Early Hints, etc.) are received, which don't end the stream.

# Fields
- `stream_id::UInt32`: The stream ID for this response
- `headers::Vector{Pair{String, String}}`: The informational response headers
- `timestamp::Float64`: When the event occurred

# Examples
```julia
julia> headers = ["status" => "100"]
julia> event = InformationalResponseReceived(UInt32(1), headers)
InformationalResponseReceived(0x00000001, [...], 1.234567e9)
```
"""
struct InformationalResponseReceived <: Event
    stream_id::UInt32
    headers::Vector{Pair{String, String}}
    timestamp::Float64
    
    function InformationalResponseReceived(stream_id::UInt32, headers::Vector{Pair{String, String}})
        validate_stream_id(stream_id)
        new(stream_id, headers, add_timestamp())
    end
end

"""
    H2CUpgradeReceived <: Event

Event indicating that an HTTP/2 connection upgrade was received.

This event is fired during the HTTP/1.1 to HTTP/2 upgrade process,
carrying the initial HTTP/2 settings from the client.

# Fields
- `http2_settings::Dict{UInt16, UInt32}`: The HTTP/2 settings from the upgrade

# Examples
```julia
julia> settings = Dict{UInt16, UInt32}(0x0002 => 0x00000000)  # ENABLE_PUSH = 0
julia> event = H2CUpgradeReceived(settings)
H2CUpgradeReceived(Dict(0x0002 => 0x00000000))
```
"""
struct H2CUpgradeReceived <: Event
    http2_settings::Dict{UInt16, UInt32}
end

"""
    event_summary(event::Event) -> String

Generate a human-readable summary of an event.

This function creates a formatted string representation of an event,
including timestamp and stream information where applicable.

# Arguments
- `event::Event`: The event to summarize

# Returns
- `String`: A formatted summary of the event

# Examples
```julia
julia> event = RequestReceived(UInt32(1), ["method" => "GET"])
julia> event_summary(event)
"[2024-01-15T10:30:45.123] RequestReceived (Stream: 1)"
```
"""
function event_summary(event::Event)
    type_name = typeof(event) |> string
    timestamp_str = Dates.unix2datetime(event.timestamp)
    
    if hasfield(typeof(event), :stream_id)
        return "[$timestamp_str] $type_name (Stream: $(event.stream_id))"
    else
        return "[$timestamp_str] $type_name"
    end
end

end