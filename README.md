# H2.jl

Experimental implementation of HTTP2 protocol

## Instructions for SSL/TLS (cert.pem & key.pem)

To run the end-to-end tests or use HTTPS/TLS, you need two files: `cert.pem` (certificate) and `key.pem` (private key).

### Creating a self-signed certificate (for testing)

You can generate self-signed files using OpenSSL:

```sh
mkdir -p ~/.mbedtls
openssl req -x509 -newkey rsa:4096 -keyout ~/.mbedtls/key.pem -out ~/.mbedtls/cert.pem -days 365 -nodes -subj "/CN=localhost"
chmod 600 ~/.mbedtls/key.pem ~/.mbedtls/cert.pem
```

### Loading certificates from environment variables

H2.jl reads the file paths from the environment variables `CERT_PATH` and `KEY_PATH`. If not set, it uses the default paths (`../cert.pem`, `../key.pem`).

#### Example:

```sh
export CERT_PATH="$HOME/.mbedtls/cert.pem"
export KEY_PATH="$HOME/.mbedtls/key.pem"
```

In your Julia code:

```julia
CERT_PATH = get(ENV, "CERT_PATH", joinpath(@__DIR__, "../cert.pem"))
KEY_PATH = get(ENV, "KEY_PATH", joinpath(@__DIR__, "../key.pem"))
```

### Troubleshooting
- Use absolute paths (e.g. `/Users/username/.mbedtls/cert.pem`), not `~`.
- The files must be readable by the user running the Julia process (`chmod 600 ...`).
- Make sure the files are not empty or corrupted.

---

For more information, see the tests and the project documentation.