module Exc 

# =============================================================================
# Abstract Exception Hierarchy
# =============================================================================
"Abstract base type for all HTTP/2 exceptions."
abstract type HTTP2Exception <: Exception end

"Abstract type for errors that MUST terminate the entire connection."
abstract type ConnectionLevelError <: HTTP2Exception end

"Abstract type for errors that can be resolved by resetting a single stream."
abstract type StreamLevelError <: HTTP2Exception end

# =============================================================================
# Concrete Exception Types
# =============================================================================
"A generic, unspecific protocol violation. Results in a GOAWAY with PROTOCOL_ERROR."
struct ProtocolError <: ConnectionLevelError
    msg::String
end
Base.showerror(io::IO, e::ProtocolError) = print(io, "ProtocolError: ", e.msg)

"An unexpected internal error in the implementation. Results in a GOAWAY with INTERNAL_ERROR."
struct InternalError <: ConnectionLevelError
    msg::String
end
Base.showerror(io::IO, e::InternalError) = print(io, "InternalError: ", e.msg)

"Violation of the HPACK specification. Results in a GOAWAY with COMPRESSION_ERROR."
struct CompressionError <: ConnectionLevelError
    msg::String
end
Base.showerror(io::IO, e::CompressionError) = print(io, "CompressionError: ", e.msg)

"A flow-control protocol violation. Can be a stream or connection error."
struct FlowControlError <: HTTP2Exception # Can be either level
    msg::String
    stream_id::Int32
end
FlowControlError(msg::String, stream_id::Integer=0) = FlowControlError(msg, Int32(stream_id))
Base.showerror(io::IO, e::FlowControlError) = print(io, "FlowControlError(stream=$(e.stream_id)): ", e.msg)
is_connection_error(e::FlowControlError) = e.stream_id == 0

"A frame with an invalid size was received. Results in a GOAWAY with FRAME_SIZE_ERROR."
struct FrameSizeError <: ConnectionLevelError
    msg::String
end
Base.showerror(io::IO, e::FrameSizeError) = print(io, "FrameSizeError: ", e.msg)

"An operation was attempted on a closed stream. Results in RST_STREAM with STREAM_CLOSED."
struct StreamClosedError <: StreamLevelError
    msg::String
    stream_id::Int32
end
StreamClosedError(msg::String, stream_id::Integer) = StreamClosedError(msg, Int32(stream_id))
Base.showerror(io::IO, e::StreamClosedError) = print(io, "StreamClosedError(stream=$(e.stream_id)): ", e.msg)

"A stream was refused by the peer. Results in RST_STREAM with REFUSED_STREAM."
struct RefusedStreamError <: StreamLevelError
    msg::String
    stream_id::Int32
end
RefusedStreamError(msg::String, stream_id::Integer) = RefusedStreamError(msg, Int32(stream_id))
Base.showerror(io::IO, e::RefusedStreamError) = print(io, "RefusedStreamError(stream=$(e.stream_id)): ", e.msg)

"A new stream could not be created because the concurrency limit was reached."
struct StreamLimitError <: StreamLevelError
    msg::String
end
Base.showerror(io::IO, e::StreamLimitError) = print(io, "StreamLimitError: ", e.msg)

# =============================================================================
# Generic Error Wrappers
# =============================================================================
struct ConnectionError <: ConnectionLevelError
    code::Symbol
    msg::String
end
Base.showerror(io::IO, e::ConnectionError) = print(io, "ConnectionError($(e.code)): ", e.msg)

struct StreamError <: StreamLevelError
    code::Symbol
    msg::String
    stream_id::Int32
end
StreamError(code::Symbol, msg::String, stream_id::Integer) = StreamError(code, msg, Int32(stream_id))
Base.showerror(io::IO, e::StreamError) = print(io, "StreamError($(e.code), stream=$(e.stream_id)): ", e.msg)

# =============================================================================
# Utility Functions
# =============================================================================
# Map exception types to protocol error code symbols
const EXCEPTION_TO_ERROR_CODE_MAP = Dict{DataType, Symbol}(
    ProtocolError       => :PROTOCOL_ERROR,
    InternalError       => :INTERNAL_ERROR,
    CompressionError    => :COMPRESSION_ERROR,
    FlowControlError    => :FLOW_CONTROL_ERROR,
    FrameSizeError      => :FRAME_SIZE_ERROR,
    StreamClosedError   => :STREAM_CLOSED_ERROR,
    RefusedStreamError  => :REFUSED_STREAM,
    StreamLimitError    => :REFUSED_STREAM
)

"Convert an HTTP/2 exception to its corresponding error code symbol."
function exception_to_error_code(ex::HTTP2Exception)
    if ex isa ConnectionError || ex isa StreamError
        return ex.code
    end
    return get(EXCEPTION_TO_ERROR_CODE_MAP, typeof(ex), :INTERNAL_ERROR)
end

# --- Error Code Helper Functions ---

