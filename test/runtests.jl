using Test
using H2  # Το κεντρικό module του project σας

@testset "H2.jl" begin
    # Μέσα στο test/runtests.jl
# ... (τα άλλα testsets) ...

println("\nRunning End-to-End Tests...")
    @testset "E2E" begin
        include("e2e_test.jl")
    end
    # # Δοκιμές για θεμελιώδεις τύπους και σταθερές
    # @testset "Core" begin
    #     include("test_types.jl")
    #     include("test_errors.jl")
    #     include("test_constants.jl")
    # end

    # # Δοκιμές για το σύστημα συμπίεσης κεφαλίδων HPACK
    # @testset "HPACK" begin
    #     include("test_hpack_primitives.jl")
    #     include("test_hpack_huffman.jl")
    #     include("test_hpack_tables.jl")
    #     include("test_hpack_encoder_decoder.jl")
    # end

    # # Δοκιμές για τη σειριοποίηση/αποσειριοποίηση των frames
    # @testset "Frames" begin
    #     include("test_frames.jl")
    # end
    
    # # Δοκιμές για τη διαχείριση των streams και του state machine
    # @testset "Streams" begin
    #     include("test_stream_state_machine.jl")
    #     include("test_streams.jl")
    # end

    # # Δοκιμές για τη διαχείριση της σύνδεσης
    # @testset "Connection" begin
    #     include("test_connection.jl")
    #     include("test_flow_control.jl")
    # end
    
    # # Integration tests για τον Client και τον Server
    # @testset "Client/Server Integration" begin
    #     include("test_integration.jl")
    # end
end