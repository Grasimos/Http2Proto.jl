"""
    H2Windows

HTTP/2 flow control window management.

This module provides functionality for managing HTTP/2 flow control windows,
including automatic window updates and flow control violation detection.
"""
module H2Windows

using ..H2Exceptions

export WindowManager, window_consumed!, window_opened!, process_bytes!

"""
    LARGEST_FLOW_CONTROL_WINDOW

The maximum allowed size for an HTTP/2 flow control window (2^31 - 1).
As specified in RFC 7540, flow control windows cannot exceed this value.
"""
const LARGEST_FLOW_CONTROL_WINDOW = UInt32(2^31 - 1)

"""
    WindowManager

A struct for automatic and intelligent management of an HTTP/2 flow control window.

The WindowManager handles the complex logic of HTTP/2 flow control, including:
- Tracking the current window size
- Detecting flow control violations
- Automatically determining when to send WINDOW_UPDATE frames
- Managing window expansion and consumption

# Fields
- `max_window_size::UInt32`: The maximum window size seen so far
- `current_window_size::UInt32`: The current available window size
- `_bytes_processed::UInt32`: Internal counter for processed bytes awaiting window update

# Examples
```julia
julia> wm = WindowManager(UInt32(65536))
WindowManager(0x00010000, 0x00010000, 0x00000000)

julia> window_consumed!(wm, UInt32(1024))  # Received 1024 bytes
```
"""
mutable struct WindowManager
    max_window_size::UInt32
    current_window_size::UInt32
    _bytes_processed::UInt32

    function WindowManager(max_window_size::UInt32)
        # Ensure the initial size is valid
        @assert max_window_size <= LARGEST_FLOW_CONTROL_WINDOW
        new(max_window_size, max_window_size, 0)
    end
end

"""
    window_consumed!(wm::WindowManager, size::UInt32)

Decrease the window because we received 'size' bytes from the peer.

This function should be called when data is received from the remote peer
to account for the flow control window consumption.

# Arguments
- `wm::WindowManager`: The window manager to update
- `size::UInt32`: The number of bytes received

# Throws
- `FlowControlError`: If the window would shrink below 0

# Examples
```julia
julia> wm = WindowManager(UInt32(65536))
julia> window_consumed!(wm, UInt32(1024))
julia> wm.current_window_size
0x0000fc00
```
"""
function window_consumed!(wm::WindowManager, size::UInt32)
    wm.current_window_size -= size
    if wm.current_window_size > LARGEST_FLOW_CONTROL_WINDOW 
        throw(FlowControlError("Flow control window shrunk below 0"))
    end
end

"""
    window_opened!(wm::WindowManager, size::UInt32)

Increase the window, typically due to a SETTINGS or WINDOW_UPDATE frame.

This function should be called when receiving WINDOW_UPDATE frames or
when SETTINGS frames modify the initial window size.

# Arguments
- `wm::WindowManager`: The window manager to update
- `size::UInt32`: The number of bytes to add to the window

# Throws
- `FlowControlError`: If the window would exceed 2^31 - 1

# Examples
```julia
julia> wm = WindowManager(UInt32(65536))
julia> window_opened!(wm, UInt32(32768))
julia> wm.current_window_size
0x00018000
```
"""
function window_opened!(wm::WindowManager, size::UInt32)
    new_size = wm.current_window_size + size
    if new_size > LARGEST_FLOW_CONTROL_WINDOW
        throw(FlowControlError("Flow control window cannot exceed 2^31 - 1"))
    end
    wm.current_window_size = new_size
    wm.max_window_size = max(wm.current_window_size, wm.max_window_size)
end

"""
    process_bytes!(wm::WindowManager, size::UInt32) -> Union{UInt32, Nothing}

The application processed 'size' bytes. Decide if a WINDOW_UPDATE should be sent.

This function implements the automatic window update logic. It tracks how many
bytes have been processed by the application and determines when to send a
WINDOW_UPDATE frame to maintain good flow control performance.

# Arguments
- `wm::WindowManager`: The window manager to update
- `size::UInt32`: The number of bytes that were processed by the application

# Returns
- `UInt32`: The increment value for a WINDOW_UPDATE frame, if one should be sent
- `Nothing`: If no WINDOW_UPDATE frame is needed at this time

# Examples
```julia
julia> wm = WindowManager(UInt32(65536))
julia> window_consumed!(wm, UInt32(32768))  # Receive data
julia> increment = process_bytes!(wm, UInt32(32768))  # Process data
julia> increment !== nothing  # Check if WINDOW_UPDATE needed
true
```
"""
function process_bytes!(wm::WindowManager, size::UInt32)::Union{UInt32, Nothing}
    wm._bytes_processed += size
    return _maybe_update_window!(wm)
end

"""
    _maybe_update_window!(wm::WindowManager) -> Union{UInt32, Nothing}

Internal function to determine if a WINDOW_UPDATE frame should be sent.

This implements the heuristic for automatic window updates: send a WINDOW_UPDATE
when the number of processed bytes reaches half of the maximum window size.

# Arguments
- `wm::WindowManager`: The window manager to check

# Returns
- `UInt32`: The increment value for a WINDOW_UPDATE frame, if one should be sent
- `Nothing`: If no WINDOW_UPDATE frame is needed
"""
function _maybe_update_window!(wm::WindowManager)::Union{UInt32, Nothing}
    if wm._bytes_processed == 0
        return nothing
    end
    if wm._bytes_processed >= (wm.max_window_size / 2)
        increment = wm._bytes_processed
        wm.current_window_size += increment
        wm._bytes_processed = 0
        return increment
    end

    return nothing
end

end