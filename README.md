# H2.jl

A high-performance, native Julia implementation of the HTTP/2 protocol with comprehensive support for modern web communication features.

## Features

### Core HTTP/2 Protocol Support
- **Full HTTP/2 Specification Compliance** - Complete implementation of RFC 7540
- **Multiplexing** - Handle multiple concurrent requests over a single connection
- **Stream Priority** - Configurable request prioritization for optimal resource delivery
- **Flow Control** - Automatic window management for efficient data transfer
- **Header Compression** - HPACK implementation for reduced bandwidth usage

### Advanced Capabilities
- **Server Push** - Proactively send resources to clients before they're requested
- **TLS/SSL Support** - Secure connections with configurable certificate management
- **Graceful Shutdown** - Clean connection termination with GOAWAY frame handling
- **Connection Management** - Automatic connection pooling and lifecycle management
- **Error Handling** - Comprehensive error recovery and protocol violation detection

### Performance & Reliability
- **Asynchronous I/O** - Non-blocking operations for maximum throughput
- **Concurrent Request Handling** - Efficient multiplexing with Julia's task system
- **Memory Efficient** - Optimized buffer management and resource utilization
- **Robust Testing** - Comprehensive end-to-end test suite covering edge cases

## Installation

```julia
using Pkg
Pkg.add("H2")
```

## Quick Start

### Basic HTTP/2 Server

```julia
using H2
using HTTP

# Create a simple router
router = HTTP.Router()
HTTP.register!(router, "GET", "/", req -> HTTP.Response(200, "Hello, HTTP/2!"))

# Start HTTP/2 server
H2.serve(H2Router(router), "127.0.0.1", 8080)
```

### HTTP/2 Client

```julia
using H2

# Connect to HTTP/2 server
client = H2.connect("httpbin.org", 443; is_tls=true)

# Make requests
response = H2.request(client, "GET", "/get")
println(String(response.body))

# Clean up
H2.close(client)
```

## TLS/SSL Configuration

H2.jl supports secure connections out of the box. For development and testing, you can generate self-signed certificates:

### Quick Setup

```bash
# Create certificate directory
mkdir -p ~/.mbedtls

# Generate self-signed certificate (for development only)
openssl req -x509 -newkey rsa:4096 \
  -keyout ~/.mbedtls/key.pem \
  -out ~/.mbedtls/cert.pem \
  -days 365 -nodes \
  -subj "/CN=localhost"

# Set appropriate permissions
chmod 600 ~/.mbedtls/key.pem ~/.mbedtls/cert.pem
```

### Environment Configuration

```bash
export CERT_PATH="$HOME/.mbedtls/cert.pem"
export KEY_PATH="$HOME/.mbedtls/key.pem"
```

### Programmatic Configuration

```julia
# Custom certificate paths
cert_path = get(ENV, "CERT_PATH", joinpath(homedir(), ".mbedtls", "cert.pem"))
key_path = get(ENV, "KEY_PATH", joinpath(homedir(), ".mbedtls", "key.pem"))

# Start secure server
H2.serve(handler, "127.0.0.1", 8443; 
         is_tls=true, 
         cert_file=cert_path, 
         key_file=key_path)
```

## Advanced Usage

### Server Push Example

```julia
HTTP.register!(router, "GET", "/push-example", req -> begin
    # Push CSS resource before client requests it
    stream = req.context[:stream]
    push_headers = [
        ":method" => "GET",
        ":scheme" => "https",
        ":authority" => "example.com",
        ":path" => "/styles.css"
    ]
    
    pushed_stream = push_promise!(stream.connection, stream, push_headers)
    
    if pushed_stream !== nothing
        # Send the pushed resource
        css_content = "body { background: blue; }"
        H2.Connection.send_headers!(pushed_stream, [":status" => "200"], end_stream=false)
        H2.Connection.send_data!(pushed_stream, Vector{UInt8}(css_content), end_stream=true)
    end
    
    return HTTP.Response(200, "<html><head><link rel='stylesheet' href='/styles.css'></head></html>")
end)
```

### Custom Settings

```julia
# Configure HTTP/2 settings
settings = H2.H2Settings.create_server_settings()
settings.max_concurrent_streams = 100
settings.initial_window_size = 65536
settings.enable_push = true

# Start server with custom settings
H2.serve(handler, "127.0.0.1", 8080; settings=settings)
```

### Connection Multiplexing

```julia
# Multiple concurrent requests over single connection
client = H2.connect("api.example.com", 443; is_tls=true)

# Launch concurrent requests
tasks = []
for i in 1:10
    task = @async H2.request(client, "GET", "/data/$i")
    push!(tasks, task)
end

# Collect results
responses = fetch.(tasks)
```

## Performance Characteristics

H2.jl is designed for high-performance scenarios:

- **Low Latency** - Minimal overhead for request processing
- **High Concurrency** - Efficient handling of thousands of concurrent streams
- **Memory Efficient** - Optimized for large-scale deployments
- **Protocol Compliance** - Full HTTP/2 specification adherence ensures compatibility

## Testing

Run the comprehensive test suite:

```julia
using Pkg
Pkg.test("H2")
```

The test suite includes:
- Protocol compliance verification
- Multiplexing and concurrency tests
- Server push functionality
- Flow control validation
- Error handling scenarios
- Performance benchmarks

## Contributing

Contributions are welcome! Please read our contributing guidelines and submit pull requests for any improvements.

## License

MIT License - see LICENSE file for details.

## Status

**Development Status**: Experimental

This implementation is under active development. While it implements the core HTTP/2 specification, it should be thoroughly tested before production use. We welcome feedback and contributions to help stabilize and optimize the implementation.

---

*H2.jl - Bringing modern HTTP/2 capabilities to the Julia ecosystem*