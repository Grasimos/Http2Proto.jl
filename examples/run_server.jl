include("Server.jl")  
using .Server
using Sockets

# Start the server
host = IPv4("127.0.0.1")  # localhost
port = 8443  # HTTPS port

server_task = Server.start_secure_server(host, port)

# Keep the server running
println("Server started on https://127.0.0.1:8443")
println("Press Ctrl+C to stop")

try
    wait(server_task)
catch InterruptException
    println("Server stopped")
end