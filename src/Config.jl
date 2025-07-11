module Config

export H2Config

"""
    H2Config

An object that contains all the configuration settings for the behavior
of an H2 connection.

# Fields
- `client_side::Bool`: Whether the connection is client-side (true) or server-side (false).
- `header_encoding::Union{String, Nothing}`: The encoding for headers. `nothing` to keep them as `bytes`.
- `validate_inbound_headers::Bool`: Enables/disables validation of incoming headers.
- `normalize_inbound_headers::Bool`: Enables/disables normalization of incoming headers (e.g., cookie merging).

# Usage

## Basic Usage
```julia
# Create a default client-side configuration
config = H2Config()

# Create a server-side configuration
server_config = H2Config(client_side=false)

# Create a configuration with custom settings
custom_config = H2Config(
    client_side=true,
    header_encoding="utf-8",
    validate_inbound_headers=false,
    normalize_inbound_headers=true
)
```

## Common Configuration Scenarios
```julia
# Strict client configuration (default)
strict_client = H2Config(
    client_side=true,
    validate_inbound_headers=true,
    normalize_inbound_headers=true
)

# Permissive server configuration
permissive_server = H2Config(
    client_side=false,
    validate_inbound_headers=false,
    normalize_inbound_headers=false
)

# Configuration with string headers instead of bytes
string_headers = H2Config(
    header_encoding="utf-8"
)
```

## Field Access and Modification
```julia
config = H2Config()

# Access fields
println(config.client_side)  # true
println(config.header_encoding)  # nothing

# Modify fields (mutable struct)
config.validate_inbound_headers = false
config.header_encoding = "ascii"
```
"""
mutable struct H2Config
    client_side::Bool
    header_encoding::Union{String, Nothing}
    validate_inbound_headers::Bool
    normalize_inbound_headers::Bool
    # TODO: In the future we can add more settings here!
end

"""
    H2Config(; client_side::Bool=true, ...)

Constructor with keyword arguments for easy creation.
"""
function H2Config(;
        client_side::Bool=true,
        header_encoding::Union{String, Nothing}=nothing,
        validate_inbound_headers::Bool=true,
        normalize_inbound_headers::Bool=true
    )
    return H2Config(
        client_side,
        header_encoding,
        validate_inbound_headers,
        normalize_inbound_headers
    )
end

end # module Config