module Client

using Sockets
using Logging

# Import the H2 modules
using H2.Connection: H2Connection, receive_data!, send_headers, send_data, data_to_send, initiate_connection!
using H2.Config: H2Config
using H2.Events
using H2Frames

include("integrations/tls.jl")
using .H2TLSIntegration

"""
    make_request(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])

Make an HTTP/2 request and return the response data.
Returns a tuple: (success::Bool, status::String, response_headers::Vector, response_body::String)
"""
function make_request(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])
    @info "Making request to https://$host:$port$path"
    
    # Establish TLS connection
    socket = nothing
    try
        socket = H2TLSIntegration.tls_connect(host, port)
        @info "✅ TLS Connection established to $host:$port"
    catch e
        @error "❌ Failed to establish TLS connection: $e"
        return (false, "", Pair{String,String}[], "")
    end
    
    try
        # Create HTTP/2 connection
        config = H2Config(client_side=true)
        conn = H2Connection(config=config)
        
        # Send connection preface
        initiate_connection!(conn)
        initial_data = data_to_send(conn)
        if !isempty(initial_data)
            write(socket, initial_data)
            @debug "Sent connection preface and initial SETTINGS"
        end
        
        # Improved server SETTINGS handling
        @debug "Waiting for server's initial SETTINGS..."
        server_ready = false
        settings_timeout = 10.0  # Increased timeout
        start_time = time()
        
        while !server_ready && (time() - start_time) < settings_timeout
            if bytesavailable(socket) > 0
                try
                    # Read available data
                    data = readavailable(socket)
                    @debug "Received $(length(data)) bytes during SETTINGS exchange"
                    
                    # Process the data
                    events = receive_data!(conn, data)
                    @debug "Processed $(length(events)) events during SETTINGS"
                    
                    # Send any response data (like SETTINGS ACK)
                    response_data = data_to_send(conn)
                    if !isempty(response_data)
                        write(socket, response_data)
                        @debug "Sent $(length(response_data)) bytes in response"
                    end
                    
                    # Check if we received SETTINGS
                    for event in events
                        if event isa Events.SettingsChanged
                            @debug "Received SETTINGS frame"
                            server_ready = true
                            break
                        end
                    end
                    
                catch e
                    @warn "Error during SETTINGS exchange: $e"
                    break
                end
            else
                sleep(0.01)
            end
        end
        
        if !server_ready
            @warn "Server SETTINGS not received within timeout, continuing anyway"
        else
            @debug "✅ HTTP/2 connection established successfully"
        end
        
        # Small delay to ensure connection is stable
        sleep(0.1)
        
        # Prepare request headers
        request_headers = [
            ":method" => "GET",
            ":path" => path,
            ":authority" => host,
            ":scheme" => "https"
        ]
        
        # Add custom headers
        for header in headers
            push!(request_headers, header)
        end
        
        # Send request
        stream_id = UInt32(1)
        @info "Sending HEADERS for stream $stream_id"
        send_headers(conn, stream_id, request_headers, end_stream=true)
        
        # Send the request data
        request_data = data_to_send(conn)
        if !isempty(request_data)
            write(socket, request_data)
            @info "🚀 Request sent for '$path' on stream $stream_id"
        else
            @warn "No request data to send"
        end
        
        # Improved response handling
        response_status = ""
        response_headers = Pair{String,String}[]
        response_body = ""
        response_complete = false
        headers_received = false
        
        # Response timeout and timing
        start_time = time()
        timeout = 30.0
        last_activity = time()
        activity_timeout = 2.0  # Consider complete if no activity for 2 seconds after headers
        
        @debug "Starting response processing loop"
        
        while !response_complete && (time() - start_time) < timeout
            data_available = false
            
            # Check for available data
            if bytesavailable(socket) > 0
                try
                    # Read all available data
                    data = readavailable(socket)
                    @debug "Received $(length(data)) bytes of response data"
                    data_available = true
                    last_activity = time()
                    
                    # Process the data
                    events = receive_data!(conn, data)
                    @debug "Processed $(length(events)) events from response"
                    
                    # Handle events
                    for event in events
                        @debug "Processing event: $(typeof(event))"
                        
                        if event isa Events.ResponseReceived
                            @info "📨 Received response headers for stream $(event.stream_id)"
                            headers_received = true
                            
                            for (name, value) in event.headers
                                if name == ":status"
                                    response_status = value
                                    @info "Response status: $response_status"
                                else
                                    push!(response_headers, name => value)
                                end
                            end
                            
                            # Check if this is end of stream (headers only response)
                            if event.end_stream
                                @info "Response complete (headers only)"
                                response_complete = true
                                break
                            end
                            
                        elseif event isa Events.DataReceived
                            @info "📦 Received $(length(event.data)) bytes of data for stream $(event.stream_id)"
                            response_body *= String(event.data)
                            
                            # Check if this is the end of stream
                            if event.end_stream
                                @info "Response complete (with body)"
                                response_complete = true
                                break
                            end
                            
                        elseif event isa Events.StreamEnded
                            @info "🔚 Stream $(event.stream_id) ended"
                            response_complete = true
                            break
                            
                        elseif event isa Events.SettingsChanged
                            @debug "Settings changed during response"
                            
                        elseif event isa Events.StreamReset
                            @warn "Stream $(event.stream_id) was reset with error code $(event.error_code)"
                            response_complete = true
                            break
                            
                        elseif event isa Events.ConnectionTerminated
                            @warn "Connection terminated with error code $(event.error_code)"
                            response_complete = true
                            break
                            
                        elseif event isa Events.PingReceived
                            @debug "Received PING"
                            
                        elseif event isa Events.PingAck
                            @debug "Received PING ACK"
                            
                        else
                            @debug "Other event: $(typeof(event))"
                        end
                    end
                    
                    # Send any response data (like WINDOW_UPDATE frames)
                    outgoing_data = data_to_send(conn)
                    if !isempty(outgoing_data)
                        write(socket, outgoing_data)
                        @debug "Sent $(length(outgoing_data)) bytes of connection management data"
                    end
                    
                catch e
                    @warn "Error processing response data: $e"
                    break
                end
            else
                sleep(0.01)
            end
            
            # Check for completion conditions
            if !response_complete
                current_time = time()
                
                # If we have headers but no recent activity, consider complete
                if headers_received && (current_time - last_activity) > activity_timeout
                    @info "Assuming response complete (headers received, no recent activity)"
                    response_complete = true
                    break
                end
                
                # If no headers received and no recent activity, something is wrong
                if !headers_received && !data_available && (current_time - last_activity) > 5.0
                    @warn "No response headers received and no recent activity"
                    break
                end
            end
        end
        
        # Final timeout check
        if !response_complete && (time() - start_time) >= timeout
            @warn "Response timeout after $(time() - start_time) seconds"
            if headers_received
                @info "Partial success: received headers but may be missing body"
            else
                @warn "Complete failure: no headers received"
            end
        end
        
        # Response summary
        @info "📥 Response Summary:"
        @info "  Status: $response_status"
        @info "  Headers: $(length(response_headers))"
        @info "  Body length: $(length(response_body)) bytes"
        
        if !isempty(response_body)
            body_preview = response_body[1:min(100, length(response_body))]
            body_preview = replace(body_preview, r"\r?\n" => " ")
            @info "  Body preview: $body_preview"
        end
        
        # Determine success
        success = !isempty(response_status) || headers_received
        
        if success
            @info "✅ Request completed successfully"
        else
            @warn "❌ Request failed - no response received"
        end
        
        return (success, response_status, response_headers, response_body)
        
    catch e
        @error "❌ Request failed with exception: $e"
        @error "Stack trace:" exception=(e, catch_backtrace())
        return (false, "", Pair{String,String}[], "")
    finally
        if socket !== nothing
            try
                close(socket)
                @debug "Socket closed"
            catch e
                @debug "Error closing socket: $e"
            end
        end
    end
