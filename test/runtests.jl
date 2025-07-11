using Test
using H2
using H2Frames
using HPACK
using Base64

const EXAMPLE_REQUEST_HEADERS = [":method" => "GET", ":path" => "/", ":authority" => "example.com", ":scheme" => "https"]
const EXAMPLE_RESPONSE_HEADERS = [":status" => "200", "content-type" => "text/html"]

function parse_frame(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    header = H2Frames.deserialize_frame_header(read(io, 9))
    payload = read(io)
    return H2Frames.create_frame(header, payload)
end

@testset "H2 Connection Core Logic" begin

    @testset "Client Initiates Connection" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        H2.initiate_connection!(client_conn)
        all_bytes = H2.data_to_send(client_conn)

        preface_len = length(H2.Connection.CONNECTION_PREFACE)
        @test all_bytes[1:preface_len] == Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)

        settings_bytes = all_bytes[preface_len+1:end]
        settings_frame = parse_frame(settings_bytes)
        @test settings_frame isa H2Frames.FrameSettings.SettingsFrame
    end

    @testset "Client Sends Request" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        H2.send_headers(client_conn, UInt32(1), EXAMPLE_REQUEST_HEADERS, end_stream=true)
        request_bytes = H2.data_to_send(client_conn)
        
        frame = parse_frame(request_bytes)
        @test frame isa H2Frames.Headers.HeadersFrame
        @test frame.stream_id == UInt32(1)
        @test frame.end_stream == true
    end

    @testset "Server Receives Realistic Request" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        server_config = H2.H2Config(client_side=false)

        server_conn = H2.H2Connection(config=server_config)
        H2.initiate_connection!(client_conn)
        H2.send_headers(client_conn, UInt32(1), EXAMPLE_REQUEST_HEADERS, end_stream=true)
        all_bytes_from_client = H2.data_to_send(client_conn)

        events = H2.receive_data!(server_conn, all_bytes_from_client)
        
        @test length(events) == 3
        @test events[1] isa H2.Events.SettingsChanged
        @test events[2] isa H2.Events.RequestReceived
        @test events[3] isa H2.Events.StreamEnded
    end
    
    @testset "Server Responds Correctly" begin
        server_config = H2.H2Config(client_side=false)
        server_conn = H2.H2Connection(config=server_config)
        response_body = "Hello from Julia!"
        
        H2.send_headers(server_conn, UInt32(1), EXAMPLE_RESPONSE_HEADERS)
        H2.send_data(server_conn, UInt32(1), Vector{UInt8}(response_body), end_stream=true)
        response_bytes = H2.data_to_send(server_conn)
        
        io = IOBuffer(response_bytes)
        headers_frame = parse_frame(read(io, 9 + H2Frames.deserialize_frame_header(view(response_bytes, 1:9)).length))
        @test headers_frame isa H2Frames.Headers.HeadersFrame
        
        data_frame = parse_frame(read(io))
        @test data_frame isa H2Frames.FrameData.DataFrame
        @test data_frame.end_stream == true
    end

end

