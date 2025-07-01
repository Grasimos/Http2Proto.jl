module H2Settings


using Base: @kwdef
using H2Frames: SettingsFrame, SettingsParameter,
                SETTINGS_HEADER_TABLE_SIZE, SETTINGS_ENABLE_PUSH,
                SETTINGS_MAX_CONCURRENT_STREAMS, SETTINGS_INITIAL_WINDOW_SIZE,
                SETTINGS_MAX_FRAME_SIZE, SETTINGS_MAX_HEADER_LIST_SIZE,
                SETTINGS_ENABLE_CONNECT_PROTOCOL
using ..Exc

export HTTP2Settings, create_server_settings, create_client_settings, create_settings_frame,
    DEFAULT_HEADER_TABLE_SIZE, DEFAULT_WINDOW_SIZE, DEFAULT_MAX_FRAME_SIZE, SETTINGS_ACK, apply_settings!

const DEFAULT_WINDOW_SIZE = 65535  # 2^16 - 1
const DEFAULT_HEADER_TABLE_SIZE = 4096
const DEFAULT_MAX_FRAME_SIZE = 16384  # 2^14
const SETTINGS_ACK = 0x1

"""
    HTTP2Settings

Structure representing HTTP/2 connection settings as defined in RFC 7540.
Contains both local and remote settings with proper validation.
"""
@kwdef mutable struct HTTP2Settings
    stream_id::UInt32 = UInt32(0)
    header_table_size::UInt32 = DEFAULT_HEADER_TABLE_SIZE
    enable_push::Bool = true
    max_concurrent_streams::UInt32 = typemax(UInt32)
    initial_window_size::UInt32 = DEFAULT_WINDOW_SIZE
    max_frame_size::UInt32 = DEFAULT_MAX_FRAME_SIZE
    max_header_list_size::UInt32 = typemax(UInt32)
    enable_connect_protocol::Bool = false
end

# Validation function
function validate_http2_settings!(settings::HTTP2Settings)
    # Validate according to RFC 7540
    settings.initial_window_size > 2147483647 && throw(FlowControlError("SETTINGS_INITIAL_WINDOW_SIZE must not exceed 2^31-1"))
    !(16384 ≤ settings.max_frame_size ≤ 16777215) && throw(ProtocolError("SETTINGS_MAX_FRAME_SIZE must be between 2^14 and 2^24-1"))
    return settings
end

# Constructor with automatic validation
function HTTP2Settings(args...; kwargs...)
    settings = HTTP2Settings(args...; kwargs...)
    return validate_http2_settings!(settings)
end


"""
    apply_settings!(settings::HTTP2Settings, frame::SettingsFrame)

Updates the `settings` object with parameters from an incoming SETTINGS frame.
Performs validation for each parameter. Ignores ACK frames.
"""
function apply_settings!(settings::HTTP2Settings, frame::SettingsFrame)
    frame.ack && return  # ACK frames just confirm, don't change settings

    for (param_id, value) in frame.parameters
        param_enum = SettingsParameter(param_id)
        
        # Validate and update based on parameter type
        if param_enum == SETTINGS_HEADER_TABLE_SIZE
            settings.header_table_size = UInt32(value)
        elseif param_enum == SETTINGS_ENABLE_PUSH
            (value != 0 && value != 1) && throw(ProtocolError("SETTINGS_ENABLE_PUSH must be 0 or 1"))
            settings.enable_push = (value == 1)
        elseif param_enum == SETTINGS_MAX_CONCURRENT_STREAMS
            settings.max_concurrent_streams = UInt32(value)
        elseif param_enum == SETTINGS_INITIAL_WINDOW_SIZE
            value > 2147483647 && throw(FlowControlError("SETTINGS_INITIAL_WINDOW_SIZE must not exceed 2^31-1"))
            settings.initial_window_size = UInt32(value)
        elseif param_enum == SETTINGS_MAX_FRAME_SIZE
            !(16384 ≤ value ≤ 16777215) && throw(ProtocolError("SETTINGS_MAX_FRAME_SIZE must be between 2^14 and 2^24-1"))
            settings.max_frame_size = UInt32(value)
        elseif param_enum == SETTINGS_MAX_HEADER_LIST_SIZE
            settings.max_header_list_size = UInt32(value)
        elseif param_enum == SETTINGS_ENABLE_CONNECT_PROTOCOL
            (value != 0 && value != 1) && throw(ProtocolError("SETTINGS_ENABLE_CONNECT_PROTOCOL must be 0 or 1"))
            settings.enable_connect_protocol = (value == 1)
        end
    end
end

"""
    copy(settings::HTTP2Settings) -> HTTP2Settings

Create a copy of HTTP/2 settings.
"""
function Base.copy(settings::HTTP2Settings)
    new_settings = HTTP2Settings(stream_id=settings.stream_id)
    new_settings.header_table_size = settings.header_table_size
    new_settings.enable_push = settings.enable_push
    new_settings.max_concurrent_streams = settings.max_concurrent_streams
    new_settings.initial_window_size = settings.initial_window_size
    new_settings.max_frame_size = settings.max_frame_size
    new_settings.max_header_list_size = settings.max_header_list_size
    new_settings.enable_connect_protocol = settings.enable_connect_protocol
    return new_settings
end

"""
    validate_settings(settings::HTTP2Settings) -> Bool

Validate that all settings values are within acceptable ranges according to RFC 7540.
Throws HTTP2Error if any setting is invalid.
"""
function validate_settings(settings::HTTP2Settings)
    if settings.initial_window_size > MAX_WINDOW_SIZE
        throw(FlowControlError("SETTINGS_INITIAL_WINDOW_SIZE ($(settings.initial_window_size)) exceeds maximum ($(MAX_WINDOW_SIZE))"))
    end
    
    if settings.max_frame_size < SETTINGS_MAX_FRAME_SIZE_MIN || settings.max_frame_size > SETTINGS_MAX_FRAME_SIZE_MAX
        throw(ProtocolError("SETTINGS_MAX_FRAME_SIZE ($(settings.max_frame_size)) must be between $(SETTINGS_MAX_FRAME_SIZE_MIN) and $(SETTINGS_MAX_FRAME_SIZE_MAX)"))
    end
    
    return true
