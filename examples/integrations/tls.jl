module H2TLSIntegration

using Sockets
using MbedTLS


const ALPN_PROTOCOLS = ["h2", "http/1.1"]

"""
    tls_accept(tcp_socket::TCPSocket; cert_file::String, key_file::String, alpn_protocols=ALPN_PROTOCOLS, kwargs...)

Accept a new incoming TCP connection and upgrade it to a TLS connection for HTTP/2 server use.

Arguments:
- `tcp_socket::TCPSocket`: The accepted TCP socket from the server's listen socket.

Keyword Arguments:
- `cert_file::String`: Path to the server's certificate file (PEM format).
- `key_file::String`: Path to the server's private key file (PEM format).
- `alpn_protocols::Vector{String}`: List of ALPN protocols to advertise (default: `["h2", "http/1.1"]`).
- `kwargs...`: Additional keyword arguments passed to the MbedTLS configuration.

Returns:
- `MbedTLS.SSLContext`: A TLS-wrapped socket ready for HTTP/2 communication.

Throws:
- `ErrorException` if ALPN negotiation fails or the handshake fails.

Notes:
- The function disables peer verification by default for development/testing. For production, set a stricter `authmode!`.
"""
function tls_accept(tcp_socket::TCPSocket;
                    cert_file::String, key_file::String, alpn_protocols=ALPN_PROTOCOLS, kwargs...)
    
    @debug "Configuring SERVER TLS with cert: '$cert_file'"
    
    conf = MbedTLS.SSLConfig(cert_file, key_file)

    MbedTLS.config_defaults!(conf,
                             endpoint=MbedTLS.MBEDTLS_SSL_IS_SERVER,
                             transport=MbedTLS.MBEDTLS_SSL_TRANSPORT_STREAM)

    MbedTLS.set_alpn!(conf, alpn_protocols)
    MbedTLS.authmode!(conf, MbedTLS.MBEDTLS_SSL_VERIFY_NONE)

    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)

    ssl_context = MbedTLS.SSLContext()
    MbedTLS.setup!(ssl_context, conf)
    MbedTLS.associate!(ssl_context, tcp_socket)
    MbedTLS.handshake!(ssl_context)
    
    negotiated = MbedTLS.alpn_proto(ssl_context)
    if negotiated != "h2"
        close(ssl_context)
        error("ALPN negotiation failed - client offered: '$negotiated', expected 'h2'")
    end
    
    return ssl_context
end

"""
    tls_connect(host::AbstractString, port::Integer; alpn_protocols=ALPN_PROTOCOLS, verify_peer::Bool=false, kwargs...)

Establish a TLS connection to a remote HTTP/2 server, performing ALPN negotiation.

Arguments:
- `host::AbstractString`: The server hostname or IP address.
- `port::Integer`: The server port.

Keyword Arguments:
- `alpn_protocols::Vector{String}`: List of ALPN protocols to advertise (default: `["h2", "http/1.1"]`).
- `verify_peer::Bool=false`: Whether to verify the server's certificate (default: false for testing).
- `kwargs...`: Additional keyword arguments passed to the MbedTLS configuration.

Returns:
- `MbedTLS.SSLContext`: A TLS-wrapped socket ready for HTTP/2 communication.

Throws:
- `ErrorException` if ALPN negotiation fails or the handshake fails.

Notes:
- For production, set `verify_peer=true` and provide CA certificates as needed.
"""
function tls_connect(host::AbstractString, port::Integer; alpn_protocols=ALPN_PROTOCOLS, verify_peer::Bool=false, kwargs...)
    @debug "Configuring CLIENT TLS for $host:$port"
    tcp_socket = Sockets.connect(host, port)
    
    conf = MbedTLS.SSLConfig()

    MbedTLS.config_defaults!(conf,
                             endpoint=MbedTLS.MBEDTLS_SSL_IS_CLIENT,
                             transport=MbedTLS.MBEDTLS_SSL_TRANSPORT_STREAM)
    
    authmode = verify_peer ? MbedTLS.MBEDTLS_SSL_VERIFY_OPTIONAL : MbedTLS.MBEDTLS_SSL_VERIFY_NONE
    MbedTLS.authmode!(conf, authmode)
    MbedTLS.set_alpn!(conf, alpn_protocols)

    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)

    ssl_context = MbedTLS.SSLContext()
    MbedTLS.setup!(ssl_context, conf)
    MbedTLS.associate!(ssl_context, tcp_socket)
    MbedTLS.handshake!(ssl_context)
    
    negotiated = MbedTLS.alpn_proto(ssl_context)
    if negotiated != "h2"
        close(ssl_context)
        error("ALPN negotiation failed - server offered: '$negotiated', expected 'h2'")
    end
    
    return ssl_context
end

end