end

"""
    simple_get(host::String, port::Int; path::String="/")

Make a simple GET request and return success/failure.
"""
function simple_get(host::String, port::Int; path::String="/")
    success, status, headers, body = make_request(host, port, path=path)
    
    if success && !isempty(status)
        @info "✅ GET $path: $status"
        return true
    else
        @info "❌ GET $path: Failed"
        return false
    end
end

"""
    get_with_headers(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])

Make a GET request with custom headers and return success/failure.
"""
function get_with_headers(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])
    success, status, response_headers, body = make_request(host, port, path=path, headers=headers)
    
    if success && !isempty(status)
        @info "✅ GET $path (with headers): $status"
        return true
    else
        @info "❌ GET $path (with headers): Failed"
        return false
    end
end

"""
    get_full_response(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])

Make a GET request and return the full response details.
"""
function get_full_response(host::String, port::Int; path::String="/", headers::Vector{Pair{String,String}}=Pair{String,String}[])
    return make_request(host, port, path=path, headers=headers)
end

"""
    test_client()

Test the HTTP/2 client with a simple request.
"""
function test_client()
    @info "Testing HTTP/2 client..."
    
    host = "127.0.0.1"
    port = 8443
    
    success, status, headers, body = make_request(host, port, path="/simple")
    
    if success
        @info "✅ Test successful!"
        @info "Status: $status"
        @info "Response headers count: $(length(headers))"
        @info "Response body length: $(length(body))"
        return true
    else
        @info "❌ Test failed"
        return false
    end
end

"""
    debug_connection(host::String, port::Int; path::String="/")

Debug HTTP/2 connection with detailed logging.
"""
function debug_connection(host::String, port::Int; path::String="/")
    @info "🔍 Debug connection to https://$host:$port$path"
    
    # Enable debug logging
    old_logger = global_logger()
    debug_logger = ConsoleLogger(stdout, Logging.Debug)
    global_logger(debug_logger)
    
    try
        success, status, headers, body = make_request(host, port, path=path)
        
        @info "🔍 Debug Summary:"
        @info "  Success: $success"
        @info "  Status: '$status'"
        @info "  Headers count: $(length(headers))"
        @info "  Body length: $(length(body))"
        
        if !isempty(headers)
            @info "  Response headers:"
            for (name, value) in headers
                @info "    $name: $value"
            end
        end
        
        if !isempty(body)
            @info "  Response body: '$body'"
        end
        
        return success
    finally
        global_logger(old_logger)
    end
end

end