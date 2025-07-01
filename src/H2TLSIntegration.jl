# [THE CORRECT API FIX] H2/src/integrations/tls.jl

module H2TLSIntegration

using Sockets
using MbedTLS


const ALPN_PROTOCOLS = ["h2", "http/1.1"]

function tls_accept(tcp_socket::TCPSocket;
                    cert_file::String, key_file::String, alpn_protocols=ALPN_PROTOCOLS, kwargs...)
    
    @debug "Configuring SERVER TLS with cert: '$cert_file'"
    
    conf = MbedTLS.SSLConfig(cert_file, key_file)

    # **THE FIX**: Χρησιμοποιούμε τα σωστά keyword arguments που μας υπέδειξε το σφάλμα.
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

end # module HTTP2TLSIntegration