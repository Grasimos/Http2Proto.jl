using Sockets
include("Server.jl")          # our turbo file
using .Server

const HOST = ip"127.0.0.1"
const PORT = 8443

tasks = Server.start_secure_server(HOST, PORT)
println("🚀 Server ready – press Ctrl+C to stop")

try
    wait.(tasks)             
catch InterruptException
    println("\n👋 Shutting down gracefully …")
end