@testset "Server Processes Settings" begin
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)

    raw_client_settings = Dict{UInt16, UInt32}(
        UInt16(H2Frames.SETTINGS_MAX_CONCURRENT_STREAMS) => UInt32(200),
        UInt16(H2Frames.SETTINGS_INITIAL_WINDOW_SIZE) => UInt32(100000)
    )
    
    settings_frame = H2Frames.SettingsFrame(raw_client_settings)
    settings_bytes = H2Frames.serialize_frame(settings_frame)

    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    H2.receive_data!(server_conn, preface)
    events = H2.receive_data!(server_conn, settings_bytes)

    @test length(events) == 1
    @test events[1] isa H2.Events.SettingsChanged
    
    expected_event_settings = Dict(
        :SETTINGS_MAX_CONCURRENT_STREAMS => UInt32(200),
        :SETTINGS_INITIAL_WINDOW_SIZE => UInt32(100000)
    )
    @test events[1].changed_settings == expected_event_settings
    
    @test server_conn.remote_settings[H2Frames.SETTINGS_MAX_CONCURRENT_STREAMS] == UInt32(200)
    @test server_conn.remote_settings[H2Frames.SETTINGS_INITIAL_WINDOW_SIZE] == UInt32(100000)

    ack_bytes = H2.data_to_send(server_conn)
    @test !isempty(ack_bytes)
    
    ack_header = H2Frames.deserialize_frame_header(view(ack_bytes, 1:9))
    ack_payload = ack_bytes[10:end]
    ack_frame = H2Frames.create_frame(ack_header, ack_payload)
    
    @test ack_frame isa H2Frames.SettingsFrame
    @test H2Frames.is_ack(ack_frame)
end

@testset "Server Processes Request with Body" begin
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)

    # Send the connection preface first!
    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    H2.receive_data!(server_conn, preface)

    headers_frame = H2Frames.create_headers_frame(
        1,
        EXAMPLE_REQUEST_HEADERS, # Χρησιμοποιούμε τα headers από το προηγούμενο τεστ
        server_conn.hpack_encoder, # Χρειαζόμαστε τον encoder
        end_stream=false # ΣΗΜΑΝΤΙΚΟ!
    )
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(headers_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.RequestReceived

    body_chunk_1 = "Hello, "
    data_frame_1 = H2Frames.create_data_frame(1, Vector{UInt8}(body_chunk_1))[1]
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(data_frame_1))

    @test length(events) == 1
    @test events[1] isa H2.Events.DataReceived
    @test events[1].stream_id == 1
    @test events[1].data == Vector{UInt8}(body_chunk_1)

    body_chunk_2 = "World!"
    data_frame_2 = H2Frames.create_data_frame(1, Vector{UInt8}(body_chunk_2), end_stream=true)[1]
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(data_frame_2))
    
    @test length(events) == 2
    @test events[1] isa H2.Events.DataReceived
    @test events[1].data == Vector{UInt8}(body_chunk_2)
    @test events[2] isa H2.Events.StreamEnded
    @test events[2].stream_id == 1
end

@testset "Flow Control and Window Updates" begin
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)
    DEFAULT_WINDOW = 65535

    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    H2.receive_data!(server_conn, preface)
    headers_frame = H2Frames.create_headers_frame(1, EXAMPLE_REQUEST_HEADERS, server_conn.hpack_encoder)
    H2.receive_data!(server_conn, H2Frames.serialize_frame(headers_frame))
    data_frame = H2Frames.create_data_frame(1, zeros(UInt8, 100))[1]
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(data_frame))

    stream = server_conn.streams[1]
    
    @test stream.inbound_window_manager.current_window_size == DEFAULT_WINDOW - 100

    chunk_size_to_trigger_update = floor(Int, DEFAULT_WINDOW * 0.51)
    H2.acknowledge_received_data!(server_conn, UInt32(1), UInt32(chunk_size_to_trigger_update))

    update_bytes = H2.data_to_send(server_conn)
    @test !isempty(update_bytes)

    # ---> ΔΙΟΡΘΩΣΗ 3: Χωρίζουμε τα bytes στα δύο frames που περιμένουμε (ένα για το stream, ένα για τη σύνδεση)
    header1 = H2Frames.deserialize_frame_header(view(update_bytes, 1:9))
    len1 = 9 + header1.length
    frame1_bytes = update_bytes[1:len1]
    frame2_bytes = update_bytes[len1+1:end]

    update_frame_1 = parse_frame(frame1_bytes)
    update_frame_2 = parse_frame(frame2_bytes)
    
    # Βρίσκουμε ποιο είναι για το stream και ποιο για τη σύνδεση
    stream_update = H2Frames.stream_id(update_frame_1) == 1 ? update_frame_1 : update_frame_2
    conn_update = H2Frames.stream_id(update_frame_1) == 0 ? update_frame_1 : update_frame_2

    @test stream_update isa H2Frames.WindowUpdateFrame
    @test H2Frames.stream_id(stream_update) == 1
    @test stream_update.window_size_increment == chunk_size_to_trigger_update
    
    @test conn_update isa H2Frames.WindowUpdateFrame
    @test H2Frames.stream_id(conn_update) == 0
    @test conn_update.window_size_increment == chunk_size_to_trigger_update
