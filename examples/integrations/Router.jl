# src/integrations/Router.jl

module H2RouterAdapter

using HTTP
using ..Server: ConnectionContext, HTTPStream, send_data_in_chunks
using H2Frames

export H2Router


struct H2Router
    router::HTTP.Router
end


function (h2r::H2Router)(context::ConnectionContext, stream_id::UInt32)
    local http_request::HTTP.Request
    
    errormonitor(@async begin
        try
            @lock context.sync_lock begin
                stream = context.streams[stream_id]
                
                http_headers = HTTP.Headers(stream.request_headers)
                
                method_substr = HTTP.header(http_headers, ":method", "GET")
                path_substr = HTTP.header(http_headers, ":path", "/")
                
                println("H2Router: Handling $(method_substr) $(path_substr) on stream $stream_id")

                http_request = HTTP.Request(
                    String(method_substr), 
                    String(path_substr),   
                    http_headers,
                    stream.request_body;
                    context=Dict(:stream_id => stream_id, :h2_context => context)
                )
            end

            http_response::HTTP.Response = h2r.router(http_request)
            println("H2Router: Application returned HTTP status $(http_response.status)")

            response_headers::Vector{Pair{String, String}} = [":status" => string(http_response.status); http_response.headers]
            
            if http_response.body isa IO
                headers_frame = H2Frames.create_headers_frame(stream_id, response_headers, context.hpack_encoder, end_stream=false)
                write(context.socket, H2Frames.serialize_frame(headers_frame))
                
                body_stream = http_response.body
                while !eof(body_stream)
                    chunk = read(body_stream, 16384)
                    is_last_chunk = eof(body_stream)
                    
                    data_frames = H2Frames.create_data_frame(stream_id, chunk; end_stream=is_last_chunk)
                    for frame in data_frames
                         write(context.socket, H2Frames.serialize_frame(frame))
                    end
                end
            else
                response_body = Vector{UInt8}(http_response.body)
                end_stream = isempty(response_body)

                headers_frame = H2Frames.create_headers_frame(stream_id, response_headers, context.hpack_encoder, end_stream=end_stream)
                write(context.socket, H2Frames.serialize_frame(headers_frame))
                
                if !end_stream
                    @lock context.sync_lock begin
                        stream = context.streams[stream_id]
                        send_data_in_chunks(context, stream, response_body)
                    end
                end
            end
            println("H2Router: Response sent for stream $stream_id.")

        catch e
            println("🔥 H2Router: Unhandled error: $e")
            showerror(stdout, e, catch_backtrace())
            try
                error_headers = [":status" => "500"]
                error_frame = H2Frames.create_headers_frame(stream_id, error_headers, context.hpack_encoder, end_stream=true)
                write(context.socket, H2Frames.serialize_frame(error_frame))
            catch inner_e
                 println("🔥 H2Router: Failed to even send 500 error response: $inner_e")
            end
        end
    end)
end

end