# Http2Proto.jl

A comprehensive HTTP/2 protocol implementation for Julia, providing both client and server functionality with full support for HTTP/2 features including multiplexing, flow control, header compression, and connection management.

## Features

- **Full HTTP/2 Protocol Support**: Complete implementation of RFC 7540
- **Client and Server Modes**: Configurable for both client-side and server-side operations
- **Stream Management**: Full support for HTTP/2 multiplexed streams
- **Header Compression**: HPACK (HTTP/2 Header Compression) support via integrated Http2Hpack.jl
- **Flow Control**: Automatic window management and flow control mechanisms
- **Priority Handling**: Stream priority and dependency management
- **Informational Responses**: Support for 1xx status codes (100 Continue, 103 Early Hints)
- **HTTP/1.1 Upgrade**: h2c (HTTP/2 over cleartext) upgrade support
- **Event-Driven Architecture**: Comprehensive event system for connection lifecycle management

## Installation

```julia
using Pkg
Pkg.add("Http2Proto")
```

## Dependencies

- `Http2Frames.jl` - HTTP/2 frame serialization and deserialization
- `Http2Hpack.jl` - Header compression implementation
- `Base64.jl` - Base64 encoding for HTTP/2 settings

## Quick Start

### Server Usage

```bash
# Create the directory
mkdir -p ~/.mbedtls

# Generate a self-signed certificate (for testing)
openssl req -x509 -newkey rsa:4096 -keyout ~/.mbedtls/key.pem -out ~/.mbedtls/cert.pem -days 365 -nodes

# Start example server

julia --project=. examples/run_server.jl

# End to End Test
bash examples/test.bash

```
## Core Components

### H2Connection

The main connection object that manages HTTP/2 state:

```julia
config = Http2Proto.H2Config(client_side=true)  # or false for server
conn = Http2Proto.H2Connection(config=config)
```

### Configuration Options

- `client_side`: Boolean indicating client (true) or server (false) mode
- Various HTTP/2 settings can be configured through the connection

### Event System

Http2Proto.jl uses an event-driven architecture. Key events include:

- `Http2Proto.Events.RequestReceived` - New request received
- `Http2Proto.Events.ResponseReceived` - Response received
- `Http2Proto.Events.DataReceived` - Data frame received
- `Http2Proto.Events.StreamEnded` - Stream completed
- `Http2Proto.Events.SettingsChanged` - Settings frame processed
- `Http2Proto.Events.PriorityChanged` - Priority frame received
- `Http2Proto.Events.StreamReset` - Stream reset
- `Http2Proto.Events.ConnectionTerminated` - Connection closed
- `Http2Proto.Events.PingReceived` - Ping frame received
- `Http2Proto.Events.PingAck` - Ping acknowledgment received
- `Http2Proto.Events.InformationalResponseReceived` - 1xx response received
- `Http2Proto.Events.H2CUpgradeReceived` - HTTP/1.1 to HTTP/2 upgrade

## Advanced Features

### Stream Priority

```julia
# Set stream priority
Http2Proto.prioritize!(conn, stream_id; weight=128, depends_on=parent_stream_id, exclusive=false)

# Send headers with priority information
Http2Proto.send_headers(conn, stream_id, headers; 
                priority_weight=128, 
                priority_depends_on=parent_stream_id, 
                priority_exclusive=false)
```

### Flow Control

```julia
# Acknowledge received data to update flow control windows
Http2Proto.acknowledge_received_data!(conn, stream_id, bytes_consumed)
```

### Informational Responses

```julia
# Send 1xx responses (server-side)
informational_headers = [":status" => "103", "link" => "</style.css>; rel=preload; as=style"]
Http2Proto.send_headers(conn, stream_id, informational_headers, end_stream=false)

# Send final response
final_headers = [":status" => "200", "content-type" => "text/html"]
Http2Proto.send_headers(conn, stream_id, final_headers, end_stream=true)
```

### HTTP/1.1 to HTTP/2 Upgrade (Http2Protoc)

```julia
# Server handles HTTP/1.1 upgrade requests automatically
# Client can initiate upgrade by sending appropriate HTTP/1.1 headers
```

## Error Handling

The library provides comprehensive error handling:

- `Http2Proto.H2Exceptions.ProtocolError` - Protocol violations
- `ArgumentError` - Invalid parameters (e.g., invalid priority weights)

## Flow Control Details

Http2Proto.jl implements automatic flow control management:

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
Pkg.test("Http2Proto")
```

## Protocol Compliance

Http2Proto.jl aims for full RFC 7540 compliance, including:

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

*Http2Proto.jl - Bringing modern HTTP/2 capabilities to the Julia ecosystem*