end


@testset "Server Handles Other Events" begin
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)
    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    H2.receive_data!(server_conn, preface)

    # Priority Frame
    priority_frame = H2Frames.PriorityFrame(1, false, 0, 16)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(priority_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.PriorityChanged
    @test events[1].stream_id == 1

    # RST_STREAM Frame
    rst_frame = H2Frames.RstStreamFrame(UInt32(1), 0x2) # INTERNAL_ERROR
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(rst_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.StreamReset
    @test events[1].stream_id == 1
    @test events[1].error_code == 0x2

    # GOAWAY Frame
    goaway_frame = H2Frames.GoAwayFrame(1, 0x0, Vector{UInt8}())
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(goaway_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.ConnectionTerminated
    @test events[1].last_stream_id == 1
    @test events[1].error_code == 0x0

    # PING Frame
    ping_data = fill(UInt8(0xAB), 8)
    ping_frame = H2Frames.PingFrame(ping_data)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(ping_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.PingReceived
    @test events[1].data == ping_data

    # PING ACK Frame
    ping_ack_frame = H2Frames.PingAckFrame(ping_frame)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(ping_ack_frame))
    @test length(events) == 1
    @test events[1] isa H2.Events.PingAck
    @test events[1].data == ping_data
end


@testset "Priority Handling" begin
    @testset "prioritize! function creates correct frame" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        # Δημιουργούμε ένα stream για να υπάρχει το ID 1
        H2.send_headers(client_conn, UInt32(1), EXAMPLE_REQUEST_HEADERS)
        H2.data_to_send(client_conn) # Καθαρίζουμε τον buffer

        H2.prioritize!(client_conn, UInt32(1); weight=200, depends_on=UInt32(0), exclusive=true)
        
        priority_bytes = H2.data_to_send(client_conn)
        @test !isempty(priority_bytes)
        
        frame = parse_frame(priority_bytes)
        @test frame isa H2Frames.PriorityFrame
        @test frame.stream_id == 1
        
        @test frame.exclusive == true
        @test frame.stream_dependency == 0
        @test frame.weight == 199 
    end

    @testset "send_headers with priority info" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        
        H2.send_headers(client_conn, UInt32(3), EXAMPLE_REQUEST_HEADERS;
                        priority_weight=128, priority_depends_on=UInt32(1), priority_exclusive=false)
        
        headers_bytes = H2.data_to_send(client_conn)
        @test !isempty(headers_bytes)

        frame = parse_frame(headers_bytes)
        @test frame isa H2Frames.Headers.HeadersFrame
        
        @test frame.priority == true
        @test frame.priority_info isa H2Frames.Headers.PriorityInfo
        
        @test frame.stream_id == 3
        
        @test frame.priority_info.exclusive == false
        @test frame.priority_info.stream_dependency == 1
        @test H2Frames.priority_weight(frame.priority_info) == 128

    end

    @testset "Error Handling for Priority" begin
        config = H2.H2Config(client_side=true)
        client_conn = H2.H2Connection(config=config)
        H2.send_headers(client_conn, UInt32(1), EXAMPLE_REQUEST_HEADERS)
        
        @test_throws ArgumentError H2.prioritize!(client_conn, UInt32(1); weight=0)
        @test_throws ArgumentError H2.prioritize!(client_conn, UInt32(1); weight=300)
        
        @test_throws H2.H2Exceptions.ProtocolError H2.prioritize!(client_conn, UInt32(1); depends_on=UInt32(1))
        
        @test_throws H2.H2Exceptions.ProtocolError H2.send_headers(client_conn, UInt32(5), EXAMPLE_REQUEST_HEADERS; priority_depends_on=UInt32(5))
    end
end

@testset "Informational Responses (1xx)" begin
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)
    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    H2.receive_data!(server_conn, preface)

    headers_103 = [":status" => "103", "link" => "</style.css>; rel=preload; as=style"]
    headers_frame_103 = H2Frames.create_headers_frame(1, headers_103, server_conn.hpack_encoder, end_stream=false)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(headers_frame_103))
    @test length(events) == 1
    @test events[1] isa H2.Events.InformationalResponseReceived
    @test events[1].stream_id == 1
    @test events[1].headers == headers_103

    headers_100 = [":status" => "100"]
    headers_frame_100 = H2Frames.create_headers_frame(1, headers_100, server_conn.hpack_encoder, end_stream=false)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(headers_frame_100))
    @test length(events) == 1
    @test events[1] isa H2.Events.InformationalResponseReceived
    @test events[1].stream_id == 1
    @test events[1].headers == headers_100

    headers_200 = [":status" => "200"]
    headers_frame_200 = H2Frames.create_headers_frame(1, headers_200, server_conn.hpack_encoder, end_stream=true)
    events = H2.receive_data!(server_conn, H2Frames.serialize_frame(headers_frame_200))
    @test any(e -> e isa H2.Events.ResponseReceived, events) || any(e -> e isa H2.Events.StreamEnded, events)
