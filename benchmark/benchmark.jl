
using Test
using H2
using Sockets
using BenchmarkTools

"""
Benchmark για την απόδοση του H2 server υπό φορτίο.
Μετράει τον χρόνο και τα memory allocations για την ταυτόχρονη
εξυπηρέτηση ενός μεγάλου αριθμού requests.
"""
function run_benchmark()
    # --- Server Setup ---
    HOST = "127.0.0.1"
    PORT = 8009 # Χρησιμοποιούμε διαφορετικό port από το e2e_test
    
    # Ένας απλός handler που επιστρέφει ένα σταθερό μήνυμα
    h2_handler(conn, stream) = begin
        resp_headers = [":status" => "200", "content-type" => "text/plain"]
        resp_body = Vector{UInt8}("benchmark-ok")
        H2.Connection.send_headers!(stream, resp_headers; end_stream=false)
        H2.Connection.send_data!(stream, resp_body; end_stream=true)
    end

    startup_channel = Channel{Bool}(1)
    CERT_PATH = joinpath(@__DIR__, "../cert.pem")
    KEY_PATH = joinpath(@__DIR__, "../key.pem")

    server_task = errormonitor(@async H2.serve(
        h2_handler, 
        HOST, PORT; 
        is_tls=false, 
        cert_file=CERT_PATH, 
        key_file=KEY_PATH,
        max_concurrent_streams=1000, # <-- ΑΥΞΑΝΟΥΜΕ ΤΟ ΟΡΙΟ ΓΙΑ ΤΟ TEST
        ready_channel=startup_channel
    ))
    
    client = nothing
    benchmark_result = nothing
    try
        # Περιμένουμε την επιβεβαίωση ότι ο server ξεκίνησε
        @test take!(startup_channel) == true

        # --- Client & Benchmark ---
        client = H2.connect(HOST, PORT; is_tls=false, verify_peer=false)
        @test H2.Connection.is_open(client.conn)

        num_requests = 1000
        tasks = Vector{Task}(undef, num_requests) 

        println("🚀 Starting benchmark with $num_requests concurrent requests...")

        benchmark_result = @btime begin
            for i in 1:$num_requests
                # Χρησιμοποιούμε $client και $tasks για να αναφερθούμε στις εξωτερικές μεταβλητές
                $tasks[i] = @async H2.request($client, "GET", "/")
            end
            # Περιμένουμε να ολοκληρωθούν όλα τα tasks
            fetch.($tasks)
        end

        # --- Cleanup ---
        println("✅ Benchmark finished.")
        
    finally
        if client !== nothing && H2.Connection.is_open(client.conn)
            H2.close(client)
        end
        if !istaskdone(server_task)
            schedule(server_task, InterruptException(), error=true)
            # Δίνουμε λίγο χρόνο για να κλείσει ο server
            sleep(0.5)
        end
    end
    
    return benchmark_result
end

# Τρέχουμε το benchmark
run_benchmark()

