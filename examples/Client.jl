module Client

using Sockets
using Logging
using H2Frames

using ..H2
using ..Connection
using ..Events
using ..H2TLSIntegration

const ALPN_PROTOCOLS = ["h2", "http/1.1"]
const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

"""
    make_request(host::String, port::Int)
"""
function make_request(host::String, port::Int)
    socket = nothing
    try
        socket = H2TLSIntegration.tls_connect(host, port; alpn_protocols=ALPN_PROTOCOLS)
        @info "✅ TLS Connection established."

        conn = H2Connection(client=true)

        # Send connection preface
        write(socket, CONNECTION_PREFACE)
        
        # Send initial SETTINGS frame
        settings_frame = H2Frames.Frame(
            H2Frames.Header(0, H2Frames.FRAME_TYPE_SETTINGS, 0x0, 0),
            UInt8[]
        )
        write(socket, H2Frames.serialize_frame(settings_frame))
        @debug "Sent preface and initial SETTINGS frame."

        # Prepare request headers
        request_headers = [
            ":method" => "GET",
            ":path" => "/simple",
            ":authority" => host,
            ":scheme" => "https"
        ]

        # Send request
        send_headers(conn, 1, request_headers, end_stream=true)

        bytes_to_send = data_to_send(conn)
        if !isempty(bytes_to_send)
            write(socket, bytes_to_send)
            @info "🚀 Request for '/simple' sent on stream 1."
        end

        # Response handling
        response_headers = []
        response_body = IOBuffer()
        stream_ended = false

        while !stream_ended
            incoming_data = readavailable(socket)
            if isempty(incoming_data) && eof(socket)
                @warn "Connection closed prematurely."
                break
            end

            events = receive_data!(conn, incoming_data)

            for event in events
                @debug "Client handling event: $(typeof(event))"
                handle_client_event(conn, event, socket, response_headers, response_body, stream_ended)
            end

            bytes_to_send = data_to_send(conn)
            if !isempty(bytes_to_send)
                write(socket, bytes_to_send)
            end
        end

        # Display results
        @info "✅🎉 Request complete!"
        final_body = String(take!(response_body))
        println("===== RESPONSE =====")
        println("Headers: $response_headers")
        println("Body: $final_body")
        println("====================")
        return true

    catch ex
        @error "🔥 Client Scenario Error: $ex"
        showerror(stdout, ex, catch_backtrace())
        return false
    finally
        isnothing(socket) || close(socket)
    end
end

"""
    handle_client_event(conn, event, socket, response_headers, response_body, stream_ended)

Handle individual events received by the client.
"""
function handle_client_event(conn::H2Connection, event::Event, socket::IO, 
                           response_headers::Vector, response_body::IOBuffer, 
                           stream_ended::Ref{Bool})
    _handle_client(conn, event, socket, response_headers, response_body, stream_ended)
end

function _handle_client(conn, event, socket, response_headers, response_body, stream_ended)
    @debug "Unhandled client event: $(typeof(event))"
end

function _handle_client(conn::H2Connection, event::ResponseReceived, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    if event.stream_id == 1
        append!(response_headers, event.headers)
        @info "👍 Received response headers: $(event.headers)"
    end
end

function _handle_client(conn::H2Connection, event::DataReceived, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    if event.stream_id == 1
        write(response_body, event.data)
        @info "👍 Received $(length(event.data)) bytes of response body."
    end
end

function _handle_client(conn::H2Connection, event::StreamEnded, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    if event.stream_id == 1
        @info "🏁 Stream 1 ended."
        stream_ended[] = true
    end
end

function _handle_client(conn::H2Connection, event::SettingsChanged, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    # Send SETTINGS ACK
    ack_frame = H2Frames.Frame(
        H2Frames.Header(0, H2Frames.FRAME_TYPE_SETTINGS, H2Frames.FLAG_ACK, 0),
        UInt8[]
    )
    write(socket, H2Frames.serialize_frame(ack_frame))
    @debug "Sent SETTINGS ACK."
end

function _handle_client(conn::H2Connection, event::InformationalResponseReceived, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    if event.stream_id == 1
        @info "👍 Received informational response ($(event.headers))"
    end
end

function _handle_client(conn::H2Connection, event::PingReceived, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    @debug "Received PING, will send PING ACK automatically"
end

function _handle_client(conn::H2Connection, event::ConnectionTerminated, socket::IO,
                       response_headers::Vector, response_body::IOBuffer, stream_ended::Ref{Bool})
    @warn "Connection terminated by server: error_code=$(event.error_code), last_stream_id=$(event.last_stream_id)"
    stream_ended[] = true
end

end