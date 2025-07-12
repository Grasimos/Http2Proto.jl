#!/bin/bash

# Define server address and port
HOST="localhost"
PORT="8443"
URL="https://${HOST}:${PORT}"

# Define certificate and key paths (adjust if different)
CERT_FILE="${HOME}/.mbedtls/cert.pem"
KEY_FILE="${HOME}/.mbedtls/key.pem"

# Counter for failed tests
FAILED_TESTS=0

echo "========================================="
echo "Starting curl tests for Julia H2 Server"
echo "Server URL: $URL"
echo "Using cert: $CERT_FILE"
echo "========================================="

# Helper function to run curl commands and display output
run_test() {
    TEST_NAME=$1
    CURL_CMD=$2
    EXPECTED_STATUS=$3
    echo -e "\n--- Running Test: $TEST_NAME ---"
    
    # Run curl, writing body to /dev/null and capturing only the http_code.
    # Added -s to silence the progress meter.
    HTTP_STATUS=$(eval "$CURL_CMD" -s -o /dev/null -w "%{http_code}")
    
    echo "Command: $CURL_CMD"
    echo "Expected Status: $EXPECTED_STATUS, Got: $HTTP_STATUS"
    
    if [[ "$HTTP_STATUS" == "$EXPECTED_STATUS" ]]; then
        echo "Status: ✅ PASSED"
    else
        echo "Status: ❌ FAILED"
        ((FAILED_TESTS++))
    fi
    echo "------------------------------------"
}

# --- Initial Connection Check ---
echo "Verifying server certificate and establishing HTTP/2 connection..."
curl -v --http2 --cacert "$CERT_FILE" --resolve "$HOST:$PORT:127.0.0.1" "$URL/" 2>&1 | grep -E 'HTTP/2|TLSv1.3'

if [ $? -ne 0 ]; then
    echo "ERROR: Initial HTTP/2 or TLS connection failed. Ensure the server is running and certs are correctly set up."
    echo "Aborting tests."
    exit 1
fi

echo "Connection verified. Proceeding with tests."

# --- API Tests ---
# Note: Removed the redundant '-k' flag as '--cacert' is used for proper verification.

# Test 1: GET /simple
run_test "GET /simple" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/simple\"" \
    "200"

# Test 2: GET /json
run_test "GET /json" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/json\" -H \"Accept: application/json\"" \
    "200"

# Test 3: GET /users/:id (e.g., /users/123) - FIXED IP typo
run_test "GET /users/123" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/users/123\" -H \"Accept: application/json\"" \
    "200"

# Test 4: POST /users (with JSON body)
run_test "POST /users" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Alice\", \"email\":\"alice@example.com\"}' \"$URL/users\"" \
    "201"

# Test 5: POST /users (with invalid JSON body)
run_test "POST /users (Invalid JSON)" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X POST -H \"Content-Type: application/json\" -d '{\"name\":\"Bob\", \"invalid_json\"' \"$URL/users\"" \
    "400"

# Test 6: GET /echo-headers
run_test "GET /echo-headers" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/echo-headers\" -H \"X-Custom-Header: TestValue\" -H \"User-Agent: curl-test-suite\"" \
    "200"

# Test 7: PUT /update/:id (e.g., /update/item456)
run_test "PUT /update/item456" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X PUT -H \"Content-Type: application/json\" -d '{\"status\":\"completed\", \"progress\":100}' \"$URL/update/item456\"" \
    "200"

# Test 8: DELETE /items/:id (e.g., /items/item789)
run_test "DELETE /items/item789" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" -X DELETE \"$URL/items/item789\"" \
    "204"

# Test 9: GET a non-existent path
run_test "GET /nonexistent" \
    "curl --http2 --cacert \"$CERT_FILE\" --resolve \"$HOST:$PORT:127.0.0.1\" \"$URL/nonexistent\"" \
    "404"

# --- Test Summary ---
echo -e "\n========================================="
echo "All curl tests completed."
if [ $FAILED_TESTS -eq 0 ]; then
    echo "🎉 All tests passed!"
else
    echo "🔥 $FAILED_TESTS test(s) failed."
fi
echo "========================================="

# Exit with a non-zero status code if any tests failed
exit $FAILED_TESTS