const ERROR_CODE_DESCRIPTIONS = Dict{Symbol, String}(
    :NO_ERROR            => "The associated condition is not a result of an error.",
    :PROTOCOL_ERROR      => "The endpoint detected an unspecific protocol error.",
    :INTERNAL_ERROR      => "The endpoint encountered an unexpected internal error.",
    :FLOW_CONTROL_ERROR  => "The endpoint detected that its peer violated the flow-control protocol.",
    :SETTINGS_TIMEOUT    => "The endpoint sent a SETTINGS frame but did not receive a response in a timely manner.",
    :STREAM_CLOSED_ERROR => "The endpoint received a frame after a stream was half-closed.",
    :FRAME_SIZE_ERROR    => "The endpoint received a frame with an invalid size.",
    :REFUSED_STREAM      => "The endpoint refused the stream prior to performing any application processing.",
    :CANCEL              => "The endpoint indicates that the stream is no longer needed.",
    :COMPRESSION_ERROR   => "The endpoint is unable to maintain the header compression context for the connection.",
    :CONNECT_ERROR       => "The connection established in response to a CONNECT request was reset or abnormally closed.",
    :ENHANCE_YOUR_CALM   => "The endpoint detected that its peer is exhibiting a behavior that might be generating excessive load.",
    :INADEQUATE_SECURITY => "The underlying transport has properties that do not meet minimum security requirements.",
    :HTTP_1_1_REQUIRED   => "The endpoint requires that HTTP/1.1 be used instead of HTTP/2."
)

# --- Error Code Value Mapping ---
const ERROR_CODE_VALUES = Dict{Symbol, UInt32}(
    :NO_ERROR            => 0x0,
    :PROTOCOL_ERROR      => 0x1,
    :INTERNAL_ERROR      => 0x2,
    :FLOW_CONTROL_ERROR  => 0x3,
    :SETTINGS_TIMEOUT    => 0x4,
    :STREAM_CLOSED_ERROR => 0x5,
    :FRAME_SIZE_ERROR    => 0x6,
    :REFUSED_STREAM      => 0x7,
    :CANCEL              => 0x8,
    :COMPRESSION_ERROR   => 0x9,
    :CONNECT_ERROR       => 0xa,
    :ENHANCE_YOUR_CALM   => 0xb,
    :INADEQUATE_SECURITY => 0xc,
    :HTTP_1_1_REQUIRED   => 0xd
)

"Returns the name of the error code as a string for logging/debugging."
error_code_name(code::Symbol) = String(code)

"Returns a human-readable description of the error code."
function error_code_description(code::Symbol)
    return get(ERROR_CODE_DESCRIPTIONS, code, "Unknown error code.")
end

"Return the UInt32 value for a given error code symbol."
function error_code_value(code::Symbol)
    return get(ERROR_CODE_VALUES, code, 0x2) # Default to INTERNAL_ERROR (0x2)
end

const VALUE_TO_ERROR_CODE_MAP = Dict(v => k for (k, v) in ERROR_CODE_VALUES)

"Returns the name of the error code from its UInt32 value."
function error_code_name(code::UInt32)
    return get(VALUE_TO_ERROR_CODE_MAP, code, :UNKNOWN_CODE)
end

const NO_ERROR              = :NO_ERROR
const PROTOCOL_ERROR        = :PROTOCOL_ERROR
const INTERNAL_ERROR        = :INTERNAL_ERROR
const FLOW_CONTROL_ERROR    = :FLOW_CONTROL_ERROR
const SETTINGS_TIMEOUT      = :SETTINGS_TIMEOUT
const STREAM_CLOSED_ERROR   = :STREAM_CLOSED_ERROR
const FRAME_SIZE_ERROR      = :FRAME_SIZE_ERROR
const REFUSED_STREAM        = :REFUSED_STREAM
const CANCEL                = :CANCEL
const COMPRESSION_ERROR     = :COMPRESSION_ERROR
const CONNECT_ERROR         = :CONNECT_ERROR
const ENHANCE_YOUR_CALM     = :ENHANCE_YOUR_CALM
const INADEQUATE_SECURITY   = :INADEQUATE_SECURITY
const HTTP_1_1_REQUIRED     = :HTTP_1_1_REQUIRED

export
    # Exception Types
    HTTP2Exception, ConnectionLevelError, StreamLevelError,
    ProtocolError, InternalError, CompressionError, FlowControlError,
    FrameSizeError, StreamClosedError, RefusedStreamError, StreamLimitError,
    ConnectionError, StreamError,

    # Utility Functions
    exception_to_error_code, error_code_name, error_code_description, error_code_value,

    # Error Code Constants
    NO_ERROR, PROTOCOL_ERROR, INTERNAL_ERROR, FLOW_CONTROL_ERROR,
    SETTINGS_TIMEOUT, STREAM_CLOSED_ERROR, FRAME_SIZE_ERROR, REFUSED_STREAM,
    CANCEL, COMPRESSION_ERROR, CONNECT_ERROR, ENHANCE_YOUR_CALM,
    INADEQUATE_SECURITY, HTTP_1_1_REQUIRED

end