end

"""
    settings_to_dict(settings::HTTP2Settings) -> Dict{UInt16, UInt32}

Convert HTTP2Settings to a dictionary for transmission in SETTINGS frame.
Only includes non-default values to minimize frame size.
"""
function settings_to_dict(settings::HTTP2Settings)
    dict = Dict{UInt16, UInt32}()
    dict[UInt16(SETTINGS_HEADER_TABLE_SIZE)] = settings.header_table_size
    dict[UInt16(SETTINGS_ENABLE_PUSH)] = settings.enable_push ? 1 : 0
    dict[UInt16(SETTINGS_MAX_CONCURRENT_STREAMS)] = settings.max_concurrent_streams
    dict[UInt16(SETTINGS_INITIAL_WINDOW_SIZE)] = settings.initial_window_size
    dict[UInt16(SETTINGS_MAX_FRAME_SIZE)] = settings.max_frame_size
    dict[UInt16(SETTINGS_MAX_HEADER_LIST_SIZE)] = settings.max_header_list_size
    dict[UInt16(SETTINGS_ENABLE_CONNECT_PROTOCOL)] = settings.enable_connect_protocol ? 1 : 0
    return dict
end



"""
    apply_setting!(settings::HTTP2Settings, setting_id::UInt16, value::UInt32)

Apply a single setting value. Validates the setting before applying.
"""


function apply_setting!(settings::HTTP2Settings, setting_id::UInt16, value::UInt32)
    # Centralized validation call. This is the core of the refactoring.
    Validation.validate_settings_value(setting_id, value)

    # Apply the setting without redundant checks.
    if setting_id == UInt16(SETTINGS_HEADER_TABLE_SIZE)
        settings.header_table_size = value
    elseif setting_id == UInt16(SETTINGS_ENABLE_PUSH)
        settings.enable_push = (value == 1)
    elseif setting_id == UInt16(SETTINGS_MAX_CONCURRENT_STREAMS)
        settings.max_concurrent_streams = value
    elseif setting_id == UInt16(SETTINGS_INITIAL_WINDOW_SIZE)
        settings.initial_window_size = value
    elseif setting_id == UInt16(SETTINGS_MAX_FRAME_SIZE)
        settings.max_frame_size = value
    elseif setting_id == UInt16(SETTINGS_MAX_HEADER_LIST_SIZE)
        settings.max_header_list_size = value
    elseif setting_id == UInt16(SETTINGS_ENABLE_CONNECT_PROTOCOL)
        settings.enable_connect_protocol = (value == 1)
    else
        # Per RFC 7540, Section 6.5.2: An endpoint that receives a SETTINGS frame with any
        # unknown parameter MUST ignore that parameter.
        @debug "Ignoring unknown setting ID: $setting_id"
    end
end

"""
    create_settings_frame(settings::HTTP2Settings; ack::Bool = false) -> SettingsFrame

Create a SETTINGS frame from HTTP2Settings.
"""
function create_settings_frame(settings::HTTP2Settings; ack::Bool = false)
    if ack
        # ACK frames have empty payload
        return SettingsFrame(Dict{UInt16, UInt32}(); ack=true)
    else
        settings_dict = settings_to_dict(settings)
        return SettingsFrame(settings_dict; ack=false)
    end
end


"""
    get_effective_max_frame_size(local_settings::HTTP2Settings, remote_settings::HTTP2Settings) -> UInt32

Get the effective maximum frame size that can be sent, which is the minimum of 
local max frame size and remote max frame size.
"""
function get_effective_max_frame_size(local_settings::HTTP2Settings, remote_settings::HTTP2Settings)
    return min(local_settings.max_frame_size, remote_settings.max_frame_size)
end


"""
    Base.show(io::IO, settings::HTTP2Settings)

Pretty print HTTP2Settings for debugging.
"""
function Base.show(io::IO, settings::HTTP2Settings)
    @info (io, "HTTP2Settings:")
    @info (io, "  Header Table Size: $(settings.header_table_size)")
    @info (io, "  Enable Push: $(settings.enable_push)")
    @info (io, "  Max Concurrent Streams: $(settings.max_concurrent_streams)")
    @info (io, "  Initial Window Size: $(settings.initial_window_size)")
    @info (io, "  Max Frame Size: $(settings.max_frame_size)")
    @info (io, "  Max Header List Size: $(settings.max_header_list_size)")
    @info (io, "  Enable Connect Protocol: $(settings.enable_connect_protocol)")
end

"""
    create_client_settings() -> HTTP2Settings

Create default settings appropriate for an HTTP/2 client.
"""
function create_client_settings()
    settings = HTTP2Settings()
    # Clients typically don't need server push
    settings.enable_push = false
    # Set reasonable limits for client
    settings.max_concurrent_streams = 100
    settings.max_header_list_size = 8192
    return settings
end

"""
    create_server_settings() -> HTTP2Settings

Create default settings appropriate for an HTTP/2 server.
"""
function create_server_settings(; max_concurrent_streams::Integer = 1000)::HTTP2Settings
    settings = HTTP2Settings()
    settings.enable_push = true
    settings.max_concurrent_streams = UInt32(max_concurrent_streams) # <-- Δυναμική τιμή
    settings.max_header_list_size = 16384
    settings.max_frame_size = 32768
    return settings
end
end