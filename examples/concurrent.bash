#!/bin/bash

# Define server address and port
HOST="localhost"
PORT="8443"
URL="https://${HOST}:${PORT}"

# Define certificate and key paths
CERT_FILE="${HOME}/.mbedtls/cert.pem"

# Stress test configuration
CONCURRENT_REQUESTS=50
TOTAL_REQUESTS=1000
DURATION_SECONDS=60

# Counters
SUCCESSFUL_REQUESTS=0
FAILED_REQUESTS=0
TOTAL_COMPLETED=0

echo "========================================="
echo "Starting Concurrent Stress Test"
echo "Server URL: $URL"
echo "Concurrent Requests: $CONCURRENT_REQUESTS"
echo "Total Requests: $TOTAL_REQUESTS"
echo "Duration: $DURATION_SECONDS seconds"
echo "========================================="

# Function to run a single request
run_single_request() {
    local endpoint=$1
    local method=$2
    local data=$3
    local expected_status=$4
    
    local start_time=$(date +%s.%3N)
    
    case $method in
        "GET")
            response=$(curl --http2 --http2-prior-knowledge --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" \
                -s -o /dev/null -w "%{http_code}:%{time_total}" \
                "$URL$endpoint" 2>/dev/null)
            ;;
        "POST")
            response=$(curl --http2 --http2-prior-knowledge --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" \
                -s -o /dev/null -w "%{http_code}:%{time_total}" \
                -X POST -H "Content-Type: application/json" \
                -d "$data" "$URL$endpoint" 2>/dev/null)
            ;;
        "PUT"|"PATCH"|"DELETE")
            response=$(curl --http2 --http2-prior-knowledge --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" \
                -s -o /dev/null -w "%{http_code}:%{time_total}" \
                -X "$method" -H "Content-Type: application/json" \
                -d "$data" "$URL$endpoint" 2>/dev/null)
            ;;
    esac
    
    local end_time=$(date +%s.%3N)
    local status_code=$(echo "$response" | cut -d':' -f1)
    local response_time=$(echo "$response" | cut -d':' -f2)
    
    echo "$status_code:$response_time:$(echo "$end_time - $start_time" | bc -l)"
}

