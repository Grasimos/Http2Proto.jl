#!/bin/bash

# Define server address and port
HOST="localhost"
PORT="8443"
URL="https://${HOST}:${PORT}"

# Define certificate and key paths
CERT_FILE="${HOME}/.mbedtls/cert.pem"

# Counters
FAILED_TESTS=0
PASSED_TESTS=0
TOTAL_TESTS=0

echo "========================================="
echo "Starting curl tests for Julia H2 Server"
echo "Server URL: $URL"
echo "========================================="

# Helper function to run a test and check the HTTP status code
run_test() {
    ((TOTAL_TESTS++))
    TEST_NAME=$1
    CURL_CMD=$2
    EXPECTED_STATUS=$3
    echo -e "\n--- Test $TOTAL_TESTS: $TEST_NAME ---"
    
    HTTP_STATUS=$(eval "$CURL_CMD" -s -o /dev/null -w "%{http_code}")
    
    echo "Command: $CURL_CMD"
    echo "Expected Status: $EXPECTED_STATUS, Got: $HTTP_STATUS"
    
    if [[ "$HTTP_STATUS" == "$EXPECTED_STATUS" ]]; then
        echo "Status: ✅ PASSED"
        ((PASSED_TESTS++))
    else
        echo "Status: ❌ FAILED"
        ((FAILED_TESTS++))
    fi
    echo "------------------------------------"
}

# Helper function to check for a specific header in the response
run_test_with_header_check() {
    ((TOTAL_TESTS++))
    TEST_NAME=$1
    CURL_CMD=$2
    EXPECTED_HEADER=$3
    echo -e "\n--- Test $TOTAL_TESTS: $TEST_NAME ---"

    # Use -i to include headers in the output, then grep for the expected header
    HEADER_OUTPUT=$(eval "$CURL_CMD" -s -i)
    
    echo "Command: $CURL_CMD"
    echo "Checking for header: '$EXPECTED_HEADER'"
    
    if echo "$HEADER_OUTPUT" | grep -q -i "$EXPECTED_HEADER"; then
        echo "Status: ✅ PASSED"
        ((PASSED_TESTS++))
    else
        echo "Status: ❌ FAILED"
        echo "Full headers received:"
        echo "$HEADER_OUTPUT"
        ((FAILED_TESTS++))
    fi
    echo "------------------------------------"
}

# --- Initial Connection Check ---
echo "Verifying server certificate and establishing HTTP/2 connection..."
curl --http2 --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" --head "$URL/simple" -s
if [ $? -ne 0 ]; then
    echo "ERROR: Initial HTTP/2 or TLS connection failed."
    exit 1
fi
echo "Connection verified. Proceeding with tests."

# --- API Tests (Existing) ---
run_test "GET /simple" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/simple\"" "200"
run_test "GET /json" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/json\"" "200"
run_test "GET /users/123" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/users/123\"" "200"
run_test "POST /users" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Alice\"}' \"$URL/users\"" "201"
run_test "POST /users with invalid JSON" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Bob\",}' \"$URL/users\"" "400"
run_test "GET /echo-headers" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -H \"X-Custom-Header: MyValue\" \"$URL/echo-headers\"" "200"
run_test "PUT /update/456" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X PUT -H \"Content-Type: application/json\" -d '{\"status\":\"updated\"}' \"$URL/update/456\"" "200"
run_test "DELETE /items/789" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X DELETE \"$URL/items/789\"" "204"
run_test "GET non-existent route" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/not-a-real-path\"" "404"
run_test "OPTIONS for CORS" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X OPTIONS \"$URL/users\"" "200"

# --- New API Tests ---
run_test "GET with Query Parameters" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/search?q=julia&limit=50\"" "200"
run_test "POST with Form Data (Success)" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -d 'username=admin&password=123' \"$URL/login\"" "200"
run_test "POST with Form Data (Failure)" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -d 'username=guest' \"$URL/login\"" "401"
run_test "GET /error to trigger custom 500 handler" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/error\"" "500"
run_test "PATCH /users/123" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X PATCH -H \"Content-Type: application/json\" -d '{\"email\":\"new.email@example.com\"}' \"$URL/users/123\"" "200"
run_test "POST with empty body" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X POST -H \"Content-Type: application/json\" -d '' \"$URL/users\"" "400"
run_test_with_header_check "GET custom response header" "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/custom-headers\"" "X-App-Version: 2.1.0"


# --- Final Results ---
echo -e "\n========================================="
echo "Test Run Summary"
echo "Total Tests: $TOTAL_TESTS"
echo "✅ Passed: $PASSED_TESTS"
echo "❌ Failed: $FAILED_TESTS"
echo "========================================="

exit $FAILED_TESTS