# Debug Test Script for HTTP/2 Client

using Logging
include("Client.jl")  # Use the fixed client
using .Client

const SERVER_HOST = "127.0.0.1"
const SERVER_PORT = 8443

"""
Debug test with detailed logging
"""
function debug_test()
    println("🔍 Debug Test - HTTP/2 Client")
    
    # Test with debug logging enabled
    println("Testing with debug logging...")
    success = Client.debug_connection(SERVER_HOST, SERVER_PORT, path="/simple")
    
    if success
        println("✅ Debug test successful!")
    else
        println("❌ Debug test failed")
    end
    
    return success
end

"""
Step-by-step connection test
"""
function step_by_step_test()
    println("\n🔬 Step-by-step Connection Test")
    println("=" + 50)
    
    # Test 1: Basic connection
    println("Step 1: Testing basic connection...")
    success1, status1, headers1, body1 = Client.get_full_response(SERVER_HOST, SERVER_PORT, path="/simple")
    
    if success1
        println("✅ Step 1 passed")
        println("   Status: $status1")
        println("   Headers: $(length(headers1))")
        println("   Body: '$body1'")
    else
        println("❌ Step 1 failed")
    end
    
    # Test 2: JSON endpoint
    println("\nStep 2: Testing JSON endpoint...")
    success2, status2, headers2, body2 = Client.get_full_response(SERVER_HOST, SERVER_PORT, path="/json")
    
    if success2
        println("✅ Step 2 passed")
        println("   Status: $status2")
        println("   Headers: $(length(headers2))")
        println("   Body: '$body2'")
    else
        println("❌ Step 2 failed")
    end
    
    # Test 3: 404 endpoint
    println("\nStep 3: Testing 404 endpoint...")
    success3, status3, headers3, body3 = Client.get_full_response(SERVER_HOST, SERVER_PORT, path="/nonexistent")
    
    if success3
        println("✅ Step 3 passed")
        println("   Status: $status3")
        println("   Headers: $(length(headers3))")
        println("   Body: '$body3'")
    else
        println("❌ Step 3 failed")
    end
    
    # Summary
    results = [success1, success2, success3]
    passed = count(results)
    
    println("\n📊 Summary: $passed/3 tests passed")
    
    if passed >= 2
        println("🎉 Most tests passed - client is working!")
    else
        println("❌ Multiple failures - need more debugging")
    end
    
    return passed >= 2
end

"""
Minimal test for quick validation
"""
function minimal_test()
    println("\n🚀 Minimal Test")
    
    try
        success, status, headers, body = Client.get_full_response(SERVER_HOST, SERVER_PORT, path="/simple")
        
        if success && !isempty(status)
            println("✅ SUCCESS!")
            println("Status: $status")
            println("Body: '$body'")
            return true
        else
            println("❌ FAILED")
            println("Success: $success")
            println("Status: '$status'")
            return false
        end
    catch ex
        println("❌ EXCEPTION: $ex")
        return false
    end
end

"""
Run all debug tests
"""
function run_debug_tests()
    println("🎯 HTTP/2 Client Debug Tests")
    println("Server: https://$SERVER_HOST:$SERVER_PORT")
    
    # Set normal logging level first
    logger = ConsoleLogger(stdout, Logging.Info)
    global_logger(logger)
    
    tests = [
        ("Minimal Test", minimal_test),
        ("Step-by-step Test", step_by_step_test),
        ("Debug Test", debug_test)
    ]
    
    results = []
    
    for (name, test_func) in tests
        println("Running: $name")
        
        try
            result = test_func()
            push!(results, (name, result))
            println("\nResult: $(result ? "✅ PASSED" : "❌ FAILED")")
        catch ex
            println("\n❌ Test '$name' failed with exception: $ex")
            push!(results, (name, false))
        end
    end
    
    # Final summary
    println("\n" * "=" * 60)
    println("🏁 FINAL RESULTS")
    println("=" * 60)
    
    for (name, success) in results
        status = success ? "✅ PASSED" : "❌ FAILED"
        println("$name: $status")
    end
    
    passed = count(r -> r[2], results)
    total = length(results)
    
    println("\n📊 Overall: $passed/$total tests passed")
    
    if passed == total
        println("🎉 All tests passed! Your HTTP/2 client is working correctly.")
    elseif passed > 0
        println("⚠️  Some tests passed. The client is partially working.")
    else
        println("❌ All tests failed. Check your server and client configuration.")
    end
    
    return results
end

# Make functions available for interactive use
println("🎮 Debug Functions Available:")
println("  - minimal_test()          # Quick validation")
println("  - step_by_step_test()     # Detailed step-by-step testing")
println("  - debug_test()            # Full debug logging")
println("  - run_debug_tests()       # Run all debug tests")
println()
println("Server: https://$SERVER_HOST:$SERVER_PORT")

# Auto-run if script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_debug_tests()
end