"""
    H2Errors

HTTP/2 error codes and utilities for error handling.

This module defines the standard HTTP/2 error codes as specified in RFC 7540
and provides utilities for working with these error codes.
"""
module H2Errors

export ERROR_CODES, error_code_name,
       NO_ERROR, PROTOCOL_ERROR, INTERNAL_ERROR, FLOW_CONTROL_ERROR,
       SETTINGS_TIMEOUT, STREAM_CLOSED, FRAME_SIZE_ERROR, REFUSED_STREAM,
       CANCEL, COMPRESSION_ERROR, CONNECT_ERROR, ENHANCE_YOUR_CALM,
       INADEQUATE_SECURITY, HTTP_1_1_REQUIRED

"""
    NO_ERROR

The associated condition is not a result of an error.
For example, a GOAWAY might include this code to indicate graceful shutdown of a connection.
"""
const NO_ERROR              = UInt32(0x0)

"""
    PROTOCOL_ERROR

The endpoint detected an unspecific protocol error.
This error is for use when a more specific error code is not available.
"""
const PROTOCOL_ERROR        = UInt32(0x1)

"""
    INTERNAL_ERROR

The endpoint encountered an unexpected internal error.
"""
const INTERNAL_ERROR        = UInt32(0x2)

"""
    FLOW_CONTROL_ERROR

The endpoint detected that its peer violated the flow-control protocol.
"""
const FLOW_CONTROL_ERROR    = UInt32(0x3)

"""
    SETTINGS_TIMEOUT

The endpoint sent a SETTINGS frame but did not receive a response in a timely manner.
"""
const SETTINGS_TIMEOUT      = UInt32(0x4)

"""
    STREAM_CLOSED

The endpoint received a frame after a stream was half-closed.
"""
const STREAM_CLOSED         = UInt32(0x5)

"""
    FRAME_SIZE_ERROR

The endpoint received a frame with an invalid size.
"""
const FRAME_SIZE_ERROR      = UInt32(0x6)

"""
    REFUSED_STREAM

The endpoint refused the stream prior to performing any application processing.
"""
const REFUSED_STREAM        = UInt32(0x7)

"""
    CANCEL

Used by the endpoint to indicate that the stream is no longer needed.
"""
const CANCEL                = UInt32(0x8)

"""
    COMPRESSION_ERROR

The endpoint is unable to maintain the header compression context for the connection.
"""
const COMPRESSION_ERROR     = UInt32(0x9)

"""
    CONNECT_ERROR

The connection established in response to a CONNECT request was reset or abnormally closed.
"""
const CONNECT_ERROR         = UInt32(0xa)

"""
    ENHANCE_YOUR_CALM

The endpoint detected that its peer is exhibiting a behavior that might be generating
excessive load.
"""
const ENHANCE_YOUR_CALM     = UInt32(0xb)

"""
    INADEQUATE_SECURITY

The underlying transport has properties that do not meet minimum security requirements.
"""
const INADEQUATE_SECURITY   = UInt32(0xc)

"""
    HTTP_1_1_REQUIRED

The endpoint requires that HTTP/1.1 be used instead of HTTP/2.
"""
const HTTP_1_1_REQUIRED     = UInt32(0xd)

"""
    ERROR_CODES

A dictionary mapping error code values to their string names.
Used for converting numeric error codes to human-readable names.
"""
const ERROR_CODES = Dict{UInt32, String}(
    NO_ERROR              => "NO_ERROR",
    PROTOCOL_ERROR        => "PROTOCOL_ERROR",
    INTERNAL_ERROR        => "INTERNAL_ERROR",
    FLOW_CONTROL_ERROR    => "FLOW_CONTROL_ERROR",
    SETTINGS_TIMEOUT      => "SETTINGS_TIMEOUT",
    STREAM_CLOSED         => "STREAM_CLOSED",
    FRAME_SIZE_ERROR      => "FRAME_SIZE_ERROR",
    REFUSED_STREAM        => "REFUSED_STREAM",
    CANCEL                => "CANCEL",
    COMPRESSION_ERROR     => "COMPRESSION_ERROR",
    CONNECT_ERROR         => "CONNECT_ERROR",
    ENHANCE_YOUR_CALM     => "ENHANCE_YOUR_CALM",
    INADEQUATE_SECURITY   => "INADEQUATE_SECURITY",
    HTTP_1_1_REQUIRED     => "HTTP_1_1_REQUIRED"
)

"""
    error_code_name(code::UInt32) -> String

Convert an HTTP/2 error code to its string name.

# Arguments
- `code::UInt32`: The numeric error code

# Returns
- `String`: The name of the error code, or "UNKNOWN_ERROR_<hex>" for unrecognized codes

# Examples
```julia
julia> error_code_name(0x1)
"PROTOCOL_ERROR"

julia> error_code_name(0x99)
"UNKNOWN_ERROR_99"
```
"""
function error_code_name(code::UInt32)
    get(ERROR_CODES, code, "UNKNOWN_ERROR_$(string(code, base=16))")
end

end