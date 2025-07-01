# test/test_buffermanager.jl
using Test
using H2.BufferManager

@testset "BufferManager Tests" begin
    @testset "Get and Release" begin
        # Πάρε έναν buffer από το pool
        buf = get_buffer()
        @test buf isa IOBuffer
        @test bytesavailable(buf) == 0

        # Γράψε κάτι στον buffer
        write(buf, "hello")

        # ΔΙΟΡΘΩΣΗ: Ελέγχουμε το μέγεθος (size) του buffer, όχι τα διαθέσιμα bytes για ανάγνωση.
        @test buf.size == 5

        # Επέστρεψε τον buffer
        release_buffer(buf)

        # Πάρε ξανά έναν buffer (μπορεί να είναι ο ίδιος ή άλλος)
        buf2 = get_buffer()
        @test buf2 isa IOBuffer
        # Πρέπει να είναι 'καθαρός' μετά το release
        @test bytesavailable(buf2) == 0
        @test buf2.size == 0

        # Επέστρεψέ τον για να μην αδειάσει το pool
        release_buffer(buf2)
    end

    @testset "Pool functionality" begin
        buffers = []
        # Αδειάζουμε ένα μεγάλο μέρος του pool
        for i in 1:BufferManager.POOL_CAPACITY - 2
            push!(buffers, get_buffer())
        end
        
        @test isready(BufferManager.buffer_pool)

        # Επιστρέφουμε όλους τους buffers
        for buf in buffers
            release_buffer(buf)
        end
    end
end