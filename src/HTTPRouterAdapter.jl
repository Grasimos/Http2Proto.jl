module HTTPRouterAdapter

using HTTP 

using ..H2Types: HTTP2Connection,HTTP2Stream, is_active
using ..Connection, ..Exc

export H2Router

"""
    H2Router

Adapter type that wraps an `HTTP.Router` for use as an HTTP/2 handler.
Allows you to use HTTP.jl-style routing and request/response handling with H2.jl connections and streams.

# Example
```julia
router = HTTP.Router()
HTTP.register!(router, "GET", "/", req -> HTTP.Response(200, "Hello"))
h2_handler = H2Router(router)
```
"""
struct H2Router
    router::HTTP.Router
end

"""
    (h2r::H2Router)(conn::HTTP2Connection, stream::HTTP2Stream)

Handle an incoming HTTP/2 stream using the wrapped HTTP.Router.

- Reads headers and body from the stream.
- Constructs an `HTTP.Request` with the correct method, path, headers, and body.
- Passes the request to the router and gets an `HTTP.Response`.
- Sends the response headers and body back on the stream.
- Handles errors and ensures a 500 response is sent if an exception occurs.
- Attaches the stream object to the request context as `:stream` for advanced handlers.

# Arguments
- `conn::HTTP2Connection`: The parent HTTP/2 connection.
- `stream::HTTP2Stream`: The stream to handle.

# Notes
- If the stream is closed by the handler, no response is sent.
- All exceptions are logged and a 500 error is sent if possible.
"""
function (h2r::H2Router)(conn::HTTP2Connection, stream::HTTP2Stream)
    @info "H2Router: Handling request on stream $(stream.id)"
    try
        req_headers_list = Connection.wait_for_headers(stream)
        req_body_bytes = Connection.wait_for_body(stream)
        http_headers = HTTP.Headers(req_headers_list)
        method = String(HTTP.header(http_headers, ":method", "GET"))
        path = String(HTTP.header(http_headers, ":path", "/"))
        http_request = HTTP.Request(method, path, http_headers, req_body_bytes; context=Dict(:stream => stream))
        http_response::HTTP.Response = h2r.router(http_request)
        @info "H2Router: Application returned HTTP.Response with status $(http_response.status)"
        if !is_active(stream)
            @info "H2Router: Stream $(stream.id) was closed by the handler. Not sending a response."
            return
        end
        response_headers = [":status" => string(http_response.status); http_response.headers]
        if isempty(http_response.body)
            Connection.send_headers!(stream, response_headers; end_stream=true)
        else
            Connection.send_headers!(stream, response_headers; end_stream=false)
            response_body_bytes = Vector{UInt8}(http_response.body)
            Connection.send_data!(stream, response_body_bytes; end_stream=true)
        end
        @info "H2Router: Successfully handled and sent response for stream $(stream.id)."

    catch e
        @error "H2Router: Unhandled error in adapter" stream_id=stream.id exception=(e, catch_backtrace())
        try
            if is_active(stream)
                error_headers = [":status" => "500"]
                Connection.send_headers!(stream, error_headers; end_stream=true)
                @warn "H2Router: Sent 500 error response to client."
            end
        catch inner_e
            @error "H2Router: Failed to send 500 error response." exception=inner_e
        end
    finally
        @info "H2Router: Handler for stream $(stream.id) finished."
    end
end

end # module