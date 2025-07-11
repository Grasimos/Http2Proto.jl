module H2Exceptions

export H2Error,
       ProtocolError,
       FrameTooLargeError,
       FrameDataMissingError,
       TooManyStreamsError,
       FlowControlError,
       StreamIDTooLowError,
       NoAvailableStreamIDError,
       NoSuchStreamError,
       StreamClosedError,
       InvalidSettingsValueError,
       InvalidBodyLengthError,
       UnsupportedFrameError,
       DenialOfServiceError,
       RFC1122Error

"""
    H2Error

The base abstract type for all custom exceptions in the H2 library.
Equivalent to `H2Error` in Python h2.
"""
abstract type H2Error <: Exception end

"""
    ProtocolError <: H2Error

A generic protocol error. Equivalent to `ProtocolError` in Python h2.

# Fields
- `msg::String`: Error message describing the protocol violation
"""
struct ProtocolError <: H2Error
    msg::String
end

"""
    FrameTooLargeError <: H2Error

The frame that was sent or received was too large.

# Fields
- `msg::String`: Error message describing the oversized frame
"""
struct FrameTooLargeError <: H2Error
    msg::String
end

"""
    FrameDataMissingError <: H2Error

The frame that was received did not contain all the required data.

# Fields
- `msg::String`: Error message describing the missing data
"""
struct FrameDataMissingError <: H2Error
    msg::String
end

"""
    TooManyStreamsError <: H2Error

An attempt was made to open a stream that would exceed the 
`MAX_CONCURRENT_STREAMS` limit.

# Fields
- `msg::String`: Error message describing the stream limit violation
"""
struct TooManyStreamsError <: H2Error
    msg::String
end

"""
    FlowControlError <: H2Error

An action violated the flow control rules.

# Fields
- `msg::String`: Error message describing the flow control violation
"""
struct FlowControlError <: H2Error
    msg::String
end

"""
    StreamIDTooLowError <: H2Error

An attempt was made to use a stream ID that is lower than the
last one that has already been used.

# Fields
- `stream_id::UInt32`: The attempted stream ID
- `max_stream_id::UInt32`: The highest stream ID that has been used
"""
struct StreamIDTooLowError <: H2Error
    stream_id::UInt32
    max_stream_id::UInt32
end

function Base.showerror(io::IO, e::StreamIDTooLowError)
    print(io, "StreamIDTooLowError: stream id $(e.stream_id) is lower than the highest seen stream id $(e.max_stream_id)")
end

"""
    NoAvailableStreamIDError <: H2Error

There are no more available stream IDs.

# Fields
- `msg::String`: Error message describing the stream ID exhaustion
"""
struct NoAvailableStreamIDError <: H2Error
    msg::String
end

"""
    NoSuchStreamError <: H2Error

The action concerned a stream that does not exist.

# Fields
- `stream_id::UInt32`: The stream ID that was referenced but does not exist
"""
struct NoSuchStreamError <: H2Error
    stream_id::UInt32
end

"""
    StreamClosedError <: H2Error

A more specific error indicating that the stream has been closed
and its state has been removed.

# Fields
- `stream_id::UInt32`: The stream ID that has been closed
"""
struct StreamClosedError <: H2Error
    stream_id::UInt32
end

"""
    InvalidSettingsValueError <: H2Error

An attempt was made to set an invalid value for a setting.

# Fields
- `msg::String`: Error message describing the invalid setting
- `error_code::UInt32`: The HTTP/2 error code associated with this violation
"""
struct InvalidSettingsValueError <: H2Error
    msg::String
    error_code::UInt32
end

"""
    InvalidBodyLengthError <: H2Error

The remote peer sent more or less data than was declared by the
`Content-Length` header.

# Fields
- `expected::Int`: The expected number of bytes based on Content-Length
- `actual::Int`: The actual number of bytes received
"""
struct InvalidBodyLengthError <: H2Error
    expected::Int
    actual::Int
end

function Base.showerror(io::IO, e::InvalidBodyLengthError)
    print(io, "InvalidBodyLengthError: Expected $(e.expected) bytes, received $(e.actual)")
end

"""
    UnsupportedFrameError <: H2Error

The remote peer sent a frame that is not supported in this context.

# Fields
- `msg::String`: Error message describing the unsupported frame
"""
struct UnsupportedFrameError <: H2Error
    msg::String
end

"""
    DenialOfServiceError <: H2Error

An error indicating a potential Denial of Service attack.

# Fields
- `msg::String`: Error message describing the potential DoS condition
"""
struct DenialOfServiceError <: H2Error
    msg::String
end

"""
    RFC1122Error <: H2Error

An error for actions that, while allowed by the RFC, are a bad idea
to permit (e.g., server-initiated prioritization).

# Fields
- `msg::String`: Error message describing the RFC violation
"""
struct RFC1122Error <: H2Error
    msg::String
end

end