end

@testset "HTTP/1.1 h2c Upgrade" begin
    # Simulate an HTTP/1.1 Upgrade request with HTTP2-Settings
    server_config = H2.H2Config(client_side=false)
    server_conn = H2.H2Connection(config=server_config)

    # HTTP2-Settings: base64url encoding of SETTINGS_MAX_CONCURRENT_STREAMS=50
    settings_dict = Dict{UInt16, UInt32}(UInt16(H2Frames.SETTINGS_MAX_CONCURRENT_STREAMS) => UInt32(50))
    settings_frame = H2Frames.SettingsFrame(settings_dict)
    settings_bytes = H2Frames.serialize_frame(settings_frame)
    http2_settings_b64 = Base64.base64encode(settings_bytes)

    # Compose HTTP/1.1 Upgrade request
    upgrade_request = join([
        "GET / HTTP/1.1",
        "Host: example.com",
        "Connection: Upgrade, HTTP2-Settings",
        "Upgrade: h2c",
        "HTTP2-Settings: $http2_settings_b64",
        "\r\n"
    ], "\r\n")
    upgrade_bytes = Vector{UInt8}(upgrade_request)

    # Server receives the upgrade request
    events = H2.receive_data!(server_conn, upgrade_bytes)
    @test any(e -> e isa H2.Events.H2CUpgradeReceived, events)
    # Server should send a 101 Switching Protocols response
    response_bytes = H2.data_to_send(server_conn)
    response_str = String(response_bytes)
    @test occursin("101 Switching Protocols", response_str)
    @test occursin("Upgrade: h2c", response_str)

    # After upgrade, server should process the HTTP2-Settings
    # Simulate client sending connection preface
    preface = Vector{UInt8}(H2.Connection.CONNECTION_PREFACE)
    events = H2.receive_data!(server_conn, preface)
    # The server's remote_settings should be updated
    @test server_conn.remote_settings[H2Frames.SETTINGS_MAX_CONCURRENT_STREAMS] == UInt32(50)

    # Example code for h2c upgrade handling:
    # if event isa H2.Events.H2CUpgradeReceived
    #     @info "HTTP/1.1 h2c upgrade received, switching protocols"
    # end
end