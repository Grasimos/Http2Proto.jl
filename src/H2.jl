module H2

using HPACK
using H2Frames

include("Exc.jl");using ..Exc
include("H2Settings.jl");using ..H2Settings
include("RateLimiter.jl");using ..RateLimiter
# include("BufferManager.jl");using ..BufferManager
include("H2Types.jl");using ..H2Types
include("Streams.jl");using ..Streams
include("Connection.jl");using ..Connection
include("H2TLSIntegration.jl");using ..H2TLSIntegration
include("H2Client.jl");using ..H2Client
include("H2Server.jl");using ..H2Server
include("HTTPRouterAdapter.jl");using ..HTTPRouterAdapter


# ========================
#        PUBLIC API) 
# ========================
"""
    connect(host, port; kwargs...) -> HTTP2Client

Establishes a client connection. This is the public API.
"""
connect(host::String, port::Integer; kwargs...) = H2Client.connect(host, port; kwargs...)

"""
    request(client::HTTP2Client, method::String, path::String; kwargs...) -> HTTP2Response

Sends a request on an established client connection. This is the public API.
"""
request(client::H2Client.HTTP2Client, method::String, path::String; kwargs...) = H2Client.request(client, method, path; kwargs...)

"""
    serve(handler, host, port; kwargs...)

Starts the HTTP/2 server. This is the public API.
"""
serve(handler, host::String, port::Integer; kwargs...) = H2Server.serve(handler, host, port; kwargs...)

"""
    push_promise!(stream::HTTP2Stream, request_headers, response)

Initiates a server push on the given stream.
"""
push_promise!(conn::HTTP2Connection, stream::HTTP2Stream, args...; kwargs...) = H2Server.push_promise!(conn, stream, args...; kwargs...)

"""
    ping(client::HTTP2Client; kwargs...) -> Float64

Sends a PING and returns the round-trip time in seconds.
"""
ping(client::H2Client.HTTP2Client; kwargs...) = H2Client.ping(client; kwargs...)

"""
    close(obj::Union{HTTP2Client, HTTP2Server})

Closes a client or server object.
"""
close(obj::H2Client.HTTP2Client) = H2Client.close(obj)
close(obj::H2Server.HTTP2Server) = H2Server.close(obj)


export
    # Client API
    connect,
    request,
    close,
    ping,
    
    # Server API
    serve,
    push_promise!,

    # Adapters & Handlers
    H2Router,

    # Core Types
    HTTP2Client,
    HTTP2Server,
    HTTP2Connection,
    HTTP2Stream,
    HTTP2Settings,
    HTTP2Request,
    HTTP2Response,

    @h2log


end # module H2
