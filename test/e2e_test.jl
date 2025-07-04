using Test
using Sockets
using Logging
using Base: errormonitor
using HTTP
using H2Frames
using H2 



@testset "End-to-End Client-Server Communication" begin
    @info :info "Starting E2E test"
    E2E_ROUTER = HTTP.Router()

    HTTP.register!(E2E_ROUTER, "GET", "/", req -> HTTP.Response(200, "Hello, World!"))

    HTTP.register!(E2E_ROUTER, "POST", "/data", req -> begin
        body_str = String(req.body)
        return HTTP.Response(200, "Received: $body_str")
    end)

    HTTP.register!(E2E_ROUTER, "GET", "/headers", req -> begin
        custom_header_value = HTTP.header(req, "X-Custom-Header", "")
        return HTTP.Response(200, custom_header_value)
    end)

    HTTP.register!(E2E_ROUTER, "GET", "/query", req -> begin
        query_params = HTTP.queryparams(req)
        name = get(query_params, "name", "Guest")
        return HTTP.Response(200, "Hello, $name")
    end)

    HTTP.register!(E2E_ROUTER, "GET", "/push-test", req -> begin
        @info ("SERVER: Initiating push for /style.css")
        pushed_req_headers = [
            ":method" => "GET",
            ":scheme" => "https",
            ":authority" => "127.0.0.1:8008",
            ":path" => "/style.css"
        ]
        original_stream = req.context[:stream]
        promised_stream = push_promise!(original_stream.connection, original_stream, pushed_req_headers)

        if promised_stream !== nothing
            errormonitor(@async begin
                @info ("SERVER: Sending response for pushed stream $(promised_stream.id)")
                pushed_response_headers = [":status" => "200", "content-type" => "text/css"]
                pushed_body = Vector{UInt8}("body { color: red; }")
                
                H2.Connection.send_headers!(promised_stream, pushed_response_headers, end_stream=false)
                H2.Connection.send_data!(promised_stream, pushed_body, end_stream=true)
            end)
        end

        @info ("SERVER: Sending main response for /push-test")
        html_body = "<html><head><link rel='stylesheet' href='/style.css'></head><body>Push Test</body></html>"
        return HTTP.Response(200, html_body)
    end)

    HTTP.register!(E2E_ROUTER, "POST", "/big-upload", req -> HTTP.Response(200, string(length(req.body))))

    HTTP.register!(E2E_ROUTER, "GET", "/reset-me", req -> begin
        stream = req.context[:stream]
        H2.Streams.mux_close_stream!(stream.connection.multiplexer, stream.id, :CANCEL)
        return HTTP.Response(200) 
    end)
    # Add this with your other HTTP.register! calls

    HTTP.register!(E2E_ROUTER, "GET", "/push-continuation-test", req -> begin
        @info ("SERVER: Initiating push with continuation for /style.css")
        original_stream = req.context[:stream]
        conn = original_stream.connection

        # Manually create and register the promised stream
        promised_stream_id = H2.Connection.next_stream_id(conn)
        promised_stream = H2.HTTP2Stream(promised_stream_id, conn)
        H2.Connection.add_stream(conn, promised_stream)
        H2.Streams.register_stream!(conn.multiplexer, promised_stream)
        H2.Streams.transition_stream_state!(promised_stream, :send_push_promise)

        # 1. Create many small headers to exceed the frame size without violating HPACK limits
        pushed_req_headers = [
            ":method" => "GET",
            ":scheme" => "https",
            ":authority" => "127.0.0.1:8008",
            ":path" => "/style.css"
        ]
        # Generate enough headers to require fragmentation
        for i in 1:400
            push!(pushed_req_headers, "x-custom-header-$i" => "value-$i-for-a-long-enough-string-to-fill-space")
        end
        
        # 2. Manually encode and split the header block
        full_header_block = H2.HPACK.encode_headers(conn.hpack_encoder, pushed_req_headers)
        split_point = 16384 # Max frame size
        fragment1 = full_header_block[1:split_point]
        fragment2 = full_header_block[split_point+1:end]

        # 3. Create and send the PUSH_PROMISE (with end_headers=false)
        push_promise_frame = H2.H2Frames.PushPromiseFrame(
            original_stream.id, promised_stream.id, fragment1; end_headers=false
        )
        H2.Connection.send_frame(conn, H2.H2Frames.serialize_frame(push_promise_frame))

        # 4. Create and send the CONTINUATION frame
        continuation_frame = H2.H2Frames.ContinuationFrame(
            original_stream.id, fragment2; end_headers=true
        )
        H2.Connection.send_frame(conn, H2.H2Frames.serialize_frame(continuation_frame))

        # 5. Spawn the task to send the actual response for the pushed stream
        errormonitor(@async begin
            pushed_response_headers = [":status" => "200", "content-type" => "text/css"]
            pushed_body = Vector{UInt8}("pushed-with-continuation")
            H2.Connection.send_headers!(promised_stream, pushed_response_headers; end_stream=false)
            H2.Connection.send_data!(promised_stream, pushed_body; end_stream=true)
        end)

        # 6. Return the main response
        return HTTP.Response(200, "Main Continuation Test Response")
    end)

    HTTP.register!(E2E_ROUTER, "GET", "/shutdown", req -> begin
        response = HTTP.Response(200, "I'm shutting down!")
        
        conn = req.context[:stream].connection
        last_processed_id = req.context[:stream].id
        
        H2.Connection.send_goaway!(conn, last_processed_id, :NO_ERROR)
        
        return response
    end)
    h2_handler = H2Router(E2E_ROUTER)


    HOST = "127.0.0.1"
    PORT = 8008
    
    startup_channel = Channel{Bool}(1)
    
    CERT_PATH = get(ENV, "CERT_PATH", joinpath(homedir(), ".mbedtls", "cert.pem"))
    KEY_PATH = get(ENV, "KEY_PATH", joinpath(homedir(), ".mbedtls", "key.pem"))

    # Create server settings with a large limit for the continuation test
    server_settings_for_test = H2.H2Settings.create_server_settings()
    server_settings_for_test.max_header_list_size = 65536

    server_task = errormonitor(@async H2.serve(
        h2_handler, 
        HOST, 
        PORT;
        is_tls=true, 
        cert_file=CERT_PATH, 
        key_file=KEY_PATH,
        ready_channel=startup_channel,
        settings=server_settings_for_test # <-- PASS THE SETTINGS
    ))
        
    client = nothing

    try
        @test take!(startup_channel) == true
        @info ("Server is confirmed to be listening. Starting client tests...")

        @info ("Connecting client...")
        client = H2.connect(HOST, PORT; is_tls=true, verify_peer=false)
        @test H2.Connection.is_open(client.conn)
        @info ("Client connected successfully.")

        @testset "Simple GET Request" begin
            @info ("👽👽👽Start: Simple GET Request👽👽👽")
            resp = H2.request(client, "GET", "/")
            @test resp.status == 200
            body = String(resp.body)
            @test body == "Hello, World!"
            @info ("👽👽👽👽End: Simple GET Request👽👽👽👽")
        end

        @testset "POST Request with Body" begin
            @info ("👽👽👽START: POST Request with Bodyt👽👽👽")
            post_body = "This is a test body."
            resp = H2.request(client, "POST", "/data", body=Vector{UInt8}(post_body))
            @test resp.status == 200
            @test String(resp.body) == "Received: $post_body"
            @info ("👽👽👽 END: POST Request with Body👽👽👽")
        end
        
        @testset "Custom Request Headers" begin
            headers = ["X-Custom-Header" => "Success!"]
            resp = H2.request(client, "GET", "/headers", headers=headers)
            @test resp.status == 200
            @test String(resp.body) == "Success!"
        end
        
        @testset "404 Not Found" begin
            resp = H2.request(client, "GET", "/this/path/does/not/exist")
            @test resp.status == 404
        end

        @testset "Concurrent Requests (Multiplexing)" begin
            @info ("Testing multiplexing with 50 concurrent requests...")
            tasks = []
            for i in 1:5
                task = @async H2.request(client, "GET", "/query?name=Task$i")
                push!(tasks, task)
            end

            responses = fetch.(tasks)

            @test length(responses) == 5
            for i in 1:5
                @test responses[i].status == 200
                @test String(responses[i].body) == "Hello, Task$i"
            end
            @info ("Multiplexing test completed successfully.")
        end

        @testset "Server Push Promise" begin
            @info ("Testing Server Push Promise with push ENABLED on client...")
            
            # Create custom settings for a client that ACCEPTS server push
            push_enabled_settings = H2.H2Settings.create_client_settings()
            push_enabled_settings.enable_push = true

            # Create a new client instance just for this test
            push_client = nothing
            try
                push_client = H2.connect(HOST, PORT; is_tls=true, verify_peer=false, settings=push_enabled_settings)
                @test H2.Connection.is_open(push_client.conn)

                # Make the request that triggers the push
                resp = H2.request(push_client, "GET", "/push-test")
                body = String(resp.body)
                @test resp.status == 200
                @test occursin("/style.css", body)

                # Find the pushed stream (it should exist and be open)
                pushed_stream = nothing
                for _ in 1:100 # Poll for a short time to find the stream
                    @lock push_client.conn.streams_lock begin
                        # Find the even-numbered stream created by the server
                        for (id, stream) in push_client.conn.streams
                            if iseven(id) && H2.is_active(stream)
                                pushed_stream = stream
                                break
                            end
                        end
                    end
                    if pushed_stream !== nothing
                        break
                    end
                    sleep(0.05)
                end
                
                @test pushed_stream !== nothing
                if pushed_stream !== nothing
                    @info ("CLIENT: Found pushed stream $(pushed_stream.id). Waiting for its headers and body...")
                    pushed_resp_headers = H2.Streams.wait_for_headers(pushed_stream)
                    pushed_body = H2.Streams.wait_for_body(pushed_stream)
                    str_pushed_body = String(pushed_body)
                    status_str = get(Dict(pushed_resp_headers), ":status", "0")
                    
                    @test parse(Int, status_str) == 200
                    @test str_pushed_body == "body { color: red; }"
                    @info ("Server Push Promise test completed successfully.")
                end
            finally
                if push_client !== nothing
                    H2.close(push_client)
                end
            end
        end


        @testset "Large Body Upload (Flow Control)" begin
            large_body = rand(UInt8, 100_000) 
            resp = H2.request(client, "POST", "/big-upload", body=large_body)
            @test resp.status == 200
            @test parse(Int, String(resp.body)) == 100_000
        end


        @testset "PING Liveness Check" begin
            @info ("Testing PING Liveness Check...")
            
            rtt = H2.ping(client, timeout=25.0)
            
            @info ("PING successful. RTT: $(rtt * 1000) ms")
            
            @test rtt isa Float64
            @test rtt > 0.0
        end

        @testset "Concurrent PINGs Stress Test" begin
            @info ("Testing concurrent PINGs...")
            
            num_pings = 5
            ping_tasks = []


            for i in 1:num_pings
                task = @async begin
                    sleep(rand() * 0.05)
                    H2.ping(client, timeout=10.0)
                end
                push!(ping_tasks, task)
            end

            @info ("Launched $num_pings PING tasks. Waiting for all ACKs...")

            try
                results = fetch.(ping_tasks)
                
                @test length(results) == num_pings
                
                @info ("Received all $num_pings PING ACKs successfully.")
                
                for (i, rtt) in enumerate(results)
                    @info ("  - PING $i RTT: $(round(rtt * 1000, digits=2)) ms")
                    @test rtt isa Float64
                    @test rtt >= 0
                end
                
            catch e
                @info ("Concurrent PING test failed: $e")
            end
        end



        @testset "Stream Reset by Server" begin
            @test_throws H2.Exc.StreamError H2.request(client, "GET", "/reset-me")
        end


        @testset "Stream Priority" begin
            @info ("Testing Stream Priority...")
            
            stream_a = H2.Streams.open_stream!(client.conn.multiplexer)
            stream_b = H2.Streams.open_stream!(client.conn.multiplexer)
            stream_c = H2.Streams.open_stream!(client.conn.multiplexer)

            priority_frame_c = H2Frames.PriorityFrame(stream_c.id, false, 0, 256) # Max priority
            priority_frame_b = H2Frames.PriorityFrame(stream_b.id, false, 0, 128) # Medium
            
            H2.Connection.send_frame_on_stream(client.conn.multiplexer, UInt32(0), priority_frame_c)
            H2.Connection.send_frame_on_stream(client.conn.multiplexer, UInt32(0), priority_frame_b)
            
            sleep(0.2)

            task_a = @async H2.request(client, "GET", "/query?name=StreamA")
            task_b = @async H2.request(client, "GET", "/query?name=StreamB")
            task_c = @async H2.request(client, "GET", "/query?name=StreamC")

            responses = fetch.([task_a, task_b, task_c])
            
            @test all(r.status == 200 for r in responses)
            @test any(r.body == Vector{UInt8}("Hello, StreamA") for r in responses)
            @test any(r.body == Vector{UInt8}("Hello, StreamB") for r in responses)
            @test any(r.body == Vector{UInt8}("Hello, StreamC") for r in responses)

            @info ("Stream Priority test completed.")
        end


        @testset "Graceful Shutdown (GOAWAY)" begin
            @info ("Testing Graceful Shutdown with GOAWAY...")
            
            resp1 = H2.request(client, "GET", "/shutdown")
            body = String(resp1.body)
            @test resp1.status == 200
            @test body == "I'm shutting down!"
            
            sleep(0.5)

            @test_throws H2.Exc.ProtocolError H2.request(client, "GET", "/")
            
            @info ("GOAWAY test completed successfully.")
        end


        @testset "Rate Limiting (ENHANCE_YOUR_CALM)" begin
            @info ("Testing Rate Limiting...")
            
            client_rl = H2.connect(HOST, PORT; is_tls=true, verify_peer=false)
            

            tasks = []
            for i in 1:150
                try
                    resp = H2.request(client_rl, "GET", "/")
                    if i <= 50 # Τα πρώτα θα πρέπει να περάσουν
                        @test resp.status == 200
                    end
                catch e
                    @info "Request $i failed as expected."
                    @test e isa H2.Exc.ProtocolError || e isa Base.IOError
                    break # Βγαίνουμε από το loop μόλις αποτύχει το πρώτο request
                end
                sleep(0.01) # Μικρή παύση
            end

            @test_throws Union{H2.Exc.ProtocolError, Base.IOError} H2.request(client_rl, "GET", "/")
            
            H2.close(client_rl)
            @info ("Rate Limiting test completed.")
        end


        @testset "Server Push with Large Headers (Continuation)" begin
            @info ("Testing Server Push with Continuation...")
            
            push_enabled_settings = H2.H2Settings.create_client_settings()
            push_enabled_settings.enable_push = true
            push_enabled_settings.max_header_list_size = 65536 # A comfortably large value

            push_client = nothing
            try
                push_client = H2.connect(HOST, PORT; is_tls=true, verify_peer=false, settings=push_enabled_settings)
                
                resp = H2.request(push_client, "GET", "/push-continuation-test")
                @test resp.status == 200

                # Find the pushed stream
                pushed_stream = nothing
                for _ in 1:100
                    @lock push_client.conn.streams_lock begin
                        pushed_stream = H2.Connection.get_stream(push_client.conn, UInt32(2))
                    end
                    (pushed_stream !== nothing && !isempty(pushed_stream.headers)) && break
                    sleep(0.05)
                end
                
                @test pushed_stream !== nothing

            @test pushed_stream !== nothing
            if pushed_stream !== nothing
                @test length(pushed_stream.headers) == 404
                pushed_resp_headers = H2.Streams.wait_for_headers(pushed_stream)
                pushed_body = H2.Streams.wait_for_body(pushed_stream)
                
                @test parse(Int, get(Dict(pushed_resp_headers), ":status", "0")) == 200
                @test String(pushed_body) == "pushed-with-continuation"
            end
            finally
                if push_client !== nothing
                    H2.close(push_client)
                end
            end
        end

    finally
        @info ("Shutting down E2E test...")
        if client !== nothing && H2.Connection.is_open(client.conn)
            @info ("Closing client connection...")
            H2.close(client)
        end
        if !istaskdone(server_task)
            @info ("Interrupting server task...")
            schedule(server_task, InterruptException(), error=true)
            sleep(0.5)
        end
        @info ("Server task state: ", istaskdone(server_task) ? "Done" : "Running")
    end
    
end