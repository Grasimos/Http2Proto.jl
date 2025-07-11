# H2.jl

A comprehensive HTTP/2 protocol implementation for Julia, providing both client and server functionality with full support for HTTP/2 features including multiplexing, flow control, header compression, and connection management.

## Features

- **Full HTTP/2 Protocol Support**: Complete implementation of RFC 7540
- **Client and Server Modes**: Configurable for both client-side and server-side operations
- **Stream Management**: Full support for HTTP/2 multiplexed streams
- **Header Compression**: HPACK (HTTP/2 Header Compression) support via integrated HPACK.jl
- **Flow Control**: Automatic window management and flow control mechanisms
- **Priority Handling**: Stream priority and dependency management
- **Informational Responses**: Support for 1xx status codes (100 Continue, 103 Early Hints)
- **HTTP/1.1 Upgrade**: h2c (HTTP/2 over cleartext) upgrade support
- **Event-Driven Architecture**: Comprehensive event system for connection lifecycle management

## Installation

```julia
using Pkg
Pkg.add("H2")
```

## Dependencies

- `H2Frames.jl` - HTTP/2 frame serialization and deserialization
- `HPACK.jl` - Header compression implementation
- `Base64.jl` - Base64 encoding for HTTP/2 settings

## Quick Start

### Client Usage

```julia
using H2

# Create a client connection
config = H2.H2Config(client_side=true)
client_conn = H2.H2Connection(config=config)

# Initiate the connection
H2.initiate_connection!(client_conn)

# Send a request
headers = [":method" => "GET", ":path" => "/", ":authority" => "example.com", ":scheme" => "https"]
H2.send_headers(client_conn, UInt32(1), headers, end_stream=true)

# Get data to send over the network
data_to_send = H2.data_to_send(client_conn)
```

### Server Usage

```julia
using H2

# Create a server connection
config = H2.H2Config(client_side=false)
server_conn = H2.H2Connection(config=config)

# Process incoming data
events = H2.receive_data!(server_conn, incoming_bytes)

# Handle events
for event in events
    if event isa H2.Events.RequestReceived
        # Process the request
        response_headers = [":status" => "200", "content-type" => "text/html"]
        H2.send_headers(server_conn, event.stream_id, response_headers)
        H2.send_data(server_conn, event.stream_id, Vector{UInt8}("Hello, World!"), end_stream=true)
    end
end

# Get response data to send
response_data = H2.data_to_send(server_conn)
```

## Core Components

### H2Connection

The main connection object that manages HTTP/2 state:

```julia
config = H2.H2Config(client_side=true)  # or false for server
conn = H2.H2Connection(config=config)
```

### Configuration Options

- `client_side`: Boolean indicating client (true) or server (false) mode
- Various HTTP/2 settings can be configured through the connection

### Event System

H2.jl uses an event-driven architecture. Key events include:

- `H2.Events.RequestReceived` - New request received
- `H2.Events.ResponseReceived` - Response received
- `H2.Events.DataReceived` - Data frame received
- `H2.Events.StreamEnded` - Stream completed
- `H2.Events.SettingsChanged` - Settings frame processed
- `H2.Events.PriorityChanged` - Priority frame received
- `H2.Events.StreamReset` - Stream reset
- `H2.Events.ConnectionTerminated` - Connection closed
- `H2.Events.PingReceived` - Ping frame received
- `H2.Events.PingAck` - Ping acknowledgment received
- `H2.Events.InformationalResponseReceived` - 1xx response received
- `H2.Events.H2CUpgradeReceived` - HTTP/1.1 to HTTP/2 upgrade

## Advanced Features

### Stream Priority

```julia
# Set stream priority
H2.prioritize!(conn, stream_id; weight=128, depends_on=parent_stream_id, exclusive=false)

# Send headers with priority information
H2.send_headers(conn, stream_id, headers; 
                priority_weight=128, 
                priority_depends_on=parent_stream_id, 
                priority_exclusive=false)
```

### Flow Control

```julia
# Acknowledge received data to update flow control windows
H2.acknowledge_received_data!(conn, stream_id, bytes_consumed)
```

### Informational Responses

```julia
# Send 1xx responses (server-side)
informational_headers = [":status" => "103", "link" => "</style.css>; rel=preload; as=style"]
H2.send_headers(conn, stream_id, informational_headers, end_stream=false)

# Send final response
final_headers = [":status" => "200", "content-type" => "text/html"]
H2.send_headers(conn, stream_id, final_headers, end_stream=true)
```

### HTTP/1.1 to HTTP/2 Upgrade (h2c)

```julia
# Server handles HTTP/1.1 upgrade requests automatically
# Client can initiate upgrade by sending appropriate HTTP/1.1 headers
```

## Error Handling

The library provides comprehensive error handling:

- `H2.H2Exceptions.ProtocolError` - Protocol violations
- `ArgumentError` - Invalid parameters (e.g., invalid priority weights)

## Flow Control Details

H2.jl implements automatic flow control management:

- **Window Management**: Automatic tracking of connection and stream-level flow control windows
- **Window Updates**: Automatic generation of WINDOW_UPDATE frames when appropriate
- **Backpressure**: Proper handling of flow control constraints

## Testing

The library includes comprehensive tests covering:

- Connection establishment and teardown
- Request/response cycles
- Stream multiplexing
- Flow control mechanisms
- Priority handling
- Error conditions
- HTTP/1.1 upgrade scenarios

Run tests with:

```julia
using Pkg
Pkg.test("H2")
```

## Protocol Compliance

H2.jl aims for full RFC 7540 compliance, including:

- Connection preface handling
- Frame format compliance
- HPACK header compression
- Stream state management
- Flow control algorithms
- Error handling and recovery

## Performance Considerations

- Efficient frame parsing and serialization
- Minimal memory allocations during normal operation
- Proper resource cleanup and stream lifecycle management
- Optimized HPACK compression/decompression

## Contributing

Contributions are welcome! Please read our contributing guidelines and submit pull requests for any improvements.

## License

MIT License - see LICENSE file for details.

## Status

**Development Status**: Experimental

This implementation is under active development. While it implements the core HTTP/2 specification, it should be thoroughly tested before production use. We welcome feedback and contributions to help stabilize and optimize the implementation.

---

*H2.jl - Bringing modern HTTP/2 capabilities to the Julia ecosystem*