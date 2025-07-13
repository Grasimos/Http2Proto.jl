"""
    H2Settings

HTTP/2 settings management for connection configuration.

This module provides functionality for managing HTTP/2 connection settings,
including tracking setting changes, acknowledgments, and maintaining both
current and pending setting values as specified in RFC 7540.
"""
module H2Settings

using ..H2Exceptions
using ..H2Errors
using Http2Frames.FrameTypes
using DataStructures

export Settings, ChangedSetting

"""
    ChangedSetting

Represents a setting that has changed and is awaiting acknowledgment.

This struct tracks the transition of a setting value from its original
value to a new value, which is useful for implementing the HTTP/2 settings
acknowledgment mechanism.

# Fields
- `setting::SettingsParameter`: The setting parameter that changed
- `original_value::Union{UInt32, Nothing}`: The previous value (Nothing if this is the first value)
- `new_value::UInt32`: The new value that was set

# Examples
```julia
julia> changed = ChangedSetting(SETTINGS_MAX_FRAME_SIZE, UInt32(16384), UInt32(32768))
ChangedSetting(SETTINGS_MAX_FRAME_SIZE, 0x00004000, 0x00008000)
```
"""
struct ChangedSetting
    setting::SettingsParameter
    original_value::Union{UInt32, Nothing}
    new_value::UInt32
end

"""
    Settings

HTTP/2 settings management with support for pending acknowledgments.

The Settings struct manages HTTP/2 connection settings according to RFC 7540.
It maintains a queue of values for each setting to handle the case where
settings are changed before they are acknowledged by the peer.

Key features:
- Implements Dict-like interface for easy access
- Tracks pending setting changes until acknowledgment
- Handles client/server differences (e.g., SETTINGS_ENABLE_PUSH)
- Maintains setting history for proper acknowledgment handling

# Fields
- `_settings::Dict{SettingsParameter, Deque{UInt32}}`: Internal storage with queued values

# Examples
```julia
julia> settings = Settings(client=true)
Settings(...)

julia> settings[SETTINGS_MAX_FRAME_SIZE]
0x00004000

julia> settings[SETTINGS_MAX_FRAME_SIZE] = UInt32(32768)
julia> changed = acknowledge(settings)
```
"""
mutable struct Settings
    _settings::Dict{SettingsParameter, Deque{UInt32}}
    
    function Settings(; client::Bool, initial_values::Dict{SettingsParameter, UInt32}=Dict{SettingsParameter, UInt32}())
        defaults = copy(DEFAULT_SETTINGS)
        defaults[SETTINGS_ENABLE_PUSH] = client ? 1 : 0
        
        merge!(defaults, initial_values)
        
        internal_dict = Dict{SettingsParameter, Deque{UInt32}}()
        for (k, v) in defaults
            internal_dict[k] = Deque{UInt32}()
            push!(internal_dict[k], v)
        end
        
        new(internal_dict)
    end
end


"""
    Base.getindex(s::Settings, key::SettingsParameter) -> UInt32

Get the current value of a setting.

Returns the most recent (current) value for the given setting parameter.
If there are pending changes, this returns the pending value.

# Arguments
- `s::Settings`: The settings object
- `key::SettingsParameter`: The setting parameter to retrieve

# Returns
- `UInt32`: The current value of the setting

# Examples
```julia
julia> settings = Settings(client=true)
julia> settings[SETTINGS_MAX_FRAME_SIZE]
0x00004000
```
"""
function Base.getindex(s::Settings, key::SettingsParameter)
    return first(s._settings[key])
end

"""
    Base.setindex!(s::Settings, value::UInt32, key::SettingsParameter)

Set a new value for a setting.

This adds a new value to the setting's queue. The new value becomes the
current value, but the old value is preserved until acknowledgment.

# Arguments
- `s::Settings`: The settings object
- `value::UInt32`: The new value to set
- `key::SettingsParameter`: The setting parameter to modify

# Examples
```julia
julia> settings = Settings(client=true)
julia> settings[SETTINGS_MAX_FRAME_SIZE] = UInt32(32768)
```
"""
function Base.setindex!(s::Settings, value::UInt32, key::SettingsParameter)
    if !haskey(s._settings, key)
        s._settings[key] = Deque{UInt32}()
    end
    empty!(s._settings[key])
    push!(s._settings[key], value)
end

"""
    Base.haskey(s::Settings, key::SettingsParameter) -> Bool

Check if a setting parameter exists.

# Arguments
- `s::Settings`: The settings object
- `key::SettingsParameter`: The setting parameter to check

# Returns
- `Bool`: true if the setting exists, false otherwise
"""
Base.haskey(s::Settings, key::SettingsParameter) = haskey(s._settings, key)

"""
    Base.get(s::Settings, key::SettingsParameter, default) -> Union{UInt32, typeof(default)}

Get a setting value with a default fallback.

# Arguments
- `s::Settings`: The settings object
- `key::SettingsParameter`: The setting parameter to retrieve
- `default`: The default value to return if the setting doesn't exist

# Returns
- The setting value if it exists, otherwise the default value
"""
function Base.get(s::Settings, key::SettingsParameter, default)
    return haskey(s, key) ? s[key] : default
end

"""
    Base.iterate(s::Settings, state...) -> Union{Tuple, Nothing}

Iterate over all settings as key-value pairs.

This allows the Settings object to be used in for loops and other
iteration contexts.

# Arguments
- `s::Settings`: The settings object
- `state...`: Iterator state (internal use)

# Returns
- `Tuple{Pair{SettingsParameter, UInt32}, Any}`: Next key-value pair and state
- `Nothing`: If iteration is complete
"""
function Base.iterate(s::Settings, state...)
    iter_result = iterate(s._settings, state...)
    isnothing(iter_result) && return nothing
    
    (pair, next_state) = iter_result
    return (pair.first => first(pair.second), next_state)
end

"""
    Base.length(s::Settings) -> Int

Get the number of settings.

# Arguments
- `s::Settings`: The settings object

# Returns
- `Int`: The number of settings
"""
Base.length(s::Settings) = length(s._settings)

"""
    acknowledge(s::Settings) -> Dict{SettingsParameter, ChangedSetting}

Acknowledge pending setting changes.

This function should be called when a SETTINGS acknowledgment frame is received.
It processes all pending setting changes and returns information about what
settings were changed.

# Arguments
- `s::Settings`: The settings object

# Returns
- `Dict{SettingsParameter, ChangedSetting}`: Map of changed settings with their old and new values

# Examples
```julia
julia> settings = Settings(client=true)
julia> settings[SETTINGS_MAX_FRAME_SIZE] = UInt32(32768)
julia> changed = acknowledge(settings)
julia> haskey(changed, SETTINGS_MAX_FRAME_SIZE)
true
```
"""
function acknowledge(s::Settings)::Dict{SettingsParameter, ChangedSetting}
    changed = Dict{SettingsParameter, ChangedSetting}()
    for (key, values) in s._settings
        if length(values) > 1
            original_value = popfirst!(values)
            new_value = first(values)
            changed[key] = ChangedSetting(key, original_value, new_value)
        end
    end
    return changed
end

end