# Function to run concurrent requests for a specific endpoint
stress_endpoint() {
    local endpoint=$1
    local method=$2
    local data=$3
    local expected_status=$4
    local num_requests=$5
    
    echo "Stressing $method $endpoint with $num_requests concurrent requests..."
    
    local pids=()
    local results_file=$(mktemp)
    
    # Start concurrent requests
    for ((i=1; i<=num_requests; i++)); do
        {
            result=$(run_single_request "$endpoint" "$method" "$data" "$expected_status")
            echo "$result" >> "$results_file"
        } &
        pids+=($!)
        
        # Limit concurrent processes
        if (( ${#pids[@]} >= CONCURRENT_REQUESTS )); then
            wait "${pids[@]}"
            pids=()
        fi
    done
    
    # Wait for remaining processes
    wait "${pids[@]}"
    
    # Process results
    local success_count=0
    local error_count=0
    local total_time=0
    local min_time=999999
    local max_time=0
    
    while IFS=':' read -r status_code response_time total_time_req; do
        if [[ "$status_code" == "$expected_status" ]]; then
            ((success_count++))
        else
            ((error_count++))
        fi
        
        if (( $(echo "$response_time > $max_time" | bc -l) )); then
            max_time=$response_time
        fi
        
        if (( $(echo "$response_time < $min_time" | bc -l) )); then
            min_time=$response_time
        fi
        
        total_time=$(echo "$total_time + $response_time" | bc -l)
    done < "$results_file"
    
    local avg_time=$(echo "scale=3; $total_time / $num_requests" | bc -l)
    
    echo "Results for $method $endpoint:"
    echo "  ✅ Successful: $success_count"
    echo "  ❌ Failed: $error_count"
    echo "  📊 Avg Response Time: ${avg_time}s"
    echo "  ⚡ Min Response Time: ${min_time}s"
    echo "  🐌 Max Response Time: ${max_time}s"
    echo "  📈 Requests/sec: $(echo "scale=2; $num_requests / $total_time * $num_requests" | bc -l)"
    echo ""
    
    rm "$results_file"
}

# Function for duration-based stress test
duration_stress_test() {
    echo "Running duration-based stress test for $DURATION_SECONDS seconds..."
    
    local end_time=$(($(date +%s) + DURATION_SECONDS))
    local request_count=0
    local success_count=0
    local error_count=0
    
    # Array of test endpoints
    local endpoints=(
        "/simple:GET::200"
        "/json:GET::200"
        "/users:POST:{\"name\":\"StressUser\"}:201"
        "/users/123:GET::200"
        "/echo-headers:GET::200"
    )
    
    while [ $(date +%s) -lt $end_time ]; do
        local pids=()
        
        # Start batch of concurrent requests
        for ((i=1; i<=CONCURRENT_REQUESTS; i++)); do
            # Pick random endpoint
            local endpoint_info=${endpoints[$RANDOM % ${#endpoints[@]}]}
            IFS=':' read -r endpoint method data expected_status <<< "$endpoint_info"
            
            {
                result=$(run_single_request "$endpoint" "$method" "$data" "$expected_status")
                status_code=$(echo "$result" | cut -d':' -f1)
                
                if [[ "$status_code" == "$expected_status" ]]; then
                    echo "SUCCESS"
                else
                    echo "FAILED:$status_code"
                fi
            } &
            pids+=($!)
        done
        
        # Wait for batch to complete
        for pid in "${pids[@]}"; do
            wait "$pid"
            result=$(jobs -p | wc -l)
        done
        
        request_count=$((request_count + CONCURRENT_REQUESTS))
        
        # Brief pause between batches
        sleep 0.1
    done
    
    echo "Duration test completed:"
    echo "  Total requests sent: $request_count"
    echo "  Average RPS: $(echo "scale=2; $request_count / $DURATION_SECONDS" | bc -l)"
}

# Function for mixed workload stress test
mixed_workload_test() {
    echo "Running mixed workload stress test..."
    
    local read_requests=$((TOTAL_REQUESTS * 60 / 100))  # 60% reads
    local write_requests=$((TOTAL_REQUESTS * 40 / 100)) # 40% writes
    
    echo "Read requests: $read_requests"
    echo "Write requests: $write_requests"
    
    # Run read-heavy workload
    stress_endpoint "/simple" "GET" "" "200" $read_requests &
    local read_pid=$!
    
    # Run write workload
    stress_endpoint "/users" "POST" '{"name":"ConcurrentUser"}' "201" $write_requests &
    local write_pid=$!
    
    # Wait for both to complete
    wait $read_pid
    wait $write_pid
    
    echo "Mixed workload test completed!"
}

# Function to test connection pooling and keep-alive
connection_test() {
    echo "Testing connection reuse and HTTP/2 multiplexing..."
    
    local temp_script=$(mktemp)
    cat > "$temp_script" << 'EOF'
#!/bin/bash
URL=$1
CERT_FILE=$2
HOST=$3
PORT=$4

# Single connection with multiple requests
curl --http2 --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" \
    -s -o /dev/null -w "%{http_code}" \
    "$URL/simple" "$URL/json" "$URL/users/123" "$URL/echo-headers"
EOF
    
    chmod +x "$temp_script"
    
    # Run multiple instances to test connection handling
    for ((i=1; i<=20; i++)); do
        "$temp_script" "$URL" "$CERT_FILE" "$HOST" "$PORT" &
    done
    
    wait
    rm "$temp_script"
    echo "Connection test completed!"
}

# Main execution
echo "Choose stress test type:"
echo "1. Endpoint-specific stress test"
echo "2. Duration-based stress test"
echo "3. Mixed workload test"
echo "4. Connection handling test"
echo "5. All tests"
read -p "Enter choice (1-5): " choice

case $choice in
    1)
        stress_endpoint "/simple" "GET" "" "200" 100
        stress_endpoint "/users" "POST" '{"name":"TestUser"}' "201" 50
        stress_endpoint "/users/123" "GET" "" "200" 100
        ;;
    2)
        duration_stress_test
        ;;
    3)
        mixed_workload_test
        ;;
    4)
        connection_test
        ;;
    5)
        echo "Running all stress tests..."
        stress_endpoint "/simple" "GET" "" "200" 100
        echo "---"
        duration_stress_test
        echo "---"
        mixed_workload_test
        echo "---"
        connection_test
        ;;
    *)
        echo "Invalid choice. Running default endpoint test..."
        stress_endpoint "/simple" "GET" "" "200" 100
        ;;
esac

echo "========================================="
echo "Stress testing completed!"
echo "========================================="