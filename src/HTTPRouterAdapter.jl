module HTTPRouterAdapter

using HTTP 

using ..H2Types: HTTP2Connection,HTTP2Stream, is_active
using ..Connection, ..Exc

export H2Router

struct H2Router
    router::HTTP.Router
end

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